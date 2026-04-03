import { useEffect, useState, useCallback } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Switch } from '@/components/ui/switch'
import { Separator } from '@/components/ui/separator'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog'
import { api, type BackendInfo, type McpServer } from '@/lib/api'
import { useI18n } from '@/hooks/useI18n'
import { setLang } from '@/lib/i18n'

interface Config {
  AI_BACKEND?: string
  PLANNER_BACKEND?: string
  GENERATOR_CONTRACT_BACKEND?: string
  GENERATOR_IMPL_BACKEND?: string
  EVALUATOR_CONTRACT_BACKEND?: string
  EVALUATOR_QA_BACKEND?: string
  PLANNER_MODEL?: string
  GENERATOR_CONTRACT_MODEL?: string
  GENERATOR_IMPL_MODEL?: string
  EVALUATOR_CONTRACT_MODEL?: string
  EVALUATOR_QA_MODEL?: string
  AUXILIARY_MODEL?: string
  MAX_ITERATIONS?: string
  MODEL_ROUTING?: string
  HARN_LANG?: string
  [key: string]: string | undefined
}

// Map model config keys to their per-role backend config keys
const MODEL_TO_BACKEND_KEY: Record<string, string> = {
  PLANNER_MODEL: 'PLANNER_BACKEND',
  GENERATOR_CONTRACT_MODEL: 'GENERATOR_CONTRACT_BACKEND',
  GENERATOR_IMPL_MODEL: 'GENERATOR_IMPL_BACKEND',
  EVALUATOR_CONTRACT_MODEL: 'EVALUATOR_CONTRACT_BACKEND',
  EVALUATOR_QA_MODEL: 'EVALUATOR_QA_BACKEND',
}

