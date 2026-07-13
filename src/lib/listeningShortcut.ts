export type ListeningShortcut = string | null

export const LISTENING_SHORTCUT_STORAGE_KEY = 'arco.listeningShortcut.v1'
export const DEFAULT_LISTENING_SHORTCUT = 'CommandOrControl+Shift+Space'
export const LEGACY_FN_LISTENING_SHORTCUT = 'Fn+KeyM'

export const shouldUseShortcutAsOnboardingTest = (
  providerSetupOpen: boolean,
  editingProviders: boolean,
) => providerSetupOpen && !editingProviders

const disabledValue = '__disabled__'
const modifierOrder = ['CommandOrControl', 'Control', 'Alt', 'Shift'] as const
const allowedKey = /^(?:Space|Enter|Tab|Backspace|Escape|Arrow(?:Up|Down|Left|Right)|Key[A-Z]|Digit[0-9]|F(?:[1-9]|1[0-2]))$/

export const isValidListeningShortcut = (value: string) => {
  const parts = value.split('+')
  if (parts.length < 2) return false
  const key = parts.at(-1) ?? ''
  const modifiers = parts.slice(0, -1)
  return allowedKey.test(key)
    && modifiers.length > 0
    && modifiers.every((modifier) => modifierOrder.includes(modifier as typeof modifierOrder[number]))
    && new Set(modifiers).size === modifiers.length
}

export const loadListeningShortcut = (): ListeningShortcut => {
  const stored = window.localStorage.getItem(LISTENING_SHORTCUT_STORAGE_KEY)
  if (stored === null) return DEFAULT_LISTENING_SHORTCUT
  if (stored === disabledValue) return null
  if (stored === LEGACY_FN_LISTENING_SHORTCUT) {
    window.localStorage.setItem(LISTENING_SHORTCUT_STORAGE_KEY, DEFAULT_LISTENING_SHORTCUT)
    return DEFAULT_LISTENING_SHORTCUT
  }
  return isValidListeningShortcut(stored) ? stored : DEFAULT_LISTENING_SHORTCUT
}

export const saveListeningShortcut = (shortcut: ListeningShortcut) => {
  if (shortcut === null) {
    window.localStorage.setItem(LISTENING_SHORTCUT_STORAGE_KEY, disabledValue)
    return
  }
  if (!isValidListeningShortcut(shortcut)) throw new Error('Invalid listening shortcut')
  window.localStorage.setItem(LISTENING_SHORTCUT_STORAGE_KEY, shortcut)
}

const keyLabel = (key: string) => {
  if (key.startsWith('Key')) return key.slice(3)
  if (key.startsWith('Digit')) return key.slice(5)
  return key.replace('Arrow', '↑').replace('Up', '').replace('Down', '↓').replace('Left', '←').replace('Right', '→')
}

export const formatListeningShortcut = (shortcut: ListeningShortcut) => {
  if (!shortcut) return 'Off'
  const labels: Record<string, string> = {
    CommandOrControl: '⌘',
    Control: '⌃',
    Alt: '⌥',
    Shift: '⇧',
  }
  const parts = shortcut.split('+')
  return [...parts.slice(0, -1).map((part) => labels[part] ?? part), keyLabel(parts.at(-1) ?? '')].join(' ')
}

type ShortcutKeyboardEvent = Pick<KeyboardEvent, 'key' | 'code' | 'metaKey' | 'ctrlKey' | 'altKey' | 'shiftKey'> & {
  getModifierState?: (modifier: 'Fn') => boolean
}

export const listeningShortcutFromKeyboardEvent = (event: ShortcutKeyboardEvent): ListeningShortcut => {
  if (['Meta', 'Control', 'Alt', 'Shift'].includes(event.key)) return null
  const modifiers: string[] = []
  if (event.metaKey || event.ctrlKey) modifiers.push('CommandOrControl')
  if (event.altKey) modifiers.push('Alt')
  if (event.shiftKey) modifiers.push('Shift')
  if (modifiers.length === 0) return null

  let key = event.code
  if (event.key === ' ') key = 'Space'
  if (!allowedKey.test(key)) return null
  return [...modifiers, key].join('+')
}
