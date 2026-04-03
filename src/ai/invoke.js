// src/ai/invoke.js — Agent invocation with context injection
// Replaces lib/invoke.sh

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import {
  detectAiCli,
  aiGenerate,
  aiGenerateStreaming,
  isCapacityError,
  fallbackModelsAfter,
} from './backend.js';
import { routeModel } from './routing.js';

// ── Role → config key mapping ────────────────────────────────────────────────

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

const ROLE_GUIDANCE_MAP = {
  planner:            'plan',
  generator_contract: 'implement',
  generator_impl:     'implement',
  evaluator_contract: 'evaluate',
  evaluator_qa:       'evaluate',
};

// Generator roles get --effort high (for copilot backend)
const GENERATOR_ROLES = new Set(['generator_contract', 'generator_impl']);

// ── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Resolve config value: check config object, then env, then default.
 */
function resolveConfig(config, key, defaultValue = '') {
  if (config && config[key] !== undefined && config[key] !== '') return config[key];
  if (process.env[key] !== undefined && process.env[key] !== '') return process.env[key];
  return defaultValue;
}

/**
 * Infer the correct backend from a model name prefix.
 * e.g. claude-sonnet-4.6 → 'claude', gpt-5.4 → 'codex', gemini-2.5-pro → 'gemini'
 */
function inferBackendFromModel(model) {
  if (!model) return '';
  const m = model.toLowerCase();
  if (m.startsWith('claude-')) return 'claude';
  if (m.startsWith('gpt-') || m.startsWith('o1') || m.startsWith('o3')) return 'codex';
  if (m.startsWith('gemini-')) return 'gemini';
  return '';
}

/**
 * Determine the backend for a role.
 * Priority: role-specific config → model-name inference → AI_BACKEND config → env → auto-detect
 */
function resolveBackend(roleDetail, config) {
  // 1. Role-specific backend (e.g. PLANNER_BACKEND)
  const key = ROLE_BACKEND_KEYS[roleDetail];
  const roleBackend = key ? resolveConfig(config, key) : '';
  if (roleBackend) return roleBackend;

  // 2. Infer from model name — prevents mismatch (e.g. claude model on codex backend)
  const modelKey = ROLE_MODEL_KEYS[roleDetail];
  const model = modelKey ? resolveConfig(config, modelKey) : '';
  const inferred = inferBackendFromModel(model);
  if (inferred) return inferred;

  // 3. Global AI_BACKEND from config or env
  const globalBackend = resolveConfig(config, 'AI_BACKEND');
  if (globalBackend) return globalBackend;

  // 4. Auto-detect from PATH
  return detectAiCli() || 'copilot';
}

/**
 * Determine the model for a role.
 */
function resolveModel(roleDetail, config) {
  const key = ROLE_MODEL_KEYS[roleDetail];
  return key ? resolveConfig(config, key) : '';
}

/**
 * Inject project memory into the prompt.
 * Memory is read from memoryInject() if available.
 * @param {string} prompt
 * @param {object} opts
 * @param {function} [opts.memoryInject] - () => string|null
 * @returns {string}
 */
function injectMemory(prompt, { memoryInject }) {
  if (typeof memoryInject !== 'function') return prompt;
  try {
    const block = memoryInject();
    if (block) return block + '\n\n' + prompt;
  } catch { /* ignore */ }
  return prompt;
}

/**
 * Inject guidance into the prompt.
 * @param {string} prompt
 * @param {string} guidanceType - 'plan' | 'implement' | 'evaluate'
 * @param {object} opts
 * @param {function} [opts.hasGuidance] - (type) => boolean
 * @param {function} [opts.injectGuidance] - (type) => string|null
 * @returns {{ prompt: string, guidanceApplied: boolean }}
 */
function injectGuidanceBlock(prompt, guidanceType, { hasGuidance, injectGuidance }) {
  if (typeof hasGuidance !== 'function' || typeof injectGuidance !== 'function') {
    return { prompt, guidanceApplied: false };
  }
  try {
    if (!hasGuidance(guidanceType)) return { prompt, guidanceApplied: false };
    const block = injectGuidance(guidanceType);
    if (block) {
      return { prompt: block + '\n\n' + prompt, guidanceApplied: true };
    }
  } catch { /* ignore */ }
  return { prompt, guidanceApplied: false };
}

/**
 * Load a prompt file's content.
 * Searches: custom prompts dir (.harn/prompts/) → built-in prompts dir.
 * @param {string} role - 'planner' | 'generator' | 'evaluator'
 * @param {string} harnDir - .harn directory
 * @param {string} scriptDir - harn installation directory
 * @returns {string|null}
 */
export function loadPromptFile(role, harnDir, scriptDir) {
  // Custom prompts take priority
  if (harnDir) {
    const customPath = join(harnDir, 'prompts', `${role}.md`);
    if (existsSync(customPath)) {
      return readFileSync(customPath, 'utf8');
    }
  }
  // Built-in prompts
  if (scriptDir) {
    const builtinPath = join(scriptDir, 'prompts', `${role}.md`);
    if (existsSync(builtinPath)) {
      return readFileSync(builtinPath, 'utf8');
    }
  }
  return null;
}

