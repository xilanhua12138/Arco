import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { demoMeetings } from '../lib/demoData'
import type { NoteDocument } from '../types'
import { NotesPage } from './NotesPage'

const notes: NoteDocument[] = [
  {
    id: 'local:note-roadmap.md',
    title: 'Roadmap follow-ups',
    body: '- Confirm the launch owner',
    source: 'manual',
    createdAt: '2026-07-12T10:00:00+08:00',
    updatedAt: '2026-07-12T10:05:00+08:00',
    path: '/tmp/notes/note-roadmap.md',
    meetingId: demoMeetings[0].id,
    meetingTitle: demoMeetings[0].title,
    agentTurnId: null,
  },
  {
    id: 'local:note-decisions.md',
    title: 'Decisions',
    body: 'Ship the native app.',
    source: 'manual',
    createdAt: '2026-07-12T09:00:00+08:00',
    updatedAt: '2026-07-12T09:05:00+08:00',
    path: '/tmp/notes/note-decisions.md',
    meetingId: demoMeetings[0].id,
    meetingTitle: demoMeetings[0].title,
    agentTurnId: null,
  },
]

const baseProps = {
  meetings: demoMeetings,
  query: '',
  loading: false,
  onQueryChange: vi.fn(),
  onOpenMeeting: vi.fn(),
  onSaveNote: vi.fn(),
  onDeleteNote: vi.fn(),
}

describe('NotesPage', () => {
  it('lets one meeting own multiple notes and creates another Markdown note for it', async () => {
    const user = userEvent.setup()
    const onSaveNote = vi.fn().mockImplementation(async (input) => ({
      ...notes[0],
      id: 'local:note-new.md',
      title: input.title,
      body: input.body,
      meetingId: input.meetingId,
    }))

    render(<NotesPage {...baseProps} notes={notes} onSaveNote={onSaveNote} />)

    expect(screen.getByRole('button', { name: /Roadmap follow-ups/ })).toBeVisible()
    expect(screen.getByRole('button', { name: /Decisions/ })).toBeVisible()

    await user.click(screen.getByRole('button', { name: 'New note' }))
    expect(screen.getByRole('combobox', { name: 'Meeting for this note' })).toHaveValue(demoMeetings[0].id)
    await user.type(screen.getByRole('textbox', { name: 'Note title' }), 'Interview follow-ups')
    await user.type(screen.getByRole('textbox', { name: 'Markdown note' }), '- Ask about pricing')
    await user.click(screen.getByRole('button', { name: 'Save note' }))

    expect(onSaveNote).toHaveBeenCalledWith({
      id: null,
      meetingId: demoMeetings[0].id,
      title: 'Interview follow-ups',
      body: '- Ask about pricing',
    })
    expect(screen.getByText('Saved')).toBeVisible()
  })

  it('opens the meeting bound to an existing note', async () => {
    const user = userEvent.setup()
    const onOpenMeeting = vi.fn()
    render(<NotesPage {...baseProps} notes={notes} onOpenMeeting={onOpenMeeting} />)

    await user.click(screen.getByRole('button', { name: /Roadmap follow-ups/ }))
    await user.click(screen.getByRole('button', { name: demoMeetings[0].title ?? 'Untitled meeting' }))
    expect(onOpenMeeting).toHaveBeenCalledWith(demoMeetings[0].id)
  })

  it('formats selected text as Markdown and saves the exact source', async () => {
    const user = userEvent.setup()
    const onSaveNote = vi.fn().mockImplementation(async (input) => ({
      ...notes[0],
      ...input,
    }))
    render(<NotesPage {...baseProps} notes={notes} onSaveNote={onSaveNote} />)

    const editor = screen.getByRole('textbox', { name: 'Markdown note' }) as HTMLTextAreaElement
    editor.focus()
    editor.setSelectionRange(2, 9)
    await user.click(screen.getByRole('button', { name: 'Bold' }))

    expect(editor).toHaveValue('- **Confirm** the launch owner')
    await user.click(screen.getByRole('button', { name: 'Save note' }))
    expect(onSaveNote).toHaveBeenCalledWith({
      id: notes[0].id,
      meetingId: notes[0].meetingId,
      title: notes[0].title,
      body: '- **Confirm** the launch owner',
    })
  })

  it('previews rendered Markdown and returns to the unchanged source', async () => {
    const user = userEvent.setup()
    const markdownNote = {
      ...notes[0],
      body: '## Decisions\n\n- Ship the native app.',
    }
    render(<NotesPage {...baseProps} notes={[markdownNote]} />)

    await user.click(screen.getByRole('button', { name: 'Preview' }))
    expect(screen.queryByRole('textbox', { name: 'Markdown note' })).not.toBeInTheDocument()
    expect(screen.getByRole('heading', { level: 2, name: 'Decisions' })).toBeVisible()
    expect(screen.getByText('Ship the native app.')).toBeVisible()

    await user.click(screen.getByRole('button', { name: 'Write' }))
    expect(screen.getByRole('textbox', { name: 'Markdown note' })).toHaveValue(markdownNote.body)
  })

  it('distinguishes loading, first-use empty, and filtered empty states', () => {
    const { rerender } = render(<NotesPage {...baseProps} notes={[]} loading />)
    expect(screen.getByRole('status', { name: 'Loading notes' })).toBeVisible()

    rerender(<NotesPage {...baseProps} notes={[]} />)
    expect(screen.getByText('No notes yet')).toBeVisible()

    rerender(<NotesPage {...baseProps} notes={[]} query="missing phrase" />)
    expect(screen.getByText('No matching notes')).toBeVisible()
  })

  it('keeps cached note rows visible during a background refresh', () => {
    render(<NotesPage {...baseProps} notes={notes} loading />)

    expect(screen.getByRole('button', { name: /Roadmap follow-ups/ })).toBeVisible()
    expect(screen.getByRole('button', { name: /Decisions/ })).toBeVisible()
    expect(screen.queryByRole('status', { name: 'Loading notes' })).not.toBeInTheDocument()
  })
})
