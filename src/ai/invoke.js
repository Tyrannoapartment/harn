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
  planner:             'AI_BACKEND_PLANNER',
  generator_contract:  'AI_BACKEND_GENERATOR_CONTRACT',
  generator_impl:      'AI_BACKEND_GENERATOR_IMPL',
  evaluator_contract:  'AI_BACKEND_EVALUATOR_CONTRACT',
  evaluator_qa:        'AI_BACKEND_EVALUATOR_QA',
};

const ROLE_MODEL_KEYS = {
  planner:             'COPILOT_MODEL_PLANNER',
  generator_contract:  'COPILOT_MODEL_GENERATOR_CONTRACT',
  generator_impl:      'COPILOT_MODEL_GENERATOR_IMPL',
  evaluator_contract:  'COPILOT_MODEL_EVALUATOR_CONTRACT',
  evaluator_qa:        'COPILOT_MODEL_EVALUATOR_QA',
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
 * Determine the backend for a role.
 */
function resolveBackend(roleDetail, config) {
  const key = ROLE_BACKEND_KEYS[roleDetail];
  const backend = key ? resolveConfig(config, key) : '';
  if (backend) return backend;
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

  // 5. Determine effort (generator roles get 'high' for copilot)
  const effort = (backend === 'copilot' && GENERATOR_ROLES.has(detail)) ? 'high' : undefined;

  // 6. Invoke AI CLI
  const result = await aiGenerate({
    prompt: enrichedPrompt,
    backend,
    model,
    cwd: runDir || process.cwd(),
    effort,
    addDir: runDir ? join(runDir, '..', '..') : undefined,
    harnDir,
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

  // 5. Effort
  const effort = (backend === 'copilot' && GENERATOR_ROLES.has(detail)) ? 'high' : undefined;

  // 6. Invoke with streaming
  const result = await aiGenerateStreaming({
    prompt: enrichedPrompt,
    backend,
    model,
    cwd: runDir || process.cwd(),
    effort,
    addDir: runDir ? join(runDir, '..', '..') : undefined,
    harnDir,
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
