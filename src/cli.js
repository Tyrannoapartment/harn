#!/usr/bin/env node

/**
 * harn — Multi-agent sprint development loop orchestrator.
 * CLI entry point. Replaces harn.sh.
 */

import { Command } from 'commander';
import { join, resolve, dirname } from 'node:path';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { printBanner, logWarn } from './core/logger.js';
import { loadConfig, DEFAULTS } from './core/config.js';
import { setLang, t } from './core/i18n.js';
import { setupErrorHandlers } from './core/error.js';
import { checkForUpdates } from './features/update.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const SCRIPT_DIR = resolve(__dirname, '..');

// Read version from package.json
const PKG = JSON.parse(readFileSync(join(SCRIPT_DIR, 'package.json'), 'utf-8'));
const VERSION = PKG.version;

// Resolve project root (cwd or HARN_ROOT)
const ROOT_DIR = process.env.HARN_ROOT || process.cwd();
const HARN_DIR = join(ROOT_DIR, '.harn');
const CONFIG_FILE = join(ROOT_DIR, '.harn_config');

setupErrorHandlers();

const program = new Command();
program
  .name('harn')
  .version(VERSION)
  .description('Multi-agent sprint development loop orchestrator');

// Global model override flags
program
  .option('--planner-model <model>')
  .option('--generator-contract-model <model>')
  .option('--generator-impl-model <model>')
  .option('--evaluator-contract-model <model>')
  .option('--evaluator-qa-model <model>');

/** Build shared context from global options + config. */
function buildContext(opts = {}) {
  const config = loadConfig(CONFIG_FILE);
  setLang(config.HARN_LANG || 'en');

  // Apply CLI model overrides
  if (opts.plannerModel) config.COPILOT_MODEL_PLANNER = opts.plannerModel;
  if (opts.generatorContractModel) config.COPILOT_MODEL_GENERATOR_CONTRACT = opts.generatorContractModel;
  if (opts.generatorImplModel) config.COPILOT_MODEL_GENERATOR_IMPL = opts.generatorImplModel;
  if (opts.evaluatorContractModel) config.COPILOT_MODEL_EVALUATOR_CONTRACT = opts.evaluatorContractModel;
  if (opts.evaluatorQaModel) config.COPILOT_MODEL_EVALUATOR_QA = opts.evaluatorQaModel;

  return {
    config,
    configFile: CONFIG_FILE,
    harnDir: HARN_DIR,
    rootDir: ROOT_DIR,
    scriptDir: SCRIPT_DIR,
    version: VERSION,
  };
}

// ─── Commands ───

program
  .command('init')
  .description('Initialize harn in the current project')
  .action(async () => {
    printBanner(VERSION);
    const ctx = buildContext(program.opts());
    const { cmdInit } = await import('./features/init.js');
    await cmdInit(ctx);
  });

program
  .command('auto')
  .description('Smart entry: resume → start next → discover')
  .action(async () => {
    printBanner(VERSION);
    const ctx = buildContext(program.opts());
    checkForUpdates(HARN_DIR, VERSION);
    const { cmdAuto } = await import('./features/auto.js');
    await cmdAuto(ctx);
  });

program
  .command('all')
  .description('Run all pending backlog items')
  .action(async () => {
    printBanner(VERSION);
    const ctx = buildContext(program.opts());
    const { cmdAll } = await import('./features/auto.js');
    await cmdAll(ctx);
  });

program
  .command('start [slug]')
  .description('Start a specific backlog item')
  .action(async (slug) => {
    printBanner(VERSION);
    const ctx = buildContext(program.opts());
    const { cmdStart } = await import('./features/auto.js');
    await cmdStart({ ...ctx, slug });
  });

program
  .command('resume')
  .description('Resume an in-progress run')
  .action(async () => {
    printBanner(VERSION);
    const ctx = buildContext(program.opts());
    const { cmdResume } = await import('./features/auto.js');
    await cmdResume(ctx);
  });

program
  .command('status')
  .description('Show current status')
  .action(async () => {
    const ctx = buildContext(program.opts());
    const { cmdStatus } = await import('./features/auto.js');
    cmdStatus(ctx);
  });

program
  .command('runs')
  .description('List run history')
  .action(async () => {
    const ctx = buildContext(program.opts());
    const { cmdRuns } = await import('./features/auto.js');
    cmdRuns(ctx);
  });

program
  .command('backlog')
  .description('Show backlog')
  .action(async () => {
    const ctx = buildContext(program.opts());
    const config = ctx.config;
    const bl = config.BACKLOG_FILE;
    if (existsSync(bl)) {
      console.log(readFileSync(bl, 'utf-8'));
    } else {
      logWarn(`Backlog not found: ${bl}`);
    }
  });

