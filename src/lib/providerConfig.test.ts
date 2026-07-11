import { describe, expect, it } from 'vitest'
import type { RuntimeStatus } from '../types'
import {
  PROVIDER_CONFIG_STORAGE_KEY,
  createProviderConfig,
  loadProviderConfig,
  resolveProviderRoute,
  saveProviderConfig,
} from './providerConfig'

const runtimes: RuntimeStatus[] = [
  { provider: 'codex', available: true, version: 'codex 1.0', path: '/bin/codex' },
  { provider: 'claude', available: true, version: 'claude 1.0', path: '/bin/claude' },
]

describe('provider configuration', () => {
  it('falls back to first-run setup when storage is missing, malformed, or structurally invalid', () => {
    expect(loadProviderConfig()).toEqual({ setupComplete: false, primary: null, secondary: null })

    window.localStorage.setItem(PROVIDER_CONFIG_STORAGE_KEY, '{not json')
    expect(loadProviderConfig()).toEqual({ setupComplete: false, primary: null, secondary: null })

    window.localStorage.setItem(PROVIDER_CONFIG_STORAGE_KEY, JSON.stringify({
      setupComplete: true,
      primary: 'codex',
      secondary: 'codex',
    }))
    expect(loadProviderConfig()).toEqual({ setupComplete: false, primary: null, secondary: null })
  })

  it('creates and persists only complete configurations backed by available CLIs', () => {
    const config = createProviderConfig('codex', 'claude', runtimes)

    expect(config).toEqual({ setupComplete: true, primary: 'codex', secondary: 'claude' })
    saveProviderConfig(config)
    expect(JSON.parse(window.localStorage.getItem(PROVIDER_CONFIG_STORAGE_KEY) ?? '')).toEqual(config)
    expect(loadProviderConfig()).toEqual(config)

    expect(() => createProviderConfig('codex', 'codex', runtimes)).toThrow('Primary and secondary providers must be different.')
    expect(() => createProviderConfig('claude', null, [
      { ...runtimes[0], available: true },
      { ...runtimes[1], available: false },
    ])).toThrow('The primary provider must be available.')
  })

  it('preserves a valid saved preference when runtime availability changes later', () => {
    window.localStorage.setItem(PROVIDER_CONFIG_STORAGE_KEY, JSON.stringify({
      setupComplete: true,
      primary: 'codex',
      secondary: 'claude',
    }))

    expect(loadProviderConfig()).toEqual({ setupComplete: true, primary: 'codex', secondary: 'claude' })
  })

  it('routes to primary first and only uses secondary when the primary runtime is unavailable', () => {
    const config = createProviderConfig('codex', 'claude', runtimes)

    expect(resolveProviderRoute(config, runtimes)).toEqual({
      provider: 'codex',
      available: true,
      isFailover: false,
    })
    expect(resolveProviderRoute(config, [
      { ...runtimes[0], available: false },
      { ...runtimes[1], available: true },
    ])).toEqual({
      provider: 'claude',
      available: true,
      isFailover: true,
    })
    expect(resolveProviderRoute(config, runtimes.map((runtime) => ({ ...runtime, available: false })))).toEqual({
      provider: 'codex',
      available: false,
      isFailover: false,
    })
  })
})
