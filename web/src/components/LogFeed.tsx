import { useEffect, useRef } from 'react'
import { Badge } from '@/components/ui/badge'
import { ScrollArea } from '@/components/ui/scroll-area'
import type { LogEntry } from '@/hooks/useSSE'

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-9;]*m/g, '')
}

function classifyLine(text: string) {
  const t = stripAnsi(text)
  if (/VERDICT: PASS|✓|✅|APPROVED/.test(t)) return 'text-emerald-600 dark:text-emerald-400'
  if (/VERDICT: FAIL|✗|❌|ERROR|NEEDS_REVISION/.test(t)) return 'text-destructive'
  if (/⚠|WARN/.test(t)) return 'text-yellow-600 dark:text-yellow-400'
  if (/^#+\s/.test(t)) return 'font-semibold text-foreground'
  if (/^===/.test(t)) return 'text-muted-foreground border-t border-border pt-1'
  return 'text-muted-foreground'
}

interface LogFeedProps {
  logs: LogEntry[]
  connected: boolean
}

export function LogFeed({ logs, connected }: LogFeedProps) {
  const bottomRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [logs])

  return (
    <div className="flex flex-col h-full">
      {/* Status bar */}
      <div className="flex items-center gap-2 px-4 py-2 border-b bg-muted/30 shrink-0">
        <div className={`h-2 w-2 rounded-full ${connected ? 'bg-emerald-500' : 'bg-muted-foreground'}`} />
        <span className="text-xs text-muted-foreground">
          {connected ? 'Connected' : 'Disconnected'}
        </span>
        {logs.length > 0 && (
          <Badge variant="secondary" className="ml-auto text-[10px] h-5 px-1.5">
            {logs.length} lines
          </Badge>
        )}
      </div>

      {logs.length === 0 ? (
        <div className="flex-1 flex flex-col items-center justify-center gap-2 text-muted-foreground">
          <div className="text-4xl">⚡</div>
          <p className="text-sm font-medium">Ready</p>
          <p className="text-xs">Run a command to see agent output</p>
        </div>
      ) : (
        <ScrollArea className="flex-1">
          <div className="p-4 font-mono text-xs space-y-0.5">
            {logs.map((entry, i) => (
              <div key={i} className={`leading-relaxed whitespace-pre-wrap break-all ${classifyLine(entry.text)}`}>
                {stripAnsi(entry.text)}
              </div>
            ))}
            <div ref={bottomRef} />
          </div>
        </ScrollArea>
      )}
    </div>
  )
}
