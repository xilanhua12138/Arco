import { useCallback, useEffect, useRef, useState } from 'react'
import { listen } from '@tauri-apps/api/event'
import { arcoBridge } from '../lib/bridge'
import {
  DEFAULT_SUMMARY_PROMPT,
  DEFAULT_TITLE_PROMPT,
  loadGenerationSettings,
} from '../lib/generationSettings'
import { loadProviderConfig, resolveProviderRoute } from '../lib/providerConfig'
import type {
  AskAgentInput,
  AgentStreamingTurn,
  AgentStreamEvent,
  AudioMode,
  CaptureState,
  MeetingDetail,
  MeetingOutputKind,
  MeetingSummary,
  NoteDocument,
  PersistedAgentTurn,
  SaveNoteInput,
  RuntimeStatus,
  TranscriptionConfig,
} from '../types'
import { useI18n } from '../i18n/i18n'

const idleCapture: CaptureState = {
  phase: 'idle',
  activeMeetingId: null,
  startedAt: null,
  message: null,
}

const TITLE_GENERATION_LINE_THRESHOLD = 6

export function useArco() {
  const { t } = useI18n()
  const [meetings, setMeetings] = useState<MeetingSummary[]>([])
  const [activeMeeting, setActiveMeeting] = useState<MeetingSummary | null>(null)
  const [selectedMeetingId, setSelectedMeetingId] = useState<string | null>(null)
  const [meeting, setMeeting] = useState<MeetingDetail | null>(null)
  const [runtimes, setRuntimes] = useState<RuntimeStatus[]>([])
  const [capture, setCapture] = useState<CaptureState>(idleCapture)
  const [agentTurnsByMeeting, setAgentTurnsByMeeting] = useState<Record<string, PersistedAgentTurn[]>>({})
  const [savedNotes, setSavedNotes] = useState<NoteDocument[]>([])
  const [notesLoading, setNotesLoading] = useState(false)
  const [loading, setLoading] = useState(true)
  const [agentRunning, setAgentRunning] = useState(false)
  const [agentStreamingTurn, setAgentStreamingTurn] = useState<AgentStreamingTurn | null>(null)
  const [error, setError] = useState<string | null>(null)
  const selectedRef = useRef<string | null>(null)
  const activeCaptureRef = useRef<string | null>(null)
  const meetingRef = useRef<MeetingDetail | null>(null)
  const meetingQueryRef = useRef('')
  const noteQueryRef = useRef('')
  const generationClaimsRef = useRef(new Map<string, Promise<void>>())
  const selectionRequestRef = useRef(0)

  const selectMeeting = useCallback(async (id: string) => {
    const request = ++selectionRequestRef.current
    setError(null)
    try {
      const next = await arcoBridge.readMeeting(id)
      let turns: PersistedAgentTurn[] = []
      let threadError: string | null = null
      try {
        turns = await arcoBridge.listAgentTurns(id)
      } catch (cause) {
        threadError = cause instanceof Error ? cause.message : t('error.loadAgentThread')
      }
      if (selectionRequestRef.current !== request) return false
      selectedRef.current = id
      meetingRef.current = next
      setSelectedMeetingId(id)
      setMeeting(next)
      setAgentTurnsByMeeting((current) => ({ ...current, [id]: turns }))
      if (threadError) setError(threadError)
      return true
    } catch (cause) {
      if (selectionRequestRef.current === request) {
        setError(cause instanceof Error ? cause.message : t('error.openMeeting'))
      }
      return false
    }
  }, [t])

  const refreshMeetings = useCallback(
    async (query = '', preferredActiveId?: string | null) => {
      try {
        meetingQueryRef.current = query
        const nextMeetings = await arcoBridge.listMeetings(query)
        setMeetings(nextMeetings)
        const activeId = preferredActiveId === undefined
          ? capture.activeMeetingId
          : preferredActiveId
        if (activeId) {
          const nextActiveMeeting = nextMeetings.find((item) => item.id === activeId)
          if (nextActiveMeeting) setActiveMeeting(nextActiveMeeting)
        } else {
          setActiveMeeting(null)
        }
        if (query.trim()) return
        const retainedSelection = selectedRef.current
          && nextMeetings.some((item) => item.id === selectedRef.current)
          ? selectedRef.current
          : null
        const preferredId = preferredActiveId === undefined
          ? retainedSelection || activeId || nextMeetings[0]?.id
          : activeId || retainedSelection || nextMeetings[0]?.id
        if (preferredId && preferredId !== selectedRef.current) await selectMeeting(preferredId)
        if (!preferredId) {
          selectedRef.current = null
          meetingRef.current = null
          setSelectedMeetingId(null)
          setMeeting(null)
        }
      } catch (cause) {
        setError(cause instanceof Error ? cause.message : t('error.loadMeetings'))
      }
    },
    [capture.activeMeetingId, selectMeeting, t],
  )

  const refreshAgentTurns = useCallback(async (meetingId: string) => {
    try {
      const turns = await arcoBridge.listAgentTurns(meetingId)
      setAgentTurnsByMeeting((current) => ({ ...current, [meetingId]: turns }))
      return turns
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('error.refreshAgentThread'))
      return []
    }
  }, [t])

  const refreshSavedNotes = useCallback(async (query = '') => {
    noteQueryRef.current = query
    setNotesLoading(true)
    try {
      const notes = await arcoBridge.listNotes(query)
      setSavedNotes(notes)
      return notes
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('error.loadSavedNotes'))
      return []
    } finally {
      setNotesLoading(false)
    }
  }, [t])

  const renameMeeting = useCallback(async (meetingId: string, title: string | null) => {
    setError(null)
    try {
      const updated = await arcoBridge.renameMeeting(meetingId, title)
      setMeetings((current) => current.map((candidate) => candidate.id === meetingId ? updated : candidate))
      setActiveMeeting((current) => current?.id === meetingId ? updated : current)
      if (meetingRef.current?.summary.id === meetingId) {
        const nextMeeting = { ...meetingRef.current, summary: updated }
        meetingRef.current = nextMeeting
        setMeeting(nextMeeting)
      }
      return true
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('error.renameMeeting'))
      return false
    }
  }, [t])

  const refreshMeetingOutput = useCallback(async (meetingId: string) => {
    try {
      const selected = selectedRef.current === meetingId
      const [nextMeetings, nextMeeting] = await Promise.all([
        arcoBridge.listMeetings(meetingQueryRef.current),
        selected ? arcoBridge.readMeeting(meetingId) : Promise.resolve(null),
      ])
      setMeetings(nextMeetings)
      const activeId = activeCaptureRef.current
      setActiveMeeting(activeId
        ? nextMeetings.find((candidate) => candidate.id === activeId) ?? null
        : null)
      if (nextMeeting && selectedRef.current === meetingId) {
        meetingRef.current = nextMeeting
        setMeeting(nextMeeting)
      }
    } catch (cause) {
      console.warn('Arco could not refresh generated meeting output', cause)
    }
  }, [])

  const generateMeetingOutputIfNeeded = useCallback(async (
    targetMeeting: MeetingDetail,
    kind: MeetingOutputKind,
  ) => {
    if (!arcoBridge.isDesktop() && !arcoBridge.isDemo()) return false
    const claim = `${targetMeeting.summary.id}:${kind}`
    const existing = generationClaimsRef.current.get(claim)
    if (existing) {
      await existing
      return false
    }
    const settings = loadGenerationSettings()
    const rule = settings[kind]
    if (!rule.enabled) return false

    if (kind === 'title') {
      if (
        targetMeeting.lines.length < TITLE_GENERATION_LINE_THRESHOLD
        || targetMeeting.summary.title !== null
        || targetMeeting.summary.titleGenerationStatus !== 'idle'
      ) return false
    } else if (
      targetMeeting.lines.length === 0
      || targetMeeting.summary.summaryGenerationStatus !== 'idle'
    ) {
      return false
    }

    const route = resolveProviderRoute(loadProviderConfig(), runtimes)
    if (!route.available || !route.provider) return false
    const provider = route.provider

    const prompt = rule.promptOverride
      ?? (kind === 'title' ? DEFAULT_TITLE_PROMPT : DEFAULT_SUMMARY_PROMPT)

    const task = (async () => {
      try {
        const artifact = await arcoBridge.generateMeetingOutput({
          meetingId: targetMeeting.summary.id,
          provider,
          kind,
          prompt,
        })
        if (artifact.status === 'failed') {
          console.warn(`Arco could not generate the meeting ${kind}`, artifact.error ?? 'Unknown CLI failure')
        }
      } catch (cause) {
        console.warn(`Arco could not generate the meeting ${kind}`, cause)
      } finally {
        await refreshMeetingOutput(targetMeeting.summary.id)
      }
    })()
    generationClaimsRef.current.set(claim, task)
    await task
    return true
  }, [refreshMeetingOutput, runtimes])

  const generateStoppedMeetingOutputs = useCallback(async (targetMeeting: MeetingDetail) => {
    await generateMeetingOutputIfNeeded(targetMeeting, 'title')
    await generateMeetingOutputIfNeeded(targetMeeting, 'summary')
  }, [generateMeetingOutputIfNeeded])

  const syncCapture = useCallback(async () => {
    try {
      const previousActiveId = activeCaptureRef.current
      const nextCapture = await arcoBridge.captureStatus()
      activeCaptureRef.current = nextCapture.activeMeetingId
      setCapture(nextCapture)
      await refreshMeetings('', nextCapture.activeMeetingId)
      if (previousActiveId && !nextCapture.activeMeetingId) {
        const opened = await selectMeeting(previousActiveId)
        if (opened && meetingRef.current?.summary.id === previousActiveId) {
          void generateStoppedMeetingOutputs(meetingRef.current)
        }
      }
      return nextCapture
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('error.refreshRecording'))
      return null
    }
  }, [generateStoppedMeetingOutputs, refreshMeetings, selectMeeting, t])

  useEffect(() => {
    let cancelled = false
    Promise.all([arcoBridge.listMeetings(), arcoBridge.runtimeStatus(), arcoBridge.captureStatus()])
      .then(async ([nextMeetings, nextRuntimes, nextCapture]) => {
        if (cancelled) return
        setMeetings(nextMeetings)
        setRuntimes(nextRuntimes)
        setCapture(nextCapture)
        activeCaptureRef.current = nextCapture.activeMeetingId
        setActiveMeeting(
          nextCapture.activeMeetingId
            ? nextMeetings.find((item) => item.id === nextCapture.activeMeetingId) ?? null
            : null,
        )
        const firstId = nextCapture.activeMeetingId ?? nextMeetings[0]?.id ?? null
        if (firstId) await selectMeeting(firstId)
      })
      .catch((cause) => {
        if (!cancelled) setError(cause instanceof Error ? cause.message : t('error.startArco'))
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [selectMeeting, t])

  useEffect(() => {
    const activeMeetingId = capture.activeMeetingId
    if (capture.phase !== 'recording' || !activeMeetingId) return
    const interval = window.setInterval(async () => {
      try {
        const [nextCapture, nextMeeting] = await Promise.all([
          arcoBridge.captureStatus(),
          arcoBridge.readMeeting(activeMeetingId),
        ])
        setCapture(nextCapture)
        activeCaptureRef.current = nextCapture.activeMeetingId
        setActiveMeeting(nextCapture.activeMeetingId ? nextMeeting.summary : null)
        if (selectedRef.current === activeMeetingId) {
          meetingRef.current = nextMeeting
          setMeeting(nextMeeting)
        }
      } catch (cause) {
        setError(cause instanceof Error ? cause.message : t('error.liveDisconnected'))
      }
    }, 1_200)
    return () => window.clearInterval(interval)
  }, [capture.activeMeetingId, capture.phase, t])

  useEffect(() => {
    if (
      capture.phase !== 'recording'
      || !capture.activeMeetingId
      || meeting?.summary.id !== capture.activeMeetingId
    ) return
    void generateMeetingOutputIfNeeded(meeting, 'title')
  }, [capture.activeMeetingId, capture.phase, generateMeetingOutputIfNeeded, meeting])

  useEffect(() => {
    if (!arcoBridge.isDesktop()) return
    let disposed = false
    const cleanups: Array<() => void> = []
    void Promise.all([
      listen('arco:capture-changed', () => void syncCapture()),
      listen<string>('arco:agent-thread-changed', (event) => {
        void refreshAgentTurns(event.payload)
        void refreshSavedNotes(noteQueryRef.current)
      }),
      listen<string>('arco:agent-target-changed', (event) => void selectMeeting(event.payload)),
      listen<string>('arco:meeting-output-changed', (event) => void refreshMeetingOutput(event.payload)),
      listen('arco:notes-changed', () => void refreshSavedNotes(noteQueryRef.current)),
    ]).then((unlisteners) => {
      if (disposed) unlisteners.forEach((unlisten) => unlisten())
      else cleanups.push(...unlisteners)
    })
    return () => {
      disposed = true
      cleanups.forEach((unlisten) => unlisten())
    }
  }, [refreshAgentTurns, refreshMeetingOutput, refreshSavedNotes, selectMeeting, syncCapture])

  const toggleCapture = useCallback(
    async (mode: AudioMode = 'both', transcription?: TranscriptionConfig) => {
      setError(null)
      const stopping = capture.phase === 'recording'
      const stoppedMeetingId = stopping ? capture.activeMeetingId : null
      setCapture((current) => ({ ...current, phase: stopping ? 'stopping' : 'starting' }))
      try {
        const next = stopping ? await arcoBridge.stopCapture() : await arcoBridge.startCapture(mode, transcription)
        activeCaptureRef.current = next.activeMeetingId
        setCapture(next)
        await refreshMeetings('', stopping ? null : next.activeMeetingId)
        if (stoppedMeetingId) {
          const opened = await selectMeeting(stoppedMeetingId)
          if (opened && meetingRef.current?.summary.id === stoppedMeetingId) {
            void generateStoppedMeetingOutputs(meetingRef.current)
          }
        }
        return next
      } catch (cause) {
        const message = cause instanceof Error ? cause.message : t('error.captureFailed')
        setCapture((current) => ({ ...current, phase: 'error', message }))
        setError(message)
        return null
      }
    },
    [capture.activeMeetingId, capture.phase, generateStoppedMeetingOutputs, refreshMeetings, selectMeeting, t],
  )

  const refreshRuntimes = useCallback(async () => {
    setError(null)
    try {
      const nextRuntimes = await arcoBridge.runtimeStatus()
      setRuntimes(nextRuntimes)
      return nextRuntimes
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('error.checkRuntimes'))
      return []
    }
  }, [t])

  const askAgent = useCallback(async (input: AskAgentInput) => {
    const question = input.question.trim()
    if (!question) return false
    const requestId = globalThis.crypto?.randomUUID?.()
      ?? `agent-${Date.now()}-${Math.random().toString(16).slice(2)}`
    setAgentRunning(true)
    setAgentStreamingTurn({
      requestId,
      meetingId: input.meetingId,
      question,
      phase: 'starting',
      answer: '',
    })
    setError(null)
    try {
      const onEvent = (event: AgentStreamEvent) => {
        setAgentStreamingTurn((current) => {
          if (
            !current
            || current.requestId !== event.requestId
            || current.meetingId !== event.meetingId
          ) return current
          if (event.type === 'status' && event.phase) {
            return { ...current, phase: event.phase }
          }
          if (event.type === 'answer' && typeof event.answer === 'string') {
            return { ...current, answer: event.answer }
          }
          return current
        })
      }
      const reply = await arcoBridge.runAgent({ ...input, question, requestId }, onEvent)
      setAgentTurnsByMeeting((current) => ({
        ...current,
        [input.meetingId]: [
          ...(current[input.meetingId] ?? []),
          reply,
        ],
      }))
      return true
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('error.agentAnswer'))
      return false
    } finally {
      setAgentRunning(false)
      setAgentStreamingTurn((current) => current?.requestId === requestId ? null : current)
    }
  }, [t])

  const setAgentTurnSaved = useCallback(async (meetingId: string, turnId: string, saved: boolean) => {
    setError(null)
    try {
      const updated = await arcoBridge.setAgentTurnSaved(meetingId, turnId, saved)
      setAgentTurnsByMeeting((current) => ({
        ...current,
        [meetingId]: (current[meetingId] ?? []).map((turn) => turn.id === turnId ? updated : turn),
      }))
      await refreshSavedNotes(noteQueryRef.current)
      return true
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('error.updateSavedNote'))
      return false
    }
  }, [refreshSavedNotes, t])

  const saveNote = useCallback(async (input: SaveNoteInput) => {
    setError(null)
    try {
      const note = await arcoBridge.saveNote(input)
      await refreshSavedNotes(noteQueryRef.current)
      return note
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('error.saveNote'))
      return null
    }
  }, [refreshSavedNotes, t])

  const deleteNote = useCallback(async (noteId: string) => {
    setError(null)
    try {
      await arcoBridge.deleteNote(noteId)
      await refreshSavedNotes(noteQueryRef.current)
      return true
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('error.deleteNote'))
      return false
    }
  }, [refreshSavedNotes, t])

  return {
    meetings,
    activeMeeting,
    selectedMeetingId,
    meeting,
    runtimes,
    capture,
    agentReplies: selectedMeetingId ? (agentTurnsByMeeting[selectedMeetingId] ?? []) : [],
    savedNotes,
    notesLoading,
    loading,
    agentRunning,
    agentStreamingTurn,
    error,
    isDesktop: arcoBridge.isDesktop(),
    selectMeeting,
    refreshMeetings,
    refreshAgentTurns,
    refreshSavedNotes,
    renameMeeting,
    syncCapture,
    refreshRuntimes,
    toggleCapture,
    askAgent,
    setAgentTurnSaved,
    saveNote,
    deleteNote,
    dismissError: () => setError(null),
  }
}
