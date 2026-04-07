/**
 * Scope-based commands: plan, contract, implement, evaluate, next, stop, clear.
 * Redesigned file exchange structure:
 *   plan/scope-{N}.md   — planner output per scope
 *   sprints/scope-{N}/  — contract.md, implementation.md, qa-report.md, status, iteration
 *   retro/              — per-agent retrospectives
 *   run_report.md       — progressive report updated after each scope
 */

import { readFileSync, writeFileSync, existsSync, rmSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { execSync } from 'node:child_process';
import { invokeRole, invokeWithStreaming } from '../ai/invoke.js';
import { readBacklog, pendingSlugs, itemText, moveItemSection, upsertPlanLine, ensureBacklogDir } from '../backlog/backlog.js';
import {
  createRun, syncRunLog, currentScopeNum, scopeDir,
  scopeStatus, setScopeStatus, scopeIteration, setScopeIteration,
  setCurrentScopeNum, scopeCount, currentRunId,
  ensurePlanDir, writeScopePlan, readScopePlan,
  appendRunReport, writeFinalReport,
} from './run.js';
import { logInfo, logOk, logWarn, logErr, logStep, stripAnsi } from '../core/logger.js';
import { t } from '../core/i18n.js';
import { getBacklogDir } from '../core/config.js';

// ── Prompt resolution ─────────────────────────────────────────────────────────

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
  const nextMarker = output.indexOf('\n===', start);
  const end = nextMarker === -1 ? output.length : nextMarker;
  return output.slice(start, end).trim();
}

/**
 * Invoke an agent role with optional real-time streaming.
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
  const bd = getBacklogDir(rootDir);
  ensureBacklogDir(bd);
  const data = readBacklog(bd);
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
  const bd = getBacklogDir(rootDir);
  ensureBacklogDir(bd);

  if (!slug) {
    const slugs = pendingSlugs(bd);
    if (slugs.length === 0) throw new Error(t('BACKLOG_EMPTY'));
    slug = slugs[0];
  }

  logStep(`Starting: ${slug}`);

  const { id, runDir } = createRun(harnDir);
  const logFile = syncRunLog(harnDir, runDir);
  writeFileSync(join(runDir, 'prompt.txt'), slug);

  moveItemSection(bd, slug, 'Pending', 'In Progress');

  await cmdPlan({ slug, runDir, config, harnDir, rootDir, scriptDir, onLog, onData, onResult, logFile });

  return { runDir, id, slug };
}

// ── cmd: plan ─────────────────────────────────────────────────────────────────
/**
 * Planner writes:
 *   - plan.txt (one-line summary)
 *   - spec.md (product spec)
 *   - plan/scope-{N}.md (detailed scope plans)
 *   - scope_count
 *   - current_scope = 1
 */
