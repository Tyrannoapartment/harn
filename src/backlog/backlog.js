// src/backlog/backlog.js — Backlog file operations
// Replaces lib/backlog.sh

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

// ── Constants ────────────────────────────────────────────────────────────────

const DEFAULT_BACKLOG = `# Sprint Backlog

## Pending
<!-- Add backlog items below. Format:
- [ ] **slug-name**
  Brief description of the feature or task.
-->

## In Progress

## Done
`;

const SLUG_RE = /^- \[[ x]\] \*\*([^*]+)\*\*/;
const UNCHECKED_SLUG_RE = /^- \[ \] \*\*([^*]+)\*\*/;
const SECTION_RE = /^## /;
const PLAN_LINE_RE = /^\s+plan:\s*/;

// ── Internal helpers ─────────────────────────────────────────────────────────

/**
 * Parse a backlog markdown file into sections.
 * Each section: { name, startLine, endLine, items }
 * Each item: { slug, description, plan, checked, startLine, endLine }
 */
function parseSections(content) {
  const lines = content.split('\n');
  const sections = [];
  let current = null;

  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('## ')) {
      if (current) {
        current.endLine = i;
        current.items = parseItems(lines, current.startLine + 1, current.endLine);
      }
      current = { name: lines[i].slice(3).trim(), startLine: i, endLine: lines.length, items: [] };
      sections.push(current);
    }
  }

  if (current) {
    current.endLine = lines.length;
    current.items = parseItems(lines, current.startLine + 1, current.endLine);
  }

  return { sections, lines };
}

function parseItems(lines, start, end) {
  const items = [];
  let i = start;

  while (i < end) {
    const match = SLUG_RE.exec(lines[i]);
    if (match) {
      const slug = match[1];
      const checked = lines[i].startsWith('- [x]');
      const itemStart = i;
      let description = '';
      let plan = '';

      let j = i + 1;
      while (j < end && !lines[j].startsWith('- [') && !lines[j].startsWith('## ')) {
        const trimmed = lines[j].trim();
        if (PLAN_LINE_RE.test(lines[j])) {
          plan = trimmed.replace(/^plan:\s*/, '');
        } else if (trimmed) {
          description += (description ? '\n' : '') + trimmed;
        }
        j++;
      }

      items.push({ slug, description, plan, checked, startLine: itemStart, endLine: j });
      i = j;
    } else {
      i++;
    }
  }

  return items;
}

function findSectionByName(sections, name) {
  const lower = name.toLowerCase();
  return sections.find(s => s.name.toLowerCase() === lower) || null;
}

// ── Exported functions ───────────────────────────────────────────────────────

/**
 * Parse backlog markdown into structured data.
 * @param {string} backlogPath
 * @returns {{ pending: Array, in_progress: Array, done: Array }}
 */
export function readBacklog(backlogPath) {
  if (!existsSync(backlogPath)) {
    return { pending: [], in_progress: [], done: [] };
  }

  const content = readFileSync(backlogPath, 'utf8');
  const { sections } = parseSections(content);

  const result = { pending: [], in_progress: [], done: [] };

  for (const section of sections) {
    const key = section.name.toLowerCase();
    if (key === 'pending') {
      result.pending = section.items.map(i => ({
        slug: i.slug, description: i.description, plan: i.plan, checked: i.checked,
      }));
    } else if (key === 'in progress') {
      result.in_progress = section.items.map(i => ({
        slug: i.slug, description: i.description, plan: i.plan, checked: i.checked,
      }));
    } else if (key === 'done') {
      result.done = section.items.map(i => ({
        slug: i.slug, description: i.description, plan: i.plan, checked: i.checked,
      }));
    }
  }

  return result;
}

/**
 * Return slugs of uncompleted items (in-progress first, then pending).
 * @param {string} backlogPath
 * @returns {string[]}
 */
