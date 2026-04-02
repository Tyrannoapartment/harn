/**
 * Run directory and sprint state management.
 * Replaces lib/run.sh
 */

import {
  readFileSync, writeFileSync, existsSync, mkdirSync,
  symlinkSync, readlinkSync, readdirSync, unlinkSync, statSync,
} from 'node:fs';
import { join, basename } from 'node:path';

/** Get active run ID from current symlink. */
export function currentRunId(harnDir) {
  const link = join(harnDir, 'current');
  try {
    if (existsSync(link)) return basename(readlinkSync(link));
  } catch { /* ignore */ }
  return null;
}

/** Get current run directory or throw. */
export function requireRunDir(harnDir) {
  const id = currentRunId(harnDir);
  if (!id) throw new Error('No active run. Use `harn start` first.');
  const dir = join(harnDir, 'runs', id);
  if (!existsSync(dir)) throw new Error(`Run directory not found: ${id}`);
  return dir;
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

  // Update current symlink
  const currentLink = join(harnDir, 'current');
  try { unlinkSync(currentLink); } catch { /* ignore */ }
  symlinkSync(join('runs', id), currentLink);

  return { id, runDir };
}

/** Set up run log file and current.log symlink. */
export function syncRunLog(harnDir, runDir) {
  const logFile = join(runDir, 'run.log');
  writeFileSync(logFile, '', { flag: 'a' });

  const currentLog = join(harnDir, 'current.log');
  try { unlinkSync(currentLog); } catch { /* ignore */ }
  try { symlinkSync(logFile, currentLog); } catch { /* ignore */ }
  return logFile;
}

/** Read current sprint number. */
export function currentSprintNum(runDir) {
  const file = join(runDir, 'current_sprint');
  if (existsSync(file)) return parseInt(readFileSync(file, 'utf-8').trim(), 10) || 1;
  return 1;
}

/** Set current sprint number. */
export function setCurrentSprintNum(runDir, num) {
  writeFileSync(join(runDir, 'current_sprint'), String(num));
}

/** Get sprint directory path (creates if needed). */
export function sprintDir(runDir, num) {
  const padded = String(num).padStart(3, '0');
  const dir = join(runDir, 'sprints', padded);
  mkdirSync(dir, { recursive: true });
  return dir;
}

/** Read sprint status. */
export function sprintStatus(runDir, num) {
  const dir = sprintDir(runDir, num);
  const file = join(dir, 'status');
  if (existsSync(file)) return readFileSync(file, 'utf-8').trim();
  return 'pending';
}

/** Set sprint status. */
export function setSprintStatus(runDir, num, status) {
  const dir = sprintDir(runDir, num);
  writeFileSync(join(dir, 'status'), status);
}

/** Read sprint iteration count. */
export function sprintIteration(runDir, num) {
  const dir = sprintDir(runDir, num);
  const file = join(dir, 'iteration');
  if (existsSync(file)) return parseInt(readFileSync(file, 'utf-8').trim(), 10) || 1;
  return 1;
}

/** Set sprint iteration count. */
export function setSprintIteration(runDir, num, iter) {
  const dir = sprintDir(runDir, num);
  writeFileSync(join(dir, 'iteration'), String(iter));
}

/** Count ## Sprint markers in sprint-backlog content. */
export function countSprintsInBacklog(content) {
  const matches = content.match(/^## Sprint/gm);
  return matches ? matches.length : 0;
}

/** List all run directories sorted descending. */
export function listRuns(harnDir) {
  const runsDir = join(harnDir, 'runs');
  if (!existsSync(runsDir)) return [];
  return readdirSync(runsDir)
    .filter((d) => statSync(join(runsDir, d)).isDirectory())
    .sort()
    .reverse();
}

/** Get full detail for a run. */
export function getRunDetail(harnDir, runId) {
  if (!/^[\w-]+$/.test(runId)) return null;
  const runPath = join(harnDir, 'runs', runId);
  if (!existsSync(runPath)) return null;

  const detail = { id: runId, sprints: [], completed: false };

  for (const fname of ['prompt.txt', 'plan.txt']) {
    const fpath = join(runPath, fname);
    if (existsSync(fpath)) {
      detail[fname.replace('.', '_')] = readFileSync(fpath, 'utf-8').trim();
    }
  }
  detail.completed = existsSync(join(runPath, 'completed'));

  const sprintsDir = join(runPath, 'sprints');
  if (existsSync(sprintsDir)) {
    for (const snum of readdirSync(sprintsDir).sort()) {
      const sp = join(sprintsDir, snum);
      if (!statSync(sp).isDirectory()) continue;
      const sprint = { num: snum, status: 'pending', iteration: '1', files: [] };
      for (const key of ['status', 'iteration']) {
        const fp = join(sp, key);
        if (existsSync(fp)) sprint[key] = readFileSync(fp, 'utf-8').trim();
      }
      sprint.files = ['contract.md', 'implementation.md', 'qa-report.md']
        .filter((f) => existsSync(join(sp, f)));
      detail.sprints.push(sprint);
    }
  }
  return detail;
}
