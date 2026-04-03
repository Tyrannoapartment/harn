import { useState, useCallback, useEffect } from 'react'
import type { LogEntry } from './useSSE'

const STORAGE_KEY = 'harn:console-sessions'
const MAX_MESSAGES_PER_SESSION = 500

export interface ConsoleMessage {
  id: string
  role: 'user' | 'assistant' | 'system' | 'log' | 'result'
  text: string
  timestamp: number
  backend?: string
  model?: string
  phase?: string
  agentRole?: string
  verdict?: string
}

export interface ConsoleSession {
  id: string
  label: string
  messages: ConsoleMessage[]
  createdAt: number
}

interface SessionsState {
  sessions: ConsoleSession[]
  activeId: string
}

function generateId() {
  return `s-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`
}

function generateMsgId() {
  return `m-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`
}

function loadState(): SessionsState {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (raw) {
      const parsed = JSON.parse(raw) as SessionsState
      if (parsed.sessions?.length > 0) return parsed
    }
  } catch { /* ignore */ }

  const defaultSession: ConsoleSession = {
    id: generateId(),
    label: 'Console 1',
    messages: [],
    createdAt: Date.now(),
  }
  return { sessions: [defaultSession], activeId: defaultSession.id }
}

function saveState(state: SessionsState) {
  try {
    // Trim messages before saving to avoid quota issues
    const trimmed: SessionsState = {
      ...state,
      sessions: state.sessions.map((s) => ({
        ...s,
        messages: s.messages.slice(-MAX_MESSAGES_PER_SESSION),
      })),
    }
    localStorage.setItem(STORAGE_KEY, JSON.stringify(trimmed))
  } catch { /* quota exceeded — ignore */ }
}

export function useConsoleSessions() {
  const [state, setState] = useState<SessionsState>(loadState)

  // Persist whenever state changes
  useEffect(() => {
    saveState(state)
  }, [state])

  const activeSession = state.sessions.find((s) => s.id === state.activeId) ?? state.sessions[0]

  const setActiveId = useCallback((id: string) => {
    setState((prev) => ({ ...prev, activeId: id }))
  }, [])

  const addSession = useCallback(() => {
    setState((prev) => {
      const num = prev.sessions.length + 1
      const session: ConsoleSession = {
        id: generateId(),
        label: `Console ${num}`,
        messages: [],
        createdAt: Date.now(),
      }
      return {
        sessions: [...prev.sessions, session],
        activeId: session.id,
      }
    })
  }, [])

  const removeSession = useCallback((id: string) => {
    setState((prev) => {
      if (prev.sessions.length <= 1) return prev
      const sessions = prev.sessions.filter((s) => s.id !== id)
      const activeId = prev.activeId === id ? sessions[0].id : prev.activeId
      return { sessions, activeId }
    })
  }, [])

  const clearSession = useCallback((id: string) => {
    setState((prev) => ({
      ...prev,
      sessions: prev.sessions.map((s) =>
        s.id === id ? { ...s, messages: [] } : s,
      ),
    }))
  }, [])

  const addMessage = useCallback(
    (
      sessionId: string,
      role: ConsoleMessage['role'],
      text: string,
      backend?: string,
      model?: string,
      extra?: { phase?: string; agentRole?: string; verdict?: string },
    ) => {
      setState((prev) => ({
        ...prev,
        sessions: prev.sessions.map((s) =>
          s.id === sessionId
            ? {
                ...s,
                messages: [
                  ...s.messages,
                  {
                    id: generateMsgId(),
                    role,
                    text,
                    timestamp: Date.now(),
                    backend,
                    model,
                    ...(extra || {}),
                  },
                ].slice(-MAX_MESSAGES_PER_SESSION),
              }
            : s,
        ),
      }))
    },
    [],
  )

  // Append SSE log entries to the ACTIVE session
  const appendLogs = useCallback((logs: LogEntry[]) => {
    if (logs.length === 0) return
    setState((prev) => ({
      ...prev,
      sessions: prev.sessions.map((s) =>
        s.id === prev.activeId
          ? {
              ...s,
              messages: [
                ...s.messages,
                ...logs.map((l) => ({
                  id: generateMsgId(),
                  role: 'log' as const,
                  text: l.text,
                  timestamp: l.timestamp,
                })),
              ].slice(-MAX_MESSAGES_PER_SESSION),
            }
          : s,
      ),
    }))
  }, [])

  // Append streaming AI chunk to the last log message (accumulate into one box)
  const appendChunk = useCallback((text: string) => {
    if (!text) return
    setState((prev) => ({
      ...prev,
      sessions: prev.sessions.map((s) => {
        if (s.id !== prev.activeId) return s
        const msgs = [...s.messages]
        const last = msgs[msgs.length - 1]
        if (last && last.role === 'log') {
          // Append to existing log message
          msgs[msgs.length - 1] = { ...last, text: last.text + text }
        } else {
          // Create new log message
          msgs.push({ id: generateMsgId(), role: 'log', text, timestamp: Date.now() })
        }
        return { ...s, messages: msgs.slice(-MAX_MESSAGES_PER_SESSION) }
      }),
    }))
  }, [])

  const renameSession = useCallback((id: string, label: string) => {
    setState((prev) => ({
      ...prev,
      sessions: prev.sessions.map((s) =>
        s.id === id ? { ...s, label } : s,
      ),
    }))
  }, [])

  return {
    sessions: state.sessions,
    activeSession,
    activeId: state.activeId,
    setActiveId,
    addSession,
    removeSession,
    clearSession,
    addMessage,
    appendLogs,
    appendChunk,
    renameSession,
  }
}
