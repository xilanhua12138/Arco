import { act, fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../i18n/i18n'
import { ONBOARDING_DRAFT_STORAGE_KEY } from '../lib/onboarding'
import type {
  AudioMode,
  AudioSetupCheck,
  DeepgramCredentialStatus,
  ElevenLabsCredentialStatus,
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
  asr: { provider: 'deepgram', model: 'nova-3', language: 'zh-CN' },
  diarization: { provider: 'deepgram', model: 'latest' },
}

const emptyDeepgram: DeepgramCredentialStatus = {
  configured: false,
  verified: false,
  message: null,
}

const emptyElevenLabs: ElevenLabsCredentialStatus = {
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
    elevenLabsCredential: emptyElevenLabs,
    listeningShortcut: 'CommandOrControl+Shift+Space',
    shortcutTestCount: 0,
    audioMode: 'both',
    onRefreshRuntimes: vi.fn().mockResolvedValue(runtimes),
    onTestProvider: vi.fn().mockResolvedValue(true),
    onSaveDeepgramApiKey: vi.fn().mockResolvedValue({ configured: true, verified: true, message: 'Deepgram is ready.' }),
    onSaveElevenLabsApiKey: vi.fn().mockResolvedValue({ configured: true, verified: true, message: 'ElevenLabs is ready.' }),
    onPrepareTranscriptionModel: vi.fn().mockResolvedValue([]),
    onTestAudio: vi.fn().mockImplementation(async (mode: AudioMode) => readyAudio(mode)),
    onRelaunch: vi.fn().mockResolvedValue(undefined),
    onChangeListeningShortcut: vi.fn().mockResolvedValue(true),
    onComplete,
    onSkip: vi.fn(),
    ...overrides,
  }
  const view = render(<I18nProvider><Onboarding {...props} /></I18nProvider>)
  return { props, onComplete, ...view }
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
  beforeEach(() => window.localStorage.clear())
  afterEach(() => vi.useRealTimers())

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

  it('offers ElevenLabs and verifies its key before transcription can continue', async () => {
    const user = userEvent.setup()
    const onSaveDeepgramApiKey = vi.fn().mockResolvedValue({
      configured: true,
      verified: true,
      message: 'Deepgram is ready.',
    })
    const onSaveElevenLabsApiKey = vi.fn().mockResolvedValue({
      configured: true,
      verified: true,
      message: 'ElevenLabs is ready.',
    })
    renderOnboarding({ onSaveDeepgramApiKey, onSaveElevenLabsApiKey })

    await continueToAgent(user)
    await chooseTranscriptOnly(user)
    await user.click(screen.getByRole('radio', { name: 'ElevenLabs' }))

    expect(screen.getByRole('radio', { name: 'Deepgram speaker separation' })).toBeChecked()
    expect(screen.getByRole('radio', { name: 'Speaker separation model' })).toBeVisible()
    expect(screen.queryByText(/when listening stops|final speaker/i)).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeDisabled()
    await user.type(screen.getByLabelText('ElevenLabs API key'), 'sk_0123456789abcdefghijklmnopqrstuvwxyz')
    await user.click(screen.getByRole('button', { name: 'Verify & save' }))

    expect(onSaveElevenLabsApiKey).toHaveBeenCalledWith('sk_0123456789abcdefghijklmnopqrstuvwxyz')
    expect(await screen.findByText('ElevenLabs is ready.')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeDisabled()

    await user.type(screen.getByLabelText('Deepgram API key'), 'dg_live_abcdefghijklmnopqrstuvwxyz')
    await user.click(screen.getByRole('button', { name: 'Verify & save' }))

    expect(onSaveDeepgramApiKey).toHaveBeenCalledWith('dg_live_abcdefghijklmnopqrstuvwxyz')
    expect(await screen.findByText('Deepgram is ready.')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeEnabled()
  })

  it('offers every registered speech and speaker model as separate downloads', async () => {
    const user = userEvent.setup()
    const speechReady: TranscriptionModelStatus[] = [
      { id: 'whisper-base', installed: true, phase: 'ready', progress: 1, error: null, path: '/models/whisper-base' },
    ]
    const allReady: TranscriptionModelStatus[] = [
      ...speechReady,
      { id: 'nemotron-speech-3.5-streaming', installed: true, phase: 'ready', progress: 1, error: null, path: '/models/nemotron' },
      { id: 'sortformer-streaming', installed: true, phase: 'ready', progress: 1, error: null, path: '/models/sortformer' },
    ]
    const onPrepareTranscriptionModel = vi.fn()
      .mockResolvedValueOnce(speechReady)
      .mockResolvedValueOnce(allReady)
    renderOnboarding({ onPrepareTranscriptionModel })

    await continueToAgent(user)
    await chooseTranscriptOnly(user)
    await user.click(screen.getByRole('radio', { name: 'On this Mac' }))
    await user.click(screen.getByRole('radio', { name: 'Speaker separation model' }))

    const speechSelect = screen.getByRole('combobox', { name: 'Speech recognition model' })
    const speakerSelect = screen.getByRole('combobox', { name: 'Speaker separation model' })
    expect(within(speechSelect).getAllByRole('option')).toHaveLength(6)
    expect(within(speakerSelect).getAllByRole('option')).toHaveLength(4)
    expect(within(speakerSelect).getByRole('option', { name: 'Pyannote + WeSpeaker' })).toBeVisible()

    await user.selectOptions(speechSelect, 'whisper-base')
    await user.click(screen.getByRole('button', { name: 'Download speech model' }))
    expect(onPrepareTranscriptionModel).toHaveBeenNthCalledWith(1, 'whisper-base')
    expect(screen.getByRole('button', { name: 'Continue' })).toBeDisabled()

    await user.click(screen.getByRole('button', { name: 'Download speaker model' }))
    expect(onPrepareTranscriptionModel).toHaveBeenNthCalledWith(2, 'sortformer-streaming')
    expect(await screen.findAllByText('Ready on this Mac')).toHaveLength(2)
    expect(screen.getByRole('button', { name: 'Continue' })).toBeEnabled()
  })

  it('resumes directly at the audio check with earlier onboarding choices intact', () => {
    window.localStorage.setItem(ONBOARDING_DRAFT_STORAGE_KEY, JSON.stringify({
      version: 1,
      step: 3,
      furthestStep: 3,
      agentChoice: 'transcript',
      primary: null,
      secondary: null,
      testedProvider: null,
      transcriptionConfig: deepgramConfig,
      audioMode: 'both',
      listeningShortcut: 'CommandOrControl+Shift+Space',
    }))

    renderOnboarding({ deepgramCredential: { configured: true, verified: true, message: null } })

    expect(screen.getByRole('heading', { name: 'Check your audio' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Audio check' })).toHaveAttribute('aria-current', 'step')
    expect(screen.getByRole('button', { name: 'Agent' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'Transcription' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'Shortcut' })).toBeDisabled()
  })

  it('confirms a real global shortcut press in place instead of starting an invisible recording', () => {
    window.localStorage.setItem(ONBOARDING_DRAFT_STORAGE_KEY, JSON.stringify({
      version: 1,
      step: 4,
      furthestStep: 4,
      agentChoice: 'transcript',
      primary: null,
      secondary: null,
      testedProvider: null,
      transcriptionConfig: deepgramConfig,
      audioMode: 'both',
      listeningShortcut: 'CommandOrControl+Shift+Space',
    }))
    const { props, rerender } = renderOnboarding({
      deepgramCredential: { configured: true, verified: true, message: null },
      shortcutTestCount: 0,
    } as Partial<React.ComponentProps<typeof Onboarding>>)

    expect(screen.getByText('Press ⌘ ⇧ Space once to test it.')).toBeVisible()
    expect(screen.queryByText('Shortcut test passed. It will start or stop listening after setup.')).not.toBeInTheDocument()

    const nextProps = { ...props, shortcutTestCount: 1 } as React.ComponentProps<typeof Onboarding>
    rerender(<I18nProvider><Onboarding {...nextProps} /></I18nProvider>)

    expect(screen.getByRole('status')).toHaveTextContent('Shortcut test passed. It will start or stop listening after setup.')
  })

  it('does not claim the shortcut works while the user is recording a replacement', async () => {
    const user = userEvent.setup()
    window.localStorage.setItem(ONBOARDING_DRAFT_STORAGE_KEY, JSON.stringify({
      version: 1,
      step: 4,
      furthestStep: 4,
      agentChoice: 'transcript',
      primary: null,
      secondary: null,
      testedProvider: null,
      transcriptionConfig: deepgramConfig,
      audioMode: 'both',
      listeningShortcut: 'CommandOrControl+Shift+Space',
    }))
    const { props, rerender } = renderOnboarding({ shortcutTestCount: 0 })
    rerender(
      <I18nProvider>
        <Onboarding {...props} shortcutTestCount={1} />
      </I18nProvider>,
    )

    expect(screen.getByText('Shortcut test passed. It will start or stop listening after setup.')).toBeVisible()
    await user.click(screen.getByRole('button', { name: 'Change listening shortcut' }))

    expect(screen.getByRole('button', { name: 'Cancel' })).toBeVisible()
    expect(screen.queryByText('Shortcut test passed. It will start or stop listening after setup.')).not.toBeInTheDocument()
  })

  it('checks system audio and microphone independently without asking for a meeting type', async () => {
    const user = userEvent.setup()
    const onTestAudio = vi.fn().mockImplementation(async (mode: AudioMode) => readyAudio(mode))
    renderOnboarding({
      deepgramCredential: { configured: true, verified: true, message: null },
      onTestAudio,
    })

    await continueToAgent(user)
    await chooseTranscriptOnly(user)
    await user.click(screen.getByRole('button', { name: 'Continue' }))

    expect(screen.queryByRole('radiogroup', { name: 'Meeting type' })).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Check system audio' }))

    expect(onTestAudio).toHaveBeenNthCalledWith(1, 'system')
    expect(await screen.findByText('System audio is ready')).toBeVisible()
    expect(document.querySelector('.onboarding-source-ready > i')).not.toBeInTheDocument()
    expect(screen.getByText('Say a few words near this Mac')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeDisabled()

    await user.click(screen.getByRole('button', { name: 'Check microphone' }))

    expect(onTestAudio).toHaveBeenNthCalledWith(2, 'mic')
    expect(screen.getByText('System audio is ready')).toBeVisible()
    expect(await screen.findByText('Microphone is ready')).toBeVisible()
    expect(screen.getByRole('status')).toHaveTextContent('Audio is ready. You can continue.')
    expect(screen.getByRole('button', { name: 'Continue' })).toBeEnabled()
  })

  it('counts down while checking and reports each failed source with a retry', async () => {
    const user = userEvent.setup()
    let resolveAudio!: (result: AudioSetupCheck) => void
    const onTestAudio = vi.fn().mockImplementation(() => new Promise<AudioSetupCheck>((resolve) => { resolveAudio = resolve }))
    renderOnboarding({
      deepgramCredential: { configured: true, verified: true, message: null },
      onTestAudio,
    })

    await continueToAgent(user)
    await chooseTranscriptOnly(user)
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    vi.useFakeTimers()
    fireEvent.click(screen.getByRole('button', { name: 'Check system audio' }))

    expect(screen.getByRole('button', { name: 'Listening… 3' })).toBeDisabled()
    expect(screen.getAllByText('Detecting…')).toHaveLength(1)
    expect(document.querySelector('.onboarding-source-detecting > i')).toBeInTheDocument()
    expect(screen.getByText('Say a few words near this Mac')).toBeVisible()
    act(() => vi.advanceTimersByTime(1000))
    expect(screen.getByRole('button', { name: 'Listening… 2' })).toBeDisabled()
    act(() => vi.advanceTimersByTime(2000))
    expect(screen.getByRole('button', { name: 'Starting…' })).toBeDisabled()

    await act(async () => resolveAudio({
      mode: 'system',
      success: false,
      system: { required: true, ready: false, level: 0, message: 'No system audio signal detected.' },
      microphone: { required: false, ready: false, level: 0, message: null },
    }))

    expect(screen.getByText('No system audio signal detected.')).toBeVisible()
    expect(screen.getByText('Say a few words near this Mac')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Check again' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'Check microphone' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeDisabled()
    vi.useRealTimers()
  })

  it('offers to reopen Arco when macOS permission changes require a restart', async () => {
    const user = userEvent.setup()
    const onRelaunch = vi.fn().mockResolvedValue(undefined)
    renderOnboarding({
      deepgramCredential: { configured: true, verified: true, message: null },
      onTestAudio: vi.fn().mockRejectedValue(new Error(
        'ARCO_AUDIO_PERMISSION_RESTART_REQUIRED: Screen Recording permission changed.',
      )),
      onRelaunch,
    })

    await continueToAgent(user)
    await chooseTranscriptOnly(user)
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('button', { name: 'Check system audio' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('macOS needs Arco to reopen')
    await user.click(screen.getByRole('button', { name: 'Reopen Arco and continue' }))
    expect(onRelaunch).toHaveBeenCalledTimes(1)
  })

  it('keeps a native string error on the source that was checked', async () => {
    const user = userEvent.setup()
    renderOnboarding({
      deepgramCredential: { configured: true, verified: true, message: null },
      onTestAudio: vi.fn().mockRejectedValue('System audio capture is unavailable.'),
    })

    await continueToAgent(user)
    await chooseTranscriptOnly(user)
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('button', { name: 'Check system audio' }))

    expect(await screen.findByText('System audio capture is unavailable.')).toBeVisible()
    expect(screen.getByText('Say a few words near this Mac')).toBeVisible()
  })

  it('finishes with the exact configuration and can start the first meeting immediately', async () => {
    const user = userEvent.setup()
    const { onComplete } = renderOnboarding({
      deepgramCredential: { configured: true, verified: true, message: null },
    })

    await continueToAgent(user)
    await chooseTranscriptOnly(user)
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('button', { name: 'Check system audio' }))
    await screen.findByText('System audio is ready')
    await user.click(screen.getByRole('button', { name: 'Check microphone' }))
    await screen.findByText('Microphone is ready')
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('button', { name: 'Continue' }))

    expect(screen.getByRole('heading', { name: 'Start your first meeting' })).toBeVisible()
    expect(screen.queryByText('Meeting type')).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Start listening' }))

    expect(onComplete).toHaveBeenCalledWith({
      providerConfig: { setupComplete: false, primary: null, secondary: null },
      transcriptionConfig: deepgramConfig,
      audioMode: 'both',
      startListening: true,
    })
  })
})
