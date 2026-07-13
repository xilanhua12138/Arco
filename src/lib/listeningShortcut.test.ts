import { describe, expect, it } from 'vitest'
import {
  DEFAULT_LISTENING_SHORTCUT,
  LISTENING_SHORTCUT_STORAGE_KEY,
  formatListeningShortcut,
  listeningShortcutFromKeyboardEvent,
  loadListeningShortcut,
  saveListeningShortcut,
  shouldUseShortcutAsOnboardingTest,
} from './listeningShortcut'

describe('listening shortcut preferences', () => {
  it('uses one non-system default and persists a custom shortcut', () => {
    expect(loadListeningShortcut()).toBe(DEFAULT_LISTENING_SHORTCUT)
    expect(DEFAULT_LISTENING_SHORTCUT).toBe('CommandOrControl+Shift+Space')
    expect(formatListeningShortcut(DEFAULT_LISTENING_SHORTCUT)).toBe('⌘ ⇧ Space')

    saveListeningShortcut('CommandOrControl+Alt+KeyL')
    expect(loadListeningShortcut()).toBe('CommandOrControl+Alt+KeyL')
    expect(window.localStorage.getItem(LISTENING_SHORTCUT_STORAGE_KEY)).toBe('CommandOrControl+Alt+KeyL')
  })

  it('migrates the unreliable legacy Fn shortcut to the native global shortcut', () => {
    window.localStorage.setItem(LISTENING_SHORTCUT_STORAGE_KEY, 'Fn+KeyM')

    expect(loadListeningShortcut()).toBe(DEFAULT_LISTENING_SHORTCUT)
    expect(window.localStorage.getItem(LISTENING_SHORTCUT_STORAGE_KEY)).toBe(DEFAULT_LISTENING_SHORTCUT)
  })

  it('treats shortcut presses as a test only during first-run onboarding', () => {
    expect(shouldUseShortcutAsOnboardingTest(true, false)).toBe(true)
    expect(shouldUseShortcutAsOnboardingTest(true, true)).toBe(false)
    expect(shouldUseShortcutAsOnboardingTest(false, false)).toBe(false)
  })

  it('can be disabled and recovers from malformed storage', () => {
    saveListeningShortcut(null)
    expect(loadListeningShortcut()).toBeNull()

    window.localStorage.setItem(LISTENING_SHORTCUT_STORAGE_KEY, 'definitely not a shortcut')
    expect(loadListeningShortcut()).toBe(DEFAULT_LISTENING_SHORTCUT)
  })

  it('converts a modified key event and rejects unsupported Fn or unsafe single keys', () => {
    expect(listeningShortcutFromKeyboardEvent({
      key: 'm',
      code: 'KeyM',
      metaKey: false,
      ctrlKey: false,
      altKey: false,
      shiftKey: false,
      getModifierState: (modifier: string) => modifier === 'Fn',
    })).toBeNull()

    expect(listeningShortcutFromKeyboardEvent({
      key: 'l',
      code: 'KeyL',
      metaKey: true,
      ctrlKey: false,
      altKey: true,
      shiftKey: false,
    })).toBe('CommandOrControl+Alt+KeyL')

    expect(listeningShortcutFromKeyboardEvent({
      key: 'l',
      code: 'KeyL',
      metaKey: false,
      ctrlKey: false,
      altKey: false,
      shiftKey: false,
    })).toBeNull()
    expect(listeningShortcutFromKeyboardEvent({
      key: 'Shift',
      code: 'ShiftLeft',
      metaKey: false,
      ctrlKey: false,
      altKey: false,
      shiftKey: true,
    })).toBeNull()
  })
})
