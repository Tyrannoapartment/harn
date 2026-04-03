// src/ai/backend.js — AI CLI detection, backend selection, generation
// Replaces lib/ai.sh

import { execFileSync, execFile, spawn } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

// ── Constants ────────────────────────────────────────────────────────────────

const CAPACITY_ERROR_RE =
  /MODEL_CAPACITY_EXHAUSTED|RESOURCE_EXHAUSTED|No capacity available|rateLimitExceeded/i;

const FALLBACK_MODELS = {
  copilot: [
    'claude-haiku-4.5', 'claude-sonnet-4.5', 'claude-sonnet-4.6',
    'claude-opus-4.5', 'claude-opus-4.6',
    'gpt-4.1', 'gpt-4o', 'gpt-4o-mini', 'o1', 'o3-mini',
  ],
  claude: [
    'claude-haiku-4.5', 'claude-sonnet-4.5', 'claude-sonnet-4.6',
    'claude-opus-4.5', 'claude-opus-4.6',
  ],
  codex: [
    'gpt-5.4', 'gpt-5.4-mini', 'gpt-5.3-codex', 'gpt-5.2-codex',
    'gpt-5.2', 'gpt-5.1-codex-max',
  ],
  gemini: [
    'gemini-2.5-pro', 'gemini-2.5-flash', 'gemini-2.0-flash',
    'gemini-1.5-pro', 'gemini-1.5-flash',
  ],
};

const BACKEND_PREFERENCE = ['copilot', 'claude', 'codex', 'gemini'];

// Clean env for subprocess: disable color and paging
const CLEAN_ENV = { ...process.env, NO_COLOR: '1', TERM: 'dumb' };

// ── Helpers ──────────────────────────────────────────────────────────────────

