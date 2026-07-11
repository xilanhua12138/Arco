import type { ProviderId, RuntimeStatus } from '../types'

export const PROVIDER_CONFIG_STORAGE_KEY = 'arco.providerConfig'

export interface ProviderConfig {
  setupComplete: boolean
  primary: ProviderId | null
  secondary: ProviderId | null
}

export interface ProviderRoute {
  provider: ProviderId | null
  available: boolean
  isFailover: boolean
}

const firstRunConfig = (): ProviderConfig => ({
  setupComplete: false,
  primary: null,
  secondary: null,
})

const isProviderId = (value: unknown): value is ProviderId => value === 'codex' || value === 'claude'

const isAvailable = (provider: ProviderId, runtimes: readonly RuntimeStatus[]) => (
  runtimes.some((runtime) => runtime.provider === provider && runtime.available)
)

const parseProviderConfig = (value: unknown): ProviderConfig | null => {
  if (!value || typeof value !== 'object') return null

  const candidate = value as Record<string, unknown>
  if (candidate.setupComplete === false && candidate.primary === null && candidate.secondary === null) {
    return firstRunConfig()
  }

  if (candidate.setupComplete !== true || !isProviderId(candidate.primary)) return null
  if (candidate.secondary !== null && !isProviderId(candidate.secondary)) return null
  if (candidate.primary === candidate.secondary) return null

  return {
    setupComplete: true,
    primary: candidate.primary,
    secondary: candidate.secondary,
  }
}

export function createProviderConfig(
  primary: ProviderId | null,
  secondary: ProviderId | null,
  runtimes: readonly RuntimeStatus[],
): ProviderConfig {
  if (!primary || !isAvailable(primary, runtimes)) {
    throw new Error('The primary provider must be available.')
  }
  if (secondary === primary) {
    throw new Error('Primary and secondary providers must be different.')
  }
  if (secondary && !isAvailable(secondary, runtimes)) {
    throw new Error('The secondary provider must be available.')
  }

  return { setupComplete: true, primary, secondary }
}

export function loadProviderConfig(): ProviderConfig {
  try {
    const stored = window.localStorage.getItem(PROVIDER_CONFIG_STORAGE_KEY)
    if (!stored) return firstRunConfig()
    return parseProviderConfig(JSON.parse(stored)) ?? firstRunConfig()
  } catch {
    return firstRunConfig()
  }
}

export function saveProviderConfig(config: ProviderConfig): void {
  const parsed = parseProviderConfig(config)
  if (!parsed?.setupComplete) {
    throw new Error('Only a complete provider configuration can be saved.')
  }
  window.localStorage.setItem(PROVIDER_CONFIG_STORAGE_KEY, JSON.stringify(parsed))
}

export function resolveProviderRoute(
  config: ProviderConfig,
  runtimes: readonly RuntimeStatus[],
): ProviderRoute {
  if (!config.setupComplete || !config.primary) {
    return { provider: null, available: false, isFailover: false }
  }

  if (isAvailable(config.primary, runtimes)) {
    return { provider: config.primary, available: true, isFailover: false }
  }

  if (config.secondary && isAvailable(config.secondary, runtimes)) {
    return { provider: config.secondary, available: true, isFailover: true }
  }

  return { provider: config.primary, available: false, isFailover: false }
}
