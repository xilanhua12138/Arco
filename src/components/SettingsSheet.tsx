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
  onPrepareTranscriptionModel?: (model: LocalTranscriptionModelId, diarizationModel?: LocalDiarizationModelId) => void
  onRemoveTranscriptionModel?: (model: LocalTranscriptionModelId | LocalDiarizationModelId) => void
  deepgramCredential?: DeepgramCredentialStatus
  deepgramCredentialBusy?: boolean
  onSaveDeepgramApiKey?: (apiKey: string) => void | Promise<void>
  onRemoveDeepgramApiKey?: () => void | Promise<void>
  onOpenDeepgramConsole?: () => void | Promise<void>
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
  if (!open) return null
  const audioScenarios: Array<{ mode: AudioMode; title: string; description: string }> = [
    { mode: 'both', title: t('settings.scenario.hybrid.title'), description: t('settings.scenario.hybrid.description') },
    { mode: 'system', title: t('settings.scenario.online.title'), description: t('settings.scenario.online.description') },
    { mode: 'mic', title: t('settings.scenario.room.title'), description: t('settings.scenario.room.description') },
  ]
  const selectedAudioScenario = audioScenarios.find((scenario) => scenario.mode === audioMode) ?? audioScenarios[0]
  const selectedModel = localModelDescriptor(transcriptionConfig.model)
  const selectedModelStatus = transcriptionModels.find((status) => status.id === transcriptionConfig.model)
  const selectedDiarizationModel = diarizationModels.find((model) => model.id === transcriptionConfig.diarization)
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
  const localSetupIncomplete = transcriptionConfig.provider === 'local'
    && (!selectedModelReady || (localDiarizationEnabled && !selectedDiarizationReady))
  const selectedModelLabel = selectedModel?.label ?? t('settings.onDevice')
  const localAsrSummary = selectedModelReady
    ? selectedModelLabel
    : t('settings.modelNotDownloaded', { model: selectedModelLabel })
  const localDiarizationSummary = localDiarizationEnabled
    ? selectedDiarizationReady
      ? selectedDiarizationModel.label
      : t('settings.modelNotDownloaded', { model: selectedDiarizationModel.label })
    : t('settings.speakerSeparationOff')
  const recognitionLabel = transcriptionConfig.provider === 'deepgram'
    ? transcriptionConfig.language === 'en-US' ? t('common.english') : t('common.chinese')
    : `${localAsrSummary} · ${localDiarizationSummary}`

  const changeEngine = (provider: TranscriptionConfig['provider']) => {
    if (provider === 'deepgram') {
      onChangeTranscriptionConfig({
        provider: 'deepgram',
        model: 'nova-3',
        language: transcriptionConfig.language === 'auto' ? 'zh-CN' : transcriptionConfig.language,
        diarization: 'provider',
      })
      return
    }
    onChangeTranscriptionConfig({
      provider: 'local',
      model: selectedModel?.id ?? 'nemotron-speech-3.5-streaming',
      language: transcriptionConfig.language,
      diarization: 'sortformer-streaming',
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
                  <details className="settings-disclosure">
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
                      {audioModeLocked ? (
                        <div className="recognition-engine-locked" aria-label={t('settings.currentRecognition')}>
                          {transcriptionConfig.provider === 'deepgram' ? <Cloud size={16} /> : <Laptop size={16} />}
                          <span>
                            <strong>{transcriptionConfig.provider === 'deepgram' ? 'Deepgram' : t('settings.onDevice')}</strong>
                            <small>{t('settings.recognitionLocked')}</small>
                          </span>
                        </div>
                      ) : (
                        <fieldset className="recognition-engine">
                          <legend>{t('settings.recognitionEngine')}</legend>
                          <label className={transcriptionConfig.provider === 'deepgram' ? 'recognition-engine-selected' : ''}>
                            <input
                              type="radio"
                              name="recognition-engine"
                              checked={transcriptionConfig.provider === 'deepgram'}
                              onChange={() => changeEngine('deepgram')}
                            />
                            <Cloud size={16} aria-hidden="true" />
                            <span><strong>{t('settings.cloud')}</strong><small>{t('settings.deepgramDescription')}</small></span>
                          </label>
                          <label className={transcriptionConfig.provider === 'local' ? 'recognition-engine-selected' : ''}>
                            <input
                              type="radio"
                              name="recognition-engine"
                              checked={transcriptionConfig.provider === 'local'}
                              onChange={() => changeEngine('local')}
                            />
                            <Laptop size={16} aria-hidden="true" />
                            <span><strong>{t('settings.onDevice')}</strong><small>{t('settings.onDeviceDescription')}</small></span>
                          </label>
                        </fieldset>
                      )}

                      {transcriptionConfig.provider === 'local' && (
                        <div className="local-recognition-settings">
                          <label className="settings-control-row">
                            <span><strong>{t('settings.model')}</strong><small>{selectedModel ? t(modelDetailKeys[selectedModel.id]) : ''}</small></span>
                            <select
                              aria-label={t('settings.onDeviceModel')}
                              value={transcriptionConfig.model}
                              disabled={audioModeLocked}
                              onChange={(event) => onChangeTranscriptionConfig({
                                ...transcriptionConfig,
                                model: event.target.value as LocalTranscriptionModelId,
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
                              value={transcriptionConfig.language}
                              disabled={audioModeLocked}
                              onChange={(event) => onChangeTranscriptionConfig({
                                ...transcriptionConfig,
                                language: event.target.value as TranscriptionConfig['language'],
                              })}
                            >
                              <option value="auto">{t('common.automatic')}</option>
                              <option value="zh-CN">{t('common.chineseSimplified')}</option>
                              <option value="en-US">{t('common.english')}</option>
                            </select>
                          </label>

                          <fieldset className="diarization-models" aria-label={t('settings.speakerSeparation')}>
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
                                    name="local-diarization-model"
                                    checked={transcriptionConfig.diarization === model.id}
                                    disabled={audioModeLocked}
                                    onChange={() => onChangeTranscriptionConfig({ ...transcriptionConfig, diarization: model.id })}
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
                                      disabled={audioModeLocked || busy || !selectedModel}
                                      aria-label={t('settings.downloadModel', { model: model.label })}
                                      onClick={() => selectedModel && onPrepareTranscriptionModel(selectedModel.id, model.id)}
                                    >
                                      <Download size={14} /> {busy ? action : t('common.download')}
                                    </button>
                                  )}
                                </div>
                              )
                            })}
                            <label className="diarization-choice diarization-choice-off">
                              <input
                                type="radio"
                                name="local-diarization-model"
                                checked={transcriptionConfig.diarization === 'none'}
                                disabled={audioModeLocked}
                                onChange={() => onChangeTranscriptionConfig({ ...transcriptionConfig, diarization: 'none' })}
                              />
                              <span><strong>{t('common.off')}</strong><small>{t('settings.speakerOff')}</small></span>
                            </label>
                          </fieldset>
                          <p className="local-privacy-note"><ShieldCheck size={14} /> {t('settings.localPrivacy')}</p>
                        </div>
                      )}

                      {transcriptionConfig.provider === 'deepgram' && (
                        <div className="deepgram-provider-panel">
                          <div className="provider-diarization-receipt">
                            <Check size={15} aria-hidden="true" />
                            <span><strong>{t('settings.deepgramBuiltIn')}</strong><small>{t('settings.deepgramNoLocalModel')}</small></span>
                          </div>
                          <div className="deepgram-key-panel" role="group" aria-label={t('settings.deepgramSetupAria')}>
                          {deepgramCredential.configured ? (
                            <div className="deepgram-key-ready" aria-live="polite">
                              <span className="deepgram-key-status"><Check size={15} aria-hidden="true" /><span><strong>{t('settings.deepgramReady')}</strong><small>{t('settings.deepgramKeychain')}</small></span></span>
                              <button type="button" className="model-action model-action-remove" disabled={audioModeLocked || deepgramCredentialBusy} onClick={() => void onRemoveDeepgramApiKey()}>
                                {t('settings.removeDeepgramKey')}
                              </button>
                            </div>
                          ) : (
                            <form onSubmit={(event) => { event.preventDefault(); void saveDeepgramKey() }}>
                              <div className="deepgram-key-heading">
                                <span><strong>{t('settings.deepgramPasteKey')}</strong><small>{t('settings.deepgramPasteKeyHelp')}</small></span>
                                <a
                                  href="https://console.deepgram.com/"
                                  target="_blank"
                                  rel="noreferrer"
                                  onClick={(event) => {
                                    event.preventDefault()
                                    void openDeepgramConsole()
                                  }}
                                >
                                  {t('settings.deepgramGetKey')}
                                </a>
                              </div>
                              <div className="deepgram-key-entry">
                                <input
                                  type="password"
                                  aria-label={t('settings.deepgramApiKey')}
                                  autoComplete="off"
                                  spellCheck={false}
                                  value={deepgramApiKey}
                                  disabled={audioModeLocked || deepgramCredentialBusy}
                                  placeholder={t('settings.deepgramKeyPlaceholder')}
                                  onChange={(event) => setDeepgramApiKey(event.target.value)}
                                />
                                <button type="submit" className="model-action" disabled={audioModeLocked || deepgramCredentialBusy || !deepgramApiKey.trim()}>
                                  {deepgramCredentialBusy ? t('settings.verifying') : t('settings.verifyAndSave')}
                                </button>
                              </div>
                              {deepgramError && <p className="deepgram-key-error" role="alert">{deepgramError}</p>}
                              <p className="deepgram-key-privacy"><ShieldCheck size={13} aria-hidden="true" /> {t('settings.deepgramPrivacy')}</p>
                            </form>
                          )}
                          </div>
                        </div>
                      )}

                      <h3>{t('settings.speakerLabels')}</h3>
                      <p className="settings-disclosure-note">
                        {transcriptionConfig.provider === 'deepgram'
                          ? t('settings.speakerDeepgram')
                          : localDiarizationEnabled
                            ? t('settings.speakerLocal', { model: selectedDiarizationModel.label })
                            : t('settings.speakerOff')}
                      </p>
                      <div
                        className={`capture-lanes ${audioMode === 'both' ? '' : 'capture-lanes-single'}`}
                        aria-label={t('settings.audioSourceNaming')}
                      >
                        {audioMode !== 'mic' && (
                          <div>
                            <Headphones size={17} aria-hidden="true" />
                            <span><strong>{t('settings.systemAudio')}</strong><small>{t('settings.systemAudioHelp')}</small></span>
                            <code>{t('settings.remoteExample')}</code>
                          </div>
                        )}
                        {audioMode !== 'system' && (
                          <div>
                            <Mic2 size={17} aria-hidden="true" />
                            <span><strong>{t('settings.roomMicrophone')}</strong><small>{t('settings.roomMicrophoneHelp')}</small></span>
                            <code>{t('settings.roomExample')}</code>
                          </div>
                        )}
                      </div>
                      <p className="speaker-policy">{t('settings.locationPolicy')}</p>
                      <dl className="settings-facts settings-disclosure-facts">
                        <div><dt>{t('settings.engine')}</dt><dd>{transcriptionConfig.provider === 'deepgram' ? t('settings.deepgramDiarization') : selectedModel?.label}</dd></div>
                        <div><dt>{t('settings.speakerSeparation')}</dt><dd>{selectedDiarizationModel?.label ?? (transcriptionConfig.diarization === 'provider' ? t('settings.deepgramBuiltIn') : t('common.off'))}</dd></div>
                      </dl>
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
