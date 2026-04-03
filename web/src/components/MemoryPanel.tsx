import { useEffect, useState } from 'react'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Skeleton } from '@/components/ui/skeleton'
import { api } from '@/lib/api'
import { useI18n } from '@/hooks/useI18n'

export function MemoryPanel() {
  const { t } = useI18n()
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
      <ScrollArea className="flex-1 min-h-0">
        <div className="p-4">
          {loading ? (
            <div className="space-y-2">
              {Array.from({ length: 6 }).map((_, i) => <Skeleton key={i} className="h-4 w-full" />)}
            </div>
          ) : !content ? (
            <div className="text-center py-12 text-muted-foreground">
              <p className="text-sm">{t('memory.empty')}</p>
              <p className="text-xs mt-1">{t('memory.hint')}</p>
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
