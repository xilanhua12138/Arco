import {
  AudioWaveform,
  Check,
  ChevronLeft,
  ChevronRight,
  Cloud,
  Command,
  Download,
  HardDrive,
  Headphones,
  MessageSquareText,
  Mic,
  RefreshCw,
} from 'lucide-react'
import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { useI18n } from '../i18n/i18n'
import type { TranslationKey } from '../i18n/messages'
import {
  loadOnboardingDraft,
  saveOnboardingDraft,
  clearOnboardingDraft,
  type OnboardingDraft,
} from '../lib/onboarding'
import { createProviderConfig, type ProviderConfig } from '../lib/providerConfig'
import {
  diarizationModels,
  transcriptionModels as localModelDescriptors,
} from '../lib/transcriptionConfig'
import type {
  AudioMode,
  AudioSourceCheck,
  AudioSetupCheck,
  DeepgramCredentialStatus,
  LocalDiarizationModelId,
  LocalTranscriptionModelId,
  ProviderId,
  RuntimeStatus,
  TranscriptionConfig,
  TranscriptionLanguage,
  TranscriptionModelStatus,
} from '../types'
import { formatListeningShortcut, type ListeningShortcut } from '../lib/listeningShortcut'
import { ShortcutRecorder } from './ShortcutRecorder'
import './ProviderSetup.css'
import './Onboarding.css'

export interface OnboardingResult {
  providerConfig: ProviderConfig
  transcriptionConfig: TranscriptionConfig
  audioMode: AudioMode
  startListening: boolean
}

interface OnboardingProps {
  runtimes: RuntimeStatus[]
  transcriptionConfig: TranscriptionConfig
  transcriptionModels: TranscriptionModelStatus[]
  deepgramCredential: DeepgramCredentialStatus
  listeningShortcut: ListeningShortcut
  shortcutTestCount: number
  audioMode: AudioMode
  onRefreshRuntimes: () => Promise<RuntimeStatus[] | void> | RuntimeStatus[] | void
  onTestProvider: (provider: ProviderId) => Promise<boolean>
  onSaveDeepgramApiKey: (apiKey: string) => Promise<DeepgramCredentialStatus>
  onPrepareTranscriptionModel: (
    model: LocalTranscriptionModelId,
    diarizationModel?: LocalDiarizationModelId,
  ) => Promise<TranscriptionModelStatus[]>
  onTestAudio: (mode: AudioMode) => Promise<AudioSetupCheck>
  onRelaunch: () => void | Promise<void>
  onChangeListeningShortcut: (shortcut: ListeningShortcut) => boolean | Promise<boolean>
  onStartListeningShortcutRecording?: () => boolean | Promise<boolean>
  onCancelListeningShortcutRecording?: () => void | Promise<void>
  onComplete: (result: OnboardingResult) => void | Promise<void>
  onSkip: () => void
}

type AgentChoice = 'agent' | 'transcript'
type AsyncState = 'idle' | 'working' | 'passed' | 'failed'
type AudioSource = 'system' | 'microphone'

interface AudioSourceSetupState {
  state: AsyncState
  result: AudioSourceCheck | null
  error: string | null
  restartRequired: boolean
}

const providerIds: ProviderId[] = ['codex', 'claude']
const defaultLocalModel: LocalTranscriptionModelId = 'nemotron-speech-3.5-streaming'
const defaultDiarizationModel: LocalDiarizationModelId = 'sortformer-streaming'
const restartRequiredPrefix = 'ARCO_AUDIO_PERMISSION_RESTART_REQUIRED:'
const localModelDetailKeys: Record<LocalTranscriptionModelId, TranslationKey> = {
  'nemotron-speech-3.5-streaming': 'model.nemotron',
  'whisper-tiny': 'model.whisperTiny',
  'whisper-base': 'model.whisperBase',
  'whisper-small': 'model.whisperSmall',
  'whisper-medium': 'model.whisperMedium',
  'whisper-large': 'model.whisperLarge',
}

const providerName = (provider: ProviderId) => provider === 'codex' ? 'Codex' : 'Claude'
const runtimeName = (provider: ProviderId) => provider === 'codex' ? 'Codex CLI' : 'Claude Code'

const modelReady = (models: readonly TranscriptionModelStatus[], id: TranscriptionModelStatus['id']) =>
  models.some((model) => model.id === id && model.installed && model.phase === 'ready')

const modelStatus = (models: readonly TranscriptionModelStatus[], id: TranscriptionModelStatus['id']) =>
  models.find((model) => model.id === id)