program
  .command('add')
  .description('Add items to backlog (AI-assisted)')
  .action(async () => {
    printBanner(VERSION);
    const ctx = buildContext(program.opts());
    const { cmdAdd } = await import('./features/discover.js');
    await cmdAdd(ctx);
  });

program
  .command('discover')
  .description('Discover new backlog items by analyzing the codebase')
  .action(async () => {
    printBanner(VERSION);
    const ctx = buildContext(program.opts());
    const { cmdDiscover } = await import('./features/discover.js');
    await cmdDiscover(ctx);
  });

program
  .command('doctor')
  .description('System diagnostics')
  .action(async () => {
    printBanner(VERSION);
    const ctx = buildContext(program.opts());
    const { cmdDoctor } = await import('./features/doctor.js');
    cmdDoctor(ctx);
  });

program
  .command('web')
  .description('Launch web dashboard')
  .option('-p, --port <port>', 'Port number', '7111')
  .option('--no-open', 'Do not open browser')
  .action(async (opts) => {
    printBanner(VERSION);
    const ctx = buildContext(program.opts());
    const { startServer } = await import('./server/index.js');
    await startServer({
      port: parseInt(opts.port, 10),
      harnDir: HARN_DIR,
      rootDir: ROOT_DIR,
      configFile: CONFIG_FILE,
      openBrowser: opts.open !== false,
      commandRunner: async (cmd, args) => {
        // Delegate command execution
        const module = await import('./features/auto.js');
        const fn = module[`cmd${cmd.charAt(0).toUpperCase() + cmd.slice(1)}`];
        if (fn) return fn({ ...ctx, ...args });
        throw new Error(`Unknown command: ${cmd}`);
      },
    });
  });

program
  .command('config [key] [value]')
  .description('View or set config')
  .action(async (key, value) => {
    const ctx = buildContext(program.opts());
    const { cmdConfig } = await import('./features/auto.js');
    cmdConfig(ctx, key, value);
  });

program
  .command('memory')
  .description('Show project memory')
  .action(async () => {
    const ctx = buildContext(program.opts());
    const { memoryLoad } = await import('./features/memory.js');
    const content = memoryLoad(HARN_DIR);
    if (content) {
      console.log(content);
    } else {
      logWarn('No project memory yet.');
    }
  });

program
  .command('do <request...>')
  .description('Natural language command (AI-routed)')
  .action(async (request) => {
    printBanner(VERSION);
    const ctx = buildContext(program.opts());
    const { routeNlp } = await import('./features/nlp.js');
    const { command, args } = await routeNlp(request.join(' '), ctx.config);
    // Execute the resolved command
    await program.parseAsync([process.argv[0], process.argv[1], command, ...args.filter(Boolean)]);
  });

program
  .command('team [count] [task...]')
  .description('Launch parallel agents in tmux')
  .action(async (count, task) => {
    printBanner(VERSION);
    const ctx = buildContext(program.opts());
    const { cmdTeam } = await import('./features/team.js');
    cmdTeam(parseInt(count, 10) || 3, task.join(' '), ctx);
  });

program
  .command('help-all')
  .description('Show all commands with descriptions')
  .action(() => {
    printBanner(VERSION);
    program.outputHelp();
  });

// ─── Default action (no subcommand) ───
// harn → banner + AI refresh + web server
program.action(async () => {
  printBanner(VERSION);
  const ctx = buildContext(program.opts());

  // Quick AI tool check
  const { execSync } = await import('node:child_process');
  const tools = ['copilot', 'claude', 'codex'];
  console.log('  Checking AI tools...\n');
  for (const tool of tools) {
    try {
      const ver = execSync(`${tool} --version 2>/dev/null || echo ""`, {
        encoding: 'utf-8', timeout: 4000, stdio: ['pipe','pipe','pipe'],
      }).trim().split('\n')[0];
      if (ver) {
        console.log(`  \x1b[32m✓\x1b[0m  ${tool}  \x1b[2m${ver}\x1b[0m`);
      } else {
        console.log(`  \x1b[2m–\x1b[0m  ${tool}  \x1b[2mnot found\x1b[0m`);
      }
    } catch {
      console.log(`  \x1b[2m–\x1b[0m  ${tool}  \x1b[2mnot found\x1b[0m`);
    }
  }
  console.log('');

  // Start web server and open browser
  const { startServer } = await import('./server/index.js');
  await startServer({
    port: 7111,
    harnDir: HARN_DIR,
    rootDir: ROOT_DIR,
    configFile: CONFIG_FILE,
    openBrowser: true,
    commandRunner: async (cmd, args) => {
      const module = await import('./features/auto.js');
      const fn = module[`cmd${cmd.charAt(0).toUpperCase() + cmd.slice(1)}`];
      if (fn) return fn({ ...ctx, ...args });
      throw new Error(`Unknown command: ${cmd}`);
    },
  });
});

// Parse
program.parseAsync(process.argv).catch((err) => {
  console.error(err.message);
  process.exit(1);
});
