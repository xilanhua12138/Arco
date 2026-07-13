import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { SettingsSheet } from './SettingsSheet'

const defaultStorage = {
  defaultDirectory: '/Users/name/Library/Application Support/Arco/transcripts',
  selectedDirectory: '/Users/name/Library/Application Support/Arco/transcripts',
  usingDefault: true,
}

const defaultNotesStorage = {
  defaultDirectory: '/Users/name/Library/Application Support/Arco/notes',
  selectedDirectory: '/Users/name/Library/Application Support/Arco/notes',
  usingDefault: true,
}

describe('SettingsSheet transcript storage', () => {
  it('opens the transcript folder picker directly from the storage row', async () => {
    const user = userEvent.setup()
    const onChooseTranscriptDirectory = vi.fn(async () => true)
    render(
      <SettingsSheet
        open
        initialPage="privacy"
        runtimes={[]}
        isDesktop
        storageSettings={defaultStorage}
        notesStorageSettings={defaultNotesStorage}
        onChooseTranscriptDirectory={onChooseTranscriptDirectory}
        onClose={vi.fn()}
      />,
    )

    const storageRow = screen.getByRole('button', { name: 'Meeting transcript storage' })
    expect(storageRow).not.toHaveAttribute('aria-expanded')
    expect(storageRow).toHaveTextContent('Default')
    expect(storageRow).toHaveTextContent(defaultStorage.selectedDirectory)
    expect(screen.queryByRole('button', { name: 'Choose folder' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Notes storage' })).toHaveTextContent(defaultNotesStorage.selectedDirectory)

    await user.click(storageRow)
    expect(onChooseTranscriptDirectory).toHaveBeenCalledTimes(1)
  })

  it('lets the user choose and restore an independent Markdown notes folder', async () => {
    const user = userEvent.setup()
    const onChooseNotesDirectory = vi.fn(async () => true)
    const onResetNotesDirectory = vi.fn(async () => true)
    render(
      <SettingsSheet
        open
        initialPage="privacy"
        runtimes={[]}
        isDesktop
        storageSettings={defaultStorage}
        notesStorageSettings={{
          ...defaultNotesStorage,
          selectedDirectory: '/Volumes/Personal/Arco Notes',
          usingDefault: false,
        }}
        onChooseNotesDirectory={onChooseNotesDirectory}
        onResetNotesDirectory={onResetNotesDirectory}
        onClose={vi.fn()}
      />,
    )

    const storageRow = screen.getByRole('button', { name: 'Notes storage' })
    expect(storageRow).toHaveTextContent('Custom')
    const restoreDefault = screen.getByRole('button', { name: 'Restore default' })
    await user.click(restoreDefault)
    expect(onResetNotesDirectory).toHaveBeenCalledTimes(1)
    expect(onChooseNotesDirectory).not.toHaveBeenCalled()

    await user.click(storageRow)
    expect(onChooseNotesDirectory).toHaveBeenCalledTimes(1)
  })

  it('offers a restore-default action for a custom folder without moving existing meetings', async () => {
    const user = userEvent.setup()
    const onResetTranscriptDirectory = vi.fn(async () => true)
    render(
      <SettingsSheet
        open
        initialPage="privacy"
        runtimes={[]}
        isDesktop
        storageSettings={{
          ...defaultStorage,
          selectedDirectory: '/Volumes/Meetings/Arco',
          usingDefault: false,
        }}
        onResetTranscriptDirectory={onResetTranscriptDirectory}
        onClose={vi.fn()}
      />,
    )

    const storageRow = screen.getByRole('button', { name: 'Meeting transcript storage' })
    expect(storageRow).toHaveTextContent('Custom')
    await user.click(screen.getByRole('button', { name: 'Restore default' }))
    expect(onResetTranscriptDirectory).toHaveBeenCalledTimes(1)
  })

  it('locks both transcript folder actions while a meeting is active', async () => {
    const user = userEvent.setup()
    const onChooseTranscriptDirectory = vi.fn(async () => true)
    const onResetTranscriptDirectory = vi.fn(async () => true)
    render(
      <SettingsSheet
        open
        initialPage="privacy"
        runtimes={[]}
        isDesktop
        audioModeLocked
        storageSettings={{
          ...defaultStorage,
          selectedDirectory: '/Volumes/Meetings/Arco',
          usingDefault: false,
        }}
        notesStorageSettings={defaultNotesStorage}
        onChooseTranscriptDirectory={onChooseTranscriptDirectory}
        onResetTranscriptDirectory={onResetTranscriptDirectory}
        onClose={vi.fn()}
      />,
    )

    const storageRow = screen.getByRole('button', { name: 'Meeting transcript storage' })
    const restoreDefault = screen.getByRole('button', { name: 'Restore default' })
    expect(storageRow).toBeDisabled()
    expect(restoreDefault).toBeDisabled()
    expect(screen.getByText('Stop the current meeting before changing this folder.')).toBeVisible()

    await user.click(storageRow)
    await user.click(restoreDefault)
    expect(onChooseTranscriptDirectory).not.toHaveBeenCalled()
    expect(onResetTranscriptDirectory).not.toHaveBeenCalled()
  })
})
