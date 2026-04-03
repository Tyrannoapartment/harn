/**
 * Configuration management.
 * Replaces lib/config.sh
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync } from 'node:fs';
import { join } from 'node:path';

// ── Defaults ──────────────────────────────────────────────────────────────────
export const DEFAULTS = {
  SPRINT_DIR: '',   // resolved at runtime to <harnDir>/sprint
  MAX_ITERATIONS: '5',
  GIT_ENABLED: 'false',
  SPRINT_COUNT: '1',
  MODEL_ROUTING: 'true',
  AI_BACKEND: '',
  AUXILIARY_BACKEND: '',
  PLANNER_BACKEND: '',
  GENERATOR_CONTRACT_BACKEND: '',
  GENERATOR_IMPL_BACKEND: '',
  EVALUATOR_CONTRACT_BACKEND: '',
  EVALUATOR_QA_BACKEND: '',
  AUXILIARY_MODEL: '',
  PLANNER_MODEL: 'claude-haiku-4.5',
  GENERATOR_CONTRACT_MODEL: 'claude-sonnet-4.6',
  GENERATOR_IMPL_MODEL: 'claude-opus-4.6',
  EVALUATOR_CONTRACT_MODEL: 'claude-haiku-4.5',
  EVALUATOR_QA_MODEL: 'claude-sonnet-4.5',
  LINT_COMMAND: '',
  TEST_COMMAND: '',
  E2E_COMMAND: '',
  HARN_LANG: '',
};

// ── Legacy key migration map ─────────────────────────────────────────────────
const LEGACY_KEY_MAP = {
  AI_BACKEND_AUXILIARY: 'AUXILIARY_BACKEND',
  AI_BACKEND_PLANNER: 'PLANNER_BACKEND',
  AI_BACKEND_GENERATOR_CONTRACT: 'GENERATOR_CONTRACT_BACKEND',
  AI_BACKEND_GENERATOR_IMPL: 'GENERATOR_IMPL_BACKEND',
  AI_BACKEND_EVALUATOR_CONTRACT: 'EVALUATOR_CONTRACT_BACKEND',
  AI_BACKEND_EVALUATOR_QA: 'EVALUATOR_QA_BACKEND',
  MODEL_AUXILIARY: 'AUXILIARY_MODEL',
  COPILOT_MODEL_PLANNER: 'PLANNER_MODEL',
  COPILOT_MODEL_GENERATOR_CONTRACT: 'GENERATOR_CONTRACT_MODEL',
  COPILOT_MODEL_GENERATOR_IMPL: 'GENERATOR_IMPL_MODEL',
  COPILOT_MODEL_EVALUATOR_CONTRACT: 'EVALUATOR_CONTRACT_MODEL',
  COPILOT_MODEL_EVALUATOR_QA: 'EVALUATOR_QA_MODEL',
};

/** Migrate legacy config keys to new names in-place. */
function migrateConfigKeys(cfg) {
  for (const [oldKey, newKey] of Object.entries(LEGACY_KEY_MAP)) {
    // If old key has a value, it came from the file — always takes priority
    if (cfg[oldKey] !== undefined && cfg[oldKey] !== '' && cfg[oldKey] !== DEFAULTS[oldKey]) {
      cfg[newKey] = cfg[oldKey];
    }
    delete cfg[oldKey];
  }
  return cfg;
}

// ── Paths ─────────────────────────────────────────────────────────────────────
export const getHarnDir    = (rootDir) => join(rootDir, '.harn');
export const getConfigPath = (rootDir) => join(rootDir, '.harn', 'config');
export const getBacklogDir  = (rootDir) => join(rootDir, '.harn', 'backlog');
/** @deprecated Use getBacklogDir instead */
export const getSprintDir   = getBacklogDir;

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
  return migrateConfigKeys(cfg);
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
  const oldHarnCfg = join(rootDir, '.harn_config');
  const newCfg = getConfigPath(rootDir);

  if (!existsSync(harnDir) && existsSync(oldDir)) {
    try { renameSync(oldDir, harnDir); } catch { /* ignore */ }
  }
  // Ensure .harn exists before migrating config into it
  ensureHarnDir(harnDir);
  if (!existsSync(newCfg)) {
    if (existsSync(oldHarnCfg)) {
      try { renameSync(oldHarnCfg, newCfg); } catch { /* ignore */ }
    } else if (existsSync(oldCfg)) {
      try { renameSync(oldCfg, newCfg); } catch { /* ignore */ }
    }
  }

  // Migrate .harn/sprint/ → .harn/backlog/
  const oldBacklogDir = join(harnDir, 'sprint');
  const newBacklogDir = join(harnDir, 'backlog');
  if (existsSync(oldBacklogDir) && !existsSync(newBacklogDir)) {
    try { renameSync(oldBacklogDir, newBacklogDir); } catch { /* ignore */ }
  }
}

// ── Ensure .harn dir ──────────────────────────────────────────────────────────
export function ensureHarnDir(harnDir) {
  if (!existsSync(harnDir)) mkdirSync(harnDir, { recursive: true });
}
