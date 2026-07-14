import { Channel, invoke } from '@tauri-apps/api/core'
import { open } from '@tauri-apps/plugin-dialog'
import {
  demoAgentReply,
  demoCapture,
  demoMeetingDetails,
  demoMeetings,
  demoRuntimes,
} from './demoData'
import type {
  AskAgentInput,
  AgentStreamEvent,
  AudioMode,
  AudioSetupCheck,
  CaptureState,
  DeepgramCredentialStatus,
  ElevenLabsCredentialStatus,
  GenerateMeetingOutputInput,
  MeetingDetail,
  MeetingGenerationStatus,
  MeetingOutputArtifact,
  MeetingSummary,
  LocalDiarizationModelId,
  LocalTranscriptionModelId,
  NoteDocument,
  NotesStorageSettings,
  PersistedAgentTurn,
  ProviderConnectionTest,
  RuntimeStatus,
  SavedNote,
  SaveNoteInput,
  TranscriptionConfig,
  TranscriptionModelStatus,
  TranscriptStorageSettings,
} from '../types'
import { workspaceName } from './agentWorkspace'

const hasTauriRuntime = () => '__TAURI_INTERNALS__' in window
const demoMode = () => new URLSearchParams(window.location.search).get('demo')
const hasExplicitDemoMode = () => !hasTauriRuntime() && ['1', 'empty'].includes(demoMode() ?? '')
const hasEmptyDemoMode = () => !hasTauriRuntime() && demoMode() === 'empty'

const wait = (milliseconds: number) => new Promise((resolve) => window.setTimeout(resolve, milliseconds))
const demoTurnsKey = 'arco.demoAgentTurns'
const demoCaptureKey = 'arco.demoCapture'
const demoTranscriptEmptyKey = 'arco.demoTranscriptEmpty'
const demoMeetingOutputsKey = 'arco.demoMeetingOutputs'
const demoStorageKey = 'arco.demoTranscriptStorage'
const demoTranscriptionModelsKey = 'arco.demoTranscriptionModels'
const demoDeepgramConfiguredKey = 'arco.demoDeepgramConfigured'
const demoElevenLabsConfiguredKey = 'arco.demoElevenLabsConfigured'
const demoNotesKey = 'arco.demoNotes'
const demoNotesStorageKey = 'arco.demoNotesStorage'
const demoDefaultTranscriptDirectory = '/Users/demo/Library/Application Support/Arco/transcripts'
const demoDefaultNotesDirectory = '/Users/demo/Library/Application Support/Arco/notes'

const createAgentRequestId = () => globalThis.crypto?.randomUUID?.()
  ?? `agent-${Date.now()}-${Math.random().toString(16).slice(2)}`

const demoTranscriptionModels: TranscriptionModelStatus[] = [
  {
    id: 'nemotron-speech-3.5-streaming',
    installed: false,
    phase: 'not-installed',
    progress: null,
    error: null,
    path: null,
  },
  ...(['whisper-tiny', 'whisper-base', 'whisper-small', 'whisper-medium', 'whisper-large'] as const).map((id) => ({
    id,
    installed: false,
    phase: 'not-installed' as const,
    progress: null,
    error: null,
    path: null,
  })),
  {
    id: 'sortformer-streaming',
    installed: false,
    phase: 'not-installed',
    progress: null,
    error: null,
    path: null,
  },
  {
    id: 'pyannote-wespeaker-streaming',
    installed: false,
    phase: 'not-installed',
    progress: null,
    error: null,
    path: null,
  },
  {
    id: 'lseend-ami-streaming',
    installed: false,
    phase: 'not-installed',
    progress: null,
    error: null,
    path: null,
  },
  {
    id: 'lseend-dihard3-streaming',
    installed: false,
    phase: 'not-installed',
    progress: null,
    error: null,
    path: null,
  },
]

const readDemoTranscriptionModels = (): TranscriptionModelStatus[] => {
  try {
    const parsed: unknown = JSON.parse(window.localStorage.getItem(demoTranscriptionModelsKey) ?? 'null')
    if (!Array.isArray(parsed)) return demoTranscriptionModels.map((status) => ({ ...status }))
    const stored = parsed as TranscriptionModelStatus[]
    return demoTranscriptionModels.map((fallback) => (
      stored.find((status) => status.id === fallback.id) ?? { ...fallback }
    ))
  } catch {
    return demoTranscriptionModels.map((status) => ({ ...status }))
  }
}

