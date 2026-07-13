import { beforeEach, describe, expect, it } from 'vitest'
import {
  ONBOARDING_DRAFT_STORAGE_KEY,
  ONBOARDING_STORAGE_KEY,
  clearOnboardingDraft,
  completeOnboarding,
  loadOnboardingDraft,
  loadOnboardingState,
  saveOnboardingDraft,
} from './onboarding'

describe('first-run onboarding state', () => {
  beforeEach(() => window.localStorage.clear())

  it('is incomplete until the user finishes or deliberately skips', () => {
    expect(loadOnboardingState()).toEqual({ completed: false, skipped: false })
    completeOnboarding(true)
    expect(loadOnboardingState()).toEqual({ completed: true, skipped: true })
  })

  it('does not trust malformed or future onboarding data', () => {
    window.localStorage.setItem(ONBOARDING_STORAGE_KEY, JSON.stringify({ completed: 'yes' }))
    expect(loadOnboardingState()).toEqual({ completed: false, skipped: false })
  })

  it('round-trips a resumable draft with the exact completed choices', () => {
    const draft = {
      version: 1 as const,
      step: 3 as const,
      furthestStep: 3 as const,
      agentChoice: 'transcript' as const,
      primary: null,
      secondary: null,
      testedProvider: null,
      transcriptionConfig: {
        provider: 'local' as const,
        model: 'whisper-base' as const,
        language: 'zh-CN' as const,
        diarization: 'lseend-ami-streaming' as const,
      },
      audioMode: 'both' as const,
      listeningShortcut: 'CommandOrControl+Shift+Space' as const,
    }

    saveOnboardingDraft(draft)

    expect(loadOnboardingDraft()).toEqual(draft)
  })

  it('keeps onboarding progress while migrating the legacy Fn shortcut', () => {
    window.localStorage.setItem(ONBOARDING_DRAFT_STORAGE_KEY, JSON.stringify({
      version: 1,
      step: 4,
      furthestStep: 4,
      agentChoice: 'transcript',
      primary: null,
      secondary: null,
      testedProvider: null,
      transcriptionConfig: {
        provider: 'deepgram',
        model: 'nova-3',
        language: 'zh-CN',
        diarization: 'provider',
      },
      audioMode: 'both',
      listeningShortcut: 'Fn+KeyM',
    }))

    expect(loadOnboardingDraft()).toMatchObject({
      step: 4,
      furthestStep: 4,
      listeningShortcut: 'CommandOrControl+Shift+Space',
    })
    expect(JSON.parse(window.localStorage.getItem(ONBOARDING_DRAFT_STORAGE_KEY) ?? '{}'))
      .toMatchObject({ step: 4, listeningShortcut: 'CommandOrControl+Shift+Space' })
  })

  it('drops malformed or future drafts instead of trapping the user', () => {
    window.localStorage.setItem(ONBOARDING_DRAFT_STORAGE_KEY, JSON.stringify({ version: 99, step: 3 }))

    expect(loadOnboardingDraft()).toBeNull()
    expect(window.localStorage.getItem(ONBOARDING_DRAFT_STORAGE_KEY)).toBeNull()
  })

  it('clears the resumable draft only after completion or an explicit clear', () => {
    const draft = {
      version: 1 as const,
      step: 1 as const,
      furthestStep: 1 as const,
      agentChoice: 'agent' as const,
      primary: 'codex' as const,
      secondary: null,
      testedProvider: 'codex' as const,
      transcriptionConfig: {
        provider: 'deepgram' as const,
        model: 'nova-3' as const,
        language: 'zh-CN' as const,
        diarization: 'provider' as const,
      },
      audioMode: 'both' as const,
      listeningShortcut: 'CommandOrControl+Shift+Space' as const,
    }
    saveOnboardingDraft(draft)

    completeOnboarding(false)
    expect(loadOnboardingDraft()).toBeNull()

    saveOnboardingDraft(draft)
    clearOnboardingDraft()
    expect(loadOnboardingDraft()).toBeNull()
  })
})
