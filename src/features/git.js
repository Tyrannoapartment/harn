/**
 * Git commit helpers with structured commit protocol.
 * Replaces lib/git.sh
 */

import { execSync, spawnSync } from 'node:child_process';
import { logOk, logInfo, logWarn } from '../core/logger.js';

/** Check if we're inside a git repo. */
export function isGitRepo(cwd) {
  try {
    execSync('git rev-parse --is-inside-work-tree', { cwd, stdio: 'pipe' });
    return true;
  } catch {
    return false;
  }
}

/** Get current branch name. */
export function currentBranch(cwd) {
  try {
    return execSync('git rev-parse --abbrev-ref HEAD', { cwd, encoding: 'utf-8', stdio: 'pipe' }).trim();
  } catch {
    return '';
  }
}

/** Check if there are uncommitted changes. */
export function hasChanges(cwd) {
  try {
    const status = execSync('git status --porcelain', { cwd, encoding: 'utf-8', stdio: 'pipe' }).trim();
    return status.length > 0;
  } catch {
    return false;
  }
}

/** Get git diff summary. */
export function diffSummary(cwd) {
  try {
    return execSync('git diff --stat', { cwd, encoding: 'utf-8', stdio: 'pipe' }).trim();
  } catch {
    return '';
  }
}

/** Get full diff text. */
export function diffText(cwd) {
  try {
    return execSync('git diff', { cwd, encoding: 'utf-8', stdio: 'pipe', maxBuffer: 10 * 1024 * 1024 }).trim();
  } catch {
    return '';
  }
}

/** Stage and commit all changes with conventional message. */
export function commitAll(cwd, message) {
  try {
    execSync('git add -A', { cwd, stdio: 'pipe' });
    execSync(`git commit -m ${JSON.stringify(message)}`, { cwd, stdio: 'pipe' });
    logOk(`Committed: ${message}`);
    return true;
  } catch (e) {
    logWarn(`Commit failed: ${e.message}`);
    return false;
  }
}

/** Build structured commit message for sprint steps. */
export function buildCommitMessage({ step, sprint, slug, detail }) {
  const scope = slug ? `(${slug})` : '';
  const prefix = {
    plan: 'chore',
    contract: 'chore',
    implement: 'feat',
    evaluate: 'test',
    next: 'chore',
  }[step] || 'chore';
  const msg = `${prefix}${scope}: sprint ${sprint} ${step}`;
  return detail ? `${msg}\n\n${detail}` : msg;
}

/** Auto-commit sprint step if git is enabled. */
export function autoCommitStep({ cwd, config, step, sprint, slug }) {
  if (config.GIT_ENABLED !== 'true') return false;
  if (!isGitRepo(cwd)) return false;
  if (!hasChanges(cwd)) return false;

  const message = buildCommitMessage({ step, sprint, slug });
  return commitAll(cwd, message);
}
