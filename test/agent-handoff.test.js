#!/usr/bin/env node

/**
 * Test: Agent handoff file flow (scope-based).
 * Verifies that Planner → Generator → Evaluator exchange files correctly
 * using the new scope-based structure:
 *   plan/scope-{N}.md       — planner output per scope
 *   sprints/scope-{N}/      — contract.md, implementation.md, qa-report.md
 *   retro/                  — per-agent retrospectives
 *   run_report.md           — progressive report
 *
 * Run: node test/agent-handoff.test.js
 */

import { writeFileSync, readFileSync, mkdirSync, existsSync, rmSync, renameSync } from 'node:fs';
import { join } from 'node:path';

const TEST_DIR = join(import.meta.dirname, '.test-handoff');
const HARN_DIR = join(TEST_DIR, '.harn');
const RUN_DIR = join(HARN_DIR, 'runs', '20260403-test');
const BACKLOG_DIR = join(HARN_DIR, 'backlog');

let passed = 0;
let failed = 0;

function assert(cond, msg) {
  if (cond) { console.log(`  ✓ ${msg}`); passed++; }
  else { console.error(`  ✗ ${msg}`); failed++; }
}

function readSafe(p) {
  try { return readFileSync(p, 'utf-8').trim(); } catch { return null; }
}

// ── Setup ──
function setup() {
  if (existsSync(TEST_DIR)) rmSync(TEST_DIR, { recursive: true });
  mkdirSync(join(BACKLOG_DIR, 'pending'), { recursive: true });
  mkdirSync(join(BACKLOG_DIR, 'in-progress'), { recursive: true });
  mkdirSync(join(BACKLOG_DIR, 'done'), { recursive: true });
  mkdirSync(join(RUN_DIR, 'plan'), { recursive: true });
  mkdirSync(join(RUN_DIR, 'sprints', 'scope-1'), { recursive: true });
  mkdirSync(join(RUN_DIR, 'retro'), { recursive: true });

  // Create a backlog item
  writeFileSync(join(BACKLOG_DIR, 'pending', 'test-feature.md'), [
    '# test-feature',
    '',
    '## Summary',
    'Add login feature',
    '',
    '## Description',
    'Implement user authentication with JWT',
  ].join('\n'));

  // Simulate run setup
  writeFileSync(join(RUN_DIR, 'prompt.txt'), 'test-feature');
}

function cleanup() {
  if (existsSync(TEST_DIR)) rmSync(TEST_DIR, { recursive: true });
}

// ── Mock Data ──

const MOCK_SCOPE_1_PLAN = [
  '# Scope 1: Auth Endpoints',
  '',
  '## Requirements',
  '- POST /auth/login endpoint',
  '- JWT token generation',
  '',
  '## Affected Files',
  '- src/auth/auth.controller.js',
  '- src/auth/auth.service.js',
  '',
  '## Acceptance Criteria',
  '- [ ] Login endpoint returns JWT',
  '- [ ] Invalid credentials return 401',
].join('\n');

const MOCK_SCOPE_2_PLAN = [
  '# Scope 2: Middleware & Tests',
  '',
  '## Requirements',
  '- Token validation middleware',
  '- Unit tests for auth module',
  '',
  '## Affected Files',
  '- src/middleware/auth.middleware.js',
  '- test/auth.test.js',
].join('\n');

const MOCK_CONTRACT = [
  '# Scope 1 Contract',
  '',
  '## Objectives',
  '- Implement POST /auth/login',
  '- Generate JWT on successful login',
  '',
  '## Deliverables',
  '- auth.controller.js',
  '- auth.service.js',
  '',
  '## Acceptance Criteria',
  '- Login returns 200 + JWT for valid creds',
  '- Login returns 401 for invalid creds',
].join('\n');

const MOCK_IMPLEMENTATION = [
  '# Implementation Summary',
  '',
  '## Files Changed',
  '- src/auth/auth.controller.js (new)',
  '- src/auth/auth.service.js (new)',
  '',
  '## Changes',
  'Created login endpoint with JWT generation.',
].join('\n');

const MOCK_QA_PASS = [
  '# QA Report',
  '',
  '## Checks',
  '- [x] Login endpoint created',
  '- [x] JWT generation works',
  '- [x] Input validation present',
  '',
  'VERDICT: PASS',
].join('\n');

