/**
 * Task discovery and backlog item creation.
 * Replaces lib/discover.sh
 */

import { existsSync, readFileSync } from 'node:fs';
import { aiGenerate } from '../ai/backend.js';
import { pendingSlugs, addItem, ensureSprintDir } from '../backlog/backlog.js';
import { logStep, logOk, logInfo } from '../core/logger.js';
import { t } from '../core/i18n.js';
import { getSprintDir } from '../core/config.js';

/** Discover new backlog items by analyzing the codebase with AI. */
export async function cmdDiscover({ config, harnDir, scriptDir, rootDir, onLog }) {
  logStep(t('DISCOVER_START'));

  const sd = getSprintDir(rootDir);
  ensureSprintDir(sd);
  const existing = pendingSlugs(sd);

  const prompt = [
    'You are analyzing a software project to discover work items.',
    `\nExisting backlog items: ${existing.join(', ') || '(none)'}`,
    '\nAnalyze the project and suggest 3–5 new backlog items that are NOT already in the backlog.',
    '\nOutput format (use exact marker):',
    '\n=== new-items ===',
    '- [ ] **slug-name**',
    '  Description (1-2 lines)',
    '',
    'Rules: slug must be hyphenated-lowercase (max 50 chars). Do NOT duplicate existing slugs.',
  ].join('\n');

  const result = await aiGenerate({
    prompt,
    backend: config.AI_BACKEND,
    model: config.MODEL_AUXILIARY || config.COPILOT_MODEL_PLANNER,
    cwd: rootDir,
  });
  const output = result?.output || '';

  // Parse new items
  const marker = '=== new-items ===';
  const idx = output.indexOf(marker);
  if (idx === -1) {
    logInfo('No new items discovered.');
    return [];
  }

  const section = output.slice(idx + marker.length).trim();
  const items = [];
  const itemRe = /^- \[[ x]\] \*\*(.+?)\*\*\s*\n?\s*(.*)/gm;
  let match;
  while ((match = itemRe.exec(section)) !== null) {
    const slug = match[1].trim();
    const desc = match[2]?.trim() || '';
    if (slug && !existing.includes(slug)) {
      items.push({ slug, description: desc });
    }
  }

  // Add to backlog
  for (const item of items) {
    addItem(sd, item.slug, item.description);
    logOk(`Added: ${item.slug}`);
  }

  return items;
}

/** Interactive backlog item creation via AI. */
export async function cmdAdd({ config, harnDir, scriptDir, rootDir }) {
  const inquirer = (await import('inquirer')).default;

  const { description } = await inquirer.prompt([{
    type: 'input', name: 'description',
    message: t('ADD_PROMPT'),
  }]);

  if (!description.trim()) return;

  const prompt = [
    'Generate 1-3 sprint backlog items based on this description:',
    `\n${description}`,
    '\nOutput as JSON array: [{"slug": "kebab-case-slug", "description": "concise description"}]',
    '\nRules: slug must be kebab-case, max 50 chars, no spaces.',
  ].join('\n');

  const addResult = await aiGenerate({
    prompt,
    backend: config.AI_BACKEND,
    model: config.MODEL_AUXILIARY || config.COPILOT_MODEL_PLANNER,
    cwd: rootDir,
  });
  const output = addResult?.output || '';

  // Parse JSON
  const jsonMatch = output.match(/\[[\s\S]*?\]/);
  if (!jsonMatch) {
    console.log('  Could not parse AI output.');
    return;
  }

  let items;
  try {
    items = JSON.parse(jsonMatch[0]);
  } catch {
    console.log('  Invalid JSON from AI.');
    return;
  }

  // Preview
  console.log('\n  Generated items:');
  for (const item of items) {
    console.log(`    - ${item.slug}: ${item.description}`);
  }

  const { confirm } = await inquirer.prompt([{
    type: 'confirm', name: 'confirm', message: 'Add these items?', default: true,
  }]);

  if (!confirm) return;

  const sd = getSprintDir(rootDir);
  ensureSprintDir(sd);
  for (const item of items) {
    addItem(sd, item.slug, item.description);
    logOk(`Added: ${item.slug}`);
  }
}
