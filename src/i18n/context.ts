import { createContext } from 'react'
import { translate, type Locale, type Translate } from './core'

export interface I18nValue {
  locale: Locale
  setLocale: (locale: Locale) => void
  t: Translate
  formatDate: (value: Date | number | string, options?: Intl.DateTimeFormatOptions) => string
  formatNumber: (value: number, options?: Intl.NumberFormatOptions) => string
}

const defaultI18nValue: I18nValue = {
  locale: 'en',
  setLocale: () => undefined,
  t: (key, params) => translate('en', key, params),
  formatDate: (value, options) => new Intl.DateTimeFormat('en', options).format(new Date(value)),
  formatNumber: (value, options) => new Intl.NumberFormat('en', options).format(value),
}

export const I18nContext = createContext<I18nValue>(defaultI18nValue)
