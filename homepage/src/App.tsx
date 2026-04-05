import { useEffect, useRef, useState, type ReactNode } from 'react'

/* ════════════════════════════════════════════
   Scroll-triggered animation hook
   ════════════════════════════════════════════ */
function useScrollReveal() {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const el = ref.current
    if (!el) return
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          el.classList.add('is-visible')
          observer.unobserve(el)
        }
      },
      { threshold: 0.15, rootMargin: '0px 0px -40px 0px' },
    )
    observer.observe(el)
    return () => observer.disconnect()
  }, [])
  return ref
}

function Reveal({ children, className = '', delay = 0 }: { children: ReactNode; className?: string; delay?: number }) {
  const ref = useScrollReveal()
  return (
    <div ref={ref} className={`animate-on-scroll ${delay ? `delay-${delay}` : ''} ${className}`}>
      {children}
    </div>
  )
}

/* ════════════════════════════════════════════
   Theme toggle
   ════════════════════════════════════════════ */
function ThemeToggle() {
  const [dark, setDark] = useState(true)
  const toggle = () => {
    setDark((d) => !d)
    document.documentElement.classList.toggle('dark')
    document.documentElement.classList.toggle('light')
  }
  return (
    <button
      onClick={toggle}
      aria-label="Toggle theme"
      className="w-9 h-9 rounded-lg border border-border-subtle flex items-center justify-center hover:border-neon/40 transition-colors cursor-pointer"
    >
      {dark ? (
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
          <circle cx="8" cy="8" r="3.5" stroke="currentColor" strokeWidth="1.5" />
          <path d="M8 1v2M8 13v2M1 8h2M13 8h2M3.05 3.05l1.41 1.41M11.54 11.54l1.41 1.41M3.05 12.95l1.41-1.41M11.54 4.46l1.41-1.41" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
        </svg>
      ) : (
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
          <path d="M14 8.5A6.5 6.5 0 017.5 2 5.5 5.5 0 1014 8.5z" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
        </svg>
      )}
    </button>
  )
}

/* ════════════════════════════════════════════
   Navbar
   ════════════════════════════════════════════ */
function Navbar() {
  const [scrolled, setScrolled] = useState(false)
  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 20)
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  return (
    <nav
      className={`fixed top-0 left-0 right-0 z-50 transition-all duration-300 ${
        scrolled ? 'bg-surface/80 backdrop-blur-xl border-b border-border-subtle' : ''
      }`}
    >
      <div className="max-w-6xl mx-auto px-6 h-16 flex items-center justify-between">
        <a href="#" className="flex items-center gap-2.5 font-heading font-bold text-lg tracking-tight">
          <span className="w-7 h-7 rounded-md bg-neon/10 border border-neon/20 flex items-center justify-center text-neon font-mono text-sm font-bold">
            h
          </span>
          <span>harn</span>
        </a>
        <div className="flex items-center gap-6">
          <div className="hidden sm:flex items-center gap-6 text-sm text-text-secondary">
            <a href="#how-it-works" className="hover:text-text-primary transition-colors">작동 원리</a>
            <a href="#features" className="hover:text-text-primary transition-colors">기능</a>
            <a href="#quickstart" className="hover:text-text-primary transition-colors">시작하기</a>
          </div>
          <ThemeToggle />
          <a
            href="https://github.com/Tyrannoapartment/harn"
            target="_blank"
            rel="noopener noreferrer"
            className="hidden sm:flex items-center gap-2 text-sm px-3.5 py-1.5 rounded-lg border border-border-medium hover:border-neon/40 transition-all hover:bg-neon/5"
          >
            <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
              <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
            </svg>
            GitHub
          </a>
        </div>
      </div>
    </nav>
  )
}

/* ════════════════════════════════════════════
   Hero Section
   ════════════════════════════════════════════ */
function CopyCommand({ command }: { command: string }) {
  const [copied, setCopied] = useState(false)
  const copy = () => {
    navigator.clipboard.writeText(command)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }
  return (
    <div className="inline-flex items-center gap-3 bg-surface-raised border border-border-medium rounded-xl px-5 py-3 font-mono text-sm">
      <span className="text-text-tertiary select-none">$</span>
      <span className="text-text-primary">{command}</span>
      <button onClick={copy} className="copy-btn text-text-tertiary ml-2 cursor-pointer" aria-label="Copy command">
        {copied ? (
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="var(--color-neon)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <polyline points="3.5 8.5 6.5 11.5 12.5 5.5" />
          </svg>
        ) : (
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
            <rect x="5" y="5" width="9" height="9" rx="2" />
            <path d="M5 11H3.5A1.5 1.5 0 012 9.5v-7A1.5 1.5 0 013.5 1h7A1.5 1.5 0 0112 2.5V5" />
          </svg>
        )}
      </button>
    </div>
  )
}