// ── Main invocation ──────────────────────────────────────────────────────────

/**
 * Invoke an AI agent for a given role.
 *
 * @param {object} opts
 * @param {string} opts.role - base role: 'planner' | 'generator' | 'evaluator'
 * @param {string} opts.roleDetail - specific role key: 'planner', 'generator_contract', etc.
 * @param {string} opts.prompt - the prompt text
 * @param {string} opts.runDir - current run directory
 * @param {string} opts.harnDir - .harn directory
 * @param {string} opts.scriptDir - harn installation directory
 * @param {object} [opts.config] - loaded config object
 * @param {function} [opts.memoryInject] - () => string|null
 * @param {function} [opts.hasGuidance] - (type) => boolean
 * @param {function} [opts.injectGuidance] - (type) => string|null
 * @returns {Promise<{output: string, exitCode: number, backend: string, model: string}>}
 */
export async function invokeRole({
  role,
  roleDetail,
  prompt,
  runDir,
  harnDir,
  scriptDir,
  rootDir,
  config = {},
  memoryInject: memoryInjectFn,
  hasGuidance: hasGuidanceFn,
  injectGuidance: injectGuidanceFn,
}) {
  const detail = roleDetail || role;

  // 1. Determine backend and model
  const backend = resolveBackend(detail, config);
  let model = resolveModel(detail, config);

  // 2. Inject memory
  let enrichedPrompt = injectMemory(prompt, { memoryInject: memoryInjectFn });

  // 3. Inject guidance
  const guidanceType = ROLE_GUIDANCE_MAP[detail] || 'implement';
  const guidance = injectGuidanceBlock(enrichedPrompt, guidanceType, {
    hasGuidance: hasGuidanceFn,
    injectGuidance: injectGuidanceFn,
  });
  enrichedPrompt = guidance.prompt;

  // 4. Apply model routing if enabled
  if (model) {
    model = routeModel(model, enrichedPrompt, config);
  }

  // 5. Determine effort and yolo (only generator_impl edits files)
  const isImpl = detail === 'generator_impl';
  const effort = (backend === 'copilot' && GENERATOR_ROLES.has(detail)) ? 'high' : undefined;
  const yolo = backend === 'copilot' && isImpl;

  // 6. Derive project root: rootDir > harnDir/.. > runDir
  const projectRoot = rootDir || (harnDir ? join(harnDir, '..') : null);
  const cwd = projectRoot || runDir || process.cwd();

  // 7. Invoke AI CLI
  const result = await aiGenerate({
    prompt: enrichedPrompt,
    backend,
    model,
    cwd,
    effort,
    addDir: projectRoot || undefined,
    harnDir,
    yolo,
  });

  return {
    output: result.output,
    exitCode: result.exitCode,
    backend,
    model: result.model || model,
    guidanceApplied: guidance.guidanceApplied,
  };
}

/**
 * Invoke an AI agent with real-time streaming output.
 * Same options as invokeRole, plus an onData callback.
 *
 * @param {object} opts - same as invokeRole
 * @param {function} opts.onData - callback(chunk: string) called for each stdout chunk
 * @returns {Promise<{output: string, exitCode: number, backend: string, model: string}>}
 */
export async function invokeWithStreaming({
  role,
  roleDetail,
  prompt,
  runDir,
  harnDir,
  scriptDir,
  rootDir,
  config = {},
  memoryInject: memoryInjectFn,
  hasGuidance: hasGuidanceFn,
  injectGuidance: injectGuidanceFn,
  onData,
}) {
  const detail = roleDetail || role;

  // 1. Determine backend and model
  const backend = resolveBackend(detail, config);
  let model = resolveModel(detail, config);

  // 2. Inject memory
  let enrichedPrompt = injectMemory(prompt, { memoryInject: memoryInjectFn });

  // 3. Inject guidance
  const guidanceType = ROLE_GUIDANCE_MAP[detail] || 'implement';
  const guidance = injectGuidanceBlock(enrichedPrompt, guidanceType, {
    hasGuidance: hasGuidanceFn,
    injectGuidance: injectGuidanceFn,
  });
  enrichedPrompt = guidance.prompt;

  // 4. Apply model routing
  if (model) {
    model = routeModel(model, enrichedPrompt, config);
  }

  // 5. Effort and yolo (only generator_impl edits files)
  const isImpl = detail === 'generator_impl';
  const effort = (backend === 'copilot' && GENERATOR_ROLES.has(detail)) ? 'high' : undefined;
  const yolo = backend === 'copilot' && isImpl;

  // 6. Derive project root: rootDir > harnDir/.. > runDir
  const projectRoot = rootDir || (harnDir ? join(harnDir, '..') : null);
  const cwd = projectRoot || runDir || process.cwd();

  // 7. Invoke with streaming
  const result = await aiGenerateStreaming({
    prompt: enrichedPrompt,
    backend,
    model,
    cwd,
    effort,
    addDir: projectRoot || undefined,
    harnDir,
    yolo,
    onData,
  });

  return {
    output: result.output,
    exitCode: result.exitCode,
    backend,
    model: result.model || model,
    guidanceApplied: guidance.guidanceApplied,
  };
}
