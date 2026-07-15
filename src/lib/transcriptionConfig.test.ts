import { beforeEach, describe, expect, it } from 'vitest'
import {
  defaultTranscriptionConfig,
  loadTranscriptionConfig,
  recognitionSummary,
  saveTranscriptionConfig,
  transcriptionModels,
} from './transcriptionConfig'
import type { TranscriptionConfig } from '../types'

describe('transcription configuration', () => {
  beforeEach(() => window.localStorage.clear())

  it('keeps Deepgram as the migration-safe default', () => {
    expect(defaultTranscriptionConfig()).toEqual({
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
  })

  it.each([
    {
      name: 'remote ASR with local streaming diarization',
      config: {
        asr: { provider: 'elevenlabs', model: 'scribe-v2-realtime', language: 'auto' },
        diarization: { provider: 'local', model: 'sortformer-streaming' },
      },
    },
    {
      name: 'local ASR with remote streaming diarization',
      config: {
        asr: { provider: 'local', model: 'whisper-small', language: 'zh-CN' },
        diarization: { provider: 'deepgram', model: 'latest' },
      },
    },
    {
      name: 'local ASR with speaker separation disabled',
      config: {
        asr: { provider: 'local', model: 'nemotron-speech-3.5-streaming', language: 'en-US' },
        diarization: { provider: 'none', model: null },
      },
    },
  ] satisfies Array<{ name: string; config: TranscriptionConfig }>)('persists $name', ({ config }) => {
    saveTranscriptionConfig(config)
    expect(loadTranscriptionConfig()).toEqual(config)
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
    'pyannote-wespeaker-streaming',
    'lseend-ami-streaming',
    'lseend-dihard3-streaming',
  ] as const)('persists the %s local diarization backend', (diarization) => {
    const config = {
      asr: {
        provider: 'local' as const,
        model: 'whisper-small' as const,
        language: 'auto' as const,
      },
      diarization: {
        provider: 'local' as const,
        model: diarization,
      },
    }

    saveTranscriptionConfig(config)

    expect(loadTranscriptionConfig()).toEqual(config)
  })

  it('persists ElevenLabs as a distinct realtime provider without speaker diarization', () => {
    const config = {
      asr: {
        provider: 'elevenlabs' as const,
        model: 'scribe-v2-realtime' as const,
        language: 'auto' as const,
      },
      diarization: {
        provider: 'none' as const,
        model: null,
      },
    }

    saveTranscriptionConfig(config)

    expect(loadTranscriptionConfig()).toEqual(config)
  })

  it('persists Doubao BigModel as a cloud provider with independent diarization', () => {
    const config = {
      asr: {
        provider: 'doubao' as const,
        model: 'bigmodel' as const,
        language: 'zh-CN' as const,
      },
      diarization: {
        provider: 'local' as const,
        model: 'sortformer-streaming' as const,
      },
    }

    saveTranscriptionConfig(config)

    expect(loadTranscriptionConfig()).toEqual(config)
    expect(recognitionSummary(config)).toBe('Chinese')
  })

  it('accepts Doubao speaker separation as its own streaming provider', () => {
    const config = {
      asr: { provider: 'doubao' as const, model: 'bigmodel' as const, language: 'zh-CN' as const },
      diarization: { provider: 'doubao' as const, model: 'bigmodel' as const },
    }
    saveTranscriptionConfig(config)
    expect(loadTranscriptionConfig()).toEqual(config)
  })

  it('rejects a Doubao provider paired with a non-Doubao model', () => {
    window.localStorage.setItem('arco.transcriptionConfig', JSON.stringify({
      asr: { provider: 'doubao', model: 'nova-3', language: 'zh-CN' },
      diarization: { provider: 'none', model: null },
    }))

    expect(loadTranscriptionConfig()).toEqual(defaultTranscriptionConfig())
  })

  it('rejects provider/model mismatches without rejecting local and remote mixing', () => {
    window.localStorage.setItem('arco.transcriptionConfig', JSON.stringify({
      asr: { provider: 'elevenlabs', model: 'nova-3', language: 'zh-CN' },
      diarization: { provider: 'deepgram', model: 'sortformer-streaming' },
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
      asr: {
        provider: 'local',
        model: 'whisper-small',
        language: 'auto',
      },
      diarization: {
        provider: 'local',
        model: 'sortformer-streaming',
      },
    })
  })

  it('migrates provider-coupled Deepgram and ElevenLabs settings into independent providers', () => {
    window.localStorage.setItem('arco.transcriptionConfig', JSON.stringify({
      provider: 'deepgram',
      model: 'nova-3',
      language: 'zh-CN',
      diarization: 'provider',
    }))
    expect(loadTranscriptionConfig()).toEqual({
      asr: { provider: 'deepgram', model: 'nova-3', language: 'zh-CN' },
      diarization: { provider: 'deepgram', model: 'latest' },
    })

    window.localStorage.setItem('arco.transcriptionConfig', JSON.stringify({
      provider: 'elevenlabs',
      model: 'scribe-v2-realtime',
      language: 'auto',
      diarization: 'none',
    }))
    expect(loadTranscriptionConfig()).toEqual({
      asr: { provider: 'elevenlabs', model: 'scribe-v2-realtime', language: 'auto' },
      diarization: { provider: 'none', model: null },
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
