import {
  AlertTriangle,
  Check,
  ChevronRight,
  Command,
  FileText,
  FolderOpen,
  HardDrive,
  Headphones,
  Mic2,
  Cloud,
  Download,
  Laptop,
  Keyboard,
  Languages,
  SlidersHorizontal,
  Trash2,
  ShieldCheck,
  X,
} from 'lucide-react'
import { useState } from 'react'
import type {
  AudioMode,
  DeepgramCredentialStatus,
  DoubaoCredentialStatus,
  ElevenLabsCredentialStatus,
  LocalDiarizationModelId,
  LocalTranscriptionModelId,
  ProviderId,
  RuntimeStatus,
  NotesStorageSettings,
  TranscriptionConfig,
  TranscriptionModelStatus,
  TranscriptStorageSettings,
} from '../types'
import { defaultGenerationSettings, type GenerationSettings } from '../lib/generationSettings'
import type { ProviderConfig } from '../lib/providerConfig'
import {
  defaultTranscriptionConfig,
  diarizationModels,
  localModelDescriptor,
  transcriptionModels as modelDescriptors,
} from '../lib/transcriptionConfig'
import { MeetingOutputSettings } from './MeetingOutputSettings'
import { ShortcutRecorder } from './ShortcutRecorder'
import type { ListeningShortcut } from '../lib/listeningShortcut'
import './ProviderSettings.css'
import { useI18n } from '../i18n/i18n'
import type { TranslationKey } from '../i18n/messages'

interface SettingsSheetProps {
  open: boolean
  runtimes: RuntimeStatus[]
  isDesktop: boolean
  audioMode?: AudioMode
  onChangeAudioMode?: (mode: AudioMode) => void
  audioModeLocked?: boolean
  transcriptionConfig?: TranscriptionConfig
  transcriptionModels?: TranscriptionModelStatus[]
  onChangeTranscriptionConfig?: (config: TranscriptionConfig) => void
  onPrepareTranscriptionModel?: (model: LocalTranscriptionModelId | LocalDiarizationModelId) => void
  onRemoveTranscriptionModel?: (model: LocalTranscriptionModelId | LocalDiarizationModelId) => void
  deepgramCredential?: DeepgramCredentialStatus
  deepgramCredentialBusy?: boolean
  onSaveDeepgramApiKey?: (apiKey: string) => void | Promise<void>
  onRemoveDeepgramApiKey?: () => void | Promise<void>
  onOpenDeepgramConsole?: () => void | Promise<void>
  elevenLabsCredential?: ElevenLabsCredentialStatus
  elevenLabsCredentialBusy?: boolean
  onSaveElevenLabsApiKey?: (
    apiKey: string,
  ) => void | ElevenLabsCredentialStatus | Promise<void | ElevenLabsCredentialStatus>
  onRemoveElevenLabsApiKey?: () => void | Promise<void>
  onOpenElevenLabsConsole?: () => void | Promise<void>
  doubaoCredential?: DoubaoCredentialStatus
  doubaoCredentialBusy?: boolean
  onSaveDoubaoCredentials?: (
    appId: string,
    accessToken: string,
  ) => void | DoubaoCredentialStatus | Promise<void | DoubaoCredentialStatus>
  onRemoveDoubaoCredentials?: () => void | Promise<void>
  onOpenDoubaoConsole?: () => void | Promise<void>
  providerConfig?: Readonly<ProviderConfig>
  onEditProviders?: () => void
  generationSettings?: GenerationSettings
  onChangeGenerationSettings?: (settings: GenerationSettings) => void
  listeningShortcut?: ListeningShortcut
  shortcutError?: string | null
  onChangeListeningShortcut?: (shortcut: ListeningShortcut) => boolean | Promise<boolean>
  onStartListeningShortcutRecording?: () => boolean | Promise<boolean>
  onCancelListeningShortcutRecording?: () => void | Promise<void>
  storageSettings?: TranscriptStorageSettings
  storageChanging?: boolean
  notesStorageSettings?: NotesStorageSettings
  notesStorageChanging?: boolean
  onChooseTranscriptDirectory?: () => boolean | Promise<boolean>
  onResetTranscriptDirectory?: () => boolean | Promise<boolean>
  onChooseNotesDirectory?: () => boolean | Promise<boolean>
  onResetNotesDirectory?: () => boolean | Promise<boolean>
  initialPage?: SettingsPage
  onClose: () => void
}

type SettingsPage = 'general' | 'audio' | 'output' | 'agent' | 'privacy'

const providerLabel: Record<ProviderId, string> = {
  codex: 'Codex',
  claude: 'Claude',
}

const cliLabel: Record<ProviderId, string> = {
  codex: 'Codex CLI',
  claude: 'Claude Code',
}

interface ProviderCredentialSetupProps {
  ariaLabel: string
  configured: boolean
  busy: boolean
  disabled: boolean
  readyLabel: string
  keychainLabel: string
  removeLabel: string
  pasteLabel: string
  pasteHelp: string
  getKeyLabel: string
  apiKeyLabel: string
  keyPlaceholder: string
  privacyLabel: string
  verifyLabel: string
  verifyingLabel: string
  href: string
  value: string
  error: string | null
  onChange: (value: string) => void
  onOpenConsole: () => void
  onRemove: () => void
  onSubmit: () => void
}

function ProviderCredentialSetup({
  ariaLabel,
  configured,
  busy,
  disabled,
  readyLabel,
  keychainLabel,
  removeLabel,
  pasteLabel,
  pasteHelp,
  getKeyLabel,
  apiKeyLabel,
  keyPlaceholder,
  privacyLabel,
  verifyLabel,
  verifyingLabel,
  href,
  value,
  error,
  onChange,
  onOpenConsole,
  onRemove,
  onSubmit,
}: ProviderCredentialSetupProps) {
  return (
    <div className="provider-key-setup" role="group" aria-label={ariaLabel}>
      {configured ? (
        <div className="provider-key-ready" aria-live="polite">
          <span className="provider-key-status">
            <Check size={15} aria-hidden="true" />
            <span><strong>{readyLabel}</strong><small>{keychainLabel}</small></span>
          </span>
          <button type="button" className="model-action model-action-remove" disabled={disabled || busy} onClick={onRemove}>
            {removeLabel}
          </button>
        </div>
      ) : (
        <form onSubmit={(event) => { event.preventDefault(); onSubmit() }}>
          <div className="provider-key-heading">
            <span><strong>{pasteLabel}</strong><small>{pasteHelp}</small></span>
            <a
              href={href}
              target="_blank"
              rel="noreferrer"
              onClick={(event) => {
                event.preventDefault()
                onOpenConsole()
              }}
            >
              {getKeyLabel}
            </a>
          </div>
          <div className="provider-key-entry">
            <input
              type="password"
              aria-label={apiKeyLabel}
              autoComplete="off"
              spellCheck={false}
              value={value}
              disabled={disabled || busy}
              placeholder={keyPlaceholder}
              onChange={(event) => onChange(event.target.value)}
            />
            <button type="submit" className="model-action" disabled={disabled || busy || !value.trim()}>
              {busy ? verifyingLabel : verifyLabel}
            </button>
          </div>
          {error && <p className="provider-key-error" role="alert">{error}</p>}
          <p className="provider-key-privacy"><ShieldCheck size={13} aria-hidden="true" /> {privacyLabel}</p>
        </form>
      )}
    </div>
  )
}

