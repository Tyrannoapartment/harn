import { useEffect, useState } from 'react'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Skeleton } from '@/components/ui/skeleton'
import { api } from '@/lib/api'

export function MemoryPanel() {
  const [content, setContent] = useState('')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    api.getMemory()
      .then((data: { content: string }) => setContent(data.content || ''))
      .catch(() => {})
      .finally(() => setLoading(false))
  }, [])

  return (
    <div className="flex flex-col h-full">
      <div className="flex items-center justify-between px-4 py-3 border-b bg-muted/30 shrink-0">
        <h2 className="font-semibold text-sm">Project Memory</h2>
      </div>
      <ScrollArea className="flex-1">
        <div className="p-4">
          {loading ? (
            <div className="space-y-2">
              {Array.from({ length: 6 }).map((_, i) => <Skeleton key={i} className="h-4 w-full" />)}
            </div>
          ) : !content ? (
            <div className="text-center py-12 text-muted-foreground">
              <p className="text-sm">No memory yet</p>
              <p className="text-xs mt-1">Memory is saved from retrospectives</p>
            </div>
          ) : (
            <pre className="font-mono text-xs whitespace-pre-wrap break-words text-muted-foreground">
              {content}
            </pre>
          )}
        </div>
      </ScrollArea>
    </div>
  )
}
