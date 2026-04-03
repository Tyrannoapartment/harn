import type { ReactElement } from 'react'

interface AILogoProps {
  backend: string
  model?: string
  size?: number
}

function CopilotLogo({ size }: { size: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path d="M12 2C6.477 2 2 6.477 2 12c0 4.42 2.865 8.17 6.839 9.49.5.092.682-.217.682-.482 0-.237-.008-.866-.013-1.7-2.782.603-3.369-1.342-3.369-1.342-.454-1.155-1.11-1.462-1.11-1.462-.908-.62.069-.608.069-.608 1.003.07 1.531 1.03 1.531 1.03.892 1.529 2.341 1.087 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.11-4.555-4.943 0-1.091.39-1.984 1.029-2.683-.103-.253-.446-1.27.098-2.647 0 0 .84-.269 2.75 1.025A9.578 9.578 0 0112 6.836a9.58 9.58 0 012.504.337c1.909-1.294 2.747-1.025 2.747-1.025.546 1.377.202 2.394.1 2.647.64.699 1.028 1.592 1.028 2.683 0 3.842-2.339 4.687-4.566 4.935.359.309.678.919.678 1.852 0 1.336-.012 2.415-.012 2.743 0 .267.18.578.688.48C19.138 20.167 22 16.418 22 12c0-5.523-4.477-10-10-10z" fill="currentColor"/>
    </svg>
  )
}

function OpenAILogo({ size }: { size: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path d="M22.282 9.821a5.985 5.985 0 00-.516-4.91 6.046 6.046 0 00-6.51-2.9A6.065 6.065 0 004.981 4.18a5.985 5.985 0 00-3.998 2.9 6.046 6.046 0 00.743 7.097 5.98 5.98 0 00.51 4.911 6.051 6.051 0 006.515 2.9A5.985 5.985 0 0013.26 24a6.056 6.056 0 005.772-4.206 5.99 5.99 0 003.997-2.9 6.056 6.056 0 00-.747-7.073zM13.26 22.43a4.476 4.476 0 01-2.876-1.04l.141-.081 4.779-2.758a.795.795 0 00.392-.681v-6.737l2.02 1.168a.071.071 0 01.038.052v5.583a4.504 4.504 0 01-4.494 4.494zM3.6 18.304a4.47 4.47 0 01-.535-3.014l.142.085 4.783 2.759a.771.771 0 00.78 0l5.843-3.369v2.332a.08.08 0 01-.033.062L9.74 19.95a4.5 4.5 0 01-6.14-1.646zM2.34 7.896a4.485 4.485 0 012.366-1.973V11.6a.766.766 0 00.388.676l5.815 3.355-2.02 1.168a.076.076 0 01-.071 0l-4.83-2.786A4.504 4.504 0 012.34 7.872zm16.597 3.855l-5.843-3.387L15.119 7.2a.076.076 0 01.071 0l4.83 2.791a4.494 4.494 0 01-.676 8.105v-5.678a.79.79 0 00-.407-.667zm2.01-3.023l-.141-.085-4.774-2.782a.776.776 0 00-.785 0L9.409 9.23V6.897a.066.066 0 01.028-.061l4.83-2.787a4.5 4.5 0 016.64 4.66zm-12.64 4.135l-2.02-1.164a.08.08 0 01-.038-.057V6.075a4.5 4.5 0 017.375-3.453l-.142.08L8.704 5.46a.795.795 0 00-.393.681zm1.097-2.365l2.602-1.5 2.607 1.5v2.999l-2.597 1.5-2.607-1.5z" fill="currentColor"/>
    </svg>
  )
}

function ClaudeLogo({ size }: { size: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path d="M4.709 15.955l4.72-2.647.08-.23-.08-.128-3.276-.648-.22.019-1.224 3.634zm8.853-10.01l-.56 1.592 4.127 11.405.74-.209.559-1.56-4.866-13.228zm6.199 7.917l-1.224-3.634-.22-.019-3.276.648-.08.128.08.23 4.72 2.647zm-6.908 3.08l-1.058-1.738-4.378 2.454-.06.08.08.11 1.894.714zm0 0l1.895-.714.08-.11-.06-.08-4.378-2.454-1.058 1.738zm2.434.06l-1.376-.519-1.376.519.618 1.786.758.12.758-.12zM12 2.052L6.61 17.03l.529.19 1.524-4.286L12 7.73l3.337 5.204 1.524 4.285.529-.19z" fill="currentColor"/>
    </svg>
  )
}

function GeminiLogo({ size }: { size: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path d="M12 24A14.304 14.304 0 000 12 14.304 14.304 0 0012 0a14.305 14.305 0 0012 12 14.305 14.305 0 00-12 12" fill="currentColor"/>
    </svg>
  )
}

const BACKEND_CONFIG: Record<string, {
  label: string
  color: string
  bg: string
  logo: (size: number) => ReactElement
}> = {
  copilot: {
    label: 'GitHub Copilot',
    color: 'text-foreground',
    bg: 'bg-muted border border-border',
    logo: (s) => <CopilotLogo size={s} />,
  },
  codex: {
    label: 'ChatGPT',
    color: 'text-[#10a37f]',
    bg: 'bg-[#10a37f]/10 border border-[#10a37f]/20',
    logo: (s) => <OpenAILogo size={s} />,
  },
  openai: {
    label: 'OpenAI',
    color: 'text-[#10a37f]',
    bg: 'bg-[#10a37f]/10 border border-[#10a37f]/20',
    logo: (s) => <OpenAILogo size={s} />,
  },
  claude: {
    label: 'Claude',
    color: 'text-[#cc785c]',
    bg: 'bg-[#cc785c]/10 border border-[#cc785c]/20',
    logo: (s) => <ClaudeLogo size={s} />,
  },
  gemini: {
    label: 'Gemini',
    color: 'text-[#4285f4]',
    bg: 'bg-[#4285f4]/10 border border-[#4285f4]/20',
    logo: (s) => <GeminiLogo size={s} />,
  },
}

/**
 * Infer the actual AI provider from the model name.
 * e.g. model="claude-sonnet-4.6" + backend="codex" → should show Claude, not ChatGPT.
 */
function inferBackend(backend: string, model?: string): string {
  if (!model) return backend
  const m = model.toLowerCase()
  if (m.startsWith('claude-')) return 'claude'
  if (m.startsWith('gpt-') || m.startsWith('o1') || m.startsWith('o3')) return backend === 'codex' ? 'codex' : 'copilot'
  if (m.startsWith('gemini-')) return 'gemini'
  return backend
}

export function AILogo({ backend, model, size = 14 }: AILogoProps) {
  const resolved = inferBackend(backend?.toLowerCase() ?? '', model)
  const key = resolved
  const conf = BACKEND_CONFIG[key]
  if (!conf) return null

  return (
    <span className="inline-flex items-center gap-1.5">
      <span
        className={`inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium select-none ${conf.color} ${conf.bg}`}
      >
        <span className={conf.color}>{conf.logo(size)}</span>
        <span>{conf.label}</span>
      </span>
      {model && (
        <span className="text-[10px] text-muted-foreground font-mono select-none">
          {model}
        </span>
      )}
    </span>
  )
}
