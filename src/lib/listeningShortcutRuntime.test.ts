import { beforeEach, describe, expect, it, vi } from 'vitest'

const { isRegistered, register, unregister } = vi.hoisted(() => ({
  isRegistered: vi.fn().mockResolvedValue(true),
  register: vi.fn(),
  unregister: vi.fn(),
}))

vi.mock('@tauri-apps/plugin-global-shortcut', () => ({ isRegistered, register, unregister }))

import { registerListeningShortcut, unregisterListeningShortcut } from './listeningShortcutRuntime'

describe('global listening shortcut runtime', () => {
  beforeEach(() => vi.clearAllMocks())

  it('reacts to Pressed once and ignores Released', async () => {
    const onPressed = vi.fn()
    await registerListeningShortcut('CommandOrControl+Shift+Space', onPressed)

    const handler = register.mock.calls[0][1]
    handler({ state: 'Released' })
    handler({ state: 'Pressed' })

    expect(register).toHaveBeenCalledWith('CommandOrControl+Shift+Space', expect.any(Function))
    expect(isRegistered).toHaveBeenCalledWith('CommandOrControl+Shift+Space')
    expect(onPressed).toHaveBeenCalledOnce()
  })

  it('does not call the plugin for a disabled shortcut', async () => {
    await registerListeningShortcut(null, vi.fn())
    await unregisterListeningShortcut(null)
    expect(register).not.toHaveBeenCalled()
    expect(unregister).not.toHaveBeenCalled()
  })

  it('leaves Fn+M to the native macOS listener instead of the unsupported plugin parser', async () => {
    await registerListeningShortcut('Fn+KeyM', vi.fn())
    await unregisterListeningShortcut('Fn+KeyM')
    expect(register).not.toHaveBeenCalled()
    expect(unregister).not.toHaveBeenCalled()
  })

  it('rejects a shortcut that macOS did not register and cleans it up', async () => {
    isRegistered.mockResolvedValueOnce(false)
    await expect(registerListeningShortcut('CommandOrControl+Alt+KeyL', vi.fn()))
      .rejects.toThrow('macOS did not register this shortcut.')
    expect(unregister).toHaveBeenCalledWith('CommandOrControl+Alt+KeyL')
  })
})