export function SettingsSheet({
  open,
  runtimes,
  isDesktop,
  audioMode = 'both',
  onChangeAudioMode = () => undefined,
  audioModeLocked = false,
  transcriptionConfig = defaultTranscriptionConfig(),
  transcriptionModels = [],
  onChangeTranscriptionConfig = () => undefined,
  onPrepareTranscriptionModel = () => undefined,
  onRemoveTranscriptionModel = () => undefined,
  deepgramCredential = { configured: false, verified: false, message: null },
  deepgramCredentialBusy = false,
  onSaveDeepgramApiKey = () => undefined,
  onRemoveDeepgramApiKey = () => undefined,
  onOpenDeepgramConsole = () => undefined,
  elevenLabsCredential = { configured: false, verified: false, message: null },
  elevenLabsCredentialBusy = false,
  onSaveElevenLabsApiKey = () => undefined,
  onRemoveElevenLabsApiKey = () => undefined,
  onOpenElevenLabsConsole = () => undefined,
  doubaoCredential = { configured: false, verified: false, message: null },
  doubaoCredentialBusy = false,
  onSaveDoubaoCredentials = () => undefined,
  onRemoveDoubaoCredentials = () => undefined,
  onOpenDoubaoConsole = () => undefined,
  providerConfig = { setupComplete: false, primary: null, secondary: null },
  onEditProviders = () => undefined,
  generationSettings = defaultGenerationSettings(),
  onChangeGenerationSettings = () => undefined,
  listeningShortcut = null,
  shortcutError = null,
  onChangeListeningShortcut = () => true,
  onStartListeningShortcutRecording,
  onCancelListeningShortcutRecording,
  storageSettings = {
    defaultDirectory: '~/Library/Application Support/Arco/transcripts',
    selectedDirectory: '~/Library/Application Support/Arco/transcripts',
    usingDefault: true,
  },
  storageChanging = false,
  notesStorageSettings = {
    defaultDirectory: '~/Library/Application Support/Arco/notes',
    selectedDirectory: '~/Library/Application Support/Arco/notes',
    usingDefault: true,
  },
  notesStorageChanging = false,
  onChooseTranscriptDirectory = () => true,
  onResetTranscriptDirectory = () => true,
  onChooseNotesDirectory = () => true,
  onResetNotesDirectory = () => true,
  initialPage = 'audio',
  onClose,
}: SettingsSheetProps) {
  const { locale, setLocale, t } = useI18n()
  const [page, setPage] = useState<SettingsPage>(initialPage)
  const [deepgramApiKey, setDeepgramApiKey] = useState('')
  const [deepgramError, setDeepgramError] = useState<string | null>(null)
  const [elevenLabsApiKey, setElevenLabsApiKey] = useState('')
  const [elevenLabsError, setElevenLabsError] = useState<string | null>(null)
  const [doubaoAppId, setDoubaoAppId] = useState('')
  const [doubaoAccessToken, setDoubaoAccessToken] = useState('')
  const [doubaoError, setDoubaoError] = useState<string | null>(null)
  if (!open) return null
  const audioScenarios: Array<{ mode: AudioMode; title: string; description: string }> = [
    { mode: 'both', title: t('settings.scenario.hybrid.title'), description: t('settings.scenario.hybrid.description') },
    { mode: 'system', title: t('settings.scenario.online.title'), description: t('settings.scenario.online.description') },
    { mode: 'mic', title: t('settings.scenario.room.title'), description: t('settings.scenario.room.description') },
  ]
  const selectedAudioScenario = audioScenarios.find((scenario) => scenario.mode === audioMode) ?? audioScenarios[0]
  const selectedModel = localModelDescriptor(transcriptionConfig.asr.model)
  const selectedModelStatus = transcriptionModels.find((status) => status.id === transcriptionConfig.asr.model)
  const selectedDiarizationModel = transcriptionConfig.diarization.provider === 'local'
    ? diarizationModels.find((model) => model.id === transcriptionConfig.diarization.model)
    : undefined
  const selectedDiarizationStatus = transcriptionModels.find((status) => status.id === selectedDiarizationModel?.id)
  const selectedModelBusy = selectedModelStatus
    ? ['downloading', 'optimizing', 'loading'].includes(selectedModelStatus.phase)
    : false
  const selectedModelAction = selectedModelStatus?.phase === 'optimizing'
    ? t('common.optimizing')
    : selectedModelStatus?.phase === 'loading'
      ? t('common.loading')
      : selectedModelStatus?.phase === 'downloading'
        ? `${Math.round((selectedModelStatus.progress ?? 0) * 100)}%`
        : t('common.download')
  const modelDetailKeys: Record<LocalTranscriptionModelId, TranslationKey> = {
    'nemotron-speech-3.5-streaming': 'model.nemotron',
    'whisper-tiny': 'model.whisperTiny',
    'whisper-base': 'model.whisperBase',
    'whisper-small': 'model.whisperSmall',
    'whisper-medium': 'model.whisperMedium',
    'whisper-large': 'model.whisperLarge',
  }
  const localDiarizationEnabled = selectedDiarizationModel !== undefined
  const selectedModelReady = selectedModelStatus?.installed === true
  const selectedDiarizationReady = selectedDiarizationStatus?.installed === true
  const localSetupIncomplete = (transcriptionConfig.asr.provider === 'local' && !selectedModelReady)
    || (localDiarizationEnabled && !selectedDiarizationReady)
  const selectedModelLabel = selectedModel?.label ?? t('settings.onDevice')
  const localAsrSummary = selectedModelReady
    ? selectedModelLabel
    : t('settings.modelNotDownloaded', { model: selectedModelLabel })
  const localDiarizationSummary = localDiarizationEnabled
    ? selectedDiarizationReady
      ? selectedDiarizationModel.label
      : t('settings.modelNotDownloaded', { model: selectedDiarizationModel.label })
    : t('settings.speakerSeparationOff')
  const cloudLanguageLabel = transcriptionConfig.asr.language === 'auto'
    ? t('common.automatic')
    : transcriptionConfig.asr.language === 'en-US' ? t('common.english') : t('common.chinese')
  const asrSummary = transcriptionConfig.asr.provider === 'deepgram'
    ? `Deepgram · ${cloudLanguageLabel}`
    : transcriptionConfig.asr.provider === 'elevenlabs'
      ? `ElevenLabs · ${cloudLanguageLabel}`
      : transcriptionConfig.asr.provider === 'doubao'
        ? `Doubao · ${cloudLanguageLabel}`
      : localAsrSummary
  const diarizationSummary = transcriptionConfig.diarization.provider === 'deepgram'
    ? t('settings.deepgramBuiltIn')
    : transcriptionConfig.diarization.provider === 'doubao'
      ? t('settings.doubaoBuiltIn')
    : transcriptionConfig.diarization.provider === 'local'
      ? localDiarizationSummary
      : t('settings.speakerSeparationOff')
  const recognitionLabel = `${asrSummary} · ${diarizationSummary}`

  const changeEngine = (provider: TranscriptionConfig['asr']['provider']) => {
    if (provider === 'deepgram') {
      onChangeTranscriptionConfig({
        ...transcriptionConfig,
        asr: {
          provider: 'deepgram',
          model: 'nova-3',
          language: transcriptionConfig.asr.language === 'auto' ? 'zh-CN' : transcriptionConfig.asr.language,
        },
      })
      return
    }
    if (provider === 'elevenlabs') {
      onChangeTranscriptionConfig({
        ...transcriptionConfig,
        asr: {
          provider: 'elevenlabs',
          model: 'scribe-v2-realtime',
          language: transcriptionConfig.asr.language,
        },
      })
      return
    }
    if (provider === 'doubao') {
      onChangeTranscriptionConfig({
        ...transcriptionConfig,
        asr: {
          provider: 'doubao',
          model: 'bigmodel',
          language: transcriptionConfig.asr.language,
        },
        diarization: transcriptionConfig.diarization.provider === 'deepgram'
          ? { provider: 'doubao', model: 'bigmodel' }
          : transcriptionConfig.diarization,
      })
      return
    }
    onChangeTranscriptionConfig({
      ...transcriptionConfig,
      asr: {
        provider: 'local',
        model: selectedModel?.id ?? 'nemotron-speech-3.5-streaming',
        language: transcriptionConfig.asr.language,
      },
    })
  }

  const changeDiarizationLocation = (location: 'cloud' | 'local' | 'off') => {
    if (location === 'cloud') {
      const provider = transcriptionConfig.diarization.provider === 'doubao'
        || transcriptionConfig.asr.provider === 'doubao'
        ? 'doubao'
        : 'deepgram'
      onChangeTranscriptionConfig({
        ...transcriptionConfig,
        diarization: provider === 'doubao'
          ? { provider: 'doubao', model: 'bigmodel' }
          : { provider: 'deepgram', model: 'latest' },
      })
      return
    }
    if (location === 'local') {
      onChangeTranscriptionConfig({
        ...transcriptionConfig,
        diarization: {
          provider: 'local',
          model: selectedDiarizationModel?.id ?? 'sortformer-streaming',
        },
      })
      return
    }
    onChangeTranscriptionConfig({
      ...transcriptionConfig,
      diarization: { provider: 'none', model: null },
    })
  }

  const changeDiarizationProvider = (provider: 'deepgram' | 'doubao') => {
    onChangeTranscriptionConfig({
      ...transcriptionConfig,
      diarization: provider === 'doubao'
        ? { provider: 'doubao', model: 'bigmodel' }
        : { provider: 'deepgram', model: 'latest' },
    })
  }

  const saveDeepgramKey = async () => {
    const key = deepgramApiKey.trim()
    if (!key) return
    setDeepgramError(null)
    try {
      await onSaveDeepgramApiKey(key)
      setDeepgramApiKey('')
    } catch (cause) {
      setDeepgramError(cause instanceof Error ? cause.message : String(cause))
    }
  }

  const openDeepgramConsole = async () => {
    setDeepgramError(null)
    try {
      await onOpenDeepgramConsole()
    } catch (cause) {
      setDeepgramError(cause instanceof Error ? cause.message : String(cause))
    }
  }

  const saveElevenLabsKey = async () => {
    const key = elevenLabsApiKey.trim()
    if (!key) return
    setElevenLabsError(null)
    try {
      await onSaveElevenLabsApiKey(key)
      setElevenLabsApiKey('')
    } catch (cause) {
      setElevenLabsError(cause instanceof Error ? cause.message : String(cause))
    }
  }

  const openElevenLabsConsole = async () => {
    setElevenLabsError(null)
    try {
      await onOpenElevenLabsConsole()
    } catch (cause) {
      setElevenLabsError(cause instanceof Error ? cause.message : String(cause))
    }
  }

  const saveDoubao = async () => {
    const appId = doubaoAppId.trim()
    const accessToken = doubaoAccessToken.trim()
    if (!appId) return
    setDoubaoError(null)
    try {
      await onSaveDoubaoCredentials(appId, accessToken)
      setDoubaoAppId('')
      setDoubaoAccessToken('')
    } catch (cause) {
      setDoubaoError(cause instanceof Error ? cause.message : String(cause))
    }
  }

  const openDoubaoConsole = async () => {
    setDoubaoError(null)
    try {
      await onOpenDoubaoConsole()
    } catch (cause) {
      setDoubaoError(cause instanceof Error ? cause.message : String(cause))
    }
  }

  return (
    <div className="settings-backdrop" role="presentation" onMouseDown={onClose}>
      <section
        className="settings-sheet settings-window"
        role="dialog"
        aria-modal="true"
        aria-labelledby="settings-heading"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <aside className="settings-navigation" aria-label={t('settings.sections')}>
          <div className="settings-navigation-heading">
            <strong>
              {t('common.settings')}
              {!isDesktop && <small className="settings-preview-badge">{t('common.preview')}</small>}
            </strong>
          </div>
          <nav>
            <button type="button" className={page === 'general' ? 'settings-nav-active' : ''} onClick={() => setPage('general')}>
              <SlidersHorizontal size={17} /> {t('settings.general')}
            </button>
            <button type="button" className={page === 'audio' ? 'settings-nav-active' : ''} onClick={() => setPage('audio')}>
              <Mic2 size={17} /> {t('settings.audio')}
            </button>
            <button type="button" className={page === 'output' ? 'settings-nav-active' : ''} onClick={() => setPage('output')}>
              <FileText size={17} /> {t('settings.output')}
            </button>
            <button type="button" className={page === 'agent' ? 'settings-nav-active' : ''} onClick={() => setPage('agent')}>
              <Command size={17} /> {t('settings.agent')}
            </button>
            <button type="button" className={page === 'privacy' ? 'settings-nav-active' : ''} onClick={() => setPage('privacy')}>
              <ShieldCheck size={17} /> {t('settings.privacy')}
            </button>
          </nav>
        </aside>

        <div className="settings-main">
          <header>
            <div>
              <h2 id="settings-heading">
                {page === 'general' && t('settings.general')}
                {page === 'audio' && t('settings.audio')}
                {page === 'output' && t('settings.output')}
                {page === 'agent' && t('settings.agent')}
                {page === 'privacy' && t('settings.privacy')}
              </h2>
              <span className="settings-subtitle">
                {page === 'general' && t('settings.generalDescription')}
                {page === 'audio' && t('settings.audioDescription')}
                {page === 'output' && t('settings.outputDescription')}
                {page === 'agent' && t('settings.agentDescription')}
                {page === 'privacy' && t('settings.privacyDescription')}
              </span>
            </div>
            <button type="button" className="icon-button" onClick={onClose} aria-label={t('settings.close')}><X size={19} /></button>
          </header>

          <div className="settings-content">
            {page === 'general' && (
              <section className="settings-section general-settings" aria-label={t('settings.generalPreferences')}>
                <div className="general-settings-list">
                  <label className="settings-control-row settings-language-row">
                    <span>
                      <strong><Languages size={15} aria-hidden="true" /> {t('settings.appLanguage')}</strong>
                      <small>{t('settings.appLanguageHelp')}</small>
                    </span>
                    <select
                      aria-label={t('settings.appLanguage')}
                      value={locale}
                      onChange={(event) => setLocale(event.target.value as 'en' | 'zh-CN')}
                    >
                      <option value="zh-CN">简体中文</option>
                      <option value="en">English</option>
                    </select>
                  </label>
                  <div className="shortcut-settings-row">
                    <span>
                      <strong className="general-setting-title"><Keyboard size={15} aria-hidden="true" /> {t('settings.startStopListening')}</strong>
                      <small>{t('settings.startStopListeningHelp')}</small>
                    </span>
                    <ShortcutRecorder
                      value={listeningShortcut}
                      onChange={onChangeListeningShortcut}
                      onStartRecording={onStartListeningShortcutRecording}
                      onCancelRecording={onCancelListeningShortcutRecording}
                    />
                  </div>
                </div>
                {shortcutError && <p className="shortcut-settings-error" role="alert">{shortcutError}</p>}
              </section>
            )}

            {page === 'audio' && (
              <section className="settings-section">
                {audioModeLocked ? (
                  <>
                    <div className="current-audio-mode" role="region" aria-label={t('settings.currentMeetingAudio')}>
                      <span className="audio-mode-icon" aria-hidden="true">
                        <AudioModeIcon mode={audioMode} />
                      </span>
                      <span className="current-audio-copy">
                        <small>{t('common.currentMeeting')}</small>
                        <strong>{selectedAudioScenario.title}</strong>
                        <span>{selectedAudioScenario.description}</span>
                      </span>
                      <span className="current-audio-locked">{t('settings.lockedUntilEnd')}</span>
                    </div>
                  </>
                ) : (
                  <fieldset className="audio-mode-fieldset">
                    <legend>{t('settings.meetingType')}</legend>
                    <div className="audio-mode-options">
                      {audioScenarios.map((scenario) => {
                        const selected = scenario.mode === audioMode
                        return (
                          <label
                            className={`audio-mode-option ${selected ? 'audio-mode-option-selected' : ''}`}
                            key={scenario.mode}
                          >
                            <input
                              type="radio"
                              name="audio-mode"
                              value={scenario.mode}
                              checked={selected}
                              onChange={() => onChangeAudioMode(scenario.mode)}
                            />
                            <span className="audio-mode-icon" aria-hidden="true">
                              <AudioModeIcon mode={scenario.mode} />
                            </span>
                            <span className="audio-mode-copy">
                              <strong>{scenario.title}</strong>
                              <small>{scenario.description}</small>
                            </span>
                            <span className="audio-mode-check" aria-hidden="true">
                              {selected && <Check size={14} strokeWidth={2.5} />}
                            </span>
                          </label>
                        )
                      })}
                    </div>
                  </fieldset>
                )}

                <div className="settings-disclosure-list">
                  <details className="settings-disclosure" open>
                    <summary>
                      <span className="settings-disclosure-title">{t('settings.recognition')}</span>
                      <span className="settings-disclosure-value" title={recognitionLabel}>
                        {localSetupIncomplete && (
                          <AlertTriangle
                            className="settings-disclosure-warning"
                            size={15}
                            strokeWidth={2.2}
                            role="img"
                            aria-label={t('settings.localModelsMissing')}
                          />
                        )}
                        <span>{recognitionLabel}</span>
                      </span>
                      <ChevronRight className="settings-disclosure-chevron" size={15} aria-hidden="true" />
                    </summary>
                    <div className="settings-disclosure-content">
                      <section className="recognition-group" aria-labelledby="speech-recognition-heading">
                        <div className="recognition-group-heading">
                          <h3 id="speech-recognition-heading">{t('settings.speechRecognition')}</h3>
                          <span>{asrSummary}</span>
                      </div>
                      <fieldset className="recognition-engine" aria-label={t('settings.asrLocation')} disabled={audioModeLocked}>
                        <legend className="sr-only">{t('settings.asrLocation')}</legend>
                        <label className={transcriptionConfig.asr.provider !== 'local' ? 'recognition-engine-selected' : ''}>
                          <input
                            type="radio"
                            name="transcription-location"
                            checked={transcriptionConfig.asr.provider !== 'local'}
                            onChange={() => changeEngine(transcriptionConfig.asr.provider === 'local' ? 'deepgram' : transcriptionConfig.asr.provider)}
                          />
                          <Cloud size={16} aria-hidden="true" />
                          <span><strong>{t('settings.cloud')}</strong><small>{t('settings.cloudDescription')}</small></span>
                        </label>
                        <label className={transcriptionConfig.asr.provider === 'local' ? 'recognition-engine-selected' : ''}>
                          <input
                            type="radio"
                            name="transcription-location"
                            checked={transcriptionConfig.asr.provider === 'local'}
                            onChange={() => changeEngine('local')}
                          />
                          <Laptop size={16} aria-hidden="true" />
                          <span><strong>{t('settings.onDevice')}</strong><small>{t('settings.onDeviceDescription')}</small></span>
                        </label>
                      </fieldset>

                      {transcriptionConfig.asr.provider !== 'local' && (
                        <fieldset
                          className="cloud-provider-options cloud-provider-options-compact provider-second-level"
                          aria-label={t('settings.asrProvider')}
                          disabled={audioModeLocked}
                        >
                          <legend>{t('settings.asrProvider')}</legend>
                          <label className={transcriptionConfig.asr.provider === 'deepgram' ? 'cloud-provider-selected' : ''}>
                            <input
                              type="radio"
                              name="transcription-provider"
                              checked={transcriptionConfig.asr.provider === 'deepgram'}
                              onChange={() => changeEngine('deepgram')}
                            />
                            <span><strong>Deepgram</strong><small>{t('settings.deepgramDescription')}</small></span>
                            {transcriptionConfig.asr.provider === 'deepgram' && <Check size={14} aria-hidden="true" />}
                          </label>
                          <label className={transcriptionConfig.asr.provider === 'elevenlabs' ? 'cloud-provider-selected' : ''}>
                            <input
                              type="radio"
                              name="transcription-provider"
                              checked={transcriptionConfig.asr.provider === 'elevenlabs'}
                              onChange={() => changeEngine('elevenlabs')}
                            />
                            <span><strong>ElevenLabs</strong><small>{t('settings.elevenLabsDescription')}</small></span>
                            {transcriptionConfig.asr.provider === 'elevenlabs' && <Check size={14} aria-hidden="true" />}
                          </label>
                          <label className={transcriptionConfig.asr.provider === 'doubao' ? 'cloud-provider-selected' : ''}>
                            <input
                              type="radio"
                              name="transcription-provider"
                              checked={transcriptionConfig.asr.provider === 'doubao'}
                              onChange={() => changeEngine('doubao')}
                            />
                            <span><strong>Doubao</strong><small>{t('settings.doubaoDescription')}</small></span>
                            {transcriptionConfig.asr.provider === 'doubao' && <Check size={14} aria-hidden="true" />}
                          </label>
                        </fieldset>
                      )}

                      {transcriptionConfig.asr.provider === 'deepgram' && (
                        <ProviderCredentialSetup
                          ariaLabel={t('settings.deepgramSetupAria')}
                          configured={deepgramCredential.configured}
                          busy={deepgramCredentialBusy}
                          disabled={audioModeLocked}
                          readyLabel={t('settings.deepgramReady')}
                          keychainLabel={t('settings.deepgramKeychain')}
                          removeLabel={t('settings.removeDeepgramKey')}
                          pasteLabel={t('settings.deepgramPasteKey')}
                          pasteHelp={t('settings.deepgramPasteKeyHelp')}
                          getKeyLabel={t('settings.deepgramGetKey')}
                          apiKeyLabel={t('settings.deepgramApiKey')}
                          keyPlaceholder={t('settings.deepgramKeyPlaceholder')}
                          privacyLabel={t('settings.deepgramPrivacy')}
                          verifyLabel={t('settings.verifyAndSave')}
                          verifyingLabel={t('settings.verifying')}
                          href="https://console.deepgram.com/"
                          value={deepgramApiKey}
                          error={deepgramError}
                          onChange={setDeepgramApiKey}
                          onOpenConsole={() => { void openDeepgramConsole() }}
                          onRemove={() => { void onRemoveDeepgramApiKey() }}
                          onSubmit={() => { void saveDeepgramKey() }}
                        />
                      )}

                      {transcriptionConfig.asr.provider === 'elevenlabs' && (
                        <ProviderCredentialSetup
                          ariaLabel={t('settings.elevenLabsSetupAria')}
                          configured={elevenLabsCredential.configured}
                          busy={elevenLabsCredentialBusy}
                          disabled={audioModeLocked}
                          readyLabel={t('settings.elevenLabsReady')}
                          keychainLabel={t('settings.elevenLabsKeychain')}
                          removeLabel={t('settings.removeElevenLabsKey')}
                          pasteLabel={t('settings.elevenLabsPasteKey')}
                          pasteHelp={t('settings.elevenLabsPasteKeyHelp')}
                          getKeyLabel={t('settings.elevenLabsGetKey')}
                          apiKeyLabel={t('settings.elevenLabsApiKey')}
                          keyPlaceholder={t('settings.elevenLabsKeyPlaceholder')}
                          privacyLabel={t('settings.elevenLabsPrivacy')}
                          verifyLabel={t('settings.verifyAndSave')}
                          verifyingLabel={t('settings.verifying')}
                          href="https://elevenlabs.io/app/developers/api-keys"
                          value={elevenLabsApiKey}
                          error={elevenLabsError}
                          onChange={setElevenLabsApiKey}
                          onOpenConsole={() => { void openElevenLabsConsole() }}
                          onRemove={() => { void onRemoveElevenLabsApiKey() }}
                          onSubmit={() => { void saveElevenLabsKey() }}
                        />
                      )}

                      {(transcriptionConfig.asr.provider === 'doubao' || transcriptionConfig.diarization.provider === 'doubao') && (
                        <div className="provider-key-setup" role="group" aria-label={t('settings.doubaoSetupAria')}>
                          {doubaoCredential.configured ? (
                            <div className="provider-key-ready" aria-live="polite">
                              <span className="provider-key-status">
                                <Check size={15} aria-hidden="true" />
                                <span><strong>{t('settings.doubaoReady')}</strong><small>{t('settings.doubaoKeychain')}</small></span>
                              </span>
                              <button type="button" className="model-action model-action-remove" disabled={audioModeLocked || doubaoCredentialBusy} onClick={() => { void onRemoveDoubaoCredentials() }}>
                                {t('settings.removeDoubaoCredentials')}
                              </button>
                            </div>
                          ) : (
                            <form onSubmit={(event) => { event.preventDefault(); void saveDoubao() }}>
                              <div className="provider-key-heading">
                                <span><strong>{t('settings.doubaoPasteCredentials')}</strong><small>{t('settings.doubaoPasteCredentialsHelp')}</small></span>
                                <a href="https://console.volcengine.com/speech/app" target="_blank" rel="noreferrer" onClick={(event) => { event.preventDefault(); void openDoubaoConsole() }}>
                                  {t('settings.doubaoGetCredentials')}
                                </a>
                              </div>
                              <div className="doubao-credential-fields">
                                <input type="password" aria-label={t('settings.doubaoAppId')} autoComplete="off" spellCheck={false} value={doubaoAppId} disabled={audioModeLocked || doubaoCredentialBusy} placeholder={t('settings.doubaoAppId')} onChange={(event) => setDoubaoAppId(event.target.value)} />
                                <input type="password" aria-label={t('settings.doubaoAccessToken')} autoComplete="off" spellCheck={false} value={doubaoAccessToken} disabled={audioModeLocked || doubaoCredentialBusy} placeholder={t('settings.doubaoAccessToken')} onChange={(event) => setDoubaoAccessToken(event.target.value)} />
                                <button type="submit" className="model-action" disabled={audioModeLocked || doubaoCredentialBusy || !doubaoAppId.trim()}>
                                  {doubaoCredentialBusy ? t('settings.verifying') : t('settings.verifyAndSave')}
                                </button>
                              </div>
                              {doubaoError && <p className="provider-key-error" role="alert">{doubaoError}</p>}
                              <p className="provider-key-privacy"><ShieldCheck size={13} aria-hidden="true" /> {t('settings.doubaoPrivacy')}</p>
                            </form>
                          )}
                        </div>
                      )}

                      {transcriptionConfig.asr.provider === 'local' && (
                        <div className="local-recognition-settings provider-second-level">
                          <label className="settings-control-row">
                            <span><strong>{t('settings.model')}</strong><small>{selectedModel ? t(modelDetailKeys[selectedModel.id]) : ''}</small></span>
                            <select
                              aria-label={t('settings.onDeviceModel')}
                              value={transcriptionConfig.asr.model}
                              disabled={audioModeLocked}
                              onChange={(event) => onChangeTranscriptionConfig({
                                ...transcriptionConfig,
                                asr: {
                                  ...transcriptionConfig.asr,
                                  model: event.target.value as LocalTranscriptionModelId,
                                },
                              })}
                            >
                              {modelDescriptors.map((model) => (
                                <option key={model.id} value={model.id}>{model.label} · {model.downloadSize}</option>
                              ))}
                            </select>
                          </label>

                          <div className="model-lifecycle-row" aria-live="polite">
                            <span>
                              <strong>{selectedModelStatus?.installed ? t('settings.modelReady') : t('settings.modelRequired')}</strong>
                              <small>{selectedModel?.downloadSize}{selectedModelStatus?.error ? ` · ${selectedModelStatus.error}` : ''}</small>
                            </span>
                            {selectedModelStatus?.installed ? (
                              <button
                                type="button"
                                className="model-action model-action-remove"
                                disabled={audioModeLocked}
                                aria-label={t('settings.removeModel', { model: selectedModel?.label ?? '' })}
                                onClick={() => selectedModel && onRemoveTranscriptionModel(selectedModel.id)}
                              >
                                <Trash2 size={14} /> {t('common.remove')}
                              </button>
                            ) : (
                              <button
                                type="button"
                                className="model-action"
                                disabled={audioModeLocked || selectedModelBusy}
                                aria-label={t('settings.downloadAndUseModel', { model: selectedModel?.label ?? '' })}
                                onClick={() => selectedModel && onPrepareTranscriptionModel(selectedModel.id)}
                              >
                                <Download size={14} />
                                {!selectedModelStatus?.installed && !selectedModelBusy
                                  ? t('settings.downloadAndUse')
                                  : selectedModelAction}
                              </button>
                            )}
                          </div>

                          <label className="settings-control-row">
                            <span><strong>{t('settings.language')}</strong><small>{t('settings.recognitionLanguageHelp')}</small></span>
                            <select
                              aria-label={t('settings.recognitionLanguage')}
                              value={transcriptionConfig.asr.language}
                              disabled={audioModeLocked}
                              onChange={(event) => onChangeTranscriptionConfig({
                                ...transcriptionConfig,
                                asr: {
                                  ...transcriptionConfig.asr,
                                  language: event.target.value as TranscriptionConfig['asr']['language'],
                                },
                              })}
                            >
                              <option value="auto">{t('common.automatic')}</option>
                              <option value="zh-CN">{t('common.chineseSimplified')}</option>
                              <option value="en-US">{t('common.english')}</option>
                            </select>
                          </label>
                          <p className="local-privacy-note"><ShieldCheck size={14} /> {t(transcriptionConfig.diarization.provider === 'deepgram' ? 'settings.localAsrMixedPrivacy' : 'settings.localPrivacy')}</p>
                        </div>
                      )}

                      </section>

                      <section className="recognition-group recognition-group-speakers" aria-labelledby="speaker-separation-heading">
                        <div className="recognition-group-heading">
                          <h3 id="speaker-separation-heading">{t('settings.speakerSeparation')}</h3>
                          <span>{diarizationSummary}</span>
                        </div>

                      {transcriptionConfig.asr.provider === 'elevenlabs' && (
                        <div className="provider-diarization-receipt provider-context-receipt">
                          <AlertTriangle size={15} aria-hidden="true" />
                          <span><strong>{t('settings.elevenLabsBuiltIn')}</strong><small>{t('settings.elevenLabsDiarizationTiming')}</small></span>
                        </div>
                      )}

                      <fieldset
                        className="recognition-engine recognition-engine-three diarization-location"
                        aria-label={t('settings.diarizationLocation')}
                        disabled={audioModeLocked}
                      >
                        <legend className="sr-only">{t('settings.diarizationLocation')}</legend>
                        <label className={transcriptionConfig.diarization.provider === 'deepgram' || transcriptionConfig.diarization.provider === 'doubao' ? 'recognition-engine-selected' : ''}>
                          <input
                            type="radio"
                            name="diarization-location"
                            checked={transcriptionConfig.diarization.provider === 'deepgram' || transcriptionConfig.diarization.provider === 'doubao'}
                            onChange={() => changeDiarizationLocation('cloud')}
                          />
                          <Cloud size={16} aria-hidden="true" />
                          <span><strong>{t('settings.cloud')}</strong><small>{t('settings.diarizationCloudDescription')}</small></span>
                        </label>
                        <label className={transcriptionConfig.diarization.provider === 'local' ? 'recognition-engine-selected' : ''}>
                          <input
                            type="radio"
                            name="diarization-location"
                            checked={transcriptionConfig.diarization.provider === 'local'}
                            onChange={() => changeDiarizationLocation('local')}
                          />
                          <Laptop size={16} aria-hidden="true" />
                          <span><strong>{t('settings.onDevice')}</strong><small>{t('settings.diarizationLocalDescription')}</small></span>
                        </label>
                        <label className={transcriptionConfig.diarization.provider === 'none' ? 'recognition-engine-selected' : ''}>
                          <input
                            type="radio"
                            name="diarization-location"
                            checked={transcriptionConfig.diarization.provider === 'none'}
                            onChange={() => changeDiarizationLocation('off')}
                          />
                          <X size={16} aria-hidden="true" />
                          <span><strong>{t('common.off')}</strong><small>{t('settings.diarizationOffDescription')}</small></span>
                        </label>
                      </fieldset>

                      {(transcriptionConfig.diarization.provider === 'deepgram' || transcriptionConfig.diarization.provider === 'doubao') && (
                        <fieldset
                          className="cloud-provider-options provider-second-level"
                          aria-label={t('settings.diarizationProvider')}
                          disabled={audioModeLocked}
                        >
                          <legend>{t('settings.diarizationProvider')}</legend>
                          <label className={transcriptionConfig.diarization.provider === 'deepgram' ? 'cloud-provider-selected' : ''}>
                            <input
                              type="radio"
                              name="diarization-cloud-provider"
                              checked={transcriptionConfig.diarization.provider === 'deepgram'}
                              onChange={() => changeDiarizationProvider('deepgram')}
                            />
                            <span><strong>Deepgram</strong><small>{t('settings.deepgramNoLocalModel')}</small></span>
                            {deepgramCredential.configured ? <em>{t('common.ready')}</em> : <Check size={14} aria-hidden="true" />}
                          </label>
                          <label className={transcriptionConfig.diarization.provider === 'doubao' ? 'cloud-provider-selected' : ''}>
                            <input
                              type="radio"
                              name="diarization-cloud-provider"
                              checked={transcriptionConfig.diarization.provider === 'doubao'}
                              onChange={() => changeDiarizationProvider('doubao')}
                            />
                            <span><strong>Doubao</strong><small>{t('settings.doubaoNoLocalModel')}</small></span>
                            {doubaoCredential.configured ? <em>{t('common.ready')}</em> : transcriptionConfig.diarization.provider === 'doubao' && <Check size={14} aria-hidden="true" />}
                          </label>
                        </fieldset>
                      )}

                      {transcriptionConfig.diarization.provider === 'local' && (
                        <fieldset className="diarization-models provider-second-level" aria-label={t('settings.localDiarizationModel')}>
                          <legend>{t('settings.localDiarizationModel')}</legend>
                          {diarizationModels.map((model) => {
                            const status = transcriptionModels.find((candidate) => candidate.id === model.id)
                            const busy = ['downloading', 'optimizing', 'loading'].includes(status?.phase ?? '')
                            const action = status?.phase === 'optimizing'
                              ? t('common.optimizing')
                              : status?.phase === 'loading'
                                ? t('common.loading')
                                : status?.phase === 'downloading'
                                  ? `${Math.round((status.progress ?? 0) * 100)}%`
                                  : t('common.download')
                            return (
                              <div className="diarization-choice" key={model.id}>
                                <input
                                  id={model.id}
                                  type="radio"
                                  name="diarization-model"
                                  checked={transcriptionConfig.diarization.model === model.id}
                                  disabled={audioModeLocked}
                                  onChange={() => onChangeTranscriptionConfig({
                                    ...transcriptionConfig,
                                    diarization: { provider: 'local', model: model.id },
                                  })}
                                />
                                <label htmlFor={model.id}>
                                  <strong>{model.label}</strong>
                                  <small>{t(model.detailKey)}{status?.error ? ` · ${status.error}` : ''}</small>
                                </label>
                                {status?.installed ? (
                                  <em>{t('common.ready')}</em>
                                ) : (
                                  <button
                                    type="button"
                                    className="model-action"
                                    disabled={audioModeLocked || busy}
                                    aria-label={t('settings.downloadModel', { model: model.label })}
                                    onClick={() => onPrepareTranscriptionModel(model.id)}
                                  >
                                    <Download size={14} /> {busy ? action : t('common.download')}
                                  </button>
                                )}
                              </div>
                            )
                          })}
                        </fieldset>
                      )}

                      {(transcriptionConfig.asr.provider === 'deepgram' || transcriptionConfig.diarization.provider === 'deepgram') && (
                        <div className="provider-diarization-receipt">
                          <Check size={15} aria-hidden="true" />
                          <span>
                            <strong>{t(transcriptionConfig.diarization.provider === 'deepgram' ? 'settings.deepgramBuiltIn' : 'settings.deepgramAsr')}</strong>
                            <small>{t(transcriptionConfig.diarization.provider === 'deepgram' ? 'settings.deepgramNoLocalModel' : 'settings.deepgramAsrHelp')}</small>
                          </span>
                        </div>
                      )}

                      {transcriptionConfig.asr.provider !== 'deepgram' && transcriptionConfig.diarization.provider === 'deepgram' && (
                        <ProviderCredentialSetup
                          ariaLabel={t('settings.deepgramSetupAria')}
                          configured={deepgramCredential.configured}
                          busy={deepgramCredentialBusy}
                          disabled={audioModeLocked}
                          readyLabel={t('settings.deepgramReady')}
                          keychainLabel={t('settings.deepgramKeychain')}
                          removeLabel={t('settings.removeDeepgramKey')}
                          pasteLabel={t('settings.deepgramPasteKey')}
                          pasteHelp={t('settings.deepgramPasteKeyHelp')}
                          getKeyLabel={t('settings.deepgramGetKey')}
                          apiKeyLabel={t('settings.deepgramApiKey')}
                          keyPlaceholder={t('settings.deepgramKeyPlaceholder')}
                          privacyLabel={t('settings.deepgramPrivacy')}
                          verifyLabel={t('settings.verifyAndSave')}
                          verifyingLabel={t('settings.verifying')}
                          href="https://console.deepgram.com/"
                          value={deepgramApiKey}
                          error={deepgramError}
                          onChange={setDeepgramApiKey}
                          onOpenConsole={() => { void openDeepgramConsole() }}
                          onRemove={() => { void onRemoveDeepgramApiKey() }}
                          onSubmit={() => { void saveDeepgramKey() }}
                        />
                      )}

                      </section>

                    </div>
                  </details>
                </div>
              </section>
            )}

            {page === 'agent' && (
              <section className="settings-section provider-settings">
                <section className="provider-configuration" aria-label={t('settings.currentConfiguration')}>
                  <div className="provider-section-heading">
                    <div>
                      <h3>{t('settings.currentConfiguration')}</h3>
                      <p>{t('settings.configurationHelp')}</p>
                    </div>
                    <button type="button" className="provider-edit-button" onClick={onEditProviders}>
                      {providerConfig.setupComplete ? t('common.editConfiguration') : t('settings.setUpAgent')}
                    </button>
                  </div>

                  <dl className="provider-summary">
                    <div>
                      <dt>{t('settings.primaryProvider')}</dt>
                      <dd>{providerConfig.primary ? providerLabel[providerConfig.primary] : t('common.notConfigured')}</dd>
                    </div>
                    <div>
                      <dt>{t('settings.secondaryProvider')}</dt>
                      <dd className={!providerConfig.secondary ? 'provider-value-muted' : undefined}>
                        {providerConfig.secondary ? providerLabel[providerConfig.secondary] : t('common.notConfigured')}
                      </dd>
                    </div>
                  </dl>
                </section>

                <section className="provider-runtimes" aria-label={t('settings.localCliStatus')}>
                  <div className="provider-section-heading provider-runtime-heading">
                    <div>
                      <h3>{t('settings.onThisMacHeading')}</h3>
                      <p>{t('settings.detectedCli')}</p>
                    </div>
                  </div>

                  <div className="provider-runtime-list">
                    {runtimes.map((runtime) => (
                      <div className="provider-runtime-row" key={runtime.provider}>
                        <span className="provider-runtime-copy">
                          <strong>{cliLabel[runtime.provider]}</strong>
                          <small>{runtime.version ?? t('common.notDetected')}</small>
                        </span>
                        <span className={`provider-runtime-state ${runtime.available ? 'provider-runtime-state-ready' : ''}`}>
                          <span aria-hidden="true" />
                          {runtime.available ? t('common.installed') : t('common.missing')}
                        </span>
                      </div>
                    ))}
                  </div>
                </section>
              </section>
            )}

            {page === 'output' && (
              <section className="settings-section">
                <MeetingOutputSettings settings={generationSettings} onSave={onChangeGenerationSettings} />
              </section>
            )}

            {page === 'privacy' && (
              <section className="settings-section">
                <div className="settings-section-intro">
                  <ShieldCheck size={18} />
                  <p>{t('settings.storageIntro')}</p>
                </div>
                <div className={`transcript-storage-setting ${!storageSettings.usingDefault ? 'transcript-storage-setting-custom' : ''}`}>
                  <button
                    type="button"
                    className="transcript-storage-summary"
                    aria-label={t('settings.transcriptStorage')}
                    disabled={storageChanging || audioModeLocked}
                    onClick={() => void onChooseTranscriptDirectory()}
                  >
                    <span className="transcript-storage-name"><HardDrive size={14} /> {t('settings.meetingTranscripts')}</span>
                    <span className="transcript-storage-value">
                      <small>{storageSettings.usingDefault ? t('settings.defaultLocation') : t('settings.customLocation')}</small>
                      <code title={storageSettings.selectedDirectory}>{storageSettings.selectedDirectory}</code>
                    </span>
                    <ChevronRight size={15} aria-hidden="true" />
                  </button>
                  {!storageSettings.usingDefault && (
                    <button
                      type="button"
                      className="storage-restore-action"
                      disabled={storageChanging || audioModeLocked}
                      onClick={() => void onResetTranscriptDirectory()}
                    >
                      {t('settings.restoreDefault')}
                    </button>
                  )}
                  {audioModeLocked && <small className="storage-lock-hint">{t('settings.storageLocked')}</small>}
                </div>
                <div className={`transcript-storage-setting ${!notesStorageSettings.usingDefault ? 'transcript-storage-setting-custom' : ''}`}>
                  <button
                    type="button"
                    className="transcript-storage-summary"
                    aria-label={t('settings.notesStorage')}
                    disabled={notesStorageChanging}
                    onClick={() => void onChooseNotesDirectory()}
                  >
                    <span className="transcript-storage-name"><FileText size={14} /> {t('settings.notes')}</span>
                    <span className="transcript-storage-value">
                      <small>{notesStorageSettings.usingDefault ? t('settings.defaultLocation') : t('settings.customLocation')}</small>
                      <code title={notesStorageSettings.selectedDirectory}>{notesStorageSettings.selectedDirectory}</code>
                    </span>
                    <ChevronRight size={15} aria-hidden="true" />
                  </button>
                  {!notesStorageSettings.usingDefault && (
                    <button
                      type="button"
                      className="storage-restore-action"
                      disabled={notesStorageChanging}
                      onClick={() => void onResetNotesDirectory()}
                    >
                      {t('settings.restoreDefault')}
                    </button>
                  )}
                </div>
                <dl className="settings-facts settings-facts-large">
                  <div><dt><FolderOpen size={14} /> {t('settings.legacyImport')}</dt><dd>{t('settings.legacyImportValue')}</dd></div>
                  <div><dt><Command size={14} /> {t('settings.nativeConversations')}</dt><dd>{t('settings.nativeConversationsValue')}</dd></div>
                  <div><dt><HardDrive size={14} /> {t('settings.linksCacheNotes')}</dt><dd>{t('settings.linksCacheNotesValue')}</dd></div>
                  <div><dt><ShieldCheck size={14} /> {t('settings.questionContext')}</dt><dd>{t('settings.questionContextValue')}</dd></div>
                </dl>
              </section>
            )}
          </div>
        </div>
      </section>
    </div>
  )
}

function AudioModeIcon({ mode }: { mode: AudioMode }) {
  if (mode === 'system') return <Headphones size={17} />
  if (mode === 'mic') return <Mic2 size={17} />

  return (
    <>
      <Headphones size={16} />
      <Mic2 size={12} />
    </>
  )
}
