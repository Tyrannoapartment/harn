import { useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Textarea } from '@/components/ui/textarea'
import { api, type PromptInfo } from '@/lib/api'
import { useI18n } from '@/hooks/useI18n'

export function PromptsPanel() {
  const { t } = useI18n()
  const [prompts, setPrompts] = useState<PromptInfo[]>([])
  const [selected, setSelected] = useState<string | null>(null)
  const [editing, setEditing] = useState(false)
  const [editContent, setEditContent] = useState('')
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    api.getPrompts().then((data) => setPrompts(data.prompts || [])).catch(() => {})
  }, [])

  const active = prompts.find((p) => p.name === selected)

  const startEdit = () => {
    if (active) {
      setEditContent(active.content)
      setEditing(true)
    }
  }

  const savePrompt = async () => {
    if (!selected) return
    setSaving(true)
    try {
      await api.savePrompt(selected, editContent)
      setPrompts((prev) =>
        prev.map((p) =>
          p.name === selected ? { ...p, content: editContent, source: 'custom' } : p,
        ),
      )
      setEditing(false)
    } catch { /* ignore */ }
    finally { setSaving(false) }
  }

  return (
    <div className="flex h-full">
      <div className="w-48 shrink-0 border-r flex flex-col">
        <div className="px-3 py-2.5 border-b bg-muted/30">
          <h3 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">{t('prompts.files')}</h3>
        </div>
        <ScrollArea className="flex-1">
          <div className="py-1">
            {prompts.map((p) => (
              <button
                key={p.name}
                onClick={() => { setSelected(p.name); setEditing(false) }}
                className={`w-full text-left px-3 py-2 text-sm transition-colors ${
                  selected === p.name
                    ? 'bg-accent text-accent-foreground'
                    : 'hover:bg-muted/50 text-muted-foreground'
                }`}
              >
                <div className="flex items-center justify-between">
                  <span className="font-medium capitalize">{p.name}</span>
                  <Badge variant={p.source === 'custom' ? 'default' : 'secondary'} className="text-[9px] h-4 px-1.5">
                    {p.source}
                  </Badge>
                </div>
                <p className="text-[10px] opacity-60 mt-0.5">{p.file}</p>
              </button>
            ))}
          </div>
        </ScrollArea>
      </div>

      <div className="flex-1 flex flex-col min-w-0">
        {active ? (
          <>
            <div className="flex items-center justify-between px-4 py-2.5 border-b bg-muted/30 shrink-0">
              <div className="flex items-center gap-2">
                <span className="text-sm font-medium capitalize">{active.name}</span>
                <Badge variant={active.source === 'custom' ? 'default' : 'secondary'} className="text-[10px]">
                  {active.source}
                </Badge>
              </div>
              <div className="flex gap-1.5">
                {editing ? (
                  <>
                    <Button size="sm" variant="ghost" className="h-7 text-xs px-2" onClick={() => setEditing(false)}>
                      {t('prompts.cancel')}
                    </Button>
                    <Button size="sm" className="h-7 text-xs px-3" onClick={savePrompt} disabled={saving}>
                      {saving ? t('prompts.saving') : t('prompts.saveAsCustom')}
                    </Button>
                  </>
                ) : (
                  <Button size="sm" variant="secondary" className="h-7 text-xs px-3" onClick={startEdit}>
                    {t('prompts.edit')}
                  </Button>
                )}
              </div>
            </div>
            <div className="flex-1 overflow-hidden">
              {editing ? (
                <Textarea
                  className="h-full w-full resize-none border-0 rounded-none font-mono text-xs p-4"
                  value={editContent}
                  onChange={(e) => setEditContent(e.target.value)}
                />
              ) : (
                <ScrollArea className="h-full">
                  <pre className="p-4 text-xs font-mono whitespace-pre-wrap text-muted-foreground leading-relaxed">
                    {active.content || t('prompts.empty')}
                  </pre>
                </ScrollArea>
              )}
            </div>
          </>
        ) : (
          <div className="flex-1 flex items-center justify-center text-muted-foreground text-sm">
            {t('prompts.selectToView')}
          </div>
        )}
      </div>
    </div>
  )
}
