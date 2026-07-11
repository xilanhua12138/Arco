import { fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { demoAgentReply, demoMeetingDetails } from '../lib/demoData'
import type { AskAgentInput, ProviderId, RuntimeStatus } from '../types'
import { InsightPanel } from './InsightPanel'

const meeting = demoMeetingDetails['demo-live']

const readyRuntimes: RuntimeStatus[] = [
  { provider: 'codex', available: true, version: 'codex 1', path: '/bin/codex' },
  { provider: 'claude', available: true, version: 'claude 1', path: '/bin/claude' },
]

type AskHandler = ReturnType<typeof vi.fn<(input: AskAgentInput) => Promise<boolean>>>
type SaveHandler = ReturnType<typeof vi.fn<(meetingId: string, turnId: string, saved: boolean) => Promise<boolean>>>

const successfulAsk = (): AskHandler => vi.fn<(input: AskAgentInput) => Promise<boolean>>().mockResolvedValue(true)
const successfulSave = (): SaveHandler => vi.fn<(meetingId: string, turnId: string, saved: boolean) => Promise<boolean>>().mockResolvedValue(true)

const renderPanel = ({
  replies = [],
  runtimes = readyRuntimes,
  provider = 'codex',
  primaryProvider = 'codex',
  isFailover = false,
  onAsk = successfulAsk(),
  onToggleSaved = successfulSave(),
  workspace = null,
  onChooseWorkspace = vi.fn(async () => null),
}: {
  replies?: typeof demoAgentReply[]
  runtimes?: RuntimeStatus[]
  provider?: ProviderId
  primaryProvider?: ProviderId
  isFailover?: boolean
  onAsk?: AskHandler
  onToggleSaved?: SaveHandler
  workspace?: string | null
  onChooseWorkspace?: () => Promise<string | null>
} = {}) => {
  render(
    <InsightPanel
      meeting={meeting}
      replies={replies}
      runtimes={runtimes}
      provider={provider}
      primaryProvider={primaryProvider}
      isFailover={isFailover}
      running={false}
      onAsk={onAsk}
      onToggleSaved={onToggleSaved}
      workspace={workspace}
      onChooseWorkspace={onChooseWorkspace}
    />,
  )
  return { onAsk, onToggleSaved }
}

describe('InsightPanel product safeguards', () => {
  it('is the persistent primary landmark instead of a closable dialog', () => {
    renderPanel()

    expect(screen.getByRole('main', { name: 'Ask Arco' })).toBeVisible()
    expect(screen.queryByRole('dialog', { name: 'Ask Arco' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Close Agent' })).not.toBeInTheDocument()
  })

  it('adds close and live affordances only when reused by the floating Agent surface', () => {
    const onClose = vi.fn()
    render(
      <InsightPanel
        meeting={meeting}
        replies={[]}
        runtimes={readyRuntimes}
        provider="codex"
        primaryProvider="codex"
        isFailover={false}
        running={false}
        live
        onClose={onClose}
        showHeader
        onAsk={successfulAsk()}
        onToggleSaved={successfulSave()}
      />,
    )

    expect(screen.getByText('Live')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Close Agent' })).toBeVisible()
  })

  it('keeps the settled provider out of the conversation chrome', () => {
    renderPanel({ provider: 'codex', primaryProvider: 'codex' })

    expect(screen.queryByRole('combobox', { name: 'Agent provider' })).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Current provider')).not.toBeInTheDocument()
  })

  it('submits every question through the configured primary provider', async () => {
    const user = userEvent.setup()
    const onAsk = successfulAsk()
    renderPanel({ provider: 'codex', primaryProvider: 'codex', onAsk })

    await user.click(screen.getByRole('button', { name: 'Answer what was asked' }))

    expect(onAsk).toHaveBeenCalledWith(expect.objectContaining({ provider: 'codex' }))
  })

  it('uses the configured secondary only when runtime routing explicitly enters failover', async () => {
    const user = userEvent.setup()
    const onAsk = successfulAsk()
    renderPanel({ provider: 'claude', primaryProvider: 'codex', isFailover: true, onAsk })

    expect(screen.getByText('Codex is unavailable. Using Claude.')).toBeVisible()
    await user.click(screen.getByRole('button', { name: 'Answer what was asked' }))

    expect(onAsk).toHaveBeenCalledWith(expect.objectContaining({ provider: 'claude', usedFallback: true }))
  })

  it('keeps the visible Agent history intact across rare provider failover', () => {
    const claudeReply = {
      ...demoAgentReply,
      id: 'demo-turn-claude',
      provider: 'claude' as const,
      usedFallback: true,
      providerSessionId: '63e72a19-dbc0-4954-b157-7df4f873b8ec',
      answer: 'Only Claude should show this answer.',
    }
    renderPanel({ replies: [demoAgentReply, claudeReply], provider: 'codex', primaryProvider: 'codex' })

    expect(screen.getByText(/Arco becomes more than a recorder/)).toBeVisible()
    expect(screen.getByText(claudeReply.answer)).toBeVisible()
    expect(screen.getByText('Claude fallback')).toBeVisible()
    expect(screen.queryByText(claudeReply.providerSessionId)).not.toBeInTheDocument()
  })

  it('never infers historical fallback from the provider configured today', () => {
    const formerPrimaryReply = {
      ...demoAgentReply,
      id: 'demo-turn-former-primary',
      provider: 'claude' as const,
      usedFallback: false,
      answer: 'Claude answered this while it was still the configured primary.',
    }

    renderPanel({ replies: [formerPrimaryReply], provider: 'codex', primaryProvider: 'codex' })

    expect(screen.getByText(formerPrimaryReply.answer)).toBeVisible()
    expect(screen.queryByText('Claude fallback')).not.toBeInTheDocument()
  })

  it('keeps the Agent surface focused on asking about the current meeting', () => {
    renderPanel({ replies: [demoAgentReply] })

    expect(screen.queryByRole('heading', { name: 'Ask Arco' })).not.toBeInTheDocument()
    expect(screen.getByRole('main', { name: 'Ask Arco' })).toBeVisible()
    expect(screen.queryByText(meeting.summary.title ?? 'Untitled meeting')).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Current provider')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Answer what was asked/i })).not.toBeInTheDocument()
    expect(screen.getByText(demoAgentReply.answer)).toBeVisible()
    expect(screen.getByText('Context used')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Save as note' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Copy' })).toBeVisible()
    expect(screen.getByText('This transcript')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Add context' })).toBeVisible()
    expect(screen.queryByRole('combobox', { name: 'Context' })).not.toBeInTheDocument()

    expect(screen.queryByText('Meeting Agent')).not.toBeInTheDocument()
    expect(screen.queryByText(`${meeting.lines.length} transcript lines`)).not.toBeInTheDocument()
    expect(screen.queryByText(/native conversation/i)).not.toBeInTheDocument()
    expect(screen.queryByText('Start with the meeting')).not.toBeInTheDocument()
    expect(screen.queryByText(/native session/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/Sent through/i)).not.toBeInTheDocument()
    expect(screen.queryByText('What do you need in this moment?')).not.toBeInTheDocument()
    expect(screen.queryByText('Draft a direct response to the latest question')).not.toBeInTheDocument()
  })

  it('does not submit while an input method editor is composing', async () => {
    const user = userEvent.setup()
    const { onAsk } = renderPanel()
    const question = screen.getByRole('textbox', { name: 'Ask the agent about this meeting' })
    await user.type(question, '这个决定是什么')

    fireEvent.keyDown(question, { key: 'Enter', code: 'Enter', isComposing: true })

    expect(onAsk).not.toHaveBeenCalled()
    expect(question).toHaveValue('这个决定是什么')
  })

  it('keeps the draft and explains the retry path when the Agent fails', async () => {
    const user = userEvent.setup()
    const onAsk = vi.fn<(input: AskAgentInput) => Promise<boolean>>().mockResolvedValue(false)
    renderPanel({ onAsk })
    const question = screen.getByRole('textbox', { name: 'Ask the agent about this meeting' })
    await user.type(question, 'What should I answer?')
    await user.click(screen.getByRole('button', { name: 'Send question' }))

    expect(question).toHaveValue('What should I answer?')
    expect(screen.getByText('No answer yet. Your question is still here.')).toBeVisible()
  })

  it('removes personal-folder context and uses one previously selected workspace without a path form', async () => {
    const user = userEvent.setup()
    const onAsk = successfulAsk()
    renderPanel({ workspace: '/Users/example/Work/Arco', onAsk })
    expect(screen.queryByText(/Home folder|Personal folder/i)).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Add context' }))
    await user.click(screen.getByRole('menuitem', { name: 'Use Arco workspace' }))
    expect(screen.queryByRole('textbox', { name: 'Workspace path' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Change workspace' })).toHaveTextContent('Arco')

    const question = screen.getByRole('textbox', { name: 'Ask the agent about this meeting' })
    await user.type(question, 'Connect this to the implementation')
    await user.click(screen.getByRole('button', { name: 'Send question' }))
    expect(onAsk).toHaveBeenCalledWith(expect.objectContaining({
      contextScope: 'workspace',
      workspace: '/Users/example/Work/Arco',
    }))
  })

  it('opens the workspace chooser when workspace context has not been configured yet', async () => {
    const user = userEvent.setup()
    const onChooseWorkspace = vi.fn(async () => '/Users/example/Work/Arco')
    renderPanel({ onChooseWorkspace })

    await user.click(screen.getByRole('button', { name: 'Add context' }))
    await user.click(screen.getByRole('menuitem', { name: 'Choose workspace' }))

    expect(onChooseWorkspace).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('textbox', { name: 'Workspace path' })).not.toBeInTheDocument()
  })

  it('presents synthetic sources honestly as context used, not dead buttons', () => {
    renderPanel({ replies: [demoAgentReply] })

    expect(screen.getByText('Context used')).toBeVisible()
    expect(screen.queryByRole('button', { name: /Current transcript · 14:02–14:06/i })).not.toBeInTheDocument()
    expect(screen.getByText('Current transcript · 14:02–14:06')).toBeVisible()
  })

  it('saves an Agent answer as a durable meeting note by stable turn id', async () => {
    const user = userEvent.setup()
    const { onToggleSaved } = renderPanel({ replies: [demoAgentReply] })

    await user.click(screen.getByRole('button', { name: 'Save as note' }))

    expect(onToggleSaved).toHaveBeenCalledWith('demo-live', 'demo-turn-1', true)
  })
})
