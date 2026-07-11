import { render as testingLibraryRender, screen, within } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { I18nProvider } from '../i18n/i18n'
import { demoCapture, demoMeetingDetails } from '../lib/demoData'
import { TranscriptPane } from './TranscriptPane'

const meeting = demoMeetingDetails['demo-live']
const render = (ui: Parameters<typeof testingLibraryRender>[0]) => testingLibraryRender(ui, { wrapper: I18nProvider })

describe('TranscriptPane progressive disclosure', () => {
  it('keeps populated, loading, and empty transcript states in the complementary evidence landmark', () => {
    const { rerender } = render(<TranscriptPane meeting={meeting} capture={demoCapture} loading={false} />)

    expect(screen.getByRole('complementary', { name: 'Meeting transcript' })).toBeVisible()

    rerender(<TranscriptPane meeting={meeting} capture={demoCapture} loading />)
    expect(screen.getByRole('complementary', { name: 'Loading transcript' })).toBeVisible()

    rerender(<TranscriptPane meeting={null} capture={demoCapture} loading={false} />)
    expect(screen.getByRole('complementary', { name: 'Meeting transcript' })).toBeVisible()
  })

  it('labels the evidence pane without adding a metadata strip', () => {
    render(<TranscriptPane meeting={meeting} capture={demoCapture} loading={false} />)

    expect(screen.getByText(/It should know enough about my work/)).toBeVisible()
    expect(screen.getByRole('heading', { name: 'Transcript' })).toBeVisible()
    expect(screen.queryByText('Meeting info')).not.toBeInTheDocument()
    expect(screen.queryByText('12 utterances · 4 speakers · 38 min')).not.toBeInTheDocument()
    expect(screen.queryByText('Deepgram')).not.toBeInTheDocument()
    expect(screen.getByLabelText('Meeting transcript').querySelector('.transcript-surface-header')).not.toBeNull()
  })

  it('retains audio-source context on each speaker label without exposing the source legend', () => {
    render(<TranscriptPane meeting={meeting} capture={demoCapture} loading={false} />)

    expect(screen.getAllByLabelText('Remote 1, system audio')).toHaveLength(4)
    expect(screen.getAllByLabelText('In room 2, room mic')).toHaveLength(3)
    expect(screen.queryByText('Meeting info')).not.toBeInTheDocument()
  })

  it('shows the speaker label on every transcript row, including consecutive rows from the same speaker', () => {
    const consecutiveMeeting = {
      ...meeting,
      lines: [
        { ...meeting.lines[0], id: 'consecutive-1', sequence: 1 },
        { ...meeting.lines[0], id: 'consecutive-2', sequence: 2, timestamp: '14:02:22', text: 'A second line from the same speaker.' },
      ],
    }

    const { rerender } = render(<TranscriptPane meeting={consecutiveMeeting} capture={demoCapture} loading={false} />)
    expect(screen.getAllByLabelText('Remote 1, system audio')).toHaveLength(2)

    rerender(<TranscriptPane meeting={consecutiveMeeting} capture={demoCapture} loading={false} compact />)
    expect(screen.getAllByLabelText('Remote 1, system audio')).toHaveLength(2)
  })

  it('assigns a stable, source-aware avatar to every speaker label', () => {
    const avatarMeeting = {
      ...meeting,
      lines: [
        { ...meeting.lines[0], id: 'speaker-generic-1', speaker: 'Speaker 1', sequence: 1 },
        { ...meeting.lines[0], id: 'speaker-remote-1', speaker: 'Remote 1', sequence: 2 },
        { ...meeting.lines[0], id: 'speaker-room-1', speaker: 'In room 1', sequence: 3 },
        { ...meeting.lines[0], id: 'speaker-generic-1-repeat', speaker: 'Speaker 1', sequence: 4 },
      ],
    }

    const { rerender } = render(<TranscriptPane meeting={avatarMeeting} capture={demoCapture} loading={false} />)
    const avatars = [...screen.getByLabelText('Meeting transcript').querySelectorAll('.speaker-avatar')]
    expect(avatars).toHaveLength(4)
    expect(avatars.every((avatar) => avatar.tagName.toLocaleLowerCase() === 'svg')).toBe(true)
    expect(avatars[0].getAttribute('data-avatar-index')).toBe(avatars[3].getAttribute('data-avatar-index'))
    expect(new Set(avatars.slice(0, 3).map((avatar) => avatar.getAttribute('data-avatar-index'))).size).toBe(3)

    rerender(<TranscriptPane meeting={avatarMeeting} capture={demoCapture} loading={false} compact />)
    expect(screen.getByLabelText('Meeting transcript').querySelectorAll('.speaker-avatar')).toHaveLength(4)
  })

  it('offers a compact headerless evidence layout for the Agent utility window', () => {
    render(<TranscriptPane meeting={meeting} capture={demoCapture} loading={false} compact showHeader={false} />)

    const transcript = screen.getByRole('complementary', { name: 'Meeting transcript' })
    expect(transcript).toHaveClass('transcript-pane-compact')
    expect(screen.queryByRole('heading', { name: 'Transcript' })).not.toBeInTheDocument()
    expect(transcript.querySelector('.compact-utterance-meta')).toHaveTextContent('Remote 1')
    expect(transcript.querySelector('.compact-utterance-meta')).toHaveTextContent('14:02:18')
    expect(screen.queryByLabelText('Listening')).not.toBeInTheDocument()
  })

  it('renders a generated summary as a linear document before transcript evidence', () => {
    const summarizedMeeting = {
      ...meeting,
      summary: {
        ...meeting.summary,
        generatedSummary: 'The team agreed to make evidence visible.\n\n- Keep Agent primary\n- Keep Transcript on the right',
        summaryGenerationStatus: 'ready' as const,
      },
    }
    render(<TranscriptPane meeting={summarizedMeeting} capture={{ ...demoCapture, phase: 'idle' }} loading={false} />)

    const summary = screen.getByRole('region', { name: 'Meeting summary' })
    const firstUtterance = screen.getByText(/If this becomes a desktop app/).closest('.utterance')
    expect(within(summary).getByRole('heading', { name: 'Summary' })).toBeVisible()
    expect(within(summary).getByText('The team agreed to make evidence visible.')).toBeVisible()
    expect(within(summary).getAllByRole('listitem').map((item) => item.textContent)).toEqual([
      'Keep Agent primary',
      'Keep Transcript on the right',
    ])
    expect(summary.compareDocumentPosition(firstUtterance as Node) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(summary).not.toHaveTextContent(/AI|Codex|Claude|generated/i)
  })

  it('keeps pending and failed generation out of the normal reading surface', () => {
    const failedMeeting = {
      ...meeting,
      summary: {
        ...meeting.summary,
        generatedSummary: null,
        titleGenerationStatus: 'failed' as const,
        summaryGenerationStatus: 'failed' as const,
      },
    }
    const { rerender } = render(<TranscriptPane meeting={failedMeeting} capture={demoCapture} loading={false} />)

    expect(screen.queryByRole('region', { name: 'Meeting summary' })).not.toBeInTheDocument()
    expect(screen.queryByText(/failed|error|generating/i)).not.toBeInTheDocument()

    rerender(<TranscriptPane meeting={{
      ...meeting,
      summary: {
        ...meeting.summary,
        generatedSummary: null,
        titleGenerationStatus: 'idle',
        summaryGenerationStatus: 'idle',
      },
    }} capture={demoCapture} loading={false} />)
    expect(screen.queryByRole('region', { name: 'Meeting summary' })).not.toBeInTheDocument()
  })

  it('renders common CLI markdown headings and emphasis without syntax litter', () => {
    const summarizedMeeting = {
      ...meeting,
      summary: {
        ...meeting.summary,
        generatedSummary: '## Outcome\n**Decision:** Keep the transcript visible.\n\n1. `Agent` stays primary',
        summaryGenerationStatus: 'ready' as const,
      },
    }
    render(<TranscriptPane meeting={summarizedMeeting} capture={{ ...demoCapture, phase: 'idle' }} loading={false} />)

    const summary = screen.getByRole('region', { name: 'Meeting summary' })
    expect(within(summary).getByRole('heading', { name: 'Outcome' })).toBeVisible()
    expect(within(summary).getByText('Decision: Keep the transcript visible.')).toBeVisible()
    expect(within(summary).getByRole('listitem')).toHaveTextContent('Agent stays primary')
    expect(summary).not.toHaveTextContent(/##|\*\*|`/)
  })
})