const MOCK_QA_FAIL = [
  '# QA Report',
  '',
  '## Issues',
  '- [ ] Missing error handling for invalid credentials',
  '- [ ] No rate limiting',
  '',
  'VERDICT: FAIL',
].join('\n');

// ── Test 1: Planner writes scope plans ──
function testPlannerOutput() {
  console.log('\n[Test 1] Planner writes scope plan files');

  const planText = 'Implement JWT authentication with login/logout endpoints';
  const specMd = '# Login Feature Spec\n\n## Requirements\n- POST /auth/login endpoint\n- JWT token generation\n- Token validation middleware';

  writeFileSync(join(RUN_DIR, 'plan.txt'), planText);
  writeFileSync(join(RUN_DIR, 'spec.md'), specMd);
  writeFileSync(join(RUN_DIR, 'plan', 'scope-1.md'), MOCK_SCOPE_1_PLAN);
  writeFileSync(join(RUN_DIR, 'plan', 'scope-2.md'), MOCK_SCOPE_2_PLAN);
  writeFileSync(join(RUN_DIR, 'scope_count'), '2');
  writeFileSync(join(RUN_DIR, 'current_scope'), '1');

  // Initialize run_report.md
  writeFileSync(join(RUN_DIR, 'run_report.md'), '# Run Report: test-feature\n\n**Plan:** ' + planText);

  assert(readSafe(join(RUN_DIR, 'plan.txt')) === planText, 'plan.txt written');
  assert(readSafe(join(RUN_DIR, 'spec.md')).includes('Login Feature'), 'spec.md written');
  assert(existsSync(join(RUN_DIR, 'plan', 'scope-1.md')), 'plan/scope-1.md written');
  assert(existsSync(join(RUN_DIR, 'plan', 'scope-2.md')), 'plan/scope-2.md written');
  assert(readSafe(join(RUN_DIR, 'plan', 'scope-1.md')).includes('Auth Endpoints'), 'scope-1 plan has correct content');
  assert(readSafe(join(RUN_DIR, 'plan', 'scope-2.md')).includes('Middleware'), 'scope-2 plan has correct content');
  assert(readSafe(join(RUN_DIR, 'scope_count')) === '2', 'scope_count = 2');
  assert(readSafe(join(RUN_DIR, 'current_scope')) === '1', 'current_scope = 1');
}

// ── Test 2: Generator (contract) reads planner output ──
function testContractReadsPlanner() {
  console.log('\n[Test 2] Generator (contract) reads planner files');

  const spec = readSafe(join(RUN_DIR, 'spec.md'));
  const scopePlan = readSafe(join(RUN_DIR, 'plan', 'scope-1.md'));

  assert(spec !== null && spec.length > 0, 'Generator can read spec.md from planner');
  assert(scopePlan !== null && scopePlan.length > 0, 'Generator can read plan/scope-1.md');
  assert(spec.includes('Login Feature'), 'spec.md has planner content');
  assert(scopePlan.includes('Auth Endpoints'), 'scope plan has planner content');

  // Write contract output
  writeFileSync(join(RUN_DIR, 'sprints', 'scope-1', 'contract.md'), MOCK_CONTRACT);
  assert(existsSync(join(RUN_DIR, 'sprints', 'scope-1', 'contract.md')), 'contract.md written to scope dir');
}

// ── Test 3: Evaluator (contract) reads generator contract ──
function testContractReviewReadsContract() {
  console.log('\n[Test 3] Evaluator (contract review) reads contract');

  const contract = readSafe(join(RUN_DIR, 'sprints', 'scope-1', 'contract.md'));
  const scopePlan = readSafe(join(RUN_DIR, 'plan', 'scope-1.md'));

  assert(contract !== null && contract.includes('Scope 1 Contract'), 'Evaluator can read contract.md');
  assert(scopePlan !== null, 'Evaluator can read scope plan');
}

// ── Test 4: Generator (impl) reads contract + spec + scope plan ──
function testImplReadsContractAndSpec() {
  console.log('\n[Test 4] Generator (impl) reads contract + spec + scope plan');

  const contract = readSafe(join(RUN_DIR, 'sprints', 'scope-1', 'contract.md'));
  const spec = readSafe(join(RUN_DIR, 'spec.md'));
  const scopePlan = readSafe(join(RUN_DIR, 'plan', 'scope-1.md'));

  assert(contract !== null && contract.includes('Objectives'), 'Generator impl reads contract.md');
  assert(spec !== null && spec.includes('Requirements'), 'Generator impl reads spec.md');
  assert(scopePlan !== null && scopePlan.includes('Auth Endpoints'), 'Generator impl reads scope plan');

  // Write implementation output
  writeFileSync(join(RUN_DIR, 'sprints', 'scope-1', 'implementation.md'), MOCK_IMPLEMENTATION);
  assert(existsSync(join(RUN_DIR, 'sprints', 'scope-1', 'implementation.md')), 'implementation.md written');
}