function Hero() {
  return (
    <section className="relative min-h-screen flex items-center justify-center pt-16 hero-gradient dot-grid overflow-hidden">
      {/* Radial glow orb */}
      <div className="absolute top-1/4 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[600px] h-[600px] rounded-full bg-neon/5 blur-[120px] pointer-events-none" />

      <div className="relative max-w-4xl mx-auto px-6 py-24 text-center">
        <Reveal>
          <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full border border-neon/20 bg-neon/5 text-neon text-xs font-mono tracking-wide mb-8">
            <span className="w-1.5 h-1.5 rounded-full bg-neon animate-pulse" />
            v2.1 — Multi-Agent Sprint Loop
          </div>
        </Reveal>

        <Reveal delay={1}>
          <h1 className="font-heading text-4xl sm:text-5xl md:text-6xl lg:text-7xl font-extrabold leading-[1.1] tracking-tight mb-6">
            AI 에이전트 개발을
            <br />
            <span className="text-neon text-glow">자동화</span>하는
            <br />
            오케스트레이터
          </h1>
        </Reveal>

        <Reveal delay={2}>
          <p className="text-text-secondary text-lg sm:text-xl max-w-2xl mx-auto mb-10 leading-relaxed">
            Automate AI agent development with the{' '}
            <span className="text-text-primary font-medium">Planner → Generator → Evaluator</span> loop.
            <br className="hidden sm:block" />
            From backlog to production, fully autonomous.
          </p>
        </Reveal>

        <Reveal delay={3}>
          <div className="flex flex-col sm:flex-row items-center justify-center gap-4 mb-8">
            <a
              href="https://github.com/Tyrannoapartment/harn"
              target="_blank"
              rel="noopener noreferrer"
              className="group inline-flex items-center gap-2.5 px-7 py-3.5 bg-neon text-surface font-heading font-bold text-sm rounded-xl transition-all hover:scale-[1.02] hover:shadow-[0_0_30px_var(--color-neon-glow)]"
            >
              <svg width="18" height="18" viewBox="0 0 16 16" fill="currentColor">
                <path d="M8 .2l2.2 4.5 5 .7-3.6 3.5.9 5L8 11.8 3.5 14l.9-5L.8 5.4l5-.7L8 .2z" />
              </svg>
              Star on GitHub
            </a>
            <CopyCommand command="npx @tyrannoapartment/harn init" />
          </div>
        </Reveal>
      </div>
    </section>
  )
}

/* ════════════════════════════════════════════
   How It Works — Animated Loop Diagram
   ════════════════════════════════════════════ */
