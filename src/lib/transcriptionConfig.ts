import type {
  DiarizationConfig,
  DiarizationProviderId,
  LocalDiarizationModelId,
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

export interface DiarizationModelDescriptor {
  id: LocalDiarizationModelId
  label: string
  detailKey:
    | 'settings.sortformerDescription'
    | 'settings.pyannoteStreamingDescription'
    | 'settings.lseendMeetingDescription'
    | 'settings.lseendGeneralDescription'
}

export const diarizationModels: DiarizationModelDescriptor[] = [
  { id: 'sortformer-streaming', label: 'Streaming Sortformer', detailKey: 'settings.sortformerDescription' },
  { id: 'pyannote-wespeaker-streaming', label: 'Pyannote + WeSpeaker', detailKey: 'settings.pyannoteStreamingDescription' },
  { id: 'lseend-ami-streaming', label: 'LS-EEND Meeting', detailKey: 'settings.lseendMeetingDescription' },
  { id: 'lseend-dihard3-streaming', label: 'LS-EEND General', detailKey: 'settings.lseendGeneralDescription' },
]

const providers = new Set<TranscriptionProviderId>(['deepgram', 'elevenlabs', 'doubao', 'local'])
const localModels = new Set<LocalTranscriptionModelId>(transcriptionModels.map((model) => model.id))
const languages = new Set<TranscriptionLanguage>(['auto', 'zh-CN', 'en-US'])
const localDiarizationModels = new Set<LocalDiarizationModelId>(diarizationModels.map((model) => model.id))
const diarizationProviders = new Set<DiarizationProviderId>(['deepgram', 'doubao', 'local', 'none'])

export const defaultTranscriptionConfig = (): TranscriptionConfig => ({
  asr: {
    provider: 'deepgram',
    model: 'nova-3',
    language: 'zh-CN',
  },
  diarization: {
    provider: 'deepgram',
    model: 'latest',
  },
})

export const isValidTranscriptionConfig = (value: unknown): value is TranscriptionConfig => {
  if (!value || typeof value !== 'object') return false
  const candidate = value as Partial<TranscriptionConfig>
  if (!candidate.asr || typeof candidate.asr !== 'object') return false
  if (!candidate.diarization || typeof candidate.diarization !== 'object') return false
  const asr = candidate.asr
  const diarization = candidate.diarization
  if (!providers.has(asr.provider as TranscriptionProviderId)) return false
  if (!languages.has(asr.language as TranscriptionLanguage)) return false
  if (!diarizationProviders.has(diarization.provider as DiarizationProviderId)) return false
  if (asr.provider === 'deepgram' && asr.model !== 'nova-3') return false
  if (asr.provider === 'elevenlabs' && asr.model !== 'scribe-v2-realtime') return false
  if (asr.provider === 'doubao' && asr.model !== 'bigmodel') return false
  if (asr.provider === 'local' && !localModels.has(asr.model as LocalTranscriptionModelId)) return false

  if (diarization.provider === 'deepgram') {
    return diarization.model === 'latest'
  }
  if (diarization.provider === 'doubao') {
    return diarization.model === 'bigmodel'
  }
  if (diarization.provider === 'local') {
    return localDiarizationModels.has(diarization.model as LocalDiarizationModelId)
  }
  return diarization.model === null
}

type LegacyTranscriptionConfig = {
  provider?: unknown
  model?: unknown
  language?: unknown
  diarization?: unknown
}

export const normalizeTranscriptionConfig = (value: unknown): TranscriptionConfig | null => {
  if (isValidTranscriptionConfig(value)) return value
  if (!value || typeof value !== 'object') return null
  const legacy = value as LegacyTranscriptionConfig
  if (!providers.has(legacy.provider as TranscriptionProviderId)) return null
  if (!languages.has(legacy.language as TranscriptionLanguage)) return null

  const rawDiarization = legacy.diarization === 'local-streaming'
    ? 'sortformer-streaming'
    : legacy.diarization
  let diarization: DiarizationConfig
  if (rawDiarization === 'provider' && legacy.provider === 'deepgram') {
    diarization = { provider: 'deepgram', model: 'latest' }
  } else if (localDiarizationModels.has(rawDiarization as LocalDiarizationModelId)) {
    diarization = { provider: 'local', model: rawDiarization as LocalDiarizationModelId }
  } else if (rawDiarization === 'none') {
    diarization = { provider: 'none', model: null }
  } else {
    return null
  }

  const migrated = {
    asr: {
      provider: legacy.provider,
      model: legacy.model,
      language: legacy.language,
    },
    diarization,
  }
  return isValidTranscriptionConfig(migrated) ? migrated : null
}

export const loadTranscriptionConfig = (): TranscriptionConfig => {
  try {
    const parsed: unknown = JSON.parse(window.localStorage.getItem(storageKey) ?? 'null')
    return normalizeTranscriptionConfig(parsed) ?? defaultTranscriptionConfig()
  } catch {
    return defaultTranscriptionConfig()
  }
}

export const saveTranscriptionConfig = (config: TranscriptionConfig) => {
  if (!isValidTranscriptionConfig(config)) throw new Error('Invalid transcription configuration')
  window.localStorage.setItem(storageKey, JSON.stringify(config))
}

export const localModelDescriptor = (id: TranscriptionModelId) =>
  transcriptionModels.find((model) => model.id === id) ?? null

export const recognitionSummary = (config: TranscriptionConfig) => {
  if (config.asr.provider === 'deepgram') return config.asr.language === 'en-US' ? 'English' : 'Chinese'
  if (config.asr.provider === 'elevenlabs') return config.asr.language === 'auto' ? 'Automatic' : config.asr.language === 'en-US' ? 'English' : 'Chinese'
  if (config.asr.provider === 'doubao') return config.asr.language === 'en-US' ? 'English' : config.asr.language === 'auto' ? 'Automatic' : 'Chinese'
  return localModelDescriptor(config.asr.model)?.label ?? 'On-device'
}