export async function cmdPlan({ slug, runDir, config, harnDir, rootDir, scriptDir, onLog, onData, onResult, logFile }) {
  logStep(t('PLAN_START'));
  const bd = getBacklogDir(rootDir);
  const item = slug || readFileSync(join(runDir, 'prompt.txt'), 'utf-8').trim();
  const itemDesc = itemText(bd, item);

  const plannerTemplate = loadPrompt('planner', harnDir, scriptDir);

  const prompt = [
    plannerTemplate,
    `\n\n## Backlog Item\n\n**${item}**\n${itemDesc}`,
    '\n\nAnalyze this backlog item and create a detailed implementation plan.',
    'Break the work into logical scopes. Each scope should be a coherent, independently verifiable unit of work.',
    '',
    'Output your result using the exact section markers:',
    '=== plan.text ===',
    '(one-line plan summary)',
    '=== spec.md ===',
    '(detailed product specification)',
    '=== scope-1 ===',
    '(detailed scope 1 plan with requirements, affected files, acceptance criteria)',
    '=== scope-2 ===',
    '(detailed scope 2 plan — add more scopes as needed)',
  ].join('\n');

  const { output, backend, model } = await invokeRoleStreaming({
    role: 'planner', roleDetail: 'planner',
    prompt, runDir, harnDir, scriptDir, config, onLog, onData,
  });

  // Parse sections
  let planText = extractSection(output, 'plan.text');
  let specMd = extractSection(output, 'spec.md');

  // Extract scope sections
  const scopePlans = [];
  for (let i = 1; i <= 20; i++) {
    const scopeContent = extractSection(output, `scope-${i}`);
    if (!scopeContent) break;
    scopePlans.push(scopeContent);
  }

  // Fallback: if no scope markers found, try legacy ## Sprint format
  if (scopePlans.length === 0) {
    const sprintPlan = extractSection(output, 'sprint-plan.md');
    if (sprintPlan) {
      // Split by ## Sprint N headers
      const parts = sprintPlan.split(/(?=^## Sprint \d+)/m).filter(s => s.trim());
      for (const part of parts) {
        scopePlans.push(part.trim());
      }
    }
  }

  // If still no sections, treat full output as single scope
  if (!planText && !specMd && scopePlans.length === 0 && output.trim()) {
    logWarn('Planner output missing section markers — using raw output as single scope');
    specMd = output.trim();
    scopePlans.push(output.trim());
  }

  // Ensure at least one scope
  if (scopePlans.length === 0) {
    scopePlans.push(specMd || planText || 'Implementation scope');
  }

  // Write files
  writeFileSync(join(runDir, 'plan.txt'), planText || '');
  writeFileSync(join(runDir, 'spec.md'), specMd || '');
  writeFileSync(join(runDir, 'scope_count'), String(scopePlans.length));
  setCurrentScopeNum(runDir, 1);

  // Write individual scope plans
  ensurePlanDir(runDir);
  for (let i = 0; i < scopePlans.length; i++) {
    writeScopePlan(runDir, i + 1, scopePlans[i]);
  }

  // Update plan line in backlog
  if (planText) upsertPlanLine(bd, item, planText);

  // Initialize run_report.md with header
  const reportHeader = [
    `# Run Report: ${item}`,
    '',
    `**Plan:** ${planText || '(no summary)'}`,
    `**Scopes:** ${scopePlans.length}`,
    `**Started:** ${new Date().toISOString()}`,
    '',
    '---',
  ].join('\n');
  writeFileSync(join(runDir, 'run_report.md'), reportHeader);

  // Broadcast result — send file list instead of full content
  if (onResult) {
    const files = [];
    if (specMd) files.push({ name: 'spec.md', path: join(runDir, 'spec.md'), content: specMd });
    for (let i = 0; i < scopePlans.length; i++) {
      files.push({ name: `plan/scope-${i + 1}.md`, path: join(runDir, 'plan', `scope-${i + 1}.md`), content: scopePlans[i] });
    }
    files.push({ name: 'run_report.md', path: join(runDir, 'run_report.md'), content: reportHeader });
    const summary = `${scopePlans.length} scope${scopePlans.length > 1 ? 's' : ''} planned${planText ? ` — ${planText}` : ''}`;
    onResult(summary, { phase: 'plan', role: 'planner', backend, model, files });
  }

  if (onLog) onLog(`Plan generated — ${scopePlans.length} scope${scopePlans.length > 1 ? 's' : ''} planned`);
  logOk(`${t('PLAN_DONE')} — ${scopePlans.length} scope${scopePlans.length > 1 ? 's' : ''} planned`);
  return { planText, specMd, scopePlans };
}

// ── cmd: design ───────────────────────────────────────────────────────────────
/**
 * Designer creates design spec for scopes that need UI/UX work.
 * Uses Figma MCP tools if available.
 * Writes: sprints/scope-{N}/design.md
 * Design output is injected into Generator's contract and implementation prompts.
 */
export async function cmdDesign({ runDir, scopeNum, config, harnDir, scriptDir, onLog, onData, onResult }) {
  logStep('Design phase — creating design specification');
  const sDir = scopeDir(runDir, scopeNum);

  const spec = existsSync(join(runDir, 'spec.md'))
    ? readFileSync(join(runDir, 'spec.md'), 'utf-8') : '';
  const scopePlan = readScopePlan(runDir, scopeNum);

  const designerTemplate = loadPrompt('designer', harnDir, scriptDir);

  const prompt = [
    designerTemplate,
    `\n\n## Product Spec\n\n${spec}`,
    `\n\n## Scope ${scopeNum} Plan\n\n${scopePlan}`,
    `\n\nYou are working on Scope ${scopeNum}. Create a detailed design specification for this scope.`,
    'Use Figma MCP tools if available to reference existing designs and design system tokens.',
    'Output your design spec inside the `=== design.md ===` section marker.',
  ].join('\n');

  const { output, backend, model } = await invokeRoleStreaming({
    role: 'designer', roleDetail: 'designer',
    prompt, runDir, harnDir, scriptDir, config, onLog, onData,
  });

  // Parse design output
  let designContent = extractSection(output, 'design.md');
  if (!designContent && output.trim()) {
    designContent = output.trim();
  }

  // Write design spec
  writeFileSync(join(sDir, 'design.md'), designContent);

  // Broadcast result
  if (onResult) {
    onResult(`Scope ${scopeNum} design specification created`, {
      phase: 'design', role: 'designer', backend, model,
      files: [{ name: `sprints/scope-${scopeNum}/design.md`, path: join(sDir, 'design.md'), content: designContent }],
    });
  }

  if (onLog) onLog(`Design spec created for scope ${scopeNum}`);
  logOk(`Design spec created for scope ${scopeNum}`);
  return designContent;
}

// ── cmd: contract ─────────────────────────────────────────────────────────────
/**
 * Generator proposes contract → Evaluator reviews.
 * On NEEDS_REVISION: Generator creates entirely new contract (not revision).
 * Writes: sprints/scope-{N}/contract.md
 */
export async function cmdContract({ runDir, scopeNum, config, harnDir, scriptDir, onLog, onData, onResult }) {
  logStep(t('CONTRACT_START'));
  const sDir = scopeDir(runDir, scopeNum);

  const spec = existsSync(join(runDir, 'spec.md'))
    ? readFileSync(join(runDir, 'spec.md'), 'utf-8') : '';
  const scopePlan = readScopePlan(runDir, scopeNum);

  // Load design spec if it exists (from Designer agent)
  const designSpec = existsSync(join(sDir, 'design.md'))
    ? readFileSync(join(sDir, 'design.md'), 'utf-8') : '';

  // Generator proposes contract
  const genTemplate = loadPrompt('generator', harnDir, scriptDir);

  const genPrompt = [
    genTemplate,
    `\n\n## Product Spec\n\n${spec}`,
    `\n\n## Scope ${scopeNum} Plan\n\n${scopePlan}`,
    ...(designSpec ? [`\n\n## Design Specification\n\nThe Designer agent has provided the following design spec. Follow it precisely for all UI/UX implementation.\n\n${designSpec}`] : []),
    `\n\nYou are working on Scope ${scopeNum}. Propose a detailed contract (scope definition) for this scope.`,
    'Include: objectives, deliverables, affected files, acceptance criteria, and any dependencies.',
  ].join('');

  let contractContent = '';

  for (let attempt = 0; attempt < 3; attempt++) {
    const genResult = await invokeRoleStreaming({
      role: 'generator', roleDetail: 'generator_contract',
      prompt: attempt === 0
        ? genPrompt
        : genPrompt + `\n\n## Previous contract was rejected (attempt ${attempt + 1}). Create a new, improved contract from scratch.`,
      runDir, harnDir, scriptDir, config, onLog, onData,
    });
    contractContent = genResult.output;

    if (onResult) {
      onResult(`Scope ${scopeNum} contract proposed (attempt ${attempt + 1})`, {
        phase: 'contract', role: 'generator', backend: genResult.backend, model: genResult.model,
        files: [{ name: `sprints/scope-${scopeNum}/contract.md`, path: join(sDir, 'contract.md'), content: contractContent }],
      });
    }

    // Evaluator reviews contract
    const evalTemplate = loadPrompt('evaluator', harnDir, scriptDir);
    const evalPrompt = [
      evalTemplate,
      `\n\n## Proposed Contract\n\n${contractContent}`,
      `\n\n## Scope Plan\n\n${scopePlan}`,
      '\n\nReview this contract for completeness and correctness.',
      'Respond with APPROVED or NEEDS_REVISION on its own line, followed by your reasoning.',
    ].join('');

    const evalResult = await invokeRoleStreaming({
      role: 'evaluator', roleDetail: 'evaluator_contract',
      prompt: evalPrompt, runDir, harnDir, scriptDir, config, onLog, onData,
    });

    if (onResult) {
      const approved = /APPROVED/i.test(evalResult.output);
      onResult(approved ? 'Contract APPROVED' : 'Contract NEEDS_REVISION', {
        phase: 'contract-review', role: 'evaluator', backend: evalResult.backend, model: evalResult.model,
        files: [{ name: `contract-review-${attempt + 1}.md`, path: '', content: evalResult.output }],
      });
    }

    if (/APPROVED/i.test(evalResult.output)) {
      logOk(t('CONTRACT_APPROVED'));
      break;
    }

    logWarn(`${t('CONTRACT_REVISION')} (attempt ${attempt + 1}/3)`);
    if (attempt >= 2) {
      logWarn('Max contract attempts reached. Proceeding with last proposal.');
    }
  }

  writeFileSync(join(sDir, 'contract.md'), contractContent);
  setScopeStatus(runDir, scopeNum, 'in-progress');
  return contractContent;
}

// ── cmd: implement ────────────────────────────────────────────────────────────
/**
 * Generator implements the contract.
 * Detects SCOPE_EXPANSION_NEEDED marker for out-of-scope work.
 * Writes: sprints/scope-{N}/implementation.md
 */
export async function cmdImplement({ runDir, scopeNum, config, harnDir, scriptDir, onLog, onData, onResult }) {
  logStep(t('IMPL_START'));
  const sDir = scopeDir(runDir, scopeNum);

  const contract = existsSync(join(sDir, 'contract.md'))
    ? readFileSync(join(sDir, 'contract.md'), 'utf-8') : '';
  const spec = existsSync(join(runDir, 'spec.md'))
    ? readFileSync(join(runDir, 'spec.md'), 'utf-8') : '';
  const scopePlan = readScopePlan(runDir, scopeNum);

  // Load design spec if available
  const designSpec = existsSync(join(sDir, 'design.md'))
    ? readFileSync(join(sDir, 'design.md'), 'utf-8') : '';

  const iter = scopeIteration(runDir, scopeNum);
  setScopeIteration(runDir, scopeNum, iter);

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
    `\n\n## Scope ${scopeNum} Plan\n\n${scopePlan}`,
    ...(designSpec ? [`\n\n## Design Specification\n\nThe Designer agent has provided the following design spec. Follow it precisely for all UI/UX implementation.\n\n${designSpec}`] : []),
    `\n\n## Sprint Contract\n\n${contract}`,
    qaContext,
    `\n\nImplement all features defined in the contract. This is iteration ${iter}.`,
    '\n\nIMPORTANT: If during implementation you discover work that is clearly outside the scope of this contract,',
    'STOP and add the marker "SCOPE_EXPANSION_NEEDED" on its own line, followed by a description of the additional work needed.',
    'Only do this for genuinely out-of-scope work, not for normal implementation tasks.',
  ].join('');

  const { output, backend, model } = await invokeRoleStreaming({
    role: 'generator', roleDetail: 'generator_impl',
    prompt, runDir, harnDir, scriptDir, config, onLog, onData,
  });

  writeFileSync(join(sDir, 'implementation.md'), output);

  // Check for scope expansion marker
  const needsExpansion = /^SCOPE_EXPANSION_NEEDED$/m.test(output);
  if (needsExpansion) {
    writeFileSync(join(sDir, 'scope_expansion'), 'true');
    logWarn('Generator flagged SCOPE_EXPANSION_NEEDED — will request evaluator verification.');
  }

  if (onResult) {
    const summary = needsExpansion
      ? `Implementation complete (iteration ${iter}) — SCOPE_EXPANSION_NEEDED`
      : `Implementation complete (iteration ${iter})`;
    onResult(summary, {
      phase: 'implement', role: 'generator', backend, model, iteration: iter,
      files: [{ name: `sprints/scope-${scopeNum}/implementation.md`, path: join(sDir, 'implementation.md'), content: output }],
    });
  }

  logOk(t('IMPL_DONE'));
  return { output, needsExpansion };
}

// ── cmd: evaluate ─────────────────────────────────────────────────────────────
/**
 * Evaluator QA: reviews implementation against contract.
 * Writes: sprints/scope-{N}/qa-report.md
 */
export async function cmdEvaluate({ runDir, scopeNum, config, harnDir, scriptDir, rootDir, onLog, onData, onResult }) {
  logStep(t('EVAL_START'));
  const sDir = scopeDir(runDir, scopeNum);

  const contract = existsSync(join(sDir, 'contract.md'))
    ? readFileSync(join(sDir, 'contract.md'), 'utf-8') : '';
  const impl = existsSync(join(sDir, 'implementation.md'))
    ? readFileSync(join(sDir, 'implementation.md'), 'utf-8') : '';
  const scopePlan = readScopePlan(runDir, scopeNum);

  // Check if scope expansion was flagged
  const hasExpansion = existsSync(join(sDir, 'scope_expansion'));
  let expansionContext = '';
  if (hasExpansion) {
    expansionContext = '\n\n## Scope Expansion Notice\n' +
      'The generator flagged that additional out-of-scope work may be needed. ' +
      'Evaluate whether the current implementation is complete for THIS scope, ' +
      'and note any expansion needs in your report.';
  }

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

  const evalTemplate = loadPrompt('evaluator', harnDir, scriptDir);

  const prompt = [
    evalTemplate,
    `\n\n## Scope ${scopeNum} Plan\n\n${scopePlan}`,
    `\n\n## Sprint Contract\n\n${contract}`,
    `\n\n## Implementation Summary\n\n${impl}`,
    expansionContext,
    testResults ? `\n\n## Automated Test Results\n${testResults}` : '',
    '\n\nEvaluate the implementation against the contract and scope plan.',
    'End with exactly VERDICT: PASS or VERDICT: FAIL on its own line.',
  ].join('');

  const { output, backend, model } = await invokeRoleStreaming({
    role: 'evaluator', roleDetail: 'evaluator_qa',
    prompt, runDir, harnDir, scriptDir, config, onLog, onData,
  });

  writeFileSync(join(sDir, 'qa-report.md'), output);

  // Parse verdict
  const passMatch = /^VERDICT:\s*PASS\s*$/m.test(output);
  let verdict = passMatch ? 'pass' : 'fail';

  // Continuation enforcement: PASS requires actual file changes
  const enforceChanges = config.CONTINUATION_ENFORCEMENT !== 'false';
  if (verdict === 'pass' && rootDir && enforceChanges) {
    try {
      const diff = execSync('git diff --stat', { cwd: rootDir, encoding: 'utf-8' }).trim();
      const diffCached = execSync('git diff --cached --stat', { cwd: rootDir, encoding: 'utf-8' }).trim();
      const untracked = execSync('git ls-files --others --exclude-standard', { cwd: rootDir, encoding: 'utf-8' }).trim();
      if (!diff && !diffCached && !untracked) {
        logWarn('PASS verdict overridden to FAIL — no file changes detected.');
        verdict = 'fail';
      }
    } catch { /* git not available, skip check */ }
  }

  setScopeStatus(runDir, scopeNum, verdict);

  if (onResult) {
    onResult(`QA ${verdict.toUpperCase()}`, {
      phase: 'evaluate', role: 'evaluator', backend, model, verdict,
      files: [{ name: `sprints/scope-${scopeNum}/qa-report.md`, path: join(sDir, 'qa-report.md'), content: output }],
    });
  }

  if (verdict === 'pass') {
    logOk(t('EVAL_PASS'));
  } else {
    logWarn(t('EVAL_FAIL'));
  }

  return { verdict, output, hasExpansion };
}

// ── cmd: next (scope advancement + report writing) ───────────────────────────
/**
 * After scope passes:
 *   1. Planner writes scope result to run_report.md
 *   2. Advance to next scope or finalize
 */
export async function cmdNext({ runDir, scopeNum, config, harnDir, scriptDir, rootDir, onLog, onData, onResult }) {
  const totalFile = join(runDir, 'scope_count');
  const total = existsSync(totalFile)
    ? parseInt(readFileSync(totalFile, 'utf-8').trim(), 10) : 1;

  // Write scope result to run_report.md
  const sDir = scopeDir(runDir, scopeNum);
  const contract = existsSync(join(sDir, 'contract.md'))
    ? readFileSync(join(sDir, 'contract.md'), 'utf-8') : '';
  const impl = existsSync(join(sDir, 'implementation.md'))
    ? readFileSync(join(sDir, 'implementation.md'), 'utf-8') : '';
  const qaReport = existsSync(join(sDir, 'qa-report.md'))
    ? readFileSync(join(sDir, 'qa-report.md'), 'utf-8') : '';
  const status = scopeStatus(runDir, scopeNum);

  const scopeResult = [
    `## Scope ${scopeNum} — ${status.toUpperCase()}`,
    '',
    '### Contract Summary',
    contract.slice(0, 500) + (contract.length > 500 ? '\n...(truncated)' : ''),
    '',
    '### Implementation',
    impl.slice(0, 500) + (impl.length > 500 ? '\n...(truncated)' : ''),
    '',
    '### QA Result',
    qaReport.slice(0, 300) + (qaReport.length > 300 ? '\n...(truncated)' : ''),
  ].join('\n');

  appendRunReport(runDir, scopeResult);

  if (scopeNum >= total) {
    // All scopes complete — write final report
    const slug = existsSync(join(runDir, 'prompt.txt'))
      ? readFileSync(join(runDir, 'prompt.txt'), 'utf-8').trim() : '';

    // Ask planner to write final summary
    const plannerTemplate = loadPrompt('planner', harnDir, scriptDir);
    const spec = existsSync(join(runDir, 'spec.md'))
      ? readFileSync(join(runDir, 'spec.md'), 'utf-8') : '';
    const currentReport = existsSync(join(runDir, 'run_report.md'))
      ? readFileSync(join(runDir, 'run_report.md'), 'utf-8') : '';

    const finalPrompt = [
      plannerTemplate,
      `\n\n## Original Spec\n\n${spec}`,
      `\n\n## Scope Results\n\n${currentReport}`,
      '\n\nAll scopes are complete. Write a comprehensive final summary.',
      'Include: what was accomplished, key decisions made, files changed, and any remaining considerations.',
    ].join('');

    try {
      const { output: finalSummary } = await invokeRoleStreaming({
        role: 'planner', roleDetail: 'planner',
        prompt: finalPrompt, runDir, harnDir, scriptDir, config, onLog, onData,
      });
      writeFinalReport(runDir, `## Final Report\n\n${finalSummary}`);
      if (onResult) {
        const reportContent = existsSync(join(runDir, 'run_report.md'))
          ? readFileSync(join(runDir, 'run_report.md'), 'utf-8') : finalSummary;
        onResult('All scopes complete — final report generated', {
          phase: 'final-report', role: 'planner',
          files: [{ name: 'run_report.md', path: join(runDir, 'run_report.md'), content: reportContent }],
        });
      }
    } catch {
      writeFinalReport(runDir, '## Final Report\n\n(Auto-generated — planner invocation failed)\n\nAll scopes completed.');
    }

    // Move backlog item to Done
    if (slug) {
      moveItemSection(getBacklogDir(rootDir), slug, 'In Progress', 'Done');
    }

    logOk(t('RUN_COMPLETE'));
    return { complete: true };
  }

  // Advance to next scope
  const nextNum = scopeNum + 1;
  setCurrentScopeNum(runDir, nextNum);
  logInfo(`${t('NEXT_DONE')} → Scope ${nextNum}`);
  return { complete: false, nextScope: nextNum };
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
  const targets = ['active_run', 'harn.pid', 'harn.log'];
  for (const t of targets) {
    try { unlinkSync(join(harnDir, t)); } catch { /* ignore */ }
  }
  const runsDir = join(harnDir, 'runs');
  if (existsSync(runsDir)) {
    rmSync(runsDir, { recursive: true, force: true });
  }
  logOk('Cleared run data. Memory, prompts, and config preserved.');
}
