#!/usr/bin/env node

/**
 * Test: Config key migration + backend/model resolution.
 * Run: node test/config-migration.test.js
 */

import { writeFileSync, mkdirSync, existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { loadConfig, DEFAULTS, saveConfig } from '../src/core/config.js';

const TEST_DIR = join(import.meta.dirname, '.test-tmp');
const CONFIG_FILE = join(TEST_DIR, 'config');

let passed = 0;
let failed = 0;

function assert(condition, msg) {
  if (condition) {
    console.log(`  ✓ ${msg}`);
    passed++;
  } else {
    console.error(`  ✗ ${msg}`);
    failed++;
  }
}

function setup() {
  if (existsSync(TEST_DIR)) rmSync(TEST_DIR, { recursive: true });
  mkdirSync(TEST_DIR, { recursive: true });
}

function cleanup() {
  if (existsSync(TEST_DIR)) rmSync(TEST_DIR, { recursive: true });
}

// ── Test 1: New key defaults ──
function testNewDefaults() {
  console.log('\n[Test 1] New config key defaults');
  assert(DEFAULTS.PLANNER_MODEL === 'claude-haiku-4.5', 'PLANNER_MODEL default = claude-haiku-4.5');
  assert(DEFAULTS.GENERATOR_CONTRACT_MODEL === 'claude-sonnet-4.6', 'GENERATOR_CONTRACT_MODEL default = claude-sonnet-4.6');
  assert(DEFAULTS.GENERATOR_IMPL_MODEL === 'claude-opus-4.6', 'GENERATOR_IMPL_MODEL default = claude-opus-4.6');
  assert(DEFAULTS.EVALUATOR_CONTRACT_MODEL === 'claude-haiku-4.5', 'EVALUATOR_CONTRACT_MODEL default');
  assert(DEFAULTS.EVALUATOR_QA_MODEL === 'claude-sonnet-4.5', 'EVALUATOR_QA_MODEL default');
  assert(DEFAULTS.PLANNER_BACKEND === '', 'PLANNER_BACKEND default empty');
  assert(DEFAULTS.AUXILIARY_MODEL === '', 'AUXILIARY_MODEL default empty');
  assert(DEFAULTS.AUXILIARY_BACKEND === '', 'AUXILIARY_BACKEND default empty');

  // Old keys should NOT exist in defaults
  assert(!('COPILOT_MODEL_PLANNER' in DEFAULTS), 'Old COPILOT_MODEL_PLANNER not in DEFAULTS');
  assert(!('AI_BACKEND_PLANNER' in DEFAULTS), 'Old AI_BACKEND_PLANNER not in DEFAULTS');
  assert(!('MODEL_AUXILIARY' in DEFAULTS), 'Old MODEL_AUXILIARY not in DEFAULTS');
}

// ── Test 2: Legacy config migration ──
function testLegacyMigration() {
  console.log('\n[Test 2] Legacy config file migration');
  // Write a config file with OLD key names
  const legacyConfig = [
    'AI_BACKEND="claude"',
    'COPILOT_MODEL_PLANNER="gpt-5.4-mini"',
    'COPILOT_MODEL_GENERATOR_CONTRACT="claude-haiku-4.5"',
    'COPILOT_MODEL_GENERATOR_IMPL="claude-opus-4.6"',
    'COPILOT_MODEL_EVALUATOR_QA="gpt-5.4"',
    'AI_BACKEND_PLANNER="codex"',
    'AI_BACKEND_GENERATOR_IMPL="claude"',
    'MODEL_AUXILIARY="gpt-5.4-mini"',
    'AI_BACKEND_AUXILIARY="codex"',
    'MAX_ITERATIONS="3"',
  ].join('\n');
  writeFileSync(CONFIG_FILE, legacyConfig);

  const cfg = loadConfig(CONFIG_FILE);

  // New keys should have migrated values
  assert(cfg.PLANNER_MODEL === 'gpt-5.4-mini', 'PLANNER_MODEL migrated from COPILOT_MODEL_PLANNER');
  assert(cfg.GENERATOR_CONTRACT_MODEL === 'claude-haiku-4.5', 'GENERATOR_CONTRACT_MODEL migrated');
  assert(cfg.GENERATOR_IMPL_MODEL === 'claude-opus-4.6', 'GENERATOR_IMPL_MODEL migrated');
  assert(cfg.EVALUATOR_QA_MODEL === 'gpt-5.4', 'EVALUATOR_QA_MODEL migrated');
  assert(cfg.PLANNER_BACKEND === 'codex', 'PLANNER_BACKEND migrated from AI_BACKEND_PLANNER');
  assert(cfg.GENERATOR_IMPL_BACKEND === 'claude', 'GENERATOR_IMPL_BACKEND migrated');
  assert(cfg.AUXILIARY_MODEL === 'gpt-5.4-mini', 'AUXILIARY_MODEL migrated from MODEL_AUXILIARY');
  assert(cfg.AUXILIARY_BACKEND === 'codex', 'AUXILIARY_BACKEND migrated');

  // Old keys should be removed
  assert(!('COPILOT_MODEL_PLANNER' in cfg), 'Old COPILOT_MODEL_PLANNER removed');
  assert(!('AI_BACKEND_PLANNER' in cfg), 'Old AI_BACKEND_PLANNER removed');
  assert(!('MODEL_AUXILIARY' in cfg), 'Old MODEL_AUXILIARY removed');
  assert(!('AI_BACKEND_AUXILIARY' in cfg), 'Old AI_BACKEND_AUXILIARY removed');

  // Non-renamed keys preserved
  assert(cfg.AI_BACKEND === 'claude', 'AI_BACKEND preserved');
  assert(cfg.MAX_ITERATIONS === '3', 'MAX_ITERATIONS preserved');
}

// ── Test 3: New config format ──
function testNewFormat() {
  console.log('\n[Test 3] New config format (no migration needed)');
  const newConfig = [
    'AI_BACKEND="claude"',
    'PLANNER_MODEL="claude-haiku-4.5"',
    'PLANNER_BACKEND="claude"',
    'GENERATOR_IMPL_MODEL="claude-opus-4.6"',
    'GENERATOR_IMPL_BACKEND="claude"',
    'EVALUATOR_QA_MODEL="claude-sonnet-4.5"',
  ].join('\n');
  writeFileSync(CONFIG_FILE, newConfig);

  const cfg = loadConfig(CONFIG_FILE);
  assert(cfg.PLANNER_MODEL === 'claude-haiku-4.5', 'PLANNER_MODEL direct');
  assert(cfg.PLANNER_BACKEND === 'claude', 'PLANNER_BACKEND direct');
  assert(cfg.GENERATOR_IMPL_MODEL === 'claude-opus-4.6', 'GENERATOR_IMPL_MODEL direct');
  assert(cfg.GENERATOR_IMPL_BACKEND === 'claude', 'GENERATOR_IMPL_BACKEND direct');
}

// ── Test 4: Save + reload roundtrip ──
function testSaveRoundtrip() {
  console.log('\n[Test 4] Save and reload roundtrip');
  const cfg = { ...DEFAULTS, AI_BACKEND: 'claude', PLANNER_MODEL: 'claude-sonnet-4.6', PLANNER_BACKEND: 'claude' };
  saveConfig(CONFIG_FILE, cfg);
  const loaded = loadConfig(CONFIG_FILE);
  assert(loaded.PLANNER_MODEL === 'claude-sonnet-4.6', 'PLANNER_MODEL roundtrip');
  assert(loaded.PLANNER_BACKEND === 'claude', 'PLANNER_BACKEND roundtrip');
  assert(loaded.AI_BACKEND === 'claude', 'AI_BACKEND roundtrip');
}

// ── Run ──
try {
  setup();
  testNewDefaults();
  testLegacyMigration();
  testNewFormat();
  testSaveRoundtrip();
} finally {
  cleanup();
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
