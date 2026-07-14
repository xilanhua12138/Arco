import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { TranscriptionConfig, TranscriptionModelStatus } from '../types'
import { SettingsSheet } from './SettingsSheet'

const localConfig: TranscriptionConfig = {
  asr: { provider: 'local', model: 'nemotron-speech-3.5-streaming', language: 'zh-CN' },
  diarization: { provider: 'local', model: 'sortformer-streaming' },
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

const ensureRecognitionOpen = async () => {
  const details = screen.getByText('Recognition').closest('details')
  if (!details?.hasAttribute('open')) await userEvent.click(screen.getByText('Recognition'))
}

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
        transcriptionConfig={{ ...localConfig, diarization: { provider: 'none', model: null } }}
        transcriptionModels={statuses}
        onClose={vi.fn()}
      />,
    )

    const summary = container.querySelector('.settings-disclosure > summary')
    expect(summary).toHaveTextContent('Nemotron Speech 3.5 · Speaker separation off')
    expect(within(summary as HTMLElement).queryByLabelText('Required local models are not downloaded')).not.toBeInTheDocument()
  })

  it('shows the unified engine, model, language, and diarization contract', async () => {
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

    await ensureRecognitionOpen()
    const recognition = screen.getByRole('group', { name: 'Speech recognition provider' })
    expect(within(recognition).getByRole('radio', { name: /This Mac/i })).toBeChecked()
    expect(within(recognition).getByText(/Nemotron or Whisper · audio stays on device/i)).toBeVisible()
    expect(screen.getByRole('combobox', { name: 'On-device model' })).toHaveValue('nemotron-speech-3.5-streaming')
    expect(screen.getAllByText('Streaming Sortformer')[0]).toBeVisible()
    expect(screen.getByRole('radio', { name: /Streaming Sortformer.*up to 4 speakers/i })).toBeChecked()
    expect(screen.getByText('Audio and transcript stay on this Mac.')).toBeVisible()
  })

  it('discloses the cloud audio boundary when local ASR uses Deepgram diarization', async () => {
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ ...localConfig, diarization: { provider: 'deepgram', model: 'latest' } }}
        transcriptionModels={statuses}
        onChangeTranscriptionConfig={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await ensureRecognitionOpen()

    expect(screen.getByText(/Speech recognition runs on this Mac/i)).toBeVisible()
    expect(screen.getByText(/Audio is also sent to Deepgram for speaker separation/i)).toBeVisible()
    expect(screen.queryByText('Audio and transcript stay on this Mac.')).not.toBeInTheDocument()
  })

  it('offers four independent on-device diarization models', async () => {
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

    await ensureRecognitionOpen()

    expect(screen.getByRole('radio', { name: /Streaming Sortformer/i })).toBeChecked()
    expect(screen.getByRole('radio', { name: /Pyannote \+ WeSpeaker/i })).not.toBeChecked()
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
        transcriptionConfig={{ ...localConfig, diarization: { provider: 'local', model: 'lseend-ami-streaming' } }}
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

    await ensureRecognitionOpen()
    const download = screen.getByRole('button', { name: 'Download LS-EEND Meeting' })
    await user.click(download)

    expect(prepare).toHaveBeenCalledWith('lseend-ami-streaming')
    expect(changeConfig).not.toHaveBeenCalledWith(expect.objectContaining({ asr: expect.objectContaining({ provider: 'deepgram' }) }))
  })

  it('downloads the experimental Pyannote and WeSpeaker streaming model independently', async () => {
    const user = userEvent.setup()
    const prepare = vi.fn()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ ...localConfig, diarization: { provider: 'local', model: 'pyannote-wespeaker-streaming' } }}
        transcriptionModels={[
          ...statuses,
          {
            id: 'pyannote-wespeaker-streaming',
            installed: false,
            phase: 'not-installed',
            progress: null,
            error: null,
            path: null,
          },
        ]}
        onPrepareTranscriptionModel={prepare}
        onClose={vi.fn()}
      />,
    )

    await ensureRecognitionOpen()
    expect(screen.getByText('Experimental · Pyannote + WeSpeaker · 5-second rolling window')).toBeVisible()
    await user.click(screen.getByRole('button', { name: 'Download Pyannote + WeSpeaker' }))

    expect(prepare).toHaveBeenCalledWith('pyannote-wespeaker-streaming')
  })

  it('lets a cloud ASR select a different streaming diarization provider', async () => {
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ asr: { provider: 'deepgram', model: 'nova-3', language: 'zh-CN' }, diarization: { provider: 'local', model: 'sortformer-streaming' } }}
        transcriptionModels={statuses}
        onChangeTranscriptionConfig={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await ensureRecognitionOpen()

    expect(screen.getByRole('radio', { name: /Deepgram.*no local model/i })).not.toBeChecked()
    expect(screen.getByRole('radio', { name: /Streaming Sortformer/i })).toBeChecked()
    expect(screen.getByRole('radio', { name: /LS-EEND Meeting/i })).not.toBeChecked()
    expect(screen.getByText('Deepgram ASR')).toBeVisible()
    expect(screen.getByText(/speaker labels come from the selected provider/i)).toBeVisible()
  })

  it('offers ElevenLabs as an independent realtime provider without speaker diarization', async () => {
    const user = userEvent.setup()
    const changeConfig = vi.fn()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ asr: { provider: 'deepgram', model: 'nova-3', language: 'zh-CN' }, diarization: { provider: 'deepgram', model: 'latest' } }}
        transcriptionModels={statuses}
        onChangeTranscriptionConfig={changeConfig}
        elevenLabsCredential={{ configured: false, verified: false, message: null }}
        onClose={vi.fn()}
      />,
    )

    await ensureRecognitionOpen()
    const providers = screen.getByRole('group', { name: 'Speech recognition provider' })
    await user.click(within(providers).getByRole('radio', { name: /ElevenLabs/i }))

    expect(changeConfig).toHaveBeenCalledWith({
      asr: { provider: 'elevenlabs', model: 'scribe-v2-realtime', language: 'zh-CN' },
      diarization: { provider: 'deepgram', model: 'latest' },
    })
  })

  it('configures ElevenLabs ASR independently from streaming speaker separation', async () => {
    const user = userEvent.setup()
    const saveKey = vi.fn().mockResolvedValue(undefined)
    const openConsole = vi.fn().mockResolvedValue(undefined)
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ asr: { provider: 'elevenlabs', model: 'scribe-v2-realtime', language: 'auto' }, diarization: { provider: 'none', model: null } }}
        transcriptionModels={statuses}
        elevenLabsCredential={{ configured: false, verified: false, message: null }}
        onSaveElevenLabsApiKey={saveKey}
        onOpenElevenLabsConsole={openConsole}
        onClose={vi.fn()}
      />,
    )

    await ensureRecognitionOpen()
    expect(screen.getByText('ElevenLabs ASR')).toBeVisible()
    expect(screen.getByRole('radio', { name: /Deepgram.*no local model/i })).toBeVisible()
    expect(screen.getByRole('radio', { name: /Streaming Sortformer/i })).toBeVisible()
    expect(screen.getByText(/keeps source lanes only/i)).toBeVisible()
    expect(screen.queryByText(/when listening stops|final speaker/i)).not.toBeInTheDocument()

    await user.type(screen.getByLabelText('ElevenLabs API key'), 'sk_0123456789abcdefghijklmnopqrstuvwxyz')
    await user.click(screen.getByRole('button', { name: 'Verify & save' }))

    expect(saveKey).toHaveBeenCalledWith('sk_0123456789abcdefghijklmnopqrstuvwxyz')
    const getKeyLink = screen.getByRole('link', { name: 'Get an ElevenLabs key' })
    expect(getKeyLink).toHaveAttribute('href', 'https://elevenlabs.io/app/developers/api-keys')
    await user.click(getKeyLink)
    expect(openConsole).toHaveBeenCalledOnce()
    expect(screen.queryByText(/ELEVENLABS_API_KEY=|\.env|python/i)).not.toBeInTheDocument()
  })

  it('downloads a missing model and disables runtime changes during capture', async () => {
    const prepare = vi.fn()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        audioModeLocked
        transcriptionConfig={{ ...localConfig, asr: { ...localConfig.asr, model: 'whisper-base' } }}
        transcriptionModels={statuses}
        onChangeTranscriptionConfig={vi.fn()}
        onPrepareTranscriptionModel={prepare}
        onRemoveTranscriptionModel={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await ensureRecognitionOpen()
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
        transcriptionConfig={{ ...localConfig, asr: { ...localConfig.asr, model: 'whisper-base' } }}
        transcriptionModels={statuses}
        onChangeTranscriptionConfig={vi.fn()}
        onPrepareTranscriptionModel={prepare}
        onRemoveTranscriptionModel={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await ensureRecognitionOpen()
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

    await ensureRecognitionOpen()
    const download = screen.getByRole('button', { name: 'Download Streaming Sortformer' })
    expect(download).toBeEnabled()
    await user.click(download)

    expect(prepare).toHaveBeenCalledOnce()
    expect(prepare).toHaveBeenCalledWith('sortformer-streaming')
  })

  it('shows Sortformer download progress without pretending the model is ready', async () => {
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

    await ensureRecognitionOpen()
    expect(screen.getByRole('button', { name: 'Download Streaming Sortformer' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Download Streaming Sortformer' })).toHaveTextContent('37%')
    expect(screen.queryByText(/^Ready$/)).not.toBeInTheDocument()
  })

  it('describes cloud and local processing truthfully instead of presenting one vendor as the engine list', async () => {
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ asr: { provider: 'deepgram', model: 'nova-3', language: 'zh-CN' }, diarization: { provider: 'deepgram', model: 'latest' } }}
        transcriptionModels={statuses}
        onChangeTranscriptionConfig={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await ensureRecognitionOpen()
    const recognition = screen.getByRole('group', { name: 'Speech recognition provider' })
    expect(within(recognition).getByRole('radio', { name: /Deepgram/i })).toBeChecked()
    expect(within(recognition).getByRole('radio', { name: /This Mac/i })).not.toBeChecked()
  })

  it('keeps the download action disabled while showing model progress', async () => {
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ ...localConfig, asr: { ...localConfig.asr, model: 'whisper-base' } }}
        transcriptionModels={statuses.map((status) => status.id === 'whisper-base'
          ? { ...status, phase: 'downloading', progress: 0.42 }
          : status)}
        onChangeTranscriptionConfig={vi.fn()}
        onPrepareTranscriptionModel={vi.fn()}
        onRemoveTranscriptionModel={vi.fn()}
        onClose={vi.fn()}
      />,
    )

    await ensureRecognitionOpen()
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
          asr: { provider: 'deepgram', model: 'nova-3', language: 'zh-CN' },
          diarization: { provider: 'deepgram', model: 'latest' },
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

    await ensureRecognitionOpen()
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
        transcriptionConfig={{ asr: { provider: 'deepgram', model: 'nova-3', language: 'zh-CN' }, diarization: { provider: 'deepgram', model: 'latest' } }}
        transcriptionModels={statuses}
        deepgramCredential={{ configured: false, verified: false, message: null }}
        onOpenDeepgramConsole={vi.fn().mockRejectedValue(new Error('Could not open the Deepgram console.'))}
        onClose={vi.fn()}
      />,
    )

    await ensureRecognitionOpen()
    await user.click(screen.getByRole('link', { name: 'Get a Deepgram key' }))

    expect(screen.getByRole('alert')).toHaveTextContent('Could not open the Deepgram console.')
  })

  it('shows only a ready receipt and remove action after Deepgram is configured', async () => {
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        transcriptionConfig={{ asr: { provider: 'deepgram', model: 'nova-3', language: 'zh-CN' }, diarization: { provider: 'deepgram', model: 'latest' } }}
        transcriptionModels={statuses}
        deepgramCredential={{ configured: true, verified: true, message: null }}
        onRemoveDeepgramApiKey={vi.fn()}
        onClose={vi.fn()}
      />,
    )
    await ensureRecognitionOpen()
    expect(screen.getByText('Deepgram is ready')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Remove key' })).toBeVisible()
    expect(screen.queryByLabelText('Deepgram API key')).not.toBeInTheDocument()
  })
})