function LoopDiagram() {
  return (
    <div className="relative w-full max-w-lg mx-auto aspect-square">
      <svg viewBox="0 0 400 400" className="w-full h-full" fill="none">
        {/* Orbit ring */}
        <circle cx="200" cy="200" r="140" stroke="var(--color-border-medium)" strokeWidth="1" />
        <circle cx="200" cy="200" r="140" className="orbit-path" stroke="var(--color-neon)" strokeWidth="1.5" opacity="0.6" />

        {/* Planner node — top */}
        <g className="loop-pulse" style={{ animationDelay: '0s' }}>
          <circle cx="200" cy="60" r="36" fill="var(--color-surface-raised)" stroke="var(--color-neon)" strokeWidth="1.5" />
          <text x="200" y="56" textAnchor="middle" fill="var(--color-neon)" fontSize="16" fontWeight="700" fontFamily="var(--font-heading)">Plan</text>
          <text x="200" y="72" textAnchor="middle" fill="var(--color-text-secondary)" fontSize="10" fontFamily="var(--font-body)">Planner</text>
        </g>

        {/* Generator node — bottom-left */}
        <g className="loop-pulse" style={{ animationDelay: '1s' }}>
          <circle cx="79" cy="270" r="36" fill="var(--color-surface-raised)" stroke="#34D399" strokeWidth="1.5" />
          <text x="79" y="266" textAnchor="middle" fill="#34D399" fontSize="16" fontWeight="700" fontFamily="var(--font-heading)">Build</text>
          <text x="79" y="282" textAnchor="middle" fill="var(--color-text-secondary)" fontSize="10" fontFamily="var(--font-body)">Generator</text>
        </g>

        {/* Evaluator node — bottom-right */}
        <g className="loop-pulse" style={{ animationDelay: '2s' }}>
          <circle cx="321" cy="270" r="36" fill="var(--color-surface-raised)" stroke="#F59E0B" strokeWidth="1.5" />
          <text x="321" y="266" textAnchor="middle" fill="#F59E0B" fontSize="16" fontWeight="700" fontFamily="var(--font-heading)">QA</text>
          <text x="321" y="282" textAnchor="middle" fill="var(--color-text-secondary)" fontSize="10" fontFamily="var(--font-body)">Evaluator</text>
        </g>

        {/* Arrows — Planner → Generator */}
        <path d="M175 88 L108 240" stroke="var(--color-text-tertiary)" strokeWidth="1.5" markerEnd="url(#arrowhead)" />
        {/* Generator → Evaluator */}
        <path d="M115 270 L285 270" stroke="var(--color-text-tertiary)" strokeWidth="1.5" markerEnd="url(#arrowhead)" />
        {/* Evaluator → Planner (PASS — next sprint) */}
        <path d="M340 237 L225 88" stroke="var(--color-text-tertiary)" strokeWidth="1.5" markerEnd="url(#arrowhead)" opacity="0.4" />

        {/* FAIL loop: Evaluator → Generator */}
        <path d="M290 290 Q200 350 108 290" stroke="#EF4444" strokeWidth="1.5" strokeDasharray="4 4" markerEnd="url(#arrowRed)" opacity="0.7" />

        {/* PASS label */}
        <text x="300" y="175" fill="var(--color-text-tertiary)" fontSize="9" fontFamily="var(--font-mono)" transform="rotate(-45, 300, 175)">PASS → next</text>

        {/* FAIL label */}
        <text x="200" y="338" textAnchor="middle" fill="#EF4444" fontSize="10" fontFamily="var(--font-mono)" opacity="0.8">FAIL → retry</text>

        <defs>
          <marker id="arrowhead" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
            <polygon points="0 0, 8 3, 0 6" fill="var(--color-text-tertiary)" />
          </marker>
          <marker id="arrowRed" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
            <polygon points="0 0, 8 3, 0 6" fill="#EF4444" />
          </marker>
        </defs>
      </svg>
    </div>
  )
}

function HowItWorks() {
  return (
    <section id="how-it-works" className="relative py-32 px-6">
      <div className="max-w-6xl mx-auto">
        <Reveal>
          <div className="text-center mb-16">
            <p className="text-neon font-mono text-sm tracking-wide mb-3">HOW IT WORKS</p>
            <h2 className="font-heading text-3xl sm:text-4xl md:text-5xl font-bold tracking-tight">
              자율 스프린트 루프
            </h2>
            <p className="text-text-secondary mt-4 max-w-xl mx-auto">
              백로그 아이템을 투입하면, AI 에이전트가 계획 → 구현 → 평가를 반복하며 자동으로 완성합니다.
            </p>
          </div>
        </Reveal>

        <div className="grid md:grid-cols-2 gap-12 items-center">
          <Reveal delay={1}>
            <LoopDiagram />
          </Reveal>

          <Reveal delay={2}>
            <div className="space-y-6">
              {[
                {
                  step: '01',
                  title: 'Planner',
                  desc: '백로그 아이템을 분석하고 상세 스펙과 스프린트 계획을 수립합니다.',
                  color: 'text-neon',
                },
                {
                  step: '02',
                  title: 'Generator',
                  desc: '계획에 따라 코드를 생성합니다. 실패 시 자동으로 재시도합니다.',
                  color: 'text-emerald-400',
                },
                {
                  step: '03',
                  title: 'Evaluator',
                  desc: '빌드/테스트/린트를 실행하고 품질을 검증합니다. PASS 또는 FAIL 판정.',
                  color: 'text-amber-400',
                },
              ].map((item) => (
                <div key={item.step} className="flex gap-4 p-4 rounded-xl bg-surface-raised border border-border-subtle">
                  <span className={`font-mono text-sm ${item.color} font-bold mt-0.5`}>{item.step}</span>
                  <div>
                    <h3 className={`font-heading font-bold text-lg ${item.color}`}>{item.title}</h3>
                    <p className="text-text-secondary text-sm mt-1 leading-relaxed">{item.desc}</p>
                  </div>
                </div>
              ))}
            </div>
          </Reveal>
        </div>
      </div>
    </section>
  )
}

/* ════════════════════════════════════════════
   Features Section
   ════════════════════════════════════════════ */
