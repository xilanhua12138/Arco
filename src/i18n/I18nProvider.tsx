import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { I18nContext, type I18nValue } from './context'
import {
  getInitialLocale,
  localeStorageKey,
  resolveLocale,
  translate,
  type Locale,
  type TranslationParams,
} from './core'
import type { TranslationKey } from './messages'

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocaleState] = useState<Locale>(getInitialLocale)

  const setLocale = useCallback((nextLocale: Locale) => {
    window.localStorage.setItem(localeStorageKey, nextLocale)
    setLocaleState(nextLocale)
  }, [])

  useEffect(() => {
    document.documentElement.lang = locale
    document.documentElement.dir = 'ltr'
  }, [locale])

  useEffect(() => {
    const syncLocale = (event: StorageEvent) => {
      if (event.key !== localeStorageKey) return
      setLocaleState(resolveLocale(event.newValue, navigator.languages))
    }
    window.addEventListener('storage', syncLocale)
    return () => window.removeEventListener('storage', syncLocale)
  }, [])

  const t = useCallback(
    (key: TranslationKey, params?: TranslationParams) => translate(locale, key, params),
    [locale],
  )
  const formatDate = useCallback(
    (value: Date | number | string, options?: Intl.DateTimeFormatOptions) => (
      new Intl.DateTimeFormat(locale, options).format(new Date(value))
    ),
    [locale],
  )
  const formatNumber = useCallback(
    (value: number, options?: Intl.NumberFormatOptions) => (
      new Intl.NumberFormat(locale, options).format(value)
    ),
    [locale],
  )

  const context = useMemo<I18nValue>(() => ({
    locale,
    setLocale,
    t,
    formatDate,
    formatNumber,
  }), [formatDate, formatNumber, locale, setLocale, t])

  return <I18nContext.Provider value={context}>{children}</I18nContext.Provider>
}
