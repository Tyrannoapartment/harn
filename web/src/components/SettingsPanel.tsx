import { useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Switch } from '@/components/ui/switch'
import { Separator } from '@/components/ui/separator'
import { api } from '@/lib/api'

interface Config {
  COPILOT_MODEL?: string
  MODEL_PLANNER?: string
  MODEL_GENERATOR?: string
  MODEL_EVALUATOR?: string
  MAX_ITERATIONS?: string
  MODEL_ROUTING?: string
  [key: string]: string | undefined
}

export function SettingsPanel() {
  const [config, setConfig] = useState<Config>({})
  const [dirty, setDirty] = useState(false)
  const [saved, setSaved] = useState(false)

  useEffect(() => {
    api.getConfig().then((data: Config) => setConfig(data)).catch(() => {})
  }, [])

  const set = (key: string, value: string) => {
    setConfig((prev) => ({ ...prev, [key]: value }))
    setDirty(true)
    setSaved(false)
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
      setTimeout(() => setSaved(false), 2000)
    } catch { /* ignore */ }
  }

  return (
    <div className="flex flex-col h-full">
      <div className="flex items-center justify-between px-4 py-3 border-b bg-muted/30 shrink-0">
        <h2 className="font-semibold text-sm">Settings</h2>
        <Button
          size="sm"
          variant={saved ? 'default' : 'secondary'}
          className="h-7 text-xs px-3"
          onClick={save}
          disabled={!dirty}
        >
          {saved ? 'Saved!' : 'Save'}
        </Button>
      </div>

      <div className="flex-1 overflow-y-auto p-4 space-y-5">
        <div className="space-y-3">
          <h3 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">Models</h3>
          {[
            { key: 'MODEL_PLANNER', label: 'Planner' },
            { key: 'MODEL_GENERATOR', label: 'Generator (Impl)' },
            { key: 'MODEL_EVALUATOR', label: 'Evaluator (QA)' },
          ].map(({ key, label }) => (
            <div key={key} className="space-y-1">
              <Label className="text-xs">{label}</Label>
              <Input
                className="h-8 text-xs font-mono"
                value={config[key] || ''}
                onChange={(e) => set(key, e.target.value)}
                placeholder="e.g. claude-sonnet-4.6"
              />
            </div>
          ))}
        </div>

        <Separator />

        <div className="space-y-3">
          <h3 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">Sprint</h3>
          <div className="space-y-1">
            <Label className="text-xs">Max Iterations</Label>
            <Input
              className="h-8 text-xs font-mono"
              type="number"
              min={1}
              max={10}
              value={config.MAX_ITERATIONS || '3'}
              onChange={(e) => set('MAX_ITERATIONS', e.target.value)}
            />
          </div>
        </div>

        <Separator />

        <div className="space-y-3">
          <h3 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">Routing</h3>
          <div className="flex items-center justify-between">
            <div>
              <Label className="text-xs">Smart Model Routing</Label>
              <p className="text-[10px] text-muted-foreground mt-0.5">
                Auto-upgrade/downgrade based on task complexity
              </p>
            </div>
            <Switch
              checked={(config.MODEL_ROUTING || 'true') === 'true'}
              onCheckedChange={(v) => set('MODEL_ROUTING', v ? 'true' : 'false')}
            />
          </div>
        </div>
      </div>
    </div>
  )
}
