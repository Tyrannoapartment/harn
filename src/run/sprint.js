/**
 * Scope-based sprint loop orchestration.
 * Flow: Planner → Generator-Contract → Evaluator-Contract → [PASS] →
 *       Generator-Implements (scope expansion detection) → Evaluator-QA →
 *       [PASS] → Planner writes scope result to run_report.md → next scope →
 *       Final report when all scopes complete.
 */

import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { join } from 'node:path';
import {
  currentScopeNum, scopeDir, scopeStatus, scopeIteration,
  setScopeIteration, setScopeStatus, setCurrentScopeNum,
} from './run.js';
import { cmdContract, cmdImplement, cmdEvaluate, cmdNext, cmdDesign } from './commands.js';
import { logInfo, logOk, logWarn, logErr, logStep } from '../core/logger.js';
import { t } from '../core/i18n.js';
import { progressBar, formatElapsed } from './progress.js';

import { detectAiCli, RateLimitExhaustedError } from '../ai/backend.js';

/**
 * Main scope-based sprint loop: contract → implement → evaluate → next.
 */
export async function runSprintLoop({ runDir, config, harnDir, scriptDir, rootDir, onLog, onData, sse, onProgress, onResult }) {
  const pidFile = join(harnDir, 'harn.pid');
  writeFileSync(pidFile, String(process.pid));

  const startTime = Date.now();
  let aborted = false;

  const backend = config.AI_BACKEND || detectAiCli();

  // Infer backend from model name prefix
  const inferFromModel = (model) => {
    if (!model) return '';
    const m = model.toLowerCase();
    if (m.startsWith('claude-')) return 'claude';
    if (m.startsWith('gpt-') || m.startsWith('o1') || m.startsWith('o3')) return 'codex';
    if (m.startsWith('gemini-')) return 'gemini';
    return '';
  };

  const PHASE_MODEL_KEYS = {
    plan: 'PLANNER_MODEL',
    design: 'DESIGNER_MODEL',
    contract: 'GENERATOR_CONTRACT_MODEL',
    implement: 'GENERATOR_IMPL_MODEL',
    evaluate: 'EVALUATOR_QA_MODEL',
  };
  const phaseModel = (phase) => config[PHASE_MODEL_KEYS[phase]] || '';

  const PHASE_BACKEND_KEYS = {
    plan: 'PLANNER_BACKEND',
    design: 'DESIGNER_BACKEND',
    contract: 'GENERATOR_CONTRACT_BACKEND',
    implement: 'GENERATOR_IMPL_BACKEND',
    evaluate: 'EVALUATOR_QA_BACKEND',
  };
  const phaseBackend = (phase) => {
    const key = PHASE_BACKEND_KEYS[phase];
    if (key && config[key]) return config[key];
    const inferred = inferFromModel(phaseModel(phase));
    if (inferred) return inferred;
    return backend;
  };
  const phaseAgent = (phase) => {
    const a = { plan: 'planner', design: 'designer', contract: 'generator', implement: 'generator', evaluate: 'evaluator', next: 'planner' };
    return a[phase] || '';
  };

  // Graceful shutdown
  const cleanup = () => {
    aborted = true;
    try { unlinkSync(pidFile); } catch { /* ignore */ }
  };
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);

  const checkStop = () => {
    if (aborted) return true;
    const stopFile = join(runDir, '.stop');
    if (existsSync(stopFile)) {
      try { unlinkSync(stopFile); } catch { /* ignore */ }
      aborted = true;
      logWarn('Stop signal received — aborting sprint loop.');
      return true;
    }
    return false;
  };

  const AI_PHASES = new Set(['plan', 'design', 'contract', 'implement', 'evaluate']);

  const emitStatus = (phase, extra = {}) => {
    const isAI = AI_PHASES.has(phase);
    if (sse) sse.broadcastStatus({
      state: 'running', phase, runDir,
      ...(isAI ? { backend: phaseBackend(phase), model: phaseModel(phase), agent: phaseAgent(phase) } : {}),
      ...extra,
    });
  };
  const emitProgress = (currentScope, totalScopes, phase, iteration) => {
    const data = { currentScope, totalScopes, phase, iteration, startTime, elapsed: Date.now() - startTime };
    if (sse) sse.broadcastProgress(data);
    if (onProgress) onProgress(data);
  };

  try {
    const totalFile = join(runDir, 'scope_count');
    const totalScopes = existsSync(totalFile)
      ? parseInt(readFileSync(totalFile, 'utf-8').trim(), 10) : 1;
    const maxIterations = parseInt(config.MAX_ITERATIONS, 10) || 5;

    emitStatus('starting', { totalScopes });
    let currentScope = currentScopeNum(runDir);
    let rateLimited = false;

    while (currentScope <= totalScopes && !aborted) {
      const sDir = scopeDir(runDir, currentScope);
      const status = scopeStatus(runDir, currentScope);

      // Progress display
      const elapsed = formatElapsed(startTime);
      logStep(`Scope ${currentScope}/${totalScopes}  ${progressBar(currentScope - 1, totalScopes, 20)}  ${elapsed}`);
      emitProgress(currentScope, totalScopes, 'starting', 0);

      // Skip already-passed scopes
      if (status === 'pass') {
        logInfo(`Scope ${currentScope} already passed, skipping.`);
        currentScope++;
        setCurrentScopeNum(runDir, currentScope);
        continue;
      }

      try {
      // ── Design phase (if scope needs design) ──
      const designFile = join(sDir, 'design.md');
      if (!existsSync(designFile)) {
        const scopePlanFile = join(runDir, 'plan', `scope-${currentScope}.md`);
        let needsDesign = false;
        if (existsSync(scopePlanFile)) {
          const scopePlanText = readFileSync(scopePlanFile, 'utf-8');
          needsDesign = /\*\*needs_design\*\*:\s*true/i.test(scopePlanText)
            || /needs_design:\s*true/i.test(scopePlanText);
        }
        if (needsDesign) {
          if (checkStop()) break;
          emitStatus('design', { scope: currentScope, totalScopes });
          emitProgress(currentScope, totalScopes, 'design', 0);
          await cmdDesign({ runDir, scopeNum: currentScope, config, harnDir, scriptDir, onLog, onData, onResult });
          if (checkStop()) break;
        }
      }

      // ── Contract phase ──
      const contractFile = join(sDir, 'contract.md');
      if (!existsSync(contractFile)) {
        if (checkStop()) break;
        emitStatus('contract', { scope: currentScope, totalScopes });
        emitProgress(currentScope, totalScopes, 'contract', 0);
        await cmdContract({ runDir, scopeNum: currentScope, config, harnDir, scriptDir, onLog, onData, onResult });
        if (checkStop()) break;
      }

      // ── Implementation + evaluation loop ──
      let iter = scopeIteration(runDir, currentScope);
      let passed = false;

      while (iter <= maxIterations && !aborted) {
        if (checkStop()) break;
        setScopeIteration(runDir, currentScope, iter);
        logInfo(`Scope ${currentScope} — iteration ${iter}/${maxIterations}`);

        // Implement
        emitStatus('implement', { scope: currentScope, iteration: iter, totalScopes });
        emitProgress(currentScope, totalScopes, 'implement', iter);
        const implResult = await cmdImplement({ runDir, scopeNum: currentScope, config, harnDir, scriptDir, onLog, onData, onResult });
        if (checkStop()) break;

        // Broadcast file changes after implementation
        if (rootDir && onLog) {
          try {
            const diff = execSync('git diff --stat', { cwd: rootDir, encoding: 'utf-8', timeout: 5000 }).trim();
            const untracked = execSync('git ls-files --others --exclude-standard', { cwd: rootDir, encoding: 'utf-8', timeout: 5000 }).trim();
            if (diff) onLog(`Changed files:\n${diff}`);
            if (untracked) onLog(`New files:\n${untracked}`);
          } catch { /* git not available */ }
        }

        // Handle scope expansion
        if (implResult.needsExpansion) {
          logWarn('Scope expansion detected — evaluator will assess in QA phase.');
        }

        if (checkStop()) break;

        // Evaluate
        emitStatus('evaluate', { scope: currentScope, iteration: iter, totalScopes });
        emitProgress(currentScope, totalScopes, 'evaluate', iter);
        const { verdict } = await cmdEvaluate({
          runDir, scopeNum: currentScope, config, harnDir, scriptDir, rootDir, onLog, onData, onResult,
        });
        if (checkStop()) break;

        if (verdict === 'pass') {
          passed = true;
          logOk(`Scope ${currentScope} PASSED`);
          emitProgress(currentScope, totalScopes, 'pass', iter);
          break;
        }

        logWarn(`Scope ${currentScope} FAILED — iteration ${iter}/${maxIterations}`);
        emitProgress(currentScope, totalScopes, 'fail', iter);
        iter++;
      }

      // If aborted at any point, break the outer loop entirely
      if (aborted) break;

      if (!passed) {
        logWarn(`Max iterations (${maxIterations}) reached for Scope ${currentScope}. Advancing.`);
        setScopeStatus(runDir, currentScope, 'fail');
      }

      // ── Next: write scope result to report + advance ──
      emitStatus('next', { scope: currentScope, totalScopes });
      const { complete } = await cmdNext({
        runDir, scopeNum: currentScope, config, harnDir, scriptDir, rootDir, onLog, onData, onResult,
      });
      if (checkStop()) break;

      if (complete) break;
      currentScope = currentScopeNum(runDir);

      } catch (err) {
        if (err instanceof RateLimitExhaustedError) {
          rateLimited = true;
          aborted = true;
          logErr(`Rate limit reached — all fallback models exhausted (${err.lastModel}). Stopping sprint.`);
          if (onLog) onLog(`⚠️ Rate limit: ${err.message}`);
          break;
        }
        throw err;
      }
    }

    if (rateLimited) {
      if (sse) sse.broadcastStatus({ state: 'waiting', phase: 'rate_limited' });
    } else if (aborted) {
      logWarn('Sprint loop aborted.');
      if (sse) sse.broadcastStatus({ state: 'waiting', phase: 'stopped' });
    } else {
      logOk(t('RUN_COMPLETE'));
      if (sse) sse.broadcastStatus({ state: 'waiting', phase: 'complete' });
    }

    return { aborted };
  } finally {
    process.removeListener('SIGINT', cleanup);
    process.removeListener('SIGTERM', cleanup);
    try { unlinkSync(pidFile); } catch { /* ignore */ }
  }
}