export function pendingSlugs(backlogPath) {
  if (!existsSync(backlogPath)) return [];

  const content = readFileSync(backlogPath, 'utf8');
  const rawSections = content.split(/^## /m);

  const inProgress = [];
  const pending = [];

  for (const section of rawSections) {
    const firstLine = section.split('\n', 1)[0].trim().toLowerCase();
    const matches = [...section.matchAll(/- \[ \] \*\*([^*]+)\*\*/g)];
    const slugs = matches.map(m => m[1]);

    if (firstLine.includes('in progress')) {
      inProgress.push(...slugs);
    } else if (firstLine === 'pending') {
      pending.push(...slugs);
    }
  }

  return [...inProgress, ...pending];
}

/**
 * Get full description block for a slug.
 * @param {string} backlogPath
 * @param {string} slug
 * @returns {string}
 */
export function itemText(backlogPath, slug) {
  if (!existsSync(backlogPath)) return '(backlog not found)';

  const content = readFileSync(backlogPath, 'utf8');
  const escaped = slug.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const pattern = new RegExp(
    `(- \\[[ x]\\] \\*\\*${escaped}\\*\\*[^\\n]*\\n(?:[ \\t]+[^\\n]*\\n)*)`,
    'm'
  );

  const match = content.match(pattern);
  if (match) return match[1].trim();
  return `(item "${slug}" not found in backlog)`;
}

/**
 * Get the first pending item slug.
 * @param {string} backlogPath
 * @returns {string|null}
 */
export function nextSlug(backlogPath) {
  const slugs = pendingSlugs(backlogPath);
  return slugs.length > 0 ? slugs[0] : null;
}

/**
 * Mark a backlog item as done: change [ ] to [x].
 * @param {string} backlogPath
 * @param {string} slug
 * @returns {boolean} true if changed
 */
export function markDone(backlogPath, slug) {
  if (!existsSync(backlogPath)) return false;

  const content = readFileSync(backlogPath, 'utf8');
  const escaped = slug.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const pattern = new RegExp(`- \\[ \\] \\*\\*${escaped}\\*\\*`);

  if (!pattern.test(content)) return false;

  const updated = content.replace(pattern, `- [x] **${slug}**`);
  writeFileSync(backlogPath, updated, 'utf8');
  return true;
}

/**
 * Move an item between sections (Pending / In Progress / Done).
 * Optionally marks the item as done.
 *
 * @param {string} backlogPath
 * @param {string} slug
 * @param {string} fromSection - not used for locating (searches all), kept for API compat
 * @param {string} toSection - target section name (e.g. 'In Progress', 'Done')
 * @param {object} [opts]
 * @param {boolean} [opts.markDone=false] - change [ ] to [x] when moving
 * @returns {'MOVED'|'NOT_FOUND'|'ERROR'}
 */
export function moveItemSection(backlogPath, slug, fromSection, toSection, opts = {}) {
  if (!existsSync(backlogPath)) return 'ERROR';

  const content = readFileSync(backlogPath, 'utf8');
  const lines = content.split('\n');
  const escapedSlug = slug.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const slugPattern = new RegExp(`^- \\[[ x]\\] \\*\\*${escapedSlug}\\*\\*`);

  // Parse sections
  const sections = [];
  let currentName = null;
  let currentStart = null;

  for (let idx = 0; idx < lines.length; idx++) {
    if (lines[idx].startsWith('## ')) {
      if (currentName !== null) {
        sections.push({ name: currentName, start: currentStart, end: idx });
      }
      currentName = lines[idx].slice(3).trim();
      currentStart = idx;
    }
  }
  if (currentName !== null) {
    sections.push({ name: currentName, start: currentStart, end: lines.length });
  }

  // Find the item across all sections
  let itemStart = null;
  let itemEnd = null;

  for (const sec of sections) {
    for (let i = sec.start + 1; i < sec.end; i++) {
      if (slugPattern.test(lines[i])) {
        itemStart = i;
        let j = i + 1;
        while (j < sec.end && !lines[j].startsWith('- [') && !lines[j].startsWith('## ')) {
          j++;
        }
        itemEnd = j;
        break;
      }
    }
    if (itemStart !== null) break;
  }

  if (itemStart === null) return 'NOT_FOUND';

  // Extract item lines
  const itemLines = lines.slice(itemStart, itemEnd);

  // Optionally mark done
  if (opts.markDone) {
    itemLines[0] = itemLines[0].replace(/^- \[ \]/, '- [x]');
  }

  // Remove item from current position
  lines.splice(itemStart, itemEnd - itemStart);

  // Find target section (re-scan after removal)
  let targetIndex = null;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('## ') && lines[i].slice(3).trim().toLowerCase() === toSection.toLowerCase()) {
      targetIndex = i + 1;
      break;
    }
  }

  // Create target section if it doesn't exist
  if (targetIndex === null) {
    if (lines.length > 0 && lines[lines.length - 1] !== '') {
      lines.push('');
    }
    lines.push(`## ${toSection}`);
    targetIndex = lines.length;
  }

  // Insert item block
  const insertBlock = [...itemLines];
  if (targetIndex < lines.length && lines[targetIndex] !== '') {
    insertBlock.push('');
  }
  lines.splice(targetIndex, 0, ...insertBlock);

  // Preserve trailing newline
  let newContent = lines.join('\n');
  if (content.endsWith('\n') && !newContent.endsWith('\n')) {
    newContent += '\n';
  }

  writeFileSync(backlogPath, newContent, 'utf8');
  return 'MOVED';
}

