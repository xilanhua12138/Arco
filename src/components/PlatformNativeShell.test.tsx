import { act, render, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { PlatformNativeShell } from './PlatformNativeShell'

const invokeMock = vi.hoisted(() => vi.fn())
const listenMock = vi.hoisted(() => vi.fn())
const listeners = vi.hoisted(() => new Map<string, (event: { payload: { action: string } }) => void>())

vi.mock('@tauri-apps/api/core', () => ({ invoke: invokeMock }))
vi.mock('@tauri-apps/api/event', () => ({ listen: listenMock }))

const labels = {
  current: 'Current',
  history: 'History',
  notes: 'Notes',
  settings: 'Settings',
  ready: 'Ready',
  audioMode: 'Hybrid',
  captureAction: 'Start listening',
}

describe('PlatformNativeShell', () => {
  beforeEach(() => {
    Object.defineProperty(window, '__TAURI_INTERNALS__', { configurable: true, value: {} })
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

  it('hands navigation and capture ownership to one native SwiftUI shell', async () => {
    const onChangePage = vi.fn()
    const onToggleCapture = vi.fn()
    const onOpenSettings = vi.fn()
    const { unmount } = render(
      <PlatformNativeShell
        page="notes"
        capturePhase="idle"
        captureEnabled
        captureActionVisible
        labels={labels}
        onChangePage={onChangePage}
        onToggleCapture={onToggleCapture}
        onOpenSettings={onOpenSettings}
      />,
    )

    await waitFor(() => expect(invokeMock).toHaveBeenCalledWith('sync_native_shell', {
      state: {
        visible: true,
        page: 'notes',
        capturePhase: 'idle',
        captureEnabled: true,
        captureActionVisible: true,
        labels,
      },
    }))

    act(() => listeners.get('arco:native-shell')?.({ payload: { action: 'history' } }))
    act(() => listeners.get('arco:native-shell')?.({ payload: { action: 'toggleCapture' } }))
    act(() => listeners.get('arco:native-shell')?.({ payload: { action: 'settings' } }))
    act(() => listeners.get('arco:native-shell')?.({ payload: { action: 'unknown' } }))

    expect(onChangePage).toHaveBeenCalledOnce()
    expect(onChangePage).toHaveBeenCalledWith('history')
    expect(onToggleCapture).toHaveBeenCalledOnce()
    expect(onOpenSettings).toHaveBeenCalledOnce()

    unmount()
    await waitFor(() => expect(invokeMock).toHaveBeenLastCalledWith('sync_native_shell', {
      state: expect.objectContaining({ visible: false }),
    }))
  })

  it('does not dispatch capture while the native action is disabled', async () => {
    const onToggleCapture = vi.fn()
    render(
      <PlatformNativeShell
        page="current"
        capturePhase="starting"
        captureEnabled={false}
        captureActionVisible
        labels={{ ...labels, captureAction: 'Starting' }}
        onChangePage={vi.fn()}
        onToggleCapture={onToggleCapture}
        onOpenSettings={vi.fn()}
      />,
    )

    await waitFor(() => expect(invokeMock).toHaveBeenCalled())
    act(() => listeners.get('arco:native-shell')?.({ payload: { action: 'toggleCapture' } }))
    expect(onToggleCapture).not.toHaveBeenCalled()
  })
})
