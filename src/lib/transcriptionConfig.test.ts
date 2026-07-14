import { beforeEach, describe, expect, it } from 'vitest'
import {
  defaultTranscriptionConfig,
  loadTranscriptionConfig,
  saveTranscriptionConfig,
  transcriptionModels,
} from './transcriptionConfig'

describe('transcription configuration', () => {
  beforeEach(() => window.localStorage.clear())

  it('keeps Deepgram as the migration-safe default', () => {
    expect(defaultTranscriptionConfig()).toEqual({
      provider: 'deepgram',
      model: 'nova-3',
      language: 'zh-CN',
      diarization: 'provider',
    })
  })

  it('publishes Nemotron and every requested Whisper size as local models', () => {
    expect(transcriptionModels.map((model) => model.id)).toEqual([
      'nemotron-speech-3.5-streaming',
      'whisper-tiny',
      'whisper-base',
      'whisper-small',
      'whisper-medium',
      'whisper-large',
    ])
    expect(transcriptionModels[0]).toMatchObject({
      provider: 'local',
      streaming: true,
      requiresAppleSilicon: true,
    })
  })

  it.each([
    'sortformer-streaming',
    'lseend-ami-streaming',
    'lseend-dihard3-streaming',
  ] as const)('persists the %s local diarization backend', (diarization) => {
    const config = {
      provider: 'local' as const,
      model: 'whisper-small' as const,
      language: 'auto' as const,
      diarization,
    }

    saveTranscriptionConfig(config)

    expect(loadTranscriptionConfig()).toEqual(config)
  })

  it('persists ElevenLabs as a distinct realtime provider without speaker diarization', () => {
    const config = {
      provider: 'elevenlabs' as const,
      model: 'scribe-v2-realtime' as const,
      language: 'auto' as const,
      diarization: 'none' as const,
    }

    saveTranscriptionConfig(config)

    expect(loadTranscriptionConfig()).toEqual(config)
  })

  it('rejects ElevenLabs configurations that claim provider or local diarization', () => {
    window.localStorage.setItem('arco.transcriptionConfig', JSON.stringify({
      provider: 'elevenlabs',
      model: 'scribe-v2-realtime',
      language: 'zh-CN',
      diarization: 'provider',
    }))

    expect(loadTranscriptionConfig()).toEqual(defaultTranscriptionConfig())
  })

  it('migrates the legacy local-streaming mode to Sortformer', () => {
    window.localStorage.setItem('arco.transcriptionConfig', JSON.stringify({
      provider: 'local',
      model: 'whisper-small',
      language: 'auto',
      diarization: 'local-streaming',
    }))

    expect(loadTranscriptionConfig()).toEqual({
      provider: 'local',
      model: 'whisper-small',
      language: 'auto',
      diarization: 'sortformer-streaming',
    })
  })

  it('rejects stale or impossible persisted combinations', () => {
    window.localStorage.setItem('arco.transcriptionConfig', JSON.stringify({
      provider: 'deepgram',
      model: 'whisper-large',
      language: 'klingon',
      diarization: 'local-streaming',
    }))

    expect(loadTranscriptionConfig()).toEqual(defaultTranscriptionConfig())
  })
})
