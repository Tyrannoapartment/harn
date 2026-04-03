import { useState, useEffect, useRef, useCallback } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import type { ResultFile } from '@/hooks/useConsoleSessions'

// ── Helpers ──

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-9;]*m/g, '')
}

// ── Types ──

export interface FileChange {
  type: 'modified' | 'added' | 'deleted' | 'renamed'
  path: string
  stat?: string // e.g. "3 insertions(+), 1 deletion(-)"
}

export interface ArtifactEntry {
  phase: string
  label: string
  content: string
  timestamp: number
}

type RightTab = 'viewer' | 'output' | 'changes' | 'artifacts'

interface RightPanelProps {
  rawLines: string[]
  fileChanges: FileChange[]
  artifacts: ArtifactEntry[]
  viewerFile?: ResultFile | null
  activeTab?: RightTab
  onTabChange?: (tab: RightTab) => void
}

// ── Tab: Raw Output ──

function RawOutputTab({ lines }: { lines: string[] }) {
  const bottomRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [lines])

  return (
    <ScrollArea className="flex-1 min-h-0">
      <div className="p-4 px-5 font-mono text-[11px] leading-relaxed text-muted-foreground whitespace-pre-wrap break-words">
        {lines.length === 0 ? (
          <span className="text-muted-foreground/40 italic">Waiting for output…</span>
        ) : (
          lines.map((line, i) => (
            <div key={i} className="hover:bg-muted/30 px-2 -mx-2 py-0.5 rounded-sm">
              {stripAnsi(line)}
            </div>
          ))
        )}
        <div ref={bottomRef} />
      </div>
    </ScrollArea>
  )
}

// ── Tab: File Changes ──

const CHANGE_COLORS: Record<string, string> = {
  modified: 'text-yellow-500',
  added: 'text-emerald-500',
  deleted: 'text-red-500',
  renamed: 'text-blue-500',
}

const CHANGE_ICONS: Record<string, string> = {
  modified: 'M',
  added: 'A',
  deleted: 'D',
  renamed: 'R',
}

function FileChangesTab({ changes }: { changes: FileChange[] }) {
  const bottomRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [changes])

  return (
    <ScrollArea className="flex-1 min-h-0">
      <div className="p-4 px-5 font-mono text-[11px]">
        {changes.length === 0 ? (
          <span className="text-muted-foreground/40 italic">No file changes yet…</span>
        ) : (
          <div className="space-y-0.5">
            {changes.map((c, i) => (
              <div key={i} className="flex items-center gap-2 hover:bg-muted/30 px-2 -mx-2 py-1 rounded-sm">
                <span className={cn('font-bold w-4 text-center shrink-0', CHANGE_COLORS[c.type])}>
                  {CHANGE_ICONS[c.type]}
                </span>
                <span className="text-foreground truncate flex-1">{c.path}</span>
                {c.stat && (
                  <span className="text-muted-foreground/60 text-[10px] shrink-0">{c.stat}</span>
                )}
              </div>
            ))}
          </div>
        )}
        <div ref={bottomRef} />
      </div>
    </ScrollArea>
  )
}

// ── Tab: Sprint Artifacts ──

