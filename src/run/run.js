/**
 * Run directory and scope state management.
 * Scope-based structure: runs/{id}/plan/scope-{N}.md, sprints/scope-{N}/
 */

import {
  readFileSync, writeFileSync, existsSync, mkdirSync,
  readdirSync, unlinkSync, statSync,
} from 'node:fs';
import { join } from 'node:path';

// ── Run management ──────────────────────────────────────────────────────────

/** Get active run ID from .harn/active_run file. */
export function currentRunId(harnDir) {
  const file = join(harnDir, 'active_run');
  try {
    if (existsSync(file)) return readFileSync(file, 'utf-8').trim();
  } catch { /* ignore */ }
  return null;
}

/** Get active run directory path, or null. */
export function currentRunDir(harnDir) {
  const id = currentRunId(harnDir);
  if (!id) return null;
  const dir = join(harnDir, 'runs', id);
  return existsSync(dir) ? dir : null;
}

/** Get current run directory or throw. */
export function requireRunDir(harnDir) {
  const id = currentRunId(harnDir);
  if (!id) throw new Error('No active run. Use `harn start` first.');
  const dir = join(harnDir, 'runs', id);
  if (!existsSync(dir)) throw new Error(`Run directory not found: ${id}`);
  return dir;
}

/** Clear the active run marker. */
export function clearActiveRun(harnDir) {
  const file = join(harnDir, 'active_run');
  try { unlinkSync(file); } catch { /* ignore */ }
}

/** Create a new run directory with timestamp ID. */
export function createRun(harnDir) {
  const now = new Date();
  const id = [
    now.getFullYear(),
    String(now.getMonth() + 1).padStart(2, '0'),
    String(now.getDate()).padStart(2, '0'),
    '-',
    String(now.getHours()).padStart(2, '0'),
    String(now.getMinutes()).padStart(2, '0'),
    String(now.getSeconds()).padStart(2, '0'),
  ].join('');
  const runDir = join(harnDir, 'runs', id);
  mkdirSync(runDir, { recursive: true });

  // Write active run ID
  writeFileSync(join(harnDir, 'active_run'), id);

  return { id, runDir };
}

/** Set up run log file. */
export function syncRunLog(harnDir, runDir) {
  const logFile = join(runDir, 'run.log');
  writeFileSync(logFile, '', { flag: 'a' });
  return logFile;
}

// ── Plan directory ──────────────────────────────────────────────────────────

/** Ensure plan/ directory exists under runDir. */
export function ensurePlanDir(runDir) {
  const dir = join(runDir, 'plan');
  mkdirSync(dir, { recursive: true });
  return dir;
}

/** Write a scope plan file: plan/scope-{N}.md */
export function writeScopePlan(runDir, scopeNum, content) {
  const planDir = ensurePlanDir(runDir);
  writeFileSync(join(planDir, `scope-${scopeNum}.md`), content);
}

/** Read a scope plan file. */
export function readScopePlan(runDir, scopeNum) {
  const file = join(runDir, 'plan', `scope-${scopeNum}.md`);
  if (existsSync(file)) return readFileSync(file, 'utf-8');
  return '';
}

/** List all scope plan files and return count. */
export function scopeCount(runDir) {
  const planDir = join(runDir, 'plan');
  if (!existsSync(planDir)) return 0;
  return readdirSync(planDir)
    .filter(f => /^scope-\d+\.md$/.test(f))
    .length;
}

// ── Scope (sprint) directory ────────────────────────────────────────────────

/** Get scope directory path: sprints/scope-{N}/ (creates if needed). */
export function scopeDir(runDir, scopeNum) {
  const dir = join(runDir, 'sprints', `scope-${scopeNum}`);
  mkdirSync(dir, { recursive: true });
  return dir;
}

/** Read current scope number. */
export function currentScopeNum(runDir) {
  const file = join(runDir, 'current_scope');
  if (existsSync(file)) return parseInt(readFileSync(file, 'utf-8').trim(), 10) || 1;
  return 1;
}

/** Set current scope number. */
export function setCurrentScopeNum(runDir, num) {
  writeFileSync(join(runDir, 'current_scope'), String(num));
}

/** Read scope status. */
export function scopeStatus(runDir, scopeNum) {
  const dir = scopeDir(runDir, scopeNum);
  const file = join(dir, 'status');
  if (existsSync(file)) return readFileSync(file, 'utf-8').trim();
  return 'pending';
}

/** Set scope status. */
export function setScopeStatus(runDir, scopeNum, status) {
  const dir = scopeDir(runDir, scopeNum);
  writeFileSync(join(dir, 'status'), status);
}

/** Read scope iteration count. */
export function scopeIteration(runDir, scopeNum) {
  const dir = scopeDir(runDir, scopeNum);
  const file = join(dir, 'iteration');
  if (existsSync(file)) return parseInt(readFileSync(file, 'utf-8').trim(), 10) || 1;
  return 1;
}

/** Set scope iteration count. */
export function setScopeIteration(runDir, scopeNum, iter) {
  const dir = scopeDir(runDir, scopeNum);
  writeFileSync(join(dir, 'iteration'), String(iter));
}

// ── Retro directory ─────────────────────────────────────────────────────────

/** Ensure retro/ directory exists under runDir. */
export function ensureRetroDir(runDir) {
  const dir = join(runDir, 'retro');
  mkdirSync(dir, { recursive: true });
  return dir;
}

/** Write a per-agent retro file: retro/{agent}.md */
export function writeRetro(runDir, agent, content) {
  const retroDir = ensureRetroDir(runDir);
  writeFileSync(join(retroDir, `${agent}.md`), content);
}

