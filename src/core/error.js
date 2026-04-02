/**
 * Error handling and bug report helper.
 * Replaces lib/error.sh
 */

import { logErr } from './logger.js';

export class HarnError extends Error {
  constructor(message, code = 'HARN_ERROR') {
    super(message);
    this.name = 'HarnError';
    this.code = code;
  }
}

/**
 * Register global error handlers.
 */
export function setupErrorHandlers(harnDir, version) {
  process.on('uncaughtException', (err) => {
    logErr(`Unexpected error: ${err.message}`);
    if (process.env.HARN_DEBUG) console.error(err.stack);
    process.exit(2);
  });

  process.on('unhandledRejection', (reason) => {
    logErr(`Unhandled rejection: ${reason}`);
    if (process.env.HARN_DEBUG) console.error(reason);
    process.exit(2);
  });

  // Graceful Ctrl+C
  process.on('SIGINT', () => {
    console.log('');
    process.exit(130);
  });
}

/**
 * Suggest filing a bug report.
 */
export function suggestBugReport(error, context = {}) {
  console.error('');
  logErr('An unexpected error occurred.');
  console.error(`  ${error.message}`);
  if (error.stack && process.env.HARN_DEBUG) console.error(error.stack);
  console.error('');
  console.error('  To report this issue:');
  console.error('  gh issue create --repo Tyrannoapartment/harn --title "Bug: ..." --body "..."');
  console.error('');
}
