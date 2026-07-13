import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { TranscriptionConfig, TranscriptionModelStatus } from '../types'
import { SettingsSheet } from './SettingsSheet'

const localConfig: TranscriptionConfig = {
  provider: 'local',
  model: 'nemotron-speech-3.5-streaming',
  language: 'zh-CN',
  diarization: 'sortformer-streaming',
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
  it('warns in the collapsed summary and names every missing model in the local pipeline', () => {
    const { container } = render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={localConfig}
        transcriptionModels={[
          {
            id: 'nemotron-speech-3.5-streaming',
            installed: false,
            phase: 'not-installed',
            progress: null,
            error: null,
            path: null,
          },
          {
            id: 'sortformer-streaming',
            installed: false,
            phase: 'not-installed',
            progress: null,
            error: null,
            path: null,
          },
        ]}
        onClose={vi.fn()}
      />,
    )

    const summary = container.querySelector('.settings-disclosure > summary')
    expect(summary).not.toBeNull()
    expect(within(summary as HTMLElement).getByLabelText('Required local models are not downloaded')).toBeVisible()
    expect(summary).toHaveTextContent('Nemotron Speech 3.5 not downloaded')
    expect(summary).toHaveTextContent('Streaming Sortformer not downloaded')
  })

  it('shows both ready local models in the collapsed summary without a warning', () => {
    const { container } = render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={localConfig}
        transcriptionModels={[
          {
            id: 'nemotron-speech-3.5-streaming',
            installed: true,
            phase: 'ready',
            progress: 1,
            error: null,
            path: '/tmp/nemotron',
          },
          {
            id: 'sortformer-streaming',
            installed: true,
            phase: 'ready',
            progress: 1,
            error: null,
            path: '/tmp/sortformer',
          },
        ]}
        onClose={vi.fn()}
      />,
    )

    const summary = container.querySelector('.settings-disclosure > summary')
    expect(summary).toHaveTextContent('Nemotron Speech 3.5 · Streaming Sortformer')
    expect(within(summary as HTMLElement).queryByLabelText('Required local models are not downloaded')).not.toBeInTheDocument()
  })

  it('does not require Sortformer when speaker separation is turned off', () => {
    const { container } = render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ ...localConfig, diarization: 'none' }}
        transcriptionModels={statuses}
        onClose={vi.fn()}
      />,
    )

    const summary = container.querySelector('.settings-disclosure > summary')
    expect(summary).toHaveTextContent('Nemotron Speech 3.5 · Speaker separation off')
    expect(within(summary as HTMLElement).queryByLabelText('Required local models are not downloaded')).not.toBeInTheDocument()
  })

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
    const recognition = screen.getByRole('group', { name: 'Where transcription runs' })
    expect(within(recognition).getByRole('radio', { name: /This Mac/i })).toBeChecked()
    expect(within(recognition).getByText(/Nemotron or Whisper · audio stays on device/i)).toBeVisible()
    expect(screen.getByRole('combobox', { name: 'On-device model' })).toHaveValue('nemotron-speech-3.5-streaming')
    expect(screen.getAllByText('Streaming Sortformer')[0]).toBeVisible()
    expect(screen.getByRole('radio', { name: /Streaming Sortformer.*up to 4 speakers/i })).toBeChecked()
    expect(screen.getByText('Audio and transcript stay on this Mac.')).toBeVisible()
  })

  it('offers three independent on-device diarization models', async () => {
    const user = userEvent.setup()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={localConfig}
        transcriptionModels={statuses}
        onChangeTranscriptionConfig={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await user.click(screen.getByText('Recognition'))

    expect(screen.getByRole('radio', { name: /Streaming Sortformer/i })).toBeChecked()
    expect(screen.getByRole('radio', { name: /LS-EEND Meeting/i })).not.toBeChecked()
    expect(screen.getByRole('radio', { name: /LS-EEND General/i })).not.toBeChecked()
  })

  it('selects and downloads the chosen LS-EEND model without touching Deepgram', async () => {
    const user = userEvent.setup()
    const changeConfig = vi.fn()
    const prepare = vi.fn()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ ...localConfig, diarization: 'lseend-ami-streaming' }}
        transcriptionModels={[
          ...statuses,
          {
            id: 'lseend-ami-streaming',
            installed: false,
            phase: 'not-installed',
            progress: null,
            error: null,
            path: null,
          },
        ]}
        onChangeTranscriptionConfig={changeConfig}
        onPrepareTranscriptionModel={prepare}
        onClose={vi.fn()}
      />,
    )

    await user.click(screen.getByText('Recognition'))
    const download = screen.getByRole('button', { name: 'Download LS-EEND Meeting' })
    await user.click(download)

    expect(prepare).toHaveBeenCalledWith('nemotron-speech-3.5-streaming', 'lseend-ami-streaming')
    expect(changeConfig).not.toHaveBeenCalledWith(expect.objectContaining({ provider: 'deepgram' }))
  })

  it('shows only Deepgram built-in diarization for the cloud provider', async () => {
    const user = userEvent.setup()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ provider: 'deepgram', model: 'nova-3', language: 'zh-CN', diarization: 'provider' }}
        transcriptionModels={statuses}
        onChangeTranscriptionConfig={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await user.click(screen.getByText('Recognition'))

    expect(screen.getAllByText('Deepgram built-in')[0]).toBeVisible()
    expect(screen.queryByRole('radio', { name: /Streaming Sortformer/i })).not.toBeInTheDocument()
    expect(screen.queryByRole('radio', { name: /LS-EEND/i })).not.toBeInTheDocument()
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

  it('offers an explicit download action when enabled speaker separation is not installed', async () => {
    const user = userEvent.setup()
    const prepare = vi.fn()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={localConfig}
        transcriptionModels={[
          ...statuses,
          {
            id: 'sortformer-streaming',
            installed: false,
            phase: 'not-installed',
            progress: null,
            error: null,
            path: null,
          },
        ]}
        onChangeTranscriptionConfig={vi.fn()}
        onPrepareTranscriptionModel={prepare}
        onRemoveTranscriptionModel={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await user.click(screen.getByText('Recognition'))
    const download = screen.getByRole('button', { name: 'Download Streaming Sortformer' })
    expect(download).toBeEnabled()
    await user.click(download)

    expect(prepare).toHaveBeenCalledOnce()
    expect(prepare).toHaveBeenCalledWith('nemotron-speech-3.5-streaming', 'sortformer-streaming')
  })

  it('shows Sortformer download progress without pretending the model is ready', async () => {
    const user = userEvent.setup()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={localConfig}
        transcriptionModels={[
          ...statuses,
          {
            id: 'sortformer-streaming',
            installed: false,
            phase: 'downloading',
            progress: 0.37,
            error: null,
            path: null,
          },
        ]}
        onChangeTranscriptionConfig={vi.fn()}
        onPrepareTranscriptionModel={vi.fn()}
        onRemoveTranscriptionModel={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await user.click(screen.getByText('Recognition'))
    expect(screen.getByRole('button', { name: 'Download Streaming Sortformer' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Download Streaming Sortformer' })).toHaveTextContent('37%')
    expect(screen.queryByText(/^Ready$/)).not.toBeInTheDocument()
  })

  it('describes cloud and local processing truthfully instead of presenting one vendor as the engine list', async () => {
    const user = userEvent.setup()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ provider: 'deepgram', model: 'nova-3', language: 'zh-CN', diarization: 'provider' }}
        transcriptionModels={statuses}
        onChangeTranscriptionConfig={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await user.click(screen.getByText('Recognition'))
    const recognition = screen.getByRole('group', { name: 'Where transcription runs' })
    expect(within(recognition).getByRole('radio', { name: /Cloud/i })).toBeChecked()
    expect(within(recognition).getByText(/Deepgram · real-time transcription/i)).toBeVisible()
    expect(within(recognition).getByRole('radio', { name: /This Mac/i })).not.toBeChecked()
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
    const openDeepgramConsole = vi.fn().mockResolvedValue(undefined)
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
        onOpenDeepgramConsole={openDeepgramConsole}
        onClose={vi.fn()}
      />,
    )

    await user.click(screen.getByText('Recognition'))
    const keyInput = screen.getByLabelText('Deepgram API key')
    await user.type(keyInput, '0123456789abcdef0123456789abcdef')
    await user.click(screen.getByRole('button', { name: 'Verify & save' }))

    expect(saveKey).toHaveBeenCalledWith('0123456789abcdef0123456789abcdef')
    const getKeyLink = screen.getByRole('link', { name: 'Get a Deepgram key' })
    expect(getKeyLink).toHaveAttribute(
      'href',
      'https://console.deepgram.com/',
    )
    await user.click(getKeyLink)
    expect(openDeepgramConsole).toHaveBeenCalledOnce()
    expect(screen.queryByText(/uv|python|\.env|DEEPGRAM_API_KEY=/i)).not.toBeInTheDocument()
  })

  it('shows a concrete error when macOS cannot open the Deepgram console', async () => {
    const user = userEvent.setup()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ provider: 'deepgram', model: 'nova-3', language: 'zh-CN', diarization: 'provider' }}
        transcriptionModels={statuses}
        deepgramCredential={{ configured: false, verified: false, message: null }}
        onOpenDeepgramConsole={vi.fn().mockRejectedValue(new Error('Could not open the Deepgram console.'))}
        onClose={vi.fn()}
      />,
    )

    await user.click(screen.getByText('Recognition'))
    await user.click(screen.getByRole('link', { name: 'Get a Deepgram key' }))

    expect(screen.getByRole('alert')).toHaveTextContent('Could not open the Deepgram console.')
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
