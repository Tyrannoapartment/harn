/**
 * Project memory — cross-session learnings.
 * Replaces lib/memory.sh
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';

const MEMORY_FILE = (harnDir) => join(harnDir, 'memory.md');
const HEADER = '# Project Memory\nAuto-collected learnings from sprint runs.\n';
const MAX_INJECT_CHARS = 3000;

/** Read memory file content. */
export function memoryLoad(harnDir) {
  const file = MEMORY_FILE(harnDir);
  if (!existsSync(file)) return '';
  return readFileSync(file, 'utf-8');
}

/** Format memory for prompt injection (last N chars). */
export function memoryInject(harnDir) {
  const content = memoryLoad(harnDir);
  if (!content.trim()) return '';
  const trimmed = content.length > MAX_INJECT_CHARS
    ? content.slice(-MAX_INJECT_CHARS)
    : content;
  return `\n\n## Project Memory (cross-session learnings)\n\n${trimmed}\n`;
}

/** Append a timestamped entry to memory. */
export function memoryAppend(harnDir, content) {
  const file = MEMORY_FILE(harnDir);
  mkdirSync(dirname(file), { recursive: true });
  const now = new Date();
  const ts = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')} ${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
  let existing = '';
  if (existsSync(file)) {
    existing = readFileSync(file, 'utf-8');
  } else {
    existing = HEADER;
  }
  existing += `\n### ${ts}\n${content.trim()}\n`;
  writeFileSync(file, existing);
}

/** Extract learnings from retrospective output. */
export function memoryExtractFromRetro(harnDir, retroOutput) {
  const marker = '=== retro-summary ===';
  const idx = retroOutput.indexOf(marker);
  if (idx === -1) return;
  const nextMarker = retroOutput.indexOf('\n===', idx + marker.length);
  const end = nextMarker === -1 ? retroOutput.length : nextMarker;
  const summary = retroOutput.slice(idx + marker.length, end).trim();
  if (summary) memoryAppend(harnDir, `[retro] ${summary}`);
}

/** Extract failure patterns from QA report. */
export function memoryExtractFromFailure(harnDir, qaReport) {
  if (!qaReport) return;
  const bugs = qaReport.match(/#### Bugs Found[\s\S]*?(?=####|$)/)?.[0];
  if (bugs) memoryAppend(harnDir, `[failure-pattern] ${bugs.trim().slice(0, 500)}`);
}