// ── Test 5: Evaluator (QA) reads contract + implementation ──
function testEvaluatorReadsAll() {
  console.log('\n[Test 5] Evaluator (QA) reads contract + implementation');

  const contract = readSafe(join(RUN_DIR, 'sprints', 'scope-1', 'contract.md'));
  const impl = readSafe(join(RUN_DIR, 'sprints', 'scope-1', 'implementation.md'));

  assert(contract !== null && contract.includes('Scope 1 Contract'), 'Evaluator reads contract.md');
  assert(impl !== null && impl.includes('Implementation Summary'), 'Evaluator reads implementation.md');

  // Write QA report (FAIL first)
  writeFileSync(join(RUN_DIR, 'sprints', 'scope-1', 'qa-report.md'), MOCK_QA_FAIL);
  assert(existsSync(join(RUN_DIR, 'sprints', 'scope-1', 'qa-report.md')), 'qa-report.md written');
}

// ── Test 6: Generator (impl retry) reads QA report ──
function testRetryReadsQAReport() {
  console.log('\n[Test 6] Generator impl (retry) reads previous QA report');

  writeFileSync(join(RUN_DIR, 'sprints', 'scope-1', 'iteration'), '2');

  const qaReport = readSafe(join(RUN_DIR, 'sprints', 'scope-1', 'qa-report.md'));
  assert(qaReport !== null && qaReport.includes('VERDICT: FAIL'), 'Generator reads previous qa-report.md on retry');
  assert(qaReport.includes('Missing error handling'), 'QA feedback is accessible for retry');

  // Update implementation and QA with PASS
  writeFileSync(join(RUN_DIR, 'sprints', 'scope-1', 'implementation.md'), MOCK_IMPLEMENTATION + '\n\n## Retry fixes\n- Added error handling');
  writeFileSync(join(RUN_DIR, 'sprints', 'scope-1', 'qa-report.md'), MOCK_QA_PASS);
  writeFileSync(join(RUN_DIR, 'sprints', 'scope-1', 'status'), 'pass');
}

// ── Test 7: Next scope advances correctly ──
function testNextAdvances() {
  console.log('\n[Test 7] Next scope advances current_scope');

  const total = parseInt(readSafe(join(RUN_DIR, 'scope_count')), 10);
  assert(total === 2, 'scope_count is 2');

  // Advance to scope 2
  writeFileSync(join(RUN_DIR, 'current_scope'), '2');
  mkdirSync(join(RUN_DIR, 'sprints', 'scope-2'), { recursive: true });

  assert(readSafe(join(RUN_DIR, 'current_scope')) === '2', 'current_scope advanced to 2');
  assert(existsSync(join(RUN_DIR, 'sprints', 'scope-2')), 'Scope 2 directory created');
}

