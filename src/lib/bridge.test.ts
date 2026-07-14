import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AskAgentInput, TranscriptionConfig } from '../types'
import { arcoBridge } from './bridge'

const invokeMock = vi.hoisted(() => vi.fn())
const openMock = vi.hoisted(() => vi.fn())
const channelHandlers = vi.hoisted(() => [] as Array<(event: unknown) => void>)

vi.mock('@tauri-apps/api/core', () => ({
  invoke: invokeMock,
  Channel: class {
    set onmessage(handler: (event: unknown) => void) {
      channelHandlers.push(handler)
    }
  },
}))
vi.mock('@tauri-apps/plugin-dialog', () => ({ open: openMock }))

const input: AskAgentInput = {
  provider: 'codex',
  usedFallback: false,
  question: 'What did we decide?',
  meetingId: 'demo-live',
  contextScope: 'transcript',
}

describe('browser Agent bridge', () => {
  beforeEach(() => {
    window.history.replaceState({}, '', '/')
  })

  it('never presents the fixed demo reply as a real CLI answer in the normal browser preview', async () => {
    expect(arcoBridge.isDemo()).toBe(false)

    await expect(arcoBridge.runAgent(input)).rejects.toThrow(
      'Browser preview cannot call your local CLI. Open the Arco desktop app to ask Codex or Claude.',
    )
    expect(window.localStorage.getItem('arco.demoAgentTurns')).toBeNull()
  })

  it('keeps deterministic fixture answers behind an explicit demo URL', async () => {
    window.history.replaceState({}, '', '/?demo=1')

    expect(arcoBridge.isDemo()).toBe(true)
    const reply = await arcoBridge.runAgent(input)

    expect(reply.question).toBe(input.question)
    expect(reply.provider).toBe('codex')
    expect(reply.usedFallback).toBe(false)
    expect(reply.meetingId).toBe(input.meetingId)
    expect(reply.answer).toContain('Arco becomes more than a recorder')
  })

  it('shows the selected workspace in the explicit demo answer receipt', async () => {
    window.history.replaceState({}, '', '/?demo=1')

    const reply = await arcoBridge.runAgent({
      ...input,
      contextScope: 'workspace',
      workspace: '/Users/example/Work/Arco',
    })

    expect(reply.sources).toEqual([
      expect.objectContaining({ kind: 'transcript' }),
      {
        kind: 'workspace',
        label: 'Arco workspace',
        reference: '/Users/example/Work/Arco',
      },
    ])
  })

  it('truthfully refuses to test a local CLI from a normal browser tab', async () => {
    const result = await arcoBridge.testAgentProvider('codex')

    expect(result).toEqual({
      provider: 'codex',
      ok: false,
      message: 'Browser preview cannot test your local CLI. Open the Arco desktop app.',
    })
  })

  it('opens the Deepgram console in a browser preview without navigating Arco away', async () => {
    const browserOpen = vi.spyOn(window, 'open').mockImplementation(() => null)

    await arcoBridge.openDeepgramConsole()

    expect(browserOpen).toHaveBeenCalledWith(
      'https://console.deepgram.com/',
      '_blank',
      'noopener,noreferrer',
    )
    browserOpen.mockRestore()
  })

  it('opens the ElevenLabs key page in a browser preview without navigating Arco away', async () => {
    const browserOpen = vi.spyOn(window, 'open').mockImplementation(() => null)

    await arcoBridge.openElevenLabsConsole()

    expect(browserOpen).toHaveBeenCalledWith(
      'https://elevenlabs.io/app/developers/api-keys',
      '_blank',
      'noopener,noreferrer',
    )
    browserOpen.mockRestore()
  })

  it('provides deterministic provider connection success only in explicit demo mode', async () => {
    window.history.replaceState({}, '', '/?demo=1')

    await expect(arcoBridge.testAgentProvider('claude')).resolves.toEqual({
      provider: 'claude',
      ok: true,
      message: 'Claude Code is connected.',
    })
  })

  it('models an explicit demo model download without touching the network', async () => {
    window.history.replaceState({}, '', '/?demo=1')

    const preparedAsr = await arcoBridge.prepareTranscriptionModel('whisper-base')
    const prepared = await arcoBridge.prepareTranscriptionModel('lseend-dihard3-streaming')

    expect(preparedAsr).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: 'whisper-base', installed: true, phase: 'ready' }),
    ]))
    expect(prepared).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: 'lseend-dihard3-streaming', installed: true, phase: 'ready' }),
    ]))

    const removed = await arcoBridge.removeTranscriptionModel('whisper-base')
    expect(removed).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: 'whisper-base', installed: false, phase: 'not-installed' }),
    ]))
  })

  it('keeps demo capture state consistent across start, status, and stop', async () => {
    window.history.replaceState({}, '', '/?surface=hud&demo=1')

    await arcoBridge.stopCapture()
    await expect(arcoBridge.captureStatus()).resolves.toMatchObject({ phase: 'idle' })

    const started = await arcoBridge.startCapture('both')
    await expect(arcoBridge.captureStatus()).resolves.toEqual(started)
  })

  it('does not pretend browser audio is a native setup check', async () => {
    await expect(arcoBridge.testAudioSetup('both')).rejects.toThrow(
      'Open the Arco desktop app to check microphone and system audio.',
    )
  })

  it('models only the audio lanes required by the explicit demo meeting mode', async () => {
    window.history.replaceState({}, '', '/?demo=1')

    await expect(arcoBridge.testAudioSetup('mic')).resolves.toEqual({
      mode: 'mic',
      success: true,
      system: { required: false, ready: true, level: 0, message: null },
      microphone: { required: true, ready: true, level: 0.61, message: null },
    })
  })

  it('never presents simulated meeting output as a real CLI result in a normal browser tab', async () => {
    await expect(arcoBridge.generateMeetingOutput({
      meetingId: 'demo-live',
      provider: 'codex',
      kind: 'title',
      prompt: 'Name this meeting.',
    })).rejects.toThrow('Browser preview cannot call your local CLI')
  })

  it('returns an explicit deterministic meeting output artifact only in demo mode', async () => {
    window.history.replaceState({}, '', '/?demo=1')

    const artifact = await arcoBridge.generateMeetingOutput({
      meetingId: 'demo-live',
      provider: 'claude',
      kind: 'summary',
      prompt: 'Lead with the decision.',
    })

    expect(artifact).toEqual({
      kind: 'summary',
      status: 'ready',
      value: expect.stringContaining('decision'),
      provider: 'claude',
      providerSessionId: null,
      providerTurnId: null,
      error: null,
      updatedAt: expect.any(String),
    })
    await expect(arcoBridge.readMeeting('demo-live')).resolves.toMatchObject({
      summary: {
        generatedSummary: artifact.value,
        summaryGenerationStatus: 'ready',
      },
    })
  })
})

