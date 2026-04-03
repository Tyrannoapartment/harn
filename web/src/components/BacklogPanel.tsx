import { useEffect, useState, useCallback, useRef } from 'react'
import ReactMarkdown from 'react-markdown'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from '@/components/ui/accordion'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from '@/components/ui/tabs'
import {
  Clock01Icon,
  Layers01Icon,
  CheckmarkCircle01Icon,
  RefreshIcon,
  PlayIcon,
  Add01Icon,
  Search01Icon,
  More01Icon,
  Tag01Icon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { api } from '@/lib/api'
import { useI18n } from '@/hooks/useI18n'

interface BacklogItem {
  slug: string
  summary?: string
  description: string
  affectedFiles?: string
  implementationGuide?: string
  acceptanceCriteria?: string
  plan?: string
  raw?: string
  status: 'pending' | 'in-progress' | 'done'
}

interface Sections {
  pending: BacklogItem[]
  inProgress: BacklogItem[]
  done: BacklogItem[]
}

// ── Item detail dialog (Markdown viewer) ──────────────────────────────────────

function ItemDialog({
  item,
  open,
  onClose,
  onStart,
  onEdit,
  onDelete,
}: {
  item: BacklogItem | null
  open: boolean
  onClose: () => void
  onStart?: (slug: string) => void
  onEdit: (item: BacklogItem) => void
  onDelete: (slug: string) => void
}) {
  const { t } = useI18n()
  const [deleting, setDeleting] = useState(false)
  const [viewMode, setViewMode] = useState<'formatted' | 'raw'>('formatted')
  if (!item) return null
  const statusColor = {
    pending: 'text-muted-foreground',
    'in-progress': 'text-blue-500',
    done: 'text-emerald-500',
  }[item.status]
  const statusLabel = {
    pending: t('backlog.pending'),
    'in-progress': t('backlog.inProgress'),
    done: t('backlog.done'),
  }[item.status]

  const handleDelete = async () => {
    if (!confirm(t('backlog.deleteConfirm'))) return
    setDeleting(true)
    try { onDelete(item.slug) } finally { setDeleting(false) }
  }

  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent className="max-w-2xl max-h-[85vh] flex flex-col">
        <DialogHeader className="shrink-0">
          <div className="flex items-center justify-between gap-3">
            <DialogTitle className="font-mono text-sm flex items-center gap-2">
              <HugeiconsIcon icon={Tag01Icon} size={14} className="text-muted-foreground" />
              {item.slug}
            </DialogTitle>
            <div className="flex items-center gap-2">
              <span className={`text-xs font-medium ${statusColor}`}>{statusLabel}</span>
              {item.status === 'in-progress' && (
                <span className="h-1.5 w-1.5 rounded-full bg-blue-500 animate-pulse" />
              )}
            </div>
          </div>
          {item.summary && (
            <p className="text-sm text-muted-foreground mt-1">{item.summary}</p>
          )}
        </DialogHeader>

        <Tabs value={viewMode} onValueChange={(v) => setViewMode(v as 'formatted' | 'raw')} className="flex-1 min-h-0 flex flex-col">
          <TabsList className="w-fit h-7 shrink-0">
            <TabsTrigger value="formatted" className="text-xs h-5 px-2">{t('backlog.viewFormatted')}</TabsTrigger>
            <TabsTrigger value="raw" className="text-xs h-5 px-2">{t('backlog.viewRaw')}</TabsTrigger>
          </TabsList>

          <TabsContent value="formatted" className="flex-1 min-h-0 mt-2">
            <ScrollArea className="h-full max-h-[50vh]">
              <div className="prose prose-sm dark:prose-invert max-w-none pr-4
                prose-headings:text-foreground prose-headings:font-semibold
                prose-h2:text-sm prose-h2:border-b prose-h2:pb-1 prose-h2:mb-2 prose-h2:mt-4 first:prose-h2:mt-0
                prose-p:text-foreground/80 prose-p:text-sm prose-p:leading-relaxed
                prose-li:text-foreground/80 prose-li:text-sm
                prose-code:text-xs prose-code:bg-muted prose-code:px-1 prose-code:py-0.5 prose-code:rounded
                prose-pre:bg-muted prose-pre:text-xs
                prose-strong:text-foreground
                prose-ul:my-1 prose-ol:my-1
                [&_input[type=checkbox]]:mr-1.5 [&_input[type=checkbox]]:accent-primary
              ">
                <ReactMarkdown>{item.raw ? cleanRawMarkdown(item.raw) : buildMarkdown(item)}</ReactMarkdown>
              </div>
            </ScrollArea>
          </TabsContent>

          <TabsContent value="raw" className="flex-1 min-h-0 mt-2">
            <ScrollArea className="h-full max-h-[50vh]">
              <pre className="text-xs font-mono text-muted-foreground whitespace-pre-wrap bg-muted/40 rounded p-3 pr-4">
                {item.raw || buildMarkdown(item)}
              </pre>
            </ScrollArea>
          </TabsContent>
        </Tabs>

        <DialogFooter className="shrink-0">
          <Button variant="destructive" size="sm" onClick={handleDelete} disabled={deleting}>
            {deleting ? t('backlog.deleting') : t('backlog.delete')}
          </Button>
          <div className="flex-1" />
          <Button variant="ghost" size="sm" onClick={onClose}>{t('backlog.close')}</Button>
          <Button variant="outline" size="sm" onClick={() => { onEdit(item); onClose() }}>
            {t('backlog.edit')}
          </Button>
          {item.status === 'pending' && onStart && (
            <Button size="sm" onClick={() => { onStart(item.slug); onClose() }}>
              <HugeiconsIcon icon={PlayIcon} size={12} className="mr-1.5" />
              {t('backlog.start')}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function buildMarkdown(item: BacklogItem): string {
  const lines: string[] = [`# ${item.slug}`, '']
  if (item.summary) lines.push('## Summary', '', item.summary, '')
  if (item.description) lines.push('## Description', '', item.description, '')
  if (item.affectedFiles) lines.push('## Affected Files', '', item.affectedFiles, '')
  if (item.implementationGuide) lines.push('## Implementation Guide', '', item.implementationGuide, '')
  if (item.acceptanceCriteria) lines.push('## Acceptance Criteria', '', item.acceptanceCriteria, '')
  if (item.plan) lines.push('## Plan', '', item.plan, '')
  return lines.join('\n')
}

/** Strip empty sections (## Header with no body) from raw markdown */
function cleanRawMarkdown(raw: string): string {
  // Split into sections by ## headers, filter out empty ones
  const sections = raw.split(/(?=^## )/m)
  return sections
    .filter((section) => {
      // Keep non-section content (e.g. # title)
      if (!section.startsWith('## ')) return true
      // Check if section has content after the header line
      const body = section.replace(/^## .+\n?/, '').trim()
      return body.length > 0
    })
    .join('')
    .trim()
}

// ── Add item dialog (Jira-like ticket form) ──────────────────────────────────

function AddItemDialog({
  open,
  onClose,
  onAdd,
}: {
  open: boolean
  onClose: () => void
  onAdd: (slug: string, description: string, plan: string, extra: { summary?: string; affectedFiles?: string; implementationGuide?: string; acceptanceCriteria?: string }) => Promise<void>
}) {
  const { t } = useI18n()
  const [slug, setSlug] = useState('')
  const [summary, setSummary] = useState('')
  const [desc, setDesc] = useState('')
  const [affectedFiles, setAffectedFiles] = useState('')
  const [implGuide, setImplGuide] = useState('')
  const [criteria, setCriteria] = useState('')
  const [busy, setBusy] = useState(false)
  const slugRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (open) {
      setSlug(''); setSummary(''); setDesc(''); setAffectedFiles(''); setImplGuide(''); setCriteria(''); setBusy(false)
      setTimeout(() => slugRef.current?.focus(), 50)
    }
  }, [open])

  const handleSlugChange = (v: string) => {
    setSlug(v.replace(/\s+/g, '-').toLowerCase())
  }

  const handleAdd = async () => {
    const cleanSlug = slug.trim()
    if (!cleanSlug) return
    setBusy(true)
    try {
      await onAdd(cleanSlug, desc.trim(), '', {
        summary: summary.trim(),
        affectedFiles: affectedFiles.trim(),
        implementationGuide: implGuide.trim(),
        acceptanceCriteria: criteria.trim(),
      })
    } finally { setBusy(false) }
  }

  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent className="max-w-lg max-h-[85vh] flex flex-col">
        <DialogHeader className="shrink-0">
          <DialogTitle className="text-sm">{t('backlog.addTitle')}</DialogTitle>
        </DialogHeader>

        <ScrollArea className="flex-1 min-h-0">
          <div className="space-y-3 pr-4">
            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">{t('backlog.slug')} <span className="text-destructive">*</span></label>
              <Input
                ref={slugRef}
                className="h-8 text-xs font-mono"
                placeholder="e.g. backend-layer-boundary-cleanup"
                value={slug}
                onChange={(e) => handleSlugChange(e.target.value)}
              />
              <p className="text-[10px] text-muted-foreground">{t('backlog.slugHint')}</p>
            </div>

            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">{t('backlog.summary')}</label>
              <Input
                className="h-8 text-xs"
                placeholder={t('backlog.summaryHint')}
                value={summary}
                onChange={(e) => setSummary(e.target.value)}
              />
            </div>

            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">{t('backlog.description')}</label>
              <Textarea
                className="text-xs resize-none min-h-[80px]"
                placeholder="Detailed description of what needs to be done…"
                value={desc}
                onChange={(e) => setDesc(e.target.value)}
              />
            </div>

            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">{t('backlog.affectedFiles')}</label>
              <Textarea
                className="text-xs resize-none min-h-[60px] font-mono"
                placeholder={`- src/server/routes/api.js\n- web/src/components/BacklogPanel.tsx`}
                value={affectedFiles}
                onChange={(e) => setAffectedFiles(e.target.value)}
              />
              <p className="text-[10px] text-muted-foreground">{t('backlog.affectedFilesHint')}</p>
            </div>

            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">{t('backlog.implementationGuide')}</label>
              <Textarea
                className="text-xs resize-none min-h-[80px]"
                placeholder={t('backlog.implementationGuideHint')}
                value={implGuide}
                onChange={(e) => setImplGuide(e.target.value)}
              />
            </div>

            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">{t('backlog.acceptanceCriteria')}</label>
              <Textarea
                className="text-xs resize-none min-h-[60px]"
                placeholder={`- [ ] Criterion 1\n- [ ] Criterion 2`}
                value={criteria}
                onChange={(e) => setCriteria(e.target.value)}
              />
              <p className="text-[10px] text-muted-foreground">{t('backlog.acceptanceCriteriaHint')}</p>
            </div>
          </div>
        </ScrollArea>

        <DialogFooter className="shrink-0">
          <Button variant="ghost" size="sm" onClick={onClose}>{t('backlog.cancel')}</Button>
          <Button size="sm" disabled={!slug.trim() || busy} onClick={handleAdd}>
            {busy ? t('backlog.adding') : t('backlog.add')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// ── Edit item dialog ──────────────────────────────────────────────────────────

function EditItemDialog({
  item,
  open,
  onClose,
  onSave,
}: {
  item: BacklogItem | null
  open: boolean
  onClose: () => void
  onSave: (originalSlug: string, data: { newSlug?: string; summary?: string; description?: string; affectedFiles?: string; implementationGuide?: string; acceptanceCriteria?: string; plan?: string }) => Promise<void>
}) {
  const { t } = useI18n()
  const [slug, setSlug] = useState('')
  const [summary, setSummary] = useState('')
  const [desc, setDesc] = useState('')
  const [affectedFiles, setAffectedFiles] = useState('')
  const [implGuide, setImplGuide] = useState('')
  const [criteria, setCriteria] = useState('')
  const [plan, setPlan] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (open && item) {
      setSlug(item.slug)
      setSummary(item.summary || '')
      setDesc(item.description || '')
      setAffectedFiles(item.affectedFiles || '')
      setImplGuide(item.implementationGuide || '')
      setCriteria(item.acceptanceCriteria || '')
      setPlan(item.plan || '')
      setBusy(false)
    }
  }, [open, item])

  const handleSlugChange = (v: string) => {
    setSlug(v.replace(/\s+/g, '-').toLowerCase())
  }

  const handleSave = async () => {
    if (!item || !slug.trim()) return
    setBusy(true)
    try {
      await onSave(item.slug, {
        newSlug: slug.trim() !== item.slug ? slug.trim() : undefined,
        summary: summary.trim(),
        description: desc.trim(),
        affectedFiles: affectedFiles.trim(),
        implementationGuide: implGuide.trim(),
        acceptanceCriteria: criteria.trim(),
        plan: plan.trim(),
      })
    } finally { setBusy(false) }
  }

  if (!item) return null

  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent className="max-w-lg max-h-[85vh] flex flex-col">
        <DialogHeader className="shrink-0">
          <DialogTitle className="text-sm">{t('backlog.editTitle')}</DialogTitle>
        </DialogHeader>

        <ScrollArea className="flex-1 min-h-0">
          <div className="space-y-3 pr-4">
            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">{t('backlog.slug')} <span className="text-destructive">*</span></label>
              <Input
                className="h-8 text-xs font-mono"
                value={slug}
                onChange={(e) => handleSlugChange(e.target.value)}
              />
              <p className="text-[10px] text-muted-foreground">{t('backlog.slugHint')}</p>
            </div>

            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">{t('backlog.summary')}</label>
              <Input
                className="h-8 text-xs"
                placeholder={t('backlog.summaryHint')}
                value={summary}
                onChange={(e) => setSummary(e.target.value)}
              />
            </div>

            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">{t('backlog.description')}</label>
              <Textarea
                className="text-xs resize-none min-h-[80px]"
                value={desc}
                onChange={(e) => setDesc(e.target.value)}
              />
            </div>

            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">{t('backlog.affectedFiles')}</label>
              <Textarea
                className="text-xs resize-none min-h-[60px] font-mono"
                placeholder={`- src/server/routes/api.js\n- web/src/components/BacklogPanel.tsx`}
                value={affectedFiles}
                onChange={(e) => setAffectedFiles(e.target.value)}
              />
            </div>

            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">{t('backlog.implementationGuide')}</label>
              <Textarea
                className="text-xs resize-none min-h-[80px]"
                placeholder={t('backlog.implementationGuideHint')}
                value={implGuide}
                onChange={(e) => setImplGuide(e.target.value)}
              />
            </div>

            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">{t('backlog.acceptanceCriteria')}</label>
              <Textarea
                className="text-xs resize-none min-h-[60px]"
                placeholder={`- [ ] Criterion 1\n- [ ] Criterion 2`}
                value={criteria}
                onChange={(e) => setCriteria(e.target.value)}
              />
            </div>

            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">{t('backlog.plan')}</label>
              <Textarea
                className="text-xs resize-none min-h-[60px]"
                value={plan}
                onChange={(e) => setPlan(e.target.value)}
              />
            </div>
          </div>
        </ScrollArea>

        <DialogFooter className="shrink-0">
          <Button variant="ghost" size="sm" onClick={onClose}>{t('backlog.cancel')}</Button>
          <Button size="sm" disabled={!slug.trim() || busy} onClick={handleSave}>
            {busy ? t('backlog.saving') : t('backlog.save')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// ── Item card ─────────────────────────────────────────────────────────────────

function ItemCard({
  item,
  onStart,
  onDetail,
  onEdit,
  onDelete,
}: {
  item: BacklogItem
  onStart?: () => void
  onDetail: () => void
  onEdit: () => void
  onDelete: () => void
}) {
  const { t } = useI18n()
  const isActive = item.status === 'in-progress'
  const isDone   = item.status === 'done'

  return (
    <div
      className={`group rounded border bg-background transition-colors cursor-pointer hover:bg-muted/30 ${
        isActive ? 'border-blue-500/40 bg-blue-500/5' : ''
      } ${isDone ? 'opacity-60' : ''}`}
      onClick={onDetail}
    >
      <div className="flex items-start gap-2 px-3 pt-2.5 pb-1">
        {isActive && <span className="h-1.5 w-1.5 rounded-full bg-blue-500 animate-pulse mt-1 shrink-0" />}
        <div className="flex-1 min-w-0">
          <span className={`font-mono text-xs font-semibold ${isDone ? 'line-through text-muted-foreground' : ''}`}>
            {item.slug}
          </span>
        </div>
        <div className="flex items-center gap-1 shrink-0 opacity-0 group-hover:opacity-100 transition-opacity" onClick={(e) => e.stopPropagation()}>
          {onStart && (
            <Button size="sm" variant="secondary" className="h-5 text-[10px] px-2 gap-1" onClick={onStart}>
              <HugeiconsIcon icon={PlayIcon} size={9} />
              {t('backlog.start')}
            </Button>
          )}
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button size="icon" variant="ghost" className="h-5 w-5">
                <HugeiconsIcon icon={More01Icon} size={11} />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="text-xs">
              <DropdownMenuItem className="text-xs" onClick={onDetail}>
                {t('backlog.details')}
              </DropdownMenuItem>
              <DropdownMenuItem className="text-xs" onClick={onEdit}>
                {t('backlog.edit')}
              </DropdownMenuItem>
              <DropdownMenuItem className="text-xs text-destructive" onClick={onDelete}>
                {t('backlog.delete')}
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>

      {item.description && (
        <p className="px-3 text-xs text-muted-foreground leading-relaxed line-clamp-2">
          {item.summary || item.description}
        </p>
      )}

      {item.affectedFiles && (
        <div className="px-3 pb-0.5 pt-0.5">
          <div className="inline-flex items-center gap-1 rounded bg-blue-500/10 px-1.5 py-0.5 max-w-full">
            <span className="text-[10px] text-blue-500/80 truncate">
              {item.affectedFiles.split('\n').filter(l => l.trim()).length} files
            </span>
          </div>
        </div>
      )}

      {item.plan && (
        <div className="px-3 pb-2.5 pt-1">
          <div className="inline-flex items-center gap-1 rounded bg-muted/60 px-1.5 py-0.5 max-w-full">
            <HugeiconsIcon icon={Tag01Icon} size={9} className="text-muted-foreground shrink-0" />
            <span className="text-[10px] text-muted-foreground truncate">{item.plan}</span>
          </div>
        </div>
      )}

      {!item.description && !item.plan && <div className="pb-2" />}
    </div>
  )
}

// ── Section header ────────────────────────────────────────────────────────────

function SectionHeader({ icon, label, count, color, dot }: {
  icon: any; label: string; count: number; color: string; dot?: string
}) {
  return (
    <div className="flex items-center gap-2 w-full">
      {dot ? (
        <span className={`h-2 w-2 rounded-full ${dot} shrink-0`} />
      ) : (
        <HugeiconsIcon icon={icon} size={14} className={color} />
      )}
      <span className="text-xs font-semibold flex-1 text-left">{label}</span>
      <Badge variant="secondary" className="text-[10px] h-4 px-1.5 mr-2 tabular-nums">{count}</Badge>
    </div>
  )
}

// ── Main component ────────────────────────────────────────────────────────────

export function BacklogPanel() {
  const { t } = useI18n()
  const [sections, setSections] = useState<Sections>({ pending: [], inProgress: [], done: [] })
  const [loading, setLoading] = useState(true)
  const [openSections, setOpenSections] = useState<string[]>(['pending', 'in-progress'])
  const [query, setQuery] = useState('')
  const [selected, setSelected] = useState<BacklogItem | null>(null)
  const [editing, setEditing] = useState<BacklogItem | null>(null)
  const [showAdd, setShowAdd] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    try {
      const data = await api.getBacklog()
      const pending: BacklogItem[] = []
      const inProgress: BacklogItem[] = []
      const done: BacklogItem[] = []
      for (const item of data.items || []) {
        const s = (['pending', 'in-progress', 'done'].includes(item.status) ? item.status : 'pending') as BacklogItem['status']
        if (s === 'pending') pending.push({ ...item, status: s })
        else if (s === 'in-progress') inProgress.push({ ...item, status: s })
        else done.push({ ...item, status: s })
      }
      setSections({ pending, inProgress, done })
    } catch { /* ignore */ }
    finally { setLoading(false) }
  }, [])

  useEffect(() => { load() }, [load])

  const startItem = async (slug: string) => {
    try { await api.startRun(slug); await load() } catch { /* ignore */ }
  }

  const addItem = async (slug: string, description: string, _plan: string, extra: { summary?: string; affectedFiles?: string; implementationGuide?: string; acceptanceCriteria?: string }) => {
    await api.addBacklogItem(slug, description, _plan, extra)
    setShowAdd(false)
    await load()
  }

  const editItem = async (originalSlug: string, data: { newSlug?: string; summary?: string; description?: string; affectedFiles?: string; implementationGuide?: string; acceptanceCriteria?: string; plan?: string }) => {
    await api.updateBacklogItem(originalSlug, data)
    setEditing(null)
    await load()
  }

  const deleteItem = async (slug: string) => {
    await api.deleteBacklogItem(slug)
    setSelected(null)
    await load()
  }

  const filter = (items: BacklogItem[]) =>
    query ? items.filter(i =>
      i.slug.includes(query) || i.description?.toLowerCase().includes(query.toLowerCase())
    ) : items

  const total = sections.pending.length + sections.inProgress.length + sections.done.length

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="px-4 py-3 border-b bg-muted/30 shrink-0 space-y-2">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <Badge variant="outline" className="text-[10px] h-4 px-1.5 tabular-nums">{total}</Badge>
          </div>
          <div className="flex items-center gap-1">
            <Button size="icon" variant="ghost" className="h-7 w-7" onClick={() => setShowAdd(true)}>
              <HugeiconsIcon icon={Add01Icon} size={14} />
            </Button>
            <Button size="icon" variant="ghost" className="h-7 w-7" onClick={load}>
              <HugeiconsIcon icon={RefreshIcon} size={14} />
            </Button>
          </div>
        </div>

        {/* Search */}
        <div className="relative">
          <HugeiconsIcon icon={Search01Icon} size={12} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-muted-foreground" />
          <Input
            className="h-7 text-xs pl-7 bg-background"
            placeholder={t('backlog.search')}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>
      </div>

      {/* Content */}
      <ScrollArea className="flex-1 min-h-0">
        <div className="p-3">
          {loading ? (
            <div className="space-y-2">
              {Array.from({ length: 4 }).map((_, i) => <Skeleton key={i} className="h-16 w-full" />)}
            </div>
          ) : total === 0 ? (
            <div className="flex flex-col items-center justify-center py-16 text-center gap-2">
              <HugeiconsIcon icon={Layers01Icon} size={32} className="text-muted-foreground/30" />
              <p className="text-sm text-muted-foreground">{t('backlog.empty')}</p>
              <Button size="sm" variant="outline" className="mt-1 gap-1.5 text-xs" onClick={() => setShowAdd(true)}>
                <HugeiconsIcon icon={Add01Icon} size={12} />
                {t('backlog.addFirst')}
              </Button>
            </div>
          ) : (
            <Accordion type="multiple" value={openSections} onValueChange={setOpenSections} className="space-y-1.5">

              {/* 대기중 */}
              <AccordionItem value="pending" className="border rounded overflow-hidden">
                <AccordionTrigger className="px-3 py-2.5 hover:no-underline hover:bg-muted/40 [&>svg]:hidden">
                  <SectionHeader
                    icon={Clock01Icon}
                    label={t('backlog.pending')}
                    count={filter(sections.pending).length}
                    color="text-muted-foreground"
                  />
                </AccordionTrigger>
                <AccordionContent className="pb-0">
                  <div className="px-2 pb-2 space-y-1.5 border-t pt-2">
                    {filter(sections.pending).length === 0 ? (
                      <p className="text-xs text-muted-foreground text-center py-3">{t('backlog.emptySection')}</p>
                    ) : filter(sections.pending).map((item) => (
                      <ItemCard
                        key={item.slug}
                        item={item}
                        onStart={() => startItem(item.slug)}
                        onDetail={() => setSelected(item)}
                        onEdit={() => setEditing(item)}
                        onDelete={() => deleteItem(item.slug)}
                      />
                    ))}
                  </div>
                </AccordionContent>
              </AccordionItem>

              <AccordionItem value="in-progress" className="border rounded overflow-hidden">
                <AccordionTrigger className="px-3 py-2.5 hover:no-underline hover:bg-muted/40 [&>svg]:hidden">
                  <SectionHeader
                    icon={Layers01Icon}
                    label={t('backlog.inProgress')}
                    count={filter(sections.inProgress).length}
                    color="text-blue-500"
                    dot="bg-blue-500 animate-pulse"
                  />
                </AccordionTrigger>
                <AccordionContent className="pb-0">
                  <div className="px-2 pb-2 space-y-1.5 border-t pt-2">
                    {filter(sections.inProgress).length === 0 ? (
                      <p className="text-xs text-muted-foreground text-center py-3">{t('backlog.emptySection')}</p>
                    ) : filter(sections.inProgress).map((item) => (
                      <ItemCard key={item.slug} item={item} onDetail={() => setSelected(item)} onEdit={() => setEditing(item)} onDelete={() => deleteItem(item.slug)} />
                    ))}
                  </div>
                </AccordionContent>
              </AccordionItem>

              <AccordionItem value="done" className="border rounded overflow-hidden">
                <AccordionTrigger className="px-3 py-2.5 hover:no-underline hover:bg-muted/40 [&>svg]:hidden">
                  <SectionHeader
                    icon={CheckmarkCircle01Icon}
                    label={t('backlog.done')}
                    count={filter(sections.done).length}
                    color="text-emerald-500"
                  />
                </AccordionTrigger>
                <AccordionContent className="pb-0">
                  <div className="px-2 pb-2 space-y-1.5 border-t pt-2">
                    {filter(sections.done).length === 0 ? (
                      <p className="text-xs text-muted-foreground text-center py-3">{t('backlog.emptySection')}</p>
                    ) : filter(sections.done).map((item) => (
                      <ItemCard key={item.slug} item={item} onDetail={() => setSelected(item)} onEdit={() => setEditing(item)} onDelete={() => deleteItem(item.slug)} />
                    ))}
                  </div>
                </AccordionContent>
              </AccordionItem>

            </Accordion>
          )}
        </div>
      </ScrollArea>

      {/* Dialogs */}
      <ItemDialog
        item={selected}
        open={!!selected}
        onClose={() => setSelected(null)}
        onStart={startItem}
        onEdit={(item) => setEditing(item)}
        onDelete={deleteItem}
      />
      <AddItemDialog open={showAdd} onClose={() => setShowAdd(false)} onAdd={addItem} />
      <EditItemDialog item={editing} open={!!editing} onClose={() => setEditing(null)} onSave={editItem} />
    </div>
  )
}