// ── Test 8: Full file tree after complete run ──
function testCompleteFileTree() {
  console.log('\n[Test 8] Complete run produces all expected files');

  // Simulate scope 2 completion
  writeFileSync(join(RUN_DIR, 'sprints', 'scope-2', 'contract.md'), '# Scope 2 Contract');
  writeFileSync(join(RUN_DIR, 'sprints', 'scope-2', 'implementation.md'), '# Scope 2 Impl');
  writeFileSync(join(RUN_DIR, 'sprints', 'scope-2', 'qa-report.md'), 'VERDICT: PASS');
  writeFileSync(join(RUN_DIR, 'sprints', 'scope-2', 'status'), 'pass');

  // Write retro files
  writeFileSync(join(RUN_DIR, 'retro', 'planner.md'), '# Planner Retrospective\n\nScope planning was effective.');
  writeFileSync(join(RUN_DIR, 'retro', 'generator.md'), '# Generator Retrospective\n\nCode generation quality was good.');
  writeFileSync(join(RUN_DIR, 'retro', 'evaluator.md'), '# Evaluator Retrospective\n\nQA caught key issues.');

  // Append to run report
  const existingReport = readSafe(join(RUN_DIR, 'run_report.md'));
  writeFileSync(join(RUN_DIR, 'run_report.md'), existingReport + '\n\n## Final Report\n\nAll scopes completed successfully.');

  // Verify all expected files exist
  const expectedFiles = [
    'prompt.txt',
    'plan.txt',
    'spec.md',
    'scope_count',
    'current_scope',
    'run_report.md',
    'plan/scope-1.md',
    'plan/scope-2.md',
    'sprints/scope-1/contract.md',
    'sprints/scope-1/implementation.md',
    'sprints/scope-1/qa-report.md',
    'sprints/scope-1/status',
    'sprints/scope-1/iteration',
    'sprints/scope-2/contract.md',
    'sprints/scope-2/implementation.md',
    'sprints/scope-2/qa-report.md',
    'sprints/scope-2/status',
    'retro/planner.md',
    'retro/generator.md',
    'retro/evaluator.md',
  ];

  for (const f of expectedFiles) {
    assert(existsSync(join(RUN_DIR, f)), `${f} exists`);
  }
}

// ── Test 9: File isolation between scopes ──
function testScopeIsolation() {
  console.log('\n[Test 9] Scope files are isolated between scopes');

  const s1Contract = readSafe(join(RUN_DIR, 'sprints', 'scope-1', 'contract.md'));
  const s2Contract = readSafe(join(RUN_DIR, 'sprints', 'scope-2', 'contract.md'));

  assert(s1Contract !== s2Contract, 'Scope 1 and 2 have different contracts');
  assert(s1Contract.includes('Scope 1'), 'Scope 1 contract belongs to scope 1');
  assert(s2Contract.includes('Scope 2'), 'Scope 2 contract belongs to scope 2');

  // Scope plans are also isolated
  const p1 = readSafe(join(RUN_DIR, 'plan', 'scope-1.md'));
  const p2 = readSafe(join(RUN_DIR, 'plan', 'scope-2.md'));
  assert(p1.includes('Auth Endpoints'), 'Scope 1 plan is specific to scope 1');
  assert(p2.includes('Middleware'), 'Scope 2 plan is specific to scope 2');
}

// ── Test 10: Scope expansion marker detection ──
function testScopeExpansion() {
  console.log('\n[Test 10] Scope expansion marker detection');

  const implWithExpansion = [
    '# Implementation Summary',
    '',
    '## Changes Made',
    '- Implemented auth endpoints',
    '',
    'SCOPE_EXPANSION_NEEDED',
    '',
    'Need to add database migration for user sessions table.',
  ].join('\n');

  const hasMarker = /^SCOPE_EXPANSION_NEEDED$/m.test(implWithExpansion);
  assert(hasMarker, 'SCOPE_EXPANSION_NEEDED marker detected in implementation');

  const implWithout = MOCK_IMPLEMENTATION;
  const noMarker = !/^SCOPE_EXPANSION_NEEDED$/m.test(implWithout);
  assert(noMarker, 'Normal implementation has no expansion marker');
}

// ── Test 11: Run report progressive updates ──
function testRunReport() {
  console.log('\n[Test 11] Run report progressive updates');

  const report = readSafe(join(RUN_DIR, 'run_report.md'));
  assert(report !== null, 'run_report.md exists');
  assert(report.includes('Run Report: test-feature'), 'Report has header');
  assert(report.includes('Final Report'), 'Report has final section');
}

// ── Test 12: Retro per-agent files ──
function testRetroFiles() {
  console.log('\n[Test 12] Per-agent retrospective files');

  const plannerRetro = readSafe(join(RUN_DIR, 'retro', 'planner.md'));
  const generatorRetro = readSafe(join(RUN_DIR, 'retro', 'generator.md'));
  const evaluatorRetro = readSafe(join(RUN_DIR, 'retro', 'evaluator.md'));

  assert(plannerRetro.includes('Planner Retrospective'), 'Planner retro has content');
  assert(generatorRetro.includes('Generator Retrospective'), 'Generator retro has content');
  assert(evaluatorRetro.includes('Evaluator Retrospective'), 'Evaluator retro has content');
}

