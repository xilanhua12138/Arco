import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { Search } from 'lucide-react'
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { useNativeOverlayVisibility } from './NativeOverlayVisibilityContext'

const NATIVE_SEARCH_CHANGED_EVENT = 'arco:native-search-changed'

interface PlatformSearchFieldProps {
  className?: string
  label: string
  placeholder: string
  value: string
  onChange: (value: string) => void
}

interface NativeSearchFieldState {
  x: number
  top: number
  width: number
  height: number
  viewportHeight: number
  visible: boolean
  obscured: boolean
  value: string
  placeholder: string
  focus: boolean
}

const hasTauriRuntime = () => '__TAURI_INTERNALS__' in window

export function PlatformSearchField({
  className = '',
  label,
  placeholder,
  value,
  onChange,
}: PlatformSearchFieldProps) {
  const nativeOverlayVisible = useNativeOverlayVisibility()
  const rootRef = useRef<HTMLLabelElement>(null)
  const valueRef = useRef(value)
  const placeholderRef = useRef(placeholder)
  const nativeOverlayVisibleRef = useRef(nativeOverlayVisible)
  const [nativeActive, setNativeActive] = useState(false)

  const nativeState = useCallback((visible: boolean, focus = false): NativeSearchFieldState | null => {
    const root = rootRef.current
    if (!root) return null
    const bounds = root.getBoundingClientRect()
    const presented = visible && nativeOverlayVisibleRef.current
    return {
      x: bounds.left,
      top: bounds.top,
      width: bounds.width,
      height: bounds.height,
      viewportHeight: window.innerHeight,
      visible: presented,
      obscured: false,
      value: valueRef.current,
      placeholder: placeholderRef.current,
      focus: focus && presented,
    }
  }, [])

  const syncNative = useCallback(async (visible = true, focus = false) => {
    if (!hasTauriRuntime()) return false
    const state = nativeState(visible, focus)
    if (!state) return false
    try {
      return await invoke<boolean>('sync_native_search_field', { state })
    } catch (error) {
      console.warn('Arco could not activate the native macOS search field.', error)
      return false
    }
  }, [nativeState])

  useLayoutEffect(() => {
    valueRef.current = value
    placeholderRef.current = placeholder
    nativeOverlayVisibleRef.current = nativeOverlayVisible
  }, [nativeOverlayVisible, placeholder, value])

  useEffect(() => {
    if (!hasTauriRuntime()) return
    let disposed = false
    let unlisten: (() => void) | undefined
    void listen<string>(NATIVE_SEARCH_CHANGED_EVENT, (event) => {
      if (nativeOverlayVisibleRef.current) onChange(event.payload)
    }).then((next) => {
      if (disposed) next()
      else unlisten = next
    })
    return () => {
      disposed = true
      unlisten?.()
    }
  }, [onChange])

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
  }, [nativeOverlayVisible, placeholder, syncNative, value])

  const classes = ['history-search', className].filter(Boolean).join(' ')
  return (
    <label
      ref={rootRef}
      className={classes}
      data-native-search={nativeActive ? 'active' : undefined}
    >
      <Search size={17} aria-hidden="true" />
      <span className="sr-only">{label}</span>
      <input
        aria-label={label}
        aria-hidden={nativeActive ? true : undefined}
        tabIndex={nativeActive ? -1 : undefined}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        onFocus={() => {
          if (nativeActive && nativeOverlayVisible) void syncNative(true, true).then(setNativeActive)
        }}
        placeholder={placeholder}
      />
    </label>
  )
}
