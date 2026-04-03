/**
 * Retrospective analysis.
 * Replaces lib/retro.sh
 */

import { readFileSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { invokeRole } from '../ai/invoke.js';
import { logStep, logOk } from '../core/logger.js';
import { t } from '../core/i18n.js';
import { memoryExtractFromRetro, memoryAppend } from './memory.js';

/** Run retrospective analysis on a completed run. */
export async function cmdRetrospective({ runDir, harnDir, config, scriptDir, rootDir }) {
  logStep(t('RETRO_START'));

  // Gather sprint data
  const spec = readSafe(join(runDir, 'spec.md'));
  const sprintBacklog = readSafe(join(runDir, 'sprint-backlog.md'));
  const handoff = readSafe(join(runDir, 'handoff.md'));

  // Collect all sprint outcomes
  const sprintSummaries = [];
  let i = 1;
  while (true) {
    const sd = join(runDir, 'sprints', String(i).padStart(3, '0'));
    if (!existsSync(sd)) break;
    const status = readSafe(join(sd, 'status'));
    const iteration = readSafe(join(sd, 'iteration'));
    const qa = readSafe(join(sd, 'qa-report.md'));
    sprintSummaries.push(`### Sprint ${i}\nStatus: ${status}\nIterations: ${iteration}\n${qa ? `QA:\n${qa.slice(0, 500)}` : ''}`);
    i++;
  }

  const promptText = [
    'You are performing a retrospective analysis on a completed sprint run.',
    '\n## Product Spec',
    spec,
    '\n## Sprint Backlog',
    sprintBacklog,
    '\n## Sprint Outcomes',
    sprintSummaries.join('\n\n'),
    '\n## Handoff',
    handoff,
    '\n---',
    '\nAnalyze the run and provide:',
    '1. What went well / what didn\'t',
    '2. Patterns for future improvement',
    '3. Prompt optimization suggestions',
    '\nUse these exact section markers:',
    '=== retro-summary ===',
    '(overall summary of the run)',
    '=== prompt-suggestion:planner ===',
    '(suggestions for planner prompt)',
    '=== prompt-suggestion:generator ===',
    '(suggestions for generator prompt)',
    '=== prompt-suggestion:evaluator ===',
    '(suggestions for evaluator prompt)',
  ].join('\n');

  const { output } = await invokeRole({
    role: 'retrospective',
    promptText,
    config,
    scriptDir,
    rootDir,
    harnDir,
  });

  // Save retrospective output
  writeFileSync(join(runDir, 'retrospective.md'), output);
  logOk(t('RETRO_DONE'));

  // Extract learnings to project memory
  memoryExtractFromRetro(harnDir, output);

  // Extract prompt suggestions
  const suggestions = {};
  for (const role of ['planner', 'generator', 'evaluator']) {
    const marker = `=== prompt-suggestion:${role} ===`;
    const idx = output.indexOf(marker);
    if (idx !== -1) {
      const nextMarker = output.indexOf('\n===', idx + marker.length);
      const end = nextMarker === -1 ? output.length : nextMarker;
      suggestions[role] = output.slice(idx + marker.length, end).trim();
    }
  }

  return { output, suggestions };
}

function readSafe(path) {
  try { return readFileSync(path, 'utf-8'); } catch { return ''; }
}
