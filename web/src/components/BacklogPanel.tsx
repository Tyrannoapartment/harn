import { useEffect, useState, useCallback } from 'react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Add01Icon,
  CheckmarkCircle01Icon,
  Clock01Icon,
  Layers01Icon,
  Delete01Icon,
  RefreshIcon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { api } from '@/lib/api'

interface BacklogItem {
  slug: string
  description: string
  plan?: string
  status: 'pending' | 'in-progress' | 'done'
}

const STATUS_MAP = {
  pending: { label: 'Pending', variant: 'secondary' as const, icon: Clock01Icon },
  'in-progress': { label: 'In Progress', variant: 'default' as const, icon: Layers01Icon },
  done: { label: 'Done', variant: 'outline' as const, icon: CheckmarkCircle01Icon },
}

export function BacklogPanel() {
  const [items, setItems] = useState<BacklogItem[]>([])
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    setLoading(true)
    try {
      const data = await api.getBacklog()
      const mapped = (data.items || []).map((item) => ({
        ...item,
        status: (['pending', 'in-progress', 'done'].includes(item.status)
          ? item.status
          : 'pending') as BacklogItem['status'],
      }))
      setItems(mapped)
    } catch { /* ignore */ }
    finally { setLoading(false) }
  }, [])

  useEffect(() => { load() }, [load])

  const startItem = async (slug: string) => {
    try { await api.startRun(slug) } catch { /* ignore */ }
  }

  return (
    <div className="flex flex-col h-full">
      <div className="flex items-center justify-between px-4 py-3 border-b bg-muted/30 shrink-0">
        <h2 className="font-semibold text-sm">Backlog</h2>
        <div className="flex gap-1">
          <Button size="icon" variant="ghost" className="h-7 w-7" onClick={load}>
            <HugeiconsIcon icon={RefreshIcon} size={14} />
          </Button>
          <Button size="icon" variant="ghost" className="h-7 w-7" onClick={() => api.addToBacklog('')}>
            <HugeiconsIcon icon={Add01Icon} size={14} />
          </Button>
        </div>
      </div>

      <ScrollArea className="flex-1">
        <div className="p-3 space-y-2">
          {loading ? (
            Array.from({ length: 4 }).map((_, i) => (
              <Skeleton key={i} className="h-16 w-full" />
            ))
          ) : items.length === 0 ? (
            <div className="text-center py-12 text-muted-foreground">
              <HugeiconsIcon icon={Delete01Icon} size={32} className="mx-auto mb-2 opacity-30" />
              <p className="text-sm">No backlog items</p>
            </div>
          ) : (
            items.map((item) => {
              const s = STATUS_MAP[item.status]
              return (
                <div
                  key={item.slug}
                  className="rounded border p-3 hover:bg-muted/50 transition-colors"
                >
                  <div className="flex items-start justify-between gap-2">
                    <div className="flex-1 min-w-0">
                      <p className="font-mono text-xs font-medium truncate">{item.slug}</p>
                      <p className="text-xs text-muted-foreground mt-0.5 line-clamp-2">
                        {item.description}
                      </p>
                      {item.plan && (
                        <p className="text-xs text-muted-foreground/70 mt-1 italic line-clamp-1">
                          → {item.plan}
                        </p>
                      )}
                    </div>
                    <div className="flex flex-col items-end gap-1.5 shrink-0">
                      <Badge variant={s.variant} className="text-[10px] h-5 px-1.5 gap-1">
                        <HugeiconsIcon icon={s.icon} size={10} />
                        {s.label}
                      </Badge>
                      {item.status === 'pending' && (
                        <Button
                          size="sm"
                          variant="secondary"
                          className="h-6 text-[10px] px-2"
                          onClick={() => startItem(item.slug)}
                        >
                          Start
                        </Button>
                      )}
                    </div>
                  </div>
                </div>
              )
            })
          )}
        </div>
      </ScrollArea>
    </div>
  )
}
