/**
 * Sprint loop orchestration.
 * Replaces lib/sprint.sh
 */

import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import {
  currentSprintNum, sprintDir, sprintStatus, sprintIteration,
  setSprintIteration, setSprintStatus, setCurrentSprintNum,
} from './run.js';
import { cmdContract, cmdImplement, cmdEvaluate, cmdNext } from './commands.js';
import { logInfo, logOk, logWarn, logErr, logStep } from '../core/logger.js';
import { t } from '../core/i18n.js';
import { progressBar, formatElapsed } from './progress.js';

/**
 * Main sprint loop: contract → implement → evaluate → next.
 */
export async function runSprintLoop({ runDir, config, harnDir, scriptDir, rootDir, onLog, onProgress }) {
  const pidFile = join(harnDir, 'harn.pid');
  writeFileSync(pidFile, String(process.pid));

  const startTime = Date.now();
  let aborted = false;

  // Graceful shutdown handler
  const cleanup = () => {
    aborted = true;
    try { unlinkSync(pidFile); } catch { /* ignore */ }
  };
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);

  try {
    const totalFile = join(runDir, 'sprint_count');
    const totalSprints = existsSync(totalFile)
      ? parseInt(readFileSync(totalFile, 'utf-8').trim(), 10) : 1;
    const maxIterations = parseInt(config.MAX_ITERATIONS, 10) || 5;

    let currentSprint = currentSprintNum(runDir);

    while (currentSprint <= totalSprints && !aborted) {
      const sDir = sprintDir(runDir, currentSprint);
      const status = sprintStatus(runDir, currentSprint);

      // Progress display
      const elapsed = formatElapsed(startTime);
      logStep(`Sprint ${currentSprint}/${totalSprints}  ${progressBar(currentSprint - 1, totalSprints, 20)}  ${elapsed}`);
      if (onProgress) onProgress({ currentSprint, totalSprints, startTime });

      // Skip already-passed sprints
      if (status === 'pass') {
        logInfo(`Sprint ${currentSprint} already passed, skipping.`);
        currentSprint++;
        setCurrentSprintNum(runDir, currentSprint);
        continue;
      }

      // Contract phase
      const contractFile = join(sDir, 'contract.md');
      if (!existsSync(contractFile)) {
        await cmdContract({ runDir, sprintNum: currentSprint, config, harnDir, scriptDir, onLog });
      }

      // Implementation + evaluation loop
      let iter = sprintIteration(runDir, currentSprint);
      let passed = false;

      while (iter <= maxIterations && !aborted) {
        setSprintIteration(runDir, currentSprint, iter);
        logInfo(`${t('SPRINT_START')} ${currentSprint} — iteration ${iter}/${maxIterations}`);

        // Implement
        await cmdImplement({ runDir, sprintNum: currentSprint, config, harnDir, scriptDir, onLog });

        // Evaluate
        const { verdict } = await cmdEvaluate({
          runDir, sprintNum: currentSprint, config, harnDir, scriptDir, rootDir, onLog,
        });

        if (verdict === 'pass') {
          passed = true;
          logOk(t('SPRINT_PASS'));
          break;
        }

        logWarn(`${t('SPRINT_FAIL')} — iteration ${iter}/${maxIterations}`);
        iter++;
      }

      if (!passed && !aborted) {
        logWarn(`Max iterations (${maxIterations}) reached for Sprint ${currentSprint}. Advancing.`);
        setSprintStatus(runDir, currentSprint, 'fail');
      }

      // Next
      const { complete } = await cmdNext({
        runDir, sprintNum: currentSprint, config, harnDir, scriptDir, rootDir, onLog,
      });

      if (complete) break;
      currentSprint = currentSprintNum(runDir);
    }

    if (!aborted) {
      logOk(t('RUN_COMPLETE'));
    }
  } finally {
    process.removeListener('SIGINT', cleanup);
    process.removeListener('SIGTERM', cleanup);
    try { unlinkSync(pidFile); } catch { /* ignore */ }
  }
}
