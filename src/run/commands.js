/**
 * Sprint commands: plan, contract, implement, evaluate, next, stop, clear.
 * Replaces lib/commands.sh
 */

import { readFileSync, writeFileSync, existsSync, rmSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { execSync } from 'node:child_process';
import { invokeRole, invokeWithStreaming } from '../ai/invoke.js';
import { readBacklog, pendingSlugs, itemText, moveItemSection, upsertPlanLine, ensureSprintDir } from '../backlog/backlog.js';
import {
  createRun, syncRunLog, currentSprintNum, sprintDir,
  sprintStatus, setSprintStatus, sprintIteration, setSprintIteration,
  setCurrentSprintNum, countSprintsInBacklog, currentRunId,
} from './run.js';
import { logInfo, logOk, logWarn, logErr, logStep, stripAnsi } from '../core/logger.js';
import { t } from '../core/i18n.js';
import { getSprintDir } from '../core/config.js';

// ── Prompt resolution ─────────────────────────────────────────────────────────

/**
 * Load a prompt template file, checking .harn/prompts/ (custom) first,
 * then the built-in prompts/ directory.
 */
function loadPrompt(role, harnDir, scriptDir) {
  if (harnDir) {
    const custom = join(harnDir, 'prompts', `${role}.md`);
    if (existsSync(custom)) return readFileSync(custom, 'utf-8');
  }
  const builtin = join(scriptDir, 'prompts', `${role}.md`);
  if (existsSync(builtin)) return readFileSync(builtin, 'utf-8');
  return '';
}

// ── Section parser ────────────────────────────────────────────────────────────
function extractSection(output, sectionName) {
  const marker = `=== ${sectionName} ===`;
  const idx = output.indexOf(marker);
  if (idx === -1) return '';
  const start = idx + marker.length;
  // Find next section marker or end
  const nextMarker = output.indexOf('\n===', start);
  const end = nextMarker === -1 ? output.length : nextMarker;
  return output.slice(start, end).trim();
}

/**
 * Invoke an agent role with optional real-time streaming.
 * When `onData` callback is provided, uses invokeWithStreaming for real-time output.
 * Otherwise falls back to non-streaming invokeRole.
 */
async function invokeRoleStreaming(params) {
  const { onData, ...roleParams } = params;
  if (onData && typeof onData === 'function') {
    return invokeWithStreaming({ ...roleParams, onData });
  }
  return invokeRole(roleParams);
}

// ── cmd: backlog ──────────────────────────────────────────────────────────────
export function cmdBacklog({ config, rootDir }) {
  const sd = getSprintDir(rootDir);
  ensureSprintDir(sd);
  const data = readBacklog(sd);
  logStep(t('BACKLOG_PENDING'));
  if (data.pending.length === 0 && data.in_progress.length === 0) {
    logInfo(t('BACKLOG_EMPTY'));
    return;
  }
  for (const item of [...data.in_progress, ...data.pending]) {
    const status = data.in_progress.includes(item) ? '▶' : '○';
    console.log(`  ${status}  ${item.slug}  ${item.description || ''}`);
  }
}

// ── cmd: start ────────────────────────────────────────────────────────────────
export async function cmdStart({ slug, config, harnDir, rootDir, scriptDir, onLog, onData, onResult }) {
  const sd = getSprintDir(rootDir);
  ensureSprintDir(sd);

  // Pick slug
  if (!slug) {
    const slugs = pendingSlugs(sd);
    if (slugs.length === 0) throw new Error(t('BACKLOG_EMPTY'));
    slug = slugs[0];
  }

  logStep(`Starting: ${slug}`);

  // Create run
  const { id, runDir } = createRun(harnDir);
  const logFile = syncRunLog(harnDir, runDir);
  writeFileSync(join(runDir, 'prompt.txt'), slug);

  // Move to In Progress
  moveItemSection(sd, slug, 'Pending', 'In Progress');

  // Plan
  await cmdPlan({ slug, runDir, config, harnDir, rootDir, scriptDir, onLog, onData, onResult, logFile });

  return { runDir, id, slug };
}

// ── cmd: plan ─────────────────────────────────────────────────────────────────
export async function cmdPlan({ slug, runDir, config, harnDir, rootDir, scriptDir, onLog, onData, onResult, logFile }) {
  logStep(t('PLAN_START'));
  const sd = getSprintDir(rootDir);
  const item = slug || readFileSync(join(runDir, 'prompt.txt'), 'utf-8').trim();
  const itemDesc = itemText(sd, item);
  const sprintCount = config.SPRINT_COUNT || '1';

  // Read planner prompt template
  const plannerTemplate = loadPrompt('planner', harnDir, scriptDir);

  const prompt = [
    plannerTemplate,
    `\n\n## Backlog Item\n\n**${item}**\n${itemDesc}`,
    `\n\nTarget sprint count: ${sprintCount}`,
    '\n\nOutput your result using the exact section markers:\n=== plan.text ===\n=== spec.md ===\n=== sprint-plan.md ===',
  ].join('');

  const { output, backend, model } = await invokeRoleStreaming({
    role: 'planner', roleDetail: 'planner',
    prompt, runDir, harnDir, scriptDir, config, onLog, onData,
  });

  // Parse sections
  const planText = extractSection(output, 'plan.text');
  const specMd = extractSection(output, 'spec.md');
  const sprintBacklog = extractSection(output, 'sprint-plan.md');

  writeFileSync(join(runDir, 'plan.txt'), planText);
  writeFileSync(join(runDir, 'spec.md'), specMd);
  writeFileSync(join(runDir, 'sprint-plan.md'), sprintBacklog);

  // Update plan line in backlog
  if (planText) upsertPlanLine(sd, item, planText);

  // Set sprint count
  const numSprints = countSprintsInBacklog(sprintBacklog) || 1;
  writeFileSync(join(runDir, 'sprint_count'), String(numSprints));
  setCurrentSprintNum(runDir, 1);

  // Broadcast result report
  if (onResult) {
    onResult(specMd || output, { phase: 'plan', role: 'planner', backend, model });
  }

  logOk(t('PLAN_DONE'));
  return { planText, specMd, sprintBacklog };
}

// ── cmd: contract ─────────────────────────────────────────────────────────────
export async function cmdContract({ runDir, sprintNum, config, harnDir, scriptDir, onLog, onData, onResult }) {
  logStep(t('CONTRACT_START'));
  const sDir = sprintDir(runDir, sprintNum);

  const spec = existsSync(join(runDir, 'spec.md'))
    ? readFileSync(join(runDir, 'spec.md'), 'utf-8') : '';
  const sb = existsSync(join(runDir, 'sprint-plan.md'))
    ? readFileSync(join(runDir, 'sprint-plan.md'), 'utf-8') : '';

  // Generator proposes contract
  const genTemplate = loadPrompt('generator', harnDir, scriptDir);

  const genPrompt = [
    genTemplate,
    `\n\n## Product Spec\n\n${spec}`,
    `\n\n## Sprint Plan\n\n${sb}`,
    `\n\nYou are working on Sprint ${sprintNum}. Propose a contract (scope definition) for this sprint.`,
  ].join('');

  const genResult = await invokeRoleStreaming({
    role: 'generator', roleDetail: 'generator_contract',
    prompt: genPrompt, runDir, harnDir, scriptDir, config, onLog, onData,
  });
  let contractContent = genResult.output;

  // Broadcast generator's contract proposal
  if (onResult) {
    onResult(contractContent, { phase: 'contract', role: 'generator', backend: genResult.backend, model: genResult.model });
  }

  // Evaluator reviews contract
  const evalTemplate = loadPrompt('evaluator', harnDir, scriptDir);

  for (let round = 0; round < 3; round++) {
    const evalPrompt = [
      evalTemplate,
      `\n\n## Proposed Contract\n\n${contractContent}`,
      `\n\n## Sprint Plan\n\n${sb}`,
      '\n\nReview this contract. Respond with APPROVED or NEEDS_REVISION on its own line.',
    ].join('');

    const evalResult = await invokeRoleStreaming({
      role: 'evaluator', roleDetail: 'evaluator_contract',
      prompt: evalPrompt, runDir, harnDir, scriptDir, config, onLog, onData,
    });
    const evalOutput = evalResult.output;

    // Broadcast evaluator's review
    if (onResult) {
      onResult(evalOutput, { phase: 'contract-review', role: 'evaluator', backend: evalResult.backend, model: evalResult.model });
    }

    if (/APPROVED/i.test(evalOutput)) {
      logOk(t('CONTRACT_APPROVED'));
      break;
    }
    logWarn(t('CONTRACT_REVISION'));
    if (round < 2) {
      const revResult = await invokeRoleStreaming({
        role: 'generator', roleDetail: 'generator_contract',
        prompt: genPrompt + `\n\n## Revision Feedback\n\n${evalOutput}`,
        runDir, harnDir, scriptDir, config, onLog, onData,
      });
      contractContent = revResult.output;
      if (onResult) {
        onResult(contractContent, { phase: 'contract-revision', role: 'generator', backend: revResult.backend, model: revResult.model });
      }
    }
  }

  writeFileSync(join(sDir, 'contract.md'), contractContent);
  setSprintStatus(runDir, sprintNum, 'in-progress');
  return contractContent;
}

// ── cmd: implement ────────────────────────────────────────────────────────────
export async function cmdImplement({ runDir, sprintNum, config, harnDir, scriptDir, onLog, onData, onResult }) {
  logStep(t('IMPL_START'));
  const sDir = sprintDir(runDir, sprintNum);

  const contract = existsSync(join(sDir, 'contract.md'))
    ? readFileSync(join(sDir, 'contract.md'), 'utf-8') : '';
  const spec = existsSync(join(runDir, 'spec.md'))
    ? readFileSync(join(runDir, 'spec.md'), 'utf-8') : '';

  // Track iteration
  const iter = sprintIteration(runDir, sprintNum);
  setSprintIteration(runDir, sprintNum, iter);

  const lang = config.HARN_LANG || 'en';
  const genTemplate = loadPrompt('generator', harnDir, scriptDir);

  // Include previous QA report if retrying
  let qaContext = '';
  if (iter > 1 && existsSync(join(sDir, 'qa-report.md'))) {
    qaContext = `\n\n## Previous QA Report (Iteration ${iter - 1})\n\n` +
      readFileSync(join(sDir, 'qa-report.md'), 'utf-8');
  }

  const prompt = [
    genTemplate,
    `\n\n## Product Spec\n\n${spec}`,
    `\n\n## Sprint Contract\n\n${contract}`,
    qaContext,
    `\n\nImplement all features defined in the sprint contract. This is iteration ${iter}.`,
  ].join('');

  const { output, backend, model } = await invokeRoleStreaming({
    role: 'generator', roleDetail: 'generator_impl',
    prompt, runDir, harnDir, scriptDir, config, onLog, onData,
  });

  writeFileSync(join(sDir, 'implementation.md'), output);

  // Broadcast result report
  if (onResult) {
    onResult(output, { phase: 'implement', role: 'generator', backend, model, iteration: iter });
  }

  logOk(t('IMPL_DONE'));
  return output;
}

// ── cmd: evaluate ─────────────────────────────────────────────────────────────
export async function cmdEvaluate({ runDir, sprintNum, config, harnDir, scriptDir, rootDir, onLog, onData, onResult }) {
  logStep(t('EVAL_START'));
  const sDir = sprintDir(runDir, sprintNum);

  const contract = existsSync(join(sDir, 'contract.md'))
    ? readFileSync(join(sDir, 'contract.md'), 'utf-8') : '';
  const impl = existsSync(join(sDir, 'implementation.md'))
    ? readFileSync(join(sDir, 'implementation.md'), 'utf-8') : '';

  // Run build/test/lint if configured
  let testResults = '';
  for (const [key, label] of [['LINT_COMMAND', 'Lint'], ['TEST_COMMAND', 'Test'], ['E2E_COMMAND', 'E2E']]) {
    const cmd = config[key];
    if (!cmd) continue;
    try {
      const out = execSync(cmd, { cwd: rootDir, encoding: 'utf-8', timeout: 120_000 });
      testResults += `\n### ${label} Output\n\`\`\`\n${out}\n\`\`\`\n`;
    } catch (err) {
      testResults += `\n### ${label} Output (FAILED)\n\`\`\`\n${err.stdout || ''}\n${err.stderr || ''}\n\`\`\`\n`;
    }
  }

  const lang = config.HARN_LANG || 'en';
  const evalTemplate = loadPrompt('evaluator', harnDir, scriptDir);

  const prompt = [
    evalTemplate,
    `\n\n## Sprint Contract\n\n${contract}`,
    `\n\n## Implementation Summary\n\n${impl}`,
    testResults ? `\n\n## Automated Test Results\n${testResults}` : '',
    '\n\nEvaluate the implementation. End with exactly VERDICT: PASS or VERDICT: FAIL on its own line.',
  ].join('');

  const { output, backend, model } = await invokeRoleStreaming({
    role: 'evaluator', roleDetail: 'evaluator_qa',
    prompt, runDir, harnDir, scriptDir, config, onLog, onData,
  });

  writeFileSync(join(sDir, 'qa-report.md'), output);

  // Parse verdict
  const passMatch = /^VERDICT:\s*PASS\s*$/m.test(output);
  const failMatch = /^VERDICT:\s*FAIL\s*$/m.test(output);

  // Continuation enforcement: PASS requires actual file changes
  let verdict = passMatch ? 'pass' : 'fail';
  if (verdict === 'pass' && rootDir) {
    try {
      const diff = execSync('git diff --stat', { cwd: rootDir, encoding: 'utf-8' }).trim();
      const diffCached = execSync('git diff --cached --stat', { cwd: rootDir, encoding: 'utf-8' }).trim();
      if (!diff && !diffCached) {
        logWarn('PASS verdict overridden to FAIL — no file changes detected.');
        verdict = 'fail';
      }
    } catch { /* git not available, skip check */ }
  }

  setSprintStatus(runDir, sprintNum, verdict);

  // Broadcast result report
  if (onResult) {
    onResult(output, { phase: 'evaluate', role: 'evaluator', backend, model, verdict });
  }

  if (verdict === 'pass') {
    logOk(t('EVAL_PASS'));
  } else {
    logWarn(t('EVAL_FAIL'));
  }

  return { verdict, output };
}

// ── cmd: next ─────────────────────────────────────────────────────────────────
export async function cmdNext({ runDir, sprintNum, config, harnDir, scriptDir, rootDir, onLog }) {
  const totalFile = join(runDir, 'sprint_count');
  const total = existsSync(totalFile)
    ? parseInt(readFileSync(totalFile, 'utf-8').trim(), 10) : 1;

  if (sprintNum >= total) {
    // All sprints complete
    logOk(t('RUN_COMPLETE'));
    writeFileSync(join(runDir, 'completed'), 'true');
    const slug = existsSync(join(runDir, 'prompt.txt'))
      ? readFileSync(join(runDir, 'prompt.txt'), 'utf-8').trim() : '';
    if (slug) moveItemSection(getSprintDir(rootDir), slug, 'In Progress', 'Done');

    // Write handoff
    const handoff = `# Run Complete\n\nSlug: ${slug}\nSprints: ${total}\nCompleted: ${new Date().toISOString()}\n`;
    writeFileSync(join(runDir, 'handoff.md'), handoff);
    return { complete: true };
  }

  // Advance to next sprint
  const nextNum = sprintNum + 1;
  setCurrentSprintNum(runDir, nextNum);
  logInfo(`${t('NEXT_DONE')} → Sprint ${nextNum}`);
  return { complete: false, nextSprint: nextNum };
}

// ── cmd: stop ─────────────────────────────────────────────────────────────────
export function cmdStop(harnDir) {
  const pidFile = join(harnDir, 'harn.pid');
  if (existsSync(pidFile)) {
    try {
      const pid = parseInt(readFileSync(pidFile, 'utf-8').trim(), 10);
      process.kill(pid, 'SIGTERM');
      logOk('Stopped active run.');
    } catch {
      logWarn('Could not stop process.');
    }
    try { unlinkSync(pidFile); } catch { /* ignore */ }
  } else {
    logInfo('No active run to stop.');
  }
}

// ── cmd: clear ────────────────────────────────────────────────────────────────
export function cmdClear(harnDir) {
  const targets = ['current', 'current.log', 'harn.pid', 'harn.log'];
  for (const t of targets) {
    try { unlinkSync(join(harnDir, t)); } catch { /* ignore */ }
  }
  const runsDir = join(harnDir, 'runs');
  if (existsSync(runsDir)) {
    rmSync(runsDir, { recursive: true, force: true });
  }
  logOk('Cleared run data. Memory, prompts, and config preserved.');
}
