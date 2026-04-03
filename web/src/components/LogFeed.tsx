import { useEffect, useRef } from 'react'
import ReactMarkdown from 'react-markdown'
import { Badge } from '@/components/ui/badge'
import { ScrollArea } from '@/components/ui/scroll-area'
import { AILogo } from '@/components/AILogo'
import type { ConsoleMessage } from '@/hooks/useConsoleSessions'

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-9;]*m/g, '')
}

function formatTime(ts: number) {
  const d = new Date(ts)
  return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
}

const PHASE_LABELS: Record<string, string> = {
  plan: '📋 Plan',
  contract: '📝 Contract',
  'contract-review': '🔍 Contract Review',
  'contract-revision': '📝 Contract Revision',
  implement: '⚡ Implementation',
  evaluate: '🔍 QA Report',
}

const ROLE_LABELS: Record<string, string> = {
  planner: 'Planner',
  generator: 'Generator',
  evaluator: 'Evaluator',
}

interface LogFeedProps {
  messages: ConsoleMessage[]
  connected: boolean
}

const PROSE_BOX = 'bg-muted/50 rounded-md px-3 py-2.5 text-foreground prose prose-sm dark:prose-invert max-w-none prose-p:my-1 prose-ul:my-1 prose-ol:my-1 prose-li:my-0.5 prose-headings:my-2 prose-pre:my-1 prose-code:text-xs prose-code:bg-muted prose-code:px-1 prose-code:py-0.5 prose-code:rounded prose-code:before:content-none prose-code:after:content-none'

export function LogFeed({ messages, connected }: LogFeedProps) {
  const bottomRef = useRef<HTMLDivElement>(null)
  // Filter: only show chat messages + results, not raw logs
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
              return (
                <div
                  key={msg.id}
                  className={`group flex gap-2 ${isNewBlock ? 'mt-4' : 'mt-1'}`}
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
                          <ReactMarkdown>{stripAnsi(msg.text)}</ReactMarkdown>
                        </div>
                      </div>
                    ) : msg.role === 'result' ? (
                      <div>
                        <div className="flex items-center gap-2 mb-1.5">
                          {msg.backend && <AILogo backend={msg.backend} model={msg.model} />}
                          <Badge
                            variant={msg.verdict === 'pass' ? 'default' : msg.verdict === 'fail' ? 'destructive' : 'secondary'}
                            className="text-[10px] h-5 px-2"
                          >
                            {PHASE_LABELS[msg.phase || ''] || msg.phase}
                            {msg.agentRole && ` · ${ROLE_LABELS[msg.agentRole] || msg.agentRole}`}
                          </Badge>
                          {msg.verdict && (
                            <Badge
                              variant={msg.verdict === 'pass' ? 'default' : 'destructive'}
                              className="text-[10px] h-5 px-2"
                            >
                              {msg.verdict === 'pass' ? '✅ PASS' : '❌ FAIL'}
                            </Badge>
                          )}
                        </div>
                        <div className={PROSE_BOX}>
                          <ReactMarkdown>{stripAnsi(msg.text)}</ReactMarkdown>
                        </div>
                      </div>
                    ) : msg.role === 'system' && msg.text.includes('✓') ? (
                      <div className="text-emerald-600 dark:text-emerald-400 prose prose-sm dark:prose-invert max-w-none prose-p:my-1 prose-ul:my-1 prose-ol:my-1 prose-li:my-0.5 prose-code:text-xs prose-code:bg-emerald-500/10 prose-code:px-1 prose-code:py-0.5 prose-code:rounded prose-code:text-emerald-600 dark:prose-code:text-emerald-400 prose-code:before:content-none prose-code:after:content-none prose-strong:text-emerald-600 dark:prose-strong:text-emerald-400">
                        <ReactMarkdown>{stripAnsi(msg.text)}</ReactMarkdown>
                      </div>
                    ) : (
                      <div className="leading-relaxed whitespace-pre-wrap break-words text-muted-foreground">
                        {stripAnsi(msg.text)}
                      </div>
                    )}
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
