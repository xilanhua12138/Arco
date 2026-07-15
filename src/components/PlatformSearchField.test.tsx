import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { PlatformSearchField } from './PlatformSearchField'
import { NativeOverlayVisibilityProvider } from './NativeOverlayVisibility'

const invokeMock = vi.hoisted(() => vi.fn())
const listenMock = vi.hoisted(() => vi.fn())
const listeners = vi.hoisted(() => new Map<string, (event: { payload: string }) => void>())

vi.mock('@tauri-apps/api/core', () => ({ invoke: invokeMock }))
vi.mock('@tauri-apps/api/event', () => ({ listen: listenMock }))

class ResizeObserverMock {
  observe() {}
  disconnect() {}
}

describe('PlatformSearchField', () => {
  beforeEach(() => {
    Object.defineProperty(window, '__TAURI_INTERNALS__', { configurable: true, value: {} })
    Object.defineProperty(window, 'innerHeight', { configurable: true, value: 720 })
    Object.defineProperty(window, 'ResizeObserver', { configurable: true, value: ResizeObserverMock })
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockReturnValue({
      x: 32,
      y: 48,
      top: 48,
      left: 32,
      right: 292,
      bottom: 86,
      width: 260,
      height: 38,
      toJSON: () => ({}),
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

  it('hands geometry and content to AppKit, then removes the CSS-painted control from the native path', async () => {
    const onChange = vi.fn()
    const { unmount } = render(
      <PlatformSearchField
        label="Search meetings"
        placeholder="Search"
        value="design"
        onChange={onChange}
      />,
    )

    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith('sync_native_search_field', {
      state: {
        x: 32,
        top: 48,
        width: 260,
        height: 38,
        viewportHeight: 720,
        visible: true,
        obscured: false,
        value: 'design',
        placeholder: 'Search',
        focus: false,
      },
    }))

    const input = document.querySelector<HTMLInputElement>('input[aria-label="Search meetings"]')
    expect(input).not.toBeNull()
    if (!input) throw new Error('native geometry input should remain mounted')
    expect(input.closest('label')).toHaveAttribute('data-native-search', 'active')
    expect(input).toHaveAttribute('aria-hidden', 'true')
    expect(input).toHaveAttribute('tabindex', '-1')

    act(() => listeners.get('arco:native-search-changed')?.({ payload: 'native query' }))
    expect(onChange).toHaveBeenLastCalledWith('native query')

    unmount()
    await waitFor(() => expect(invokeMock).toHaveBeenLastCalledWith('sync_native_search_field', {
      state: expect.objectContaining({ visible: false }),
    }))
  })

  it('keeps an accessible editable fallback when native AppKit search is unavailable', async () => {
    invokeMock.mockRejectedValue(new Error('native search unavailable'))
    const user = userEvent.setup()
    const onChange = vi.fn()

    render(
      <PlatformSearchField
        label="Search meetings"
        placeholder="Search"
        value=""
        onChange={onChange}
      />,
    )

    const input = await screen.findByRole('textbox', { name: 'Search meetings' })
    await user.type(input, 'a')
    expect(onChange).toHaveBeenLastCalledWith('a')
    expect(input.closest('label')).not.toHaveAttribute('data-native-search', 'active')
  })

  it('asks the system search field to become first responder for the command-k focus path', async () => {
    render(
      <PlatformSearchField
        label="Search meetings"
        placeholder="Search"
        value=""
        onChange={vi.fn()}
      />,
    )

    const input = document.querySelector<HTMLInputElement>('input[aria-label="Search meetings"]')
    expect(input).not.toBeNull()
    if (!input) throw new Error('native geometry input should remain mounted')
    await waitFor(() => expect(input.closest('label')).toHaveAttribute('data-native-search', 'active'))
    act(() => input.focus())

    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith('sync_native_search_field', {
      state: expect.objectContaining({ visible: true, focus: true }),
    }))
  })

  it('removes the system field while a WebView modal owns the window', async () => {
    const field = (visible: boolean) => (
      <NativeOverlayVisibilityProvider visible={visible}>
        <PlatformSearchField label="Search meetings" placeholder="Search" value="" onChange={vi.fn()} />
      </NativeOverlayVisibilityProvider>
    )
    const { rerender } = render(field(true))
    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith('sync_native_search_field', {
      state: expect.objectContaining({ visible: true, obscured: false }),
    }))

    rerender(field(false))

    await waitFor(() => expect(invokeMock).toHaveBeenLastCalledWith('sync_native_search_field', {
      state: expect.objectContaining({ visible: false, obscured: false }),
    }))
    expect(document.querySelector('label')).toHaveAttribute('data-native-search', 'active')
  })
})
