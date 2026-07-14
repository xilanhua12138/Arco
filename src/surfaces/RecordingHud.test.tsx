import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { arcoBridge } from '../lib/bridge'
import type { CaptureState } from '../types'
import { RecordingHud } from './RecordingHud'

const recording: CaptureState = {
  phase: 'recording',
  activeMeetingId: 'demo-live',
  startedAt: new Date(Date.now() - 72_000).toISOString(),
  message: null,
}

describe('RecordingHud', () => {
  beforeEach(() => {
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(recording)
  })

  it('contains only the global recording status and the two promised actions', async () => {
    render(<RecordingHud />)

    expect(await screen.findByText('Recording')).toBeVisible()
    expect(screen.getByRole('timer')).toHaveTextContent('01:12')
    expect(screen.getByRole('button', { name: 'Stop recording' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Ask Arco' })).toBeVisible()
    expect(screen.queryByText(/Deepgram|speaker|transcript stored|provider/i)).not.toBeInTheDocument()
  })

  it('opens the single native Agent overlay for the active meeting', async () => {
    const user = userEvent.setup()
    const toggle = vi.spyOn(arcoBridge, 'toggleAgentOverlay').mockResolvedValue(true)
    render(<RecordingHud />)

    await screen.findByText('Recording')
    await user.click(screen.getByRole('button', { name: 'Ask Arco' }))

    expect(toggle).toHaveBeenCalledTimes(1)
  })

  it('uses the non-control HUD surface as a native drag region', async () => {
    render(<RecordingHud />)

    const hud = await screen.findByRole('region', { name: 'Arco recording controls' })
    expect(hud).toHaveAttribute('data-tauri-drag-region', 'deep')
    expect(screen.getByRole('button', { name: 'Stop recording' })).not.toHaveAttribute('data-tauri-drag-region')
    expect(screen.getByRole('button', { name: 'Ask Arco' })).not.toHaveAttribute('data-tauri-drag-region')
  })

  it('stops capture exactly once and locks the controls while the final transcript is saved', async () => {
    const user = userEvent.setup()
    let resolveStop!: (state: CaptureState) => void
    const stop = vi.spyOn(arcoBridge, 'stopCapture').mockImplementation(() => new Promise((resolve) => {
      resolveStop = resolve
    }))
    render(<RecordingHud />)

    await screen.findByText('Recording')
    const stopButton = screen.getByRole('button', { name: 'Stop recording' })
    await user.click(stopButton)
    await user.click(stopButton)

    expect(stop).toHaveBeenCalledTimes(1)
    expect(screen.getByText('Saving…')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Ask Arco' })).toBeDisabled()

    resolveStop({ phase: 'idle', activeMeetingId: null, startedAt: null, message: null })
    await waitFor(() => expect(screen.getByText('Saved')).toBeVisible())
  })
})
