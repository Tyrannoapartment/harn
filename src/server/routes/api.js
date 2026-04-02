/**
 * REST API routes.
 * Replaces routes from harn_server.py
 */

import { Router } from 'express';
import { readFileSync, existsSync, writeFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { loadConfig, saveConfig } from '../../core/config.js';
import { pendingSlugs, inProgressSlug, addItem } from '../../backlog/backlog.js';
import { listRuns, currentRunDir } from '../../run/run.js';
import { memoryLoad, memoryAppend } from '../../features/memory.js';
import { aiGenerate } from '../../ai/backend.js';

export function createApiRouter({ harnDir, rootDir, configFile, sse, commandRunner }) {
  const router = Router();

  // ─── Health ───
  router.get('/health', (_req, res) => {
    res.json({ status: 'ok', version: process.env.npm_package_version || '2.0.0' });
  });

  // ─── Status ───
  router.get('/status', (_req, res) => {
    const config = loadConfig(configFile);
    const curDir = currentRunDir(harnDir);
    let active = null;
    if (curDir) {
      active = {
        slug: readSafe(join(curDir, 'prompt.txt')),
        sprint: readSafe(join(curDir, 'current_sprint')),
        plan: readSafe(join(curDir, 'plan.txt')),
      };
    }
    const backlogFile = config.BACKLOG_FILE;
    const pending = existsSync(backlogFile) ? pendingSlugs(backlogFile) : [];
    const ip = existsSync(backlogFile) ? inProgressSlug(backlogFile) : null;
    res.json({ active, pending, inProgress: ip, config });
  });

  // ─── Backlog ───
  router.get('/backlog', (_req, res) => {
    const config = loadConfig(configFile);
    const backlogFile = config.BACKLOG_FILE;
    if (!existsSync(backlogFile)) return res.json({ items: [] });
    const content = readFileSync(backlogFile, 'utf-8');
    const items = [];

    // Parse pending items
    const pendingMatch = content.match(/## Pending([\s\S]*?)(?=##|$)/);
    if (pendingMatch) {
      const lines = pendingMatch[1].split('\n');
      let current = null;
      for (const line of lines) {
        const slugMatch = line.match(/- \[ \] \*\*(.+?)\*\*/);
        if (slugMatch) {
          if (current) items.push(current);
          current = { slug: slugMatch[1], description: '', status: 'pending' };
        } else if (current && line.trim() && !line.match(/^\s*plan:/)) {
          current.description = line.trim();
        } else if (current && line.match(/^\s*plan:/)) {
          current.plan = line.replace(/^\s*plan:\s*/, '').trim();
        }
      }
      if (current) items.push(current);
    }

    // Parse in-progress
    const ipMatch = content.match(/## In Progress([\s\S]*?)(?=##|$)/);
    if (ipMatch) {
      const lines = ipMatch[1].split('\n');
      let current = null;
      for (const line of lines) {
        const slugMatch = line.match(/- \[.\] \*\*(.+?)\*\*/);
        if (slugMatch) {
          if (current) items.push(current);
          current = { slug: slugMatch[1], description: '', status: 'in-progress' };
        } else if (current && line.trim() && !line.match(/^\s*plan:/)) {
          current.description = line.trim();
        } else if (current && line.match(/^\s*plan:/)) {
          current.plan = line.replace(/^\s*plan:\s*/, '').trim();
        }
      }
      if (current) items.push(current);
    }

    // Parse done
    const doneMatch = content.match(/## Done([\s\S]*?)(?=##|$)/);
    if (doneMatch) {
      const lines = doneMatch[1].split('\n');
      let current = null;
      for (const line of lines) {
        const slugMatch = line.match(/- \[x\] \*\*(.+?)\*\*/i);
        if (slugMatch) {
          if (current) items.push(current);
          current = { slug: slugMatch[1], description: '', status: 'done' };
        } else if (current && line.trim() && !line.match(/^\s*plan:/)) {
          current.description = line.trim();
        }
      }
      if (current) items.push(current);
    }

    res.json({ items });
  });

  router.post('/backlog/add', async (req, res) => {
    const { slug, description } = req.body;
    if (!slug) return res.status(400).json({ error: 'slug required' });
    const config = loadConfig(configFile);
    addItem(config.BACKLOG_FILE, slug, description || '');
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
        '\nOutput as JSON array: [{"slug": "kebab-case", "description": "text"}]',
      ].join('\n');
      const output = await aiGenerate({ prompt, backend: config.AI_BACKEND, model: config.COPILOT_MODEL_PLANNER, cwd: rootDir });
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
    const { action } = req.body; // 'remove', 'moveUp', 'moveDown'
    // Simple implementation — would need backlog module support
    res.json({ ok: true, slug, action });
  });

  // ─── Runs ───
  router.get('/runs', (_req, res) => {
    const runs = listRuns(harnDir);
    const curDir = currentRunDir(harnDir);
    const curId = curDir ? curDir.split('/').pop() : null;

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
            });
          }
        } catch { /* skip */ }
      }
      return {
        id: r,
        prompt: readSafe(join(dir, 'prompt.txt')),
        plan: readSafe(join(dir, 'plan.txt')),
        sprints,
        active: r === curId,
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

  // ─── Memory ───
  router.get('/memory', (_req, res) => {
    res.json({ content: memoryLoad(harnDir) });
  });

  router.post('/memory', (req, res) => {
    const { content } = req.body;
    if (content) memoryAppend(harnDir, content);
    res.json({ ok: true });
  });

  // ─── Commands ───
  router.post('/command', async (req, res) => {
    const { command, args } = req.body;
    if (!command) return res.status(400).json({ error: 'command required' });
    try {
      const result = await commandRunner(command, args || []);
      res.json({ ok: true, result });
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  });

  router.post('/command/stop', (_req, res) => {
    // Signal stop by writing a stop file
    const curDir = currentRunDir(harnDir);
    if (curDir) {
      writeFileSync(join(curDir, '.stop'), '');
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

  return router;
}

function readSafe(path) {
  try { return readFileSync(path, 'utf-8').trim(); } catch { return ''; }
}