const modelBusy = (status: TranscriptionModelStatus | undefined) => (
  status ? ['downloading', 'optimizing', 'loading'].includes(status.phase) : false
)

const emptyAudioSourceState = (): AudioSourceSetupState => ({
  state: 'idle',
  result: null,
  error: null,
  restartRequired: false,
})

export function Onboarding({
  runtimes,
  transcriptionConfig: initialTranscription,
  transcriptionModels,
  deepgramCredential,
  listeningShortcut,
  shortcutTestCount,
  onRefreshRuntimes,
  onTestProvider,
  onSaveDeepgramApiKey,
  onPrepareTranscriptionModel,
  onTestAudio,
  onRelaunch,
  onChangeListeningShortcut,
  onStartListeningShortcutRecording,
  onCancelListeningShortcutRecording,
  onComplete,
  onSkip,
}: OnboardingProps) {
  const { locale, setLocale, t } = useI18n()
  const [initialDraft] = useState(loadOnboardingDraft)
  const firstAvailable = providerIds.find((provider) => (
    runtimes.some((runtime) => runtime.provider === provider && runtime.available)
  )) ?? null
  const [step, setStep] = useState(initialDraft?.step ?? 0)
  const [furthestStep, setFurthestStep] = useState(initialDraft?.furthestStep ?? 0)
  const [agentChoice, setAgentChoice] = useState<AgentChoice>(initialDraft?.agentChoice ?? 'agent')
  const [selectedPrimary, setPrimary] = useState<ProviderId | null>(initialDraft?.primary ?? null)
  const [secondary, setSecondary] = useState<ProviderId | null>(initialDraft?.secondary ?? null)
  const [providerTest, setProviderTest] = useState<AsyncState>(() => {
    if (!initialDraft?.testedProvider || initialDraft.testedProvider !== initialDraft.primary) return 'idle'
    return runtimes.some((runtime) => runtime.provider === initialDraft.primary && runtime.available) ? 'passed' : 'idle'
  })
  const [testedProvider, setTestedProvider] = useState<ProviderId | null>(initialDraft?.testedProvider ?? null)
  const [refreshing, setRefreshing] = useState(false)
  const [transcription, setTranscription] = useState<TranscriptionConfig>(initialDraft?.transcriptionConfig ?? initialTranscription)
  const [modelsOverride, setModelsOverride] = useState<TranscriptionModelStatus[] | null>(null)
  const [credentialOverride, setCredentialOverride] = useState<DeepgramCredentialStatus | null>(null)
  const [apiKey, setApiKey] = useState('')
  const [transcriptionState, setTranscriptionState] = useState<AsyncState>('idle')
  const [transcriptionError, setTranscriptionError] = useState<string | null>(null)
  const [preparingModel, setPreparingModel] = useState<TranscriptionModelStatus['id'] | null>(null)
  const [modelErrors, setModelErrors] = useState<Partial<Record<TranscriptionModelStatus['id'], string>>>({})
  const audioMode: AudioMode = 'both'
  const [audioChecks, setAudioChecks] = useState<Record<AudioSource, AudioSourceSetupState>>(() => ({
    system: emptyAudioSourceState(),
    microphone: emptyAudioSourceState(),
  }))
  const [workingAudioSource, setWorkingAudioSource] = useState<AudioSource | null>(null)
  const [audioCountdown, setAudioCountdown] = useState(3)
  const [shortcut, setShortcut] = useState(initialDraft?.listeningShortcut ?? listeningShortcut)
  const [shortcutTestBaseline, setShortcutTestBaseline] = useState(shortcutTestCount)
  const [shortcutRecording, setShortcutRecording] = useState(false)
  const [finishing, setFinishing] = useState(false)

  const primary = selectedPrimary ?? firstAvailable
  const models = modelsOverride ?? transcriptionModels
  const credential = credentialOverride ?? deepgramCredential
  const selectedLocalModel: LocalTranscriptionModelId = transcription.provider === 'local'
    ? transcription.model as LocalTranscriptionModelId
    : defaultLocalModel
  const selectedDiarizationModel: LocalDiarizationModelId = transcription.provider === 'local'
    && transcription.diarization !== 'none'
    && transcription.diarization !== 'provider'
    ? transcription.diarization as LocalDiarizationModelId
    : defaultDiarizationModel
  const selectedLocalStatus = modelStatus(models, selectedLocalModel)
  const selectedDiarizationStatus = modelStatus(models, selectedDiarizationModel)

  const steps = [
    t('onboarding.step.welcome'),
    t('onboarding.step.agent'),
    t('onboarding.step.transcription'),
    t('onboarding.step.audio'),
    t('onboarding.step.shortcut'),
    t('onboarding.step.firstMeeting'),
  ]

  const runtimeFor = (provider: ProviderId) => runtimes.find((runtime) => runtime.provider === provider)
  const providerReady = agentChoice === 'transcript'
    || (primary !== null && providerTest === 'passed' && testedProvider === primary)
  const localReady = modelReady(models, selectedLocalModel) && modelReady(models, selectedDiarizationModel)
  const transcriptionReady = transcription.provider === 'deepgram'
    ? credential.configured && credential.verified
    : localReady
  const audioReady = (['system', 'microphone'] as const).every((source) => (
    audioChecks[source].state === 'passed' && audioChecks[source].result?.ready
  ))
  const canContinue = [true, providerReady, transcriptionReady, audioReady, true, false][step]

  const onboardingDraft = useMemo<OnboardingDraft>(() => ({
    version: 1,
    step: Math.max(1, Math.min(5, step)) as OnboardingDraft['step'],
    furthestStep: Math.max(1, Math.min(5, furthestStep)) as OnboardingDraft['furthestStep'],
    agentChoice,
    primary,
    secondary,
    testedProvider: providerTest === 'passed' ? testedProvider : null,
    transcriptionConfig: transcription,
    audioMode,
    listeningShortcut: shortcut,
  }), [agentChoice, audioMode, furthestStep, primary, providerTest, secondary, shortcut, step, testedProvider, transcription])

  useEffect(() => {
    if (step === 0) return
    saveOnboardingDraft(onboardingDraft)
  }, [onboardingDraft, step])

  useEffect(() => {
    if (workingAudioSource === null) return
    setAudioCountdown(3)
    const timer = window.setInterval(() => {
      setAudioCountdown((current) => Math.max(0, current - 1))
    }, 1000)
    return () => window.clearInterval(timer)
  }, [workingAudioSource])

  const progressSummary = useMemo(() => ({
    agent: agentChoice === 'transcript' ? t('onboarding.transcriptOnly') : primary ? providerName(primary) : t('common.notSet'),
    transcription: transcription.provider === 'deepgram' ? 'Deepgram' : t('onboarding.onThisMac'),
  }), [agentChoice, primary, t, transcription.provider])

  const reveal = (next: number) => {
    setFurthestStep((current) => Math.max(current, next))
    if (next === 4) setShortcutTestBaseline(shortcutTestCount)
    setStep(next)
  }

  const moveTo = (next: number) => {
    if (next <= furthestStep) setStep(next)
  }

  const selectPrimary = (provider: ProviderId) => {
    if (!runtimeFor(provider)?.available) return
    setPrimary(provider)
    if (secondary === provider) setSecondary(null)
    setProviderTest('idle')
    setTestedProvider(null)
  }

  const testProvider = async () => {
    if (!primary || providerTest === 'working') return
    setProviderTest('working')
    setTestedProvider(primary)
    try {
      setProviderTest(await onTestProvider(primary) ? 'passed' : 'failed')
    } catch {
      setProviderTest('failed')
    }
  }

  const refreshRuntimes = async () => {
    if (refreshing) return
    setRefreshing(true)
    try {
      const next = await onRefreshRuntimes()
      const source = next ?? runtimes
      const available = primary && source.some((runtime) => runtime.provider === primary && runtime.available)
      if (!available) {
        const fallback = providerIds.find((provider) => source.some((runtime) => runtime.provider === provider && runtime.available)) ?? null
        setPrimary(fallback)
        setSecondary(null)
        setAgentChoice(fallback ? 'agent' : 'transcript')
      }
      setProviderTest('idle')
      setTestedProvider(null)
    } finally {
      setRefreshing(false)
    }
  }

  const changeProvider = (provider: 'deepgram' | 'local') => {
    setTranscriptionError(null)
    setTranscriptionState('idle')
    setTranscription(provider === 'deepgram'
      ? { provider: 'deepgram', model: 'nova-3', language: transcription.language, diarization: 'provider' }
      : {
          provider: 'local',
          model: selectedLocalModel,
          language: transcription.language,
          diarization: selectedDiarizationModel,
        })
  }

  const changeLanguage = (language: TranscriptionLanguage) => {
    setTranscription((current) => ({ ...current, language }))
  }

  const saveDeepgram = async () => {
    if (!apiKey.trim() || transcriptionState === 'working') return
    setTranscriptionState('working')
    setTranscriptionError(null)
    try {
      const next = await onSaveDeepgramApiKey(apiKey.trim())
      setCredentialOverride(next)
      setApiKey('')
      setTranscriptionState(next.configured && next.verified ? 'passed' : 'failed')
    } catch (cause) {
      setTranscriptionState('failed')
      setTranscriptionError(cause instanceof Error ? cause.message : t('onboarding.deepgramFailed'))
    }
  }

  const changeLocalModel = (model: LocalTranscriptionModelId) => {
    setTranscription((current) => ({
      provider: 'local',
      model,
      language: current.language,
      diarization: current.provider === 'local' && current.diarization !== 'none'
        ? current.diarization
        : defaultDiarizationModel,
    }))
    setTranscriptionError(null)
  }

  const changeDiarizationModel = (diarization: LocalDiarizationModelId) => {
    setTranscription((current) => ({
      provider: 'local',
      model: current.provider === 'local' ? current.model : defaultLocalModel,
      language: current.language,
      diarization,
    }))
    setTranscriptionError(null)
  }

  const prepareLocalModel = async (target: LocalTranscriptionModelId | LocalDiarizationModelId) => {
    if (preparingModel || modelBusy(modelStatus(models, target))) return
    setPreparingModel(target)
    setModelErrors((current) => ({ ...current, [target]: undefined }))
    try {
      const next = target === selectedLocalModel
        ? await onPrepareTranscriptionModel(selectedLocalModel)
        : await onPrepareTranscriptionModel(selectedLocalModel, target as LocalDiarizationModelId)
      setModelsOverride(next)
      const status = modelStatus(next, target)
      if (!status?.installed || status.phase !== 'ready') {
        setModelErrors((current) => ({
          ...current,
          [target]: status?.error ?? t('onboarding.localFailed'),
        }))
      }
    } catch (cause) {
      setModelErrors((current) => ({
        ...current,
        [target]: cause instanceof Error ? cause.message : t('onboarding.localFailed'),
      }))
    } finally {
      setPreparingModel(null)
    }
  }

  const runAudioCheck = async (source: AudioSource) => {
    if (workingAudioSource !== null) return
    const mode: AudioMode = source === 'system' ? 'system' : 'mic'
    setWorkingAudioSource(source)
    setAudioChecks((current) => ({
      ...current,
      [source]: { ...emptyAudioSourceState(), state: 'working' },
    }))
    try {
      const result = await onTestAudio(mode)
      const sourceResult = result[source]
      setAudioChecks((current) => ({
        ...current,
        [source]: {
          state: sourceResult.ready ? 'passed' : 'failed',
          result: sourceResult,
          error: null,
          restartRequired: false,
        },
      }))
    } catch (cause) {
      const nativeMessage = cause instanceof Error ? cause.message : typeof cause === 'string' ? cause : ''
      const message = nativeMessage.trim()
        || (source === 'system' ? t('onboarding.systemNotDetected') : t('onboarding.micNotDetected'))
      const restartRequired = source === 'system' && message.startsWith(restartRequiredPrefix)
      setAudioChecks((current) => ({
        ...current,
        [source]: {
          state: 'failed',
          result: null,
          error: restartRequired ? message.slice(restartRequiredPrefix.length).trim() : message,
          restartRequired,
        },
      }))
    } finally {
      setWorkingAudioSource(null)
    }
  }

  const relaunch = async () => {
    saveOnboardingDraft(onboardingDraft)
    await onRelaunch()
  }

  const skip = () => {
    clearOnboardingDraft()
    onSkip()
  }

  const changeShortcut = async (next: ListeningShortcut) => {
    const changed = await onChangeListeningShortcut(next)
    if (changed) {
      setShortcut(next)
      setShortcutTestBaseline(shortcutTestCount)
    }
    return changed
  }

  const complete = async (startListening: boolean) => {
    if (finishing) return
    setFinishing(true)
    try {
      const providerConfig = agentChoice === 'agent'
        ? createProviderConfig(primary, secondary, runtimes)
        : { setupComplete: false, primary: null, secondary: null } satisfies ProviderConfig
      await onComplete({ providerConfig, transcriptionConfig: transcription, audioMode, startListening })
    } finally {
      setFinishing(false)
    }
  }

  const modelActionLabel = (
    id: TranscriptionModelStatus['id'],
    status: TranscriptionModelStatus | undefined,
    idleLabel: string,
  ) => {
    if (status?.phase === 'downloading') return `${Math.round((status.progress ?? 0) * 100)}%`
    if (status?.phase === 'optimizing') return t('common.optimizing')
    if (status?.phase === 'loading') return t('common.loading')
    if (preparingModel === id) return t('onboarding.downloading')
    return idleLabel
  }

  const renderAudioSource = (
    source: AudioSource,
    icon: ReactNode,
    title: string,
  ) => {
    const check = audioChecks[source]
    const result = check.result
    const isDetecting = workingAudioSource === source
    const isStarting = isDetecting && audioCountdown === 0
    const isReady = check.state === 'passed' && result?.ready === true
    const isFailed = check.state === 'failed'
    const description = isDetecting
      ? isStarting ? t('common.starting') : t('onboarding.detecting')
      : isReady
        ? source === 'system' ? t('onboarding.systemReady') : t('onboarding.micReady')
        : isFailed
          ? check.error || result?.message || (source === 'system' ? t('onboarding.systemNotDetected') : t('onboarding.micNotDetected'))
          : source === 'system' ? t('onboarding.playSomething') : t('onboarding.saySomething')
    const idleLabel = source === 'system' ? t('onboarding.checkSystemAudio') : t('onboarding.checkMicrophone')
    const buttonLabel = isDetecting
      ? isStarting ? t('common.starting') : t('onboarding.listeningCountdown', { seconds: audioCountdown })
      : check.state === 'idle' ? idleLabel : t('onboarding.checkAgain')
    return (
      <div className={isDetecting ? 'onboarding-source-detecting' : isReady ? 'onboarding-source-ready' : isFailed ? 'onboarding-source-failed' : ''}>
        {icon}
        <span><strong>{title}</strong><small>{description}</small></span>
        {isReady && <Check className="onboarding-source-check" size={16} aria-hidden="true" />}
        {isDetecting && <i className="onboarding-level-detecting" aria-hidden="true" />}
        <button type="button" className="onboarding-audio-test" onClick={() => runAudioCheck(source)} disabled={workingAudioSource !== null}>
          <AudioWaveform size={15} /> {buttonLabel}
        </button>
      </div>
    )
  }

  const languagePicker = (
    <label className="provider-setup-language onboarding-language-picker">
      <span className="sr-only">{t('settings.appLanguage')}</span>
      <select aria-label={t('settings.appLanguage')} value={locale} onChange={(event) => setLocale(event.target.value as 'en' | 'zh-CN')}>
        <option value="zh-CN">简体中文</option>
        <option value="en">English</option>
      </select>
    </label>
  )

  if (step === 0) {
    return (
      <main className="onboarding-page onboarding-landing" aria-labelledby="onboarding-welcome-heading">
        <header className="onboarding-landing-bar" data-tauri-drag-region>
          <div className="onboarding-brand"><img src="/arco-icon.png" alt="" draggable={false} /> Arco</div>
          <div className="onboarding-landing-tools">
            {languagePicker}
            <button type="button" className="onboarding-text-button" onClick={skip}>{t('onboarding.setUpLater')}</button>
          </div>
        </header>

        <section className="onboarding-landing-hero">
          <div className="onboarding-landing-copy">
            <span className="onboarding-eyebrow"><AudioWaveform size={16} /> {t('onboarding.welcome')}</span>
            <h1 id="onboarding-welcome-heading">{t('onboarding.stayInConversation')}</h1>
            <p>{t('onboarding.completeIntro')}</p>
            <button type="button" className="onboarding-primary-cta" onClick={() => reveal(1)}>
              {t('common.continue')} <ChevronRight size={17} />
            </button>
            <span className="onboarding-time"><Check size={14} /> {t('onboarding.timeEstimate')}</span>
          </div>

          <div className="onboarding-landing-preview" aria-hidden="true">
            <div className="onboarding-preview-glow" />
            <div className="onboarding-preview-window">
              <div className="onboarding-preview-title"><span /> {t('common.untitledMeeting')}</div>
              <div className="onboarding-preview-columns">
                <div className="onboarding-preview-transcript">
                  <i /><i /><i /><i />
                </div>
                <div className="onboarding-preview-agent">
                  <AudioWaveform size={18} />
                  <strong>Arco</strong>
                  <i /><i />
                </div>
              </div>
            </div>
          </div>
        </section>
      </main>
    )
  }

  return (
    <main className="onboarding-page onboarding-wizard" aria-label={steps[step]}>
      <aside className="onboarding-progress" aria-label={t('onboarding.progress')}>
        <div className="onboarding-brand"><img src="/arco-icon.png" alt="" draggable={false} /> Arco</div>
        <ol>
          {steps.slice(1).map((label, wizardIndex) => {
            const index = wizardIndex + 1
            return (
              <li key={label}>
                <button
                  type="button"
                  aria-label={label}
                  aria-current={index === step ? 'step' : undefined}
                  disabled={index > furthestStep}
                  onClick={() => moveTo(index)}
                >
                  <span aria-hidden="true">{index < step ? <Check size={13} /> : wizardIndex + 1}</span>
                  {label}
                </button>
              </li>
            )
          })}
        </ol>
        <button type="button" className="onboarding-skip-rail" onClick={skip}>{t('onboarding.setUpLater')}</button>
      </aside>

      <section className="onboarding-main">
        <header className="onboarding-header" data-tauri-drag-region>
          <button type="button" className="onboarding-back-top" onClick={() => setStep((current) => current - 1)}>
            <ChevronLeft size={16} /> {t('common.back')}
          </button>
          {languagePicker}
        </header>

        <div className="onboarding-content" key={step}>

            {step === 1 && (
              <section aria-labelledby="onboarding-agent-heading">
                <div className="onboarding-heading-row">
                  <div><h2 id="onboarding-agent-heading">{t('onboarding.yourAgent')}</h2><p>{t('onboarding.agentHelp')}</p></div>
                  <button type="button" className="provider-refresh-button" onClick={refreshRuntimes} disabled={refreshing}>
                    <RefreshCw size={14} className={refreshing ? 'provider-test-spinning' : ''} /> {t('onboarding.recheck')}
                  </button>
                </div>
                <div className="onboarding-choice-list onboarding-agent-choice">
                  <label className={agentChoice === 'agent' ? 'onboarding-choice-selected' : ''}>
                    <input type="radio" name="agent-choice" aria-label={t('onboarding.useAgent')} checked={agentChoice === 'agent'} disabled={!firstAvailable} onChange={() => setAgentChoice('agent')} />
                    <MessageSquareText size={19} /><span><strong>{t('onboarding.useAgent')}</strong><small>{t('onboarding.useAgentHelp')}</small></span>
                  </label>
                  <label className={agentChoice === 'transcript' ? 'onboarding-choice-selected' : ''}>
                    <input type="radio" name="agent-choice" aria-label={t('onboarding.withoutAgent')} checked={agentChoice === 'transcript'} onChange={() => setAgentChoice('transcript')} />
                    <AudioWaveform size={19} /><span><strong>{t('onboarding.withoutAgent')}</strong><small>{t('onboarding.withoutAgentHelp')}</small></span>
                  </label>
                </div>
                {agentChoice === 'agent' && (
                  <div className="onboarding-agent-config">
                    <div className="onboarding-provider-row">
                      {providerIds.map((provider) => {
                        const runtime = runtimeFor(provider)
                        return (
                          <label key={provider} className={primary === provider ? 'onboarding-provider-selected' : ''}>
                            <input type="radio" name="primary-provider" aria-label={`${providerName(provider)} as primary`} checked={primary === provider} disabled={!runtime?.available} onChange={() => selectPrimary(provider)} />
                            <span><strong>{runtimeName(provider)}</strong><small>{runtime?.available ? runtime.version : t('common.notDetected')}</small></span>
                            <em>{runtime?.available ? t('common.installed') : t('common.missing')}</em>
                          </label>
                        )
                      })}
                    </div>
                    <div className="onboarding-provider-test-row">
                      <button type="button" className="provider-test-button" disabled={!primary || providerTest === 'working'} onClick={testProvider}>
                        <RefreshCw size={15} className={providerTest === 'working' ? 'provider-test-spinning' : ''} />
                        {providerTest === 'working' ? t('onboarding.testing') : t('onboarding.testProvider', { provider: primary ? providerName(primary) : t('onboarding.connection') })}
                      </button>
                      {providerTest === 'passed' && <span className="onboarding-inline-success"><Check size={14} /> {t('onboarding.providerReady', { provider: primary ? providerName(primary) : '' })}</span>}
                      {providerTest === 'failed' && <span className="onboarding-inline-error" role="alert">{t('onboarding.providerFailed', { provider: primary ? providerName(primary) : t('onboarding.theProvider') })}</span>}
                    </div>
                    <label className="onboarding-secondary-select">
                      <span>{t('onboarding.secondary')} · {t('common.optional')}</span>
                      <select value={secondary ?? ''} onChange={(event) => setSecondary((event.target.value || null) as ProviderId | null)}>
                        <option value="">{t('common.none')}</option>
                        {providerIds.filter((provider) => provider !== primary && runtimeFor(provider)?.available).map((provider) => <option key={provider} value={provider}>{providerName(provider)}</option>)}
                      </select>
                    </label>
                  </div>
                )}
              </section>
            )}

            {step === 2 && (
              <section aria-labelledby="onboarding-transcription-heading">
                <h2 id="onboarding-transcription-heading">{t('onboarding.chooseTranscription')}</h2>
                <p className="onboarding-lede">{t('onboarding.transcriptionHelp')}</p>
                <div className="onboarding-choice-list onboarding-transcription-choice">
                  <label className={transcription.provider === 'deepgram' ? 'onboarding-choice-selected' : ''}>
                    <input type="radio" name="transcription-provider" aria-label="Deepgram" checked={transcription.provider === 'deepgram'} onChange={() => changeProvider('deepgram')} />
                    <Cloud size={19} /><span><strong>Deepgram</strong><small>{t('onboarding.deepgramHelp')}</small></span>
                  </label>
                  <label className={transcription.provider === 'local' ? 'onboarding-choice-selected' : ''}>
                    <input type="radio" name="transcription-provider" aria-label={t('onboarding.onThisMac')} checked={transcription.provider === 'local'} onChange={() => changeProvider('local')} />
                    <HardDrive size={19} /><span><strong>{t('onboarding.onThisMac')}</strong><small>{t('onboarding.localHelp')}</small></span>
                  </label>
                </div>
                <label className="onboarding-language-field"><span>{t('settings.language')}</span><select value={transcription.language} onChange={(event) => changeLanguage(event.target.value as TranscriptionLanguage)}><option value="zh-CN">简体中文</option><option value="en-US">English</option><option value="auto">{t('common.automatic')}</option></select></label>
                {transcription.provider === 'deepgram' ? (
                  <div className="onboarding-transcription-action">
                    {credential.configured && credential.verified ? (
                      <span className="onboarding-ready-line"><Check size={15} /> {t('onboarding.deepgramReady')}</span>
                    ) : (
                      <><label><span>{t('onboarding.deepgramKey')}</span><input type="password" aria-label={t('onboarding.deepgramKey')} value={apiKey} placeholder="dg_…" onChange={(event) => setApiKey(event.target.value)} /></label><button type="button" onClick={saveDeepgram} disabled={!apiKey.trim() || transcriptionState === 'working'}>{transcriptionState === 'working' ? t('settings.verifying') : t('settings.verifyAndSave')}</button></>
                    )}
                  </div>
                ) : (
                  <div className="onboarding-local-models">
                    <div className="onboarding-model-setup-row">
                      <label>
                        <span>{t('onboarding.speechModel')}</span>
                        <select aria-label={t('onboarding.speechModel')} value={selectedLocalModel} onChange={(event) => changeLocalModel(event.target.value as LocalTranscriptionModelId)}>
                          {localModelDescriptors.map((model) => <option key={model.id} value={model.id}>{model.label} · {model.downloadSize}</option>)}
                        </select>
                        <small>{t(localModelDetailKeys[selectedLocalModel])}</small>
                        {(modelErrors[selectedLocalModel] || selectedLocalStatus?.error) && <em role="alert">{modelErrors[selectedLocalModel] || selectedLocalStatus?.error}</em>}
                      </label>
                      {modelReady(models, selectedLocalModel) ? (
                        <span className="onboarding-ready-line"><Check size={15} /> {t('onboarding.readyOnMac')}</span>
                      ) : (
                        <button type="button" onClick={() => prepareLocalModel(selectedLocalModel)} disabled={Boolean(preparingModel) || modelBusy(selectedLocalStatus)}>
                          <Download size={14} /> {modelActionLabel(selectedLocalModel, selectedLocalStatus, t('onboarding.downloadSpeechModel'))}
                        </button>
                      )}
                    </div>
                    <div className="onboarding-model-setup-row">
                      <label>
                        <span>{t('onboarding.speakerModel')}</span>
                        <select aria-label={t('onboarding.speakerModel')} value={selectedDiarizationModel} onChange={(event) => changeDiarizationModel(event.target.value as LocalDiarizationModelId)}>
                          {diarizationModels.map((model) => <option key={model.id} value={model.id}>{model.label}</option>)}
                        </select>
                        <small>{t(diarizationModels.find((model) => model.id === selectedDiarizationModel)?.detailKey ?? 'settings.sortformerDescription')}</small>
                        {(modelErrors[selectedDiarizationModel] || selectedDiarizationStatus?.error) && <em role="alert">{modelErrors[selectedDiarizationModel] || selectedDiarizationStatus?.error}</em>}
                      </label>
                      {modelReady(models, selectedDiarizationModel) ? (
                        <span className="onboarding-ready-line"><Check size={15} /> {t('onboarding.readyOnMac')}</span>
                      ) : (
                        <button type="button" onClick={() => prepareLocalModel(selectedDiarizationModel)} disabled={Boolean(preparingModel) || modelBusy(selectedDiarizationStatus) || !modelReady(models, selectedLocalModel)}>
                          <Download size={14} /> {modelActionLabel(selectedDiarizationModel, selectedDiarizationStatus, t('onboarding.downloadSpeakerModel'))}
                        </button>
                      )}
                    </div>
                  </div>
                )}
                {transcriptionError && <p className="onboarding-inline-error" role="alert">{transcriptionError}</p>}
              </section>
            )}

            {step === 3 && (
              <section aria-labelledby="onboarding-audio-heading">
                <h2 id="onboarding-audio-heading">{t('onboarding.checkAudio')}</h2>
                <p className="onboarding-lede">{t('onboarding.audioHelp')}</p>
                <div className="onboarding-audio-sources">
                  {renderAudioSource('system', <Headphones size={18} />, t('settings.systemAudio'))}
                  {renderAudioSource('microphone', <Mic size={18} />, t('onboarding.microphone'))}
                </div>
                {audioReady && <p className="onboarding-audio-summary onboarding-audio-summary-ready" role="status"><Check size={15} /> {t('onboarding.audioReadySummary')}</p>}
                {audioChecks.system.restartRequired ? (
                  <div className="onboarding-restart-callout" role="alert">
                    <strong>{t('onboarding.restartRequiredTitle')}</strong>
                    <p>{t('onboarding.restartRequiredHelp')}</p>
                    <button type="button" onClick={relaunch}><RefreshCw size={14} /> {t('onboarding.reopenAndContinue')}</button>
                  </div>
                ) : null}
              </section>
            )}

            {step === 4 && (
              <section className="provider-shortcut onboarding-shortcut" aria-labelledby="onboarding-shortcut-heading">
                <Command size={30} strokeWidth={1.5} aria-hidden="true" />
                <h2 id="onboarding-shortcut-heading">{t('onboarding.startAnywhere')}</h2>
                <p>{t('onboarding.shortcutHelp')}</p>
                <ShortcutRecorder
                  value={shortcut}
                  onChange={changeShortcut}
                  onStartRecording={onStartListeningShortcutRecording}
                  onCancelRecording={onCancelListeningShortcutRecording}
                  onRecordingChange={(recording) => {
                    setShortcutRecording(recording)
                    if (recording) setShortcutTestBaseline(shortcutTestCount)
                  }}
                />
                {!shortcutRecording && shortcut && (
                  <div
                    className={`onboarding-shortcut-feedback ${shortcutTestCount > shortcutTestBaseline ? 'onboarding-shortcut-feedback-ready' : ''}`}
                    role={shortcutTestCount > shortcutTestBaseline ? 'status' : undefined}
                  >
                    {shortcutTestCount > shortcutTestBaseline && <Check size={14} aria-hidden="true" />}
                    {t(
                      shortcutTestCount > shortcutTestBaseline
                        ? 'onboarding.shortcutTestPassed'
                        : 'onboarding.shortcutTestHelp',
                      { shortcut: formatListeningShortcut(shortcut) },
                    )}
                  </div>
                )}
                {!shortcutRecording && !shortcut && (
                  <div className="onboarding-shortcut-feedback">{t('onboarding.shortcutDisabled')}</div>
                )}
                <small>{t('onboarding.shortcutSettings')}</small>
              </section>
            )}

            {step === 5 && (
              <section className="onboarding-complete" aria-labelledby="onboarding-complete-heading">
                <span className="provider-complete-check" aria-hidden="true"><Check size={24} /></span>
                <h2 id="onboarding-complete-heading">{t('onboarding.startFirstMeeting')}</h2>
                <p>{t('onboarding.firstMeetingHelp')}</p>
                <dl><div><dt>{t('onboarding.step.agent')}</dt><dd>{progressSummary.agent}</dd></div><div><dt>{t('onboarding.step.transcription')}</dt><dd>{progressSummary.transcription}</dd></div><div><dt>{t('onboarding.step.shortcut')}</dt><dd>{formatListeningShortcut(shortcut)}</dd></div></dl>
                <div className="onboarding-complete-actions"><button type="button" className="onboarding-start" onClick={() => complete(true)} disabled={finishing}>{t('onboarding.startListening')}</button><button type="button" className="onboarding-open" onClick={() => complete(false)} disabled={finishing}>{t('onboarding.openArco')}</button></div>
              </section>
            )}
          {step < 5 && (
            <footer className="onboarding-actions">
              <div />
              <button type="button" className="provider-setup-next" disabled={!canContinue} onClick={() => reveal(step + 1)}>{t('common.continue')} <ChevronRight size={16} /></button>
            </footer>
          )}
        </div>
      </section>
    </main>
  )
}
