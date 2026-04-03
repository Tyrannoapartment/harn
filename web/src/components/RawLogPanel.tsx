import { useEffect, useRef } from 'react'
import { ScrollArea } from '@/components/ui/scroll-area'

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-9;]*m/g, '')
}

interface RawLogPanelProps {
  lines: string[]
}

export function RawLogPanel({ lines }: RawLogPanelProps) {
  const bottomRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [lines])

  return (
    <div className="flex flex-col h-full bg-background">
      <div className="flex items-center gap-2 px-3 py-2 border-b bg-muted/30 shrink-0">
        <span className="h-1.5 w-1.5 rounded-full bg-muted-foreground/60" />
        <span className="text-[10px] font-medium text-muted-foreground uppercase tracking-wider">Raw Output</span>
        <span className="text-[10px] text-muted-foreground/50 ml-auto">{lines.length} lines</span>
      </div>

      <ScrollArea className="flex-1 min-h-0">
        <div className="p-3 font-mono text-[11px] leading-relaxed text-muted-foreground whitespace-pre-wrap break-words">
          {lines.length === 0 ? (
            <span className="text-muted-foreground/40 italic">Waiting for AI output…</span>
          ) : (
            lines.map((line, i) => (
              <div key={i} className="hover:bg-muted/30 px-1 -mx-1 rounded-sm">
                {stripAnsi(line)}
              </div>
            ))
          )}
          <div ref={bottomRef} />
        </div>
      </ScrollArea>
    </div>
  )
}