function ArtifactsTab({ artifacts }: { artifacts: ArtifactEntry[] }) {
  const [expanded, setExpanded] = useState<number | null>(null)
  const bottomRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [artifacts])

  const PHASE_BADGE: Record<string, { label: string; variant: 'default' | 'secondary' | 'destructive' }> = {
    plan: { label: '📋 Plan', variant: 'secondary' },
    contract: { label: '📝 Contract', variant: 'secondary' },
    'contract-review': { label: '🔍 Review', variant: 'secondary' },
    implement: { label: '⚡ Impl', variant: 'default' },
    evaluate: { label: '🔍 QA', variant: 'secondary' },
  }

  return (
    <ScrollArea className="flex-1 min-h-0">
      <div className="p-4 px-5 font-mono text-[11px]">
        {artifacts.length === 0 ? (
          <span className="text-muted-foreground/40 italic">No sprint artifacts yet…</span>
        ) : (
          <div className="space-y-2">
            {artifacts.map((a, i) => {
              const badge = PHASE_BADGE[a.phase] || { label: a.phase, variant: 'secondary' as const }
              const isOpen = expanded === i
              return (
                <div key={i} className="border rounded-md overflow-hidden">
                  <button
                    onClick={() => setExpanded(isOpen ? null : i)}
                    className="flex items-center gap-2 w-full px-3 py-2 text-left hover:bg-muted/30 transition-colors"
                  >
                    <Badge variant={badge.variant} className="text-[10px] h-5 px-2 shrink-0">
                      {badge.label}
                    </Badge>
                    <span className="text-foreground truncate flex-1 text-xs">{a.label}</span>
                    <span className="text-muted-foreground/50 text-[10px] shrink-0">
                      {isOpen ? '▼' : '▶'}
                    </span>
                  </button>
                  {isOpen && (
                    <div className="border-t px-3 py-2 text-muted-foreground whitespace-pre-wrap break-words leading-relaxed max-h-[400px] overflow-auto">
                      {stripAnsi(a.content)}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}
        <div ref={bottomRef} />
      </div>
    </ScrollArea>
  )
}

// ── Tab: File Viewer ──

const VIEWER_PROSE = 'prose prose-sm dark:prose-invert max-w-none prose-p:my-1.5 prose-ul:my-1 prose-ol:my-1 prose-li:my-0.5 prose-headings:my-2 prose-pre:my-1 prose-code:text-xs prose-code:bg-muted prose-code:px-1 prose-code:py-0.5 prose-code:rounded prose-code:before:content-none prose-code:after:content-none prose-table:border-collapse prose-th:border prose-th:border-border prose-th:px-2 prose-th:py-1 prose-th:bg-muted prose-td:border prose-td:border-border prose-td:px-2 prose-td:py-1'

function ViewerTab({ file }: { file: ResultFile | null | undefined }) {
  if (!file) {
    return (
      <div className="flex-1 flex items-center justify-center text-muted-foreground/40 text-xs italic">
        Click a file in the chat to view it here
      </div>
    )
  }
  return (
    <ScrollArea className="flex-1 min-h-0">
      <div className="p-4 px-5">
        <div className="flex items-center gap-2 mb-3 pb-2 border-b">
          <span className="text-sm">📄</span>
          <span className="text-xs font-mono text-foreground font-medium truncate">{file.name}</span>
        </div>
        <div className={VIEWER_PROSE}>
          <ReactMarkdown remarkPlugins={[remarkGfm]}>{file.content}</ReactMarkdown>
        </div>
      </div>
    </ScrollArea>
  )
}

// ── Main Component ──

const TABS: { key: RightTab; label: string }[] = [
  { key: 'viewer', label: 'Viewer' },
  { key: 'output', label: 'Raw Output' },
  { key: 'changes', label: 'File Changes' },
  { key: 'artifacts', label: 'Artifacts' },
]

export function RightPanel({ rawLines, fileChanges, artifacts, viewerFile, activeTab: controlledTab, onTabChange }: RightPanelProps) {
  const [internalTab, setInternalTab] = useState<RightTab>('viewer')
  const tab = controlledTab ?? internalTab

  const setTab = useCallback((t: RightTab) => {
    setInternalTab(t)
    onTabChange?.(t)
  }, [onTabChange])

  // Auto-switch to viewer tab when a new file is selected
  const prevViewerRef = useRef(viewerFile)
  useEffect(() => {
    if (viewerFile && viewerFile !== prevViewerRef.current) {
      setTab('viewer')
    }
    prevViewerRef.current = viewerFile
  }, [viewerFile, setTab])

  // Auto-switch to changes tab when new file changes arrive
  const prevChangesLen = useRef(fileChanges.length)
  useEffect(() => {
    if (fileChanges.length > prevChangesLen.current && fileChanges.length > 0) {
      setTab('changes')
    }
    prevChangesLen.current = fileChanges.length
  }, [fileChanges.length, setTab])

  // Auto-switch to artifacts tab when new artifacts arrive
  const prevArtifactsLen = useRef(artifacts.length)
  useEffect(() => {
    if (artifacts.length > prevArtifactsLen.current && artifacts.length > 0) {
      setTab('artifacts')
    }
    prevArtifactsLen.current = artifacts.length
  }, [artifacts.length, setTab])

  return (
    <div className="flex flex-col h-full bg-background">
      {/* Tab bar */}
      <div className="flex items-center gap-0.5 px-2 h-9 border-b bg-muted/30 shrink-0">
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={cn(
              'h-7 px-3 text-[10px] font-medium rounded-md transition-colors uppercase tracking-wider',
              tab === t.key
                ? 'bg-background text-foreground shadow-sm border'
                : 'text-muted-foreground hover:text-foreground hover:bg-muted',
            )}
          >
            {t.label}
            {t.key === 'changes' && fileChanges.length > 0 && (
              <span className="ml-1.5 text-[9px] text-muted-foreground/70">{fileChanges.length}</span>
            )}
            {t.key === 'artifacts' && artifacts.length > 0 && (
              <span className="ml-1.5 text-[9px] text-muted-foreground/70">{artifacts.length}</span>
            )}
          </button>
        ))}
      </div>

      {/* Tab content */}
      {tab === 'viewer' && <ViewerTab file={viewerFile} />}
      {tab === 'output' && <RawOutputTab lines={rawLines} />}
      {tab === 'changes' && <FileChangesTab changes={fileChanges} />}
      {tab === 'artifacts' && <ArtifactsTab artifacts={artifacts} />}
    </div>
  )
}
