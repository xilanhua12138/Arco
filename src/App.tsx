import { AlertTriangle, Radio, X } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import { listen } from '@tauri-apps/api/event'
import './App.css'
import { HistoryPage } from './components/HistoryPage'
import { CurrentIdleState } from './components/CurrentIdleState'
import { InsightPanel } from './components/InsightPanel'
import { NotesPage } from './components/NotesPage'
import { ProviderSetup } from './components/ProviderSetup'
import { SettingsSheet } from './components/SettingsSheet'
import { Sidebar } from './components/Sidebar'
import { TopBar } from './components/TopBar'
import { TranscriptPane } from './components/TranscriptPane'
import { useArco } from './hooks/useArco'
import { useAgentWorkspace } from './hooks/useAgentWorkspace'
import { arcoBridge } from './lib/bridge'
import {
  loadProviderConfig,
  resolveProviderRoute,
  saveProviderConfig,
  type ProviderConfig,
} from './lib/providerConfig'
import {
  loadGenerationSettings,
  saveGenerationSettings,
  type GenerationSettings,
} from './lib/generationSettings'
import type { AudioMode } from './types'
import type { DeepgramCredentialStatus, NotesStorageSettings, TranscriptStorageSettings, TranscriptionConfig, TranscriptionModelStatus } from './types'
import {
  loadTranscriptionConfig,
  saveTranscriptionConfig,
} from './lib/transcriptionConfig'
import {
  loadListeningShortcut,
  saveListeningShortcut,
  type ListeningShortcut,
} from './lib/listeningShortcut'
import { registerListeningShortcut, unregisterListeningShortcut } from './lib/listeningShortcutRuntime'
import { completeOnboarding, loadOnboardingState } from './lib/onboarding'
import { useI18n } from './i18n/i18n'

type AppPage = 'current' | 'history' | 'notes' | 'review'

const storedAudioMode = (): AudioMode => {
  const value = window.localStorage.getItem('arco.audioMode')
  return value === 'system' || value === 'mic' || value === 'both' ? value : 'both'
}

