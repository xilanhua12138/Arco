import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { TranscriptionConfig, TranscriptionModelStatus } from '../types'
import { SettingsSheet } from './SettingsSheet'

const localConfig: TranscriptionConfig = {
  provider: 'local',
  model: 'nemotron-speech-3.5-streaming',
  language: 'zh-CN',
  diarization: 'local-streaming',
}

const statuses: TranscriptionModelStatus[] = [
  {
    id: 'nemotron-speech-3.5-streaming',
    installed: true,
    phase: 'ready',
    progress: 1,
    error: null,
    path: '/tmp/nemotron',
  },
  {
    id: 'whisper-base',
    installed: false,
    phase: 'not-installed',
    progress: null,
    error: null,
    path: null,
  },
]

describe('SettingsSheet local transcription', () => {
  it('shows the unified engine, model, language, and diarization contract', async () => {
    const user = userEvent.setup()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={localConfig}
        transcriptionModels={statuses}
        onChangeTranscriptionConfig={vi.fn()}
        onPrepareTranscriptionModel={vi.fn()}
        onRemoveTranscriptionModel={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await user.click(screen.getByText('Recognition'))
    const recognition = screen.getByRole('group', { name: 'Speech recognition engine' })
    expect(within(recognition).getByRole('radio', { name: /On-device/i })).toBeChecked()
    expect(screen.getByRole('combobox', { name: 'On-device model' })).toHaveValue('nemotron-speech-3.5-streaming')
    expect(screen.getByText('Streaming Sortformer')).toBeVisible()
    expect(screen.getByText(/up to 4 speakers/i)).toBeVisible()
    expect(screen.getByText('Audio and transcript stay on this Mac.')).toBeVisible()
  })

  it('downloads a missing model and disables runtime changes during capture', async () => {
    const user = userEvent.setup()
    const prepare = vi.fn()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        audioModeLocked
        transcriptionConfig={{ ...localConfig, model: 'whisper-base' }}
        transcriptionModels={statuses}
        onChangeTranscriptionConfig={vi.fn()}
        onPrepareTranscriptionModel={prepare}
        onRemoveTranscriptionModel={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await user.click(screen.getByText('Recognition'))
    expect(screen.getByRole('combobox', { name: 'On-device model' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Download Whisper Base' })).toBeDisabled()
    expect(prepare).not.toHaveBeenCalled()
  })
})
