import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { arcoBridge } from '../lib/bridge'
import { PROVIDER_CONFIG_STORAGE_KEY } from '../lib/providerConfig'
import { AgentOverlay } from './AgentOverlay'

describe('AgentOverlay', () => {
  beforeEach(() => {
    window.history.replaceState({}, '', '/?surface=agent-overlay&demo=1')
    window.localStorage.setItem(PROVIDER_CONFIG_STORAGE_KEY, JSON.stringify({
      setupComplete: true,
      primary: 'codex',
      secondary: 'claude',
    }))
  })

  it('reuses the meeting Agent workspace as a focused floating conversation', async () => {
    render(<AgentOverlay />)

    const dialog = await screen.findByRole('dialog', { name: 'Ask Arco' })
    expect(dialog).toBeVisible()
    expect(screen.getByText('Live')).toBeVisible()
    expect(screen.getByRole('textbox', { name: 'Ask the agent about this meeting' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Answer what was asked' })).toBeVisible()
    expect(screen.getByRole('complementary', { name: 'Meeting transcript' })).toBeVisible()
    expect(screen.getByText(/It should know enough about my work/)).toBeVisible()
    expect(screen.queryByText(/Codex native session|This transcript ·|Deepgram/i)).not.toBeInTheDocument()
  })

  it('collapses transcript evidence and resizes the native utility window without losing the Agent', async () => {
    const user = userEvent.setup()
    const resize = vi.spyOn(arcoBridge, 'setAgentTranscriptVisible').mockResolvedValue(undefined)
    render(<AgentOverlay />)

    await screen.findByRole('complementary', { name: 'Meeting transcript' })
    await user.click(screen.getByRole('button', { name: 'Hide transcript' }))

    expect(screen.queryByRole('complementary', { name: 'Meeting transcript' })).not.toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Ask the agent about this meeting' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Show transcript' })).toBeVisible()
    expect(resize).toHaveBeenLastCalledWith(false)

    await user.click(screen.getByRole('button', { name: 'Show transcript' }))
    expect(await screen.findByRole('complementary', { name: 'Meeting transcript' })).toBeVisible()
    expect(resize).toHaveBeenLastCalledWith(true)
  })

  it('hides rather than destroys the native conversation window', async () => {
    const user = userEvent.setup()
    const hide = vi.spyOn(arcoBridge, 'hideAgentOverlay').mockResolvedValue(undefined)
    render(<AgentOverlay />)

    await screen.findByRole('dialog', { name: 'Ask Arco' })
    await user.click(screen.getByRole('button', { name: 'Close Agent' }))

    expect(hide).toHaveBeenCalledTimes(1)
  })
})