const writeDemoTranscriptionModels = (statuses: TranscriptionModelStatus[]) => {
  window.localStorage.setItem(demoTranscriptionModelsKey, JSON.stringify(statuses))
}

const updateDemoTranscriptionModel = (
  statuses: TranscriptionModelStatus[],
  id: TranscriptionModelStatus['id'],
  installed: boolean,
) => statuses.map((status) => status.id === id ? {
  ...status,
  installed,
  phase: installed ? 'ready' as const : 'not-installed' as const,
  progress: installed ? 1 : null,
  error: null,
  path: installed ? `/Users/demo/Library/Application Support/Arco/models/${id}` : null,
} : status)

interface DemoMeetingOutputState {
  title?: string | null
  generatedSummary?: string | null
  titleGenerationStatus?: MeetingGenerationStatus
  summaryGenerationStatus?: MeetingGenerationStatus
}

const readDemoMeetingOutputs = (): Record<string, DemoMeetingOutputState> => {
  try {
    const parsed: unknown = JSON.parse(window.localStorage.getItem(demoMeetingOutputsKey) ?? '{}')
    return parsed && typeof parsed === 'object'
      ? parsed as Record<string, DemoMeetingOutputState>
      : {}
  } catch {
    return {}
  }
}

const writeDemoMeetingOutput = (meetingId: string, output: DemoMeetingOutputState) => {
  const current = readDemoMeetingOutputs()
  window.localStorage.setItem(demoMeetingOutputsKey, JSON.stringify({
    ...current,
    [meetingId]: { ...current[meetingId], ...output },
  }))
}

const withDemoMeetingOutput = (summary: MeetingSummary): MeetingSummary => {
  const stored = readDemoMeetingOutputs()[summary.id]
  const hasStoredTitle = Boolean(stored && Object.prototype.hasOwnProperty.call(stored, 'title'))
  return {
    ...summary,
    title: hasStoredTitle ? stored?.title ?? null : summary.title ?? null,
    generatedSummary: stored?.generatedSummary ?? summary.generatedSummary ?? null,
    titleGenerationStatus: stored?.titleGenerationStatus
      ?? summary.titleGenerationStatus
      ?? (summary.title ? 'ready' : 'idle'),
    summaryGenerationStatus: stored?.summaryGenerationStatus
      ?? summary.summaryGenerationStatus
      ?? 'idle',
  }
}

const readDemoTurns = (): PersistedAgentTurn[] => {
  try {
    const parsed: unknown = JSON.parse(window.localStorage.getItem(demoTurnsKey) ?? '[]')
    return Array.isArray(parsed) ? parsed as PersistedAgentTurn[] : []
  } catch {
    return []
  }
}

const writeDemoTurns = (turns: PersistedAgentTurn[]) => {
  window.localStorage.setItem(demoTurnsKey, JSON.stringify(turns))
}

const readDemoNotes = (): NoteDocument[] => {
  try {
    const parsed: unknown = JSON.parse(window.localStorage.getItem(demoNotesKey) ?? '[]')
    return Array.isArray(parsed) ? parsed as NoteDocument[] : []
  } catch {
    return []
  }
}

const writeDemoNotes = (notes: NoteDocument[]) => {
  window.localStorage.setItem(demoNotesKey, JSON.stringify(notes))
}

const readDemoCapture = (): CaptureState => {
  try {
    const stored = window.localStorage.getItem(demoCaptureKey)
    return stored ? JSON.parse(stored) as CaptureState : hasEmptyDemoMode()
      ? { phase: 'idle', activeMeetingId: null, startedAt: null, message: null }
      : demoCapture
  } catch {
    return hasEmptyDemoMode()
      ? { phase: 'idle', activeMeetingId: null, startedAt: null, message: null }
      : demoCapture
  }
}

const writeDemoCapture = (capture: CaptureState) => {
  window.localStorage.setItem(demoCaptureKey, JSON.stringify(capture))
}

