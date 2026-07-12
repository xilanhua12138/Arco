import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { SettingsSheet } from './SettingsSheet'

const baseProps = {
  open: true,
  runtimes: [],
  isDesktop: true,
  onClose: vi.fn(),
}

describe('SettingsSheet audio scenarios', () => {
  it('shows the three meeting scenarios and changes the preferred source mode', async () => {
    const user = userEvent.setup()
    const onChangeAudioMode = vi.fn()

    render(
      <SettingsSheet
        {...baseProps}
        audioMode="both"
        audioModeLocked={false}
        onChangeAudioMode={onChangeAudioMode}
      />,
    )

    expect(screen.getByRole('radio', { name: /Hybrid meeting/i })).toBeChecked()
    expect(screen.getByRole('radio', { name: /Online meeting/i })).not.toBeChecked()
    expect(screen.getByRole('radio', { name: /In-person meeting/i })).not.toBeChecked()

    await user.click(screen.getByRole('radio', { name: /Online meeting/i }))

    expect(onChangeAudioMode).toHaveBeenCalledOnce()
    expect(onChangeAudioMode).toHaveBeenCalledWith('system')
  })

  it('shows only the current mode while capture is locked', () => {
    const onChangeAudioMode = vi.fn()

    render(
      <SettingsSheet
        {...baseProps}
        audioMode="mic"
        audioModeLocked
        onChangeAudioMode={onChangeAudioMode}
      />,
    )

    expect(screen.queryAllByRole('radio')).toHaveLength(0)
    expect(screen.getByRole('region', { name: 'Current meeting audio' })).toHaveTextContent('In-person meeting')
    expect(screen.getByText('Locked until this meeting ends')).toBeVisible()
    expect(screen.queryByText('Hybrid meeting')).not.toBeInTheDocument()
    expect(screen.queryByText('Online meeting')).not.toBeInTheDocument()
    expect(onChangeAudioMode).not.toHaveBeenCalled()
  })

  it('keeps speaker and transcription internals behind concise disclosure rows', async () => {
    const user = userEvent.setup()
    render(
      <SettingsSheet
        {...baseProps}
        audioMode="both"
        audioModeLocked
      />,
    )

    const recognitionDetails = screen.getByText('Recognition').closest('details')
    expect(recognitionDetails).not.toHaveAttribute('open')
    expect(screen.getByText('Chinese')).toBeVisible()
    expect(screen.queryByText('Remote 1… · In room 1…')).not.toBeInTheDocument()
    expect(screen.getByText(/Deepgram separates multiple speakers/i)).not.toBeVisible()

    await user.click(screen.getByText('Recognition'))
    expect(recognitionDetails).toHaveAttribute('open')
    expect(screen.getByText(/Deepgram separates multiple speakers/i)).toBeVisible()
    expect(screen.getByText('Deepgram · multichannel diarization')).toBeVisible()
    expect(screen.getByText('System audio')).toBeVisible()
    expect(screen.getByText('Room microphone')).toBeVisible()
  })

  it('keeps provider routing concise while retaining native storage disclosure', async () => {
    const user = userEvent.setup()
    render(
      <SettingsSheet
        {...baseProps}
        runtimes={[
          { provider: 'codex', available: true, version: 'codex 0.137.0', path: '/bin/codex' },
          { provider: 'claude', available: true, version: 'Claude Code 2.1.202', path: '/bin/claude' },
        ]}
        providerConfig={{ setupComplete: true, primary: 'codex', secondary: 'claude' }}
        audioMode="both"
        audioModeLocked={false}
        onChangeAudioMode={vi.fn()}
      />,
    )

    await user.click(screen.getByRole('button', { name: /Agent runtime/i }))
    expect(screen.getByRole('region', { name: 'Current configuration' })).toBeVisible()
    expect(screen.getByText('Primary provider')).toBeVisible()
    expect(screen.getByText('Secondary provider')).toBeVisible()
    expect(screen.queryByText(/follow-up questions resume that exact native session/i)).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /Data & privacy/i }))
    expect(screen.getByText('Native Agent conversations')).toBeVisible()
    expect(screen.getByText('Stored by Codex or Claude on this Mac')).toBeVisible()
    expect(screen.getByText('Meeting links and answer cache')).toBeVisible()
    expect(screen.getByText('Notes')).toBeVisible()
  })
})
