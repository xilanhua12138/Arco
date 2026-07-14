import { act, renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DEFAULT_SUMMARY_PROMPT, DEFAULT_TITLE_PROMPT } from '../lib/generationSettings'
import { demoAgentReply, demoCapture, demoMeetingDetails, demoMeetings, demoRuntimes } from '../lib/demoData'
import { arcoBridge } from '../lib/bridge'
import type { MeetingDetail, MeetingSummary, NoteDocument } from '../types'
import { useArco } from './useArco'

const eventListeners = vi.hoisted(() => new Map<string, (event: { payload: string }) => void>())
const listenMock = vi.hoisted(() => vi.fn())

vi.mock('@tauri-apps/api/event', () => ({ listen: listenMock }))

const providerConfig = {
  setupComplete: true,
  primary: 'codex',
  secondary: 'claude',
}

const generationSettings = {
  title: { enabled: true, promptOverride: null },
  summary: { enabled: true, promptOverride: null },
}

const meetingWith = (
  lineCount: number,
  overrides: Partial<MeetingSummary> = {},
): MeetingDetail => ({
  ...demoMeetingDetails['demo-live'],
  summary: {
    ...demoMeetingDetails['demo-live'].summary,
    title: null,
    generatedSummary: null,
    titleGenerationStatus: 'idle',
    summaryGenerationStatus: 'idle',
    utteranceCount: lineCount,
    ...overrides,
  },
  lines: demoMeetingDetails['demo-live'].lines.slice(0, lineCount),
})

const outputArtifact = (kind: 'title' | 'summary', value: string) => ({
  kind,
  status: 'ready' as const,
  value,
  provider: 'codex' as const,
  providerSessionId: null,
  providerTurnId: null,
  error: null,
  updatedAt: '2026-07-11T12:00:00+08:00',
})

const mockMeetingBackend = (
  detail: ReturnType<typeof meetingWith>,
  capture = demoCapture,
) => {
  vi.spyOn(arcoBridge, 'listMeetings').mockResolvedValue([detail.summary])
  vi.spyOn(arcoBridge, 'runtimeStatus').mockResolvedValue(demoRuntimes)
  vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(capture)
  vi.spyOn(arcoBridge, 'readMeeting').mockResolvedValue(detail)
  vi.spyOn(arcoBridge, 'listAgentTurns').mockResolvedValue([])
}

