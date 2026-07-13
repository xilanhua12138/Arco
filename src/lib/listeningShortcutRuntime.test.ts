import { beforeEach, describe, expect, it, vi } from 'vitest'

const { isRegistered, register, unregister } = vi.hoisted(() => ({
  isRegistered: vi.fn().mockResolvedValue(true),
  register: vi.fn(),
  unregister: vi.fn(),
}))

vi.mock('@tauri-apps/plugin-global-shortcut', () => ({ isRegistered, register, unregister }))

import { registerListeningShortcut, unregisterListeningShortcut } from './listeningShortcutRuntime'

describe('global listening shortcut runtime', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    isRegistered.mockReset()
  })

  it('reacts to Pressed once and ignores Released', async () => {
    isRegistered.mockResolvedValueOnce(false).mockResolvedValueOnce(false).mockResolvedValueOnce(true)
    const onPressed = vi.fn()
    await registerListeningShortcut('CommandOrControl+Alt+KeyL', onPressed)

    const handler = register.mock.calls[0][1]
    handler({ state: 'Released' })
    handler({ state: 'Pressed' })

    expect(register).toHaveBeenCalledWith('CommandOrControl+Alt+KeyL', expect.any(Function))
    expect(isRegistered).toHaveBeenCalledWith('CommandOrControl+Alt+KeyL')
    expect(onPressed).toHaveBeenCalledOnce()
  })

  it('does not call the plugin for a disabled shortcut', async () => {
    isRegistered.mockResolvedValueOnce(false)
    await registerListeningShortcut(null, vi.fn())
    await unregisterListeningShortcut(null)
    expect(register).not.toHaveBeenCalled()
    expect(unregister).not.toHaveBeenCalled()
  })

  it('reuses the native default registration instead of trying to register it twice', async () => {
    isRegistered.mockResolvedValueOnce(true)

    await registerListeningShortcut('CommandOrControl+Shift+Space', vi.fn())

    expect(register).not.toHaveBeenCalled()
    expect(unregister).not.toHaveBeenCalled()
  })

  it('removes the native default when the shortcut is disabled', async () => {
    isRegistered.mockResolvedValueOnce(true)

    await registerListeningShortcut(null, vi.fn())

    expect(unregister).toHaveBeenCalledWith('CommandOrControl+Shift+Space')
    expect(register).not.toHaveBeenCalled()
  })

  it('rejects a shortcut that macOS did not register and cleans it up', async () => {
    isRegistered.mockResolvedValueOnce(false).mockResolvedValueOnce(false).mockResolvedValueOnce(false)
    await expect(registerListeningShortcut('CommandOrControl+Alt+KeyL', vi.fn()))
      .rejects.toThrow('macOS did not register this shortcut.')
    expect(unregister).toHaveBeenCalledWith('CommandOrControl+Alt+KeyL')
  })
})
