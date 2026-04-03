/**
 * Console assistant — AI-powered chat that interprets user intent,
 * executes harn skills (backlog, sprint, config, info), and responds
 * conversationally when no action is needed.
 *
 * Replaces the old NLP-only command router.
 */

import { readFileSync, existsSync, mkdirSync, writeFileSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { aiGenerate, detectAiCli } from '../ai/backend.js';
import { loadConfig, saveConfig, getBacklogDir } from '../core/config.js';
import {
  readBacklog, pendingSlugs, addItem, removeItem,
  updateItem, moveItemSection, ensureBacklogDir,
} from '../backlog/backlog.js';
import { listRuns, currentRunId } from '../run/run.js';
import { memoryLoad } from '../features/memory.js';
import { getMcpSummary, setMcpServer, removeMcpServer } from '../features/mcp.js';
import { logInfo } from '../core/logger.js';

// ── Prompt loader ─────────────────────────────────────────────────────────────

function loadAssistantPrompt(scriptDir, harnDir) {
  // 1. Custom prompt in .harn/prompts/
  if (harnDir) {
    const custom = join(harnDir, 'prompts', 'assistant.md');
    if (existsSync(custom)) return readFileSync(custom, 'utf-8');
  }

  // 2. Built-in prompt
  const builtIn = join(scriptDir, 'prompts', 'assistant.md');
  if (existsSync(builtIn)) return readFileSync(builtIn, 'utf-8');

  return '';
}

// ── Context builder ───────────────────────────────────────────────────────────

function buildContext({ harnDir, rootDir, configFile }) {
  const config = loadConfig(configFile);
  const sd = getBacklogDir(rootDir);
  ensureBacklogDir(sd);
  const bl = readBacklog(sd);

  const parts = ['## Current Project State\n'];

  // Backlog summary
  parts.push(`### Backlog`);
  if (bl.pending.length) {
    parts.push(`**Pending (${bl.pending.length}):**`);
    for (const it of bl.pending) parts.push(`- \`${it.slug}\` — ${it.description || '(no description)'}`);
  } else {
    parts.push('**Pending:** (empty)');
  }
  if (bl.in_progress.length) {
    parts.push(`\n**In Progress (${bl.in_progress.length}):**`);
    for (const it of bl.in_progress) parts.push(`- \`${it.slug}\` — ${it.description || '(no description)'}`);
  }
  if (bl.done.length) {
    parts.push(`\n**Done (${bl.done.length}):** ${bl.done.map(i => '`' + i.slug + '`').join(', ')}`);
  }

  // Active run
  const curId = currentRunId(harnDir);
  if (curId) {
    const runDir = join(harnDir, 'runs', curId);
    const slug = readSafe(join(runDir, 'prompt.txt'));
    const sprint = readSafe(join(runDir, 'current_scope')) || readSafe(join(runDir, 'current_sprint'));
    parts.push(`\n### Active Run`);
    parts.push(`- Run: \`${curId}\`, Item: \`${slug || '?'}\`, Sprint: ${sprint || '?'}`);
  } else {
    parts.push(`\n### Active Run\nNo active run.`);
  }

  // Key config values
  parts.push(`\n### Configuration`);
  const showKeys = ['AI_BACKEND', 'PLANNER_MODEL', 'GENERATOR_IMPL_MODEL',
    'EVALUATOR_QA_MODEL', 'AUXILIARY_MODEL', 'HARN_LANG', 'SPRINT_COUNT', 'MAX_ITERATIONS'];
  for (const k of showKeys) {
    if (config[k]) parts.push(`- ${k} = \`${config[k]}\``);
  }

  // Prompt customization status
  parts.push(`\n### Prompts`);
  const roles = ['planner', 'generator', 'evaluator', 'retrospective', 'assistant'];
  const customDir = join(harnDir, 'prompts');
  for (const role of roles) {
    const customPath = join(customDir, `${role}.md`);
    const isCustom = existsSync(customPath);
    parts.push(`- ${role}: ${isCustom ? '**custom** (.harn/prompts/)' : 'built-in'}`);
  }

  return parts.join('\n');
}

function readSafe(path) {
  try { return readFileSync(path, 'utf-8').trim(); } catch { return ''; }
}

// ── Action parser ─────────────────────────────────────────────────────────────

const ACTION_BLOCK_RE = /```actions\n([\s\S]*?)```/;
const ACTION_LINE_RE = /^(\S+)\s+(\{.*\})\s*$/;

function parseActions(text) {
  const match = ACTION_BLOCK_RE.exec(text);
  if (!match) return [];

  const lines = match[1].trim().split('\n');
  const actions = [];
  for (const line of lines) {
    const m = ACTION_LINE_RE.exec(line.trim());
    if (m) {
      try {
        actions.push({ action: m[1], params: JSON.parse(m[2]) });
      } catch { /* skip malformed JSON */ }
    }
  }
  return actions;
}

function stripActionBlock(text) {
  return text.replace(/```actions\n[\s\S]*?```/g, '').trim();
}

// ── Action executor ───────────────────────────────────────────────────────────

async function executeActions(actions, { harnDir, rootDir, configFile, commandRunner, sse }) {
  const results = [];
  const sd = getBacklogDir(rootDir);
  ensureBacklogDir(sd);

  for (const { action, params } of actions) {
    try {
      const result = await executeSingle(action, params, { sd, harnDir, rootDir, configFile, commandRunner, sse });
      results.push({ action, ok: true, result });
    } catch (e) {
      results.push({ action, ok: false, error: e.message });
    }
  }
  return results;
}

async function executeSingle(action, params, { sd, harnDir, rootDir, configFile, commandRunner, sse }) {
  switch (action) {
    // ── Backlog ──
    case 'backlog:add': {
      const extra = params.extra || {};
      const ok = addItem(sd, params.slug, params.description || '', params.plan || '', extra);
      if (sse) sse.broadcastLog(`✓ Added backlog item: ${params.slug}`);
      return ok ? `Added "${params.slug}"` : `"${params.slug}" already exists`;
    }
    case 'backlog:remove': {
      const ok = removeItem(sd, params.slug);
      if (sse) sse.broadcastLog(`✓ Removed backlog item: ${params.slug}`);
      return ok ? `Removed "${params.slug}"` : `"${params.slug}" not found`;
    }
    case 'backlog:update': {
      const { slug, ...updates } = params;
      const ok = updateItem(sd, slug, updates);
      if (sse) sse.broadcastLog(`✓ Updated backlog item: ${slug}`);
      return ok ? `Updated "${slug}"` : `"${slug}" not found`;
    }
    case 'backlog:move': {
      const res = moveItemSection(sd, params.slug, '', params.to);
      if (sse) sse.broadcastLog(`✓ Moved ${params.slug} → ${params.to}`);
      return res;
    }

    // ── Sprint (fire-and-forget — runs in background, progress via SSE) ──
    case 'sprint:start': {
      if (sse) sse.broadcastLog(`▶ Starting sprint: ${params.slug || 'auto'}`);
      commandRunner('start', [params.slug]).catch((e) => {
        if (sse) sse.broadcastLog(`⚠ Sprint error: ${e.message}`);
      });
      return 'started';
    }
    case 'sprint:auto': {
      if (sse) sse.broadcastLog('▶ Running auto mode…');
      commandRunner('auto', []).catch((e) => {
        if (sse) sse.broadcastLog(`⚠ Sprint error: ${e.message}`);
      });
      return 'started';
    }
    case 'sprint:all': {
      if (sse) sse.broadcastLog('▶ Running all pending items…');
      commandRunner('all', []).catch((e) => {
        if (sse) sse.broadcastLog(`⚠ Sprint error: ${e.message}`);
      });
      return 'started';
    }
    case 'sprint:resume': {
      if (sse) sse.broadcastLog('▶ Resuming sprint…');
      commandRunner('resume', []).catch((e) => {
        if (sse) sse.broadcastLog(`⚠ Sprint error: ${e.message}`);
      });
      return 'started';
    }
    case 'sprint:stop': {
      if (sse) sse.broadcastLog('⏹ Stopping sprint…');
      return commandRunner('stop', []);
    }
    case 'sprint:discover': {
      if (sse) sse.broadcastLog('🔍 Discovering new tasks…');
      return commandRunner('discover', []);
    }

    // ── Config ──
    case 'config:set': {
      const config = loadConfig(configFile);
      config[params.key] = params.value;
      saveConfig(configFile, config);
      if (sse) sse.broadcastLog(`✓ Config: ${params.key} = ${params.value}`);
      return `Set ${params.key} = ${params.value}`;
    }
    case 'config:get': {
      const config = loadConfig(configFile);
      return config[params.key] ?? '(not set)';
    }

    // ── Prompts ──
    case 'prompt:customize': {
      const { role, content } = params;
      const validRoles = ['planner', 'generator', 'evaluator', 'retrospective', 'assistant'];
      if (!validRoles.includes(role)) return `Invalid role: ${role}. Valid: ${validRoles.join(', ')}`;
      if (!content) return 'Content is required';
      const customDir = join(harnDir, 'prompts');
      if (!existsSync(customDir)) mkdirSync(customDir, { recursive: true });
      writeFileSync(join(customDir, `${role}.md`), content, 'utf-8');
      if (sse) sse.broadcastLog(`✓ Customized ${role} prompt → .harn/prompts/${role}.md`);
      return `Custom ${role} prompt saved to .harn/prompts/${role}.md`;
    }
    case 'prompt:reset': {
      const { role } = params;
      const customPath = join(harnDir, 'prompts', `${role}.md`);
      if (existsSync(customPath)) {
        unlinkSync(customPath);
        if (sse) sse.broadcastLog(`✓ Reset ${role} prompt to built-in`);
        return `Reset ${role} prompt to built-in default`;
      }
      return `${role} prompt is already using built-in default`;
    }

    // ── Info ──
    case 'info:status': {
      const config = loadConfig(configFile);
      const curId = currentRunId(harnDir);
      const bl = readBacklog(sd);
      const parts = [];
      parts.push(`Pending: ${bl.pending.length}, In Progress: ${bl.in_progress.length}, Done: ${bl.done.length}`);
      if (curId) parts.push(`Active run: ${curId}`);
      else parts.push('No active run');
      return parts.join('\n');
    }
    case 'info:backlog': {
      const bl = readBacklog(sd);
      const lines = [];
      if (bl.pending.length) {
        lines.push(`**Pending (${bl.pending.length}):**`);
        for (const it of bl.pending) lines.push(`- \`${it.slug}\` — ${it.summary || it.description || '(no description)'}`);
      }
      if (bl.in_progress.length) {
        lines.push(`**In Progress (${bl.in_progress.length}):**`);
        for (const it of bl.in_progress) lines.push(`- \`${it.slug}\` — ${it.summary || it.description || '(no description)'}`);
      }
      if (bl.done.length) {
        lines.push(`**Done (${bl.done.length}):**`);
        for (const it of bl.done) lines.push(`- \`${it.slug}\``);
      }
      return lines.length ? lines.join('\n') : 'Backlog is empty.';
    }
    case 'info:runs': {
      const runs = listRuns(harnDir);
      if (!runs.length) return 'No runs yet.';
      const lines = [];
      for (const id of runs.slice(0, 10)) {
        const runDir = join(harnDir, 'runs', id);
        const slug = readSafe(join(runDir, 'prompt.txt'));
        const sprint = readSafe(join(runDir, 'current_scope')) || readSafe(join(runDir, 'current_sprint'));
        lines.push(`- \`${id}\` ${slug ? `(${slug})` : ''} ${sprint ? `sprint ${sprint}` : ''}`);
      }
      return lines.join('\n');
    }
    case 'info:memory': {
      const mem = memoryLoad(harnDir);
      return mem || 'No project memory yet.';
    }

    // ── MCP ──
    case 'mcp:list': {
      const servers = getMcpSummary(rootDir);
      if (!servers.length) return 'No MCP servers configured.';
      const lines = [];
      let lastCli = '';
      for (const s of servers) {
        if (s.cli !== lastCli) { lines.push(`\n**${s.cli}:**`); lastCli = s.cli; }
        lines.push(`- \`${s.name}\` (${s.type}, ${s.scope}) — ${s.url || s.command || '?'}`);
      }
      return lines.join('\n').trim();
    }
    case 'mcp:add': {
      const { cli, scope, name, config: srvConfig } = params;
      if (!cli || !name || !srvConfig) return 'Missing cli, name, or config';
      try {
        setMcpServer(rootDir, cli, scope || 'project', name, srvConfig);
        if (sse) sse.broadcastLog(`✓ Added MCP server: ${name} → ${cli} (${scope || 'project'})`);
        return `Added MCP server "${name}" for ${cli} (${scope || 'project'})`;
      } catch (e) { return `Failed: ${e.message}`; }
    }
    case 'mcp:remove': {
      const { cli, scope, name } = params;
      if (!cli || !name) return 'Missing cli or name';
      try {
        const ok = removeMcpServer(rootDir, cli, scope || 'project', name);
        if (sse) sse.broadcastLog(`✓ Removed MCP server: ${name} from ${cli}`);
        return ok ? `Removed "${name}" from ${cli}` : `Server "${name}" not found in ${cli}`;
      } catch (e) { return `Failed: ${e.message}`; }
    }

    default:
      return `Unknown action: ${action}`;
  }
}

// ── Main chat handler ─────────────────────────────────────────────────────────

/**
 * Process a user chat message through the AI assistant.
 *
 * @param {string} message - user input
 * @param {object} opts
 * @param {string} opts.harnDir
 * @param {string} opts.rootDir
 * @param {string} opts.configFile
 * @param {string} opts.scriptDir
 * @param {function} opts.commandRunner
 * @param {object} opts.sse
 * @param {Array<{role: string, text: string}>} [opts.history] - previous conversation turns
 * @returns {Promise<{reply: string, actions: Array}>}
 */
export async function chat(message, { harnDir, rootDir, configFile, scriptDir, commandRunner, sse, history = [] }) {
  const config = loadConfig(configFile);
  const usedBackend = config.AI_BACKEND || detectAiCli() || 'copilot';
  const usedModel = config.AUXILIARY_MODEL || config.PLANNER_MODEL || '';

  // Build the full prompt: system + context + history + user message
  const systemPrompt = loadAssistantPrompt(scriptDir, harnDir);
  const context = buildContext({ harnDir, rootDir, configFile });

  // Build conversation history section (last 10 turns, max 8000 chars)
  let historySection = '';
  if (history.length > 0) {
    const recentHistory = history.slice(-10);
    const lines = [];
    let charCount = 0;
    const MAX_HISTORY_CHARS = 8000;
    for (const turn of recentHistory) {
      const label = turn.role === 'user' ? 'User' : 'Assistant';
      const truncated = turn.text.length > 1000 ? turn.text.slice(0, 1000) + '...' : turn.text;
      const line = `**${label}:** ${truncated}`;
      if (charCount + line.length > MAX_HISTORY_CHARS) break;
      lines.push(line);
      charCount += line.length;
    }
    if (lines.length > 0) {
      historySection = `\n\n## Conversation History\n\nBelow is the recent conversation. Use this to maintain context and continuity.\n\n${lines.join('\n\n')}`;
    }
  }

  // Inject current prompt contents when user mentions prompts/customization
  let promptContext = '';
  const promptKeywords = /prompt|프롬프트|planner|generator|evaluator|retrospective|assistant/i;
  if (promptKeywords.test(message)) {
    const roles = ['planner', 'generator', 'evaluator', 'retrospective', 'assistant'];
    const customDir = join(harnDir, 'prompts');
    const builtinDir = join(scriptDir, 'prompts');
    const snippets = [];
    for (const role of roles) {
      const customPath = join(customDir, `${role}.md`);
      const builtinPath = join(builtinDir, `${role}.md`);
      let content = '';
      if (existsSync(customPath)) content = readFileSync(customPath, 'utf-8');
      else if (existsSync(builtinPath)) content = readFileSync(builtinPath, 'utf-8');
      if (content) snippets.push(`### ${role}.md (current)\n\`\`\`\n${content}\n\`\`\``);
    }
    if (snippets.length) {
      promptContext = `\n\n## Current Prompts\n\nBelow are the current prompt files. When the user asks to customize a prompt, read the current content, apply their requested changes, and output the FULL updated content in the prompt:customize action.\n\n${snippets.join('\n\n')}`;
    }
  }

  const fullPrompt = [
    systemPrompt,
    '\n\n---\n\n',
    context,
    historySection,
    promptContext,
    '\n\n---\n\n',
    `## User Message\n\n${message}`,
  ].join('');

  // Call AI
  let rawOutput = '';
  try {
    const result = await aiGenerate({
      prompt: fullPrompt,
      backend: config.AI_BACKEND,
      model: config.AUXILIARY_MODEL || config.PLANNER_MODEL,
      cwd: rootDir,
    });

    rawOutput = result?.output || '';

    // If AI returned non-zero exit code with no useful output, surface the error
    if (!rawOutput.trim() && result?.exitCode !== 0) {
      return {
        reply: `I couldn't process your request — the AI backend returned no output (exit code ${result?.exitCode}). Please check your AI CLI configuration in Settings.`,
        actions: [],
      };
    }
  } catch (e) {
    // No AI CLI available or invocation failed
    const errMsg = e.message || String(e);
    if (errMsg.includes('No AI CLI found')) {
      return {
        reply: `**No AI CLI detected.** Please install one of: \`copilot\`, \`claude\`, \`codex\`, or \`gemini\` CLI, and make sure it's in your PATH.\n\nYou can also set \`AI_BACKEND\` in Settings to specify which one to use.`,
        actions: [],
      };
    }
    return {
      reply: `Error communicating with AI: ${errMsg}`,
      actions: [],
    };
  }

  // If output is empty, provide a helpful response
  if (!rawOutput.trim()) {
    return {
      reply: `I received an empty response from the AI. This usually means the AI CLI isn't configured properly. Check Settings → Models to ensure a valid model is selected.`,
      actions: [],
    };
  }

  // Parse actions from the response
  const actions = parseActions(rawOutput);
  const reply = stripActionBlock(rawOutput);

  // Execute any actions
  let actionResults = [];
  if (actions.length > 0) {
    logInfo(`Assistant dispatching ${actions.length} action(s): ${actions.map(a => a.action).join(', ')}`);
    actionResults = await executeActions(actions, {
      harnDir, rootDir, configFile, commandRunner, sse,
    });
  }

  return { reply, actions: actionResults, backend: usedBackend, model: usedModel };
}
