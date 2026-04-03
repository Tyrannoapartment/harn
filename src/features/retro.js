/**
 * Retrospective analysis.
 * Writes per-agent retro files: retro/planner.md, retro/generator.md, retro/evaluator.md
 */

import { readFileSync, existsSync, writeFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { invokeRole } from '../ai/invoke.js';
import { logStep, logOk } from '../core/logger.js';
import { t } from '../core/i18n.js';
import { memoryExtractFromRetro, memoryAppend } from './memory.js';
import { ensureRetroDir, writeRetro } from '../run/run.js';

/** Run retrospective analysis on a completed run. */
export async function cmdRetrospective({ runDir, harnDir, config, scriptDir, rootDir }) {
  logStep(t('RETRO_START'));

  // Gather run data
  const spec = readSafe(join(runDir, 'spec.md'));
  const runReport = readSafe(join(runDir, 'run_report.md'));

  // Collect scope plans
  const planDir = join(runDir, 'plan');
  let scopePlans = '';
  if (existsSync(planDir)) {
    for (const f of readdirSync(planDir).filter(f => f.endsWith('.md')).sort()) {
      scopePlans += `### ${f}\n${readSafe(join(planDir, f))}\n\n`;
    }
  }

  // Collect all scope outcomes
  const scopeSummaries = [];
  const sprintsDir = join(runDir, 'sprints');
  if (existsSync(sprintsDir)) {
    for (const sname of readdirSync(sprintsDir).sort()) {
      const sd = join(sprintsDir, sname);
      if (!existsSync(join(sd, 'status'))) continue;
      const status = readSafe(join(sd, 'status'));
      const iteration = readSafe(join(sd, 'iteration'));
      const qa = readSafe(join(sd, 'qa-report.md'));
      scopeSummaries.push(`### ${sname}\nStatus: ${status}\nIterations: ${iteration}\n${qa ? `QA:\n${qa.slice(0, 500)}` : ''}`);
    }
  }

  const promptText = [
    'You are performing a retrospective analysis on a completed run.',
    '\n## Product Spec',
    spec,
    '\n## Scope Plans',
    scopePlans,
    '\n## Scope Outcomes',
    scopeSummaries.join('\n\n'),
    '\n## Run Report',
    runReport,
    '\n---',
    '\nAnalyze the run and provide per-agent retrospectives.',
    '\nUse these exact section markers:',
    '=== retro-summary ===',
    '(overall summary of the run)',
    '=== retro:planner ===',
    '(planner retrospective: how planning went, scope accuracy, improvements)',
    '=== retro:generator ===',
    '(generator retrospective: code quality, contract adherence, scope expansion issues)',
    '=== retro:evaluator ===',
    '(evaluator retrospective: QA effectiveness, false pass/fail rate, improvements)',
    '=== prompt-suggestion:planner ===',
    '(suggestions for planner prompt)',
    '=== prompt-suggestion:generator ===',
    '(suggestions for generator prompt)',
    '=== prompt-suggestion:evaluator ===',
    '(suggestions for evaluator prompt)',
  ].join('\n');

  const { output } = await invokeRole({
    role: 'retrospective',
    prompt: promptText,
    config,
    scriptDir,
    rootDir,
    harnDir,
  });

  // Save full retrospective output
  writeFileSync(join(runDir, 'retrospective.md'), output);

  // Extract and write per-agent retro files
  ensureRetroDir(runDir);
  for (const agent of ['planner', 'generator', 'evaluator']) {
    const content = extractSection(output, `retro:${agent}`);
    if (content) {
      writeRetro(runDir, agent, content);
    }
  }

  logOk(t('RETRO_DONE'));

  // Extract learnings to project memory
  memoryExtractFromRetro(harnDir, output);

  // Extract prompt suggestions
  const suggestions = {};
  for (const role of ['planner', 'generator', 'evaluator']) {
    const content = extractSection(output, `prompt-suggestion:${role}`);
    if (content) suggestions[role] = content;
  }

  return { output, suggestions };
}

function extractSection(output, sectionName) {
  const marker = `=== ${sectionName} ===`;
  const idx = output.indexOf(marker);
  if (idx === -1) return '';
  const start = idx + marker.length;
  const nextMarker = output.indexOf('\n===', start);
  const end = nextMarker === -1 ? output.length : nextMarker;
  return output.slice(start, end).trim();
}

function readSafe(path) {
  try { return readFileSync(path, 'utf-8'); } catch { return ''; }
}