export function SettingsPanel() {
  const { t } = useI18n()
  const [config, setConfig] = useState<Config>({})
  const [backends, setBackends] = useState<BackendInfo[]>([])
  const [detected, setDetected] = useState('')
  const [dirty, setDirty] = useState(false)
  const [saved, setSaved] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [loadingConfig, setLoadingConfig] = useState(true)
  const [loadingBackends, setLoadingBackends] = useState(true)
  // Tracks which backend each model field was explicitly selected from
  const [modelSourceMap, setModelSourceMap] = useState<Record<string, string>>({})

  // Currently selected backend for model dropdowns
  const selectedBackend = config.AI_BACKEND || detected || 'copilot'

  const MODEL_FIELDS = [
    { key: 'PLANNER_MODEL', labelKey: 'settings.planner', default: 'claude-haiku-4.5' },
    { key: 'GENERATOR_CONTRACT_MODEL', labelKey: 'settings.generatorContract', default: 'claude-sonnet-4.6' },
    { key: 'GENERATOR_IMPL_MODEL', labelKey: 'settings.generatorImpl', default: 'claude-opus-4.6' },
    { key: 'EVALUATOR_CONTRACT_MODEL', labelKey: 'settings.evaluatorContract', default: 'claude-haiku-4.5' },
    { key: 'EVALUATOR_QA_MODEL', labelKey: 'settings.evaluatorQA', default: 'claude-sonnet-4.5' },
    { key: 'AUXILIARY_MODEL', labelKey: 'settings.auxiliary', default: '' },
  ]

  useEffect(() => {
    api.getConfig().then((data: Config) => {
      setConfig(data)
      // Initialize modelSourceMap from saved per-role backend config
      const sourceMap: Record<string, string> = {}
      for (const [modelKey, backendKey] of Object.entries(MODEL_TO_BACKEND_KEY)) {
        const savedBackend = data[backendKey]
        if (savedBackend) sourceMap[modelKey] = savedBackend
      }
      if (Object.keys(sourceMap).length > 0) setModelSourceMap(sourceMap)
    }).catch(() => {}).finally(() => setLoadingConfig(false))
    api.getBackends().then((data) => {
      setBackends(data.backends || [])
      setDetected(data.detected || '')
    }).catch(() => {}).finally(() => setLoadingBackends(false))
  }, [])

  const set = (key: string, value: string) => {
    setConfig((prev) => ({ ...prev, [key]: value }))
    setDirty(true)
    setSaved(false)
  }

  // Select a model: value format is "backend/model"
  // Also saves the per-role AI_BACKEND_* key so the correct backend is used at runtime
  const setModel = (key: string, compositeValue: string) => {
    const slashIdx = compositeValue.indexOf('/')
    if (slashIdx > 0) {
      const backend = compositeValue.substring(0, slashIdx)
      const model = compositeValue.substring(slashIdx + 1)
      setModelSourceMap((prev) => ({ ...prev, [key]: backend }))
      set(key, model)
      // Save per-role backend config
      const backendKey = MODEL_TO_BACKEND_KEY[key]
      if (backendKey) {
        set(backendKey, backend)
      }
    } else {
      set(key, compositeValue)
    }
  }

  // Infer the natural backend from a model name prefix
  const inferBackendFromModel = (model: string): string | null => {
    if (!model) return null
    const m = model.toLowerCase()
    if (m.startsWith('claude-')) return 'claude'
    if (m.startsWith('gpt-') || m.startsWith('o1') || m.startsWith('o3')) return 'codex'
    if (m.startsWith('gemini-')) return 'gemini'
    return null
  }

  // Get display backend for a model field
  const getModelBackend = (key: string, modelName: string) => {
    // 1. Explicitly chosen backend takes priority (from modelSourceMap or saved config)
    if (modelSourceMap[key]) return modelSourceMap[key]
    // 2. Infer from model name prefix (claude-* → claude, gpt-* → codex, etc.)
    const inferred = inferBackendFromModel(modelName)
    if (inferred && backends.some((b) => b.backend === inferred)) return inferred
    // 3. Find unique backend that has this model
    const matches = backends.filter((b) => b.models.includes(modelName))
    if (matches.length === 1) return matches[0].backend
    // 4. Prefer selectedBackend if it has the model
    if (matches.some((b) => b.backend === selectedBackend)) return selectedBackend
    return matches[0]?.backend || selectedBackend
  }

  const save = async () => {
    try {
      const clean: Record<string, string> = {}
      for (const [k, v] of Object.entries(config)) {
        if (v !== undefined) clean[k] = v
      }
      await api.saveConfig(clean)
      setDirty(false)
      setSaved(true)
      // Update UI language immediately
      if (config.HARN_LANG) setLang(config.HARN_LANG)
      setTimeout(() => setSaved(false), 2000)
    } catch { /* ignore */ }
  }

  const refresh = async () => {
    setRefreshing(true)
    try {
      await api.refreshModels()
      const data = await api.getBackends()
      setBackends(data.backends || [])
      setDetected(data.detected || '')
    } catch { /* ignore */ }
    finally { setRefreshing(false) }
  }

  return (
    <div className="flex flex-col h-full">
      <div className="flex items-center justify-end px-4 py-3 border-b bg-muted/30 shrink-0">
        <Button
          size="sm"
          variant={saved ? 'default' : 'secondary'}
          className="h-7 text-xs px-3"
          onClick={save}
          disabled={!dirty}
        >
          {saved ? t('settings.saved') : t('settings.save')}
        </Button>
      </div>

      <div className="flex-1 overflow-y-auto p-4 space-y-5">

        {/* AI Backend */}
        <div className="space-y-3">
          <div className="flex items-center justify-between">
            <h3 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">{t('settings.aiBackend')}</h3>
            <Button
              size="sm"
              variant="ghost"
              className="h-6 text-[10px] px-2"
              onClick={refresh}
              disabled={refreshing || loadingBackends}
            >
              {refreshing ? t('settings.refreshing') : t('settings.refresh')}
            </Button>
          </div>

          {loadingBackends ? (
            <div className="space-y-3">
              <div className="space-y-1">
                <Skeleton className="h-3.5 w-20" />
                <Skeleton className="h-8 w-full" />
              </div>
              <div className="space-y-1.5">
                {[1, 2, 3, 4].map((i) => (
                  <Skeleton key={i} className="h-10 w-full rounded" />
                ))}
              </div>
            </div>
          ) : (
            <>
              {/* Backend selector */}
              <div className="space-y-1">
                <Label className="text-xs">{t('settings.selectBackend')}</Label>
                <Select
                  value={selectedBackend}
                  onValueChange={(v) => set('AI_BACKEND', v)}
                >
                  <SelectTrigger className="h-8 text-xs font-mono">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {backends.map((b) => (
                      <SelectItem key={b.backend} value={b.backend} className="text-xs font-mono">
                        <span className="flex items-center gap-2">
                          {b.backend}
                          {b.isDefault && <Badge variant="secondary" className="text-[9px] h-3.5 px-1">auto</Badge>}
                        </span>
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              {/* Backend health status */}
              <div className="space-y-1.5">
                {backends.map((b) => (
                  <div key={b.backend} className="flex items-center justify-between rounded border px-3 py-2">
                    <div className="flex items-center gap-2">
                      <span className={`h-2 w-2 rounded-full shrink-0 ${
                        b.installed && b.authenticated ? 'bg-emerald-500' :
                        b.installed ? 'bg-amber-500' : 'bg-muted-foreground/30'
                      }`} />
                      <span className="text-xs font-mono font-medium">{b.backend}</span>
                    </div>
                    <div className="flex items-center gap-2">
                      {b.installed ? (
                        <>
                          <span className="text-[10px] text-muted-foreground font-mono">{b.version}</span>
                          <Badge variant="default" className="text-[9px] h-4 px-1.5">
                            {t('settings.installed')}
                          </Badge>
                        </>
                      ) : (
                        <Badge variant="outline" className="text-[9px] h-4 px-1.5 text-muted-foreground">
                          {t('settings.notInstalled')}
                        </Badge>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            </>
          )}
        </div>

        <Separator />

        {/* Models — show "backend / model" format */}
        <div className="space-y-3">
          <h3 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">{t('settings.models')}</h3>
          {loadingBackends ? (
            <div className="space-y-3">
              {[1, 2, 3, 4, 5, 6].map((i) => (
                <div key={i} className="space-y-1">
                  <Skeleton className="h-3.5 w-28" />
                  <Skeleton className="h-8 w-full" />
                </div>
              ))}
            </div>
          ) : (
            MODEL_FIELDS.map(({ key, labelKey, default: def }) => {
              const currentVal = config[key] || def
              const displayBackend = getModelBackend(key, currentVal)
              const selectValue = currentVal ? `${displayBackend}/${currentVal}` : ''
              return (
                <div key={key} className="space-y-1">
                  <Label className="text-xs">{t(labelKey)}</Label>
                  <Select
                    value={selectValue}
                    onValueChange={(v) => setModel(key, v)}
                  >
                    <SelectTrigger className="h-8 text-xs font-mono">
                      <SelectValue placeholder={t('settings.selectModel')}>
                        {currentVal ? `${displayBackend} / ${currentVal}` : t('settings.selectModel')}
                      </SelectValue>
                    </SelectTrigger>
                    <SelectContent>
                      {backends.filter((b) => b.models.length > 0).map((b) => (
                        b.models.map((m) => (
                          <SelectItem key={`${b.backend}-${m}`} value={`${b.backend}/${m}`} className="text-xs font-mono">
                            {b.backend} / {m}
                          </SelectItem>
                        ))
                      ))}
                      {currentVal && !backends.some((b) => b.models.includes(currentVal)) && (
                        <SelectItem value={`${displayBackend}/${currentVal}`} className="text-xs font-mono">
                          {displayBackend} / {currentVal}
                        </SelectItem>
                      )}
                    </SelectContent>
                  </Select>
                </div>
              )
            })
          )}
        </div>

        <Separator />

        {/* Sprint */}
        <div className="space-y-3">
          <h3 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">{t('settings.sprint')}</h3>
          {loadingConfig ? (
            <div className="space-y-1">
              <Skeleton className="h-3.5 w-24" />
              <Skeleton className="h-8 w-full" />
            </div>
          ) : (
            <div className="space-y-1">
              <Label className="text-xs">{t('settings.maxIterations')}</Label>
              <Input
                className="h-8 text-xs font-mono"
                type="number"
                min={1}
                max={10}
                value={config.MAX_ITERATIONS || '5'}
                onChange={(e) => set('MAX_ITERATIONS', e.target.value)}
              />
            </div>
          )}
        </div>

        <Separator />

        {/* Routing */}
        <div className="space-y-3">
          <h3 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">{t('settings.routing')}</h3>
          {loadingConfig ? (
            <div className="flex items-center justify-between">
              <div className="space-y-1">
                <Skeleton className="h-3.5 w-32" />
                <Skeleton className="h-3 w-52" />
              </div>
              <Skeleton className="h-5 w-9 rounded-full" />
            </div>
          ) : (
            <div className="flex items-center justify-between">
              <div>
                <Label className="text-xs">{t('settings.smartRouting')}</Label>
                <p className="text-[10px] text-muted-foreground mt-0.5">
                  {t('settings.smartRoutingDesc')}
                </p>
              </div>
              <Switch
                checked={(config.MODEL_ROUTING || 'true') === 'true'}
                onCheckedChange={(v) => set('MODEL_ROUTING', v ? 'true' : 'false')}
              />
            </div>
          )}
        </div>

        <Separator />

        {/* Language */}
        <div className="space-y-3">
          <h3 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">{t('settings.language')}</h3>
          {loadingConfig ? (
            <div className="space-y-1">
              <Skeleton className="h-3.5 w-28" />
              <Skeleton className="h-8 w-full" />
              <Skeleton className="h-3 w-48" />
            </div>
          ) : (
            <div className="space-y-1">
              <Label className="text-xs">{t('settings.uiLanguage')}</Label>
              <Select
                value={config.HARN_LANG || 'en'}
                onValueChange={(v) => set('HARN_LANG', v)}
              >
                <SelectTrigger className="h-8 text-xs">
                  <SelectValue placeholder={t('settings.selectLanguage')} />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="en" className="text-xs">English</SelectItem>
                  <SelectItem value="ko" className="text-xs">한국어 (Korean)</SelectItem>
                </SelectContent>
              </Select>
              <p className="text-[10px] text-muted-foreground mt-0.5">
                {t('settings.languageDesc')}
              </p>
            </div>
          )}
        </div>

        <Separator />

        {/* MCP Servers */}
        <McpSection backends={backends} />
      </div>
    </div>
  )
}

// ── MCP Server Management ──────────────────────────────────────────────────

interface AddServerForm {
  name: string
  cli: string
  scope: 'global' | 'project'
  type: 'http' | 'stdio'
  url: string
  command: string
  args: string
  env: string
}

const EMPTY_FORM: AddServerForm = {
  name: '', cli: 'copilot', scope: 'project', type: 'http',
  url: '', command: '', args: '', env: '',
}

function McpSection({ backends }: { backends: BackendInfo[] }) {
  const { t } = useI18n()
  const [servers, setServers] = useState<McpServer[]>([])
  const [loading, setLoading] = useState(true)
  const [showAdd, setShowAdd] = useState(false)
  const [form, setForm] = useState<AddServerForm>({ ...EMPTY_FORM })
  const [saving, setSaving] = useState(false)

  const availableClis = backends.length > 0
    ? backends.map((b) => b.backend)
    : ['copilot', 'claude', 'codex', 'gemini']

  const load = useCallback(() => {
    setLoading(true)
    api.getMcp()
      .then((data) => setServers(data.servers || []))
      .catch(() => {})
      .finally(() => setLoading(false))
  }, [])

  useEffect(() => { load() }, [load])

  const handleAdd = async () => {
    if (!form.name.trim()) return
    setSaving(true)
    try {
      const config: Record<string, unknown> = { type: form.type }
      if (form.type === 'http') {
        config.url = form.url
      } else {
        config.command = form.command
        if (form.args.trim()) config.args = form.args.split(/\s+/)
      }
      if (form.env.trim()) {
        try {
          config.env = JSON.parse(form.env)
        } catch { /* ignore bad JSON */ }
      }
      const res = await api.addMcpServer(form.cli, form.scope, form.name, config)
      setServers(res.servers || [])
      setShowAdd(false)
      setForm({ ...EMPTY_FORM })
    } catch { /* ignore */ }
    finally { setSaving(false) }
  }

  const handleRemove = async (server: McpServer) => {
    try {
      const res = await api.removeMcpServer(server.cli, server.scope, server.name)
      setServers(res.servers || [])
    } catch { /* ignore */ }
  }

  // Group servers by CLI
  const grouped = servers.reduce<Record<string, McpServer[]>>((acc, s) => {
    (acc[s.cli] ??= []).push(s)
    return acc
  }, {})

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
            {t('settings.mcp')}
          </h3>
          <p className="text-[10px] text-muted-foreground mt-0.5">
            {t('settings.mcpDesc')}
          </p>
        </div>
        <Button size="sm" variant="outline" className="h-6 text-[10px] px-2" onClick={() => setShowAdd(true)}>
          {t('settings.mcpAdd')}
        </Button>
      </div>

      {loading ? (
        <div className="space-y-2">
          {[1, 2, 3].map((i) => <Skeleton key={i} className="h-12 w-full rounded" />)}
        </div>
      ) : servers.length === 0 ? (
        <div className="text-center py-6 text-xs text-muted-foreground">
          {t('settings.mcpEmpty')}
        </div>
      ) : (
        <div className="space-y-3">
          {Object.entries(grouped).map(([cli, items]) => (
            <div key={cli} className="space-y-1.5">
              <div className="flex items-center gap-2">
                <span className="text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">{cli}</span>
                <Badge variant="secondary" className="text-[9px] h-3.5 px-1">{items.length}</Badge>
              </div>
              {items.map((s) => (
                <div key={`${s.cli}-${s.scope}-${s.name}`} className="flex items-center justify-between rounded border px-3 py-2 group">
                  <div className="flex items-center gap-2 min-w-0 flex-1">
                    <span className={`h-2 w-2 rounded-full shrink-0 ${s.type === 'http' ? 'bg-blue-500' : 'bg-amber-500'}`} />
                    <span className="text-xs font-mono font-medium truncate">{s.name}</span>
                    <Badge variant="outline" className="text-[9px] h-3.5 px-1 shrink-0">
                      {s.type}
                    </Badge>
                    <Badge variant={s.scope === 'project' ? 'default' : 'secondary'} className="text-[9px] h-3.5 px-1 shrink-0">
                      {s.scope === 'project' ? t('settings.mcpProject') : t('settings.mcpGlobal')}
                    </Badge>
                  </div>
                  <div className="flex items-center gap-2 shrink-0 ml-2">
                    <span className="text-[10px] text-muted-foreground font-mono truncate max-w-[180px]">
                      {s.url || s.command || ''}
                    </span>
                    <Button
                      size="sm"
                      variant="ghost"
                      className="h-5 text-[10px] px-1.5 text-destructive opacity-0 group-hover:opacity-100 transition-opacity"
                      onClick={() => handleRemove(s)}
                    >
                      {t('settings.mcpRemove')}
                    </Button>
                  </div>
                </div>
              ))}
            </div>
          ))}
        </div>
      )}

      {/* Add Server Dialog */}
      <Dialog open={showAdd} onOpenChange={(v) => !v && setShowAdd(false)}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle className="text-sm">{t('settings.mcpAdd')}</DialogTitle>
          </DialogHeader>

          <div className="space-y-3">
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1">
                <Label className="text-xs">{t('settings.mcpCli')}</Label>
                <Select value={form.cli} onValueChange={(v) => setForm((f) => ({ ...f, cli: v }))}>
                  <SelectTrigger className="h-8 text-xs font-mono"><SelectValue /></SelectTrigger>
                  <SelectContent>
                    {availableClis.map((c) => (
                      <SelectItem key={c} value={c} className="text-xs font-mono">{c}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-1">
                <Label className="text-xs">{t('settings.mcpScope')}</Label>
                <Select value={form.scope} onValueChange={(v) => setForm((f) => ({ ...f, scope: v as 'global' | 'project' }))}>
                  <SelectTrigger className="h-8 text-xs"><SelectValue /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="project" className="text-xs">{t('settings.mcpProject')}</SelectItem>
                    <SelectItem value="global" className="text-xs">{t('settings.mcpGlobal')}</SelectItem>
                  </SelectContent>
                </Select>
              </div>
            </div>

            <div className="space-y-1">
              <Label className="text-xs">{t('settings.mcpName')}</Label>
              <Input
                className="h-8 text-xs font-mono"
                placeholder="my-mcp-server"
                value={form.name}
                onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
              />
            </div>

            <div className="space-y-1">
              <Label className="text-xs">{t('settings.mcpType')}</Label>
              <Select value={form.type} onValueChange={(v) => setForm((f) => ({ ...f, type: v as 'http' | 'stdio' }))}>
                <SelectTrigger className="h-8 text-xs"><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="http" className="text-xs">HTTP</SelectItem>
                  <SelectItem value="stdio" className="text-xs">stdio (Command)</SelectItem>
                </SelectContent>
              </Select>
            </div>

            {form.type === 'http' ? (
              <div className="space-y-1">
                <Label className="text-xs">{t('settings.mcpUrl')}</Label>
                <Input
                  className="h-8 text-xs font-mono"
                  placeholder="http://localhost:3000/mcp"
                  value={form.url}
                  onChange={(e) => setForm((f) => ({ ...f, url: e.target.value }))}
                />
              </div>
            ) : (
              <>
                <div className="space-y-1">
                  <Label className="text-xs">{t('settings.mcpCommand')}</Label>
                  <Input
                    className="h-8 text-xs font-mono"
                    placeholder="npx -y @some/mcp-server"
                    value={form.command}
                    onChange={(e) => setForm((f) => ({ ...f, command: e.target.value }))}
                  />
                </div>
                <div className="space-y-1">
                  <Label className="text-xs">{t('settings.mcpArgs')}</Label>
                  <Input
                    className="h-8 text-xs font-mono"
                    placeholder="--port 3000 --verbose"
                    value={form.args}
                    onChange={(e) => setForm((f) => ({ ...f, args: e.target.value }))}
                  />
                </div>
              </>
            )}

            <div className="space-y-1">
              <Label className="text-xs">{t('settings.mcpEnv')} <span className="text-muted-foreground">(JSON)</span></Label>
              <Input
                className="h-8 text-xs font-mono"
                placeholder='{"API_KEY": "..."}'
                value={form.env}
                onChange={(e) => setForm((f) => ({ ...f, env: e.target.value }))}
              />
            </div>
          </div>

          <DialogFooter>
            <Button variant="ghost" size="sm" onClick={() => setShowAdd(false)}>
              {t('prompts.cancel')}
            </Button>
            <Button size="sm" onClick={handleAdd} disabled={saving || !form.name.trim()}>
              {saving ? t('prompts.saving') : t('settings.mcpSave')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}