import { useState, useEffect, useCallback } from 'react'
import { t as translate, setLang, getLang, onLangChange } from '@/lib/i18n'
import { api } from '@/lib/api'

/**
 * React hook for i18n. Returns a `t()` function that auto-updates
 * when language changes.
 */
export function useI18n() {
  const [, rerender] = useState(0)

  useEffect(() => {
    // Load language from config on mount
    api.getConfig()
      .then((cfg: Record<string, string>) => {
        if (cfg.HARN_LANG) setLang(cfg.HARN_LANG)
      })
      .catch(() => {})
  }, [])

  useEffect(() => {
    return onLangChange(() => rerender((n) => n + 1))
  }, [])

  const t = useCallback((key: string) => translate(key), [])

  return { t, lang: getLang(), setLang }
}
