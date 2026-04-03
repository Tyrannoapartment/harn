/**
 * System diagnostics.
 * Replaces lib/doctor.sh
 */

import { execSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import chalk from 'chalk';
import { logStep } from '../core/logger.js';
import { t } from '../core/i18n.js';
import { getBacklogDir } from '../core/config.js';

function checkCli(name) {
  try {
    const ver = execSync(`${name} --version 2>/dev/null || ${name} version 2>/dev/null`, {
      encoding: 'utf-8', timeout: 5000,
    }).trim().split('\n')[0];
    return { installed: true, version: ver };
  } catch {
    return { installed: false, version: null };
  }
}

export function cmdDoctor({ harnDir, rootDir, config }) {
  logStep(t('DOCTOR_TITLE'));
  const results = {};

  // AI CLIs
  for (const cli of ['copilot', 'claude', 'codex', 'gemini']) {
    const r = checkCli(cli);
    results[cli] = r;
    const icon = r.installed ? chalk.green('✓') : chalk.dim('–');
    const ver = r.version ? chalk.dim(` (${r.version})`) : '';
    console.log(`  ${icon}  ${cli}${ver}`);
  }

  // System tools
  for (const cli of ['git', 'gh', 'node', 'python3', 'tmux']) {
    const r = checkCli(cli);
    results[cli] = r;
    const icon = r.installed ? chalk.green('✓') : chalk.dim('–');
    const ver = r.version ? chalk.dim(` (${r.version})`) : '';
    console.log(`  ${icon}  ${cli}${ver}`);
  }

  // Config
  const configFile = join(rootDir, '.harn', 'config');
  const hasConfig = existsSync(configFile);
  console.log(`  ${hasConfig ? chalk.green('✓') : chalk.yellow('?')}  .harn/config ${hasConfig ? '' : chalk.yellow('(missing)')}`);

  // Backlog
  if (config) {
    const bd = getBacklogDir(rootDir);
    const hasBacklog = existsSync(join(bd, 'pending'));
    console.log(`  ${hasBacklog ? chalk.green('✓') : chalk.yellow('?')}  backlog dir ${hasBacklog ? chalk.dim(bd) : chalk.yellow('(missing)')}`);
  }

  // Git branch
  try {
    const branch = execSync('git rev-parse --abbrev-ref HEAD', { cwd: rootDir, encoding: 'utf-8' }).trim();
    console.log(`  ${chalk.green('✓')}  git branch: ${chalk.bold(branch)}`);
  } catch {
    console.log(`  ${chalk.dim('–')}  git branch: ${chalk.dim('(not a git repo)')}`);
  }

  // Active backend & models
  if (config) {
    console.log(chalk.dim('\n  Models:'));
    const modelKeys = [
      ['PLANNER_MODEL', 'Planner'],
      ['GENERATOR_CONTRACT_MODEL', 'Generator (contract)'],
      ['GENERATOR_IMPL_MODEL', 'Generator (impl)'],
      ['EVALUATOR_CONTRACT_MODEL', 'Evaluator (contract)'],
      ['EVALUATOR_QA_MODEL', 'Evaluator (QA)'],
    ];
    for (const [key, label] of modelKeys) {
      const val = config[key] || chalk.dim('default');
      console.log(`    ${label}: ${val}`);
    }
  }

  console.log('');
  return results;
}
