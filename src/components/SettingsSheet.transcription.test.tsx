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
    expect(screen.getByRole('button', { name: 'Download and use Whisper Base' })).toBeDisabled()
    expect(prepare).not.toHaveBeenCalled()
  })

  it('downloads and uses the selected on-device model in one action', async () => {
    const user = userEvent.setup()
    const prepare = vi.fn()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ ...localConfig, model: 'whisper-base' }}
        transcriptionModels={statuses}
        onChangeTranscriptionConfig={vi.fn()}
        onPrepareTranscriptionModel={prepare}
        onRemoveTranscriptionModel={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await user.click(screen.getByText('Recognition'))
    await user.click(screen.getByRole('button', { name: 'Download and use Whisper Base' }))

    expect(prepare).toHaveBeenCalledOnce()
    expect(prepare).toHaveBeenCalledWith('whisper-base')
  })

  it('keeps the download action disabled while showing model progress', async () => {
    const user = userEvent.setup()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ ...localConfig, model: 'whisper-base' }}
        transcriptionModels={statuses.map((status) => status.id === 'whisper-base'
          ? { ...status, phase: 'downloading', progress: 0.42 }
          : status)}
        onChangeTranscriptionConfig={vi.fn()}
        onPrepareTranscriptionModel={vi.fn()}
        onRemoveTranscriptionModel={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await user.click(screen.getByText('Recognition'))
    const progress = screen.getByRole('button', { name: 'Download and use Whisper Base' })
    expect(progress).toBeDisabled()
    expect(progress).toHaveTextContent('42%')
  })

  it('accepts a Deepgram key directly without showing Python or environment setup', async () => {
    const user = userEvent.setup()
    const saveKey = vi.fn().mockResolvedValue(undefined)
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{
          provider: 'deepgram',
          model: 'nova-3',
          language: 'zh-CN',
          diarization: 'provider',
        }}
        transcriptionModels={statuses}
        onChangeTranscriptionConfig={vi.fn()}
        onPrepareTranscriptionModel={vi.fn()}
        onRemoveTranscriptionModel={vi.fn()}
        deepgramCredential={{ configured: false, verified: false, message: null }}
        onSaveDeepgramApiKey={saveKey}
        onClose={vi.fn()}
      />,
    )

    await user.click(screen.getByText('Recognition'))
    const keyInput = screen.getByLabelText('Deepgram API key')
    await user.type(keyInput, '0123456789abcdef0123456789abcdef')
    await user.click(screen.getByRole('button', { name: 'Verify & save' }))

    expect(saveKey).toHaveBeenCalledWith('0123456789abcdef0123456789abcdef')
    expect(screen.getByRole('link', { name: 'Get a Deepgram key' })).toHaveAttribute(
      'href',
      'https://console.deepgram.com/',
    )
    expect(screen.queryByText(/uv|python|\.env|DEEPGRAM_API_KEY=/i)).not.toBeInTheDocument()
  })

  it('shows only a ready receipt and remove action after Deepgram is configured', async () => {
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ provider: 'deepgram', model: 'nova-3', language: 'zh-CN', diarization: 'provider' }}
        transcriptionModels={statuses}
        deepgramCredential={{ configured: true, verified: true, message: null }}
        onRemoveDeepgramApiKey={vi.fn()}
        onClose={vi.fn()}
      />,
    )
    await userEvent.click(screen.getByText('Recognition'))
    expect(screen.getByText('Deepgram is ready')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Remove key' })).toBeVisible()
    expect(screen.queryByLabelText('Deepgram API key')).not.toBeInTheDocument()
  })
})
