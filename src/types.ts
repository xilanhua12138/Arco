export type CapturePhase = 'idle' | 'starting' | 'recording' | 'stopping' | 'error'

export type ProviderId = 'codex' | 'claude'

export type ContextScope = 'transcript' | 'workspace'

export type MeetingGenerationStatus = 'idle' | 'ready' | 'failed'

export type MeetingOutputKind = 'title' | 'summary'

export interface MeetingSummary {
  id: string
  title: string | null
  generatedSummary: string | null
  titleGenerationStatus: MeetingGenerationStatus
  summaryGenerationStatus: MeetingGenerationStatus
  startedAt: string
  durationLabel: string
  preview: string
  path: string
  utteranceCount: number
  isLive: boolean
  source: 'arco' | 'legacy'
}

export interface TranscriptLine {
  id: string
  timestamp: string
  speaker: string
  text: string
  sequence: number
}

export interface MeetingDetail {
  summary: MeetingSummary
  lines: TranscriptLine[]
}

export interface TranscriptStorageSettings {
  defaultDirectory: string
  selectedDirectory: string
  usingDefault: boolean
}

export interface RuntimeStatus {
  provider: ProviderId
  available: boolean
  version: string | null
  path: string | null
}

export interface ProviderConnectionTest {
  provider: ProviderId
  ok: boolean
  message: string
}

export interface GenerateMeetingOutputInput {
  meetingId: string
  provider: ProviderId
  kind: MeetingOutputKind
  prompt: string
}

export interface MeetingOutputArtifact {
  kind: MeetingOutputKind
  status: Exclude<MeetingGenerationStatus, 'idle'>
  value: string | null
  provider: ProviderId | null
  providerSessionId: string | null
  providerTurnId: string | null
  error: string | null
  updatedAt: string
}

export interface CaptureState {
  phase: CapturePhase
  activeMeetingId: string | null
  startedAt: string | null
  message: string | null
  mode?: AudioMode | null
  transcriptPath?: string | null
  error?: string | null
  transcription?: TranscriptionConfig | null
}

export interface AgentSource {
  kind: 'transcript' | 'meeting' | 'workspace' | 'personal' | 'context'
  label: string
  reference: string
}

export interface AgentReply {
  provider: ProviderId
  answer: string
  sources: AgentSource[]
  createdAt: string
  contextScope?: ContextScope
}

export interface PersistedAgentTurn extends AgentReply {
  id: string
  meetingId: string
  providerSessionId?: string | null
  providerTurnId?: string | null
  question: string
  contextScope: ContextScope
  savedAsNote: boolean
  noteId?: string | null
  usedFallback: boolean
}

export interface SavedNote {
  meeting: MeetingSummary
  turn: PersistedAgentTurn
}

export interface NoteDocument {
  id: string
  title: string
  body: string
  source: 'manual' | 'agent'
  createdAt: string
  updatedAt: string
  path: string
  meetingId: string | null
  meetingTitle: string | null
  agentTurnId: string | null
}

export interface SaveNoteInput {
  id: string | null
  meetingId: string
  title: string
  body: string
}

export type NotesStorageSettings = TranscriptStorageSettings

export interface AskAgentInput {
  provider: ProviderId
  usedFallback: boolean
  question: string
  agentPrompt?: string
  meetingId: string
  workspace?: string
  contextScope: ContextScope
}

export type AudioMode = 'both' | 'system' | 'mic'

export interface AudioSourceCheck {
  required: boolean
  ready: boolean
  level: number | null
  message: string | null
}

export interface AudioSetupCheck {
  mode: AudioMode
  success: boolean
  system: AudioSourceCheck
  microphone: AudioSourceCheck
}

export type TranscriptionProviderId = 'deepgram' | 'local'

export type LocalTranscriptionModelId =
  | 'nemotron-speech-3.5-streaming'
  | 'whisper-tiny'
  | 'whisper-base'
  | 'whisper-small'
  | 'whisper-medium'
  | 'whisper-large'

export type TranscriptionModelId = 'nova-3' | LocalTranscriptionModelId

export type TranscriptionLanguage = 'auto' | 'zh-CN' | 'en-US'

export type DiarizationMode = 'provider' | 'local-streaming' | 'none'

export interface TranscriptionConfig {
  provider: TranscriptionProviderId
  model: TranscriptionModelId
  language: TranscriptionLanguage
  diarization: DiarizationMode
}

export type TranscriptionModelPhase =
  | 'not-installed'
  | 'downloading'
  | 'optimizing'
  | 'loading'
  | 'ready'
  | 'failed'

export interface TranscriptionModelStatus {
  id: LocalTranscriptionModelId | 'sortformer-streaming'
  installed: boolean
  phase: TranscriptionModelPhase
  progress: number | null
  error: string | null
  path: string | null
}

export interface DeepgramCredentialStatus {
  configured: boolean
  verified: boolean
  message: string | null
}
