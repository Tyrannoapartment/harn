/**
 * MCP (Model Context Protocol) configuration management.
 * Reads/writes MCP server configs for various AI CLIs.
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

// ── Known MCP config locations ──────────────────────────────────────────────

const HOME = homedir();

/**
 * Per-CLI configuration paths and format details.
 * Each entry describes where to find/write MCP config.
 */
const CLI_MCP_PATHS = {
  copilot: {
    global: join(HOME, '.copilot', 'mcp-config.json'),
    project: (rootDir) => join(rootDir, '.github', 'copilot', 'mcp.json'),
    format: 'mcpServers',  // top-level key
  },
  claude: {
    global: join(HOME, '.claude.json'),
    project: (rootDir) => join(rootDir, '.mcp.json'),
    format: 'mcpServers',
  },
  codex: {
    global: join(HOME, '.codex', 'mcp-config.json'),
    project: (rootDir) => join(rootDir, '.codex', 'mcp.json'),
    format: 'mcpServers',
  },
  gemini: {
    global: join(HOME, '.gemini', 'settings.json'),
    project: (rootDir) => join(rootDir, '.gemini', 'mcp.json'),
    format: 'mcpServers',
  },
};

// ── Helpers ──────────────────────────────────────────────────────────────────

function readJsonSafe(filePath) {
  try {
    if (!existsSync(filePath)) return null;
    return JSON.parse(readFileSync(filePath, 'utf-8'));
  } catch {
    return null;
  }
}

function writeJsonSafe(filePath, data) {
  const dir = join(filePath, '..');
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf-8');
}

/**
 * Extract mcpServers from a config JSON.
 * Handles both { mcpServers: {...} } and flat formats.
 */
function extractServers(json) {
  if (!json || typeof json !== 'object') return {};
  if (json.mcpServers && typeof json.mcpServers === 'object') return json.mcpServers;
  return {};
}

// ── Public API ──────────────────────────────────────────────────────────────

/**
 * Get MCP configuration for all known CLIs.
 * @param {string} rootDir - Project root directory
 * @returns {{ [cli: string]: { global: object, project: object, globalPath: string, projectPath: string } }}
 */
export function getMcpConfigs(rootDir) {
  const result = {};

  for (const [cli, paths] of Object.entries(CLI_MCP_PATHS)) {
    const globalPath = paths.global;
    const projectPath = paths.project(rootDir);

    const globalJson = readJsonSafe(globalPath);
    const projectJson = readJsonSafe(projectPath);

    result[cli] = {
      globalPath,
      projectPath,
      global: extractServers(globalJson),
      project: extractServers(projectJson),
      globalExists: existsSync(globalPath),
      projectExists: existsSync(projectPath),
    };
  }

  return result;
}

/**
 * Get MCP servers for a specific CLI (merged: project overrides global).
 */
export function getMcpServersForCli(rootDir, cli) {
  const paths = CLI_MCP_PATHS[cli];
  if (!paths) return {};

  const globalJson = readJsonSafe(paths.global);
  const projectJson = readJsonSafe(paths.project(rootDir));

  return {
    ...extractServers(globalJson),
    ...extractServers(projectJson),
  };
}

/**
 * Add or update an MCP server.
 * @param {'global'|'project'} scope
 */
export function setMcpServer(rootDir, cli, scope, serverName, serverConfig) {
  const paths = CLI_MCP_PATHS[cli];
  if (!paths) throw new Error(`Unknown CLI: ${cli}`);

  const filePath = scope === 'global' ? paths.global : paths.project(rootDir);
  const json = readJsonSafe(filePath) || {};
  if (!json.mcpServers) json.mcpServers = {};
  json.mcpServers[serverName] = serverConfig;
  writeJsonSafe(filePath, json);
  return true;
}

/**
 * Remove an MCP server.
 */
export function removeMcpServer(rootDir, cli, scope, serverName) {
  const paths = CLI_MCP_PATHS[cli];
  if (!paths) throw new Error(`Unknown CLI: ${cli}`);

  const filePath = scope === 'global' ? paths.global : paths.project(rootDir);
  const json = readJsonSafe(filePath);
  if (!json?.mcpServers?.[serverName]) return false;
  delete json.mcpServers[serverName];
  writeJsonSafe(filePath, json);
  return true;
}

/**
 * Get a summary of all MCP servers across all CLIs (for dashboard display).
 */
export function getMcpSummary(rootDir) {
  const configs = getMcpConfigs(rootDir);
  const servers = [];

  for (const [cli, data] of Object.entries(configs)) {
    // Global servers
    for (const [name, config] of Object.entries(data.global)) {
      servers.push({
        name,
        cli,
        scope: 'global',
        type: config.type || (config.command ? 'stdio' : 'http'),
        url: config.url || null,
        command: config.command || null,
        args: config.args || [],
        env: config.env || {},
      });
    }
    // Project servers (may override global)
    for (const [name, config] of Object.entries(data.project)) {
      const existing = servers.findIndex((s) => s.name === name && s.cli === cli);
      const entry = {
        name,
        cli,
        scope: 'project',
        type: config.type || (config.command ? 'stdio' : 'http'),
        url: config.url || null,
        command: config.command || null,
        args: config.args || [],
        env: config.env || {},
      };
      if (existing >= 0) servers[existing] = entry;
      else servers.push(entry);
    }
  }

  return servers;
}
