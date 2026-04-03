import { useState, useEffect, useCallback } from 'react'
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarTrigger,
  SidebarInset,
} from '@/components/ui/sidebar'
import { Button } from '@/components/ui/button'
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip'
import { Badge } from '@/components/ui/badge'
import { Separator } from '@/components/ui/separator'
import {
  Home01Icon,
  Layers01Icon,
  WorkHistoryIcon,
  Settings01Icon,
  Brain01Icon,
  Moon01Icon,
  Sun01Icon,
  FlashIcon,
  StopIcon,
  FileCodeIcon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { useTheme } from '@/hooks/useTheme'
import { useSSE, type RunStatus as SSERunStatus, type RunProgress } from '@/hooks/useSSE'
import { useI18n } from '@/hooks/useI18n'
import { ConsoleTabs } from '@/components/ConsoleTabs'
import { BacklogPanel } from '@/components/BacklogPanel'
import { RunsPanel } from '@/components/RunsPanel'
import { SettingsPanel } from '@/components/SettingsPanel'
import { MemoryPanel } from '@/components/MemoryPanel'
import { PromptsPanel } from '@/components/PromptsPanel'
import { api } from '@/lib/api'

type Page = 'home' | 'backlog' | 'runs' | 'settings' | 'memory' | 'prompts'

const NAV_KEYS: Record<Page, string> = {
  home: 'nav.console',
  backlog: 'nav.backlog',
  runs: 'nav.runs',
  prompts: 'nav.prompts',
  memory: 'nav.memory',
  settings: 'nav.settings',
}

const NAV_ICONS: Record<Page, any> = {
  home: Home01Icon,
  backlog: Layers01Icon,
  runs: WorkHistoryIcon,
  prompts: FileCodeIcon,
  memory: Brain01Icon,
  settings: Settings01Icon,
}

const NAV_ORDER: Page[] = ['home', 'backlog', 'runs', 'prompts', 'memory', 'settings']

function AppSidebar({ page, setPage }: { page: Page; setPage: (p: Page) => void }) {
  const { t } = useI18n()
  return (
    <Sidebar collapsible="icon">
      <SidebarHeader className="py-2 px-2">
        <SidebarTrigger className="h-8 w-8" />
      </SidebarHeader>

      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupContent>
            <SidebarMenu>
              {NAV_ORDER.map((id) => (
                <SidebarMenuItem key={id}>
                  <SidebarMenuButton
                    isActive={page === id}
                    onClick={() => setPage(id)}
                    tooltip={t(NAV_KEYS[id])}
                  >
                    <HugeiconsIcon icon={NAV_ICONS[id]} size={16} />
                    <span>{t(NAV_KEYS[id])}</span>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              ))}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      </SidebarContent>

      <SidebarFooter className="py-2">
        <SidebarMenu>
          <SidebarMenuItem>
            <span className="text-[10px] text-muted-foreground px-2 group-data-[collapsible=icon]:hidden">v2.0.0</span>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarFooter>
    </Sidebar>
  )
}

type RunStatusUI = 'waiting' | 'running' | 'error'

const PAGE_TITLE_KEYS: Record<Page, string> = {
  home: 'page.console',
  backlog: 'page.backlog',
  runs: 'page.runs',
  prompts: 'page.prompts',
  settings: 'page.settings',
  memory: 'page.memory',
}

function Header({
  page,
  runStatus,
  runPhase,
  projectPath,
  onAuto,
  onStop,
}: {
  page: Page
  runStatus: RunStatusUI
  runPhase: string | null
  projectPath: string
  onAuto: () => void
  onStop: () => void
}) {
  const { resolved, setTheme } = useTheme()
  const { t } = useI18n()

  return (
    <header className="flex items-center h-12 px-4 border-b shrink-0 gap-3">
      <div className="flex items-center gap-2">
        <div className="h-6 w-6 rounded bg-primary flex items-center justify-center shrink-0">
          <HugeiconsIcon icon={FlashIcon} size={12} className="text-primary-foreground" />
        </div>
        <span className="font-bold text-sm tracking-tight">harn</span>
      </div>

      <Separator orientation="vertical" className="h-4" />
      <h1 className="font-medium text-sm flex-1 text-muted-foreground">{t(PAGE_TITLE_KEYS[page])}</h1>

      {projectPath && (() => {
        const sep = projectPath.includes('/') ? '/' : '\\'
        const parts = projectPath.split(sep).filter(Boolean)
        const display = parts.length > 2
          ? `...${sep}${parts.slice(-2).join(sep)}`
          : projectPath
        return (
          <span
            className="text-xs text-muted-foreground font-mono shrink-0"
            title={projectPath}
          >
            {display}
          </span>
        )
      })()}

      {runStatus === 'running' ? (
        <Badge variant="secondary" className="gap-1.5 text-xs shrink-0">
          <span className="h-1.5 w-1.5 rounded-full bg-emerald-500 animate-pulse" />
          {t('header.running')}{runPhase ? ` · ${t(`phase.${runPhase}`)}` : ''}
        </Badge>
      ) : runStatus === 'error' ? (
        <Badge variant="destructive" className="gap-1.5 text-xs shrink-0">
          <span className="h-1.5 w-1.5 rounded-full bg-red-300" />
          {t('header.error')}
        </Badge>
      ) : (
        <Badge variant="outline" className="gap-1.5 text-xs shrink-0">
          <span className="h-1.5 w-1.5 rounded-full bg-muted-foreground/40" />
          {t('header.waiting')}
        </Badge>
      )}

      <div className="flex items-center gap-1">
        <TooltipProvider>
          <Tooltip>
            <TooltipTrigger asChild>
              <Button size="sm" variant="default" className="h-7 gap-1.5 text-xs px-3" onClick={onAuto} disabled={runStatus === 'running'}>
                <HugeiconsIcon icon={FlashIcon} size={12} />
                {t('header.auto')}
              </Button>
            </TooltipTrigger>
            <TooltipContent>{t('header.autoTooltip')}</TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <Button size="sm" variant="outline" className="h-7 gap-1.5 text-xs px-3" onClick={onStop} disabled={runStatus !== 'running'}>
                <HugeiconsIcon icon={StopIcon} size={12} />
                {t('header.stop')}
              </Button>
            </TooltipTrigger>
            <TooltipContent>{t('header.stopTooltip')}</TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                size="icon"
                variant="ghost"
                className="h-7 w-7"
                onClick={() => setTheme(resolved === 'dark' ? 'light' : 'dark')}
              >
                <HugeiconsIcon icon={resolved === 'dark' ? Sun01Icon : Moon01Icon} size={14} />
              </Button>
            </TooltipTrigger>
            <TooltipContent>{t('header.toggleTheme')}</TooltipContent>
          </Tooltip>
        </TooltipProvider>
      </div>
    </header>
  )
}

export default function App() {
  const [page, setPage] = useState<Page>('home')
  const [runStatus, setRunStatus] = useState<RunStatusUI>('waiting')
  const [runPhase, setRunPhase] = useState<string | null>(null)
  const [projectPath, setProjectPath] = useState('')

  const sse = useSSE()

  // SSE-driven status updates (primary)
  useEffect(() => {
    return sse.onStatus((s: SSERunStatus) => {
      if (s.state === 'running') {
        setRunStatus('running')
        setRunPhase(s.phase || null)
      } else if (s.state === 'error') {
        setRunStatus('error')
        setRunPhase(null)
      } else {
        setRunStatus('waiting')
        setRunPhase(null)
      }
    })
  }, [sse.onStatus])

  // SSE-driven progress updates
  useEffect(() => {
    return sse.onProgress((p: RunProgress) => {
      setRunStatus('running')
      setRunPhase(p.phase)
    })
  }, [sse.onProgress])

  // Polling as fallback (slower, checks actual harn.pid)
  useEffect(() => {
    const check = () =>
      api.status()
        .then((s) => {
          if (s.isRunning) {
            setRunStatus('running')
          } else if (runStatus === 'running') {
            // Only downgrade from running→waiting via polling if SSE hasn't said otherwise
            setRunStatus('waiting')
            setRunPhase(null)
          }
          if (s.rootDir) setProjectPath(s.rootDir)
        })
        .catch(() => setRunStatus('error'))
    check()
    const t = setInterval(check, 5000)
    return () => clearInterval(t)
  }, [])

  const handleAuto = useCallback(async () => {
    setRunStatus('running')
    setRunPhase('starting')
    try {
      await api.runCommand('auto')
    } catch { /* ignore */ }
  }, [])

  const handleStop = useCallback(async () => {
    try { await api.stopCommand() } catch { /* ignore */ }
    setRunStatus('waiting')
    setRunPhase(null)
  }, [])

  return (
    <TooltipProvider>
      <SidebarProvider>
        <div className="flex h-screen w-full overflow-hidden bg-background text-foreground">
          <AppSidebar page={page} setPage={setPage} />

          <SidebarInset className="flex flex-col flex-1 overflow-hidden">
            <Header
              page={page}
              runStatus={runStatus}
              runPhase={runPhase}
              projectPath={projectPath}
              onAuto={handleAuto}
              onStop={handleStop}
            />

            <main className="flex-1 overflow-hidden">
              {page === 'home' ? (
                <ConsoleTabs />
              ) : page === 'backlog' ? (
                <div className="h-full overflow-hidden">
                  <BacklogPanel />
                </div>
              ) : page === 'runs' ? (
                <div className="h-full overflow-hidden">
                  <RunsPanel sse={sse} />
                </div>
              ) : page === 'settings' ? (
                <div className="h-full overflow-hidden">
                  <SettingsPanel />
                </div>
              ) : page === 'memory' ? (
                <div className="h-full overflow-hidden">
                  <MemoryPanel />
                </div>
              ) : page === 'prompts' ? (
                <div className="h-full overflow-hidden">
                  <PromptsPanel />
                </div>
              ) : null}
            </main>
          </SidebarInset>
        </div>
      </SidebarProvider>
    </TooltipProvider>
  )
}
