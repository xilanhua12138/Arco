import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { useEffect, useLayoutEffect, useRef } from 'react'
import type { CaptureState } from '../types'

const NATIVE_SHELL_EVENT = 'arco:native-shell'

export type NativeShellPage = 'current' | 'history' | 'notes' | 'review'

export interface NativeShellLabels {
  current: string
  history: string
  notes: string
  settings: string
  ready: string
  audioMode: string
  captureAction: string
}

interface PlatformNativeShellProps {
  visible?: boolean
  page: NativeShellPage
  capturePhase: CaptureState['phase']
  captureEnabled: boolean
  captureActionVisible: boolean
  labels: NativeShellLabels
  onChangePage: (page: Exclude<NativeShellPage, 'review'>) => void
  onToggleCapture: () => void
  onOpenSettings: () => void
}

interface NativeShellState {
  visible: boolean
  page: NativeShellPage
  capturePhase: CaptureState['phase']
  captureEnabled: boolean
  captureActionVisible: boolean
  labels: NativeShellLabels
}

const hasTauriRuntime = () => '__TAURI_INTERNALS__' in window

export function PlatformNativeShell({
  visible = true,
  page,
  capturePhase,
  captureEnabled,
  captureActionVisible,
  labels,
  onChangePage,
  onToggleCapture,
  onOpenSettings,
}: PlatformNativeShellProps) {
  const propsRef = useRef({ captureEnabled, onChangePage, onToggleCapture, onOpenSettings })
  const stateRef = useRef<NativeShellState>({
    visible,
    page,
    capturePhase,
    captureEnabled,
    captureActionVisible,
    labels,
  })

  useLayoutEffect(() => {
    propsRef.current = { captureEnabled, onChangePage, onToggleCapture, onOpenSettings }
    stateRef.current = {
      visible,
      page,
      capturePhase,
      captureEnabled,
      captureActionVisible,
      labels,
    }
  }, [captureActionVisible, captureEnabled, capturePhase, labels, onChangePage, onOpenSettings, onToggleCapture, page, visible])

  useEffect(() => {
    if (!hasTauriRuntime()) return
    let disposed = false
    let unlisten: (() => void) | undefined
    void listen<{ action: string }>(NATIVE_SHELL_EVENT, (event) => {
      const { action } = event.payload
      if (action === 'current' || action === 'history' || action === 'notes') {
        propsRef.current.onChangePage(action)
      } else if (action === 'toggleCapture' && propsRef.current.captureEnabled) {
        propsRef.current.onToggleCapture()
      } else if (action === 'settings') {
        propsRef.current.onOpenSettings()
      }
    }).then((next) => {
      if (disposed) next()
      else unlisten = next
    })
    return () => {
      disposed = true
      unlisten?.()
    }
  }, [])

  useLayoutEffect(() => {
    if (!hasTauriRuntime()) return
    void invoke('sync_native_shell', { state: stateRef.current })
      .catch((error) => console.warn('Arco could not activate its native macOS shell.', error))
  }, [captureActionVisible, captureEnabled, capturePhase, labels, page, visible])

  useEffect(() => () => {
    if (!hasTauriRuntime()) return
    void invoke('sync_native_shell', {
      state: { ...stateRef.current, visible: false },
    }).catch(() => undefined)
  }, [])

  return null
}
