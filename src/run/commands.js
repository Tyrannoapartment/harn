/**
 * Sprint commands: plan, contract, implement, evaluate, next, stop, clear.
 * Replaces lib/commands.sh
 */

import { readFileSync, writeFileSync, existsSync, rmSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { execSync } from 'node:child_process';
import { invokeRole } from '../ai/invoke.js';
import { readBacklog, pendingSlugs, itemText, moveItemSection, upsertPlanLine } from '../backlog/backlog.js';
import {
  createRun, syncRunLog, currentSprintNum, sprintDir,
  sprintStatus, setSprintStatus, sprintIteration, setSprintIteration,
  setCurrentSprintNum, countSprintsInBacklog, currentRunId,
} from './run.js';
import { logInfo, logOk, logWarn, logErr, logStep, stripAnsi } from '../core/logger.js';
import { t } from '../core/i18n.js';

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

// ── cmd: backlog ──────────────────────────────────────────────────────────────
export function cmdBacklog(config) {
  const backlogPath = config.BACKLOG_FILE;
  if (!existsSync(backlogPath)) {
    logWarn(t('ERR_NO_BACKLOG'));
    return;
  }
  const data = readBacklog(backlogPath);
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
export async function cmdStart({ slug, config, harnDir, scriptDir, onLog }) {
  const backlogPath = config.BACKLOG_FILE;
  if (!existsSync(backlogPath)) throw new Error(t('ERR_NO_BACKLOG'));

  // Pick slug
  if (!slug) {
    const slugs = pendingSlugs(backlogPath);
    if (slugs.length === 0) throw new Error(t('BACKLOG_EMPTY'));
    slug = slugs[0];
  }

  logStep(`Starting: ${slug}`);

  // Create run
  const { id, runDir } = createRun(harnDir);
  const logFile = syncRunLog(harnDir, runDir);
  writeFileSync(join(runDir, 'prompt.txt'), slug);

  // Move to In Progress
  moveItemSection(backlogPath, slug, 'Pending', 'In Progress');

  // Plan
  await cmdPlan({ slug, runDir, config, harnDir, scriptDir, onLog, logFile });

  return { runDir, id, slug };
}

// ── cmd: plan ─────────────────────────────────────────────────────────────────
export async function cmdPlan({ slug, runDir, config, harnDir, scriptDir, onLog, logFile }) {
  logStep(t('PLAN_START'));
  const backlogPath = config.BACKLOG_FILE;
  const item = slug || readFileSync(join(runDir, 'prompt.txt'), 'utf-8').trim();
  const itemDesc = itemText(backlogPath, item);
  const sprintCount = config.SPRINT_COUNT || '1';

  // Read planner prompt template
  const lang = config.HARN_LANG || 'en';
  let promptsDir = join(scriptDir, 'prompts', lang);
  if (config.CUSTOM_PROMPTS_DIR && existsSync(join(config.CUSTOM_PROMPTS_DIR, 'planner.md'))) {
    promptsDir = config.CUSTOM_PROMPTS_DIR;
  }
  const plannerTemplate = existsSync(join(promptsDir, 'planner.md'))
    ? readFileSync(join(promptsDir, 'planner.md'), 'utf-8')
    : '';

  const prompt = [
    plannerTemplate,
    `\n\n## Backlog Item\n\n**${item}**\n${itemDesc}`,
    `\n\nTarget sprint count: ${sprintCount}`,
    '\n\nOutput your result using the exact section markers:\n=== plan.text ===\n=== spec.md ===\n=== sprint-backlog.md ===',
  ].join('');

  const output = await invokeRole({
    role: 'planner', roleDetail: 'planner',
    prompt, runDir, harnDir, scriptDir, config, onLog,
  });

  // Parse sections
  const planText = extractSection(output, 'plan.text');
  const specMd = extractSection(output, 'spec.md');
  const sprintBacklog = extractSection(output, 'sprint-backlog.md');

  writeFileSync(join(runDir, 'plan.txt'), planText);
  writeFileSync(join(runDir, 'spec.md'), specMd);
  writeFileSync(join(runDir, 'sprint-backlog.md'), sprintBacklog);

  // Update plan line in backlog
  if (planText) upsertPlanLine(config.BACKLOG_FILE, item, planText);

  // Set sprint count
  const numSprints = countSprintsInBacklog(sprintBacklog) || 1;
  writeFileSync(join(runDir, 'sprint_count'), String(numSprints));
  setCurrentSprintNum(runDir, 1);

  logOk(t('PLAN_DONE'));
  return { planText, specMd, sprintBacklog };
}

// ── cmd: contract ─────────────────────────────────────────────────────────────
export async function cmdContract({ runDir, sprintNum, config, harnDir, scriptDir, onLog }) {
  logStep(t('CONTRACT_START'));
  const sDir = sprintDir(runDir, sprintNum);

  const spec = existsSync(join(runDir, 'spec.md'))
    ? readFileSync(join(runDir, 'spec.md'), 'utf-8') : '';
  const sb = existsSync(join(runDir, 'sprint-backlog.md'))
    ? readFileSync(join(runDir, 'sprint-backlog.md'), 'utf-8') : '';

  // Generator proposes contract
  const lang = config.HARN_LANG || 'en';
  let promptsDir = join(scriptDir, 'prompts', lang);
  if (config.CUSTOM_PROMPTS_DIR) promptsDir = config.CUSTOM_PROMPTS_DIR;

  const genTemplate = existsSync(join(promptsDir, 'generator.md'))
    ? readFileSync(join(promptsDir, 'generator.md'), 'utf-8') : '';

  const genPrompt = [
    genTemplate,
    `\n\n## Product Spec\n\n${spec}`,
    `\n\n## Sprint Backlog\n\n${sb}`,
    `\n\nYou are working on Sprint ${sprintNum}. Propose a contract (scope definition) for this sprint.`,
  ].join('');

  let contractContent = await invokeRole({
    role: 'generator', roleDetail: 'generator_contract',
    prompt: genPrompt, runDir, harnDir, scriptDir, config, onLog,
  });

  // Evaluator reviews contract
  const evalTemplate = existsSync(join(promptsDir, 'evaluator.md'))
    ? readFileSync(join(promptsDir, 'evaluator.md'), 'utf-8') : '';

  for (let round = 0; round < 3; round++) {
    const evalPrompt = [
      evalTemplate,
      `\n\n## Proposed Contract\n\n${contractContent}`,
      `\n\n## Sprint Backlog\n\n${sb}`,
      '\n\nReview this contract. Respond with APPROVED or NEEDS_REVISION on its own line.',
    ].join('');

    const evalOutput = await invokeRole({
      role: 'evaluator', roleDetail: 'evaluator_contract',
      prompt: evalPrompt, runDir, harnDir, scriptDir, config, onLog,
    });

    if (/APPROVED/i.test(evalOutput)) {
      logOk(t('CONTRACT_APPROVED'));
      break;
    }
    logWarn(t('CONTRACT_REVISION'));
    if (round < 2) {
      contractContent = await invokeRole({
        role: 'generator', roleDetail: 'generator_contract',
        prompt: genPrompt + `\n\n## Revision Feedback\n\n${evalOutput}`,
        runDir, harnDir, scriptDir, config, onLog,
      });
    }
  }

  writeFileSync(join(sDir, 'contract.md'), contractContent);
  setSprintStatus(runDir, sprintNum, 'in-progress');
  return contractContent;
}

// ── cmd: implement ────────────────────────────────────────────────────────────
export async function cmdImplement({ runDir, sprintNum, config, harnDir, scriptDir, onLog }) {
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
  let promptsDir = join(scriptDir, 'prompts', lang);
  if (config.CUSTOM_PROMPTS_DIR) promptsDir = config.CUSTOM_PROMPTS_DIR;

  const genTemplate = existsSync(join(promptsDir, 'generator.md'))
    ? readFileSync(join(promptsDir, 'generator.md'), 'utf-8') : '';

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

  const output = await invokeRole({
    role: 'generator', roleDetail: 'generator_impl',
    prompt, runDir, harnDir, scriptDir, config, onLog,
  });

  writeFileSync(join(sDir, 'implementation.md'), output);
  logOk(t('IMPL_DONE'));
  return output;
}

// ── cmd: evaluate ─────────────────────────────────────────────────────────────
export async function cmdEvaluate({ runDir, sprintNum, config, harnDir, scriptDir, rootDir, onLog }) {
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
  let promptsDir = join(scriptDir, 'prompts', lang);
  if (config.CUSTOM_PROMPTS_DIR) promptsDir = config.CUSTOM_PROMPTS_DIR;

  const evalTemplate = existsSync(join(promptsDir, 'evaluator.md'))
    ? readFileSync(join(promptsDir, 'evaluator.md'), 'utf-8') : '';

  const prompt = [
    evalTemplate,
    `\n\n## Sprint Contract\n\n${contract}`,
    `\n\n## Implementation Summary\n\n${impl}`,
    testResults ? `\n\n## Automated Test Results\n${testResults}` : '',
    '\n\nEvaluate the implementation. End with exactly VERDICT: PASS or VERDICT: FAIL on its own line.',
  ].join('');

  const output = await invokeRole({
    role: 'evaluator', roleDetail: 'evaluator_qa',
    prompt, runDir, harnDir, scriptDir, config, onLog,
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
    if (slug) moveItemSection(config.BACKLOG_FILE, slug, 'In Progress', 'Done');

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
