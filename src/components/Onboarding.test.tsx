import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../i18n/i18n'
import type {
  AudioMode,
  AudioSetupCheck,
  DeepgramCredentialStatus,
  RuntimeStatus,
  TranscriptionConfig,
  TranscriptionModelStatus,
} from '../types'
import { Onboarding, type OnboardingResult } from './Onboarding'

const runtimes: RuntimeStatus[] = [
  { provider: 'codex', available: true, version: 'codex 1.0', path: '/bin/codex' },
  { provider: 'claude', available: true, version: 'claude 1.0', path: '/bin/claude' },
]

const deepgramConfig: TranscriptionConfig = {
  provider: 'deepgram',
  model: 'nova-3',
  language: 'zh-CN',
  diarization: 'provider',
}

const emptyDeepgram: DeepgramCredentialStatus = {
  configured: false,
  verified: false,
  message: null,
}

const readyAudio = (mode: AudioMode): AudioSetupCheck => ({
  mode,
  success: true,
  system: { required: mode !== 'mic', ready: mode !== 'mic', level: 0.42, message: null },
  microphone: { required: mode !== 'system', ready: mode !== 'system', level: 0.58, message: null },
})

const renderOnboarding = (overrides: Partial<React.ComponentProps<typeof Onboarding>> = {}) => {
  const onComplete = vi.fn<(result: OnboardingResult) => void>()
  const props: React.ComponentProps<typeof Onboarding> = {
    runtimes,
    transcriptionConfig: deepgramConfig,
    transcriptionModels: [],
    deepgramCredential: emptyDeepgram,
    listeningShortcut: 'Fn+KeyM',
    audioMode: 'both',
    onRefreshRuntimes: vi.fn().mockResolvedValue(runtimes),
    onTestProvider: vi.fn().mockResolvedValue(true),
    onSaveDeepgramApiKey: vi.fn().mockResolvedValue({ configured: true, verified: true, message: 'Deepgram is ready.' }),
    onPrepareTranscriptionModel: vi.fn().mockResolvedValue([]),
    onTestAudio: vi.fn().mockImplementation(async (mode: AudioMode) => readyAudio(mode)),
    onChangeListeningShortcut: vi.fn().mockResolvedValue(true),
    onComplete,
    onSkip: vi.fn(),
    ...overrides,
  }
  render(<I18nProvider><Onboarding {...props} /></I18nProvider>)
  return { props, onComplete }
}

const continueToAgent = async (user: ReturnType<typeof userEvent.setup>) => {
  await user.click(screen.getByRole('button', { name: 'Continue' }))
  expect(screen.getByRole('heading', { name: 'Your meeting Agent' })).toBeVisible()
}

const chooseTranscriptOnly = async (user: ReturnType<typeof userEvent.setup>) => {
  await user.click(screen.getByRole('radio', { name: 'Continue without an Agent' }))
  await user.click(screen.getByRole('button', { name: 'Continue' }))
}

