import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { PlatformActionButton } from './PlatformActionButton'
import { NativeOverlayVisibilityProvider } from './NativeOverlayVisibility'

const invokeMock = vi.hoisted(() => vi.fn())
const listenMock = vi.hoisted(() => vi.fn())
const listeners = vi.hoisted(() => new Map<string, (event: { payload: { id: string } }) => void>())

vi.mock('@tauri-apps/api/core', () => ({ invoke: invokeMock }))
vi.mock('@tauri-apps/api/event', () => ({ listen: listenMock }))

class ResizeObserverMock {
  observe() {}
  disconnect() {}
}

describe('PlatformActionButton', () => {
  beforeEach(() => {
    Object.defineProperty(window, '__TAURI_INTERNALS__', { configurable: true, value: {} })
    Object.defineProperty(window, 'innerHeight', { configurable: true, value: 720 })
    Object.defineProperty(window, 'ResizeObserver', { configurable: true, value: ResizeObserverMock })
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockReturnValue({
      x: 620, y: 48, top: 48, left: 620, right: 732, bottom: 84,
      width: 112, height: 36, toJSON: () => ({}),
    })
    invokeMock.mockReset().mockResolvedValue(true)
    listeners.clear()
    listenMock.mockReset().mockImplementation(async (event, listener) => {
      listeners.set(event, listener)
      return vi.fn()
    })
  })

  afterEach(() => {
    delete (window as Window & { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__
    vi.restoreAllMocks()
  })

  it('hands a prominent page action to a native Glass NSButton and routes its action back once', async () => {
    const onPress = vi.fn()
    const { unmount } = render(
      <PlatformActionButton nativeId="notes-new" label="New note" symbol="plus" variant="prominent" onPress={onPress}>
        New note
      </PlatformActionButton>,
    )

    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith('sync_native_action_button', {
      state: {
        id: 'notes-new', x: 620, top: 48, width: 112, height: 36, viewportHeight: 720,
        visible: true, obscured: false, title: 'New note', symbol: 'plus', enabled: true, variant: 'prominent',
      },
    }))

    const fallback = document.querySelector<HTMLButtonElement>('button[aria-label="New note"]')
    expect(fallback).not.toBeNull()
    if (!fallback) throw new Error('native action geometry button should remain mounted')
    expect(fallback).toHaveAttribute('data-native-control', 'active')
    expect(fallback).toHaveAttribute('aria-hidden', 'true')
    expect(fallback).toHaveAttribute('tabindex', '-1')

    act(() => listeners.get('arco:native-action')?.({ payload: { id: 'notes-new' } }))
    act(() => listeners.get('arco:native-action')?.({ payload: { id: 'settings-open' } }))
    expect(onPress).toHaveBeenCalledOnce()

    unmount()
    await waitFor(() => expect(invokeMock).toHaveBeenLastCalledWith('sync_native_action_button', {
      state: expect.objectContaining({ id: 'notes-new', visible: false }),
    }))
  })

  it('preserves disabled state in AppKit and refuses synthetic action events while disabled', async () => {
    const onPress = vi.fn()
    render(
      <PlatformActionButton nativeId="notes-new" label="New note" symbol="plus" variant="prominent" disabled onPress={onPress}>
        New note
      </PlatformActionButton>,
    )

    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith('sync_native_action_button', {
      state: expect.objectContaining({ id: 'notes-new', enabled: false }),
    }))
    act(() => listeners.get('arco:native-action')?.({ payload: { id: 'notes-new' } }))
    expect(onPress).not.toHaveBeenCalled()
  })

  it('removes the native control while a WebView modal owns the window', async () => {
    const control = (visible: boolean) => (
      <NativeOverlayVisibilityProvider visible={visible}>
        <PlatformActionButton nativeId="settings-open" label="Open settings" symbol="slider.horizontal.3" variant="toolbar" onPress={vi.fn()}>
          Settings
        </PlatformActionButton>
      </NativeOverlayVisibilityProvider>
    )
    const { rerender } = render(control(true))
    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith('sync_native_action_button', {
      state: expect.objectContaining({ id: 'settings-open', visible: true, obscured: false }),
    }))

    rerender(control(false))

    await waitFor(() => expect(invokeMock).toHaveBeenLastCalledWith('sync_native_action_button', {
      state: expect.objectContaining({ id: 'settings-open', visible: false, obscured: false }),
    }))
    const fallback = document.querySelector<HTMLButtonElement>('button[aria-label="Open settings"]')
    expect(fallback).toHaveAttribute('data-native-control', 'active')
  })

  it('keeps the existing accessible HTML button when AppKit is unavailable', async () => {
    invokeMock.mockRejectedValue(new Error('native action unavailable'))
    const user = userEvent.setup()
    const onPress = vi.fn()
    render(
      <PlatformActionButton nativeId="settings-open" label="Open settings" symbol="slider.horizontal.3" variant="toolbar" onPress={onPress}>
        Settings
      </PlatformActionButton>,
    )

    const button = screen.getByRole('button', { name: 'Open settings' })
    await user.click(button)
    expect(onPress).toHaveBeenCalledOnce()
    expect(button).not.toHaveAttribute('data-native-control', 'active')
  })
})