/**
 * Add or update the `plan:` line for a backlog item.
 * Prioritizes items in the "In Progress" section if duplicates exist.
 *
 * @param {string} backlogPath
 * @param {string} slug
 * @param {string} planText
 * @returns {'UPDATED'|'UNCHANGED'|'NOT_FOUND'}
 */
export function upsertPlanLine(backlogPath, slug, planText) {
  if (!existsSync(backlogPath)) return 'NOT_FOUND';

  const content = readFileSync(backlogPath, 'utf8');
  const lines = content.split('\n');
  const escapedSlug = slug.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const slugPattern = new RegExp(`^- \\[[ x]\\] \\*\\*${escapedSlug}\\*\\*`);

  const trimmedPlan = planText.trim();

  // Find all candidate items with their section context
  const candidates = [];
  let currentSection = '';
  let i = 0;

  while (i < lines.length) {
    if (lines[i].startsWith('## ')) {
      currentSection = lines[i].slice(3).trim().toLowerCase();
      i++;
      continue;
    }

    if (slugPattern.test(lines[i])) {
      const start = i;
      let j = i + 1;
      while (j < lines.length) {
        if (lines[j].startsWith('## ') || lines[j].startsWith('- [')) break;
        j++;
      }
      candidates.push({ section: currentSection, start, end: j });
      i = j;
      continue;
    }

    i++;
  }

  if (candidates.length === 0) return 'NOT_FOUND';

  // Prefer "in progress" section
  let target = candidates.find(c => c.section.includes('in progress'));
  if (!target) target = candidates[0];

  const { start, end } = target;
  const itemLines = lines.slice(start, end);
  const newPlanLine = `  plan: ${trimmedPlan}`;

  // Find existing plan line
  let planIdx = null;
  for (let k = 1; k < itemLines.length; k++) {
    if (PLAN_LINE_RE.test(itemLines[k])) {
      planIdx = k;
      break;
    }
  }

  let changed = false;

  if (planIdx !== null) {
    if (itemLines[planIdx] !== newPlanLine) {
      itemLines[planIdx] = newPlanLine;
      changed = true;
    }
  } else {
    itemLines.splice(1, 0, newPlanLine);
    changed = true;
  }

  if (!changed) return 'UNCHANGED';

  // Replace in original lines
  lines.splice(start, end - start, ...itemLines);

  let newContent = lines.join('\n');
  if (content.endsWith('\n') && !newContent.endsWith('\n')) {
    newContent += '\n';
  }

  writeFileSync(backlogPath, newContent, 'utf8');
  return 'UPDATED';
}

/**
 * Add a new item to the Pending section.
 * @param {string} backlogPath
 * @param {string} slug
 * @param {string} description
 * @returns {boolean} true if added
 */
