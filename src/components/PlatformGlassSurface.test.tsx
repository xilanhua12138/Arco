import { render, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { PlatformGlassSurface } from './PlatformGlassSurface'
import { NativeOverlayVisibilityProvider } from './NativeOverlayVisibility'

const invokeMock = vi.hoisted(() => vi.fn())

vi.mock('@tauri-apps/api/core', () => ({ invoke: invokeMock }))

class ResizeObserverMock {
  observe() {}
  disconnect() {}
}

describe('PlatformGlassSurface', () => {
  beforeEach(() => {
    Object.defineProperty(window, '__TAURI_INTERNALS__', { configurable: true, value: {} })
    Object.defineProperty(window, 'innerHeight', { configurable: true, value: 760 })
    Object.defineProperty(window, 'ResizeObserver', { configurable: true, value: ResizeObserverMock })
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockReturnValue({
      x: 280, y: 420, top: 420, left: 280, right: 800, bottom: 580,
      width: 520, height: 160, toJSON: () => ({}),
    })
    invokeMock.mockReset().mockResolvedValue(true)
  })

  afterEach(() => {
    delete (window as Window & { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__
    vi.restoreAllMocks()
  })

  it('places a passive native SwiftUI glass card behind web content', async () => {
    const { container, unmount } = render(
      <PlatformGlassSurface
        nativeId="current-stats"
        className="current-idle-stats"
        cornerRadius={18}
        tone="neutral"
      >
        <h2>On this Mac</h2>
      </PlatformGlassSurface>,
    )

    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith('sync_native_glass_surface', {
      state: {
        id: 'current-stats', x: 280, top: 420, width: 520, height: 160,
        viewportHeight: 760, visible: true, obscured: false, cornerRadius: 18, tone: 'neutral',
      },
    }))
    expect(container.querySelector('.current-idle-stats')).toHaveAttribute('data-native-surface', 'active')

    unmount()
    await waitFor(() => expect(invokeMock).toHaveBeenLastCalledWith('sync_native_glass_surface', {
      state: expect.objectContaining({ id: 'current-stats', visible: false }),
    }))
  })

  it('keeps the semantic web surface when native glass is unavailable', async () => {
    invokeMock.mockRejectedValue(new Error('native surface unavailable'))
    const { container } = render(
      <PlatformGlassSurface nativeId="current-shortcuts" cornerRadius={18} tone="elevated">
        <h2>Shortcuts</h2>
      </PlatformGlassSurface>,
    )

    await waitFor(() => expect(invokeMock).toHaveBeenCalled())
    expect(container.querySelector('section')).not.toHaveAttribute('data-native-surface', 'active')
  })

  it('removes the native material while a WebView modal owns the window', async () => {
    const surface = (visible: boolean) => (
      <NativeOverlayVisibilityProvider visible={visible}>
        <PlatformGlassSurface nativeId="current-stats" cornerRadius={18} tone="neutral">
          <h2>On this Mac</h2>
        </PlatformGlassSurface>
      </NativeOverlayVisibilityProvider>
    )
    const { container, rerender } = render(surface(true))
    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith('sync_native_glass_surface', {
      state: expect.objectContaining({ visible: true, obscured: false }),
    }))

    rerender(surface(false))

    await waitFor(() => expect(invokeMock).toHaveBeenLastCalledWith('sync_native_glass_surface', {
      state: expect.objectContaining({ visible: false, obscured: false }),
    }))
    expect(container.querySelector('section')).toHaveAttribute('data-native-surface', 'active')
  })
})
