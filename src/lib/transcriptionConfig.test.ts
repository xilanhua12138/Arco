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

  it('persists a local provider with streaming on-device diarization', () => {
    const config = {
      provider: 'local' as const,
      model: 'whisper-small' as const,
      language: 'auto' as const,
      diarization: 'local-streaming' as const,
    }

    saveTranscriptionConfig(config)

    expect(loadTranscriptionConfig()).toEqual(config)
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
