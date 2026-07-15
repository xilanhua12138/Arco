import { act, render, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { PlatformNotesToolbar } from './PlatformNotesToolbar'
import { NativeOverlayVisibilityProvider } from './NativeOverlayVisibility'

const invokeMock = vi.hoisted(() => vi.fn())
const listeners = vi.hoisted(() => new Map<string, (event: { payload: string }) => void>())

vi.mock('@tauri-apps/api/core', () => ({ invoke: invokeMock }))
vi.mock('@tauri-apps/api/event', () => ({
  listen: vi.fn(async (event: string, callback: (event: { payload: string }) => void) => {
    listeners.set(event, callback)
    return () => listeners.delete(event)
  }),
}))

class ResizeObserverMock {
  observe() {}
  disconnect() {}
}

describe('PlatformNotesToolbar', () => {
  beforeEach(() => {
    Object.defineProperty(window, '__TAURI_INTERNALS__', { configurable: true, value: {} })
    Object.defineProperty(window, 'innerHeight', { configurable: true, value: 760 })
    Object.defineProperty(window, 'ResizeObserver', { configurable: true, value: ResizeObserverMock })
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockReturnValue({
      x: 430, y: 48, top: 48, left: 430, right: 820, bottom: 92,
      width: 390, height: 44, toJSON: () => ({}),
    })
    invokeMock.mockReset().mockResolvedValue(true)
    listeners.clear()
  })

  afterEach(() => {
    delete (window as Window & { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__
    vi.restoreAllMocks()
  })

  it('replaces the web fallback with one native SwiftUI glass control cluster', async () => {
    const onAction = vi.fn()
    const { container } = render(
      <PlatformNotesToolbar
        labels={{
          format: 'Format', title: 'Title', heading: 'Heading', subheading: 'Subheading', body: 'Body',
          monostyled: 'Monostyled', bold: 'Bold', italic: 'Italic',
          strikethrough: 'Strikethrough', bullet: 'Bulleted list',
          dash: 'Dashed list', numbered: 'Numbered list', checklist: 'Checklist', quote: 'Quote',
          table: 'Table', code: 'Code', write: 'Write', preview: 'Preview',
        }}
        mode="write"
        onAction={onAction}
      >
        <button type="button">Fallback</button>
      </PlatformNotesToolbar>,
    )

    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith('sync_native_notes_toolbar', {
      state: expect.objectContaining({
        x: 430, top: 48, width: 390, height: 44, viewportHeight: 760,
        visible: true, obscured: false, mode: 'write', labelsJson: expect.stringContaining('"format":"Format"'),
      }),
    }))
    expect(container.querySelector('section')).toHaveAttribute('data-native-notes-toolbar', 'active')

    act(() => listeners.get('arco:native-notes-toolbar')?.({ payload: 'bold' }))
    expect(onAction).toHaveBeenCalledWith('bold')

    act(() => listeners.get('arco:native-notes-toolbar')?.({ payload: 'subheading' }))
    expect(onAction).toHaveBeenCalledWith('subheading')

    act(() => listeners.get('arco:native-notes-toolbar')?.({ payload: 'table' }))
    expect(onAction).toHaveBeenCalledWith('table')
  })

  it('removes the native format cluster while a WebView modal owns the window', async () => {
    const labels = {
      format: 'Format', title: 'Title', heading: 'Heading', subheading: 'Subheading', body: 'Body',
      monostyled: 'Monostyled', bold: 'Bold', italic: 'Italic', strikethrough: 'Strikethrough',
      bullet: 'Bulleted list', dash: 'Dashed list', numbered: 'Numbered list', checklist: 'Checklist',
      quote: 'Quote', table: 'Table', code: 'Code', write: 'Write', preview: 'Preview',
    }
    const toolbar = (visible: boolean) => (
      <NativeOverlayVisibilityProvider visible={visible}>
        <PlatformNotesToolbar labels={labels} mode="write" onAction={vi.fn()}><span>Fallback</span></PlatformNotesToolbar>
      </NativeOverlayVisibilityProvider>
    )
    const { rerender } = render(toolbar(true))
    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith('sync_native_notes_toolbar', {
      state: expect.objectContaining({ visible: true, obscured: false }),
    }))

    rerender(toolbar(false))

    await waitFor(() => expect(invokeMock).toHaveBeenLastCalledWith('sync_native_notes_toolbar', {
      state: expect.objectContaining({ visible: false, obscured: false }),
    }))
    expect(document.querySelector('section')).toHaveAttribute('data-native-notes-toolbar', 'active')
  })
})
