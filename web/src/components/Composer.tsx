import { useState, useRef, type KeyboardEvent } from 'react'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import { ArrowBigUp, Loading03Icon } from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { useI18n } from '@/hooks/useI18n'

interface ComposerProps {
  loading: boolean
  onSubmit: (text: string) => void
}

export function Composer({ loading, onSubmit }: ComposerProps) {
  const { t } = useI18n()
  const [value, setValue] = useState('')
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const submittingRef = useRef(false)

  const submit = () => {
    const text = value.trim()
    if (!text || loading || submittingRef.current) return
    submittingRef.current = true
    setValue('')
    onSubmit(text)
    setTimeout(() => {
      submittingRef.current = false
      textareaRef.current?.focus()
    }, 50)
  }

  const onKey = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      submit()
    }
  }

  return (
    <div className="p-3 border-t bg-background">
      {loading && (
        <div className="flex items-center gap-2 px-2 pb-2 text-xs text-muted-foreground">
          <HugeiconsIcon icon={Loading03Icon} size={14} className="animate-spin" />
          <span>{t('console.thinking')}</span>
        </div>
      )}
      <div className="relative">
        <Textarea
          ref={textareaRef}
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={onKey}
          placeholder={t('console.placeholder')}
          className="min-h-[88px] max-h-[200px] resize-none text-sm font-mono pr-14 pb-12"
          disabled={loading}
        />
        <Button
          size="lg"
          className="absolute bottom-2 right-2 h-9 w-9 rounded-md p-0"
          onClick={submit}
          disabled={!value.trim() || loading}
        >
          {loading ? (
            <HugeiconsIcon icon={Loading03Icon} size={20} className="animate-spin" />
          ) : (
            <HugeiconsIcon icon={ArrowBigUp} size={20} />
          )}
        </Button>
      </div>
    </div>
  )
}
