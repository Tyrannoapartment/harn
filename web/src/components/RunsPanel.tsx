import { useEffect, useState, useCallback } from 'react'
import { Badge } from '@/components/ui/badge'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Skeleton } from '@/components/ui/skeleton'
import { Progress } from '@/components/ui/progress'
import { CheckmarkCircle01Icon, Clock01Icon, Cancel01Icon, Layers01Icon } from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { api } from '@/lib/api'
import type { RunInfo } from '@/lib/api'
import type { RunProgress } from '@/hooks/useSSE'
import { useI18n } from '@/hooks/useI18n'
import { t as translate } from '@/lib/i18n'

interface SSEHandle {
  onProgress: (fn: (p: RunProgress) => void) => () => void
}

function getPhaseLabel(phase: string): string {
  return translate(`phase.${phase}`) || phase
}

function statusBadge(status: string, isLive = false) {
  const labelKeys: Record<string, string> = {
    pass: 'runs.pass',
    fail: 'runs.fail',
    'in-progress': 'runs.running',
    pending: 'backlog.pending',
    cancelled: 'runs.cancelled',
  }
  const map: Record<string, { variant: 'default' | 'secondary' | 'outline' | 'destructive'; icon: any }> = {
    pass: { variant: 'default', icon: CheckmarkCircle01Icon },
    fail: { variant: 'destructive', icon: Cancel01Icon },
    'in-progress': { variant: 'secondary', icon: Layers01Icon },
    pending: { variant: 'outline', icon: Clock01Icon },
    cancelled: { variant: 'outline', icon: Cancel01Icon },
  }
  const s = map[status] || map.pending
  const label = translate(labelKeys[status] || 'backlog.pending')
  return (
    <Badge variant={s.variant} className={`text-[10px] h-5 px-1.5 gap-1 ${isLive ? 'animate-pulse' : ''}`}>
      <HugeiconsIcon icon={s.icon} size={10} />
      {label}
    </Badge>
  )
}

function formatElapsed(ms: number) {
  const s = Math.floor(ms / 1000)
  const m = Math.floor(s / 60)
  if (m > 0) return `${m}m ${s % 60}s`
  return `${s}s`
}

function RunProgressBar({ progress }: { progress: RunProgress | null }) {
  if (!progress) return null
  const { currentSprint, totalSprints, phase, iteration, elapsed } = progress
  const pct = totalSprints > 0
    ? Math.round(((currentSprint - 1) / totalSprints) * 100 + (phase === 'pass' ? 100 / totalSprints : 0))
    : 0

  return (
    <div className="space-y-1.5 mt-2 pt-2 border-t border-border/50">
      <div className="flex items-center justify-between text-[10px]">
        <span className="text-muted-foreground">
          {translate('runs.sprint')} {currentSprint}/{totalSprints} · {getPhaseLabel(phase)}
          {iteration > 1 && ` (iter ${iteration})`}
        </span>
        <span className="text-muted-foreground font-mono">{formatElapsed(elapsed)}</span>
      </div>
      <Progress value={Math.min(pct, 100)} className="h-1.5" />
    </div>
  )
}

export function RunsPanel({ sse }: { sse?: SSEHandle }) {
  const { t } = useI18n()
  const [runs, setRuns] = useState<RunInfo[]>([])
  const [loading, setLoading] = useState(true)
  const [liveProgress, setLiveProgress] = useState<RunProgress | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    try {
      const data = await api.getRuns()
      setRuns(data.runs || [])
    } catch { /* ignore */ }
    finally { setLoading(false) }
  }, [])

  useEffect(() => { load() }, [load])

  // SSE progress listener — live updates
  useEffect(() => {
    if (!sse) return
    return sse.onProgress((p: RunProgress) => {
      setLiveProgress(p)
      // Re-fetch run data periodically to reflect new sprint statuses
      if (p.phase === 'pass' || p.phase === 'fail' || p.phase === 'next') {
        load()
      }
    })
  }, [sse, load])

  // Also refresh when SSE says run status changed (via parent)
  useEffect(() => {
    const interval = setInterval(() => {
      if (runs.some((r) => r.isRunning)) load()
    }, 10000)
    return () => clearInterval(interval)
  }, [runs, load])

  return (
    <div className="flex flex-col h-full">
      <ScrollArea className="flex-1 min-h-0">
        <div className="p-3 space-y-2">
          {loading ? (
            Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-20 w-full" />)
          ) : runs.length === 0 ? (
            <div className="text-center py-12 text-muted-foreground">
              <p className="text-sm">{t('runs.empty')}</p>
            </div>
          ) : (
            runs.map((run) => (
              <div
                key={run.id}
                className={`rounded border p-3 transition-all duration-300 ${
                  run.isRunning ? 'border-emerald-500/50 bg-emerald-500/5 shadow-sm' :
                  run.active ? 'border-primary/50 bg-primary/5' :
                  run.completed ? 'opacity-80' : 'hover:bg-muted/50'
                }`}
              >
                <div className="flex items-start justify-between gap-2 mb-1.5">
                  <div className="min-w-0">
                    <p className="font-mono text-xs font-medium truncate">{run.prompt}</p>
                    <p className="text-[10px] text-muted-foreground font-mono">{run.id}</p>
                  </div>
                  <div className="flex items-center gap-1 shrink-0">
                    {run.isRunning ? (
                      <Badge variant="default" className="text-[10px] gap-1">
                        <span className="h-1.5 w-1.5 rounded-full bg-white animate-pulse" />
                        {t('runs.running')}
                      </Badge>
                    ) : run.completed ? (
                      <Badge variant="secondary" className="text-[10px]">{t('runs.done')}</Badge>
                    ) : run.active ? (
                      <Badge variant="outline" className="text-[10px]">{t('runs.active')}</Badge>
                    ) : null}
                  </div>
                </div>
                {run.plan && (
                  <p className="text-xs text-muted-foreground italic line-clamp-1 mb-1.5">→ {run.plan}</p>
                )}
                <div className="flex flex-wrap gap-1">
                  {run.sprints.map((s) => (
                    <div key={s.number} className="flex items-center gap-1">
                      <span className="text-[10px] text-muted-foreground">#{s.number}</span>
                      {statusBadge(s.status, run.isRunning && run.currentSprint?.toString().padStart(3, '0') === s.number && s.status === 'in-progress')}
                      {s.hasContract && <span className="text-[10px] text-blue-500">C</span>}
                      {s.hasImplementation && <span className="text-[10px] text-green-500">I</span>}
                      {s.hasQAReport && <span className="text-[10px] text-orange-500">Q</span>}
                    </div>
                  ))}
                </div>
                {run.isRunning && <RunProgressBar progress={liveProgress} />}
              </div>
            ))
          )}
        </div>
      </ScrollArea>
    </div>
  )
}
