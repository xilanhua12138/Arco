import { render, screen, waitFor, within } from '@testing-library/react'
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
  it('uses an Apple Notes style persistent list beside a separate editor toolbar', () => {
    render(<NotesPage {...baseProps} notes={notes} />)

    const index = screen.getByRole('complementary', { name: 'Meeting notes' })
    expect(within(index).getByRole('heading', { name: 'Notes' })).toBeVisible()
    expect(within(index).getByRole('button', { name: /Roadmap follow-ups/ })).toBeVisible()
    expect(within(index).getByRole('button', { name: /Decisions/ })).toBeVisible()
    expect(within(index).getByText('Confirm the launch owner')).toBeVisible()

    const editor = screen.getByRole('region', { name: 'Markdown note editor' })
    const controls = within(editor).getByRole('group', { name: 'Note controls' })
    expect(within(controls).getByRole('button', { name: 'New note' })).toBeVisible()
    expect(within(controls).getByRole('toolbar', { name: 'Format' })).toBeVisible()
    expect(within(controls).getByRole('textbox', { name: 'Search notes' })).toBeVisible()
  })

  it('collapses and restores the notes list from an Apple-style sidebar control', async () => {
    const user = userEvent.setup()
    render(<NotesPage {...baseProps} notes={notes} />)

    await user.click(screen.getByRole('button', { name: 'Hide notes list' }))

    expect(screen.queryByRole('complementary', { name: 'Meeting notes' })).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Show notes list' }))
    expect(screen.getByRole('complementary', { name: 'Meeting notes' })).toBeVisible()
  })

  it('keeps write and preview modes with the document instead of crowding the top format cluster', () => {
    render(<NotesPage {...baseProps} notes={notes} />)

    const formatTools = screen.getByRole('toolbar', { name: 'Format' })
    expect(within(formatTools).queryByRole('button', { name: 'Write' })).not.toBeInTheDocument()
    expect(within(formatTools).queryByRole('button', { name: 'Preview' })).not.toBeInTheDocument()

    const editor = screen.getByRole('region', { name: 'Markdown note editor' })
    expect(within(editor).getByRole('button', { name: 'Write' })).toBeVisible()
    expect(within(editor).getByRole('button', { name: 'Preview' })).toBeVisible()
  })

  it('keeps meeting navigation with note metadata instead of crowding the centered date row', () => {
    render(<NotesPage {...baseProps} notes={notes} />)

    const editor = screen.getByRole('region', { name: 'Markdown note editor' })
    const documentControls = within(editor).getByRole('group', { name: 'Document controls' })
    expect(within(documentControls).queryByRole('button', { name: demoMeetings[0].title ?? 'Untitled meeting' })).not.toBeInTheDocument()

    const metadata = within(editor).getByRole('group', { name: 'Note metadata' })
    const meetingButton = within(metadata).getByRole('button', {
      name: `Open meeting: ${demoMeetings[0].title ?? 'Untitled meeting'}`,
    })
    expect(meetingButton).toBeVisible()
    expect(meetingButton.closest('.note-meeting-control')).toContainElement(
      within(metadata).getByRole('combobox', { name: 'Meeting for this note' }),
    )
  })

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
    expect(screen.queryByRole('button', { name: 'Save note' })).not.toBeInTheDocument()

    await waitFor(() => expect(onSaveNote).toHaveBeenCalledWith({
        id: null,
        meetingId: demoMeetings[0].id,
        title: 'Interview follow-ups',
        body: '- Ask about pricing',
      }),
      { timeout: 2_000 },
    )
    expect(screen.getByText('Saved')).toBeVisible()
  })

  it('opens the meeting bound to an existing note', async () => {
    const user = userEvent.setup()
    const onOpenMeeting = vi.fn()
    render(<NotesPage {...baseProps} notes={notes} onOpenMeeting={onOpenMeeting} />)

    await user.click(screen.getByRole('button', { name: /Roadmap follow-ups/ }))
    await user.click(screen.getByRole('button', { name: `Open meeting: ${demoMeetings[0].title ?? 'Untitled meeting'}` }))
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
    await user.click(screen.getByRole('button', { name: 'Format' }))
    await user.click(screen.getByRole('menuitem', { name: 'Bold' }))

    expect(editor).toHaveValue('- **Confirm** the launch owner')
    await waitFor(() => expect(onSaveNote).toHaveBeenCalledWith({
        id: notes[0].id,
        meetingId: notes[0].meetingId,
        title: notes[0].title,
        body: '- **Confirm** the launch owner',
      }),
      { timeout: 2_000 },
    )
  })

  it('expands the complete Apple Notes format hierarchy and replaces paragraph styles', async () => {
    const user = userEvent.setup()
    const styledNote = { ...notes[0], body: '## Existing heading' }
    render(<NotesPage {...baseProps} notes={[styledNote]} />)

    await user.click(screen.getByRole('button', { name: 'Format' }))
    const formatMenu = screen.getByRole('menu', { name: 'Format' })
    for (const label of [
      'Bold', 'Italic', 'Strikethrough',
      'Title', 'Heading', 'Subheading', 'Body', 'Monostyled',
      'Bulleted list', 'Dashed list', 'Numbered list', 'Quote',
    ]) {
      expect(within(formatMenu).getByRole('menuitem', { name: label })).toBeVisible()
    }
    expect(within(formatMenu).queryByRole('menuitem', { name: 'Underline' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Attachment' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Highlight' })).not.toBeInTheDocument()

    const editor = screen.getByRole('textbox', { name: 'Markdown note' }) as HTMLTextAreaElement
    editor.focus()
    editor.setSelectionRange(4, 4)
    await user.click(within(formatMenu).getByRole('menuitem', { name: 'Body' }))
    expect(editor).toHaveValue('Existing heading')

    await user.click(screen.getByRole('button', { name: 'Format' }))
    editor.focus()
    editor.setSelectionRange(0, editor.value.length)
    await user.click(within(screen.getByRole('menu', { name: 'Format' })).getByRole('menuitem', { name: 'Dashed list' }))
    expect(editor).toHaveValue('- Existing heading')
  })

  it('deletes a note from its list-row context menu instead of the editor', async () => {
    const user = userEvent.setup()
    const onDeleteNote = vi.fn().mockResolvedValue(true)
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    render(<NotesPage {...baseProps} notes={notes} onDeleteNote={onDeleteNote} />)

    expect(screen.queryByRole('button', { name: 'Delete note' })).not.toBeInTheDocument()
    const row = screen.getByRole('button', { name: /Decisions/ })
    await user.pointer({ target: row, keys: '[MouseRight]' })
    await user.click(screen.getByRole('menuitem', { name: 'Delete note' }))

    expect(onDeleteNote).toHaveBeenCalledWith(notes[1].id)
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

  it('keeps cached note rows available during a background refresh', () => {
    render(<NotesPage {...baseProps} notes={notes} loading />)

    expect(screen.getByRole('button', { name: /Roadmap follow-ups/ })).toBeVisible()
    expect(screen.getByRole('button', { name: /Decisions/ })).toBeVisible()
    expect(screen.queryByRole('status', { name: 'Loading notes' })).not.toBeInTheDocument()
  })
})
