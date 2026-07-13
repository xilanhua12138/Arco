import type { AudioMode, ProviderId, TranscriptionConfig } from '../types'
import {
  DEFAULT_LISTENING_SHORTCUT,
  LEGACY_FN_LISTENING_SHORTCUT,
  isValidListeningShortcut,
  type ListeningShortcut,
} from './listeningShortcut'
import { isValidTranscriptionConfig } from './transcriptionConfig'

export const ONBOARDING_STORAGE_KEY = 'arco.onboarding.v1'
export const ONBOARDING_DRAFT_STORAGE_KEY = 'arco.onboarding.draft.v1'

export interface OnboardingState {
  completed: boolean
  skipped: boolean
}

const defaultState: OnboardingState = { completed: false, skipped: false }

export interface OnboardingDraft {
  version: 1
  step: 1 | 2 | 3 | 4 | 5
  furthestStep: 1 | 2 | 3 | 4 | 5
  agentChoice: 'agent' | 'transcript'
  primary: ProviderId | null
  secondary: ProviderId | null
  testedProvider: ProviderId | null
  transcriptionConfig: TranscriptionConfig
  audioMode: AudioMode
  listeningShortcut: ListeningShortcut
}

const providerIds = new Set<ProviderId>(['codex', 'claude'])
const audioModes = new Set<AudioMode>(['both', 'system', 'mic'])

const isNullableProvider = (value: unknown): value is ProviderId | null => (
  value === null || providerIds.has(value as ProviderId)
)

const isOnboardingDraft = (value: unknown): value is OnboardingDraft => {
  if (!value || typeof value !== 'object') return false
  const draft = value as Partial<OnboardingDraft>
  return draft.version === 1
    && Number.isInteger(draft.step)
    && Number.isInteger(draft.furthestStep)
    && (draft.step ?? 0) >= 1
    && (draft.step ?? 0) <= 5
    && (draft.furthestStep ?? 0) >= (draft.step ?? 6)
    && (draft.furthestStep ?? 0) <= 5
    && (draft.agentChoice === 'agent' || draft.agentChoice === 'transcript')
    && isNullableProvider(draft.primary)
    && isNullableProvider(draft.secondary)
    && isNullableProvider(draft.testedProvider)
    && (draft.primary === null || draft.primary !== draft.secondary)
    && isValidTranscriptionConfig(draft.transcriptionConfig)
    && audioModes.has(draft.audioMode as AudioMode)
    && (draft.listeningShortcut === null
      || (typeof draft.listeningShortcut === 'string' && isValidListeningShortcut(draft.listeningShortcut)))
}

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
  clearOnboardingDraft()
  return next
}

export const loadOnboardingDraft = (): OnboardingDraft | null => {
  try {
    const stored = window.localStorage.getItem(ONBOARDING_DRAFT_STORAGE_KEY)
    if (!stored) return null
    let parsed: unknown = JSON.parse(stored)
    if (
      parsed
      && typeof parsed === 'object'
      && (parsed as Partial<OnboardingDraft>).listeningShortcut === LEGACY_FN_LISTENING_SHORTCUT
    ) {
      parsed = { ...parsed, listeningShortcut: DEFAULT_LISTENING_SHORTCUT }
      window.localStorage.setItem(ONBOARDING_DRAFT_STORAGE_KEY, JSON.stringify(parsed))
    }
    if (isOnboardingDraft(parsed)) return parsed
  } catch {
    // Invalid partial writes must never trap the user in onboarding.
  }
  clearOnboardingDraft()
  return null
}

export const saveOnboardingDraft = (draft: OnboardingDraft) => {
  if (!isOnboardingDraft(draft)) throw new Error('Invalid onboarding draft')
  window.localStorage.setItem(ONBOARDING_DRAFT_STORAGE_KEY, JSON.stringify(draft))
}

export const clearOnboardingDraft = () => {
  window.localStorage.removeItem(ONBOARDING_DRAFT_STORAGE_KEY)
}
