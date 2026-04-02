import { useState, useRef, type KeyboardEvent } from 'react'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import { ArrowUp01Icon } from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { api } from '@/lib/api'

export function Composer() {
  const [value, setValue] = useState('')
  const [loading, setLoading] = useState(false)
  const textareaRef = useRef<HTMLTextAreaElement>(null)

  const submit = async () => {
    const text = value.trim()
    if (!text || loading) return
    setLoading(true)
    setValue('')
    try {
      await api.runCommand(text)
    } catch { /* ignore */ }
    finally { setLoading(false) }
  }

  const onKey = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      submit()
    }
  }

  return (
    <div className="flex gap-2 p-3 border-t bg-background">
      <Textarea
        ref={textareaRef}
        value={value}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={onKey}
        placeholder="Enter command or natural language… (Enter to send, Shift+Enter for newline)"
        className="min-h-[60px] max-h-[160px] resize-none text-sm font-mono"
        disabled={loading}
      />
      <Button
        size="icon"
        className="h-auto self-end mb-[1px] shrink-0"
        onClick={submit}
        disabled={!value.trim() || loading}
      >
        <HugeiconsIcon icon={ArrowUp01Icon} size={16} />
      </Button>
    </div>
  )
}
