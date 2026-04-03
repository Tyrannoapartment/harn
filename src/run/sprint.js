/**
 * Sprint loop orchestration.
 * Replaces lib/sprint.sh
 */

import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import {
  currentSprintNum, sprintDir, sprintStatus, sprintIteration,
  setSprintIteration, setSprintStatus, setCurrentSprintNum,
} from './run.js';
import { cmdContract, cmdImplement, cmdEvaluate, cmdNext } from './commands.js';
import { logInfo, logOk, logWarn, logErr, logStep } from '../core/logger.js';
import { t } from '../core/i18n.js';
import { progressBar, formatElapsed } from './progress.js';

import { detectBackend } from '../ai/backend.js';

/**
 * Main sprint loop: contract → implement → evaluate → next.
 */
export async function runSprintLoop({ runDir, config, harnDir, scriptDir, rootDir, onLog, onData, sse, onProgress, onResult }) {
  const pidFile = join(harnDir, 'harn.pid');
  writeFileSync(pidFile, String(process.pid));

  const startTime = Date.now();
  let aborted = false;
  const backend = detectBackend();

  // Model lookup per phase
  const phaseModel = (phase) => {
    const m = {
      plan: config.COPILOT_MODEL_PLANNER,
      contract: config.COPILOT_MODEL_GENERATOR_CONTRACT,
      implement: config.COPILOT_MODEL_GENERATOR_IMPL,
      evaluate: config.COPILOT_MODEL_EVALUATOR_QA,
    };
    return m[phase] || '';
  };
  const phaseAgent = (phase) => {
    const a = { plan: 'planner', contract: 'generator', implement: 'generator', evaluate: 'evaluator', next: 'evaluator' };
    return a[phase] || '';
  };

  // Graceful shutdown handler
  const cleanup = () => {
    aborted = true;
    try { unlinkSync(pidFile); } catch { /* ignore */ }
  };
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);

  // Helper to broadcast status/progress
  const emitStatus = (phase, extra = {}) => {
    if (sse) sse.broadcastStatus({
      state: 'running', phase, runDir,
      backend, model: phaseModel(phase), agent: phaseAgent(phase),
      ...extra,
    });
  };
  const emitProgress = (currentSprint, totalSprints, phase, iteration) => {
    const data = { currentSprint, totalSprints, phase, iteration, startTime, elapsed: Date.now() - startTime };
    if (sse) sse.broadcastProgress(data);
    if (onProgress) onProgress(data);
  };

  try {
    const totalFile = join(runDir, 'sprint_count');
    const totalSprints = existsSync(totalFile)
      ? parseInt(readFileSync(totalFile, 'utf-8').trim(), 10) : 1;
    const maxIterations = parseInt(config.MAX_ITERATIONS, 10) || 5;

    emitStatus('starting', { totalSprints });
    let currentSprint = currentSprintNum(runDir);

    while (currentSprint <= totalSprints && !aborted) {
      const sDir = sprintDir(runDir, currentSprint);
      const status = sprintStatus(runDir, currentSprint);

      // Progress display
      const elapsed = formatElapsed(startTime);
      logStep(`Sprint ${currentSprint}/${totalSprints}  ${progressBar(currentSprint - 1, totalSprints, 20)}  ${elapsed}`);
      emitProgress(currentSprint, totalSprints, 'starting', 0);

      // Skip already-passed sprints
      if (status === 'pass') {
        logInfo(`Sprint ${currentSprint} already passed, skipping.`);
        currentSprint++;
        setCurrentSprintNum(runDir, currentSprint);
        continue;
      }

      // Contract phase
      const contractFile = join(sDir, 'contract.md');
      if (!existsSync(contractFile)) {
        emitStatus('contract', { sprint: currentSprint, totalSprints });
        emitProgress(currentSprint, totalSprints, 'contract', 0);
        await cmdContract({ runDir, sprintNum: currentSprint, config, harnDir, scriptDir, onLog, onData, onResult });
      }

      // Implementation + evaluation loop
      let iter = sprintIteration(runDir, currentSprint);
      let passed = false;

      while (iter <= maxIterations && !aborted) {
        setSprintIteration(runDir, currentSprint, iter);
        logInfo(`${t('SPRINT_START')} ${currentSprint} — iteration ${iter}/${maxIterations}`);

        // Implement
        emitStatus('implement', { sprint: currentSprint, iteration: iter, totalSprints });
        emitProgress(currentSprint, totalSprints, 'implement', iter);
        await cmdImplement({ runDir, sprintNum: currentSprint, config, harnDir, scriptDir, onLog, onData, onResult });

        // Evaluate
        emitStatus('evaluate', { sprint: currentSprint, iteration: iter, totalSprints });
        emitProgress(currentSprint, totalSprints, 'evaluate', iter);
        const { verdict } = await cmdEvaluate({
          runDir, sprintNum: currentSprint, config, harnDir, scriptDir, rootDir, onLog, onData, onResult,
        });

        if (verdict === 'pass') {
          passed = true;
          logOk(t('SPRINT_PASS'));
          emitProgress(currentSprint, totalSprints, 'pass', iter);
          break;
        }

        logWarn(`${t('SPRINT_FAIL')} — iteration ${iter}/${maxIterations}`);
        emitProgress(currentSprint, totalSprints, 'fail', iter);
        iter++;
      }

      if (!passed && !aborted) {
        logWarn(`Max iterations (${maxIterations}) reached for Sprint ${currentSprint}. Advancing.`);
        setSprintStatus(runDir, currentSprint, 'fail');
      }

      // Next
      emitStatus('next', { sprint: currentSprint, totalSprints });
      const { complete } = await cmdNext({
        runDir, sprintNum: currentSprint, config, harnDir, scriptDir, rootDir, onLog,
      });

      if (complete) break;
      currentSprint = currentSprintNum(runDir);
    }

    if (!aborted) {
      logOk(t('RUN_COMPLETE'));
    }
    // Broadcast completion
    if (sse) sse.broadcastStatus({ state: 'waiting', phase: 'complete' });
  } finally {
    process.removeListener('SIGINT', cleanup);
    process.removeListener('SIGTERM', cleanup);
    try { unlinkSync(pidFile); } catch { /* ignore */ }
  }
}
