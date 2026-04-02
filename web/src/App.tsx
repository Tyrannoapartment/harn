import { useState, useEffect } from 'react'
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
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { useTheme } from '@/hooks/useTheme'
import { useSSE } from '@/hooks/useSSE'
import { LogFeed } from '@/components/LogFeed'
import { Composer } from '@/components/Composer'
import { BacklogPanel } from '@/components/BacklogPanel'
import { RunsPanel } from '@/components/RunsPanel'
import { SettingsPanel } from '@/components/SettingsPanel'
import { MemoryPanel } from '@/components/MemoryPanel'
import { api } from '@/lib/api'

type Page = 'home' | 'backlog' | 'runs' | 'settings' | 'memory'

const NAV = [
  { id: 'home' as Page, label: 'Console', icon: Home01Icon },
  { id: 'backlog' as Page, label: 'Backlog', icon: Layers01Icon },
  { id: 'runs' as Page, label: 'Runs', icon: WorkHistoryIcon },
  { id: 'memory' as Page, label: 'Memory', icon: Brain01Icon },
  { id: 'settings' as Page, label: 'Settings', icon: Settings01Icon },
]

function AppSidebar({ page, setPage }: { page: Page; setPage: (p: Page) => void }) {
  return (
    <Sidebar collapsible="icon">
      <SidebarHeader className="py-3 px-2">
        <div className="flex items-center gap-2 px-1">
          <div className="h-7 w-7 rounded bg-primary flex items-center justify-center shrink-0">
            <HugeiconsIcon icon={FlashIcon} size={14} className="text-primary-foreground" />
          </div>
          <span className="font-bold text-sm tracking-tight group-data-[collapsible=icon]:hidden">harn</span>
        </div>
      </SidebarHeader>

      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupContent>
            <SidebarMenu>
              {NAV.map((item) => (
                <SidebarMenuItem key={item.id}>
                  <SidebarMenuButton
                    isActive={page === item.id}
                    onClick={() => setPage(item.id)}
                    tooltip={item.label}
                  >
                    <HugeiconsIcon icon={item.icon} size={16} />
                    <span>{item.label}</span>
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

function Header({
  page,
  running,
  onAuto,
  onStop,
}: {
  page: Page
  running: boolean
  onAuto: () => void
  onStop: () => void
}) {
  const { resolved, setTheme } = useTheme()
  const labels: Record<Page, string> = {
    home: 'Console',
    backlog: 'Backlog',
    runs: 'Runs',
    settings: 'Settings',
    memory: 'Project Memory',
  }

  return (
    <header className="flex items-center h-12 px-4 border-b shrink-0 gap-3">
      <SidebarTrigger />
      <Separator orientation="vertical" className="h-4" />
      <h1 className="font-semibold text-sm flex-1">{labels[page]}</h1>

      {running && (
        <Badge variant="secondary" className="gap-1.5 text-xs">
          <span className="h-1.5 w-1.5 rounded-full bg-emerald-500 animate-pulse" />
          Running
        </Badge>
      )}

      <div className="flex items-center gap-1">
        <TooltipProvider>
          <Tooltip>
            <TooltipTrigger asChild>
              <Button size="sm" variant="default" className="h-7 gap-1.5 text-xs px-3" onClick={onAuto} disabled={running}>
                <HugeiconsIcon icon={FlashIcon} size={12} />
                Auto
              </Button>
            </TooltipTrigger>
            <TooltipContent>Run next backlog item automatically</TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <Button size="sm" variant="outline" className="h-7 gap-1.5 text-xs px-3" onClick={onStop} disabled={!running}>
                <HugeiconsIcon icon={StopIcon} size={12} />
                Stop
              </Button>
            </TooltipTrigger>
            <TooltipContent>Stop current run</TooltipContent>
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
            <TooltipContent>Toggle theme</TooltipContent>
          </Tooltip>
        </TooltipProvider>
      </div>
    </header>
  )
}

export default function App() {
  const [page, setPage] = useState<Page>('home')
  const [running, setRunning] = useState(false)
  const { logs, connected } = useSSE()

  useEffect(() => {
    const check = () =>
      api.status().then((s) => setRunning(!!s.active)).catch(() => {})
    check()
    const t = setInterval(check, 3000)
    return () => clearInterval(t)
  }, [])

  const handleAuto = async () => {
    try { await api.runCommand('auto') } catch { /* ignore */ }
  }

  const handleStop = async () => {
    try { await api.stopCommand() } catch { /* ignore */ }
  }

  return (
    <TooltipProvider>
      <SidebarProvider>
        <div className="flex h-screen w-full overflow-hidden bg-background text-foreground">
          <AppSidebar page={page} setPage={setPage} />

          <SidebarInset className="flex flex-col flex-1 overflow-hidden">
            <Header page={page} running={running} onAuto={handleAuto} onStop={handleStop} />

            <main className="flex-1 overflow-hidden">
              {page === 'home' ? (
                <div className="flex flex-col h-full">
                  <div className="flex-1 overflow-hidden">
                    <LogFeed logs={logs} connected={connected} />
                  </div>
                  <Composer />
                </div>
              ) : page === 'backlog' ? (
                <BacklogPanel />
              ) : page === 'runs' ? (
                <RunsPanel />
              ) : page === 'settings' ? (
                <SettingsPanel />
              ) : page === 'memory' ? (
                <MemoryPanel />
              ) : null}
            </main>
          </SidebarInset>
        </div>
      </SidebarProvider>
    </TooltipProvider>
  )
}
