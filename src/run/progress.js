/**
 * Progress display: bars, elapsed time, run/batch progress.
 * Replaces lib/progress.sh
 */

import chalk from 'chalk';

/** Generate a visual progress bar. */
export function progressBar(current, total, width = 20) {
  if (total <= 0) return '░'.repeat(width);
  const pct = Math.min(current / total, 1);
  const filled = Math.round(pct * width);
  return '█'.repeat(filled) + '░'.repeat(width - filled);
}

/** Format elapsed time since startTime as M:SS. */
export function formatElapsed(startTime) {
  const secs = Math.floor((Date.now() - startTime) / 1000);
  const min = Math.floor(secs / 60);
  const sec = secs % 60;
  return `${min}:${String(sec).padStart(2, '0')}`;
}

/** Print comprehensive run progress box. */
export function printRunProgress({ currentSprint, totalSprints, statuses, startTime }) {
  const elapsed = formatElapsed(startTime);
  const bar = progressBar(currentSprint - 1, totalSprints);
  const passed = statuses.filter((s) => s === 'pass').length;
  const failed = statuses.filter((s) => s === 'fail').length;
  const active = statuses.filter((s) => s === 'in-progress').length;
  const pending = statuses.filter((s) => s === 'pending').length;

  console.log(chalk.dim('\n  ┌─────────────────────────────────────────┐'));
  console.log(`  │ Sprint ${currentSprint}/${totalSprints}  ${bar}  ${elapsed}`);
  console.log(`  │ ${chalk.green(`✓ ${passed}`)}  ${chalk.red(`✗ ${failed}`)}  ${chalk.yellow(`↻ ${active}`)}  ${chalk.dim(`⏳ ${pending}`)}`);
  console.log(chalk.dim('  └─────────────────────────────────────────┘\n'));
}

/** Print batch progress for `harn all` mode. */
export function printBatchProgress({ currentItem, totalItems, slug, startTime }) {
  const elapsed = formatElapsed(startTime);
  const bar = progressBar(currentItem - 1, totalItems, 12);
  console.log(chalk.dim('\n  ──────────────────────────────'));
  console.log(`  Item ${currentItem}/${totalItems}  ${bar}  ${elapsed}`);
  console.log(`  ${chalk.bold(slug)}`);
  console.log(chalk.dim('  ──────────────────────────────\n'));
}
