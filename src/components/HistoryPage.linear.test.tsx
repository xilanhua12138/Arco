import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { MeetingSummary } from '../types'
import { HistoryPage } from './HistoryPage'

const meetings: MeetingSummary[] = [
  {
    id: 'meeting-1',
    title: 'Design review',
    startedAt: new Date().toISOString(),
    durationLabel: '32 min',
    preview: 'We agreed to simplify the first-run experience.',
    path: '/tmp/design-review.md',
    utteranceCount: 42,
    isLive: false,
    source: 'arco',
    generatedSummary: null,
    titleGenerationStatus: 'idle',
    summaryGenerationStatus: 'idle',
  },
]

describe('HistoryPage linear meeting history', () => {
  it('keeps history focused and removes dashboard-like policy and filter controls', () => {
    render(
      <HistoryPage
        meetings={meetings}
        selectedMeetingId={null}
        query=""
        onQueryChange={vi.fn()}
        onSelectMeeting={vi.fn()}
      />,
    )

    expect(screen.getByRole('heading', { level: 1, name: 'History' })).toBeVisible()
    expect(screen.queryByText('Your conversations')).not.toBeInTheDocument()
    expect(screen.queryByText('Transcripts stay on this Mac.')).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Meeting storage and privacy')).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Filter meetings')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Live' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Past meetings' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Design review/i })).toBeVisible()
  })

  it('keeps search and meeting selection as the only history actions', async () => {
    const user = userEvent.setup()
    const onQueryChange = vi.fn()
    const onSelectMeeting = vi.fn()

    render(
      <HistoryPage
        meetings={meetings}
        selectedMeetingId={null}
        query=""
        onQueryChange={onQueryChange}
        onSelectMeeting={onSelectMeeting}
      />,
    )

    await user.type(screen.getByRole('textbox', { name: 'Search meetings' }), 'design')
    expect(onQueryChange).toHaveBeenLastCalledWith('n')

    await user.click(screen.getByRole('button', { name: /Design review/i }))
    expect(onSelectMeeting).toHaveBeenCalledOnce()
    expect(onSelectMeeting).toHaveBeenCalledWith('meeting-1')
  })

  it('keeps an untitled meeting selectable without fabricating a time-based title', () => {
    const untitledMeeting = { ...meetings[0], id: 'untitled', title: null }
    render(
      <HistoryPage
        meetings={[untitledMeeting]}
        selectedMeetingId={null}
        query=""
        onQueryChange={vi.fn()}
        onSelectMeeting={vi.fn()}
      />,
    )

    expect(screen.getByRole('button', { name: /Untitled meeting/i })).toBeVisible()
    expect(screen.queryByText(/Meeting ·/i)).not.toBeInTheDocument()
    expect(untitledMeeting.title).toBeNull()
  })
})
