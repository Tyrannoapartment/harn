const API_BASE = '/api'

async function fetchJSON<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    headers: { 'Content-Type': 'application/json' },
    ...init,
  })
  if (!res.ok) throw new Error(`API ${path}: ${res.status}`)
  return res.json()
}

export interface BacklogItem {
  slug: string
  description: string
  plan?: string
  status: string
}

export interface RunInfo {
  id: string
  prompt: string
  plan: string
  sprints: { number: string; status: string; iteration: string; hasContract?: boolean; hasImplementation?: boolean; hasQAReport?: boolean }[]
  currentSprint: number | null
  totalSprints: number | null
  active: boolean
  isRunning: boolean
  completed: boolean
}

export interface PromptInfo {
  name: string
  file: string
  content: string
  source: 'builtin' | 'custom'
}

export interface BackendInfo {
  backend: string
  installed: boolean
  version: string
  authenticated: boolean
  models: string[]
  isDefault: boolean
}

export interface WrapperInfo {
  installed: boolean
  version: string
  enabled: boolean
}

export interface WrappersStatus {
  omc: WrapperInfo
  omx: WrapperInfo
}

export interface McpServerConfig {
  type?: string
  url?: string
  command?: string
  args?: string[]
  env?: Record<string, string>
}

export interface McpServer {
  name: string
  cli: string
  scope: 'global' | 'project'
  type: string
  url: string | null
  command: string | null
  args: string[]
  env: Record<string, string>
}

export interface McpCliConfig {
  globalPath: string
  projectPath: string
  global: Record<string, McpServerConfig>
  project: Record<string, McpServerConfig>
  globalExists: boolean
  projectExists: boolean
}

export const api = {
  health: () => fetchJSON<{ status: string; version: string }>('/health'),
  status: () => fetchJSON<{ active: unknown; pending: string[]; inProgress: string | null; config: Record<string, string>; rootDir: string; isRunning: boolean }>('/status'),
  getBacklog: () => fetchJSON<{ items: BacklogItem[] }>('/backlog'),
  getRuns: () => fetchJSON<{ runs: RunInfo[] }>('/runs'),
  getConfig: () => fetchJSON<Record<string, string>>('/config'),
  getMemory: () => fetchJSON<{ content: string }>('/memory'),

  saveConfig: (data: Record<string, string>) =>
    fetchJSON<Record<string, string>>('/config', { method: 'POST', body: JSON.stringify(data) }),

  addBacklogItem: (slug: string, description: string, plan?: string, extra?: { summary?: string; affectedFiles?: string; implementationGuide?: string; acceptanceCriteria?: string }) =>
    fetchJSON<{ ok: boolean }>('/backlog/add', { method: 'POST', body: JSON.stringify({ slug, description, plan, ...extra }) }),

  updateBacklogItem: (slug: string, data: { newSlug?: string; summary?: string; description?: string; affectedFiles?: string; implementationGuide?: string; acceptanceCriteria?: string; plan?: string }) =>
    fetchJSON<{ ok: boolean }>(`/backlog/${encodeURIComponent(slug)}`, { method: 'PATCH', body: JSON.stringify(data) }),

  deleteBacklogItem: (slug: string) =>
    fetchJSON<{ ok: boolean }>(`/backlog/${encodeURIComponent(slug)}`, { method: 'DELETE' }),

  // Chat (AI Assistant)
  chat: (message: string, history?: { role: string; text: string }[]) =>
    fetchJSON<{ ok: boolean; reply: string; backend?: string; model?: string; actions: { action: string; ok: boolean; result?: unknown; error?: string }[] }>('/chat', { method: 'POST', body: JSON.stringify({ message, history }) }),

  // Direct commands
  runCommand: (command: string, args?: string[]) =>
    fetchJSON<{ ok: boolean; result?: unknown }>('/command', { method: 'POST', body: JSON.stringify({ command, args }) }),

  startRun: (slug: string) =>
    fetchJSON<{ ok: boolean }>('/command', { method: 'POST', body: JSON.stringify({ command: 'start', args: [slug] }) }),

  stopCommand: () =>
    fetchJSON<{ ok: boolean }>('/command/stop', { method: 'POST' }),

  // Models
  getModels: (backend?: string) =>
    fetchJSON<{ backend: string; models: string[] }>(backend ? `/models/${backend}` : '/models/available/all'),

  refreshModels: () =>
    fetchJSON<{ ok: boolean; backend: string; models: string[] }>('/models/refresh', { method: 'POST' }),

  // Backends (AI CLI health)
  getBackends: () =>
    fetchJSON<{ backends: BackendInfo[]; detected: string }>('/backends'),

  // CLI Wrappers (omc / omx)
  getWrappers: () =>
    fetchJSON<WrappersStatus>('/wrappers'),

  // Prompts
  getPrompts: () =>
    fetchJSON<{ prompts: PromptInfo[] }>('/prompts'),

  savePrompt: (name: string, content: string) =>
    fetchJSON<{ ok: boolean }>(`/prompts/${name}`, { method: 'POST', body: JSON.stringify({ content }) }),

  // Memory
  saveMemory: (content: string) =>
    fetchJSON<{ ok: boolean }>('/memory', { method: 'POST', body: JSON.stringify({ content }) }),

  // MCP
  getMcp: () =>
    fetchJSON<{ configs: Record<string, McpCliConfig>; servers: McpServer[] }>('/mcp'),

  addMcpServer: (cli: string, scope: string, name: string, config: McpServerConfig) =>
    fetchJSON<{ ok: boolean; servers: McpServer[] }>('/mcp/server', { method: 'POST', body: JSON.stringify({ cli, scope, name, config }) }),

  removeMcpServer: (cli: string, scope: string, name: string) =>
    fetchJSON<{ ok: boolean; servers: McpServer[] }>('/mcp/server', { method: 'DELETE', body: JSON.stringify({ cli, scope, name }) }),
}
