/**
 * Mid-run guidance system.
 * Replaces lib/guidance.sh
 */

import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import readline from 'node:readline';

const INBOX_FILE = (runDir) => join(runDir, 'inbox.md');

/** Start non-blocking guidance listener that reads stdin between steps. */
export function startGuidanceListener(runDir) {
  // In Node.js we handle guidance synchronously between sprint steps
  // via promptForGuidance(). This stub keeps API compatibility.
}

/** Prompt user for inter-step instructions. Returns the text or empty string. */
export async function promptForGuidance(rl) {
  return new Promise((resolve) => {
    process.stdout.write('\n  💬 Additional instructions? (Enter to skip): ');
    rl.once('line', (line) => {
      resolve(line.trim());
    });
  });
}

/** Read and consume the guidance inbox file. */
export function consumeInbox(runDir) {
  const file = INBOX_FILE(runDir);
  if (!existsSync(file)) return '';
  const content = readFileSync(file, 'utf-8').trim();
  writeFileSync(file, '');
  return content;
}

/** Append user guidance to the inbox. */
export function appendToInbox(runDir, text) {
  const file = INBOX_FILE(runDir);
  mkdirSync(join(runDir), { recursive: true });
  let existing = '';
  if (existsSync(file)) existing = readFileSync(file, 'utf-8');
  writeFileSync(file, existing + text + '\n');
}

/** Build guidance context string for prompt injection. */
export function buildGuidanceContext(runDir, extraInstructions) {
  const inbox = consumeInbox(runDir);
  const parts = [];
  if (inbox) parts.push(`User guidance (from inbox):\n${inbox}`);
  if (extraInstructions) parts.push(`User instructions:\n${extraInstructions}`);
  if (parts.length === 0) return '';
  return `\n\n## User Guidance\n\n${parts.join('\n\n')}\n`;
}
