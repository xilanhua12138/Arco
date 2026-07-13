import {
  AudioWaveform,
  Check,
  ChevronLeft,
  ChevronRight,
  Cloud,
  Command,
  HardDrive,
  Headphones,
  MessageSquareText,
  Mic,
  RefreshCw,
} from 'lucide-react'
import { useMemo, useState, type CSSProperties } from 'react'
import { useI18n } from '../i18n/i18n'
import { createProviderConfig, type ProviderConfig } from '../lib/providerConfig'
import { localModelDescriptor } from '../lib/transcriptionConfig'
import type {
  AudioMode,
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
  audioMode: AudioMode
  onRefreshRuntimes: () => Promise<RuntimeStatus[] | void> | RuntimeStatus[] | void
  onTestProvider: (provider: ProviderId) => Promise<boolean>
  onSaveDeepgramApiKey: (apiKey: string) => Promise<DeepgramCredentialStatus>
  onPrepareTranscriptionModel: (
    model: LocalTranscriptionModelId,
    diarizationModel: LocalDiarizationModelId,
  ) => Promise<TranscriptionModelStatus[]>
  onTestAudio: (mode: AudioMode) => Promise<AudioSetupCheck>
  onChangeListeningShortcut: (shortcut: ListeningShortcut) => boolean | Promise<boolean>
  onComplete: (result: OnboardingResult) => void | Promise<void>
  onSkip: () => void
}

type AgentChoice = 'agent' | 'transcript'
type AsyncState = 'idle' | 'working' | 'passed' | 'failed'

const providerIds: ProviderId[] = ['codex', 'claude']
const localModel: LocalTranscriptionModelId = 'nemotron-speech-3.5-streaming'

const providerName = (provider: ProviderId) => provider === 'codex' ? 'Codex' : 'Claude'
const runtimeName = (provider: ProviderId) => provider === 'codex' ? 'Codex CLI' : 'Claude Code'

const modelReady = (models: readonly TranscriptionModelStatus[], id: TranscriptionModelStatus['id']) =>
  models.some((model) => model.id === id && model.installed && model.phase === 'ready')

