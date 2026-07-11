import { beforeEach, describe, expect, it } from 'vitest'
import {
  agentWorkspaceStorageKey,
  loadAgentWorkspace,
  saveAgentWorkspace,
  workspaceName,
} from './agentWorkspace'

describe('Agent workspace preference', () => {
  beforeEach(() => window.localStorage.removeItem(agentWorkspaceStorageKey))

  it('starts without an implied personal or project folder', () => {
    expect(loadAgentWorkspace()).toBeNull()
  })

  it('persists one absolute workspace for later questions and launches', () => {
    saveAgentWorkspace('  /Users/example/Work/Arco  ')

    expect(loadAgentWorkspace()).toBe('/Users/example/Work/Arco')
  })

  it('ignores invalid relative paths left by stale storage', () => {
    window.localStorage.setItem(agentWorkspaceStorageKey, 'projects/Arco')

    expect(loadAgentWorkspace()).toBeNull()
  })

  it('uses the final folder name for compact composer disclosure', () => {
    expect(workspaceName('/Users/example/Work/Arco')).toBe('Arco')
  })
})
