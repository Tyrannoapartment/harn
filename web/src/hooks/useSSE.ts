import { useEffect, useRef, useState, useCallback } from 'react'

export interface LogEntry {
  text: string
  timestamp: number
}

export function useSSE(url = '/api/logs/stream') {
  const [logs, setLogs] = useState<LogEntry[]>([])
  const [connected, setConnected] = useState(false)
  const esRef = useRef<EventSource | null>(null)

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
    return () => { es.close(); esRef.current = null }
  }, [url])

  const clearLogs = useCallback(() => setLogs([]), [])
  return { logs, connected, clearLogs }
}
