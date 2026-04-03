import { useEffect, useRef } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { Badge } from '@/components/ui/badge'
import { ScrollArea } from '@/components/ui/scroll-area'
import { AILogo } from '@/components/AILogo'
import type { ConsoleMessage, ResultFile } from '@/hooks/useConsoleSessions'

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-9;]*m/g, '')
}

function formatTime(ts: number) {
  const d = new Date(ts)
  return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
}

// ── Phase config ────────────────────────────────────────────────────────────

const PHASE_LABELS: Record<string, string> = {
  plan: 'Plan',
  contract: 'Contract',
  'contract-review': 'Contract Review',
  'contract-revision': 'Contract Revision',
  implement: 'Implementation',
  evaluate: 'QA Report',
  'final-report': 'Final Report',
}

const AGENT_STYLES: Record<string, { border: string; bg: string; label: string; icon: string }> = {
  planner:   { border: 'border-l-blue-500',    bg: 'bg-blue-500/5',    label: 'Planner',   icon: '📋' },
  generator: { border: 'border-l-emerald-500', bg: 'bg-emerald-500/5', label: 'Generator', icon: '⚡' },
  evaluator: { border: 'border-l-amber-500',   bg: 'bg-amber-500/5',   label: 'Evaluator', icon: '🔍' },
}

// ── File icon ───────────────────────────────────────────────────────────────

function fileIcon(name: string) {
  if (name.includes('spec')) return '📄'
  if (name.includes('scope') || name.includes('plan')) return '📋'
  if (name.includes('contract-review')) return '🔍'
  if (name.includes('contract')) return '📝'
  if (name.includes('implementation')) return '⚡'
  if (name.includes('qa-report')) return '🔍'
  if (name.includes('run_report')) return '📊'
  if (name.includes('retro')) return '🔄'
  return '📎'
}

// ── Prose style ─────────────────────────────────────────────────────────────

const PROSE_BOX = 'bg-muted/50 rounded-md px-3 py-2.5 text-foreground prose prose-sm dark:prose-invert max-w-none prose-p:my-1 prose-ul:my-1 prose-ol:my-1 prose-li:my-0.5 prose-headings:my-2 prose-pre:my-1 prose-code:text-xs prose-code:bg-muted prose-code:px-1 prose-code:py-0.5 prose-code:rounded prose-code:before:content-none prose-code:after:content-none prose-table:border-collapse prose-th:border prose-th:border-border prose-th:px-2 prose-th:py-1 prose-th:bg-muted prose-td:border prose-td:border-border prose-td:px-2 prose-td:py-1'

// ── FileLink: click filename → open in right panel ──────────────────────────

function FileLink({ file, onClick }: { file: ResultFile; onClick?: (file: ResultFile) => void }) {
  return (
    <button
      onClick={() => onClick?.(file)}
      className="flex items-center gap-1.5 w-full text-left cursor-pointer hover:bg-muted/80 rounded-md px-2 py-1.5 transition-colors group"
    >
      <span className="text-sm shrink-0">{fileIcon(file.name)}</span>
      <span className="text-xs font-mono text-blue-400 group-hover:text-blue-300 truncate">
        {file.name}
      </span>
      <span className="text-[10px] text-muted-foreground/60 ml-auto shrink-0">▸</span>
    </button>
  )
}

// ── ResultCard ──────────────────────────────────────────────────────────────

function ResultCard({ msg, onFileClick }: { msg: ConsoleMessage; onFileClick?: (file: ResultFile) => void }) {
  const agentStyle = AGENT_STYLES[msg.agentRole || '']
  const hasFiles = msg.files && msg.files.length > 0

  // Build a short summary line (never show raw full content)
  const summaryText = (() => {
    const raw = stripAnsi(msg.text || '')
    // If the text is already short (our new format), use it
    if (raw.length <= 120) return raw
    // Old format: full markdown blob — extract first meaningful line
    const firstLine = raw.split('\n').find(l => l.trim() && !l.startsWith('#') && !l.startsWith('='))
    if (firstLine && firstLine.length <= 120) return firstLine.trim()
    return raw.slice(0, 80) + '…'
  })()

  return (
    <div className={`border-l-2 ${agentStyle?.border || 'border-l-muted-foreground'} rounded-r-md ${agentStyle?.bg || ''} py-1.5 px-3`}>
      {/* Header: logo + badge + summary */}
      <div className="flex items-center gap-2 flex-wrap">
        {msg.backend && <AILogo backend={msg.backend} model={msg.model} />}
        <Badge
          variant={msg.verdict === 'pass' ? 'default' : msg.verdict === 'fail' ? 'destructive' : 'secondary'}
          className="text-[10px] h-5 px-2"
        >
          {PHASE_LABELS[msg.phase || ''] || msg.phase || 'Result'}
        </Badge>
        {msg.verdict && (
          <Badge
            variant={msg.verdict === 'pass' ? 'default' : 'destructive'}
            className="text-[10px] h-5 px-2"
          >
            {msg.verdict === 'pass' ? 'PASS' : 'FAIL'}
          </Badge>
        )}
        {summaryText && (
          <span className="text-[11px] text-muted-foreground truncate">
            {summaryText}
          </span>
        )}
      </div>

      {/* File list */}
      {hasFiles && (
        <div className="mt-1.5 space-y-0">
          {msg.files!.map((file, i) => (
            <FileLink key={`${file.name}-${i}`} file={file} onClick={onFileClick} />
          ))}
        </div>
      )}
    </div>
  )
}