const features = [
  {
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="12" cy="12" r="3" />
        <path d="M12 1v4M12 19v4M4.22 4.22l2.83 2.83M16.95 16.95l2.83 2.83M1 12h4M19 12h4M4.22 19.78l2.83-2.83M16.95 7.05l2.83-2.83" />
      </svg>
    ),
    title: '멀티에이전트 자율 스프린트',
    desc: 'Planner, Generator, Evaluator가 자율적으로 스프린트를 순환하며 백로그를 해결합니다.',
  },
  {
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
        <polyline points="16 18 22 12 16 6" />
        <polyline points="8 6 2 12 8 18" />
        <line x1="14" y1="4" x2="10" y2="20" />
      </svg>
    ),
    title: '코드 생성 & 평가 자동화',
    desc: 'AI가 코드를 작성하고, 빌드/테스트/린트를 자동 실행하여 품질을 보장합니다.',
  },
  {
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
        <path d="M12.22 2h-.44a2 2 0 00-2 2v.18a2 2 0 01-1 1.73l-.43.25a2 2 0 01-2 0l-.15-.08a2 2 0 00-2.73.73l-.22.38a2 2 0 00.73 2.73l.15.1a2 2 0 011 1.72v.51a2 2 0 01-1 1.74l-.15.09a2 2 0 00-.73 2.73l.22.38a2 2 0 002.73.73l.15-.08a2 2 0 012 0l.43.25a2 2 0 011 1.73V20a2 2 0 002 2h.44a2 2 0 002-2v-.18a2 2 0 011-1.73l.43-.25a2 2 0 012 0l.15.08a2 2 0 002.73-.73l.22-.39a2 2 0 00-.73-2.73l-.15-.08a2 2 0 01-1-1.74v-.5a2 2 0 011-1.74l.15-.09a2 2 0 00.73-2.73l-.22-.38a2 2 0 00-2.73-.73l-.15.08a2 2 0 01-2 0l-.43-.25a2 2 0 01-1-1.73V4a2 2 0 00-2-2z" />
        <circle cx="12" cy="12" r="3" />
      </svg>
    ),
    title: '확장 가능한 구성',
    desc: '커스텀 프롬프트, 모델 라우팅, 역할별 모델 설정으로 자유롭게 커스터마이즈합니다.',
  },
  {
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
        <rect x="2" y="3" width="20" height="14" rx="2" />
        <line x1="8" y1="21" x2="16" y2="21" />
        <line x1="12" y1="17" x2="12" y2="21" />
        <path d="M6 8h.01M9 8h.01M12 8h.01" />
      </svg>
    ),
    title: '팀 모드',
    desc: 'tmux 기반으로 최대 8개의 병렬 AI 에이전트를 동시에 실행합니다.',
  },
  {
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
        <path d="M21 15a2 2 0 01-2 2H7l-4 4V5a2 2 0 012-2h14a2 2 0 012 2z" />
        <path d="M8 9h8M8 13h4" />
      </svg>
    ),
    title: '자연어 커맨드',
    desc: 'harn do "백로그에서 우선순위 높은것 진행해줘" — 자연어로 명령합니다.',
  },
  {
    icon: (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
        <path d="M12 2a5 5 0 015 5v3a5 5 0 01-10 0V7a5 5 0 015-5z" />
        <path d="M8 14v1a4 4 0 008 0v-1" />
        <circle cx="12" cy="20" r="2" />
        <line x1="12" y1="17" x2="12" y2="18" />
      </svg>
    ),
    title: '프로젝트 메모리',
    desc: '스프린트 회고와 실패 패턴을 기억하여 세션을 넘어 학습합니다.',
  },
]

