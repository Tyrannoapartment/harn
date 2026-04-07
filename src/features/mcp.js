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
    format: 'json',
  },
  claude: {
    global: join(HOME, '.claude.json'),
    project: (rootDir) => join(rootDir, '.mcp.json'),
    format: 'json',
  },
  codex: {
    global: join(HOME, '.codex', 'config.toml'),
    project: (rootDir) => join(rootDir, '.codex', 'config.toml'),
    format: 'toml',
  },
  gemini: {
    global: join(HOME, '.gemini', 'settings.json'),
    project: (rootDir) => join(rootDir, '.gemini', 'mcp.json'),
    format: 'json',
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

/**
 * Minimal TOML parser for codex config.toml.
 * Extracts [mcp_servers.*] sections into { name: { url, command, args, env, ... } }
 */
function parseTomlMcpServers(filePath) {
  try {
    if (!existsSync(filePath)) return {};
    const content = readFileSync(filePath, 'utf-8');
    const servers = {};
    // Match [mcp_servers.NAME] or any [section] headers
    const sectionRe = /^\[mcp_servers\.([^\]]+)\]\s*$/gm;
    const anySectionRe = /^\[/gm;
    let match;
    const sections = [];
    while ((match = sectionRe.exec(content)) !== null) {
      sections.push({ name: match[1], start: match.index + match[0].length });
    }
    // Find all section header positions for boundary detection
    const allSectionStarts = [];
    while ((match = anySectionRe.exec(content)) !== null) {
      allSectionStarts.push(match.index);
    }
    for (let i = 0; i < sections.length; i++) {
      // End at the next section header (any [xxx]) after our start
      const nextSection = allSectionStarts.find(pos => pos > sections[i].start);
      const end = nextSection !== undefined ? nextSection : content.length;
      const block = content.slice(sections[i].start, end);
      const server = {};
      for (const line of block.split('\n')) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith('#') || trimmed.startsWith('[')) continue;
        const eqIdx = trimmed.indexOf('=');
        if (eqIdx === -1) continue;
        const key = trimmed.slice(0, eqIdx).trim();
        let val = trimmed.slice(eqIdx + 1).trim();
        // Parse value
        if (val.startsWith('"') && val.endsWith('"')) {
          val = val.slice(1, -1);
        } else if (val.startsWith('[')) {
          // Parse TOML array
          try {
            val = JSON.parse(val.replace(/'/g, '"'));
          } catch {
            val = val.slice(1, -1).split(',').map(s => s.trim().replace(/^["']|["']$/g, '')).filter(Boolean);
          }
        } else if (val.startsWith('{')) {
          // Parse inline table
          try {
            const jsonStr = val
              .replace(/([\w_]+)\s*=/g, '"$1":')
              .replace(/'/g, '"');
            val = JSON.parse(jsonStr);
          } catch {
            // keep as string
          }
        }
        server[key] = val;
      }
      servers[sections[i].name] = server;
    }
    return servers;
  } catch {
    return {};
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

/**
 * Read MCP servers from a config file, handling both JSON and TOML formats.
 */
function readServers(filePath, format) {
  if (format === 'toml') {
    return parseTomlMcpServers(filePath);
  }
  return extractServers(readJsonSafe(filePath));
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

    result[cli] = {
      globalPath,
      projectPath,
      global: readServers(globalPath, paths.format),
      project: readServers(projectPath, paths.format),
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

  return {
    ...readServers(paths.global, paths.format),
    ...readServers(paths.project(rootDir), paths.format),
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

/**
 * Check if a Figma MCP server is configured in any CLI.
 * Looks for server names containing 'figma' (case-insensitive).
 * @returns {{ found: boolean, servers: Array<{ name, cli, scope, type }> }}
 */
export function checkFigmaMcp(rootDir) {
  const all = getMcpSummary(rootDir);
  const figmaServers = all.filter((s) =>
    /figma/i.test(s.name) || /figma/i.test(s.command || '') || /figma/i.test(s.url || '')
  );
  return {
    found: figmaServers.length > 0,
    servers: figmaServers.map((s) => ({
      name: s.name,
      cli: s.cli,
      scope: s.scope,
      type: s.type,
      command: s.command,
      url: s.url,
    })),
  };
}