describe('Onboarding', () => {
  it('starts on a standalone landing page, then reveals the setup wizard', async () => {
    const user = userEvent.setup()
    renderOnboarding()

    const landing = screen.getByRole('main', { name: 'Stay in the conversation' })
    expect(within(landing).queryAllByRole('listitem')).toHaveLength(0)
    expect(within(landing).getByText('About 2 minutes')).toBeVisible()

    await user.click(within(landing).getByRole('button', { name: 'Continue' }))

    const setup = screen.getByRole('main', { name: 'Agent' })
    expect(within(setup).getAllByRole('listitem')).toHaveLength(5)
    expect(within(setup).getByRole('button', { name: 'Agent' })).toHaveAttribute('aria-current', 'step')
    expect(within(setup).getByRole('button', { name: 'Transcription' })).toBeDisabled()
    expect(within(setup).getByRole('button', { name: 'Audio check' })).toBeDisabled()
    expect(within(setup).getByRole('button', { name: 'Shortcut' })).toBeDisabled()
    expect(within(setup).getByRole('button', { name: 'First meeting' })).toBeDisabled()
  })

  it('allows transcript-only setup without pretending an Agent is connected', async () => {
    const user = userEvent.setup()
    renderOnboarding({ deepgramCredential: { configured: true, verified: true, message: null } })

    await continueToAgent(user)
    await chooseTranscriptOnly(user)

    expect(screen.getByRole('heading', { name: 'Choose transcription' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeEnabled()
  })

  it('requires a real primary CLI test when the Agent path is selected', async () => {
    const user = userEvent.setup()
    const onTestProvider = vi.fn().mockResolvedValue(false)
    renderOnboarding({ onTestProvider })

    await continueToAgent(user)
    await user.click(screen.getByRole('button', { name: 'Test Codex' }))

    expect(onTestProvider).toHaveBeenCalledWith('codex')
    expect(screen.getByRole('alert')).toHaveTextContent('Codex did not respond')
    expect(screen.getByRole('button', { name: 'Continue' })).toBeDisabled()
  })

  it('verifies a pasted Deepgram key before transcription can continue', async () => {
    const user = userEvent.setup()
    const onSaveDeepgramApiKey = vi.fn().mockResolvedValue({ configured: true, verified: true, message: 'Deepgram is ready.' })
    renderOnboarding({ onSaveDeepgramApiKey })

    await continueToAgent(user)
    await chooseTranscriptOnly(user)
    expect(screen.getByRole('button', { name: 'Continue' })).toBeDisabled()

    await user.type(screen.getByLabelText('Deepgram API key'), 'dg_live_abcdefghijklmnopqrstuvwxyz')
    await user.click(screen.getByRole('button', { name: 'Verify & save' }))

    expect(onSaveDeepgramApiKey).toHaveBeenCalledWith('dg_live_abcdefghijklmnopqrstuvwxyz')
    expect(await screen.findByText('Deepgram is ready.')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeEnabled()
  })

  it('downloads the recommended local ASR and speaker model as one choice', async () => {
    const user = userEvent.setup()
    const readyModels: TranscriptionModelStatus[] = [
      { id: 'nemotron-speech-3.5-streaming', installed: true, phase: 'ready', progress: 1, error: null, path: '/models/nemotron' },
      { id: 'sortformer-streaming', installed: true, phase: 'ready', progress: 1, error: null, path: '/models/sortformer' },
    ]
    const onPrepareTranscriptionModel = vi.fn().mockResolvedValue(readyModels)
    renderOnboarding({ onPrepareTranscriptionModel })

    await continueToAgent(user)
    await chooseTranscriptOnly(user)
    await user.click(screen.getByRole('radio', { name: 'On this Mac' }))
    await user.click(screen.getByRole('button', { name: 'Download & use' }))

    expect(onPrepareTranscriptionModel).toHaveBeenCalledWith('nemotron-speech-3.5-streaming', true)
    expect(await screen.findByText('Ready on this Mac')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeEnabled()
  })

  it('tests only the sources required by the selected meeting type', async () => {
    const user = userEvent.setup()
    const onTestAudio = vi.fn().mockImplementation(async (mode: AudioMode) => readyAudio(mode))
    renderOnboarding({
      deepgramCredential: { configured: true, verified: true, message: null },
      onTestAudio,
    })

    await continueToAgent(user)
    await chooseTranscriptOnly(user)
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByText('In-person meeting'))
    await user.click(screen.getByRole('button', { name: 'Check microphone' }))

    expect(onTestAudio).toHaveBeenCalledWith('mic')
    expect(await screen.findByText('Microphone is ready')).toBeVisible()
    expect(screen.getByText('System audio is not needed')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeEnabled()
  })

  it('finishes with the exact configuration and can start the first meeting immediately', async () => {
    const user = userEvent.setup()
    const { onComplete } = renderOnboarding({
      deepgramCredential: { configured: true, verified: true, message: null },
    })

    await continueToAgent(user)
    await chooseTranscriptOnly(user)
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('button', { name: 'Check audio' }))
    await screen.findByText('Microphone is ready')
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('button', { name: 'Continue' }))

    expect(screen.getByRole('heading', { name: 'Start your first meeting' })).toBeVisible()
    await user.click(screen.getByRole('button', { name: 'Start listening' }))

    expect(onComplete).toHaveBeenCalledWith({
      providerConfig: { setupComplete: false, primary: null, secondary: null },
      transcriptionConfig: deepgramConfig,
      audioMode: 'both',
      startListening: true,
    })
  })
})
