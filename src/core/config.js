/**
 * Configuration management.
 * Replaces lib/config.sh
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync } from 'node:fs';
import { join } from 'node:path';

// ── Defaults ──────────────────────────────────────────────────────────────────
export const DEFAULTS = {
  BACKLOG_FILE: 'sprint-backlog.md',
  MAX_ITERATIONS: '5',
  GIT_ENABLED: 'false',
  SPRINT_COUNT: '1',
  MODEL_ROUTING: 'true',
  AI_BACKEND: '',
  AI_BACKEND_AUXILIARY: '',
  AI_BACKEND_PLANNER: '',
  AI_BACKEND_GENERATOR_CONTRACT: '',
  AI_BACKEND_GENERATOR_IMPL: '',
  AI_BACKEND_EVALUATOR_CONTRACT: '',
  AI_BACKEND_EVALUATOR_QA: '',
  MODEL_AUXILIARY: '',
  COPILOT_MODEL_PLANNER: 'claude-haiku-4.5',
  COPILOT_MODEL_GENERATOR_CONTRACT: 'claude-sonnet-4.6',
  COPILOT_MODEL_GENERATOR_IMPL: 'claude-opus-4.6',
  COPILOT_MODEL_EVALUATOR_CONTRACT: 'claude-haiku-4.5',
  COPILOT_MODEL_EVALUATOR_QA: 'claude-sonnet-4.5',
  LINT_COMMAND: '',
  TEST_COMMAND: '',
  E2E_COMMAND: '',
  HARN_LANG: '',
  CUSTOM_PROMPTS_DIR: '',
};

// ── Paths ─────────────────────────────────────────────────────────────────────
export const getHarnDir    = (rootDir) => join(rootDir, '.harn');
export const getConfigPath = (rootDir) => join(rootDir, '.harn_config');

// ── Load config ───────────────────────────────────────────────────────────────
export function loadConfig(configFile) {
  const cfg = { ...DEFAULTS };
  if (!existsSync(configFile)) return cfg;

  const content = readFileSync(configFile, 'utf-8');
  for (const line of content.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) continue;
    const idx = trimmed.indexOf('=');
    const key = trimmed.slice(0, idx).trim();
    let val = trimmed.slice(idx + 1).trim();
    // Strip surrounding quotes
    if ((val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    cfg[key] = val;
  }
  return cfg;
}

// ── Save config ───────────────────────────────────────────────────────────────
export function saveConfig(configFile, cfg) {
  const lines = [];
  for (const [key, val] of Object.entries(cfg)) {
    if (val === undefined || val === null) continue;
    lines.push(`${key}="${val}"`);
  }
  writeFileSync(configFile, lines.join('\n') + '\n', 'utf-8');
}

// ── Save raw config ───────────────────────────────────────────────────────────
export function saveConfigRaw(configFile, raw) {
  writeFileSync(configFile, raw, 'utf-8');
}

// ── Detect language ───────────────────────────────────────────────────────────
export function detectLang(cfg) {
  // 1. Env var
  if (process.env.HARN_LANG) return process.env.HARN_LANG;
  // 2. Config
  if (cfg?.HARN_LANG) return cfg.HARN_LANG;
  // 3. System locale
  const locale = process.env.LANG || process.env.LC_ALL || process.env.LC_MESSAGES || '';
  if (/^ko/i.test(locale)) return 'ko';
  return 'en';
}

// ── Backward compat migration ─────────────────────────────────────────────────
export function migrateOldDirs(rootDir) {
  const harnDir = getHarnDir(rootDir);
  const oldDir = join(rootDir, '.harness');
  const oldCfg = join(rootDir, '.harness_config');
  const newCfg = getConfigPath(rootDir);

  if (!existsSync(harnDir) && existsSync(oldDir)) {
    try { renameSync(oldDir, harnDir); } catch { /* ignore */ }
  }
  if (!existsSync(newCfg) && existsSync(oldCfg)) {
    try { renameSync(oldCfg, newCfg); } catch { /* ignore */ }
  }
}

// ── Ensure .harn dir ──────────────────────────────────────────────────────────
export function ensureHarnDir(harnDir) {
  if (!existsSync(harnDir)) mkdirSync(harnDir, { recursive: true });
}