describe('desktop meeting output bridge', () => {
  beforeEach(() => {
    Object.defineProperty(window, '__TAURI_INTERNALS__', { configurable: true, value: {} })
  })

  afterEach(() => {
    delete (window as Window & { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__
    invokeMock.mockReset()
    openMock.mockReset()
    channelHandlers.length = 0
  })

  it('persists the visible quick-action message while sending its detailed Agent prompt', async () => {
    invokeMock.mockResolvedValue({ question: 'Answer what was asked' })

    await arcoBridge.runAgent({
      ...input,
      question: 'Answer what was asked',
      agentPrompt: 'What is the strongest direct answer to the latest question in this meeting?',
    })

    expect(invokeMock).toHaveBeenCalledWith('run_agent', {
      provider: 'codex',
      usedFallback: false,
      question: 'Answer what was asked',
      agentPrompt: 'What is the strongest direct answer to the latest question in this meeting?',
      meetingId: 'demo-live',
      workspace: null,
      contextScope: 'transcript',
      requestId: expect.any(String),
      onEvent: expect.anything(),
    })
  })

  it('forwards native Agent process events to the caller before the invoke resolves', async () => {
    const onEvent = vi.fn()
    invokeMock.mockImplementation(async () => {
      channelHandlers.at(-1)?.({
        type: 'status',
        requestId: 'request-native',
        meetingId: 'demo-live',
        phase: 'analyzing',
      })
      return { question: input.question }
    })

    await arcoBridge.runAgent({ ...input, requestId: 'request-native' }, onEvent)

    expect(onEvent).toHaveBeenCalledWith({
      type: 'status',
      requestId: 'request-native',
      meetingId: 'demo-live',
      phase: 'analyzing',
    })
  })

  it('delegates the Deepgram console link to the native opener command', async () => {
    invokeMock.mockResolvedValue(undefined)

    await arcoBridge.openDeepgramConsole()

    expect(invokeMock).toHaveBeenCalledWith('open_deepgram_console')
  })

  it('passes the typed request through to the native command and returns its artifact', async () => {
    const artifact = {
      kind: 'title' as const,
      status: 'ready' as const,
      value: 'Native title',
      provider: 'codex' as const,
      providerSessionId: '019f4b00-1111-7000-8000-000000000001',
      providerTurnId: 'item-1',
      error: null,
      updatedAt: '2026-07-11T12:00:00+08:00',
    }
    invokeMock.mockResolvedValue(artifact)

    await expect(arcoBridge.generateMeetingOutput({
      meetingId: 'local:transcript-20260711-120000.md',
      provider: 'codex',
      kind: 'title',
      prompt: 'Use the decision.',
    })).resolves.toEqual(artifact)
    expect(invokeMock).toHaveBeenCalledWith('generate_meeting_output', {
      meetingId: 'local:transcript-20260711-120000.md',
      provider: 'codex',
      kind: 'title',
      prompt: 'Use the decision.',
    })
  })

  it('passes a manual title, including an explicit untitled value, to native storage', async () => {
    const summary = {
      id: 'local:transcript-20260711-120000.md',
      title: null,
      generatedSummary: null,
      titleGenerationStatus: 'ready',
      summaryGenerationStatus: 'idle',
      startedAt: '2026-07-11T12:00:00+08:00',
      durationLabel: '2 min',
      preview: 'Evidence',
      path: '/tmp/transcript.md',
      utteranceCount: 2,
      isLive: false,
      source: 'arco',
    }
    invokeMock.mockResolvedValue(summary)

    await expect(arcoBridge.renameMeeting(summary.id, null)).resolves.toEqual(summary)
    expect(invokeMock).toHaveBeenCalledWith('rename_meeting', {
      meetingId: summary.id,
      title: null,
    })
  })

  it('reads and changes the native transcript directory without fabricating browser state', async () => {
    const settings = {
      defaultDirectory: '/Users/name/Library/Application Support/Arco/transcripts',
      selectedDirectory: '/Volumes/Meetings/Arco',
      usingDefault: false,
    }
    invokeMock.mockResolvedValue(settings)

    await expect(arcoBridge.storageSettings()).resolves.toEqual(settings)
    expect(invokeMock).toHaveBeenLastCalledWith('storage_settings')

    await expect(arcoBridge.setTranscriptDirectory('/Volumes/Meetings/Arco')).resolves.toEqual(settings)
    expect(invokeMock).toHaveBeenLastCalledWith('set_transcript_directory', {
      directory: '/Volumes/Meetings/Arco',
    })
  })

  it('uses the native directory picker for an Agent workspace', async () => {
    openMock.mockResolvedValue('/Users/example/Work/Arco')

    await expect(arcoBridge.chooseAgentWorkspace('Choose Agent workspace')).resolves.toBe('/Users/example/Work/Arco')
    expect(openMock).toHaveBeenCalledWith({
      directory: true,
      multiple: false,
      title: 'Choose Agent workspace',
    })
  })
})

describe('desktop transcription bridge', () => {
  beforeEach(() => {
    Object.defineProperty(window, '__TAURI_INTERNALS__', { configurable: true, value: {} })
  })

  afterEach(() => {
    delete (window as Window & { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__
    invokeMock.mockReset()
  })

  it('passes the selected provider contract when capture starts', async () => {
    const transcription: TranscriptionConfig = {
      asr: { provider: 'local', model: 'nemotron-speech-3.5-streaming', language: 'zh-CN' },
      diarization: { provider: 'local', model: 'sortformer-streaming' },
    }
    invokeMock.mockResolvedValue({
      phase: 'recording',
      activeMeetingId: 'local:transcript-1.md',
      startedAt: '2026-07-11T12:00:00+08:00',
      message: 'Listening',
      mode: 'both',
      transcription,
    })

    await arcoBridge.startCapture('both', transcription)

    expect(invokeMock).toHaveBeenCalledWith('start_capture', { mode: 'both', transcription })
  })

  it('passes the reviewed meeting ID when capture continues an existing transcript', async () => {
    const transcription: TranscriptionConfig = {
      asr: { provider: 'local', model: 'nemotron-speech-3.5-streaming', language: 'zh-CN' },
      diarization: { provider: 'none', model: null },
    }
    invokeMock.mockResolvedValue({
      phase: 'recording',
      activeMeetingId: 'local:transcript-20260714-101500.md',
      startedAt: '2026-07-14T10:15:00+08:00',
      message: 'Listening',
    })

    await arcoBridge.startCapture(
      'both',
      transcription,
      'local:transcript-20260714-101500.md',
    )

    expect(invokeMock).toHaveBeenCalledWith('start_capture', {
      mode: 'both',
      transcription,
      meetingId: 'local:transcript-20260714-101500.md',
    })
  })

  it('keeps ElevenLabs credential operations behind native commands', async () => {
    const ready = { configured: true, verified: true, message: 'ElevenLabs is ready.' }
    const missing = { configured: false, verified: false, message: null }
    invokeMock
      .mockResolvedValueOnce(ready)
      .mockResolvedValueOnce(ready)
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce(missing)

    await expect(arcoBridge.elevenLabsCredentialStatus()).resolves.toEqual(ready)
    await expect(arcoBridge.saveElevenLabsApiKey('sk_0123456789abcdefghijklmnopqrstuvwxyz')).resolves.toEqual(ready)
    await expect(arcoBridge.openElevenLabsConsole()).resolves.toBeUndefined()
    await expect(arcoBridge.removeElevenLabsApiKey()).resolves.toEqual(missing)

    expect(invokeMock.mock.calls).toEqual([
      ['elevenlabs_credential_status'],
      ['save_elevenlabs_api_key', { apiKey: 'sk_0123456789abcdefghijklmnopqrstuvwxyz' }],
      ['open_elevenlabs_console'],
      ['remove_elevenlabs_api_key'],
    ])
  })

  it('runs the native audio setup check with the selected meeting mode', async () => {
    const result = {
      mode: 'system',
      success: true,
      system: { required: true, ready: true, level: 0.52, message: null },
      microphone: { required: false, ready: false, level: 0, message: null },
    }
    invokeMock.mockResolvedValue(result)

    await expect(arcoBridge.testAudioSetup('system')).resolves.toEqual(result)
    expect(invokeMock).toHaveBeenCalledWith('test_audio_setup', { mode: 'system' })
  })

  it('requests a native relaunch so onboarding can resume after permission changes', async () => {
    invokeMock.mockResolvedValue(undefined)

    await expect(arcoBridge.relaunchApp()).resolves.toBeUndefined()

    expect(invokeMock).toHaveBeenCalledWith('relaunch_app')
  })

  it('uses the local sidecar as the source of truth for model readiness', async () => {
    const models = [{
      id: 'whisper-base',
      installed: true,
      phase: 'ready',
      progress: 1,
      error: null,
      path: '/Users/example/Library/Application Support/Arco/models/whisper/ggml-base.bin',
    }]
    invokeMock.mockResolvedValue(models)

    await expect(arcoBridge.transcriptionModelStatus()).resolves.toEqual(models)
    expect(invokeMock).toHaveBeenCalledWith('transcription_model_status')
  })
})
