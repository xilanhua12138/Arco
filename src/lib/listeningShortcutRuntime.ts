import { isRegistered, register, unregister } from '@tauri-apps/plugin-global-shortcut'
import type { ListeningShortcut } from './listeningShortcut'

export const registerListeningShortcut = async (
  shortcut: ListeningShortcut,
  onPressed: () => void,
) => {
  if (!shortcut) return
  if (shortcut === 'Fn+KeyM') return
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
  if (shortcut === 'Fn+KeyM') return
  await unregister(shortcut)
}
