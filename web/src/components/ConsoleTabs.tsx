import { useState, useEffect, useRef, useCallback } from 'react'
import { Button } from '@/components/ui/button'
import { Tooltip, TooltipContent, TooltipTrigger, TooltipProvider } from '@/components/ui/tooltip'
import { ScrollArea, ScrollBar } from '@/components/ui/scroll-area'
import { Add01Icon, Cancel01Icon, Delete02Icon, SidebarRight01Icon } from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { LogFeed } from '@/components/LogFeed'
import { RightPanel, type FileChange, type ArtifactEntry } from '@/components/RightPanel'
import type { ResultFile } from '@/hooks/useConsoleSessions'
import { Composer } from '@/components/Composer'
import { useConsoleSessions } from '@/hooks/useConsoleSessions'
import { useSSE, type ResultEntry } from '@/hooks/useSSE'
import { useI18n } from '@/hooks/useI18n'
import { api } from '@/lib/api'
import { cn } from '@/lib/utils'

export function ConsoleTabs() {
  const { t } = useI18n()
  const {
    sessions,
    activeSession,
    activeId,
    setActiveId,
    addSession,
    removeSession,
    clearSession,
    addMessage,
    appendLogs,
    appendChunk,
    renameSession,
  } = useConsoleSessions()

  const { logs, connected, onAIChunk, onResult, onStatus } = useSSE()
  const [loading, setLoading] = useState(false)
  const [logOpen, setLogOpen] = useState(false)
  const [rawLines, setRawLines] = useState<string[]>([])
  const [fileChanges, setFileChanges] = useState<FileChange[]>([])
  const [artifacts, setArtifacts] = useState<ArtifactEntry[]>([])
  const [viewerFile, setViewerFile] = useState<ResultFile | null>(null)
  const prevLogCount = useRef(0)
  const lastPhaseRef = useRef<string | null>(null)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [editValue, setEditValue] = useState('')
  const editInputRef = useRef<HTMLInputElement>(null)

  // Parse git diff stat lines into FileChange entries
  const parseFileChanges = useCallback((text: string) => {
    // Match lines like: "📁 Changed files:" or "📄 New files:"
    if (!text.includes('📁') && !text.includes('📄')) return
    const lines = text.split('\n').filter((l) => l.trim())
    for (const line of lines) {
      const trimmed = line.trim()
      if (trimmed.startsWith('📁') || trimmed.startsWith('📄')) continue
      // git diff --stat lines: " path/to/file | 5 ++--"
      const statMatch = trimmed.match(/^\s*(.+?)\s+\|\s+(.+)$/)
      if (statMatch) {
        setFileChanges((prev) => {
          if (prev.some((c) => c.path === statMatch[1].trim())) return prev
          return [...prev, { type: 'modified', path: statMatch[1].trim(), stat: statMatch[2].trim() }]
        })
        continue
      }
      // Plain file path (new/untracked)
      if (trimmed && !trimmed.includes('file') && !trimmed.includes('changed')) {
        setFileChanges((prev) => {
          if (prev.some((c) => c.path === trimmed)) return prev
          return [...prev, { type: 'added', path: trimmed }]
        })
      }
    }
  }, [])

  // Pipe new SSE logs into active session (operational messages)
  useEffect(() => {
    if (logs.length > prevLogCount.current) {
      const newLogs = logs.slice(prevLogCount.current)
      appendLogs(newLogs)
      // Also add to raw log + detect file changes
      setRawLines((prev) => [...prev, ...newLogs.map((l) => l.text)])
      for (const l of newLogs) parseFileChanges(l.text)
    }
    prevLogCount.current = logs.length
  }, [logs, appendLogs, parseFileChanges])

  // Pipe AI streaming chunks — accumulate into session + raw log
  useEffect(() => {
    return onAIChunk((chunk) => {
      if (chunk.chunk) {
        appendChunk(chunk.chunk)
        setRawLines((prev) => {
          const last = prev[prev.length - 1]
          // Accumulate into last raw line if it doesn't end with newline
          if (last !== undefined && !last.endsWith('\n')) {
            return [...prev.slice(0, -1), last + chunk.chunk]
          }
          return [...prev, chunk.chunk]
        })
      }
    })
  }, [onAIChunk, appendChunk])

  // Pipe result events as result messages in chat + store as artifacts
  const PHASE_LABELS_MAP: Record<string, string> = {
    plan: 'Plan',
    contract: 'Contract',
    'contract-review': 'Contract Review',
    'contract-revision': 'Contract Revision',
    implement: 'Implementation',
    evaluate: 'QA Report',
  }

  useEffect(() => {
    return onResult((r: ResultEntry) => {
      addMessage(activeId, 'result', r.text, r.backend, r.model, {
        phase: r.phase,
        agentRole: r.role,
        verdict: r.verdict,
        files: r.files,
      })
      // Store as artifact for right panel
      setArtifacts((prev) => [
        ...prev,
        {
          phase: r.phase,
          label: PHASE_LABELS_MAP[r.phase] || r.phase,
          content: r.text,
          timestamp: r.timestamp,
        },
      ])
    })
  }, [onResult, activeId, addMessage])

  // Pipe status events as activity messages in chat (styled like assistant with AILogo)
  useEffect(() => {
    const PHASE_ACTIVITY: Record<string, { label: string; emoji: string }> = {
      plan: { label: 'Planner', emoji: '📋' },
      starting: { label: 'Sprint Loop', emoji: '🚀' },
      contract: { label: 'Generator', emoji: '📝' },
      implement: { label: 'Generator', emoji: '⚡' },
      evaluate: { label: 'Evaluator', emoji: '🔍' },
      next: { label: 'Sprint', emoji: '➡️' },
      complete: { label: 'Sprint Loop', emoji: '✅' },
      stopped: { label: 'Sprint Loop', emoji: '🛑' },
    }

    const PHASE_DESC: Record<string, string> = {
      plan: 'Generating plan…',
      starting: 'Sprint loop started',
      contract: 'Proposing contract…',
      implement: 'Implementing…',
      evaluate: 'Reviewing implementation…',
      next: 'Moving to next sprint…',
      complete: 'All sprints complete!',
      stopped: 'Sprint loop stopped.',
    }

    return onStatus((s) => {
      const phase = s.phase || ''
      if (phase === lastPhaseRef.current) return
      lastPhaseRef.current = phase

      const info = PHASE_ACTIVITY[phase]
      const desc = PHASE_DESC[phase] || `Phase: ${phase}`

      let text = `${info?.emoji || '🔄'} **${info?.label || phase}** — ${desc}`
      if (s.sprint && s.totalSprints) {
        text = `**Sprint ${s.sprint}/${s.totalSprints}**\n\n${text}`
      }
      if (s.iteration && s.iteration > 1) {
        text += ` *(iteration ${s.iteration})*`
      }

      addMessage(activeId, 'assistant', text, s.backend || undefined, s.model || undefined)
    })
  }, [onStatus, activeId, addMessage])

  const handleFileClick = useCallback((file: ResultFile) => {
    setViewerFile(file)
    setLogOpen(true)
  }, [])

  const handleSubmit = useCallback(async (text: string) => {
    addMessage(activeId, 'user', text)
    setLoading(true)
    try {
      // Build conversation history from current session (user/assistant only)
      const history = (activeSession?.messages ?? [])
        .filter((m) => m.role === 'user' || m.role === 'assistant')
        .map((m) => ({ role: m.role, text: m.text }))
      const res = await api.chat(text, history)
      // Show AI reply as assistant message
      if (res.reply) {
        addMessage(activeId, 'assistant', res.reply, res.backend, res.model)
      }
      // Show action results separately
      if (res.actions?.length) {
        const actionParts: string[] = []
        for (const a of res.actions) {
          if (a.ok) {
            const result = typeof a.result === 'string' ? a.result : 'done'
            if (result.includes('\n')) {
              actionParts.push(`**✓ ${a.action}**\n\n${result}`)
            } else {
              actionParts.push(`✓ \`${a.action}\`: ${result}`)
            }
          } else {
            actionParts.push(`⚠ \`${a.action}\`: ${a.error}`)
          }
        }
        if (actionParts.length > 0) {
          addMessage(activeId, 'system', actionParts.join('\n\n'))
        }
      }
      if (!res.reply && !res.actions?.length) {
        addMessage(activeId, 'assistant', t('console.noResponse'), res.backend, res.model)
      }
    } catch (e) {
      addMessage(activeId, 'system', `Error: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setLoading(false)
    }
  }, [activeId, addMessage])

  const startEdit = useCallback((id: string, label: string, e: React.MouseEvent) => {
    e.stopPropagation()
    setEditingId(id)
    setEditValue(label)
    setTimeout(() => {
      editInputRef.current?.select()
    }, 0)
  }, [])

  const commitEdit = useCallback(() => {
    if (editingId) {
      const trimmed = editValue.trim()
      if (trimmed) renameSession(editingId, trimmed)
    }
    setEditingId(null)
  }, [editingId, editValue, renameSession])

  const handleEditKey = useCallback((e: React.KeyboardEvent) => {
    if (e.key === 'Enter') commitEdit()
    if (e.key === 'Escape') setEditingId(null)
  }, [commitEdit])

  return (
    <div className="flex h-full">
      {/* ── Left: Chat Panel ── */}
      <div className="flex flex-col flex-1 min-w-0 overflow-hidden">
        {/* Tab bar */}
        <div className="flex items-center border-b bg-muted/30 shrink-0">
          <ScrollArea className="flex-1">
            <div className="flex items-center h-9 px-1 gap-0.5 overflow-x-auto">
              {sessions.map((s) => (
                <button
                  key={s.id}
                  onClick={() => setActiveId(s.id)}
                  onDoubleClick={(e) => startEdit(s.id, s.label, e)}
                  className={cn(
                    'group relative flex items-center gap-1.5 h-7 px-3 text-xs rounded-md transition-colors shrink-0',
                    s.id === activeId
                      ? 'bg-background text-foreground shadow-sm border'
                      : 'text-muted-foreground hover:text-foreground hover:bg-muted',
                  )}
                >
                  {editingId === s.id ? (
                    <input
                      ref={editInputRef}
                      value={editValue}
                      onChange={(e) => setEditValue(e.target.value)}
                      onBlur={commitEdit}
                      onKeyDown={handleEditKey}
                      onClick={(e) => e.stopPropagation()}
                      className="w-24 bg-transparent outline-none border-b border-primary text-xs"
                    />
                  ) : (
                    <span className="truncate max-w-[100px]">{s.label}</span>
                  )}
                  {s.messages.length > 0 && s.id !== activeId && editingId !== s.id && (
                    <span className="h-1.5 w-1.5 rounded-full bg-primary/60 shrink-0" />
                  )}
                  {sessions.length > 1 && editingId !== s.id && (
                    <span
                      role="button"
                      onClick={(e) => {
                        e.stopPropagation()
                        removeSession(s.id)
                      }}
                      className="ml-0.5 opacity-0 group-hover:opacity-100 transition-opacity rounded-sm hover:bg-muted-foreground/20 p-0.5"
                    >
                      <HugeiconsIcon icon={Cancel01Icon} size={10} />
                    </span>
                  )}
                </button>
              ))}
            </div>
            <ScrollBar orientation="horizontal" className="h-0" />
          </ScrollArea>

          <div className="flex items-center gap-0.5 px-1 shrink-0 border-l">
            <TooltipProvider>
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button size="icon" variant="ghost" className="h-6 w-6" onClick={addSession}>
                    <HugeiconsIcon icon={Add01Icon} size={12} />
                  </Button>
                </TooltipTrigger>
                <TooltipContent side="bottom">{t('console.newConsole')}</TooltipContent>
              </Tooltip>
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    size="icon"
                    variant="ghost"
                    className="h-6 w-6"
                    onClick={() => clearSession(activeId)}
                    disabled={!activeSession || activeSession.messages.length === 0}
                  >
                    <HugeiconsIcon icon={Delete02Icon} size={12} />
                  </Button>
                </TooltipTrigger>
                <TooltipContent side="bottom">{t('console.clearConsole')}</TooltipContent>
              </Tooltip>
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    size="icon"
                    variant={logOpen ? 'secondary' : 'ghost'}
                    className="h-6 w-6"
                    onClick={() => setLogOpen((v) => !v)}
                  >
                    <HugeiconsIcon icon={SidebarRight01Icon} size={12} />
                  </Button>
                </TooltipTrigger>
                <TooltipContent side="bottom">Side Panel</TooltipContent>
              </Tooltip>
            </TooltipProvider>
          </div>
        </div>

        {/* Chat feed */}
        <div className="flex-1 overflow-hidden">
          <LogFeed
            messages={activeSession?.messages ?? []}
            connected={connected}
            onFileClick={handleFileClick}
          />
        </div>

        <Composer loading={loading} onSubmit={handleSubmit} />
      </div>

      {/* ── Right: Tabbed Panel (toggleable) ── */}
      {logOpen && (
        <>
          <div className="w-px bg-border shrink-0" />
          <div className="w-[400px] shrink-0 overflow-hidden">
            <RightPanel
              rawLines={rawLines}
              fileChanges={fileChanges}
              artifacts={artifacts}
              viewerFile={viewerFile}
            />
          </div>
        </>
      )}
    </div>
  )
}
