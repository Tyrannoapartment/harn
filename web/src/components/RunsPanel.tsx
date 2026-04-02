import { useEffect, useState, useCallback } from 'react'
import { Badge } from '@/components/ui/badge'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Skeleton } from '@/components/ui/skeleton'
import { CheckmarkCircle01Icon, Clock01Icon, Cancel01Icon, Layers01Icon } from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { api } from '@/lib/api'

interface SprintInfo {
  number: string
  status: string
  iteration: string
}

interface RunInfo {
  id: string
  prompt: string
  plan: string
  sprints: SprintInfo[]
  active: boolean
}

function statusBadge(status: string) {
  const map: Record<string, { variant: 'default' | 'secondary' | 'outline' | 'destructive'; icon: any; label: string }> = {
    pass: { variant: 'default', icon: CheckmarkCircle01Icon, label: 'Pass' },
    fail: { variant: 'destructive', icon: Cancel01Icon, label: 'Fail' },
    'in-progress': { variant: 'secondary', icon: Layers01Icon, label: 'Running' },
    pending: { variant: 'outline', icon: Clock01Icon, label: 'Pending' },
    cancelled: { variant: 'outline', icon: Cancel01Icon, label: 'Cancelled' },
  }
  const s = map[status] || map.pending
  return (
    <Badge variant={s.variant} className="text-[10px] h-5 px-1.5 gap-1">
      <HugeiconsIcon icon={s.icon} size={10} />
      {s.label}
    </Badge>
  )
}

export function RunsPanel() {
  const [runs, setRuns] = useState<RunInfo[]>([])
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    setLoading(true)
    try {
      const data = await api.getRuns()
      setRuns(data.runs || [])
    } catch { /* ignore */ }
    finally { setLoading(false) }
  }, [])

  useEffect(() => { load() }, [load])

  return (
    <div className="flex flex-col h-full">
      <div className="flex items-center justify-between px-4 py-3 border-b bg-muted/30 shrink-0">
        <h2 className="font-semibold text-sm">Runs</h2>
      </div>
      <ScrollArea className="flex-1">
        <div className="p-3 space-y-2">
          {loading ? (
            Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-20 w-full" />)
          ) : runs.length === 0 ? (
            <div className="text-center py-12 text-muted-foreground">
              <p className="text-sm">No runs yet</p>
            </div>
          ) : (
            runs.map((run) => (
              <div
                key={run.id}
                className={`rounded border p-3 transition-colors ${run.active ? 'border-primary/50 bg-primary/5' : 'hover:bg-muted/50'}`}
              >
                <div className="flex items-start justify-between gap-2 mb-1.5">
                  <div className="min-w-0">
                    <p className="font-mono text-xs font-medium truncate">{run.prompt}</p>
                    <p className="text-[10px] text-muted-foreground font-mono">{run.id}</p>
                  </div>
                  {run.active && <Badge variant="default" className="text-[10px] shrink-0">Active</Badge>}
                </div>
                {run.plan && (
                  <p className="text-xs text-muted-foreground italic line-clamp-1 mb-1.5">→ {run.plan}</p>
                )}
                <div className="flex flex-wrap gap-1">
                  {run.sprints.map((s) => (
                    <div key={s.number} className="flex items-center gap-1">
                      <span className="text-[10px] text-muted-foreground">#{s.number}</span>
                      {statusBadge(s.status)}
                    </div>
                  ))}
                </div>
              </div>
            ))
          )}
        </div>
      </ScrollArea>
    </div>
  )
}
