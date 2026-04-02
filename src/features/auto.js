/**
 * Auto/All/Status/Resume modes.
 * Replaces lib/auto.sh
 */

import { existsSync, readFileSync, readdirSync, symlinkSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { pendingSlugs, inProgressSlug, moveItem } from '../backlog/backlog.js';
import { createRun, sprintStateFor, listRuns, currentRunDir } from '../run/run.js';
import { runSprintLoop } from '../run/sprint.js';
import { cmdPlan } from '../run/commands.js';
import { cmdDiscover } from './discover.js';
import { cmdRetrospective } from './retro.js';
import { logStep, logOk, logInfo, logWarn } from '../core/logger.js';
import { t } from '../core/i18n.js';
import { printBatchProgress } from '../run/progress.js';

/**
 * Smart entry point: resumes → starts next → discovers.
 */
export async function cmdAuto(ctx) {
  const { config, harnDir, rootDir, scriptDir } = ctx;
  const backlogFile = config.BACKLOG_FILE;

  // 1. Resume in-progress run
  const curDir = currentRunDir(harnDir);
  if (curDir) {
    const curSprint = readSafe(join(curDir, 'current_sprint'));
    if (curSprint) {
      logInfo('Resuming in-progress run…');
      return cmdResume(ctx);
    }
  }

  // 2. Start next pending item
  const pending = pendingSlugs(backlogFile);
  if (pending.length > 0) {
    logInfo(`Starting next item: ${pending[0]}`);
    return cmdStart({ ...ctx, slug: pending[0] });
  }

  // 3. No items — discover
  logInfo('No pending items. Running discover…');
  return cmdDiscover(ctx);
}

/**
 * Run all pending backlog items sequentially.
 */
export async function cmdAll(ctx) {
  const { config, harnDir, rootDir, scriptDir } = ctx;
  const backlogFile = config.BACKLOG_FILE;
  const pending = pendingSlugs(backlogFile);

  if (pending.length === 0) {
    logInfo('No pending items.');
    return;
  }

  logStep(`Running ${pending.length} items`);
  const batchStart = Date.now();

  for (let i = 0; i < pending.length; i++) {
    const slug = pending[i];
    printBatchProgress({
      currentItem: i + 1, totalItems: pending.length, slug, startTime: batchStart,
    });

    try {
      await cmdStart({ ...ctx, slug, skipRetro: true });
    } catch (e) {
      logWarn(`Item ${slug} failed: ${e.message}`);
    }
  }

  // Final retrospective
  const curDir = currentRunDir(harnDir);
  if (curDir) {
    try {
      await cmdRetrospective({ runDir: curDir, ...ctx });
    } catch { /* skip */ }
  }

  logOk(`Batch complete: ${pending.length} items`);
}

/**
 * Start a specific backlog item (or prompt for selection).
 */
export async function cmdStart(ctx) {
  const { config, harnDir, rootDir, scriptDir, slug: inputSlug, skipRetro } = ctx;
  const backlogFile = config.BACKLOG_FILE;

  let slug = inputSlug;
  if (!slug) {
    const pending = pendingSlugs(backlogFile);
    if (pending.length === 0) {
      logWarn('No pending items.');
      return;
    }
    if (pending.length === 1) {
      slug = pending[0];
    } else {
      const inquirer = (await import('inquirer')).default;
      const { chosen } = await inquirer.prompt([{
        type: 'list', name: 'chosen', message: t('START_SELECT'), choices: pending,
      }]);
      slug = chosen;
    }
  }

  logStep(`Starting: ${slug}`);

  // Create run directory
  const runDir = createRun(harnDir, slug);

  // Move to In Progress
  moveItem(backlogFile, slug, 'In Progress');

  // Plan
  await cmdPlan({ runDir, harnDir, config, scriptDir, rootDir, slug });

  // Sprint loop
  await runSprintLoop({ runDir, harnDir, config, scriptDir, rootDir, slug });

  // Move to Done
  moveItem(backlogFile, slug, 'Done');
  logOk(`Completed: ${slug}`);

  // Retrospective
  if (!skipRetro && process.env.HARN_SKIP_RETRO !== 'true') {
    try {
      await cmdRetrospective({ runDir, harnDir, config, scriptDir, rootDir });
    } catch { /* skip */ }
  }
}

/**
 * Resume an in-progress run.
 */
export async function cmdResume(ctx) {
  const { harnDir, config, scriptDir, rootDir } = ctx;
  const curDir = currentRunDir(harnDir);

  if (!curDir) {
    logWarn('No active run to resume.');
    return;
  }

  const slug = readSafe(join(curDir, 'prompt.txt'));
  if (!slug) {
    logWarn('Cannot determine slug for current run.');
    return;
  }

  logStep(`Resuming: ${slug}`);
  await runSprintLoop({ runDir: curDir, harnDir, config, scriptDir, rootDir, slug });
  logOk(`Completed: ${slug}`);
}

/**
 * Show current status.
 */
export function cmdStatus({ harnDir, config }) {
  const backlogFile = config.BACKLOG_FILE;
  const curDir = currentRunDir(harnDir);

  logStep('Status');

  // Current run
  if (curDir) {
    const slug = readSafe(join(curDir, 'prompt.txt'));
    const sprint = readSafe(join(curDir, 'current_sprint'));
    console.log(`  Active: ${slug || '?'}  Sprint: ${sprint || '?'}`);
  } else {
    console.log('  No active run');
  }

  // Backlog summary
  if (existsSync(backlogFile)) {
    const pending = pendingSlugs(backlogFile);
    const ip = inProgressSlug(backlogFile);
    console.log(`  Pending: ${pending.length}  In Progress: ${ip || 'none'}`);
  }

  // Recent runs
  const runs = listRuns(harnDir);
  if (runs.length > 0) {
    console.log(`  Runs: ${runs.length} total (latest: ${runs[runs.length - 1]})`);
  }
  console.log('');
}

/**
 * Show run history.
 */
export function cmdRuns({ harnDir }) {
  const runs = listRuns(harnDir);
  if (runs.length === 0) {
    logInfo('No runs found.');
    return;
  }
  for (const run of runs) {
    const dir = join(harnDir, 'runs', run);
    const slug = readSafe(join(dir, 'prompt.txt'));
    const completed = existsSync(join(dir, 'completed'));
    const icon = completed ? '✓' : '…';
    console.log(`  ${icon}  ${run}  ${slug || ''}`);
  }
}

/**
 * Show or update config via CLI.
 */
export async function cmdConfig({ config, configFile }, key, value) {
  if (!key) {
    for (const [k, v] of Object.entries(config)) {
      console.log(`  ${k}=${v}`);
    }
    return;
  }
  if (value !== undefined) {
    const { saveConfig } = await import('../core/config.js');
    config[key] = value;
    saveConfig(configFile, config);
    logOk(`${key}=${value}`);
  } else {
    console.log(`  ${key}=${config[key] || '(not set)'}`);
  }
}

function readSafe(path) {
  try { return readFileSync(path, 'utf-8').trim(); } catch { return ''; }
}
