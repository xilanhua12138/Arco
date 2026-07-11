import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { SettingsSheet } from './SettingsSheet'

const defaultStorage = {
  defaultDirectory: '/Users/name/Library/Application Support/Arco/transcripts',
  selectedDirectory: '/Users/name/Library/Application Support/Arco/transcripts',
  usingDefault: true,
}

describe('SettingsSheet transcript storage', () => {
  it('shows the real default location quietly and reveals controls only on demand', async () => {
    const user = userEvent.setup()
    const onChooseTranscriptDirectory = vi.fn(async () => true)
    render(
      <SettingsSheet
        open
        initialPage="privacy"
        runtimes={[]}
        isDesktop
        storageSettings={defaultStorage}
        onChooseTranscriptDirectory={onChooseTranscriptDirectory}
        onClose={vi.fn()}
      />,
    )

    const disclosure = screen.getByRole('button', { name: 'Meeting transcript storage' })
    expect(disclosure).toHaveAttribute('aria-expanded', 'false')
    expect(disclosure).toHaveTextContent('Default')
    expect(disclosure).toHaveTextContent(defaultStorage.selectedDirectory)
    expect(screen.queryByRole('button', { name: 'Choose folder' })).not.toBeInTheDocument()

    await user.click(disclosure)
    expect(disclosure).toHaveAttribute('aria-expanded', 'true')
    await user.click(screen.getByRole('button', { name: 'Choose folder' }))
    expect(onChooseTranscriptDirectory).toHaveBeenCalledTimes(1)
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

    const disclosure = screen.getByRole('button', { name: 'Meeting transcript storage' })
    expect(disclosure).toHaveTextContent('Custom')
    await user.click(disclosure)
    expect(screen.getByText('Existing meetings stay where they are and remain available in History.')).toBeVisible()
    await user.click(screen.getByRole('button', { name: 'Restore default' }))
    expect(onResetTranscriptDirectory).toHaveBeenCalledTimes(1)
  })
})
