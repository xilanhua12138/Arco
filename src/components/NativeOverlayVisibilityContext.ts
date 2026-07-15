import { createContext, useContext } from 'react'

export const NativeOverlayVisibilityContext = createContext(true)

export const useNativeOverlayVisibility = () => useContext(NativeOverlayVisibilityContext)