export function Onboarding({
  runtimes,
  transcriptionConfig: initialTranscription,
  transcriptionModels,
  deepgramCredential,
  listeningShortcut,
  audioMode: initialAudioMode,
  onRefreshRuntimes,
  onTestProvider,
  onSaveDeepgramApiKey,
  onPrepareTranscriptionModel,
  onTestAudio,
  onChangeListeningShortcut,
  onComplete,
  onSkip,
}: OnboardingProps) {
  const { locale, setLocale, t } = useI18n()
  const firstAvailable = providerIds.find((provider) => (
    runtimes.some((runtime) => runtime.provider === provider && runtime.available)
  )) ?? null
  const [step, setStep] = useState(0)
  const [furthestStep, setFurthestStep] = useState(0)
  const [agentChoice, setAgentChoice] = useState<AgentChoice>('agent')
  const [selectedPrimary, setPrimary] = useState<ProviderId | null>(null)
  const [secondary, setSecondary] = useState<ProviderId | null>(null)
  const [providerTest, setProviderTest] = useState<AsyncState>('idle')
  const [testedProvider, setTestedProvider] = useState<ProviderId | null>(null)
  const [refreshing, setRefreshing] = useState(false)
  const [transcription, setTranscription] = useState<TranscriptionConfig>(initialTranscription)
  const [modelsOverride, setModelsOverride] = useState<TranscriptionModelStatus[] | null>(null)
  const [credentialOverride, setCredentialOverride] = useState<DeepgramCredentialStatus | null>(null)
  const [apiKey, setApiKey] = useState('')
  const [transcriptionState, setTranscriptionState] = useState<AsyncState>('idle')
  const [transcriptionError, setTranscriptionError] = useState<string | null>(null)
  const [audioMode, setAudioMode] = useState(initialAudioMode)
  const [audioState, setAudioState] = useState<AsyncState>('idle')
  const [audioResult, setAudioResult] = useState<AudioSetupCheck | null>(null)
  const [audioError, setAudioError] = useState<string | null>(null)
  const [shortcut, setShortcut] = useState(listeningShortcut)
  const [finishing, setFinishing] = useState(false)

  const primary = selectedPrimary ?? firstAvailable
  const models = modelsOverride ?? transcriptionModels
  const credential = credentialOverride ?? deepgramCredential

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
  const localReady = modelReady(models, localModel) && modelReady(models, 'sortformer-streaming')
  const transcriptionReady = transcription.provider === 'deepgram'
    ? credential.configured && credential.verified
    : localReady
  const audioReady = audioState === 'passed' && audioResult?.mode === audioMode && audioResult.success
  const canContinue = [true, providerReady, transcriptionReady, audioReady, true, false][step]

  const progressSummary = useMemo(() => ({
    agent: agentChoice === 'transcript' ? t('onboarding.transcriptOnly') : primary ? providerName(primary) : t('common.notSet'),
    transcription: transcription.provider === 'deepgram' ? 'Deepgram' : t('onboarding.onThisMac'),
    audio: audioMode === 'both'
      ? t('settings.scenario.hybrid.title')
      : audioMode === 'system'
        ? t('settings.scenario.online.title')
        : t('settings.scenario.room.title'),
  }), [agentChoice, audioMode, primary, t, transcription.provider])

  const reveal = (next: number) => {
    setFurthestStep((current) => Math.max(current, next))
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
      : { provider: 'local', model: localModel, language: transcription.language, diarization: 'sortformer-streaming' })
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

  const prepareLocal = async () => {
    if (transcriptionState === 'working') return
    setTranscriptionState('working')
    setTranscriptionError(null)
    try {
      const next = await onPrepareTranscriptionModel(localModel, 'sortformer-streaming')
      setModelsOverride(next)
      setTranscriptionState(
        modelReady(next, localModel) && modelReady(next, 'sortformer-streaming') ? 'passed' : 'failed',
      )
    } catch (cause) {
      setTranscriptionState('failed')
      setTranscriptionError(cause instanceof Error ? cause.message : t('onboarding.localFailed'))
    }
  }

  const runAudioCheck = async () => {
    if (audioState === 'working') return
    setAudioState('working')
    setAudioResult(null)
    setAudioError(null)
    try {
      const result = await onTestAudio(audioMode)
      setAudioResult(result)
      setAudioState(result.success ? 'passed' : 'failed')
    } catch (cause) {
      setAudioState('failed')
      setAudioError(cause instanceof Error ? cause.message : t('onboarding.audioFailed'))
    }
  }

  const changeShortcut = async (next: ListeningShortcut) => {
    const changed = await onChangeListeningShortcut(next)
    if (changed) setShortcut(next)
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
        <header className="onboarding-landing-bar">
          <div className="onboarding-brand"><img src="/arco-icon.png" alt="" draggable={false} /> Arco</div>
          <div className="onboarding-landing-tools">
            {languagePicker}
            <button type="button" className="onboarding-text-button" onClick={onSkip}>{t('onboarding.setUpLater')}</button>
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
        <button type="button" className="onboarding-skip-rail" onClick={onSkip}>{t('onboarding.setUpLater')}</button>
      </aside>

      <section className="onboarding-main">
        <header className="onboarding-header">
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
                  <div className="onboarding-transcription-action onboarding-local-action">
                    <div><strong>{localModelDescriptor(localModel)?.label}</strong><small>{localModelDescriptor(localModel)?.downloadSize} · {t('onboarding.speakerSeparationIncluded')}</small></div>
                    {localReady ? <span className="onboarding-ready-line"><Check size={15} /> {t('onboarding.readyOnMac')}</span> : <button type="button" onClick={prepareLocal} disabled={transcriptionState === 'working'}>{transcriptionState === 'working' ? t('onboarding.downloading') : t('settings.downloadAndUse')}</button>}
                  </div>
                )}
                {transcriptionError && <p className="onboarding-inline-error" role="alert">{transcriptionError}</p>}
              </section>
            )}

            {step === 3 && (
              <section aria-labelledby="onboarding-audio-heading">
                <h2 id="onboarding-audio-heading">{t('onboarding.checkAudio')}</h2>
                <p className="onboarding-lede">{t('onboarding.audioHelp')}</p>
                <div className="onboarding-mode-switch" role="radiogroup" aria-label={t('settings.meetingType')}>
                  {([['both', t('settings.scenario.hybrid.title')], ['system', t('settings.scenario.online.title')], ['mic', t('settings.scenario.room.title')]] as const).map(([mode, label]) => (
                    <label key={mode} className={audioMode === mode ? 'onboarding-mode-selected' : ''}><input type="radio" name="audio-mode" aria-label={label.replace(' meeting', '')} checked={audioMode === mode} onChange={() => { setAudioMode(mode); setAudioState('idle'); setAudioResult(null) }} /><span>{label}</span></label>
                  ))}
                </div>
                <div className="onboarding-audio-sources">
                  <div><Headphones size={18} /><span><strong>{t('settings.systemAudio')}</strong><small>{audioResult?.system.required === false ? t('onboarding.systemNotNeeded') : audioResult?.system.ready ? t('onboarding.systemReady') : t('onboarding.playSomething')}</small></span><i style={{ '--level': audioResult?.system.level ?? 0 } as CSSProperties} /></div>
                  <div><Mic size={18} /><span><strong>{t('settings.roomMicrophone')}</strong><small>{audioResult?.microphone.required === false ? t('onboarding.micNotNeeded') : audioResult?.microphone.ready ? t('onboarding.micReady') : t('onboarding.saySomething')}</small></span><i style={{ '--level': audioResult?.microphone.level ?? 0 } as CSSProperties} /></div>
                </div>
                <button type="button" className="onboarding-audio-test" onClick={runAudioCheck} disabled={audioState === 'working'}><AudioWaveform size={16} /> {audioState === 'working' ? t('onboarding.listeningNow') : audioMode === 'mic' ? t('onboarding.checkMicrophone') : t('onboarding.checkAudioAction')}</button>
                {audioError && <p className="onboarding-inline-error" role="alert">{audioError}</p>}
              </section>
            )}

            {step === 4 && (
              <section className="provider-shortcut onboarding-shortcut" aria-labelledby="onboarding-shortcut-heading">
                <Command size={30} strokeWidth={1.5} aria-hidden="true" />
                <h2 id="onboarding-shortcut-heading">{t('onboarding.startAnywhere')}</h2>
                <p>{t('onboarding.shortcutHelp')}</p>
                <ShortcutRecorder value={shortcut} onChange={changeShortcut} />
                <small>{t('onboarding.shortcutSettings')}</small>
              </section>
            )}

            {step === 5 && (
              <section className="onboarding-complete" aria-labelledby="onboarding-complete-heading">
                <span className="provider-complete-check" aria-hidden="true"><Check size={24} /></span>
                <h2 id="onboarding-complete-heading">{t('onboarding.startFirstMeeting')}</h2>
                <p>{t('onboarding.firstMeetingHelp')}</p>
                <dl><div><dt>{t('onboarding.step.agent')}</dt><dd>{progressSummary.agent}</dd></div><div><dt>{t('onboarding.step.transcription')}</dt><dd>{progressSummary.transcription}</dd></div><div><dt>{t('settings.meetingType')}</dt><dd>{progressSummary.audio}</dd></div><div><dt>{t('onboarding.step.shortcut')}</dt><dd>{formatListeningShortcut(shortcut)}</dd></div></dl>
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
