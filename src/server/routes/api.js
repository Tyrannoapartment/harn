/**
 * REST API routes.
 * Replaces routes from harn_server.py
 */

import { Router } from 'express';
import { readFileSync, existsSync, writeFileSync, readdirSync, mkdirSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, saveConfig, getSprintDir } from '../../core/config.js';
import { pendingSlugs, addItem, removeItem, updateItem, readBacklog, ensureSprintDir } from '../../backlog/backlog.js';
import { listRuns, currentRunId } from '../../run/run.js';
import { memoryLoad, memoryAppend } from '../../features/memory.js';
import { aiGenerate, getModelsForBackend, refreshModelCache, detectAiCli, getFallbackModels, checkBackendHealth, getAllBackendModels } from '../../ai/backend.js';
import { chat as assistantChat } from '../../features/assistant.js';
import { getMcpConfigs, getMcpSummary, setMcpServer, removeMcpServer } from '../../features/mcp.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const SCRIPT_DIR = resolve(__dirname, '..', '..', '..');

export function createApiRouter({ harnDir, rootDir, configFile, scriptDir, sse, commandRunner }) {
  const router = Router();

  // ─── Health ───
  router.get('/health', (_req, res) => {
    res.json({ status: 'ok', version: process.env.npm_package_version || '2.0.0' });
  });

  // ─── Status ───
  router.get('/status', (_req, res) => {
    const config = loadConfig(configFile);
    const curDir = (() => { const id = currentRunId(harnDir); return id ? join(harnDir, "runs", id) : null; })();

    // Check if actually running via harn.pid
    let isRunning = false;
    const pidFile = join(harnDir, 'harn.pid');
    if (existsSync(pidFile)) {
      try {
        const pid = parseInt(readFileSync(pidFile, 'utf-8').trim(), 10);
        process.kill(pid, 0); // signal 0 = check if alive
        isRunning = true;
      } catch {
        isRunning = false;
      }
    }

    let active = null;
    if (curDir) {
      active = {
        slug: readSafe(join(curDir, 'prompt.txt')),
        sprint: readSafe(join(curDir, 'current_sprint')),
        plan: readSafe(join(curDir, 'plan.txt')),
        completed: existsSync(join(curDir, 'completed')),
      };
    }
    const sd = getSprintDir(rootDir);
    ensureSprintDir(sd);
    const pending = pendingSlugs(sd);
    const bl = readBacklog(sd);
    const ip = bl.in_progress[0]?.slug || null;
    res.json({ active, pending, inProgress: ip, config, rootDir, isRunning });
  });

  // ─── Backlog ───
  router.get('/backlog', (_req, res) => {
    const sd = getSprintDir(rootDir);
    ensureSprintDir(sd);
    const bl = readBacklog(sd);
    const mapItem = (i, status) => ({
      slug: i.slug,
      summary: i.summary || '',
      description: i.description || '',
      affectedFiles: i.affectedFiles || '',
      implementationGuide: i.implementationGuide || '',
      acceptanceCriteria: i.acceptanceCriteria || '',
      plan: i.plan || '',
      raw: i.raw || '',
      status,
    });
    const items = [
      ...bl.pending.map((i) => mapItem(i, 'pending')),
      ...bl.in_progress.map((i) => mapItem(i, 'in-progress')),
      ...bl.done.map((i) => mapItem(i, 'done')),
    ];
    res.json({ items });
  });

  router.post('/backlog/add', async (req, res) => {
    const { slug, description, plan, summary, affectedFiles, implementationGuide, acceptanceCriteria } = req.body;
    if (!slug) return res.status(400).json({ error: 'slug required' });
    const sd = getSprintDir(rootDir);
    ensureSprintDir(sd);
    addItem(sd, slug, description || '', plan || '', { summary, affectedFiles, implementationGuide, acceptanceCriteria });
    res.json({ ok: true, slug });
  });

  router.post('/backlog/enhance', async (req, res) => {
    const { description } = req.body;
    if (!description) return res.status(400).json({ error: 'description required' });
    const config = loadConfig(configFile);
    try {
      const prompt = [
        'Generate 1-3 sprint backlog items based on this description:',
        description,
        '\nOutput as JSON array with these fields:',
        '[{"slug": "kebab-case-id", "summary": "one-line summary", "description": "detailed description", "affectedFiles": "- path/to/file1\\n- path/to/file2", "implementationGuide": "step-by-step guide", "acceptanceCriteria": "- [ ] criterion 1\\n- [ ] criterion 2"}]',
        '\nOnly output the JSON array, no extra text.',
      ].join('\n');
      const result = await aiGenerate({ prompt, backend: config.AI_BACKEND, model: config.COPILOT_MODEL_PLANNER, cwd: rootDir });
      const output = result?.output || '';
      const match = output.match(/\[[\s\S]*?\]/);
      if (match) {
        res.json({ items: JSON.parse(match[0]) });
      } else {
        res.json({ items: [], raw: output });
      }
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  });

  router.patch('/backlog/:slug', (req, res) => {
    const { slug } = req.params;
    const { description, plan, newSlug, summary, affectedFiles, implementationGuide, acceptanceCriteria } = req.body;
    const sd = getSprintDir(rootDir);
    ensureSprintDir(sd);
    const ok = updateItem(sd, slug, { newSlug, summary, description, affectedFiles, implementationGuide, acceptanceCriteria, plan });
    if (!ok) return res.status(404).json({ error: 'item not found' });
    res.json({ ok: true, slug: newSlug || slug });
  });

  router.delete('/backlog/:slug', (req, res) => {
    const { slug } = req.params;
    const sd = getSprintDir(rootDir);
    ensureSprintDir(sd);
    const ok = removeItem(sd, slug);
    if (!ok) return res.status(404).json({ error: 'item not found' });
    res.json({ ok: true, slug });
  });

  // ─── Runs ───
  router.get('/runs', (_req, res) => {
    const runs = listRuns(harnDir);
    const curDir = (() => { const id = currentRunId(harnDir); return id ? join(harnDir, "runs", id) : null; })();
    const curId = curDir ? curDir.split('/').pop() : null;

    // Check if process is actually running
    let isRunning = false;
    const pidFile = join(harnDir, 'harn.pid');
    if (existsSync(pidFile)) {
      try {
        const pid = parseInt(readFileSync(pidFile, 'utf-8').trim(), 10);
        process.kill(pid, 0);
        isRunning = true;
      } catch { isRunning = false; }
    }

    const result = runs.map((r) => {
      const dir = join(harnDir, 'runs', r);
      const sprintsDir = join(dir, 'sprints');
      const sprints = [];
      if (existsSync(sprintsDir)) {
        try {
          const sprintDirs = readdirSync(sprintsDir).sort();
          for (const s of sprintDirs) {
            const sd = join(sprintsDir, s);
            sprints.push({
              number: s,
              status: readSafe(join(sd, 'status')) || 'pending',
              iteration: readSafe(join(sd, 'iteration')) || '0',
              hasContract: existsSync(join(sd, 'contract.md')),
              hasImplementation: existsSync(join(sd, 'implementation.md')),
              hasQAReport: existsSync(join(sd, 'qa-report.md')),
            });
          }
        } catch { /* skip */ }
      }
      const completed = existsSync(join(dir, 'completed'));
      const currentSprint = readSafe(join(dir, 'current_sprint'));
      const totalSprints = readSafe(join(dir, 'sprint_count'));
      return {
        id: r,
        prompt: readSafe(join(dir, 'prompt.txt')),
        plan: readSafe(join(dir, 'plan.txt')),
        sprints,
        currentSprint: currentSprint ? parseInt(currentSprint, 10) : null,
        totalSprints: totalSprints ? parseInt(totalSprints, 10) : null,
        active: r === curId,
        isRunning: r === curId && isRunning,
        completed,
      };
    });
    res.json({ runs: result });
  });

  // ─── Config ───
  router.get('/config', (_req, res) => {
    res.json(loadConfig(configFile));
  });

  router.post('/config', (req, res) => {
    const current = loadConfig(configFile);
    const updated = { ...current, ...req.body };
    saveConfig(configFile, updated);
    res.json(updated);
  });

  // ─── Models ───
  router.get('/models', (_req, res) => {
    const config = loadConfig(configFile);
    res.json({
      planner: config.COPILOT_MODEL_PLANNER || 'claude-haiku-4.5',
      generatorContract: config.COPILOT_MODEL_GENERATOR_CONTRACT || 'claude-sonnet-4.6',
      generatorImpl: config.COPILOT_MODEL_GENERATOR_IMPL || 'claude-opus-4.6',
      evaluatorContract: config.COPILOT_MODEL_EVALUATOR_CONTRACT || 'claude-haiku-4.5',
      evaluatorQA: config.COPILOT_MODEL_EVALUATOR_QA || 'claude-sonnet-4.5',
    });
  });

  router.get('/models/:backend', (req, res) => {
    const { backend } = req.params;
    const models = getModelsForBackend(backend, harnDir);
    res.json({ backend, models });
  });

  router.get('/models/available/all', (_req, res) => {
    const backend = detectAiCli() || 'copilot';
    const models = getModelsForBackend(backend, harnDir);
    res.json({ backend, models });
  });

  router.post('/models/refresh', async (_req, res) => {
    try {
      await refreshModelCache(harnDir);
      const backend = detectAiCli() || 'copilot';
      const models = getModelsForBackend(backend, harnDir);
      res.json({ ok: true, backend, models });
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  });

  // ─── Backends ───
  router.get('/backends', (_req, res) => {
    const health = checkBackendHealth(harnDir);
    const allModels = getAllBackendModels(harnDir);
    const detected = detectAiCli();
    const result = health.map((h) => ({
      ...h,
      models: allModels[h.backend] || [],
      isDefault: h.backend === detected,
    }));
    res.json({ backends: result, detected });
  });

  // ─── Prompts ───
  router.get('/prompts', (_req, res) => {
    // Check custom prompts first, then built-in
    const customDir = join(harnDir, 'prompts');
    const builtinDir = join(SCRIPT_DIR, 'prompts');

    const promptFiles = ['planner.md', 'generator.md', 'evaluator.md', 'retrospective.md', 'assistant.md'];
    const prompts = [];
    for (const file of promptFiles) {
      let content = '';
      let source = 'builtin';
      if (existsSync(join(customDir, file))) {
        content = readFileSync(join(customDir, file), 'utf-8');
        source = 'custom';
      } else if (existsSync(join(builtinDir, file))) {
        content = readFileSync(join(builtinDir, file), 'utf-8');
      }
      prompts.push({ name: file.replace('.md', ''), file, content, source });
    }
    res.json({ prompts });
  });

  router.post('/prompts/:name', (req, res) => {
    const { name } = req.params;
    const { content } = req.body;
    if (!content) return res.status(400).json({ error: 'content required' });
    const customDir = join(harnDir, 'prompts');
    if (!existsSync(customDir)) {
      mkdirSync(customDir, { recursive: true });
    }
    writeFileSync(join(customDir, `${name}.md`), content, 'utf-8');
    res.json({ ok: true, name });
  });

  // ─── Memory ───
  router.get('/memory', (_req, res) => {
    res.json({ content: memoryLoad(harnDir) });
  });

  router.post('/memory', (req, res) => {
    const { content } = req.body;
    if (content) memoryAppend(harnDir, content);
    res.json({ ok: true });
  });

  // ─── Chat / Assistant ───
  router.post('/chat', async (req, res) => {
    const { message, history } = req.body;
    if (!message) return res.status(400).json({ error: 'message required' });

    try {
      const { reply, actions, backend, model } = await assistantChat(message, {
        harnDir, rootDir, configFile, scriptDir, commandRunner, sse, history: history || [],
      });
      res.json({ ok: true, reply, actions, backend, model });
    } catch (e) {
      sse.broadcastLog(`Error: ${e.message}`);
      res.status(500).json({ error: e.message });
    }
  });

  // ─── Commands (direct) ───
  router.post('/command', async (req, res) => {
    const { command, args } = req.body;
    if (!command) return res.status(400).json({ error: 'command required' });
    try {
      sse.broadcastLog(`> harn ${command}`);
      const result = await commandRunner(command, args || []);
      sse.broadcastLog(`Command complete: ${command}`);
      res.json({ ok: true, result });
    } catch (e) {
      sse.broadcastLog(`Error: ${e.message}`);
      res.status(500).json({ error: e.message });
    }
  });

  router.post('/command/stop', (_req, res) => {
    const curDir = (() => { const id = currentRunId(harnDir); return id ? join(harnDir, "runs", id) : null; })();
    if (curDir) {
      writeFileSync(join(curDir, '.stop'), '');
      sse.broadcastLog('Stop signal sent');
      res.json({ ok: true });
    } else {
      res.json({ ok: false, error: 'no active run' });
    }
  });

  // ─── Logs SSE ───
  router.get('/logs/stream', (req, res) => {
    sse.addClient(res);
  });

  // ─── Shutdown ───
  router.post('/shutdown', (_req, res) => {
    res.json({ ok: true });
    setTimeout(() => process.exit(0), 500);
  });

  // ─── MCP Configuration ───
  router.get('/mcp', (_req, res) => {
    try {
      const configs = getMcpConfigs(rootDir);
      const servers = getMcpSummary(rootDir);
      res.json({ configs, servers });
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  });

  router.post('/mcp/server', (req, res) => {
    const { cli, scope, name, config: serverConfig } = req.body;
    if (!cli || !name || !serverConfig) {
      return res.status(400).json({ error: 'cli, name, config required' });
    }
    try {
      setMcpServer(rootDir, cli, scope || 'project', name, serverConfig);
      const servers = getMcpSummary(rootDir);
      res.json({ ok: true, servers });
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  });

  router.delete('/mcp/server', (req, res) => {
    const { cli, scope, name } = req.body;
    if (!cli || !name) {
      return res.status(400).json({ error: 'cli, name required' });
    }
    try {
      const ok = removeMcpServer(rootDir, cli, scope || 'project', name);
      const servers = getMcpSummary(rootDir);
      res.json({ ok, servers });
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  });

  return router;
}

function readSafe(path) {
  try { return readFileSync(path, 'utf-8').trim(); } catch { return ''; }
}