describe('useArco automatic meeting output', () => {
  beforeEach(() => {
    window.history.replaceState({}, '', '/?demo=1')
    window.localStorage.setItem('arco.providerConfig', JSON.stringify(providerConfig))
    window.localStorage.setItem('arco.generationSettings', JSON.stringify(generationSettings))
    eventListeners.clear()
    listenMock.mockReset()
    listenMock.mockImplementation(async (event: string, listener: (payload: { payload: string }) => void) => {
      eventListeners.set(event, listener)
      return vi.fn()
    })
  })

  afterEach(() => {
    delete (window as Window & { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__
  })

  it('does not generate a live title at N-1 finalized transcript lines', async () => {
    const meeting = meetingWith(5)
    mockMeetingBackend(meeting)
    const generate = vi.spyOn(arcoBridge, 'generateMeetingOutput').mockResolvedValue(
      outputArtifact('title', 'Should not be used'),
    )

    const { result } = renderHook(() => useArco())
    await waitFor(() => expect(result.current.loading).toBe(false))
    await act(async () => { await Promise.resolve() })

    expect(result.current.meeting?.lines).toHaveLength(5)
    expect(generate).not.toHaveBeenCalled()
  })

  it('generates one live title at N finalized transcript lines', async () => {
    const meeting = meetingWith(6)
    mockMeetingBackend(meeting)
    const generate = vi.spyOn(arcoBridge, 'generateMeetingOutput').mockResolvedValue(
      outputArtifact('title', 'Agent-native meeting output'),
    )

    const { result } = renderHook(() => useArco())
    await waitFor(() => expect(result.current.loading).toBe(false))
    await waitFor(() => expect(generate).toHaveBeenCalledTimes(1))

    expect(generate).toHaveBeenCalledWith({
      meetingId: meeting.summary.id,
      provider: 'codex',
      kind: 'title',
      prompt: DEFAULT_TITLE_PROMPT,
    })
  })

  it('does not regenerate a live title at N+1 finalized transcript lines', async () => {
    const meeting = meetingWith(7)
    mockMeetingBackend(meeting)
    const generate = vi.spyOn(arcoBridge, 'generateMeetingOutput').mockResolvedValue(
      outputArtifact('title', 'Agent-native meeting output'),
    )

    const { result } = renderHook(() => useArco())
    await waitFor(() => expect(result.current.loading).toBe(false))
    await waitFor(() => expect(generate).toHaveBeenCalledTimes(1))
    await act(async () => { await Promise.resolve(); await Promise.resolve() })

    expect(generate).toHaveBeenCalledTimes(1)
  })

  it('reads prompt settings and the current primary route when the threshold is actually crossed', async () => {
    const beforeThreshold = meetingWith(5)
    const atThreshold = meetingWith(6)
    let poll!: () => void
    const nativeSetInterval = window.setInterval
    vi.spyOn(window, 'setInterval').mockImplementation(((handler: TimerHandler, timeout?: number, ...args: unknown[]) => {
      if (timeout === 1_200) {
        poll = typeof handler === 'function' ? handler as () => void : () => undefined
        return 1
      }
      return nativeSetInterval(handler, timeout, ...args)
    }) as typeof window.setInterval)
    vi.spyOn(arcoBridge, 'listMeetings').mockResolvedValue([beforeThreshold.summary])
    vi.spyOn(arcoBridge, 'runtimeStatus').mockResolvedValue([
      { provider: 'codex', available: false, version: null, path: null },
      { provider: 'claude', available: true, version: 'claude 1', path: '/bin/claude' },
    ])
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(demoCapture)
    vi.spyOn(arcoBridge, 'readMeeting')
      .mockResolvedValueOnce(beforeThreshold)
      .mockResolvedValue(atThreshold)
    vi.spyOn(arcoBridge, 'listAgentTurns').mockResolvedValue([])
    const generate = vi.spyOn(arcoBridge, 'generateMeetingOutput').mockResolvedValue(
      { ...outputArtifact('title', 'A routed title'), provider: 'claude' },
    )

    const { result } = renderHook(() => useArco())
    await waitFor(() => expect(result.current.loading).toBe(false))
    await waitFor(() => expect(poll).toBeTypeOf('function'))
    window.localStorage.setItem('arco.generationSettings', JSON.stringify({
      title: { enabled: true, promptOverride: 'Use the unresolved decision as the title.' },
      summary: { enabled: true, promptOverride: null },
    }))

    await act(async () => { await poll() })
    await waitFor(() => expect(generate).toHaveBeenCalledTimes(1))

    expect(generate).toHaveBeenCalledWith({
      meetingId: atThreshold.summary.id,
      provider: 'claude',
      kind: 'title',
      prompt: 'Use the unresolved decision as the title.',
    })
  })

  it('returns capture to idle without awaiting summary and then serializes title before summary', async () => {
    const live = meetingWith(5)
    const finalized = meetingWith(6, { isLive: false })
    let stopped = false
    mockMeetingBackend(live)
    vi.spyOn(arcoBridge, 'listMeetings').mockImplementation(async () => [stopped ? finalized.summary : live.summary])
    vi.spyOn(arcoBridge, 'readMeeting').mockImplementation(async () => stopped ? finalized : live)
    vi.spyOn(arcoBridge, 'stopCapture').mockImplementation(async () => {
      stopped = true
      return { phase: 'idle', activeMeetingId: null, startedAt: null, message: 'Saved' }
    })
    let resolveTitle!: (artifact: ReturnType<typeof outputArtifact>) => void
    const title = new Promise<ReturnType<typeof outputArtifact>>((resolve) => { resolveTitle = resolve })
    const generate = vi.spyOn(arcoBridge, 'generateMeetingOutput').mockImplementation(async (input) => {
      if (input.kind === 'title') return title
      return outputArtifact('summary', 'Decision first. One action remains.')
    })

    const { result } = renderHook(() => useArco())
    await waitFor(() => expect(result.current.loading).toBe(false))

    let stopPromise!: Promise<unknown>
    act(() => { stopPromise = result.current.toggleCapture() })
    const settled = await Promise.race([
      stopPromise.then(() => 'settled'),
      new Promise<string>((resolve) => window.setTimeout(() => resolve('blocked'), 150)),
    ])

    expect(settled).toBe('settled')
    await act(async () => { await stopPromise })
    expect(result.current.capture.phase).toBe('idle')
    await waitFor(() => expect(generate).toHaveBeenCalledTimes(1))
    expect(generate.mock.calls[0][0]).toMatchObject({ kind: 'title', prompt: DEFAULT_TITLE_PROMPT })

    await act(async () => { resolveTitle(outputArtifact('title', 'Short final meeting')); await title })
    await waitFor(() => expect(generate).toHaveBeenCalledTimes(2))
    expect(generate.mock.calls[1][0]).toMatchObject({ kind: 'summary', prompt: DEFAULT_SUMMARY_PROMPT })
  })

  it('waits for an already-running live title before starting the stopped-meeting summary', async () => {
    const live = meetingWith(6)
    const finalized = meetingWith(7, { isLive: false })
    let stopped = false
    mockMeetingBackend(live)
    vi.spyOn(arcoBridge, 'listMeetings').mockImplementation(async () => [stopped ? finalized.summary : live.summary])
    vi.spyOn(arcoBridge, 'readMeeting').mockImplementation(async () => stopped ? finalized : live)
    vi.spyOn(arcoBridge, 'stopCapture').mockImplementation(async () => {
      stopped = true
      return { phase: 'idle', activeMeetingId: null, startedAt: null, message: 'Saved' }
    })
    let resolveTitle!: (artifact: ReturnType<typeof outputArtifact>) => void
    const title = new Promise<ReturnType<typeof outputArtifact>>((resolve) => { resolveTitle = resolve })
    const generate = vi.spyOn(arcoBridge, 'generateMeetingOutput').mockImplementation(async (input) => {
      if (input.kind === 'title') return title
      return outputArtifact('summary', 'Summary after the title.')
    })

    const { result } = renderHook(() => useArco())
    await waitFor(() => expect(generate).toHaveBeenCalledTimes(1))
    expect(generate.mock.calls[0][0].kind).toBe('title')

    await act(async () => { await result.current.toggleCapture() })
    await act(async () => { await Promise.resolve() })
    expect(result.current.capture.phase).toBe('idle')
    expect(generate).toHaveBeenCalledTimes(1)

    await act(async () => { resolveTitle(outputArtifact('title', 'Resolved live title')); await title })
    await waitFor(() => expect(generate).toHaveBeenCalledTimes(2))
    expect(generate.mock.calls[1][0].kind).toBe('summary')
  })

  it('skips title but still summarizes a nonempty meeting stopped below the title threshold', async () => {
    const live = meetingWith(1)
    const finalized = meetingWith(2, { isLive: false })
    let stopped = false
    mockMeetingBackend(live)
    vi.spyOn(arcoBridge, 'listMeetings').mockImplementation(async () => [stopped ? finalized.summary : live.summary])
    vi.spyOn(arcoBridge, 'readMeeting').mockImplementation(async () => stopped ? finalized : live)
    vi.spyOn(arcoBridge, 'stopCapture').mockImplementation(async () => {
      stopped = true
      return { phase: 'idle', activeMeetingId: null, startedAt: null, message: 'Saved' }
    })
    const generate = vi.spyOn(arcoBridge, 'generateMeetingOutput').mockResolvedValue(
      outputArtifact('summary', 'A short but nonempty meeting.'),
    )

    const { result } = renderHook(() => useArco())
    await waitFor(() => expect(result.current.loading).toBe(false))
    await act(async () => { await result.current.toggleCapture() })
    await waitFor(() => expect(generate).toHaveBeenCalledTimes(1))

    expect(generate.mock.calls[0][0]).toMatchObject({ kind: 'summary' })
  })

  it('keeps automatic generation failure nonfatal and refreshes persisted status', async () => {
    const meeting = meetingWith(6)
    mockMeetingBackend(meeting)
    const readMeeting = vi.spyOn(arcoBridge, 'readMeeting').mockResolvedValue(meeting)
    const listMeetings = vi.spyOn(arcoBridge, 'listMeetings').mockResolvedValue([meeting.summary])
    const generate = vi.spyOn(arcoBridge, 'generateMeetingOutput').mockResolvedValue({
      ...outputArtifact('title', 'unused'),
      status: 'failed',
      value: null,
      provider: null,
      error: 'CLI timed out',
    })
    const warning = vi.spyOn(console, 'warn').mockImplementation(() => undefined)

    const { result } = renderHook(() => useArco())
    await waitFor(() => expect(generate).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(warning).toHaveBeenCalled())

    expect(result.current.capture.phase).toBe('recording')
    expect(result.current.error).toBeNull()
    expect(generate).toHaveBeenCalledTimes(1)
    expect(readMeeting.mock.calls.length).toBeGreaterThanOrEqual(2)
    expect(listMeetings.mock.calls.length).toBeGreaterThanOrEqual(2)
  })

  it('refreshes list and selected meeting on output events without reloading Agent turns', async () => {
    Object.defineProperty(window, '__TAURI_INTERNALS__', { configurable: true, value: {} })
    const pending = meetingWith(5)
    const ready = meetingWith(5, {
      title: 'A generated title',
      generatedSummary: 'A generated summary',
      titleGenerationStatus: 'ready',
      summaryGenerationStatus: 'ready',
    })
    let enriched = false
    vi.spyOn(arcoBridge, 'listMeetings').mockImplementation(async () => [enriched ? ready.summary : pending.summary])
    vi.spyOn(arcoBridge, 'runtimeStatus').mockResolvedValue(demoRuntimes)
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue({
      phase: 'idle', activeMeetingId: null, startedAt: null, message: null,
    })
    vi.spyOn(arcoBridge, 'readMeeting').mockImplementation(async () => enriched ? ready : pending)
    const listTurns = vi.spyOn(arcoBridge, 'listAgentTurns').mockResolvedValue([demoAgentReply])
    vi.spyOn(arcoBridge, 'generateMeetingOutput').mockResolvedValue(outputArtifact('title', 'unused'))

    const { result, unmount } = renderHook(() => useArco())
    await waitFor(() => expect(result.current.loading).toBe(false))
    await waitFor(() => expect(eventListeners.has('arco:meeting-output-changed')).toBe(true))
    expect(result.current.agentReplies).toEqual([demoAgentReply])

    enriched = true
    await act(async () => {
      eventListeners.get('arco:meeting-output-changed')?.({ payload: pending.summary.id })
    })
    await waitFor(() => expect(result.current.meeting?.summary.title).toBe('A generated title'))

    expect(result.current.meeting?.summary.generatedSummary).toBe('A generated summary')
    expect(result.current.agentReplies).toEqual([demoAgentReply])
    expect(listTurns).toHaveBeenCalledTimes(1)
    unmount()
  })
})

describe('useArco cross-window capture synchronization', () => {
  it('force-reads the stopped meeting so transcript lines flushed by the HUD are not lost', async () => {
    const initial = {
      ...demoMeetingDetails['demo-live'],
      lines: demoMeetingDetails['demo-live'].lines.slice(0, 1),
    }
    const finalized = {
      ...demoMeetingDetails['demo-live'],
      lines: demoMeetingDetails['demo-live'].lines.slice(0, 2),
    }
    vi.spyOn(arcoBridge, 'listMeetings').mockResolvedValue(demoMeetings)
    vi.spyOn(arcoBridge, 'runtimeStatus').mockResolvedValue(demoRuntimes)
    vi.spyOn(arcoBridge, 'listAgentTurns').mockResolvedValue([])
    vi.spyOn(arcoBridge, 'captureStatus')
      .mockResolvedValueOnce(demoCapture)
      .mockResolvedValueOnce({ phase: 'idle', activeMeetingId: null, startedAt: null, message: null })
    const readMeeting = vi.spyOn(arcoBridge, 'readMeeting')
      .mockResolvedValueOnce(initial)
      .mockResolvedValue(finalized)

    const { result } = renderHook(() => useArco())
    await waitFor(() => expect(result.current.loading).toBe(false))
    expect(result.current.meeting?.lines).toHaveLength(1)

    await act(async () => {
      await result.current.syncCapture()
    })

    expect(readMeeting).toHaveBeenCalledTimes(2)
    expect(result.current.meeting?.lines).toHaveLength(2)
    expect(result.current.capture.phase).toBe('idle')
    expect(result.current.completedMeetingId).toBe(finalized.summary.id)
  })
})

describe('useArco saved note refreshes', () => {
  it('keeps the newest query result when an older request resolves last', async () => {
    const detail = meetingWith(2)
    mockMeetingBackend(detail)
    const note = (id: string, title: string): NoteDocument => ({
      id,
      title,
      body: `${title} body`,
      source: 'manual',
      createdAt: '2026-07-14T10:00:00+08:00',
      updatedAt: '2026-07-14T10:00:00+08:00',
      path: `/tmp/${id}.md`,
      meetingId: null,
      meetingTitle: null,
      agentTurnId: null,
    })
    let resolveOld!: (notes: NoteDocument[]) => void
    let resolveNew!: (notes: NoteDocument[]) => void
    const oldRequest = new Promise<NoteDocument[]>((resolve) => { resolveOld = resolve })
    const newRequest = new Promise<NoteDocument[]>((resolve) => { resolveNew = resolve })
    vi.spyOn(arcoBridge, 'listNotes').mockImplementation(async (query) => {
      if (query === 'old') return oldRequest
      if (query === 'new') return newRequest
      return []
    })

    const { result } = renderHook(() => useArco())
    await waitFor(() => expect(result.current.loading).toBe(false))

    let oldRefresh!: Promise<NoteDocument[]>
    let newRefresh!: Promise<NoteDocument[]>
    act(() => {
      oldRefresh = result.current.refreshSavedNotes('old')
      newRefresh = result.current.refreshSavedNotes('new')
    })
    expect(result.current.notesLoading).toBe(true)

    await act(async () => {
      resolveNew([note('new-note', 'Newest result')])
      await newRefresh
    })
    expect(result.current.savedNotes.map((item) => item.id)).toEqual(['new-note'])
    expect(result.current.notesLoading).toBe(false)

    await act(async () => {
      resolveOld([note('old-note', 'Stale result')])
      await oldRefresh
    })
    expect(result.current.savedNotes.map((item) => item.id)).toEqual(['new-note'])
    expect(result.current.notesLoading).toBe(false)
  })
})

describe('useArco Agent process streaming', () => {
  it('exposes status and answer snapshots before committing the persisted turn', async () => {
    const detail = meetingWith(2)
    mockMeetingBackend(detail)
    let pushEvent!: (event: {
      type: 'status' | 'answer'
      requestId: string
      meetingId: string
      phase?: 'starting' | 'analyzing' | 'using-tools' | 'finalizing'
      answer?: string
    }) => void
    let finishRun!: () => void
    const completedTurn = {
      ...demoAgentReply,
      id: 'persisted-stream-turn',
      meetingId: detail.summary.id,
      question: 'What did we decide?',
      answer: 'The persisted final answer.',
    }
    vi.spyOn(arcoBridge, 'runAgent').mockImplementation((input, onEvent) => new Promise((resolve) => {
      expect(onEvent).toEqual(expect.any(Function))
      pushEvent = onEvent!
      finishRun = () => resolve(completedTurn)
      expect(input.requestId).toEqual(expect.any(String))
    }))

    const { result } = renderHook(() => useArco())
    await waitFor(() => expect(result.current.loading).toBe(false))

    let askPromise!: Promise<boolean>
    act(() => {
      askPromise = result.current.askAgent({
        provider: 'codex',
        usedFallback: false,
        question: 'What did we decide?',
        meetingId: detail.summary.id,
        contextScope: 'transcript',
      })
    })
    await waitFor(() => expect(result.current.agentRunning).toBe(true))
    const requestId = result.current.agentStreamingTurn?.requestId
    expect(requestId).toEqual(expect.any(String))

    act(() => {
      pushEvent({
        type: 'status',
        requestId: requestId!,
        meetingId: detail.summary.id,
        phase: 'using-tools',
      })
      pushEvent({
        type: 'answer',
        requestId: requestId!,
        meetingId: detail.summary.id,
        answer: 'A completed intermediate Codex message.',
      })
      pushEvent({
        type: 'answer',
        requestId: 'stale-request',
        meetingId: detail.summary.id,
        answer: 'This stale request must not replace the live answer.',
      })
      pushEvent({
        type: 'answer',
        requestId: requestId!,
        meetingId: 'another-meeting',
        answer: 'This other meeting must not replace the live answer.',
      })
    })

    expect(result.current.agentStreamingTurn).toMatchObject({
      phase: 'using-tools',
      answer: 'A completed intermediate Codex message.',
    })
    expect(result.current.agentReplies).toEqual([])

    await act(async () => {
      finishRun()
      await askPromise
    })

    expect(result.current.agentStreamingTurn).toBeNull()
    expect(result.current.agentReplies).toEqual([completedTurn])
  })
})
