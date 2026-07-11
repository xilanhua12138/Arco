import { en, type TranslationKey, zhCN } from './messages'

export type Locale = 'en' | 'zh-CN'
export type TranslationParams = Record<string, string | number>
export type Translate = (key: TranslationKey, params?: TranslationParams) => string

export const localeStorageKey = 'arco.locale'
const supportedLocales = new Set<Locale>(['en', 'zh-CN'])
const resources: Record<Locale, Record<TranslationKey, string>> = {
  en,
  'zh-CN': zhCN,
}

export const resolveLocale = (
  storedLocale: string | null,
  browserLocales: readonly string[] = [],
): Locale => {
  if (storedLocale && supportedLocales.has(storedLocale as Locale)) return storedLocale as Locale
  return browserLocales.some((locale) => locale.toLocaleLowerCase().startsWith('zh')) ? 'zh-CN' : 'en'
}

export const getInitialLocale = (): Locale => {
  const saved = window.localStorage.getItem(localeStorageKey)
  const validSaved = saved && supportedLocales.has(saved as Locale) ? saved : null
  return resolveLocale(validSaved, navigator.languages)
}

export const translate = (
  locale: Locale,
  key: TranslationKey,
  params: TranslationParams = {},
) => {
  const template = resources[locale][key] ?? en[key]
  return Object.entries(params).reduce(
    (message, [name, value]) => message.replaceAll(`{{${name}}}`, String(value)),
    template,
  )
}

export const formatDurationLabel = (durationLabel: string, t: Translate) => {
  const match = durationLabel.trim().match(/^(\d+)\s*(?:m|min)$/i)
  return match ? t('history.durationMinutes', { count: Number(match[1]) }) : durationLabel
}

export const localizedSpeakerLabel = (speaker: string, t: Translate) => {
  const number = speaker.match(/\d+/)?.[0] ?? '1'
  return speaker.toLocaleLowerCase().startsWith('remote')
    ? t('transcript.remoteSpeaker', { number })
    : speaker.toLocaleLowerCase().startsWith('in room')
      ? t('transcript.roomSpeaker', { number })
      : speaker
}
