import { useEffect, useRef, useState, useCallback } from 'react'

export interface LogEntry {
  text: string
  timestamp: number
}

export interface RunStatus {
  state: 'running' | 'waiting' | 'error'
  phase?: string
  sprint?: number
  totalSprints?: number
  iteration?: number
  backend?: string
  model?: string
  agent?: string
  timestamp: number
}

export interface RunProgress {
  currentSprint: number
  totalSprints: number
  phase: string
  iteration: number
  elapsed: number
  startTime: number
  timestamp: number
}

export interface AIChunk {
  chunk: string
  role?: string
  phase?: string
  timestamp: number
}

export interface ResultFile {
  name: string
  path: string
  content: string
}

export interface ResultEntry {
  text: string
  phase: string
  role: string
  backend?: string
  model?: string
  verdict?: string
  iteration?: number
  files?: ResultFile[]
  timestamp: number
}

export function useSSE(url = '/api/logs/stream') {
  const [logs, setLogs] = useState<LogEntry[]>([])
  const [connected, setConnected] = useState(false)
  const [runStatus, setRunStatus] = useState<RunStatus | null>(null)
  const [runProgress, setRunProgress] = useState<RunProgress | null>(null)
  const esRef = useRef<EventSource | null>(null)

  // Stable callbacks for consumers
  const statusListeners = useRef<Set<(s: RunStatus) => void>>(new Set())
  const progressListeners = useRef<Set<(p: RunProgress) => void>>(new Set())
  const aiChunkListeners = useRef<Set<(c: AIChunk) => void>>(new Set())
  const resultListeners = useRef<Set<(r: ResultEntry) => void>>(new Set())

  useEffect(() => {
    const es = new EventSource(url)
    esRef.current = es
    es.onopen = () => setConnected(true)
    es.onerror = () => setConnected(false)

    es.addEventListener('log', (e: MessageEvent) => {
      try {
        const data = JSON.parse(e.data) as LogEntry
        setLogs((prev) => [...prev, data])
      } catch { /* ignore */ }
    })

    es.addEventListener('status', (e: MessageEvent) => {
      try {
        const data = JSON.parse(e.data) as RunStatus
        setRunStatus(data)
        statusListeners.current.forEach((fn) => fn(data))
      } catch { /* ignore */ }
    })

    es.addEventListener('progress', (e: MessageEvent) => {
      try {
        const data = JSON.parse(e.data) as RunProgress
        setRunProgress(data)
        progressListeners.current.forEach((fn) => fn(data))
      } catch { /* ignore */ }
    })

    es.addEventListener('ai_chunk', (e: MessageEvent) => {
      try {
        const data = JSON.parse(e.data) as AIChunk
        aiChunkListeners.current.forEach((fn) => fn(data))
      } catch { /* ignore */ }
    })

    es.addEventListener('result', (e: MessageEvent) => {
      try {
        const data = JSON.parse(e.data) as ResultEntry
        resultListeners.current.forEach((fn) => fn(data))
      } catch { /* ignore */ }
    })

    return () => { es.close(); esRef.current = null }
  }, [url])

  const clearLogs = useCallback(() => setLogs([]), [])

  const onStatus = useCallback((fn: (s: RunStatus) => void) => {
    statusListeners.current.add(fn)
    return () => { statusListeners.current.delete(fn) }
  }, [])

  const onProgress = useCallback((fn: (p: RunProgress) => void) => {
    progressListeners.current.add(fn)
    return () => { progressListeners.current.delete(fn) }
  }, [])

  const onAIChunk = useCallback((fn: (c: AIChunk) => void) => {
    aiChunkListeners.current.add(fn)
    return () => { aiChunkListeners.current.delete(fn) }
  }, [])

  const onResult = useCallback((fn: (r: ResultEntry) => void) => {
    resultListeners.current.add(fn)
    return () => { resultListeners.current.delete(fn) }
  }, [])

  return { logs, connected, clearLogs, runStatus, runProgress, onStatus, onProgress, onAIChunk, onResult }
}
