/**
 * Express server entry point.
 * Replaces server/harn_server.py
 */

import express from 'express';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';
import { createSSEManager } from './sse.js';
import { createApiRouter } from './routes/api.js';
import { logOk, logInfo } from '../core/logger.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

export async function startServer({ port = 7111, harnDir, rootDir, configFile, commandRunner, openBrowser = true }) {
  const app = express();
  const sse = createSSEManager();

  app.use(express.json());

  // CORS
  app.use((_req, res, next) => {
    res.header('Access-Control-Allow-Origin', '*');
    res.header('Access-Control-Allow-Headers', 'Content-Type');
    res.header('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE');
    next();
  });

  // API routes
  const apiRouter = createApiRouter({ harnDir, rootDir, configFile, sse, commandRunner });
  app.use('/api', apiRouter);

  // Serve web frontend (production build)
  const webDist = join(__dirname, '..', '..', 'web', 'dist');
  if (existsSync(webDist)) {
    app.use(express.static(webDist));
    app.get('*', (_req, res) => {
      res.sendFile(join(webDist, 'index.html'));
    });
  } else {
    app.get('/', (_req, res) => {
      res.send('<h1>harn</h1><p>Web frontend not built. Run <code>npm run build:web</code>.</p>');
    });
  }

  return new Promise((resolve) => {
    const server = app.listen(port, () => {
      logOk(`Server running on http://localhost:${port}`);
      if (openBrowser) {
        import('open').then((mod) => mod.default(`http://localhost:${port}`)).catch(() => {});
      }
      resolve({ app, server, sse });
    });
  });
}
