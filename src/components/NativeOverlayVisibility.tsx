import { type ReactNode } from 'react'
import { NativeOverlayVisibilityContext } from './NativeOverlayVisibilityContext'

interface NativeOverlayVisibilityProviderProps {
  visible: boolean
  children: ReactNode
}

export function NativeOverlayVisibilityProvider({
  visible,
  children,
}: NativeOverlayVisibilityProviderProps) {
  return (
    <NativeOverlayVisibilityContext.Provider value={visible}>
      {children}
    </NativeOverlayVisibilityContext.Provider>
  )
}
