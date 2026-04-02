/**
 * Auto-update check — npm version compare.
 * Replaces lib/update.sh
 */

import { execSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import chalk from 'chalk';

const PKG_NAME = '@tyrannoapartment/harn';
const CACHE_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours

/** Check for updates (non-blocking, cached). */
export function checkForUpdates(harnDir, currentVersion) {
  if (process.env.HARN_NO_UPDATE_CHECK === 'true') return;

  const cacheFile = join(harnDir, '.update-cache');

  // Check cache
  if (existsSync(cacheFile)) {
    try {
      const cache = JSON.parse(readFileSync(cacheFile, 'utf-8'));
      if (Date.now() - cache.timestamp < CACHE_TTL_MS) {
        if (cache.latest && isNewer(cache.latest, currentVersion)) {
          showUpdateNotice(currentVersion, cache.latest);
        }
        return;
      }
    } catch { /* ignore corrupt cache */ }
  }

  // Async check (non-blocking)
  try {
    const latest = execSync(`npm view ${PKG_NAME} version 2>/dev/null`, {
      encoding: 'utf-8', timeout: 5000, stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();

    // Write cache
    mkdirSync(harnDir, { recursive: true });
    writeFileSync(cacheFile, JSON.stringify({ latest, timestamp: Date.now() }));

    if (latest && isNewer(latest, currentVersion)) {
      showUpdateNotice(currentVersion, latest);
    }
  } catch {
    // Network error — silently skip
  }
}

/** Compare semver strings (simple). */
function isNewer(remote, local) {
  const r = remote.split('.').map(Number);
  const l = local.split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    if ((r[i] || 0) > (l[i] || 0)) return true;
    if ((r[i] || 0) < (l[i] || 0)) return false;
  }
  return false;
}

function showUpdateNotice(current, latest) {
  console.log(chalk.yellow(`\n  ⬆  Update available: ${current} → ${latest}`));
  console.log(chalk.dim(`     npm update -g ${PKG_NAME}\n`));
}
