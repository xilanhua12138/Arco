const AGENT_WORKSPACE_KEY = 'arco.agentWorkspace'

export const loadAgentWorkspace = (): string | null => {
  const workspace = window.localStorage.getItem(AGENT_WORKSPACE_KEY)?.trim()
  return workspace?.startsWith('/') ? workspace : null
}

export const saveAgentWorkspace = (workspace: string) => {
  window.localStorage.setItem(AGENT_WORKSPACE_KEY, workspace.trim())
}

export const agentWorkspaceStorageKey = AGENT_WORKSPACE_KEY

export const workspaceName = (workspace: string) => {
  const parts = workspace.split('/').filter(Boolean)
  return parts.at(-1) ?? workspace
}