function Features() {
  return (
    <section id="features" className="relative py-32 px-6 dot-grid">
      <div className="max-w-6xl mx-auto">
        <Reveal>
          <div className="text-center mb-16">
            <p className="text-neon font-mono text-sm tracking-wide mb-3">FEATURES</p>
            <h2 className="font-heading text-3xl sm:text-4xl md:text-5xl font-bold tracking-tight">
              개발 루프의 모든 것
            </h2>
          </div>
        </Reveal>

        <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-5">
          {features.map((f, i) => (
            <Reveal key={f.title} delay={(i % 3) + 1 as 1 | 2 | 3}>
              <div className="feature-card rounded-2xl bg-surface-raised p-6 h-full">
                <div className="w-10 h-10 rounded-lg bg-neon/10 text-neon flex items-center justify-center mb-4">
                  {f.icon}
                </div>
                <h3 className="font-heading font-bold text-lg mb-2">{f.title}</h3>
                <p className="text-text-secondary text-sm leading-relaxed">{f.desc}</p>
              </div>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  )
}

/* ════════════════════════════════════════════
   Quick Start Section
   ════════════════════════════════════════════ */
function QuickStart() {
  const [copied, setCopied] = useState(false)
  const code = `# Install globally
npm install -g @tyrannoapartment/harn

# Initialize in your project
cd your-project
harn init

# Start the sprint loop
harn start`

  const copyAll = () => {
    navigator.clipboard.writeText('npm install -g @tyrannoapartment/harn && cd your-project && harn init && harn start')
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <section id="quickstart" className="relative py-32 px-6">
      <div className="max-w-3xl mx-auto">
        <Reveal>
          <div className="text-center mb-12">
            <p className="text-neon font-mono text-sm tracking-wide mb-3">QUICK START</p>
            <h2 className="font-heading text-3xl sm:text-4xl md:text-5xl font-bold tracking-tight">
              3줄이면 시작
            </h2>
            <p className="text-text-secondary mt-4">
              설치하고, 초기화하고, 실행하세요. 그게 전부입니다.
            </p>
          </div>
        </Reveal>

        <Reveal delay={1}>
          <div className="terminal">
            <div className="terminal-header">
              <div className="terminal-dot bg-[#FF5F57]" />
              <div className="terminal-dot bg-[#FEBC2E]" />
              <div className="terminal-dot bg-[#28C840]" />
              <span className="ml-3 text-text-tertiary text-xs font-mono">terminal</span>
              <button
                onClick={copyAll}
                className="copy-btn ml-auto text-text-tertiary cursor-pointer"
                aria-label="Copy all commands"
              >
                {copied ? (
                  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="var(--color-neon)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <polyline points="3.5 8.5 6.5 11.5 12.5 5.5" />
                  </svg>
                ) : (
                  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                    <rect x="5" y="5" width="9" height="9" rx="2" />
                    <path d="M5 11H3.5A1.5 1.5 0 012 9.5v-7A1.5 1.5 0 013.5 1h7A1.5 1.5 0 0112 2.5V5" />
                  </svg>
                )}
              </button>
            </div>
            <pre className="p-6 font-mono text-sm leading-7 overflow-x-auto">
              {code.split('\n').map((line, i) => (
                <div key={i}>
                  {line.startsWith('#') ? (
                    <span className="text-text-tertiary">{line}</span>
                  ) : line.trim() === '' ? (
                    <br />
                  ) : (
                    <>
                      <span className="text-neon select-none">{'> '}</span>
                      <span className="text-text-primary">{line}</span>
                    </>
                  )}
                </div>
              ))}
            </pre>
          </div>
        </Reveal>

        <Reveal delay={2}>
          <div className="mt-8 text-center">
            <p className="text-text-secondary text-sm">
              또는 npx로 바로 실행:{' '}
              <code className="text-neon bg-neon/10 px-2 py-0.5 rounded font-mono text-xs">
                npx @tyrannoapartment/harn init
              </code>
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  )
}

/* ════════════════════════════════════════════
   Footer
   ════════════════════════════════════════════ */
function Footer() {
  return (
    <footer className="border-t border-border-subtle py-12 px-6">
      <div className="max-w-6xl mx-auto flex flex-col sm:flex-row items-center justify-between gap-6 text-sm text-text-secondary">
        <div className="flex items-center gap-3">
          <span className="w-6 h-6 rounded-md bg-neon/10 border border-neon/20 flex items-center justify-center text-neon font-mono text-xs font-bold">
            h
          </span>
          <span className="font-heading font-medium text-text-primary">harn</span>
          <span className="text-text-tertiary">MIT License</span>
        </div>

        <div className="flex items-center gap-6">
          <a href="https://tyrannoapartment.com" target="_blank" rel="noopener noreferrer" className="hover:text-text-primary transition-colors">
            tyrannoapartment.com
          </a>
          <a href="https://github.com/Tyrannoapartment/harn" target="_blank" rel="noopener noreferrer" className="hover:text-text-primary transition-colors flex items-center gap-1.5">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
              <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
            </svg>
            GitHub
          </a>
        </div>
      </div>
    </footer>
  )
}

/* ════════════════════════════════════════════
   App
   ════════════════════════════════════════════ */
export default function App() {
  return (
    <div className="min-h-screen bg-surface text-text-primary">
      <Navbar />
      <Hero />
      <HowItWorks />
      <Features />
      <QuickStart />
      <Footer />
    </div>
  )
}
