import { isRegistered, register, unregister } from '@tauri-apps/plugin-global-shortcut'
import { DEFAULT_LISTENING_SHORTCUT, type ListeningShortcut } from './listeningShortcut'

export const NATIVE_LISTENING_SHORTCUT_EVENT = 'arco:listening-shortcut-pressed'

export const registerListeningShortcut = async (
  shortcut: ListeningShortcut,
  onPressed: () => void,
) => {
  if (shortcut !== DEFAULT_LISTENING_SHORTCUT && await isRegistered(DEFAULT_LISTENING_SHORTCUT)) {
    await unregister(DEFAULT_LISTENING_SHORTCUT)
  }
  if (!shortcut) return
  if (await isRegistered(shortcut)) return
  await register(shortcut, (event) => {
    if (event.state === 'Pressed') onPressed()
  })
  if (!await isRegistered(shortcut)) {
    await unregister(shortcut)
    throw new Error('macOS did not register this shortcut.')
  }
}

export const unregisterListeningShortcut = async (shortcut: ListeningShortcut) => {
  if (!shortcut) return
  await unregister(shortcut)
}
