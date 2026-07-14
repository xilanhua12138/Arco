import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { demoCapture, demoMeetingDetails, demoMeetings } from '../lib/demoData'
import { TopBar } from './TopBar'

const liveMeeting = demoMeetingDetails['demo-live']

describe('TopBar progressive disclosure', () => {
  const renameMeeting = vi.fn(async () => true)

  it('keeps meeting context and details in the top bar without an Agent toggle', () => {
    render(
      <TopBar
        meeting={demoMeetings[0]}
        meetingDetail={liveMeeting}
        capture={demoCapture}
        onRenameMeeting={renameMeeting}
      />,
    )

    expect(screen.getByRole('heading', { level: 1, name: demoMeetings[0].title ?? 'Untitled meeting' })).toBeVisible()
    expect(screen.getByRole('status', { name: 'Recording status' })).toHaveTextContent('Listening')
    expect(screen.getByRole('button', { name: 'Meeting details' })).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByRole('dialog', { name: 'Meeting details' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Open Agent|Close Agent/i })).not.toBeInTheDocument()
    expect(screen.queryByText('Ask Arco')).not.toBeInTheDocument()

    expect(screen.queryByText('Meeting review')).not.toBeInTheDocument()
    expect(screen.queryByText('On this Mac')).not.toBeInTheDocument()
    expect(screen.queryByText('Transcript stored locally')).not.toBeInTheDocument()
    expect(screen.queryByText(demoMeetings[0].durationLabel)).not.toBeInTheDocument()
  })

  it('does not add a review label when viewing a completed meeting', () => {
    render(
      <TopBar
        meeting={demoMeetings[1]}
        meetingDetail={null}
        capture={{ ...demoCapture, phase: 'idle', activeMeetingId: null }}
        onRenameMeeting={renameMeeting}
      />,
    )

    expect(screen.getByRole('heading', { level: 1, name: demoMeetings[1].title ?? 'Untitled meeting' })).toBeVisible()
    expect(screen.queryByRole('status', { name: 'Recording status' })).not.toBeInTheDocument()
    expect(screen.queryByText('Meeting review')).not.toBeInTheDocument()
  })

  it('uses a quiet UI-only placeholder when an automatic title is not ready', () => {
    const untitled = { ...demoMeetings[0], title: null }
    render(
      <TopBar
        meeting={untitled}
        meetingDetail={{ ...liveMeeting, summary: untitled }}
        capture={demoCapture}
        onRenameMeeting={renameMeeting}
      />,
    )

    expect(screen.getByRole('heading', { level: 1, name: 'Untitled meeting' })).toBeVisible()
    expect(screen.queryByText(/Meeting ·/i)).not.toBeInTheDocument()
    expect(screen.queryByText(untitled.startedAt)).not.toBeInTheDocument()
    expect(untitled.title).toBeNull()
  })

  it('edits the meeting title in place and saves a trimmed name with Enter', async () => {
    const user = userEvent.setup()
    const onRenameMeeting = vi.fn(async () => true)
    render(
      <TopBar
        meeting={demoMeetings[0]}
        meetingDetail={liveMeeting}
        capture={demoCapture}
        onRenameMeeting={onRenameMeeting}
      />,
    )

    await user.click(screen.getByRole('button', { name: 'Rename meeting' }))
    const input = screen.getByRole('textbox', { name: 'Meeting title' })
    expect(input).toHaveValue(demoMeetings[0].title)
    await user.clear(input)
    await user.type(input, '  Product direction decisions  {Enter}')

    expect(onRenameMeeting).toHaveBeenCalledTimes(1)
    expect(onRenameMeeting).toHaveBeenCalledWith(demoMeetings[0].id, 'Product direction decisions')
  })

  it('turns an empty title into the quiet untitled state and cancels edits with Escape', async () => {
    const user = userEvent.setup()
    const onRenameMeeting = vi.fn(async () => true)
    render(
      <TopBar
        meeting={demoMeetings[0]}
        meetingDetail={liveMeeting}
        capture={demoCapture}
        onRenameMeeting={onRenameMeeting}
      />,
    )

    await user.click(screen.getByRole('button', { name: 'Rename meeting' }))
    await user.clear(screen.getByRole('textbox', { name: 'Meeting title' }))
    await user.tab()
    expect(onRenameMeeting).toHaveBeenLastCalledWith(demoMeetings[0].id, null)

    await user.click(screen.getByRole('button', { name: 'Rename meeting' }))
    await user.type(screen.getByRole('textbox', { name: 'Meeting title' }), 'Do not save')
    await user.keyboard('{Escape}')
    expect(onRenameMeeting).toHaveBeenCalledTimes(1)
    expect(screen.getByRole('heading', { level: 1, name: demoMeetings[0].title ?? 'Untitled meeting' })).toBeVisible()
  })

  it('opens a compact non-modal meeting details popover on demand', async () => {
    const user = userEvent.setup()
    render(
      <TopBar
        meeting={demoMeetings[0]}
        meetingDetail={liveMeeting}
        capture={demoCapture}
        onRenameMeeting={renameMeeting}
      />,
    )

    const trigger = screen.getByRole('button', { name: 'Meeting details' })
    await user.click(trigger)

    const popover = screen.getByRole('dialog', { name: 'Meeting details' })
    expect(trigger).toHaveAttribute('aria-expanded', 'true')
    expect(popover).toBeVisible()
    expect(popover).not.toHaveAttribute('aria-modal')
    expect(popover).toHaveTextContent('38 min')
    expect(popover).toHaveTextContent('12 utterances · 4 speakers')
    expect(popover).toHaveTextContent('On this Mac')
    expect(popover).toHaveTextContent('Deepgram')
    expect(withinPopover(popover, 'System')).toHaveTextContent('Remote 1, Remote 2')
    expect(withinPopover(popover, 'Room')).toHaveTextContent('In room 1, In room 2')
    expect(popover).toHaveTextContent('Location labels, not identities')
  })

  it('shows ElevenLabs instead of hard-coding Deepgram for an active meeting', async () => {
    const user = userEvent.setup()
    render(
      <TopBar
        meeting={demoMeetings[0]}
        meetingDetail={liveMeeting}
        capture={{
          ...demoCapture,
          transcription: {
            provider: 'elevenlabs',
            model: 'scribe-v2-realtime',
            language: 'zh-CN',
            diarization: 'none',
          },
        }}
        onRenameMeeting={renameMeeting}
      />,
    )

    await user.click(screen.getByRole('button', { name: 'Meeting details' }))
    const popover = screen.getByRole('dialog', { name: 'Meeting details' })
    expect(popover).toHaveTextContent('ElevenLabs')
    expect(popover).not.toHaveTextContent('Deepgram')
  })

  it('closes meeting details with Escape and restores focus to its trigger', async () => {
    const user = userEvent.setup()
    render(
      <TopBar
        meeting={demoMeetings[0]}
        meetingDetail={liveMeeting}
        capture={demoCapture}
        onRenameMeeting={renameMeeting}
      />,
    )

    const trigger = screen.getByRole('button', { name: 'Meeting details' })
    await user.click(trigger)
    await user.keyboard('{Escape}')

    expect(screen.queryByRole('dialog', { name: 'Meeting details' })).not.toBeInTheDocument()
    expect(trigger).toHaveAttribute('aria-expanded', 'false')
    expect(trigger).toHaveFocus()
  })

  it('closes meeting details after a click outside the popover', async () => {
    const user = userEvent.setup()
    render(
      <TopBar
        meeting={demoMeetings[0]}
        meetingDetail={liveMeeting}
        capture={demoCapture}
        onRenameMeeting={renameMeeting}
      />,
    )

    await user.click(screen.getByRole('button', { name: 'Meeting details' }))
    expect(screen.getByRole('dialog', { name: 'Meeting details' })).toBeVisible()

    await user.click(document.body)

    expect(screen.queryByRole('dialog', { name: 'Meeting details' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Meeting details' })).toHaveAttribute('aria-expanded', 'false')
  })
})

const withinPopover = (popover: HTMLElement, label: string) => {
  const term = Array.from(popover.querySelectorAll('dt')).find((node) => node.textContent === label)
  if (!term?.nextElementSibling) throw new Error(`Missing ${label} detail row`)
  return term.nextElementSibling
}
