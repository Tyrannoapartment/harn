// src/backlog/backlog.js — Per-file backlog storage
//
// Storage layout (.harn/sprint/):
//   pending/<slug>.md        — waiting items
//   in-progress/<slug>.md    — active item(s)
//   done/<slug>.md           — completed items
//
// Each file is a Jira-style markdown ticket:
//   # slug-name
//   ## Summary
//   One-line summary
//   ## Description
//   Detailed description
//   ## Affected Files
//   - path/to/file.ts
//   ## Implementation Guide
//   Step-by-step approach
//   ## Acceptance Criteria
//   - [ ] Criterion 1
//   ## Plan
//   (Planner-appended after planning phase)

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, renameSync, unlinkSync } from 'node:fs';
import { join, basename } from 'node:path';

// ── Directory names ───────────────────────────────────────────────────────────

const SECTIONS = ['pending', 'in-progress', 'done'];

function sectionDir(sprintDir, section) {
  return join(sprintDir, section);
}

// ── Per-file parser ───────────────────────────────────────────────────────────

/**
 * Parse a backlog item markdown file.
 * Extracts known sections while keeping the full raw content.
 */
function parseItemFile(content, slug) {
  const lines = content.split('\n');
  const sectionMap = {};
  let currentSection = null;
  let currentLines = [];

  for (const line of lines) {
    if (/^# /.test(line)) continue; // skip title

    const h2 = line.match(/^## (.+)/);
    if (h2) {
      if (currentSection) sectionMap[currentSection] = currentLines.join('\n').trim();
      currentSection = h2[1].trim().toLowerCase();
      currentLines = [];
      continue;
    }

    if (currentSection) currentLines.push(line);
  }
  if (currentSection) sectionMap[currentSection] = currentLines.join('\n').trim();

  return {
    slug,
    summary:            sectionMap['summary'] || '',
    description:        sectionMap['description'] || '',
    affectedFiles:      sectionMap['affected files'] || '',
    implementationGuide: sectionMap['implementation guide'] || '',
    acceptanceCriteria: sectionMap['acceptance criteria'] || '',
    plan:               sectionMap['plan'] || '',
    raw:                content,
  };
}

/**
 * Serialize a backlog item to markdown.
 */
function serializeItem(item) {
  const lines = [`# ${item.slug}`, ''];

  lines.push('## Summary', '');
  if (item.summary) lines.push(item.summary);
  lines.push('');

  lines.push('## Description', '');
  if (item.description) lines.push(item.description);
  lines.push('');

  lines.push('## Affected Files', '');
  if (item.affectedFiles) lines.push(item.affectedFiles);
  lines.push('');

  lines.push('## Implementation Guide', '');
  if (item.implementationGuide) lines.push(item.implementationGuide);
  lines.push('');

  lines.push('## Acceptance Criteria', '');
  if (item.acceptanceCriteria) lines.push(item.acceptanceCriteria);
  lines.push('');

  lines.push('## Plan', '');
  if (item.plan) lines.push(item.plan);
  lines.push('');

  return lines.join('\n');
}

// ── Low-level helpers ─────────────────────────────────────────────────────────

function listItems(sprintDir, section) {
  const dir = sectionDir(sprintDir, section);
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter(f => f.endsWith('.md'))
    .sort()
    .map(f => {
      const slug = f.replace(/\.md$/, '');
      const content = readFileSync(join(dir, f), 'utf8');
      return parseItemFile(content, slug);
    });
}

function findItem(sprintDir, slug) {
  for (const section of SECTIONS) {
    const filePath = join(sectionDir(sprintDir, section), `${slug}.md`);
    if (existsSync(filePath)) {
      const content = readFileSync(filePath, 'utf8');
      return { ...parseItemFile(content, slug), section, filePath };
    }
  }
  return null;
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Ensure the sprint directory and its section subdirectories exist.
 */
export function ensureSprintDir(sprintDir) {
  for (const section of SECTIONS) {
    mkdirSync(sectionDir(sprintDir, section), { recursive: true });
  }
}

/**
 * Read all backlog items grouped by section.
 */
export function readBacklog(sprintDir) {
  return {
    pending:     listItems(sprintDir, 'pending'),
    in_progress: listItems(sprintDir, 'in-progress'),
    done:        listItems(sprintDir, 'done'),
  };
}

/**
 * Return slugs of uncompleted items (in-progress first, then pending).
 */
export function pendingSlugs(sprintDir) {
  const ip = listItems(sprintDir, 'in-progress').map(i => i.slug);
  const p  = listItems(sprintDir, 'pending').map(i => i.slug);
  return [...ip, ...p];
}

/**
 * Return the first in-progress slug, or null.
 */
export function inProgressSlug(sprintDir) {
  const items = listItems(sprintDir, 'in-progress');
  return items.length ? items[0].slug : null;
}

/**
 * Return the next pending slug (in-progress first).
 */
export function nextSlug(sprintDir) {
  const slugs = pendingSlugs(sprintDir);
  return slugs.length ? slugs[0] : null;
}

/**
 * Get the full file content for a slug.
 */
export function itemText(sprintDir, slug) {
  const found = findItem(sprintDir, slug);
  if (!found) return `(item "${slug}" not found in backlog)`;
  return readFileSync(found.filePath, 'utf8');
}

/**
 * Add a new item to pending/.
 * @param {string} sprintDir
 * @param {string} slug
 * @param {string} description
 * @param {string} plan
 * @param {{ summary?, affectedFiles?, implementationGuide?, acceptanceCriteria? }} [extra]
 */
export function addItem(sprintDir, slug, description, plan, extra = {}) {
  ensureSprintDir(sprintDir);
  const dest = join(sectionDir(sprintDir, 'pending'), `${slug}.md`);
  if (existsSync(dest)) return false;
  writeFileSync(dest, serializeItem({
    slug,
    summary: extra.summary || '',
    description: description || '',
    affectedFiles: extra.affectedFiles || '',
    implementationGuide: extra.implementationGuide || '',
    acceptanceCriteria: extra.acceptanceCriteria || '',
    plan: plan || '',
  }), 'utf8');
  return true;
}

/**
 * Move an item between sections by renaming the file.
 * toSection: 'Pending' | 'In Progress' | 'Done' (or lowercase/kebab variants)
 */
export function moveItemSection(sprintDir, slug, _fromSection, toSection, opts = {}) {
  const toKey = normalizeSectionName(toSection);
  ensureSprintDir(sprintDir);

  for (const section of SECTIONS) {
    const src = join(sectionDir(sprintDir, section), `${slug}.md`);
    if (!existsSync(src)) continue;

    const dest = join(sectionDir(sprintDir, toKey), `${slug}.md`);
    renameSync(src, dest);
    return 'MOVED';
  }
  return 'NOT_FOUND';
}

/**
 * Convenience alias used in auto.js / commands.js.
 */
export function moveItem(sprintDir, slug, toSection) {
  return moveItemSection(sprintDir, slug, '', toSection);
}

/**
 * Mark an item done — move to done/ directory.
 */
export function markDone(sprintDir, slug) {
  const result = moveItemSection(sprintDir, slug, '', 'Done');
  return result === 'MOVED';
}

/**
 * Add or update the Plan section in the item's markdown file.
 */
export function upsertPlanLine(sprintDir, slug, planText) {
  const found = findItem(sprintDir, slug);
  if (!found) return 'NOT_FOUND';

  const trimmed = planText.trim();
  if (found.plan === trimmed) return 'UNCHANGED';

  const updated = { ...found, plan: trimmed };
  writeFileSync(found.filePath, serializeItem(updated), 'utf8');
  return 'UPDATED';
}

/**
 * Update fields of an existing item.
 */
export function updateItem(sprintDir, slug, { newSlug, summary, description, affectedFiles, implementationGuide, acceptanceCriteria, plan } = {}) {
  const found = findItem(sprintDir, slug);
  if (!found) return false;

  const updated = { ...found };
  if (summary              !== undefined) updated.summary = summary;
  if (description          !== undefined) updated.description = description;
  if (affectedFiles        !== undefined) updated.affectedFiles = affectedFiles;
  if (implementationGuide  !== undefined) updated.implementationGuide = implementationGuide;
  if (acceptanceCriteria   !== undefined) updated.acceptanceCriteria = acceptanceCriteria;
  if (plan                 !== undefined) updated.plan = plan;

  if (newSlug && newSlug !== slug) {
    updated.slug = newSlug;
    const newPath = join(sectionDir(sprintDir, found.section), `${newSlug}.md`);
    writeFileSync(newPath, serializeItem(updated), 'utf8');
    unlinkSync(found.filePath);
  } else {
    writeFileSync(found.filePath, serializeItem(updated), 'utf8');
  }
  return true;
}

/**
 * Remove an item from any section.
 */
export function removeItem(sprintDir, slug) {
  const found = findItem(sprintDir, slug);
  if (!found) return false;
  unlinkSync(found.filePath);
  return true;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function normalizeSectionName(name) {
  const l = name.toLowerCase().trim();
  if (l === 'pending')                                      return 'pending';
  if (l === 'in progress' || l === 'in-progress')           return 'in-progress';
  if (l === 'done')                                         return 'done';
  return 'pending';
}

// Legacy alias
export const ensureBacklogFile = ensureSprintDir;
