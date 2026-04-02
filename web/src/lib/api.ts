const API_BASE = '/api'

async function fetchJSON<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    headers: { 'Content-Type': 'application/json' },
    ...init,
  })
  if (!res.ok) throw new Error(`API ${path}: ${res.status}`)
  return res.json()
}

export const api = {
  health: () => fetchJSON<{ status: string; version: string }>('/health'),
  status: () => fetchJSON<{ active: unknown; pending: string[]; inProgress: string | null; config: Record<string, string> }>('/status'),
  getBacklog: () => fetchJSON<{ items: { slug: string; description: string; plan?: string; status: string }[] }>('/backlog'),
  getRuns: () => fetchJSON<{ runs: { id: string; prompt: string; plan: string; sprints: { number: string; status: string; iteration: string }[]; active: boolean }[] }>('/runs'),
  getConfig: () => fetchJSON<Record<string, string>>('/config'),
  getMemory: () => fetchJSON<{ content: string }>('/memory'),

  saveConfig: (data: Record<string, string>) =>
    fetchJSON<Record<string, string>>('/config', { method: 'POST', body: JSON.stringify(data) }),

  addToBacklog: (description: string) =>
    fetchJSON<{ ok: boolean }>('/backlog/add', { method: 'POST', body: JSON.stringify({ description }) }),

  startRun: (slug: string) =>
    fetchJSON<{ ok: boolean }>('/command', { method: 'POST', body: JSON.stringify({ command: 'start', args: [slug] }) }),

  runCommand: (command: string) =>
    fetchJSON<{ ok: boolean; result?: unknown }>('/command', { method: 'POST', body: JSON.stringify({ command }) }),

  stopCommand: () =>
    fetchJSON<{ ok: boolean }>('/command/stop', { method: 'POST' }),

  saveMemory: (content: string) =>
    fetchJSON<{ ok: boolean }>('/memory', { method: 'POST', body: JSON.stringify({ content }) }),
}