function which(cmd) {
  try {
    const p = execFileSync('which', [cmd], { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
    return p.trim() || null;
  } catch {
    return null;
  }
}

function modelCacheDir(harnDir) {
  return join(harnDir, 'model-cache');
}

function modelCacheFile(harnDir, backend) {
  return join(modelCacheDir(harnDir), `${backend}.txt`);
}

function readCacheLines(path) {
  if (!existsSync(path)) return null;
  const lines = readFileSync(path, 'utf8')
    .split('\n')
    .map(l => l.trim())
    .filter(Boolean);
  // deduplicate
  return [...new Set(lines)];
}

function writeCacheLines(path, lines) {
  const dir = join(path, '..');
  mkdirSync(dir, { recursive: true });
  const deduped = [...new Set(lines.filter(Boolean))];
  writeFileSync(path, deduped.join('\n') + '\n', 'utf8');
}

// ── Exported functions ───────────────────────────────────────────────────────

/**
 * Auto-detect the preferred AI CLI available on PATH.
 * Checks env AI_BACKEND first, then copilot → claude → codex → gemini.
 * @returns {string} backend name or '' if none found
 */
export function detectAiCli() {
  const override = process.env.AI_BACKEND;
  if (override) return override;

  for (const backend of BACKEND_PREFERENCE) {
    if (which(backend)) return backend;
  }
  return '';
}

/**
 * Get auxiliary AI backend (fallback for lightweight generation).
 * @returns {string} backend name
 */
export function detectAuxAiCli() {
  if (process.env.AI_BACKEND_AUXILIARY) return process.env.AI_BACKEND_AUXILIARY;
  return detectAiCli();
}

/**
 * Check if text contains a capacity/rate-limit error keyword.
 * @param {string} text
 * @returns {boolean}
 */
export function isCapacityError(text) {
  return CAPACITY_ERROR_RE.test(text);
}

/**
 * Return hardcoded fallback model list for a backend.
 * @param {string} backend
 * @returns {string[]}
 */
export function getFallbackModels(backend) {
  return [...(FALLBACK_MODELS[backend] || FALLBACK_MODELS.copilot)];
}

/**
 * Get the model list for a backend — cache first, then fallback.
 * @param {string} backend
 * @param {string} harnDir - path to .harn directory
 * @returns {string[]}
 */
export function getModelsForBackend(backend, harnDir) {
  if (harnDir) {
    const cached = readCacheLines(modelCacheFile(harnDir, backend));
    if (cached && cached.length > 0) return cached;
  }
  return getFallbackModels(backend);
}

/**
 * Get fallback models after the current model (for capacity-error retry).
 * Returns models listed after `currentModel` in the backend's model list.
 * @param {string} backend
 * @param {string} currentModel
 * @param {string} [harnDir]
 * @returns {string[]}
 */
export function fallbackModelsAfter(backend, currentModel, harnDir) {
  let models;
  try {
    models = getModelsForBackend(backend, harnDir);
  } catch {
    models = getFallbackModels(backend);
  }
  if (!currentModel) return models;
  const idx = models.indexOf(currentModel);
  if (idx === -1) return models;
  return models.slice(idx + 1);
}

/**
 * Discover models for a backend using its CLI.
 * Returns array of model names or null on failure. Timeout: 5 seconds.
 * @param {string} backend
 * @returns {Promise<string[]|null>}
 */
function discoverModels(backend) {
  const commands = {
    copilot: [['copilot', 'models']],
    claude: [['claude', 'models']],
    codex: [['codex', 'models'], ['codex', '--list-models']],
    gemini: [['gemini', 'models', 'list'], ['gemini', 'list-models']],
  };
  const patterns = {
    copilot: /(?:claude-[A-Za-z0-9.\-]+|gpt-[A-Za-z0-9.\-]+|o[13]-[A-Za-z0-9.\-]+|o[13]\b)/g,
    claude: /claude-[A-Za-z0-9.\-]+/g,
    codex: /(?:gpt-[A-Za-z0-9.\-]+|o[13]-[A-Za-z0-9.\-]+)/g,
    gemini: /gemini-[A-Za-z0-9.\-]+/g,
  };

  const cmds = commands[backend];
  const pattern = patterns[backend];
  if (!cmds || !pattern) return Promise.resolve(null);

  return new Promise(resolve => {
    let resolved = false;

    const tryNext = (i) => {
      if (i >= cmds.length) { resolve(null); return; }
      const [cmd, ...args] = cmds[i];
      const child = execFile(cmd, args, {
        timeout: 5000,
        encoding: 'utf8',
        env: CLEAN_ENV,
      }, (err, stdout, stderr) => {
        if (resolved) return;
        const text = (stdout || '') + '\n' + (stderr || '');
        const matches = text.match(pattern);
        if (matches && matches.length > 0) {
          resolved = true;
          resolve([...new Set(matches)]);
        } else {
          tryNext(i + 1);
        }
      });
      // Extra safety: kill on overall timeout
      setTimeout(() => { try { child.kill(); } catch {} }, 6000);
    };

    tryNext(0);
  });
}

/**
 * Refresh the model cache for all installed backends.
 * Writes `backends.txt` + per-backend cache files.
 * @param {string} harnDir
 */
export async function refreshModelCache(harnDir) {
  const cacheDir = modelCacheDir(harnDir);
  mkdirSync(cacheDir, { recursive: true });

  const installed = BACKEND_PREFERENCE.filter(b => which(b));
  writeFileSync(join(cacheDir, 'backends.txt'), installed.join('\n') + '\n', 'utf8');

  for (const backend of installed) {
    const models = await discoverModels(backend);
    const list = (models && models.length > 0) ? models : getFallbackModels(backend);
    writeCacheLines(modelCacheFile(harnDir, backend), list);
  }
}

/**
 * Return list of installed (available) backends.
 */
export function getInstalledBackends(harnDir) {
  const cacheFile = join(modelCacheDir(harnDir), 'backends.txt');
  try {
    return readFileSync(cacheFile, 'utf8').trim().split('\n').filter(Boolean);
  } catch {
    return BACKEND_PREFERENCE.filter(b => which(b));
  }
}

/**
 * Check the health status of all known AI backends.
 * Returns info about each: installed, version, auth status.
 * @param {string} harnDir
 * @returns {{ backend: string, installed: boolean, version: string, authenticated: boolean }[]}
 */
export function checkBackendHealth(harnDir) {
  const results = [];
  for (const backend of BACKEND_PREFERENCE) {
    const path = which(backend);
    const installed = !!path;
    let version = '';
    let authenticated = false;

    if (installed) {
      // Try to get version
      try {
        const raw = execFileSync(backend, ['--version'], {
          encoding: 'utf-8', timeout: 5000, env: CLEAN_ENV,
          stdio: ['pipe', 'pipe', 'pipe'],
        }).trim().split('\n')[0];
        version = raw || 'unknown';
      } catch {
        version = 'unknown';
      }

      // Quick auth check — different per backend
      try {
        if (backend === 'copilot') {
          // copilot: check if `gh auth status` or `copilot --version` works
          authenticated = true; // if we got version, it's likely ok
        } else if (backend === 'claude') {
          // claude: check if API key is set
          authenticated = !!(process.env.ANTHROPIC_API_KEY || version);
        } else if (backend === 'codex') {
          authenticated = !!(process.env.OPENAI_API_KEY || version);
        } else if (backend === 'gemini') {
          authenticated = !!(process.env.GOOGLE_API_KEY || process.env.GEMINI_API_KEY || version);
        }
      } catch {
        authenticated = false;
      }
    }

    results.push({ backend, installed, version, authenticated });
  }
  return results;
}

/**
 * Return models for ALL installed backends grouped by backend name.
 * @returns {{ [backend: string]: string[] }}
 */
export function getAllBackendModels(harnDir) {
  const backends = getInstalledBackends(harnDir);
  const result = {};
  for (const b of backends) {
    result[b] = getModelsForBackend(b, harnDir);
  }
  // Also include any backends not installed but with fallback models
  for (const b of BACKEND_PREFERENCE) {
    if (!result[b]) {
      result[b] = getFallbackModels(b);
    }
  }
  return result;
}

/**
 * Execute an AI CLI with a prompt and return the output.
 * Handles capacity errors by retrying with fallback models.
 *
 * @param {object} opts
 * @param {string} opts.prompt - prompt text
 * @param {string} [opts.backend] - ai backend (auto-detected if omitted)
 * @param {string} [opts.model] - model name
 * @param {string} [opts.cwd] - working directory for the subprocess
 * @param {number} [opts.timeout] - timeout in ms (default: 5 minutes)
 * @param {string} [opts.effort] - effort level (e.g. 'high') for copilot
 * @param {string} [opts.addDir] - directory to add via --add-dir (copilot)
 * @param {string} [opts.harnDir] - .harn directory for model cache
 * @returns {Promise<{output: string, exitCode: number, model: string}>}
 */
export async function aiGenerate({
  prompt,
  backend,
  model,
  cwd,
  timeout = 300_000,
  effort,
  addDir,
  harnDir,
}) {
  if (!backend) backend = detectAuxAiCli();
  if (!backend) throw new Error('No AI CLI found on PATH');

  let attemptModel = model || process.env.MODEL_AUXILIARY || '';

  while (true) {
    const { output, exitCode, stderr } = await _runCli({
      backend,
      prompt,
      model: attemptModel,
      cwd,
      timeout,
      effort,
      addDir,
    });

    if (exitCode === 0) {
      return { output, exitCode: 0, model: attemptModel };
    }

    // Check for capacity error → retry with fallback
    const combined = output + '\n' + stderr;
    if (isCapacityError(combined)) {
      const fallbacks = fallbackModelsAfter(backend, attemptModel, harnDir);
      if (fallbacks.length > 0) {
        attemptModel = fallbacks[0];
        continue;
      }
    }

    return { output, exitCode, model: attemptModel };
  }
}

/**
 * Run a single AI CLI invocation.
 * @returns {Promise<{output: string, stderr: string, exitCode: number}>}
 */
function _runCli({ backend, prompt, model, cwd, timeout, effort, addDir }) {
  return new Promise((resolve) => {
    let cmd, args;
    let useStdin = false;

    switch (backend) {
      case 'copilot': {
        cmd = 'copilot';
        args = [];
        if (addDir) args.push('--add-dir', addDir);
        args.push('--yolo', '-p', prompt);
        if (model) args.push('--model', model);
        if (effort) args.push('--effort', effort);
        break;
      }
      case 'claude': {
        cmd = 'claude';
        args = ['-p', prompt];
        if (model) args.push('--model', model);
        break;
      }
      case 'codex': {
        cmd = 'codex';
        args = ['exec'];
        if (model) args.push('-m', model);
        args.push('-');
        useStdin = true;
        break;
      }
      case 'gemini': {
        cmd = 'gemini';
        args = ['-p', prompt];
        if (model) args.push('--model', model);
        break;
      }
      default:
        resolve({ output: '', stderr: `Unknown backend: ${backend}`, exitCode: 1 });
        return;
    }

    const child = spawn(cmd, args, {
      cwd: cwd || process.cwd(),
      env: CLEAN_ENV,
      stdio: [useStdin ? 'pipe' : 'ignore', 'pipe', 'pipe'],
      timeout,
    });

    const stdout = [];
    const stderr = [];

    child.stdout.on('data', (chunk) => stdout.push(chunk));
    child.stderr.on('data', (chunk) => stderr.push(chunk));

    if (useStdin) {
      child.stdin.write(prompt);
      child.stdin.end();
    }

    child.on('close', (code) => {
      resolve({
        output: Buffer.concat(stdout).toString('utf8'),
        stderr: Buffer.concat(stderr).toString('utf8'),
        exitCode: code ?? 1,
      });
    });

    child.on('error', (err) => {
      resolve({
        output: '',
        stderr: err.message,
        exitCode: 1,
      });
    });
  });
}

/**
 * Run an AI CLI invocation with streaming output via callback.
 * @param {object} opts - same as aiGenerate plus onData callback
 * @param {function} opts.onData - callback(chunk: string) for each stdout chunk
 * @returns {Promise<{output: string, exitCode: number, model: string}>}
 */
export async function aiGenerateStreaming({
  prompt,
  backend,
  model,
  cwd,
  timeout = 300_000,
  effort,
  addDir,
  harnDir,
  onData,
}) {
  if (!backend) backend = detectAuxAiCli();
  if (!backend) throw new Error('No AI CLI found on PATH');

  let attemptModel = model || process.env.MODEL_AUXILIARY || '';

  while (true) {
    const { output, exitCode, stderr } = await _runCliStreaming({
      backend,
      prompt,
      model: attemptModel,
      cwd,
      timeout,
      effort,
      addDir,
      onData,
    });

    if (exitCode === 0) {
      return { output, exitCode: 0, model: attemptModel };
    }

    const combined = output + '\n' + stderr;
    if (isCapacityError(combined)) {
      const fallbacks = fallbackModelsAfter(backend, attemptModel, harnDir);
      if (fallbacks.length > 0) {
        attemptModel = fallbacks[0];
        continue;
      }
    }

    return { output, exitCode, model: attemptModel };
  }
}

function _runCliStreaming({ backend, prompt, model, cwd, timeout, effort, addDir, onData }) {
  return new Promise((resolve) => {
    let cmd, args;
    let useStdin = false;

    switch (backend) {
      case 'copilot': {
        cmd = 'copilot';
        args = [];
        if (addDir) args.push('--add-dir', addDir);
        args.push('--yolo', '-p', prompt);
        if (model) args.push('--model', model);
        if (effort) args.push('--effort', effort);
        break;
      }
      case 'claude': {
        cmd = 'claude';
        args = ['-p', prompt];
        if (model) args.push('--model', model);
        break;
      }
      case 'codex': {
        cmd = 'codex';
        args = ['exec'];
        if (model) args.push('-m', model);
        args.push('-');
        useStdin = true;
        break;
      }
      case 'gemini': {
        cmd = 'gemini';
        args = ['-p', prompt];
        if (model) args.push('--model', model);
        break;
      }
      default:
        resolve({ output: '', stderr: `Unknown backend: ${backend}`, exitCode: 1 });
        return;
    }

    const child = spawn(cmd, args, {
      cwd: cwd || process.cwd(),
      env: CLEAN_ENV,
      stdio: [useStdin ? 'pipe' : 'ignore', 'pipe', 'pipe'],
      timeout,
    });

    const stdout = [];
    const stderr = [];

    child.stdout.on('data', (chunk) => {
      const text = chunk.toString('utf8');
      stdout.push(chunk);
      if (onData) onData(text);
    });
    child.stderr.on('data', (chunk) => stderr.push(chunk));

    if (useStdin) {
      child.stdin.write(prompt);
      child.stdin.end();
    }

    child.on('close', (code) => {
      resolve({
        output: Buffer.concat(stdout).toString('utf8'),
        stderr: Buffer.concat(stderr).toString('utf8'),
        exitCode: code ?? 1,
      });
    });

    child.on('error', (err) => {
      resolve({ output: '', stderr: err.message, exitCode: 1 });
    });
  });
}
