import { render, screen, within } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { AudioMode, CaptureState, MeetingSummary } from '../types'
import { Sidebar } from './Sidebar'

const capture: CaptureState = {
  phase: 'idle',
  activeMeetingId: null,
  startedAt: null,
  message: null,
}

const meeting: MeetingSummary & { title: string } = {
  id: 'meeting-1',
  title: 'Product direction · weekly working session',
  startedAt: '2026-07-10T08:00:00.000Z',
  durationLabel: '38 min',
  preview: 'A working session about product direction.',
  path: '/tmp/meeting-1.json',
  utteranceCount: 12,
  isLive: true,
  source: 'arco',
  generatedSummary: null,
  titleGenerationStatus: 'idle',
  summaryGenerationStatus: 'idle',
}

const renderSidebar = (
  audioMode: AudioMode,
  captureState: CaptureState = capture,
  page: 'current' | 'history' | 'review' = 'current',
) =>
  render(
    <Sidebar
      page={page}
      meeting={meeting}
      capture={captureState}
      audioMode={audioMode}
      audioModeLocked={false}
      onChangePage={vi.fn()}
      onToggleCapture={vi.fn()}
      onOpenSettings={vi.fn()}
    />,
  )

describe('Sidebar capture control', () => {
  it('uses the canonical Arco artwork in the sidebar brand', () => {
    const { container } = renderSidebar('both')

    const brandImage = container.querySelector<HTMLImageElement>('.brand-mark img')
    expect(brandImage).toHaveAttribute('src', '/arco-icon.png')
    expect(brandImage).toHaveAttribute('alt', '')
  })

  it.each([
    ['both', 'Hybrid', 'System and room audio'],
    ['system', 'Online', 'System audio'],
    ['mic', 'Room', 'Room audio'],
  ] as const)('keeps the idle Current %s mode as status without duplicating its central action', (mode, label, sourceLabel) => {
    renderSidebar(mode)
    const captureRegion = screen.getByRole('region', {
      name: `Audio capture · ${label} · ${sourceLabel}`,
    })

    expect(within(captureRegion).getByText('Ready')).toBeVisible()
    expect(within(captureRegion).getByText(label)).toBeVisible()
    expect(within(captureRegion).queryByRole('button', { name: 'Start listening' })).not.toBeInTheDocument()

    expect(captureRegion).not.toHaveTextContent(meeting.title)
    expect(captureRegion).not.toHaveTextContent('System')
    expect(captureRegion).not.toHaveTextContent('Room audio')
    expect(captureRegion).not.toHaveTextContent('Online call + people in the room')
    expect(captureRegion).not.toHaveTextContent('Only the call playing on this Mac')
    expect(captureRegion).not.toHaveTextContent('Only people speaking near this Mac')
  })

  it.each(['history', 'review'] as const)('offers the global Start action while idle on %s', (page) => {
    renderSidebar('both', capture, page)
    const captureRegion = screen.getByRole('region', {
      name: 'Audio capture · Hybrid · System and room audio',
    })

    expect(within(captureRegion).getByRole('button', { name: 'Start listening' })).toBeEnabled()
  })

  it('keeps the live state compact without repeating the current meeting title', () => {
    renderSidebar('both', {
      phase: 'recording',
      activeMeetingId: meeting.id,
      startedAt: meeting.startedAt,
      message: null,
    })
    const captureRegion = screen.getByRole('region', {
      name: 'Audio capture · Hybrid · System and room audio',
    })

    expect(within(captureRegion).getByText('Listening')).toBeVisible()
    expect(within(captureRegion).getByText('Hybrid')).toBeVisible()
    expect(within(captureRegion).getAllByRole('button')).toHaveLength(1)
    expect(within(captureRegion).getByRole('button', { name: 'Stop listening' })).toBeEnabled()
    expect(captureRegion).not.toHaveTextContent(meeting.title)
    expect(captureRegion).not.toHaveTextContent('System')
    expect(captureRegion).not.toHaveTextContent('Room audio')
  })

  it('keeps provider routing out of the everyday navigation chrome', () => {
    render(
      <Sidebar
        page="current"
        meeting={meeting}
        capture={capture}
        audioMode="both"
        onChangePage={vi.fn()}
        onToggleCapture={vi.fn()}
        onOpenSettings={vi.fn()}
      />,
    )

    expect(screen.getByRole('button', { name: 'Open settings' })).toBeVisible()
    expect(screen.queryByText('claude')).not.toBeInTheDocument()
    expect(screen.queryByText('codex')).not.toBeInTheDocument()
    expect(screen.queryByText('No CLI')).not.toBeInTheDocument()
  })
})
