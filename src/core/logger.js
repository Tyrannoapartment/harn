/**
 * Core logging, colors, and banner display.
 * Replaces lib/core.sh
 */

import chalk from 'chalk';
import { appendFileSync } from 'node:fs';

// ── ANSI strip ────────────────────────────────────────────────────────────────
const ANSI_RE = /\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])/g;
export const stripAnsi = (s) => s.replace(ANSI_RE, '');

// ── Timestamp ─────────────────────────────────────────────────────────────────
export const ts = () => {
  const d = new Date();
  return [d.getHours(), d.getMinutes(), d.getSeconds()]
    .map((n) => String(n).padStart(2, '0'))
    .join(':');
};

// ── Terminal width ────────────────────────────────────────────────────────────
export const termWidth = () => process.stdout.columns || 80;

// ── Raw log (terminal + file, ANSI-stripped in file) ──────────────────────────
export function logRaw(msg, logFile) {
  process.stdout.write(msg + '\n');
  if (logFile) {
    try {
      appendFileSync(logFile, stripAnsi(msg) + '\n');
    } catch { /* ignore */ }
  }
}

// ── Logging functions ─────────────────────────────────────────────────────────
export const logInfo  = (msg) => console.log(chalk.dim(`  [${ts()}]`) + `  ℹ  ${msg}`);
export const logOk    = (msg) => console.log(chalk.dim(`  [${ts()}]`) + chalk.green(`  ✓  ${msg}`));
export const logWarn  = (msg) => console.log(chalk.dim(`  [${ts()}]`) + chalk.yellow(`  ⚠  ${msg}`));
export const logErr   = (msg) => console.error(chalk.dim(`  [${ts()}]`) + chalk.red(`  ✗  ${msg}`));

export function logStep(msg) {
  const w = termWidth();
  const line = '─'.repeat(Math.max(w - 4, 20));
  console.log(chalk.dim(`\n  ${line}`));
  if (msg) console.log(chalk.bold(`  ${msg}`));
}

// ── Agent start/done boxes ────────────────────────────────────────────────────
const BACKEND_COLOR = {
  claude: chalk.blue, copilot: chalk.green,
  codex: chalk.yellow, gemini: chalk.magenta,
};

export function logAgentStart({ role, model, backend, task }) {
  const w = termWidth();
  const color = BACKEND_COLOR[backend] || chalk.white;
  const top = '┌' + '─'.repeat(w - 4) + '┐';
  const bot = '├' + '─'.repeat(w - 4) + '┤';
  console.log(chalk.dim(`\n  ${top}`));
  console.log(chalk.dim('  │ ') + color.bold(`${role}`) + chalk.dim(` · ${backend}/${model}`));
  if (task) console.log(chalk.dim('  │ ') + chalk.dim(task));
  console.log(chalk.dim(`  ${bot}\n`));
}

export function logAgentDone() {
  const w = termWidth();
  const line = '└' + '─'.repeat(w - 4) + '┘';
  console.log(chalk.dim(`\n  ${line}\n`));
}

// ── Banner ────────────────────────────────────────────────────────────────────
// 3-color block logo: purple(top) / gray(mid) / teal(bottom)
// Each "pixel" = 2 full-block chars for bold look
const BANNER = `
  ██╗  ██╗ █████╗ ██████╗ ███╗   ██╗
  ██║  ██║██╔══██╗██╔══██╗████╗  ██║
  ███████║███████║██████╔╝██╔██╗ ██║
  ██╔══██║██╔══██║██╔══██╗██║╚██╗██║
  ██║  ██║██║  ██║██║  ██║██║ ╚████║
  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝`;

const RESET = '\x1b[0m';
const DIM   = '\x1b[2m';
const BOLD  = '\x1b[1m';

export function printBanner(version) {
  console.log(chalk.cyan.bold(BANNER));
  console.log(chalk.dim(`  v${version} — AI Multi-Agent Sprint Loop\n`));
  console.log('');

  const cwd = process.cwd();
  console.log('');
  console.log(`  ${BOLD}harn${RESET} ${DIM}v${version}${RESET}  ${DIM}·${RESET}  ${DIM}AI Multi-Agent Sprint Loop${RESET}`);
  console.log('');
  console.log(`  \x1b[4m\x1b[36m${cwd}${RESET}`);
  console.log('');
}