export const arcoBridge = {
  isDesktop: hasTauriRuntime,
  isDemo: hasExplicitDemoMode,

  async openDeepgramConsole(): Promise<void> {
    if (hasTauriRuntime()) {
      await invoke('open_deepgram_console')
      return
    }
    window.open('https://console.deepgram.com/', '_blank', 'noopener,noreferrer')
  },

  async openElevenLabsConsole(): Promise<void> {
    if (hasTauriRuntime()) {
      await invoke('open_elevenlabs_console')
      return
    }
    window.open('https://elevenlabs.io/app/developers/api-keys', '_blank', 'noopener,noreferrer')
  },

  async listMeetings(query = ''): Promise<MeetingSummary[]> {
    if (hasTauriRuntime()) {
      return invoke<MeetingSummary[]>('list_meetings', { query })
    }
    const needle = query.trim().toLocaleLowerCase()
    const meetings = hasEmptyDemoMode() && readDemoCapture().phase !== 'recording' ? [] : demoMeetings
    return meetings
      .map(withDemoMeetingOutput)
      .filter((meeting) =>
        `${meeting.title ?? ''} ${meeting.preview}`.toLocaleLowerCase().includes(needle),
      )
  },

  async readMeeting(id: string): Promise<MeetingDetail> {
    if (hasTauriRuntime()) {
      return invoke<MeetingDetail>('read_meeting', { id })
    }
    const meeting = demoMeetingDetails[id]
    if (!meeting) throw new Error('Meeting not found')
    return {
      ...meeting,
      summary: withDemoMeetingOutput(meeting.summary),
      lines: window.localStorage.getItem(demoTranscriptEmptyKey) === 'true' ? [] : meeting.lines,
    }
  },

  async storageSettings(): Promise<TranscriptStorageSettings> {
    if (hasTauriRuntime()) return invoke<TranscriptStorageSettings>('storage_settings')
    const selectedDirectory = window.localStorage.getItem(demoStorageKey) || demoDefaultTranscriptDirectory
    return {
      defaultDirectory: demoDefaultTranscriptDirectory,
      selectedDirectory,
      usingDefault: selectedDirectory === demoDefaultTranscriptDirectory,
    }
  },

  async notesStorageSettings(): Promise<NotesStorageSettings> {
    if (hasTauriRuntime()) return invoke<NotesStorageSettings>('notes_storage_settings')
    const selectedDirectory = window.localStorage.getItem(demoNotesStorageKey) || demoDefaultNotesDirectory
    return {
      defaultDirectory: demoDefaultNotesDirectory,
      selectedDirectory,
      usingDefault: selectedDirectory === demoDefaultNotesDirectory,
    }
  },

  async chooseTranscriptDirectory(title = 'Choose where Arco saves meeting transcripts'): Promise<string | null> {
    if (!hasTauriRuntime()) return '/Users/demo/Documents/Arco Meetings'
    const selected = await open({
      directory: true,
      multiple: false,
      title,
    })
    return typeof selected === 'string' ? selected : null
  },

  async chooseNotesDirectory(title = 'Choose where Arco saves Markdown notes'): Promise<string | null> {
    if (!hasTauriRuntime()) return '/Users/demo/Documents/Arco Notes'
    const selected = await open({ directory: true, multiple: false, title })
    return typeof selected === 'string' ? selected : null
  },

  async chooseAgentWorkspace(title = 'Choose Agent workspace'): Promise<string | null> {
    if (!hasTauriRuntime()) return '/Users/demo/Work/Arco'
    const selected = await open({
      directory: true,
      multiple: false,
      title,
    })
    return typeof selected === 'string' ? selected : null
  },

  async setTranscriptDirectory(directory: string | null): Promise<TranscriptStorageSettings> {
    if (hasTauriRuntime()) {
      return invoke<TranscriptStorageSettings>('set_transcript_directory', { directory })
    }
    if (directory) window.localStorage.setItem(demoStorageKey, directory)
    else window.localStorage.removeItem(demoStorageKey)
    return arcoBridge.storageSettings()
  },

  async setNotesDirectory(directory: string | null): Promise<NotesStorageSettings> {
    if (hasTauriRuntime()) return invoke<NotesStorageSettings>('set_notes_directory', { directory })
    if (directory) window.localStorage.setItem(demoNotesStorageKey, directory)
    else window.localStorage.removeItem(demoNotesStorageKey)
    return arcoBridge.notesStorageSettings()
  },

  async renameMeeting(meetingId: string, title: string | null): Promise<MeetingSummary> {
    if (hasTauriRuntime()) {
      return invoke<MeetingSummary>('rename_meeting', { meetingId, title })
    }
    const detail = demoMeetingDetails[meetingId]
    if (!detail) throw new Error('Meeting not found')
    const normalized = title?.trim() || null
    writeDemoMeetingOutput(meetingId, {
      title: normalized,
      titleGenerationStatus: 'ready',
    })
    return withDemoMeetingOutput(detail.summary)
  },

  async runtimeStatus(): Promise<RuntimeStatus[]> {
    if (hasTauriRuntime()) return invoke<RuntimeStatus[]>('runtime_status')
    return demoRuntimes
  },

  async testAgentProvider(provider: RuntimeStatus['provider']): Promise<ProviderConnectionTest> {
    if (hasTauriRuntime()) {
      return invoke<ProviderConnectionTest>('test_agent_provider', { provider })
    }
    if (hasExplicitDemoMode()) {
      return {
        provider,
        ok: true,
        message: provider === 'codex' ? 'Codex CLI is connected.' : 'Claude Code is connected.',
      }
    }
    return {
      provider,
      ok: false,
      message: 'Browser preview cannot test your local CLI. Open the Arco desktop app.',
    }
  },

  async generateMeetingOutput(input: GenerateMeetingOutputInput): Promise<MeetingOutputArtifact> {
    if (hasTauriRuntime()) {
      return invoke<MeetingOutputArtifact>('generate_meeting_output', {
        meetingId: input.meetingId,
        provider: input.provider,
        kind: input.kind,
        prompt: input.prompt,
      })
    }
    if (!hasExplicitDemoMode()) {
      throw new Error('Browser preview cannot call your local CLI. Open the Arco desktop app to generate meeting output.')
    }
    const value = input.kind === 'title'
      ? 'Product direction and meeting-native AI'
      : 'The decision is to keep Arco meeting-native, with transcript evidence beside the local CLI Agent.'
    const artifact: MeetingOutputArtifact = {
      kind: input.kind,
      status: 'ready',
      value,
      provider: input.provider,
      providerSessionId: null,
      providerTurnId: null,
      error: null,
      updatedAt: new Date().toISOString(),
    }
    writeDemoMeetingOutput(input.meetingId, input.kind === 'title'
      ? { title: value, titleGenerationStatus: 'ready' }
      : { generatedSummary: value, summaryGenerationStatus: 'ready' })
    return artifact
  },

  async captureStatus(): Promise<CaptureState> {
    if (hasTauriRuntime()) return invoke<CaptureState>('capture_status')
    return hasExplicitDemoMode() ? readDemoCapture() : demoCapture
  },

  async testAudioSetup(mode: AudioMode): Promise<AudioSetupCheck> {
    if (hasTauriRuntime()) return invoke<AudioSetupCheck>('test_audio_setup', { mode })
    if (!hasExplicitDemoMode()) {
      throw new Error('Open the Arco desktop app to check microphone and system audio.')
    }
    await wait(180)
    return {
      mode,
      success: true,
      system: {
        required: mode !== 'mic',
        ready: true,
        level: mode === 'mic' ? 0 : 0.46,
        message: null,
      },
      microphone: {
        required: mode !== 'system',
        ready: true,
        level: mode === 'system' ? 0 : 0.61,
        message: null,
      },
    }
  },

  async relaunchApp(): Promise<void> {
    if (hasTauriRuntime()) {
      await invoke('relaunch_app')
      return
    }
    window.location.reload()
  },

  async deepgramCredentialStatus(): Promise<DeepgramCredentialStatus> {
    if (hasTauriRuntime()) return invoke<DeepgramCredentialStatus>('deepgram_credential_status')
    const configured = window.sessionStorage.getItem(demoDeepgramConfiguredKey) === 'true'
    return { configured, verified: configured, message: null }
  },

  async saveDeepgramApiKey(apiKey: string): Promise<DeepgramCredentialStatus> {
    if (hasTauriRuntime()) {
      return invoke<DeepgramCredentialStatus>('save_deepgram_api_key', { apiKey })
    }
    if (apiKey.trim().length < 20 || /\s/.test(apiKey.trim())) {
      throw new Error('Paste a complete Deepgram API key.')
    }
    await wait(120)
    window.sessionStorage.setItem(demoDeepgramConfiguredKey, 'true')
    return { configured: true, verified: true, message: 'Deepgram is ready.' }
  },

  async removeDeepgramApiKey(): Promise<DeepgramCredentialStatus> {
    if (hasTauriRuntime()) return invoke<DeepgramCredentialStatus>('remove_deepgram_api_key')
    window.sessionStorage.removeItem(demoDeepgramConfiguredKey)
    return { configured: false, verified: false, message: null }
  },

  async elevenLabsCredentialStatus(): Promise<ElevenLabsCredentialStatus> {
    if (hasTauriRuntime()) return invoke<ElevenLabsCredentialStatus>('elevenlabs_credential_status')
    const configured = window.sessionStorage.getItem(demoElevenLabsConfiguredKey) === 'true'
    return { configured, verified: configured, message: null }
  },

  async saveElevenLabsApiKey(apiKey: string): Promise<ElevenLabsCredentialStatus> {
    if (hasTauriRuntime()) {
      return invoke<ElevenLabsCredentialStatus>('save_elevenlabs_api_key', { apiKey })
    }
    if (apiKey.trim().length < 20 || /\s/.test(apiKey.trim())) {
      throw new Error('Paste a complete ElevenLabs API key.')
    }
    await wait(120)
    window.sessionStorage.setItem(demoElevenLabsConfiguredKey, 'true')
    return { configured: true, verified: true, message: 'ElevenLabs is ready.' }
  },

  async removeElevenLabsApiKey(): Promise<ElevenLabsCredentialStatus> {
    if (hasTauriRuntime()) return invoke<ElevenLabsCredentialStatus>('remove_elevenlabs_api_key')
    window.sessionStorage.removeItem(demoElevenLabsConfiguredKey)
    return { configured: false, verified: false, message: null }
  },

  async startCapture(mode: AudioMode, transcription?: TranscriptionConfig): Promise<CaptureState> {
    if (hasTauriRuntime()) return invoke<CaptureState>('start_capture', { mode, transcription })
    await wait(250)
    const capture = {
      ...demoCapture,
      phase: 'recording' as const,
      mode,
      transcription: transcription ?? null,
      startedAt: new Date().toISOString(),
    }
    if (hasExplicitDemoMode()) writeDemoCapture(capture)
    return capture
  },

  async transcriptionModelStatus(): Promise<TranscriptionModelStatus[]> {
    if (hasTauriRuntime()) return invoke<TranscriptionModelStatus[]>('transcription_model_status')
    return hasExplicitDemoMode() ? readDemoTranscriptionModels() : demoTranscriptionModels
  },

  async prepareTranscriptionModel(model: LocalTranscriptionModelId | LocalDiarizationModelId): Promise<TranscriptionModelStatus[]> {
    if (hasTauriRuntime()) {
      return invoke<TranscriptionModelStatus[]>('prepare_transcription_model', { model })
    }
    if (hasExplicitDemoMode()) {
      await wait(120)
      const statuses = updateDemoTranscriptionModel(readDemoTranscriptionModels(), model, true)
      writeDemoTranscriptionModels(statuses)
      return statuses
    }
    throw new Error('Open the Arco desktop app to download on-device speech models.')
  },

  async removeTranscriptionModel(model: LocalTranscriptionModelId | LocalDiarizationModelId): Promise<TranscriptionModelStatus[]> {
    if (hasTauriRuntime()) {
      return invoke<TranscriptionModelStatus[]>('remove_transcription_model', { model })
    }
    if (hasExplicitDemoMode()) {
      const statuses = updateDemoTranscriptionModel(readDemoTranscriptionModels(), model, false)
      writeDemoTranscriptionModels(statuses)
      return statuses
    }
    throw new Error('Open the Arco desktop app to manage on-device speech models.')
  },

  async stopCapture(): Promise<CaptureState> {
    if (hasTauriRuntime()) return invoke<CaptureState>('stop_capture')
    await wait(250)
    const capture: CaptureState = { phase: 'idle', activeMeetingId: null, startedAt: null, message: null }
    if (hasExplicitDemoMode()) writeDemoCapture(capture)
    return capture
  },

  async toggleAgentOverlay(): Promise<boolean> {
    if (hasTauriRuntime()) return invoke<boolean>('toggle_agent_overlay')
    return true
  },

  async hideAgentOverlay(): Promise<void> {
    if (hasTauriRuntime()) await invoke('hide_agent_overlay')
  },

  async setAgentTranscriptVisible(visible: boolean): Promise<void> {
    if (hasTauriRuntime()) await invoke('set_agent_transcript_visible', { visible })
  },

  async focusMainWindow(): Promise<void> {
    if (hasTauriRuntime()) await invoke('focus_main_window')
  },

  async listAgentTurns(meetingId: string): Promise<PersistedAgentTurn[]> {
    if (hasTauriRuntime()) return invoke<PersistedAgentTurn[]>('list_agent_turns', { meetingId })
    if (!hasExplicitDemoMode()) return []
    return readDemoTurns().filter((turn) => turn.meetingId === meetingId)
  },

  async listSavedNotes(query = ''): Promise<SavedNote[]> {
    if (hasTauriRuntime()) return invoke<SavedNote[]>('list_saved_notes', { query })
    if (!hasExplicitDemoMode()) return []
    const needle = query.trim().toLocaleLowerCase()
    return readDemoTurns()
      .filter((turn) => turn.savedAsNote)
      .flatMap((turn) => {
        const summary = demoMeetings.find((meeting) => meeting.id === turn.meetingId)
        if (!summary) return []
        const meeting = withDemoMeetingOutput(summary)
        const searchable = `${meeting.title ?? ''}\n${turn.question}\n${turn.answer}`.toLocaleLowerCase()
        return needle && !searchable.includes(needle) ? [] : [{ meeting, turn }]
      })
      .sort((left, right) => {
        const leftTime = Date.parse(left.turn.createdAt)
        const rightTime = Date.parse(right.turn.createdAt)
        return (Number.isNaN(rightTime) ? 0 : rightTime) - (Number.isNaN(leftTime) ? 0 : leftTime)
      })
  },

  async listNotes(query = ''): Promise<NoteDocument[]> {
    if (hasTauriRuntime()) return invoke<NoteDocument[]>('list_notes', { query })
    if (!hasExplicitDemoMode()) return []
    const needle = query.trim().toLocaleLowerCase()
    return readDemoNotes()
      .filter((note) => !needle || `${note.title}\n${note.body}`.toLocaleLowerCase().includes(needle))
      .sort((left, right) => Date.parse(right.updatedAt) - Date.parse(left.updatedAt))
  },

  async saveNote(input: SaveNoteInput): Promise<NoteDocument> {
    if (hasTauriRuntime()) {
      return invoke<NoteDocument>('save_note', {
        noteId: input.id,
        meetingId: input.meetingId,
        title: input.title,
        body: input.body,
      })
    }
    if (!hasExplicitDemoMode()) throw new Error('Open the Arco desktop app to save Markdown notes.')
    const notes = readDemoNotes()
    const existing = input.id ? notes.find((note) => note.id === input.id) : undefined
    const now = new Date().toISOString()
    const note: NoteDocument = {
      id: existing?.id ?? `local:note-${Date.now()}.md`,
      title: input.title.trim(),
      body: input.body,
      source: existing?.source ?? 'manual',
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      path: existing?.path ?? `${demoDefaultNotesDirectory}/note-${Date.now()}.md`,
      meetingId: input.meetingId,
      meetingTitle: demoMeetings.find((meeting) => meeting.id === input.meetingId)?.title ?? existing?.meetingTitle ?? null,
      agentTurnId: existing?.agentTurnId ?? null,
    }
    writeDemoNotes([note, ...notes.filter((candidate) => candidate.id !== note.id)])
    return note
  },

  async deleteNote(noteId: string): Promise<void> {
    if (hasTauriRuntime()) return invoke<void>('delete_note', { noteId })
    if (!hasExplicitDemoMode()) throw new Error('Open the Arco desktop app to delete Markdown notes.')
    writeDemoNotes(readDemoNotes().filter((note) => note.id !== noteId))
  },

  async setAgentTurnSaved(meetingId: string, turnId: string, saved: boolean): Promise<PersistedAgentTurn> {
    if (hasTauriRuntime()) {
      return invoke<PersistedAgentTurn>('set_agent_turn_saved', { meetingId, turnId, saved })
    }
    if (!hasExplicitDemoMode()) {
      throw new Error('Browser preview cannot update Agent notes. Open the Arco desktop app.')
    }
    const turns = readDemoTurns()
    const index = turns.findIndex((turn) => turn.meetingId === meetingId && turn.id === turnId)
    if (index < 0) throw new Error('Agent turn not found')
    const noteId = saved ? `local:note-agent-${turnId}.md` : null
    const updated = { ...turns[index], savedAsNote: saved, noteId }
    turns[index] = updated
    writeDemoTurns(turns)
    if (saved) {
      const meeting = demoMeetings.find((candidate) => candidate.id === meetingId)
      const notes = readDemoNotes()
      if (!notes.some((note) => note.agentTurnId === turnId)) {
        const now = new Date().toISOString()
        writeDemoNotes([{
          id: noteId!,
          title: updated.question,
          body: updated.answer,
          source: 'agent',
          createdAt: now,
          updatedAt: now,
          path: `${demoDefaultNotesDirectory}/note-agent-${turnId}.md`,
          meetingId,
          meetingTitle: meeting?.title ?? null,
          agentTurnId: turnId,
        }, ...notes])
      }
    } else {
      writeDemoNotes(readDemoNotes().filter((note) => note.agentTurnId !== turnId))
    }
    return updated
  },

  async runAgent(
    input: AskAgentInput,
    onEvent: (event: AgentStreamEvent) => void = () => undefined,
  ): Promise<PersistedAgentTurn> {
    const requestId = input.requestId ?? createAgentRequestId()
    if (hasTauriRuntime()) {
      const eventChannel = new Channel<AgentStreamEvent>()
      eventChannel.onmessage = onEvent
      return invoke<PersistedAgentTurn>('run_agent', {
        provider: input.provider,
        usedFallback: input.usedFallback,
        question: input.question,
        agentPrompt: input.agentPrompt ?? null,
        meetingId: input.meetingId,
        workspace: input.workspace ?? null,
        contextScope: input.contextScope,
        requestId,
        onEvent: eventChannel,
      })
    }
    if (!hasExplicitDemoMode()) {
      throw new Error('Browser preview cannot call your local CLI. Open the Arco desktop app to ask Codex or Claude.')
    }
    onEvent({
      type: 'status',
      requestId,
      meetingId: input.meetingId,
      phase: 'analyzing',
    })
    await wait(500)
    const turn: PersistedAgentTurn = {
      ...demoAgentReply,
      id: `demo-turn-${Date.now()}-${Math.random().toString(16).slice(2)}`,
      meetingId: input.meetingId,
      providerSessionId: input.provider === 'codex'
        ? '019f4b7a-5d83-7a20-b14c-31920a30d9b8'
        : '63e72a19-dbc0-4954-b157-7df4f873b8ec',
      providerTurnId: input.provider === 'codex' ? 'item_demo' : 'msg_demo',
      provider: input.provider,
      question: input.question,
      contextScope: input.contextScope,
      sources: input.contextScope === 'workspace' && input.workspace
        ? [
            demoAgentReply.sources[0],
            {
              kind: 'workspace',
              label: `${workspaceName(input.workspace)} workspace`,
              reference: input.workspace,
            },
          ]
        : demoAgentReply.sources,
      savedAsNote: false,
      usedFallback: input.usedFallback,
      createdAt: new Date().toISOString(),
    }
    onEvent({
      type: 'answer',
      requestId,
      meetingId: input.meetingId,
      answer: turn.answer,
    })
    writeDemoTurns([...readDemoTurns(), turn])
    return turn
  },
}
