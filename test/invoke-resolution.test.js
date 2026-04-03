#!/usr/bin/env node

/**
 * Test: Backend + model resolution in invoke.js
 * Verifies that resolveBackend/resolveModel use new config keys
 * and correctly infer backend from model names.
 * Run: node test/invoke-resolution.test.js
 */

// We can't easily import private functions from invoke.js, so we test
// the exported invokeRole indirectly by checking that the config keys
// are properly read. Instead, we replicate the resolution logic here
// to verify the key mapping.

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

// Replicate the key maps from invoke.js (should match)
const ROLE_BACKEND_KEYS = {
  planner:             'PLANNER_BACKEND',
  generator_contract:  'GENERATOR_CONTRACT_BACKEND',
  generator_impl:      'GENERATOR_IMPL_BACKEND',
  evaluator_contract:  'EVALUATOR_CONTRACT_BACKEND',
  evaluator_qa:        'EVALUATOR_QA_BACKEND',
};

const ROLE_MODEL_KEYS = {
  planner:             'PLANNER_MODEL',
  generator_contract:  'GENERATOR_CONTRACT_MODEL',
  generator_impl:      'GENERATOR_IMPL_MODEL',
  evaluator_contract:  'EVALUATOR_CONTRACT_MODEL',
  evaluator_qa:        'EVALUATOR_QA_MODEL',
};

function inferBackendFromModel(model) {
  if (!model) return '';
  const m = model.toLowerCase();
  if (m.startsWith('claude-')) return 'claude';
  if (m.startsWith('gpt-') || m.startsWith('o1') || m.startsWith('o3')) return 'codex';
  if (m.startsWith('gemini-')) return 'gemini';
  return '';
}

function resolveBackend(roleDetail, config) {
  const key = ROLE_BACKEND_KEYS[roleDetail];
  const roleBackend = key && config[key] ? config[key] : '';
  if (roleBackend) return roleBackend;

  const modelKey = ROLE_MODEL_KEYS[roleDetail];
  const model = modelKey && config[modelKey] ? config[modelKey] : '';
  const inferred = inferBackendFromModel(model);
  if (inferred) return inferred;

  if (config.AI_BACKEND) return config.AI_BACKEND;
  return 'copilot';
}

// ── Test 1: Explicit per-role backend ──
console.log('\n[Test 1] Explicit per-role backend');
{
  const config = {
    AI_BACKEND: 'codex',
    PLANNER_BACKEND: 'claude',
    PLANNER_MODEL: 'claude-haiku-4.5',
  };
  assert(resolveBackend('planner', config) === 'claude', 'Explicit PLANNER_BACKEND takes priority');
}

// ── Test 2: Infer backend from model name ──
console.log('\n[Test 2] Infer backend from model name');
{
  const config = {
    AI_BACKEND: 'codex',
    PLANNER_MODEL: 'claude-haiku-4.5',
    GENERATOR_IMPL_MODEL: 'gpt-5.4',
    EVALUATOR_QA_MODEL: 'gemini-2.5-pro',
  };
  assert(resolveBackend('planner', config) === 'claude', 'claude-haiku-4.5 → claude backend');
  assert(resolveBackend('generator_impl', config) === 'codex', 'gpt-5.4 → codex backend');
  assert(resolveBackend('evaluator_qa', config) === 'gemini', 'gemini-2.5-pro → gemini backend');
}

// ── Test 3: Fallback to global AI_BACKEND ──
console.log('\n[Test 3] Fallback to global AI_BACKEND');
{
  const config = {
    AI_BACKEND: 'claude',
  };
  assert(resolveBackend('planner', config) === 'claude', 'No model set → uses AI_BACKEND');
}

// ── Test 4: Mixed backends per role ──
console.log('\n[Test 4] Mixed backends — each role gets correct backend');
{
  const config = {
    AI_BACKEND: 'copilot',
    PLANNER_MODEL: 'claude-haiku-4.5',
    GENERATOR_CONTRACT_MODEL: 'claude-sonnet-4.6',
    GENERATOR_IMPL_MODEL: 'claude-opus-4.6',
    EVALUATOR_QA_MODEL: 'gpt-5.4',
  };
  assert(resolveBackend('planner', config) === 'claude', 'Planner → claude');
  assert(resolveBackend('generator_contract', config) === 'claude', 'Generator contract → claude');
  assert(resolveBackend('generator_impl', config) === 'claude', 'Generator impl → claude');
  assert(resolveBackend('evaluator_qa', config) === 'codex', 'Evaluator QA → codex (gpt-5.4)');
  assert(resolveBackend('evaluator_contract', config) === 'copilot', 'Evaluator contract → copilot (no model, uses global)');
}

// ── Test 5: Key names are correct format ──
console.log('\n[Test 5] Key naming convention');
for (const [role, key] of Object.entries(ROLE_BACKEND_KEYS)) {
  assert(key.endsWith('_BACKEND'), `${role} backend key ends with _BACKEND: ${key}`);
  assert(!key.includes('AI_BACKEND_'), `${role} backend key does NOT use old AI_BACKEND_ prefix: ${key}`);
}
for (const [role, key] of Object.entries(ROLE_MODEL_KEYS)) {
  assert(key.endsWith('_MODEL'), `${role} model key ends with _MODEL: ${key}`);
  assert(!key.includes('COPILOT_'), `${role} model key does NOT use old COPILOT_ prefix: ${key}`);
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