/** Read a per-agent retro file. */
export function readRetro(runDir, agent) {
  const file = join(runDir, 'retro', `${agent}.md`);
  if (existsSync(file)) return readFileSync(file, 'utf-8');
  return '';
}

// ── Run report ──────────────────────────────────────────────────────────────

/** Append a scope result section to run_report.md */
export function appendRunReport(runDir, section) {
  const file = join(runDir, 'run_report.md');
  const existing = existsSync(file) ? readFileSync(file, 'utf-8') : '';
  writeFileSync(file, existing + (existing ? '\n\n' : '') + section);
}

/** Write the final report to run_report.md */
export function writeFinalReport(runDir, content) {
  const file = join(runDir, 'run_report.md');
  const existing = existsSync(file) ? readFileSync(file, 'utf-8') : '';
  writeFileSync(file, existing + '\n\n---\n\n' + content);
}

/** Read run_report.md */
export function readRunReport(runDir) {
  const file = join(runDir, 'run_report.md');
  if (existsSync(file)) return readFileSync(file, 'utf-8');
  return '';
}

// ── Legacy compat (sprint-numbered helpers) ─────────────────────────────────

/** @deprecated Use currentScopeNum */
export function currentSprintNum(runDir) {
  // Try new format first, fall back to old
  const newFile = join(runDir, 'current_scope');
  if (existsSync(newFile)) return parseInt(readFileSync(newFile, 'utf-8').trim(), 10) || 1;
  const oldFile = join(runDir, 'current_sprint');
  if (existsSync(oldFile)) return parseInt(readFileSync(oldFile, 'utf-8').trim(), 10) || 1;
  return 1;
}

/** @deprecated Use setCurrentScopeNum */
export function setCurrentSprintNum(runDir, num) {
  setCurrentScopeNum(runDir, num);
}

/** @deprecated Use scopeDir */
export function sprintDir(runDir, num) {
  return scopeDir(runDir, num);
}

/** @deprecated Use scopeStatus */
export function sprintStatus(runDir, num) {
  return scopeStatus(runDir, num);
}

/** @deprecated Use setScopeStatus */
export function setSprintStatus(runDir, num, status) {
  setScopeStatus(runDir, num, status);
}

/** @deprecated Use scopeIteration */
export function sprintIteration(runDir, num) {
  return scopeIteration(runDir, num);
}

/** @deprecated Use setScopeIteration */
export function setSprintIteration(runDir, num, iter) {
  setScopeIteration(runDir, num, iter);
}

/** @deprecated Use scopeCount */
export function countSprintsInBacklog(content) {
  const matches = content.match(/^## Sprint/gm);
  return matches ? matches.length : 0;
}

// ── Listing ─────────────────────────────────────────────────────────────────

/** List all run directories sorted descending. */
export function listRuns(harnDir) {
  const runsDir = join(harnDir, 'runs');
  if (!existsSync(runsDir)) return [];
  return readdirSync(runsDir)
    .filter((d) => statSync(join(runsDir, d)).isDirectory())
    .sort()
    .reverse();
}

/** Get full detail for a run (supports both scope-based and legacy numbered sprints). */
export function getRunDetail(harnDir, runId) {
  if (!/^[\w-]+$/.test(runId)) return null;
  const runPath = join(harnDir, 'runs', runId);
  if (!existsSync(runPath)) return null;

  const detail = { id: runId, scopes: [], completed: false };

  // Read basic files
  for (const fname of ['prompt.txt', 'plan.txt']) {
    const fpath = join(runPath, fname);
    if (existsSync(fpath)) {
      detail[fname.replace('.', '_')] = readFileSync(fpath, 'utf-8').trim();
    }
  }

  // Read spec
  const specPath = join(runPath, 'spec.md');
  if (existsSync(specPath)) {
    detail.spec = readFileSync(specPath, 'utf-8').trim();
  }

  // Read run report
  const reportPath = join(runPath, 'run_report.md');
  if (existsSync(reportPath)) {
    detail.run_report = readFileSync(reportPath, 'utf-8').trim();
    detail.completed = true;
  }

  // Read scope plans
  const planDir = join(runPath, 'plan');
  if (existsSync(planDir)) {
    detail.plans = readdirSync(planDir)
      .filter(f => f.endsWith('.md'))
      .sort()
      .map(f => ({ name: f, content: readFileSync(join(planDir, f), 'utf-8').trim() }));
  }

  // Read scopes (sprints)
  const sprintsDir = join(runPath, 'sprints');
  if (existsSync(sprintsDir)) {
    for (const sname of readdirSync(sprintsDir).sort()) {
      const sp = join(sprintsDir, sname);
      if (!statSync(sp).isDirectory()) continue;
      const scope = { name: sname, status: 'pending', iteration: '1', files: [] };
      for (const key of ['status', 'iteration']) {
        const fp = join(sp, key);
        if (existsSync(fp)) scope[key] = readFileSync(fp, 'utf-8').trim();
      }
      scope.files = ['contract.md', 'implementation.md', 'qa-report.md']
        .filter((f) => existsSync(join(sp, f)));
      detail.scopes.push(scope);
    }
  }

  // Read retro
  const retroDir = join(runPath, 'retro');
  if (existsSync(retroDir)) {
    detail.retro = {};
    for (const f of readdirSync(retroDir).filter(f => f.endsWith('.md'))) {
      const agent = f.replace('.md', '');
      detail.retro[agent] = readFileSync(join(retroDir, f), 'utf-8').trim();
    }
  }

  // Legacy compat: also expose as "sprints" for old consumers
  detail.sprints = detail.scopes;

  return detail;
}
