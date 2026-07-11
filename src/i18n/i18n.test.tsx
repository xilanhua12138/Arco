import { act, renderHook } from '@testing-library/react'
import type { ReactNode } from 'react'
import { describe, expect, it } from 'vitest'
import {
  I18nProvider,
  getInitialLocale,
  resolveLocale,
  translate,
  useI18n,
} from './i18n'

describe('i18n locale resolution', () => {
  it('prefers a saved supported locale over the operating-system locale', () => {
    expect(resolveLocale('en', ['zh-CN'])).toBe('en')
    expect(resolveLocale('zh-CN', ['en-US'])).toBe('zh-CN')
  })

  it('maps Chinese system locales to Simplified Chinese and otherwise falls back to English', () => {
    expect(resolveLocale(null, ['zh-HK', 'en-US'])).toBe('zh-CN')
    expect(resolveLocale(null, ['fr-FR', 'de-DE'])).toBe('en')
    expect(resolveLocale('unsupported', ['en-US'])).toBe('en')
  })

  it('reads the persisted locale without accepting malformed values', () => {
    window.localStorage.setItem('arco.locale', 'zh-CN')
    expect(getInitialLocale()).toBe('zh-CN')

    window.localStorage.setItem('arco.locale', 'not-a-locale')
    expect(getInitialLocale()).toBe(resolveLocale(null, navigator.languages))
  })
})

describe('i18n translations', () => {
  it('renders both locale resources and interpolates dynamic values', () => {
    expect(translate('en', 'history.lineCount', { count: 3 })).toBe('3 lines')
    expect(translate('zh-CN', 'history.lineCount', { count: 3 })).toBe('3 行')
    expect(translate('zh-CN', 'agent.failover', { primary: 'Codex', provider: 'Claude' }))
      .toBe('Codex 当前不可用，正在使用 Claude。')
  })
})

describe('I18nProvider', () => {
  it('persists language changes and updates the document language', () => {
    window.localStorage.setItem('arco.locale', 'en')
    const wrapper = ({ children }: { children: ReactNode }) => (
      <I18nProvider>{children}</I18nProvider>
    )
    const { result } = renderHook(() => useI18n(), { wrapper })

    expect(result.current.locale).toBe('en')
    expect(document.documentElement.lang).toBe('en')

    act(() => result.current.setLocale('zh-CN'))

    expect(result.current.locale).toBe('zh-CN')
    expect(window.localStorage.getItem('arco.locale')).toBe('zh-CN')
    expect(document.documentElement.lang).toBe('zh-CN')
    expect(result.current.t('nav.history')).toBe('历史')
  })
})
