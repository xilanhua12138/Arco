import { describe, expect, it } from 'vitest'
import {
  ONBOARDING_STORAGE_KEY,
  completeOnboarding,
  loadOnboardingState,
} from './onboarding'

describe('first-run onboarding state', () => {
  it('is incomplete until the user finishes or deliberately skips', () => {
    expect(loadOnboardingState()).toEqual({ completed: false, skipped: false })
    completeOnboarding(true)
    expect(loadOnboardingState()).toEqual({ completed: true, skipped: true })
  })

  it('does not trust malformed or future onboarding data', () => {
    window.localStorage.setItem(ONBOARDING_STORAGE_KEY, JSON.stringify({ completed: 'yes' }))
    expect(loadOnboardingState()).toEqual({ completed: false, skipped: false })
  })
})