function App() {
  const { t } = useI18n()
  const arco = useArco()
  const agentWorkspace = useAgentWorkspace(t('agent.chooseWorkspaceDialogTitle'))
  const refreshMeetings = arco.refreshMeetings
  const refreshSavedNotes = arco.refreshSavedNotes
  const activeMeeting = arco.activeMeeting
  const [page, setPage] = useState<AppPage>('current')
  const [query, setQuery] = useState('')
  const [notesQuery, setNotesQuery] = useState('')
  const [audioMode, setAudioMode] = useState<AudioMode>(storedAudioMode)
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [settingsPage, setSettingsPage] = useState<'general' | 'audio'>('general')
  const [providerConfig, setProviderConfig] = useState<ProviderConfig>(loadProviderConfig)
  const [generationSettings, setGenerationSettings] = useState<GenerationSettings>(loadGenerationSettings)
  const [transcriptionConfig, setTranscriptionConfig] = useState<TranscriptionConfig>(loadTranscriptionConfig)
  const [transcriptionModels, setTranscriptionModels] = useState<TranscriptionModelStatus[]>([])
  const [deepgramCredential, setDeepgramCredential] = useState<DeepgramCredentialStatus>({ configured: false, verified: false, message: null })
  const [deepgramCredentialBusy, setDeepgramCredentialBusy] = useState(false)
  const [providerSetupOpen, setProviderSetupOpen] = useState(() => {
    const existingProvider = loadProviderConfig()
    return !existingProvider.setupComplete && !loadOnboardingState().completed
  })
  const [editingProviders, setEditingProviders] = useState(false)
  const [listeningShortcut, setListeningShortcut] = useState<ListeningShortcut>(loadListeningShortcut)
  const [shortcutError, setShortcutError] = useState<string | null>(null)
  const [storageSettings, setStorageSettings] = useState<TranscriptStorageSettings | undefined>()
  const [notesStorageSettings, setNotesStorageSettings] = useState<NotesStorageSettings | undefined>()
  const [storageChanging, setStorageChanging] = useState(false)
  const [notesStorageChanging, setNotesStorageChanging] = useState(false)
  const [storageError, setStorageError] = useState<string | null>(null)
  const returnFocusRef = useRef<string | null>(null)
  const registeredShortcutRef = useRef<ListeningShortcut>(null)
  const toggleListeningRef = useRef<() => void>(() => undefined)
  const providerRoute = resolveProviderRoute(providerConfig, arco.runtimes)
  const audioModeLocked = ['starting', 'recording', 'stopping'].includes(arco.capture.phase)
  const displayedAudioMode = audioModeLocked && arco.capture.mode ? arco.capture.mode : audioMode
  const reviewingWhileRecording = Boolean(
    arco.capture.phase === 'recording' &&
    arco.capture.activeMeetingId &&
    arco.meeting &&
    arco.meeting.summary.id !== arco.capture.activeMeetingId,
  )
  const currentMeeting = arco.capture.phase === 'recording'
    && arco.capture.activeMeetingId
    && arco.meeting?.summary.id === arco.capture.activeMeetingId
    ? arco.meeting
    : null
  const activeMeetingDisplayTitle = activeMeeting
    ? activeMeeting.title?.trim() || t('common.untitledMeeting')
    : t('common.currentMeeting')

  const changeAudioMode = (mode: AudioMode) => {
    setAudioMode(mode)
    window.localStorage.setItem('arco.audioMode', mode)
  }

  const changeGenerationSettings = (settings: GenerationSettings) => {
    saveGenerationSettings(settings)
    setGenerationSettings(settings)
  }

  const changeTranscriptionConfig = (config: TranscriptionConfig) => {
    saveTranscriptionConfig(config)
    setTranscriptionConfig(config)
  }

  const refreshTranscriptionModels = async () => {
    const next = await arcoBridge.transcriptionModelStatus()
    setTranscriptionModels(next)
    return next
  }

  const refreshDeepgramCredential = async () => {
    const status = await arcoBridge.deepgramCredentialStatus()
    setDeepgramCredential(status)
    return status
  }

  const saveDeepgramApiKey = async (apiKey: string) => {
    setDeepgramCredentialBusy(true)
    try {
      const status = await arcoBridge.saveDeepgramApiKey(apiKey)
      setDeepgramCredential(status)
    } finally {
      setDeepgramCredentialBusy(false)
    }
  }

  const removeDeepgramApiKey = async () => {
    setDeepgramCredentialBusy(true)
    try {
      const status = await arcoBridge.removeDeepgramApiKey()
      setDeepgramCredential(status)
    } finally {
      setDeepgramCredentialBusy(false)
    }
  }

  const mergeTranscriptionModelStatus = useCallback((status: TranscriptionModelStatus) => {
    setTranscriptionModels((current) => {
      const retained = current.filter((candidate) => candidate.id !== status.id)
      return [...retained, status]
    })
  }, [])

  const restoreTriggerFocus = () => {
    const triggerId = returnFocusRef.current
    if (!triggerId) return
    window.setTimeout(() => document.getElementById(triggerId)?.focus(), 0)
  }

  const closeSettings = () => {
    setSettingsOpen(false)
    restoreTriggerFocus()
  }

  const showPage = async (nextPage: AppPage) => {
    setSettingsOpen(false)
    if (nextPage === 'notes') void refreshSavedNotes(notesQuery)
    if (
      nextPage === 'current' &&
      arco.capture.phase === 'recording' &&
      arco.capture.activeMeetingId &&
      arco.selectedMeetingId !== arco.capture.activeMeetingId
    ) {
      const opened = await arco.selectMeeting(arco.capture.activeMeetingId)
      if (!opened) return
    }
    if (nextPage === 'current' && query.trim()) {
      setQuery('')
      await arco.refreshMeetings('')
    }
    setPage(nextPage)
  }

  const toggleListening = useCallback(async () => {
    if (['starting', 'stopping'].includes(arco.capture.phase)) return
    const nextCapture = await arco.toggleCapture(audioMode, transcriptionConfig)
    if (nextCapture?.phase === 'recording') setPage('current')
  }, [arco, audioMode, transcriptionConfig])

  useEffect(() => {
    toggleListeningRef.current = () => void toggleListening()
  }, [toggleListening])

  useEffect(() => {
    if (!arco.isDesktop || !listeningShortcut) return
    let disposed = false
    void registerListeningShortcut(listeningShortcut, () => toggleListeningRef.current())
      .then(() => {
        if (!disposed) registeredShortcutRef.current = listeningShortcut
      })
      .catch((cause) => {
        if (!disposed) setShortcutError(cause instanceof Error ? cause.message : String(cause))
      })
    return () => {
      disposed = true
      const registered = registeredShortcutRef.current
      registeredShortcutRef.current = null
      void unregisterListeningShortcut(registered).catch(() => undefined)
    }
  // Registration is owned for the lifetime of the desktop window; changes are swapped below.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [arco.isDesktop])

  const changeListeningShortcut = async (next: ListeningShortcut) => {
    const previous = registeredShortcutRef.current
    setShortcutError(null)
    if (arco.isDesktop) {
      try {
        await unregisterListeningShortcut(previous)
        registeredShortcutRef.current = null
        await registerListeningShortcut(next, () => toggleListeningRef.current())
        registeredShortcutRef.current = next
      } catch (cause) {
        const message = cause instanceof Error ? cause.message : String(cause)
        setShortcutError(message)
        try {
          await registerListeningShortcut(previous, () => toggleListeningRef.current())
          registeredShortcutRef.current = previous
        } catch {
          registeredShortcutRef.current = null
        }
        return false
      }
    }
    saveListeningShortcut(next)
    setListeningShortcut(next)
    return true
  }

  const refreshStorageSettings = useCallback(async () => {
    try {
      const [settings, noteSettings] = await Promise.all([
        arcoBridge.storageSettings(),
        arcoBridge.notesStorageSettings(),
      ])
      setStorageSettings(settings)
      setNotesStorageSettings(noteSettings)
      return settings
    } catch (cause) {
      setStorageError(cause instanceof Error ? cause.message : String(cause))
      return null
    }
  }, [])

  const chooseTranscriptDirectory = async () => {
    setStorageError(null)
    try {
      const directory = await arcoBridge.chooseTranscriptDirectory(t('settings.chooseFolderDialogTitle'))
      if (!directory) return false
      setStorageChanging(true)
      const settings = await arcoBridge.setTranscriptDirectory(directory)
      setStorageSettings(settings)
      await refreshMeetings(query)
      return true
    } catch (cause) {
      setStorageError(cause instanceof Error ? cause.message : String(cause))
      return false
    } finally {
      setStorageChanging(false)
    }
  }

  const resetTranscriptDirectory = async () => {
    setStorageError(null)
    setStorageChanging(true)
    try {
      const settings = await arcoBridge.setTranscriptDirectory(null)
      setStorageSettings(settings)
      await refreshMeetings(query)
      return true
    } catch (cause) {
      setStorageError(cause instanceof Error ? cause.message : String(cause))
      return false
    } finally {
      setStorageChanging(false)
    }
  }

  const chooseNotesDirectory = async () => {
    setStorageError(null)
    try {
      const directory = await arcoBridge.chooseNotesDirectory(t('settings.chooseNotesFolderDialogTitle'))
      if (!directory) return false
      setNotesStorageChanging(true)
      const settings = await arcoBridge.setNotesDirectory(directory)
      setNotesStorageSettings(settings)
      await refreshSavedNotes(notesQuery)
      return true
    } catch (cause) {
      setStorageError(cause instanceof Error ? cause.message : String(cause))
      return false
    } finally {
      setNotesStorageChanging(false)
    }
  }

  const resetNotesDirectory = async () => {
    setStorageError(null)
    setNotesStorageChanging(true)
    try {
      const settings = await arcoBridge.setNotesDirectory(null)
      setNotesStorageSettings(settings)
      await refreshSavedNotes(notesQuery)
      return true
    } catch (cause) {
      setStorageError(cause instanceof Error ? cause.message : String(cause))
      return false
    } finally {
      setNotesStorageChanging(false)
    }
  }

  useEffect(() => {
    let cancelled = false
    void Promise.all([arcoBridge.storageSettings(), arcoBridge.notesStorageSettings()])
      .then(([settings, noteSettings]) => {
        if (!cancelled) {
          setStorageSettings(settings)
          setNotesStorageSettings(noteSettings)
        }
      })
      .catch((cause) => {
        if (!cancelled) setStorageError(cause instanceof Error ? cause.message : String(cause))
      })
    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    const timer = window.setTimeout(() => void refreshMeetings(query), 180)
    return () => window.clearTimeout(timer)
  }, [query, refreshMeetings])

  useEffect(() => {
    if (page !== 'notes') return
    const timer = window.setTimeout(() => void refreshSavedNotes(notesQuery), 180)
    return () => window.clearTimeout(timer)
  }, [notesQuery, page, refreshSavedNotes])

  useEffect(() => {
    const listener = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLocaleLowerCase() === 'k') {
        event.preventDefault()
        setSettingsOpen(false)
        setPage('history')
        window.setTimeout(() => document.querySelector<HTMLInputElement>('.history-search input')?.focus(), 0)
        return
      }

      if (event.key === 'Escape') {
        setSettingsOpen(false)
        const triggerId = returnFocusRef.current
        if (triggerId) window.setTimeout(() => document.getElementById(triggerId)?.focus(), 0)
      }
    }

    window.addEventListener('keydown', listener)
    return () => window.removeEventListener('keydown', listener)
  }, [])

  useEffect(() => {
    if (!arco.isDesktop) return
    let disposed = false
    let unlisten: (() => void) | undefined
    void listen<TranscriptionModelStatus>('arco:transcription-model-progress', (event) => {
      mergeTranscriptionModelStatus(event.payload)
    }).then((next) => {
      if (disposed) next()
      else unlisten = next
    })
    return () => {
      disposed = true
      unlisten?.()
    }
  }, [arco.isDesktop, mergeTranscriptionModelStatus])

  useEffect(() => {
    if (!arco.isDesktop || listeningShortcut !== 'Fn+KeyM') return
    let disposed = false
    let unlisten: (() => void) | undefined
    void listen('arco:fn-m-pressed', () => toggleListeningRef.current()).then((next) => {
      if (disposed) next()
      else unlisten = next
    })
    return () => {
      disposed = true
      unlisten?.()
    }
  }, [arco.isDesktop, listeningShortcut])

  return (
    <div className="app-shell consumer-shell">
      <Sidebar
        page={page}
        meeting={
          arco.capture.phase === 'recording'
            ? activeMeeting ?? (arco.meeting?.summary.id === arco.capture.activeMeetingId ? arco.meeting.summary : null)
            : null
        }
        capture={arco.capture}
        audioMode={displayedAudioMode}
        audioModeLocked={audioModeLocked}
        onChangePage={showPage}
        onToggleCapture={async () => {
          await toggleListening()
        }}
          onOpenSettings={() => {
          returnFocusRef.current = 'settings-trigger'
          setSettingsPage('general')
            setSettingsOpen(true)
            void refreshStorageSettings()
            void refreshTranscriptionModels().catch((cause) => console.warn('Could not read local speech models', cause))
            void refreshDeepgramCredential().catch((cause) => console.warn('Could not read Deepgram credential status', cause))
        }}
      />

      <section className="page-stage">
        <div className="page-drag-space" data-tauri-drag-region />

        {page === 'current' ? (
          <section className="current-page" aria-label={t('app.currentMeetingAria')}>
            {arco.capture.phase !== 'recording' ? (
              <div className="current-workspace current-workspace-idle">
                <CurrentIdleState
                  capture={arco.capture}
                  meetings={arco.meetings}
                  audioMode={displayedAudioMode}
                  shortcut={listeningShortcut}
                  onStart={() => void toggleListening()}
                  onOpenAudioSettings={() => {
                    returnFocusRef.current = 'settings-trigger'
                    setSettingsPage('audio')
                    setSettingsOpen(true)
                    void refreshTranscriptionModels().catch((cause) => console.warn('Could not read local speech models', cause))
                    void refreshDeepgramCredential().catch((cause) => console.warn('Could not read Deepgram credential status', cause))
                  }}
                />
              </div>
            ) : (
              <>
                <TopBar
                  meeting={currentMeeting?.summary ?? null}
                  meetingDetail={currentMeeting}
                  capture={arco.capture}
                  onRenameMeeting={arco.renameMeeting}
                />
                <div className="current-workspace">
                  <TranscriptPane meeting={currentMeeting} capture={arco.capture} loading={arco.loading} />
                  {providerRoute.provider && (
                    <InsightPanel
                      meeting={currentMeeting}
                      replies={arco.agentReplies}
                      runtimes={arco.runtimes}
                      provider={providerRoute.provider}
                      primaryProvider={providerConfig.primary ?? providerRoute.provider}
                      isFailover={providerRoute.isFailover}
                      running={arco.agentRunning}
                      onAsk={arco.askAgent}
                      onToggleSaved={arco.setAgentTurnSaved}
                      workspace={agentWorkspace.workspace}
                      onChooseWorkspace={agentWorkspace.chooseWorkspace}
                    />
                  )}
                </div>
              </>
            )}
          </section>
        ) : page === 'history' ? (
          <HistoryPage
            meetings={arco.meetings}
            selectedMeetingId={arco.selectedMeetingId}
            query={query}
            onQueryChange={setQuery}
            onSelectMeeting={async (id) => {
              const opened = await arco.selectMeeting(id)
              if (opened) setPage(id === arco.capture.activeMeetingId ? 'current' : 'review')
            }}
          />
        ) : page === 'notes' ? (
          <NotesPage
            notes={arco.savedNotes}
            meetings={arco.meetings}
            query={notesQuery}
            loading={arco.notesLoading}
            onQueryChange={setNotesQuery}
            onOpenMeeting={async (id) => {
              const opened = await arco.selectMeeting(id)
              if (opened) setPage(id === arco.capture.activeMeetingId ? 'current' : 'review')
            }}
            onSaveNote={arco.saveNote}
            onDeleteNote={arco.deleteNote}
          />
        ) : (
          <section className="current-page" aria-label={t('app.historyReviewAria')}>
            <TopBar
              meeting={arco.meeting?.summary ?? null}
              meetingDetail={arco.meeting}
              capture={arco.capture}
              onRenameMeeting={arco.renameMeeting}
              onBackToHistory={() => void showPage('history')}
            />
            {reviewingWhileRecording && (
              <button
                type="button"
                className="live-review-banner"
                aria-label={t('app.returnToLiveMeeting', { title: activeMeetingDisplayTitle })}
                onClick={() => void showPage('current')}
              >
                <Radio size={15} aria-hidden="true" />
                <span>{t('app.listeningContinues')}</span>
                <strong>{activeMeetingDisplayTitle}</strong>
                <span>{t('app.returnToLive')}</span>
              </button>
            )}
            <div className="current-workspace">
              <TranscriptPane meeting={arco.meeting} capture={arco.capture} loading={arco.loading} />
              {providerRoute.provider && (
                <InsightPanel
                  meeting={arco.meeting}
                  replies={arco.agentReplies}
                  runtimes={arco.runtimes}
                  provider={providerRoute.provider}
                  primaryProvider={providerConfig.primary ?? providerRoute.provider}
                  isFailover={providerRoute.isFailover}
                  running={arco.agentRunning}
                  onAsk={arco.askAgent}
                  onToggleSaved={arco.setAgentTurnSaved}
                  workspace={agentWorkspace.workspace}
                  onChooseWorkspace={agentWorkspace.chooseWorkspace}
                />
              )}
            </div>
          </section>
        )}
      </section>

      {(arco.error || storageError) && (
        <div className="error-toast" role="alert">
          <AlertTriangle size={17} />
          <span><strong>{t('app.needsAttention')}</strong>{arco.error || storageError}</span>
          <button type="button" onClick={() => { arco.dismissError(); setStorageError(null) }} aria-label={t('app.dismissError')}><X size={15} /></button>
        </div>
      )}

      {settingsOpen && (
        <SettingsSheet
        open
        initialPage={settingsPage}
        runtimes={arco.runtimes}
        isDesktop={arco.isDesktop}
        providerConfig={providerConfig}
        generationSettings={generationSettings}
        listeningShortcut={listeningShortcut}
        shortcutError={shortcutError}
        storageSettings={storageSettings}
        notesStorageSettings={notesStorageSettings}
        storageChanging={storageChanging}
        notesStorageChanging={notesStorageChanging}
        onChooseTranscriptDirectory={chooseTranscriptDirectory}
        onResetTranscriptDirectory={resetTranscriptDirectory}
        onChooseNotesDirectory={chooseNotesDirectory}
        onResetNotesDirectory={resetNotesDirectory}
        onChangeListeningShortcut={changeListeningShortcut}
        onChangeGenerationSettings={changeGenerationSettings}
        audioMode={displayedAudioMode}
        onChangeAudioMode={changeAudioMode}
        audioModeLocked={audioModeLocked}
        transcriptionConfig={transcriptionConfig}
        transcriptionModels={transcriptionModels}
        deepgramCredential={deepgramCredential}
        deepgramCredentialBusy={deepgramCredentialBusy}
        onSaveDeepgramApiKey={saveDeepgramApiKey}
        onRemoveDeepgramApiKey={removeDeepgramApiKey}
        onChangeTranscriptionConfig={changeTranscriptionConfig}
        onPrepareTranscriptionModel={(model) => {
          const includeDiarization = transcriptionConfig.diarization === 'local-streaming'
          mergeTranscriptionModelStatus({
            id: model,
            installed: false,
            phase: 'downloading',
            progress: 0,
            error: null,
            path: null,
          })
          if (includeDiarization) {
            mergeTranscriptionModelStatus({
              id: 'sortformer-streaming',
              installed: false,
              phase: 'downloading',
              progress: 0,
              error: null,
              path: null,
            })
          }
          void arcoBridge.prepareTranscriptionModel(
            model,
            includeDiarization,
          ).then(setTranscriptionModels).catch((cause) => {
            const error = cause instanceof Error ? cause.message : String(cause)
            mergeTranscriptionModelStatus({
              id: model,
              installed: false,
              phase: 'failed',
              progress: null,
              error,
              path: null,
            })
            if (includeDiarization) {
              mergeTranscriptionModelStatus({
                id: 'sortformer-streaming',
                installed: false,
                phase: 'failed',
                progress: null,
                error,
                path: null,
              })
            }
          })
        }}
        onRemoveTranscriptionModel={(model) => {
          void arcoBridge.removeTranscriptionModel(model)
            .then(setTranscriptionModels)
            .catch((cause) => {
              mergeTranscriptionModelStatus({
                id: model,
                installed: true,
                phase: 'failed',
                progress: null,
                error: cause instanceof Error ? cause.message : String(cause),
                path: null,
              })
            })
        }}
        onEditProviders={() => {
          setSettingsOpen(false)
          setEditingProviders(true)
          setProviderSetupOpen(true)
        }}
        onClose={closeSettings}
        />
      )}

      {providerSetupOpen && (
        <ProviderSetup
          mode={editingProviders ? 'provider' : 'onboarding'}
          runtimes={arco.runtimes}
          initialConfig={editingProviders ? providerConfig : undefined}
          listeningShortcut={listeningShortcut}
          onChangeListeningShortcut={changeListeningShortcut}
          onRefresh={arco.refreshRuntimes}
          onTest={async (provider) => (await arcoBridge.testAgentProvider(provider)).ok}
          onComplete={(nextConfig) => {
            saveProviderConfig(nextConfig)
            setProviderConfig(nextConfig)
            completeOnboarding(false)
            setProviderSetupOpen(false)
            setEditingProviders(false)
          }}
          onCancel={editingProviders ? () => {
            setProviderSetupOpen(false)
            setEditingProviders(false)
          } : undefined}
          onSkip={!editingProviders ? () => {
            completeOnboarding(true)
            setProviderSetupOpen(false)
          } : undefined}
        />
      )}
    </div>
  )
}

export default App
