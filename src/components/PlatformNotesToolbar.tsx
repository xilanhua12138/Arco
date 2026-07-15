import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { type ReactNode, useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { useNativeOverlayVisibility } from './NativeOverlayVisibilityContext'

const NATIVE_NOTES_TOOLBAR_EVENT = 'arco:native-notes-toolbar'

export type NotesToolbarAction =
  | 'title'
  | 'heading'
  | 'subheading'
  | 'body'
  | 'monostyled'
  | 'bold'
  | 'italic'
  | 'strikethrough'
  | 'bullet'
  | 'dash'
  | 'numbered'
  | 'checklist'
  | 'quote'
  | 'table'
  | 'code'
  | 'write'
  | 'preview'

export interface NotesToolbarLabels {
  format: string
  title: string
  heading: string
  subheading: string
  body: string
  monostyled: string
  bold: string
  italic: string
  strikethrough: string
  bullet: string
  dash: string
  numbered: string
  checklist: string
  quote: string
  table: string
  code: string
  write: string
  preview: string
}

interface PlatformNotesToolbarProps {
  labels: NotesToolbarLabels
  mode: 'write' | 'preview'
  onAction: (action: NotesToolbarAction) => void
  children: ReactNode
}

interface NativeNotesToolbarState {
  x: number
  top: number
  width: number
  height: number
  viewportHeight: number
  visible: boolean
  obscured: boolean
  mode: 'write' | 'preview'
  labelsJson: string
}

const hasTauriRuntime = () => '__TAURI_INTERNALS__' in window

export function PlatformNotesToolbar({ labels, mode, onAction, children }: PlatformNotesToolbarProps) {
  const nativeOverlayVisible = useNativeOverlayVisibility()
  const rootRef = useRef<HTMLElement>(null)
  const propsRef = useRef({ labelsJson: JSON.stringify(labels), mode, onAction, nativeOverlayVisible })
  const [nativeActive, setNativeActive] = useState(false)

  const nativeState = useCallback((visible: boolean): NativeNotesToolbarState | null => {
    const root = rootRef.current
    if (!root) return null
    const bounds = root.getBoundingClientRect()
    const presented = visible && propsRef.current.nativeOverlayVisible
    return {
      x: bounds.left,
      top: bounds.top,
      width: bounds.width,
      height: bounds.height,
      viewportHeight: window.innerHeight,
      visible: presented,
      obscured: false,
      mode: propsRef.current.mode,
      labelsJson: propsRef.current.labelsJson,
    }
  }, [])

  const syncNative = useCallback(async (visible = true) => {
    if (!hasTauriRuntime()) return false
    const state = nativeState(visible)
    if (!state) return false
    try {
      return await invoke<boolean>('sync_native_notes_toolbar', { state })
    } catch (error) {
      console.warn('Arco could not activate the native SwiftUI notes toolbar.', error)
      return false
    }
  }, [nativeState])

  useLayoutEffect(() => {
    propsRef.current = { labelsJson: JSON.stringify(labels), mode, onAction, nativeOverlayVisible }
  }, [labels, mode, nativeOverlayVisible, onAction])

  useEffect(() => {
    if (!hasTauriRuntime()) return
    let disposed = false
    let unlisten: (() => void) | undefined
    void listen<string>(NATIVE_NOTES_TOOLBAR_EVENT, (event) => {
      const action = event.payload as NotesToolbarAction
      if (propsRef.current.nativeOverlayVisible && [
        'title', 'heading', 'subheading', 'body', 'monostyled',
        'bold', 'italic', 'strikethrough',
        'bullet', 'dash', 'numbered', 'checklist', 'quote',
        'table', 'code', 'write', 'preview',
      ].includes(action)) {
        propsRef.current.onAction(action)
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
    const root = rootRef.current
    if (!root) return
    const updateGeometry = () => void syncNative(true).then(setNativeActive)
    const observer = new ResizeObserver(updateGeometry)
    observer.observe(root)
    window.addEventListener('resize', updateGeometry)
    updateGeometry()
    return () => {
      observer.disconnect()
      window.removeEventListener('resize', updateGeometry)
      void syncNative(false)
    }
  }, [syncNative])

  useLayoutEffect(() => {
    void syncNative(true).then(setNativeActive)
  }, [labels, mode, nativeOverlayVisible, syncNative])

  return (
    <section
      ref={rootRef}
      className="note-format-toolbar-surface"
      aria-label={labels.format}
      data-native-notes-toolbar={nativeActive ? 'active' : undefined}
    >
      {children}
    </section>
  )
}