// ── Test 13: Backlog directory structure ──
function testBacklogDir() {
  console.log('\n[Test 13] Backlog directory structure (.harn/backlog/)');

  assert(existsSync(join(BACKLOG_DIR, 'pending')), '.harn/backlog/pending/ exists');
  assert(existsSync(join(BACKLOG_DIR, 'in-progress')), '.harn/backlog/in-progress/ exists');
  assert(existsSync(join(BACKLOG_DIR, 'done')), '.harn/backlog/done/ exists');
  assert(existsSync(join(BACKLOG_DIR, 'pending', 'test-feature.md')), 'backlog item in pending/');

  // Move to in-progress
  renameSync(
    join(BACKLOG_DIR, 'pending', 'test-feature.md'),
    join(BACKLOG_DIR, 'in-progress', 'test-feature.md'),
  );
  assert(existsSync(join(BACKLOG_DIR, 'in-progress', 'test-feature.md')), 'item moved to in-progress/');
  assert(!existsSync(join(BACKLOG_DIR, 'pending', 'test-feature.md')), 'item removed from pending/');

  // Move to done
  renameSync(
    join(BACKLOG_DIR, 'in-progress', 'test-feature.md'),
    join(BACKLOG_DIR, 'done', 'test-feature.md'),
  );
  assert(existsSync(join(BACKLOG_DIR, 'done', 'test-feature.md')), 'item moved to done/');
}

// ── Test 14: Agent handoff data flow summary ──
function testHandoffSummary() {
  console.log('\n[Test 14] Agent handoff data flow verification');

  // Planner → shared files + per-scope plans
  assert(existsSync(join(RUN_DIR, 'spec.md')), 'Planner → spec.md (shared by all agents)');
  assert(existsSync(join(RUN_DIR, 'plan', 'scope-1.md')), 'Planner → plan/scope-1.md (per scope)');
  assert(existsSync(join(RUN_DIR, 'plan', 'scope-2.md')), 'Planner → plan/scope-2.md (per scope)');

  // Generator (contract) → per-scope file
  assert(existsSync(join(RUN_DIR, 'sprints', 'scope-1', 'contract.md')), 'Generator → contract.md (per scope)');

  // Generator (impl) → per-scope file
  assert(existsSync(join(RUN_DIR, 'sprints', 'scope-1', 'implementation.md')), 'Generator → implementation.md (per scope)');

  // Evaluator (QA) → per-scope file
  assert(existsSync(join(RUN_DIR, 'sprints', 'scope-1', 'qa-report.md')), 'Evaluator → qa-report.md (per scope)');

  // Progressive report
  assert(existsSync(join(RUN_DIR, 'run_report.md')), 'Planner → run_report.md (progressive)');

  // Per-agent retros
  assert(existsSync(join(RUN_DIR, 'retro', 'planner.md')), 'Retro → retro/planner.md');
  assert(existsSync(join(RUN_DIR, 'retro', 'generator.md')), 'Retro → retro/generator.md');
  assert(existsSync(join(RUN_DIR, 'retro', 'evaluator.md')), 'Retro → retro/evaluator.md');

  console.log('\n  === Agent Handoff Map (Scope-Based) ===');
  console.log('  Planner       → spec.md, plan/scope-{N}.md, scope_count, run_report.md');
  console.log('  Gen(contract)  ← spec.md, plan/scope-{N}.md');
  console.log('  Gen(contract)  → sprints/scope-{N}/contract.md');
  console.log('  Eval(contract) ← contract.md, plan/scope-{N}.md');
  console.log('  Gen(impl)      ← spec.md, plan/scope-{N}.md, contract.md, qa-report.md (retry)');
  console.log('  Gen(impl)      → sprints/scope-{N}/implementation.md (+scope_expansion)');
  console.log('  Eval(QA)       ← contract.md, implementation.md, plan/scope-{N}.md');
  console.log('  Eval(QA)       → sprints/scope-{N}/qa-report.md');
  console.log('  Next           → run_report.md (scope result appended)');
  console.log('  Final          → run_report.md (final summary), retro/{agent}.md');
}

// ── Run ──
try {
  setup();
  testPlannerOutput();
  testContractReadsPlanner();
  testContractReviewReadsContract();
  testImplReadsContractAndSpec();
  testEvaluatorReadsAll();
  testRetryReadsQAReport();
  testNextAdvances();
  testCompleteFileTree();
  testScopeIsolation();
  testScopeExpansion();
  testRunReport();
  testRetroFiles();
  testBacklogDir();
  testHandoffSummary();
} finally {
  cleanup();
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
