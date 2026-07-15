import { invoke } from '@tauri-apps/api/core'
import { type ReactNode, useCallback, useLayoutEffect, useRef, useState } from 'react'
import { useNativeOverlayVisibility } from './NativeOverlayVisibilityContext'

type NativeGlassSurfaceId = 'sidebar-capture' | 'current-stats' | 'current-shortcuts'
type NativeGlassSurfaceTone = 'neutral' | 'accent' | 'elevated'

interface PlatformGlassSurfaceProps {
  nativeId: NativeGlassSurfaceId
  className?: string
  cornerRadius: number
  tone: NativeGlassSurfaceTone
  ariaLabel?: string
  children: ReactNode
}

interface NativeGlassSurfaceState {
  id: NativeGlassSurfaceId
  x: number
  top: number
  width: number
  height: number
  viewportHeight: number
  visible: boolean
  obscured: boolean
  cornerRadius: number
  tone: NativeGlassSurfaceTone
}

const hasTauriRuntime = () => '__TAURI_INTERNALS__' in window

export function PlatformGlassSurface({
  nativeId,
  className = '',
  cornerRadius,
  tone,
  ariaLabel,
  children,
}: PlatformGlassSurfaceProps) {
  const nativeOverlayVisible = useNativeOverlayVisibility()
  const rootRef = useRef<HTMLElement>(null)
  const propsRef = useRef({ cornerRadius, tone, nativeOverlayVisible })
  const [nativeActive, setNativeActive] = useState(false)

  const nativeState = useCallback((visible: boolean): NativeGlassSurfaceState | null => {
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
      cornerRadius: propsRef.current.cornerRadius,
      tone: propsRef.current.tone,
    }
  }, [nativeId])

  const syncNative = useCallback(async (visible = true) => {
    if (!hasTauriRuntime()) return false
    const state = nativeState(visible)
    if (!state) return false
    try {
      return await invoke<boolean>('sync_native_glass_surface', { state })
    } catch (error) {
      console.warn('Arco could not activate a native SwiftUI glass surface.', error)
      return false
    }
  }, [nativeState])

  useLayoutEffect(() => {
    propsRef.current = { cornerRadius, tone, nativeOverlayVisible }
  }, [cornerRadius, nativeOverlayVisible, tone])

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
  }, [cornerRadius, nativeOverlayVisible, syncNative, tone])

  return (
    <section
      ref={rootRef}
      className={className}
      aria-label={ariaLabel}
      data-native-surface={nativeActive ? 'active' : undefined}
    >
      {children}
    </section>
  )
}
