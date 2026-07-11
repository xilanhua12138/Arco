export const ONBOARDING_STORAGE_KEY = 'arco.onboarding.v1'

export interface OnboardingState {
  completed: boolean
  skipped: boolean
}

const defaultState: OnboardingState = { completed: false, skipped: false }

export const loadOnboardingState = (): OnboardingState => {
  try {
    const stored = window.localStorage.getItem(ONBOARDING_STORAGE_KEY)
    if (!stored) return defaultState
    const parsed: unknown = JSON.parse(stored)
    if (
      !parsed
      || typeof parsed !== 'object'
      || typeof (parsed as OnboardingState).completed !== 'boolean'
      || typeof (parsed as OnboardingState).skipped !== 'boolean'
    ) return defaultState
    return parsed as OnboardingState
  } catch {
    return defaultState
  }
}

export const completeOnboarding = (skipped = false) => {
  const next: OnboardingState = { completed: true, skipped }
  window.localStorage.setItem(ONBOARDING_STORAGE_KEY, JSON.stringify(next))
  return next
}
