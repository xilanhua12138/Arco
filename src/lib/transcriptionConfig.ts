import type {
  DiarizationMode,
  LocalTranscriptionModelId,
  TranscriptionConfig,
  TranscriptionLanguage,
  TranscriptionModelId,
  TranscriptionProviderId,
} from '../types'

const storageKey = 'arco.transcriptionConfig'

export interface TranscriptionModelDescriptor {
  id: LocalTranscriptionModelId
  provider: 'local'
  label: string
  detail: string
  downloadSize: string
  streaming: boolean
  requiresAppleSilicon: boolean
}

export const transcriptionModels: TranscriptionModelDescriptor[] = [
  {
    id: 'nemotron-speech-3.5-streaming',
    provider: 'local',
    label: 'Nemotron Speech 3.5',
    detail: 'Ultra-fast multilingual streaming · Apple Neural Engine',
    downloadSize: '~670 MB',
    streaming: true,
    requiresAppleSilicon: true,
  },
  {
    id: 'whisper-tiny',
    provider: 'local',
    label: 'Whisper Tiny',
    detail: 'Fastest Whisper · lowest memory use',
    downloadSize: '~75 MB',
    streaming: false,
    requiresAppleSilicon: false,
  },
  {
    id: 'whisper-base',
    provider: 'local',
    label: 'Whisper Base',
    detail: 'Fast and lightweight',
    downloadSize: '~142 MB',
    streaming: false,
    requiresAppleSilicon: false,
  },
  {
    id: 'whisper-small',
    provider: 'local',
    label: 'Whisper Small',
    detail: 'Balanced local accuracy and speed',
    downloadSize: '~466 MB',
    streaming: false,
    requiresAppleSilicon: false,
  },
  {
    id: 'whisper-medium',
    provider: 'local',
    label: 'Whisper Medium',
    detail: 'Higher accuracy · heavier runtime',
    downloadSize: '~1.5 GB',
    streaming: false,
    requiresAppleSilicon: false,
  },
  {
    id: 'whisper-large',
    provider: 'local',
    label: 'Whisper Large',
    detail: 'Highest Whisper accuracy · highest memory use',
    downloadSize: '~2.9 GB',
    streaming: false,
    requiresAppleSilicon: false,
  },
]

const providers = new Set<TranscriptionProviderId>(['deepgram', 'local'])
const localModels = new Set<LocalTranscriptionModelId>(transcriptionModels.map((model) => model.id))
const languages = new Set<TranscriptionLanguage>(['auto', 'zh-CN', 'en-US'])
const diarizationModes = new Set<DiarizationMode>(['provider', 'local-streaming', 'none'])

export const defaultTranscriptionConfig = (): TranscriptionConfig => ({
  provider: 'deepgram',
  model: 'nova-3',
  language: 'zh-CN',
  diarization: 'provider',
})

const isValidConfig = (value: unknown): value is TranscriptionConfig => {
  if (!value || typeof value !== 'object') return false
  const candidate = value as Partial<TranscriptionConfig>
  if (!providers.has(candidate.provider as TranscriptionProviderId)) return false
  if (!languages.has(candidate.language as TranscriptionLanguage)) return false
  if (!diarizationModes.has(candidate.diarization as DiarizationMode)) return false
  if (candidate.provider === 'deepgram') {
    return candidate.model === 'nova-3' && candidate.diarization === 'provider'
  }
  return localModels.has(candidate.model as LocalTranscriptionModelId)
    && (candidate.diarization === 'local-streaming' || candidate.diarization === 'none')
}

export const loadTranscriptionConfig = (): TranscriptionConfig => {
  try {
    const parsed: unknown = JSON.parse(window.localStorage.getItem(storageKey) ?? 'null')
    return isValidConfig(parsed) ? parsed : defaultTranscriptionConfig()
  } catch {
    return defaultTranscriptionConfig()
  }
}

export const saveTranscriptionConfig = (config: TranscriptionConfig) => {
  if (!isValidConfig(config)) throw new Error('Invalid transcription configuration')
  window.localStorage.setItem(storageKey, JSON.stringify(config))
}

export const localModelDescriptor = (id: TranscriptionModelId) =>
  transcriptionModels.find((model) => model.id === id) ?? null

export const recognitionSummary = (config: TranscriptionConfig) => {
  if (config.provider === 'deepgram') return config.language === 'en-US' ? 'English' : 'Chinese'
  return localModelDescriptor(config.model)?.label ?? 'On-device'
}