export function addItem(backlogPath, slug, description) {
  ensureBacklogFile(backlogPath);

  const content = readFileSync(backlogPath, 'utf8');
  const lines = content.split('\n');

  // Find the Pending section
  let pendingIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('## ') && lines[i].slice(3).trim().toLowerCase() === 'pending') {
      pendingIdx = i;
      break;
    }
  }

  if (pendingIdx === -1) {
    // Append a Pending section
    lines.push('', '## Pending');
    pendingIdx = lines.length - 1;
  }

  // Find insertion point: after section header and any existing items
  let insertIdx = pendingIdx + 1;
  while (insertIdx < lines.length && !lines[insertIdx].startsWith('## ')) {
    insertIdx++;
  }

  // Build item block
  const itemLines = [`- [ ] **${slug}**`];
  if (description) {
    for (const line of description.split('\n')) {
      itemLines.push(`  ${line.trim()}`);
    }
  }

  lines.splice(insertIdx, 0, ...itemLines);

  let newContent = lines.join('\n');
  if (content.endsWith('\n') && !newContent.endsWith('\n')) {
    newContent += '\n';
  }

  writeFileSync(backlogPath, newContent, 'utf8');
  return true;
}

/**
 * Update an existing backlog item.
 * @param {string} backlogPath
 * @param {string} slug
 * @param {object} updates
 * @param {string} [updates.newSlug] - rename the slug
 * @param {string} [updates.description] - replace description
 * @param {string} [updates.plan] - update plan line
 * @returns {boolean} true if found and updated
 */
export function updateItem(backlogPath, slug, { newSlug, description, plan } = {}) {
  if (!existsSync(backlogPath)) return false;

  const content = readFileSync(backlogPath, 'utf8');
  const lines = content.split('\n');
  const escapedSlug = slug.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const slugPattern = new RegExp(`^- \\[[ x]\\] \\*\\*${escapedSlug}\\*\\*`);

  // Find the item
  let itemStart = -1;
  let itemEnd = -1;

  for (let i = 0; i < lines.length; i++) {
    if (slugPattern.test(lines[i])) {
      itemStart = i;
      let j = i + 1;
      while (j < lines.length && !lines[j].startsWith('- [') && !lines[j].startsWith('## ')) {
        j++;
      }
      itemEnd = j;
      break;
    }
  }

  if (itemStart === -1) return false;

  // Rebuild item lines
  const checked = lines[itemStart].startsWith('- [x]');
  const checkbox = checked ? '- [x]' : '- [ ]';
  const finalSlug = newSlug || slug;

  const newItemLines = [`${checkbox} **${finalSlug}**`];
  if (description !== undefined) {
    for (const line of description.split('\n')) {
      if (line.trim()) newItemLines.push(`  ${line.trim()}`);
    }
  } else {
    // Keep existing description lines (skip plan lines)
    for (let k = itemStart + 1; k < itemEnd; k++) {
      if (!PLAN_LINE_RE.test(lines[k])) {
        newItemLines.push(lines[k]);
      }
    }
  }

  if (plan !== undefined) {
    newItemLines.push(`  plan: ${plan.trim()}`);
  } else {
    // Keep existing plan line if not overriding
    for (let k = itemStart + 1; k < itemEnd; k++) {
      if (PLAN_LINE_RE.test(lines[k])) {
        newItemLines.push(lines[k]);
        break;
      }
    }
  }

  lines.splice(itemStart, itemEnd - itemStart, ...newItemLines);

  let newContent = lines.join('\n');
  if (content.endsWith('\n') && !newContent.endsWith('\n')) {
    newContent += '\n';
  }

  writeFileSync(backlogPath, newContent, 'utf8');
  return true;
}

/**
 * Create default backlog file if it doesn't exist.
 * @param {string} backlogPath
 * @returns {boolean} true if created, false if already exists
 */
export function ensureBacklogFile(backlogPath) {
  if (existsSync(backlogPath)) return false;
  mkdirSync(dirname(backlogPath), { recursive: true });
  writeFileSync(backlogPath, DEFAULT_BACKLOG, 'utf8');
  return true;
}
