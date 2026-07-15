import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { type ReactNode, useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { useNativeOverlayVisibility } from './NativeOverlayVisibilityContext'

const NATIVE_ACTION_EVENT = 'arco:native-action'

type NativeActionId = 'notes-new' | 'notes-list-toggle' | 'settings-open' | 'capture-toggle'
type NativeActionVariant = 'prominent' | 'standard' | 'toolbar'

interface PlatformActionButtonProps {
  nativeId: NativeActionId
  id?: string
  className?: string
  label: string
  symbol: string
  variant: NativeActionVariant
  disabled?: boolean
  ariaHasPopup?: 'dialog'
  layoutVersion?: string | number
  onPress: () => void
  children: ReactNode
}

interface NativeActionState {
  id: NativeActionId
  x: number
  top: number
  width: number
  height: number
  viewportHeight: number
  visible: boolean
  obscured: boolean
  title: string
  symbol: string
  enabled: boolean
  variant: NativeActionVariant
}

const hasTauriRuntime = () => '__TAURI_INTERNALS__' in window

export function PlatformActionButton({
  nativeId,
  id,
  className = '',
  label,
  symbol,
  variant,
  disabled = false,
  ariaHasPopup,
  layoutVersion,
  onPress,
  children,
}: PlatformActionButtonProps) {
  const nativeOverlayVisible = useNativeOverlayVisibility()
  const rootRef = useRef<HTMLButtonElement>(null)
  const propsRef = useRef({ label, symbol, variant, disabled, onPress, nativeOverlayVisible })
  const [nativeActive, setNativeActive] = useState(false)

  const nativeState = useCallback((visible: boolean): NativeActionState | null => {
    const root = rootRef.current
    if (!root) return null
    const bounds = root.getBoundingClientRect()
    const presented = visible && propsRef.current.nativeOverlayVisible
    return {
      id: nativeId,
      x: bounds.left,
      top: bounds.top,
      width: bounds.width,
      height: bounds.height,
      viewportHeight: window.innerHeight,
      visible: presented,
      obscured: false,
      title: propsRef.current.label,
      symbol: propsRef.current.symbol,
      enabled: !propsRef.current.disabled,
      variant: propsRef.current.variant,
    }
  }, [nativeId])

  const syncNative = useCallback(async (visible = true) => {
    if (!hasTauriRuntime()) return false
    const state = nativeState(visible)
    if (!state) return false
    try {
      return await invoke<boolean>('sync_native_action_button', { state })
    } catch (error) {
      console.warn('Arco could not activate a native macOS action button.', error)
      return false
    }
  }, [nativeState])

  useLayoutEffect(() => {
    propsRef.current = { label, symbol, variant, disabled, onPress, nativeOverlayVisible }
  }, [disabled, label, nativeOverlayVisible, onPress, symbol, variant])

  useEffect(() => {
    if (!hasTauriRuntime()) return
    let disposed = false
    let unlisten: (() => void) | undefined
    void listen<{ id: string }>(NATIVE_ACTION_EVENT, (event) => {
      if (event.payload.id === nativeId && propsRef.current.nativeOverlayVisible && !propsRef.current.disabled) propsRef.current.onPress()
    }).then((next) => {
      if (disposed) next()
      else unlisten = next
    })
    return () => {
      disposed = true
      unlisten?.()
    }
  }, [nativeId])

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
  }, [disabled, label, layoutVersion, nativeOverlayVisible, symbol, syncNative, variant])

  return (
    <button
      ref={rootRef}
      id={id}
      type="button"
      className={className}
      aria-label={label}
      aria-haspopup={ariaHasPopup}
      aria-hidden={nativeActive ? true : undefined}
      tabIndex={nativeActive ? -1 : undefined}
      data-native-control={nativeActive ? 'active' : undefined}
      disabled={disabled}
      onClick={onPress}
    >
      {children}
    </button>
  )
}