// ── Agent divider ───────────────────────────────────────────────────────────

function AgentDivider({ role }: { role: string }) {
  const style = AGENT_STYLES[role]
  if (!style) return null
  const color = role === 'planner' ? 'bg-blue-500/30' : role === 'generator' ? 'bg-emerald-500/30' : 'bg-amber-500/30'
  return (
    <div className="flex items-center gap-2 mt-5 mb-2">
      <div className={`h-px flex-1 ${color}`} />
      <span className="text-[10px] font-semibold uppercase tracking-wider text-muted-foreground select-none">
        {style.icon} {style.label}
      </span>
      <div className={`h-px flex-1 ${color}`} />
    </div>
  )
}

// ── LogFeed ─────────────────────────────────────────────────────────────────

interface LogFeedProps {
  messages: ConsoleMessage[]
  connected: boolean
  onFileClick?: (file: ResultFile) => void
}

export function LogFeed({ messages, connected, onFileClick }: LogFeedProps) {
  const bottomRef = useRef<HTMLDivElement>(null)
  // Filter: only show chat messages + results, not raw streaming logs
  const chatMessages = messages.filter((m) => m.role !== 'log')

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [chatMessages])

  return (
    <div className="flex flex-col h-full">
      {/* Status bar */}
      <div className="flex items-center gap-2 px-4 py-2 border-b bg-muted/30 shrink-0">
        <div className={`h-2 w-2 rounded-full ${connected ? 'bg-emerald-500' : 'bg-muted-foreground'}`} />
        <span className="text-xs text-muted-foreground">
          {connected ? 'Connected' : 'Disconnected'}
        </span>
      </div>

      {chatMessages.length === 0 ? (
        <div className="flex-1 flex flex-col items-center justify-center gap-2 text-muted-foreground">
          <div className="text-4xl">⚡</div>
          <p className="text-sm font-medium">Harn Assistant</p>
          <p className="text-xs text-center max-w-[280px]">
            Ask me to manage your backlog, run sprints, change settings, or just chat about your project.
          </p>
        </div>
      ) : (
        <ScrollArea className="flex-1 min-h-0">
          <div className="p-4 font-mono text-xs space-y-0">
            {chatMessages.map((msg, i) => {
              const prevMsg = i > 0 ? chatMessages[i - 1] : null
              const isNewBlock = prevMsg && prevMsg.role !== msg.role

              // Show agent divider when agent role changes between result messages
              const currentAgent = msg.role === 'result' ? msg.agentRole : undefined
              const prevAgent = prevMsg?.role === 'result' ? prevMsg.agentRole : undefined
              const showDivider = currentAgent && currentAgent !== prevAgent

              return (
                <div key={msg.id}>
                  {showDivider && <AgentDivider role={currentAgent} />}
                  <div
                    className={`group flex gap-2 ${isNewBlock && !showDivider ? 'mt-4' : 'mt-1'}`}
                  >
                    <span className="text-muted-foreground/40 shrink-0 select-none opacity-0 group-hover:opacity-100 transition-opacity text-[10px] leading-relaxed pt-0.5">
                      {formatTime(msg.timestamp)}
                    </span>
                    <div className="flex-1 min-w-0">
                      {msg.role === 'user' ? (
                        <div className="flex items-start gap-1.5">
                          <span className="text-primary shrink-0 select-none">›</span>
                          <span className="text-foreground whitespace-pre-wrap break-words leading-relaxed">
                            {msg.text}
                          </span>
                        </div>
                      ) : msg.role === 'assistant' ? (
                        <div>
                          {msg.backend && (
                            <div className="mb-1.5">
                              <AILogo backend={msg.backend} model={msg.model} />
                            </div>
                          )}
                          <div className={PROSE_BOX}>
                            <ReactMarkdown remarkPlugins={[remarkGfm]}>{stripAnsi(msg.text)}</ReactMarkdown>
                          </div>
                        </div>
                      ) : msg.role === 'result' ? (
                        <ResultCard msg={msg} onFileClick={onFileClick} />
                      ) : msg.role === 'system' && msg.text.includes('✓') ? (
                        <div className="text-emerald-600 dark:text-emerald-400 prose prose-sm dark:prose-invert max-w-none prose-p:my-1 prose-ul:my-1 prose-ol:my-1 prose-li:my-0.5 prose-code:text-xs prose-code:bg-emerald-500/10 prose-code:px-1 prose-code:py-0.5 prose-code:rounded prose-code:text-emerald-600 dark:prose-code:text-emerald-400 prose-code:before:content-none prose-code:after:content-none prose-strong:text-emerald-600 dark:prose-strong:text-emerald-400">
                          <ReactMarkdown remarkPlugins={[remarkGfm]}>{stripAnsi(msg.text)}</ReactMarkdown>
                        </div>
                      ) : (
                        <div className="leading-relaxed whitespace-pre-wrap break-words text-muted-foreground">
                          {stripAnsi(msg.text)}
                        </div>
                      )}
                    </div>
                  </div>
                </div>
              )
            })}
            <div ref={bottomRef} />
          </div>
        </ScrollArea>
      )}
    </div>
  )
}
