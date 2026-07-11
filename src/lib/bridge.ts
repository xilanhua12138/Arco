import { invoke } from '@tauri-apps/api/core'
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
  AudioMode,
  CaptureState,
  GenerateMeetingOutputInput,
  MeetingDetail,
  MeetingGenerationStatus,
  MeetingOutputArtifact,
  MeetingSummary,
  PersistedAgentTurn,
  ProviderConnectionTest,
  RuntimeStatus,
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
const demoMeetingOutputsKey = 'arco.demoMeetingOutputs'
const demoStorageKey = 'arco.demoTranscriptStorage'
const demoDefaultTranscriptDirectory = '/Users/demo/Library/Application Support/Arco/transcripts'

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
]

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
    return { ...meeting, summary: withDemoMeetingOutput(meeting.summary) }
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

  async chooseTranscriptDirectory(title = 'Choose where Arco saves meeting transcripts'): Promise<string | null> {
    if (!hasTauriRuntime()) return '/Users/demo/Documents/Arco Meetings'
    const selected = await open({
      directory: true,
      multiple: false,
      title,
    })
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
    return demoTranscriptionModels
  },

  async prepareTranscriptionModel(model: TranscriptionConfig['model'], includeDiarization: boolean): Promise<TranscriptionModelStatus[]> {
    if (hasTauriRuntime()) {
      return invoke<TranscriptionModelStatus[]>('prepare_transcription_model', { model, includeDiarization })
    }
    throw new Error('Open the Arco desktop app to download on-device speech models.')
  },

  async removeTranscriptionModel(model: TranscriptionConfig['model'] | 'sortformer-streaming'): Promise<TranscriptionModelStatus[]> {
    if (hasTauriRuntime()) {
      return invoke<TranscriptionModelStatus[]>('remove_transcription_model', { model })
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
    const updated = { ...turns[index], savedAsNote: saved }
    turns[index] = updated
    writeDemoTurns(turns)
    return updated
  },

  async runAgent(input: AskAgentInput): Promise<PersistedAgentTurn> {
    if (hasTauriRuntime()) {
      return invoke<PersistedAgentTurn>('run_agent', {
        provider: input.provider,
        usedFallback: input.usedFallback,
        question: input.question,
        meetingId: input.meetingId,
        workspace: input.workspace ?? null,
        contextScope: input.contextScope,
      })
    }
    if (!hasExplicitDemoMode()) {
      throw new Error('Browser preview cannot call your local CLI. Open the Arco desktop app to ask Codex or Claude.')
    }
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
    writeDemoTurns([...readDemoTurns(), turn])
    return turn
  },
}
