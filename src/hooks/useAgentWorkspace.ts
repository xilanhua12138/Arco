import { useCallback, useEffect, useState } from 'react'
import { arcoBridge } from '../lib/bridge'
import {
  agentWorkspaceStorageKey,
  loadAgentWorkspace,
  saveAgentWorkspace,
} from '../lib/agentWorkspace'

export function useAgentWorkspace(dialogTitle: string) {
  const [workspace, setWorkspace] = useState<string | null>(loadAgentWorkspace)

  useEffect(() => {
    const refresh = (event: StorageEvent) => {
      if (event.key === agentWorkspaceStorageKey) setWorkspace(loadAgentWorkspace())
    }
    window.addEventListener('storage', refresh)
    return () => window.removeEventListener('storage', refresh)
  }, [])

  const chooseWorkspace = useCallback(async () => {
    const selected = await arcoBridge.chooseAgentWorkspace(dialogTitle)
    if (!selected) return null
    saveAgentWorkspace(selected)
    setWorkspace(selected)
    return selected
  }, [dialogTitle])

  return { workspace, chooseWorkspace }
}
