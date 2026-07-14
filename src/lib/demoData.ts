import type {
  CaptureState,
  MeetingDetail,
  MeetingSummary,
  PersistedAgentTurn,
  RuntimeStatus,
} from '../types'

const summaries: MeetingSummary[] = [
  {
    id: 'demo-live',
    title: 'Product direction · weekly working session',
    startedAt: '2026-07-10T14:02:00+08:00',
    durationLabel: '38 min',
    preview: 'The team is defining how source-aware help should work in a hybrid room…',
    path: '~/Library/Application Support/Arco/transcripts/demo-live.md',
    utteranceCount: 12,
    isLive: true,
    source: 'arco',
    generatedSummary: null,
    titleGenerationStatus: 'idle',
    summaryGenerationStatus: 'idle',
  },
  {
    id: 'demo-yesterday',
    title: 'Benchmark review with Estrella',
    startedAt: '2026-07-09T17:10:00+08:00',
    durationLabel: '52 min',
    preview: 'We should separate a useful follow-up from a merely fluent one in the scoring rubric.',
    path: '~/.claude/meeting-transcripts/transcript-20260709-171000.md',
    utteranceCount: 37,
    isLive: false,
    source: 'legacy',
    generatedSummary: `The team agreed that benchmark scoring should distinguish a useful follow-up from a merely fluent one.

- Score whether the follow-up advances the research objective and uses what the participant just said
- Review borderline examples together before changing rubric wording`,
    titleGenerationStatus: 'ready',
    summaryGenerationStatus: 'ready',
  },
  {
    id: 'demo-older',
    title: 'Interview host roadmap',
    startedAt: '2026-07-07T10:30:00+08:00',
    durationLabel: '44 min',
    preview: 'Top-tier means the participant feels understood while the research objective keeps moving forward.',
    path: '~/.claude/meeting-transcripts/meeting-20260707-103000.md',
    utteranceCount: 31,
    isLive: false,
    source: 'legacy',
    generatedSummary: null,
    titleGenerationStatus: 'idle',
    summaryGenerationStatus: 'idle',
  },
]

const liveLines = [
  ['14:02:18', 'Remote 1', 'If this becomes a desktop app, what is the one behavior that makes it more than another meeting recorder?'],
  ['14:02:31', 'In room 1', 'It should know enough about my work to help while the conversation is still happening, not just summarize it later.'],
  ['14:02:52', 'In room 2', 'And the microphone cannot be treated as one person. Three of us are sitting around the same table today.'],
  ['14:03:04', 'Remote 1', 'Then the transcript is not the product. It is the shared evidence layer for the agent.'],
  ['14:03:18', 'Remote 2', 'The source labels matter too. I am remote, but there are two separate speakers coming through system audio.'],
  ['14:03:36', 'In room 1', 'Right, and I do not want an agent that interrupts every thirty seconds with generic advice.'],
  ['14:04:02', 'Remote 1', 'Could it stay quiet until there is a question, a contradiction, or a decision without an owner?'],
  ['14:04:27', 'In room 2', 'That sounds right. The user should always know what source an insight came from.'],
  ['14:05:16', 'Remote 2', 'And when it uses project context, the app should show which workspace was in scope.'],
  ['14:05:46', 'In room 1', 'Let us make that the default trust model: transcript first, broader context only when visible.'],
  ['14:06:11', 'Remote 1', 'Can the interface make the two audio channels legible without turning this into an audio engineering console?'],
  ['14:06:34', 'In room 2', 'Yes. Keep Remote N and In room N visible, but explain that they are location labels rather than verified identities.'],
].map(([timestamp, speaker, text], sequence) => ({
  id: `live-${sequence}`,
  timestamp,
  speaker,
  text,
  sequence,
}))

export const demoMeetings: MeetingSummary[] = summaries

export const demoMeetingDetails: Record<string, MeetingDetail> = Object.fromEntries(
  summaries.map((summary, index) => [
    summary.id,
    {
      summary,
      lines:
        index === 0
          ? liveLines
          : liveLines.slice(0, index === 1 ? 6 : 4).map((line, lineIndex) => ({
              ...line,
              id: `${summary.id}-${lineIndex}`,
              timestamp: `${10 + index}:${String(12 + lineIndex * 4).padStart(2, '0')}:00`,
            })),
    },
  ]),
)

export const demoRuntimes: RuntimeStatus[] = [
  { provider: 'codex', available: true, version: 'codex-cli 0.137.0', path: '/opt/homebrew/bin/codex' },
  { provider: 'claude', available: true, version: 'Claude Code 2.1.202', path: '/opt/homebrew/bin/claude' },
]

export const demoCapture: CaptureState = {
  phase: 'recording',
  activeMeetingId: 'demo-live',
  startedAt: '2026-07-10T14:02:00+08:00',
  message: null,
  transcription: {
    provider: 'deepgram',
    model: 'nova-3',
    language: 'zh-CN',
    diarization: 'provider',
  },
}

export const demoAgentReply: PersistedAgentTurn = {
  id: 'demo-turn-1',
  meetingId: 'demo-live',
  providerSessionId: '019f4b7a-5d83-7a20-b14c-31920a30d9b8',
  providerTurnId: 'item_0',
  provider: 'codex',
  question: 'What is the strongest direct answer to the latest question in this meeting?',
  answer:
    'Arco becomes more than a recorder when it can use the context you already trust to improve the conversation while it is still happening. The transcript remains the evidence; the Agent earns its place by answering a real question, testing a consequential assumption, or connecting the moment to relevant work without interrupting by default.',
  sources: [
    { kind: 'transcript', label: 'Current transcript · 14:02–14:06', reference: 'demo-live#14:02:18' },
    { kind: 'context', label: 'Your stated trust model', reference: 'demo-live#14:05:46' },
  ],
  contextScope: 'transcript',
  createdAt: new Date().toISOString(),
  savedAsNote: false,
  noteId: null,
  usedFallback: false,
}
