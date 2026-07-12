import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import App from './App'
import { arcoBridge } from './lib/bridge'
import { demoAgentReply } from './lib/demoData'
import {
  loadGenerationSettings,
  saveGenerationSettings,
} from './lib/generationSettings'
import {
  PROVIDER_CONFIG_STORAGE_KEY,
  loadProviderConfig,
  saveProviderConfig,
} from './lib/providerConfig'
import { completeOnboarding, ONBOARDING_STORAGE_KEY } from './lib/onboarding'
import type { CaptureState, MeetingDetail, MeetingSummary } from './types'

const findAgentWorkspace = () => screen.findByRole('main', { name: 'Ask Arco' })
const findTranscriptEvidence = () => screen.findByRole('complementary', { name: 'Meeting transcript' })

const openHistory = async (user: ReturnType<typeof userEvent.setup>) => {
  await user.click(await screen.findByRole('button', { name: 'Open meeting history' }))
  return screen.findByRole('heading', { level: 1, name: 'History' })
}

const pastA: MeetingSummary & { title: string } = {
  id: 'past-a',
  title: 'Past meeting A',
  startedAt: '2026-07-09T10:00:00+08:00',
  durationLabel: '20 min',
  preview: 'The older meeting remains available for review.',
  path: '/tmp/past-a.md',
  utteranceCount: 1,
  isLive: false,
  source: 'arco',
  generatedSummary: null,
  titleGenerationStatus: 'idle',
  summaryGenerationStatus: 'idle',
}

const liveB: MeetingSummary & { title: string } = {
  id: 'live-b',
  title: 'Live meeting B',
  startedAt: '2026-07-10T15:00:00+08:00',
  durationLabel: 'Live',
  preview: 'The newly started live meeting.',
  path: '/tmp/live-b.md',
  utteranceCount: 1,
  isLive: true,
  source: 'arco',
  generatedSummary: null,
  titleGenerationStatus: 'idle',
  summaryGenerationStatus: 'idle',
}

const idleCapture: CaptureState = {
  phase: 'idle',
  activeMeetingId: null,
  startedAt: null,
  message: null,
}

const liveCapture: CaptureState = {
  phase: 'recording',
  activeMeetingId: liveB.id,
  startedAt: liveB.startedAt,
  message: 'Listening',
}

const detail = (summary: MeetingSummary, text: string): MeetingDetail => ({
  summary,
  lines: [{ id: `${summary.id}-1`, timestamp: '15:00:01', speaker: 'Remote 1', text, sequence: 1 }],
})

beforeEach(() => {
  window.history.replaceState({}, '', '/?demo=1')
  window.localStorage.removeItem('arco.agentWorkspace')
  saveProviderConfig({ setupComplete: true, primary: 'codex', secondary: 'claude' })
  completeOnboarding(false)
})

describe('Arco consumer conversation workspace', () => {
  it('guides the first launch through Agent, transcription, audio, shortcut, and first meeting', async () => {
    const user = userEvent.setup()
    const runtimeStatus = vi.spyOn(arcoBridge, 'runtimeStatus')
    vi.spyOn(arcoBridge, 'deepgramCredentialStatus').mockResolvedValue({ configured: true, verified: true, message: null })
    window.localStorage.removeItem(PROVIDER_CONFIG_STORAGE_KEY)
    window.localStorage.removeItem(ONBOARDING_STORAGE_KEY)

    render(<App />)

    const landing = await screen.findByRole('main', { name: 'Stay in the conversation' })
    expect(within(landing).getByRole('button', { name: 'Set up later' })).toBeVisible()
    expect(screen.queryByRole('navigation', { name: 'Main navigation' })).not.toBeInTheDocument()

    await user.click(within(landing).getByRole('button', { name: 'Continue' }))
    const setup = await screen.findByRole('main', { name: 'Agent' })
    expect(await within(setup).findByRole('heading', { name: 'Your meeting Agent' })).toBeVisible()
    await user.click(within(setup).getByRole('button', { name: 'Re-check' }))
    await waitFor(() => expect(runtimeStatus).toHaveBeenCalledTimes(2))
    await user.click(within(setup).getByRole('button', { name: 'Test Codex' }))
    expect(await within(setup).findByText('Codex is ready.')).toBeVisible()
    await user.click(within(setup).getByRole('button', { name: 'Continue' }))

    expect(within(setup).getByRole('heading', { name: 'Choose transcription' })).toBeVisible()
    expect(await within(setup).findByText('Deepgram is ready.')).toBeVisible()
    await user.click(within(setup).getByRole('button', { name: 'Continue' }))

    await user.click(within(setup).getByRole('button', { name: 'Check audio' }))
    expect(await within(setup).findByText('Microphone is ready')).toBeVisible()
    await user.click(within(setup).getByRole('button', { name: 'Continue' }))

    expect(within(setup).getByRole('heading', { name: 'Start from anywhere' })).toBeVisible()
    await user.click(within(setup).getByRole('button', { name: 'Continue' }))
    await user.click(within(setup).getByRole('button', { name: 'Open Arco' }))

    expect(screen.queryByRole('main', { name: 'First meeting' })).not.toBeInTheDocument()
    expect(loadProviderConfig()).toEqual({ setupComplete: true, primary: 'codex', secondary: null })
    expect(await findAgentWorkspace()).toBeVisible()
    expect(await findTranscriptEvidence()).toBeVisible()
    expect(screen.queryByRole('button', { name: /Open Agent|Close Agent/i })).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Current provider')).not.toBeInTheDocument()
    expect(screen.queryByRole('combobox', { name: 'Agent provider' })).not.toBeInTheDocument()
  })

  it('uses one focused CTA instead of an empty Transcript and Agent workspace before the first meeting', async () => {
    const user = userEvent.setup()
    vi.spyOn(arcoBridge, 'listMeetings').mockResolvedValue([])
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(idleCapture)
    const startCapture = vi.spyOn(arcoBridge, 'startCapture').mockResolvedValue(liveCapture)

    render(<App />)

    const idle = await screen.findByRole('region', { name: 'Start listening' })
    expect(within(idle).getByRole('heading', { name: 'Start listening' })).toBeVisible()
    expect(within(idle).queryByText('Start a new meeting when you are ready. Its live transcript and Agent will appear here.')).not.toBeInTheDocument()
    const shortcuts = within(idle).getByRole('region', { name: 'Shortcuts' })
    expect([...shortcuts.querySelectorAll('kbd')].map((key) => key.textContent)).toEqual(['Fn', 'M', '⌘', 'K'])
    expect(within(idle).getByRole('region', { name: 'On this Mac' })).toHaveTextContent('0')
    expect(screen.queryByRole('heading', { name: 'Transcript' })).not.toBeInTheDocument()
    expect(screen.queryByRole('main', { name: 'Ask Arco' })).not.toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: 'Start listening' })).toHaveLength(1)

    await user.click(within(idle).getByRole('button', { name: 'Start listening' }))
    expect(startCapture).toHaveBeenCalledWith('both', expect.any(Object))
  })

  it('keeps Current in its start-listening state while idle even when History has meetings', async () => {
    vi.spyOn(arcoBridge, 'listMeetings').mockResolvedValue([pastA])
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(idleCapture)
    vi.spyOn(arcoBridge, 'readMeeting').mockResolvedValue(detail(pastA, 'Historical evidence from A'))

    render(<App />)

    expect(await screen.findByRole('region', { name: 'Start listening' })).toBeVisible()
    expect(screen.queryByRole('heading', { level: 1, name: pastA.title })).not.toBeInTheDocument()
    expect(screen.queryByRole('complementary', { name: 'Meeting transcript' })).not.toBeInTheDocument()
    expect(screen.queryByRole('main', { name: 'Ask Arco' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Open current meeting' })).toHaveAttribute('aria-current', 'page')
  })

  it('restores full local statistics when returning from a filtered History search', async () => {
    const secondPast = { ...liveB, id: 'past-b', title: 'Past meeting B', isLive: false, durationLabel: '10 min' }
    vi.spyOn(arcoBridge, 'listMeetings').mockImplementation(async (query = '') => (
      query.trim() ? [pastA] : [pastA, secondPast]
    ))
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(idleCapture)
    vi.spyOn(arcoBridge, 'readMeeting').mockImplementation(async (id) => (
      id === pastA.id
        ? detail(pastA, 'Historical evidence from A')
        : detail(secondPast, 'Historical evidence from B')
    ))

    const user = userEvent.setup()
    render(<App />)
    let idle = await screen.findByRole('region', { name: 'Start listening' })
    const initialStats = within(idle).getByRole('region', { name: 'On this Mac' })
    expect(within(initialStats).getByText('Meetings').closest('div')).toHaveTextContent('2')

    await openHistory(user)
    await user.type(screen.getByRole('textbox', { name: 'Search meetings' }), 'older')
    await waitFor(() => expect(arcoBridge.listMeetings).toHaveBeenCalledWith('older'))
    await user.click(screen.getByRole('button', { name: 'Open current meeting' }))

    idle = await screen.findByRole('region', { name: 'Start listening' })
    const restoredStats = within(idle).getByRole('region', { name: 'On this Mac' })
    await waitFor(() => expect(within(restoredStats).getByText('Meetings').closest('div')).toHaveTextContent('2'))
  })

  it('lets a first-time user postpone setup and enter transcript-only Arco', async () => {
    const user = userEvent.setup()
    window.localStorage.removeItem(PROVIDER_CONFIG_STORAGE_KEY)
    window.localStorage.removeItem(ONBOARDING_STORAGE_KEY)
    vi.spyOn(arcoBridge, 'listMeetings').mockResolvedValue([])
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(idleCapture)

    render(<App />)
    const setup = await screen.findByRole('main', { name: 'Stay in the conversation' })
    await user.click(within(setup).getByRole('button', { name: 'Set up later' }))

    expect(screen.queryByRole('main', { name: 'Stay in the conversation' })).not.toBeInTheDocument()
    expect(await screen.findByRole('region', { name: 'Start listening' })).toBeVisible()
    expect(screen.queryByRole('main', { name: 'Ask Arco' })).not.toBeInTheDocument()
  })

  it('uses the configured secondary only when the primary CLI is unavailable', async () => {
    const user = userEvent.setup()
    vi.spyOn(arcoBridge, 'runtimeStatus').mockResolvedValue([
      { provider: 'codex', available: false, version: null, path: null },
      { provider: 'claude', available: true, version: 'claude 1', path: '/bin/claude' },
    ])
    const runAgent = vi.spyOn(arcoBridge, 'runAgent')

    render(<App />)
    const agent = await findAgentWorkspace()

    expect(within(agent).getByText('Codex is unavailable. Using Claude.')).toBeVisible()
    await user.click(within(agent).getByRole('button', { name: 'Answer what was asked' }))
    await waitFor(() => expect(runAgent).toHaveBeenCalledWith(expect.objectContaining({ provider: 'claude' })))
  })

  it('opens on Current with transcript primary and Agent visible alongside it', async () => {
    render(<App />)

    expect(await screen.findByRole('heading', {
      level: 1,
      name: 'Product direction · weekly working session',
    })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Open current meeting' })).toHaveAttribute('aria-current', 'page')
    expect(await findAgentWorkspace()).toBeVisible()
    expect(await findTranscriptEvidence()).toBeVisible()
    expect(screen.getByText(/It should know enough about my work/)).toBeVisible()
    expect(screen.getByRole('button', { name: 'Meeting details' })).toBeVisible()
    expect(screen.queryByText('On this Mac')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Open Agent|Close Agent/i })).not.toBeInTheDocument()
    expect(screen.queryByRole('dialog', { name: 'Ask Arco' })).not.toBeInTheDocument()
  })

  it('exposes exactly one global capture action', async () => {
    render(<App />)

    expect(await screen.findAllByRole('button', { name: 'Stop listening' })).toHaveLength(1)
    const capture = screen.getByRole('region', { name: 'Audio capture · Hybrid · System and room audio' })
    expect(capture).toHaveTextContent('Listening')
    expect(capture).toHaveTextContent('Hybrid')
    expect(capture).not.toHaveTextContent('Product direction · weekly working session')
    expect(within(capture).getAllByRole('button')).toHaveLength(1)
  })

  it('keeps mixed remote and room speakers distinct and never invents You', async () => {
    const user = userEvent.setup()
    render(<App />)

    expect((await screen.findAllByLabelText('Remote 1, system audio')).length).toBeGreaterThanOrEqual(2)
    expect(screen.getAllByLabelText('In room 2, room mic').length).toBeGreaterThanOrEqual(2)
    expect(screen.queryByText('Location labels, not identities')).not.toBeInTheDocument()
    expect(screen.queryByText('You')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Meeting details' }))
    expect(screen.getByLabelText('System audio speakers: Remote 1, Remote 2')).toHaveTextContent('Remote 1, Remote 2')
    expect(screen.getByLabelText('Room microphone speakers: In room 1, In room 2')).toHaveTextContent('In room 1, In room 2')
    expect(screen.getByText('Location labels, not identities')).toBeVisible()
  })

  it('treats History as a page with search and empty-result guidance', async () => {
    const user = userEvent.setup()
    render(<App />)
    expect(await findAgentWorkspace()).toBeVisible()
    expect(await findTranscriptEvidence()).toBeVisible()
    await openHistory(user)

    expect(screen.getByRole('button', { name: 'Open meeting history' })).toHaveAttribute('aria-current', 'page')
    expect(screen.queryByRole('main', { name: 'Ask Arco' })).not.toBeInTheDocument()
    expect(screen.queryByRole('complementary', { name: 'Meeting transcript' })).not.toBeInTheDocument()
    const search = screen.getByRole('textbox', { name: 'Search meetings' })
    await user.type(search, 'a phrase that cannot exist')

    expect(await screen.findByText('No matching meetings')).toBeVisible()
    expect(screen.getByText('Try a phrase from the transcript or clear your search.')).toBeVisible()
  })

  it('opens a selected meeting as History review without turning it into Current', async () => {
    const user = userEvent.setup()
    render(<App />)
    await openHistory(user)

    expect(screen.getByRole('button', { name: /Benchmark review with Estrella/i })).toBeVisible()
    const search = screen.getByRole('textbox', { name: 'Search meetings' })
    await user.type(search, 'Benchmark review')
    await user.clear(search)

    await user.click(screen.getByRole('button', { name: /Benchmark review with Estrella/i }))

    expect(await screen.findByRole('heading', { level: 1, name: 'Benchmark review with Estrella' })).toBeVisible()
    await act(async () => { await new Promise((resolve) => window.setTimeout(resolve, 220)) })
    expect(screen.getByRole('heading', { level: 1, name: 'Benchmark review with Estrella' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Open meeting history' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('button', { name: 'Open current meeting' })).not.toHaveAttribute('aria-current')
    expect(await findAgentWorkspace()).toBeVisible()
    expect(await findTranscriptEvidence()).toBeVisible()
    expect(screen.queryByRole('heading', { level: 1, name: 'History' })).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Back to History' }))

    expect(await screen.findByRole('heading', { level: 1, name: 'History' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Open meeting history' })).toHaveAttribute('aria-current', 'page')
    expect(screen.queryByRole('heading', { level: 1, name: 'Benchmark review with Estrella' })).not.toBeInTheDocument()
  })

  it('returns Current to the start-listening state after stopping an active meeting', async () => {
    vi.spyOn(arcoBridge, 'listMeetings').mockResolvedValue([liveB, pastA])
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(liveCapture)
    vi.spyOn(arcoBridge, 'readMeeting').mockImplementation(async (id) => (
      id === liveB.id
        ? detail(liveB, 'Live evidence from B')
        : detail(pastA, 'Historical evidence from A')
    ))
    vi.spyOn(arcoBridge, 'stopCapture').mockResolvedValue(idleCapture)

    const user = userEvent.setup()
    render(<App />)
    expect(await screen.findByRole('heading', { level: 1, name: liveB.title })).toBeVisible()

    await user.click(screen.getByRole('button', { name: 'Stop listening' }))

    expect(await screen.findByRole('region', { name: 'Start listening' })).toBeVisible()
    expect(screen.queryByRole('heading', { level: 1, name: liveB.title })).not.toBeInTheDocument()
    expect(screen.queryByRole('complementary', { name: 'Meeting transcript' })).not.toBeInTheDocument()
  })

  it('opens History search with Command K and hides the Current workspace', async () => {
    const user = userEvent.setup()
    render(<App />)
    expect(await findAgentWorkspace()).toBeVisible()

    await user.keyboard('{Meta>}k{/Meta}')

    expect(await screen.findByRole('heading', { level: 1, name: 'History' })).toBeVisible()
    expect(screen.queryByRole('main', { name: 'Ask Arco' })).not.toBeInTheDocument()
    expect(screen.queryByRole('complementary', { name: 'Meeting transcript' })).not.toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Search meetings' })).toHaveFocus()
  })

  it('chooses an Agent workspace natively once and reuses it without a per-question path field', async () => {
    const user = userEvent.setup()
    const runAgent = vi.spyOn(arcoBridge, 'runAgent')
    const chooseWorkspace = vi.spyOn(arcoBridge, 'chooseAgentWorkspace').mockResolvedValue('/Users/example/Work/Arco')
    render(<App />)
    await findAgentWorkspace()

    await user.click(screen.getByRole('button', { name: 'Add context' }))
    await user.click(screen.getByRole('menuitem', { name: 'Choose workspace' }))
    const send = screen.getByRole('button', { name: 'Send question' })
    const question = screen.getByRole('textbox', { name: 'Ask the agent about this meeting' })

    await waitFor(() => expect(chooseWorkspace).toHaveBeenCalledTimes(1))
    expect(screen.queryByRole('textbox', { name: 'Workspace path' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Change workspace' })).toHaveTextContent('Arco')
    await user.type(question, 'Connect this decision to the implementation plan.')
    expect(send).toBeEnabled()
    expect(screen.getByText('This transcript')).toBeVisible()
    expect(screen.queryByText(/Sent through your Codex CLI/)).not.toBeInTheDocument()
    await user.click(send)

    await waitFor(() => expect(runAgent).toHaveBeenCalledWith(expect.objectContaining({
      contextScope: 'workspace',
      workspace: '/Users/example/Work/Arco',
      question: 'Connect this decision to the implementation plan.',
    })))
    expect(chooseWorkspace).toHaveBeenCalledTimes(1)
  })

  it('keeps sourced Agent answers attached to the current meeting', async () => {
    const user = userEvent.setup()
    render(<App />)
    const agent = await findAgentWorkspace()

    await user.click(within(agent).getByRole('button', { name: /Answer what was asked/i }))

    expect(await screen.findByText(/Arco becomes more than a recorder/)).toBeVisible()
    const contextDisclosure = screen.getByRole('button', { name: 'Context used · 2' })
    expect(contextDisclosure).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByText('Current transcript · 14:02–14:06')).not.toBeInTheDocument()

    await user.click(contextDisclosure)

    expect(screen.getByText('Current transcript · 14:02–14:06')).toBeVisible()
    expect(contextDisclosure).toHaveAttribute('aria-expanded', 'true')
    expect(screen.queryByText(/Codex native session · This transcript/i)).not.toBeInTheDocument()
  })

  it('loads the persisted Agent thread when a meeting is reopened', async () => {
    const persisted = {
      ...demoAgentReply,
      id: 'persisted-turn',
      question: 'What did we decide?',
      answer: 'The persisted answer survives an app restart.',
      savedAsNote: true,
    }
    const listAgentTurns = vi.spyOn(arcoBridge, 'listAgentTurns').mockResolvedValue([persisted])

    render(<App />)
    const agent = await findAgentWorkspace()

    expect(listAgentTurns).toHaveBeenCalledWith('demo-live')
    expect(within(agent).getByText('What did we decide?')).toBeVisible()
    expect(within(agent).getByText('The persisted answer survives an app restart.')).toBeVisible()
    expect(within(agent).getByRole('button', { name: 'Saved note' })).toBeVisible()
  })

  it('collects saved Agent answers in Notes and opens their source meeting', async () => {
    const user = userEvent.setup()
    const savedTurn = {
      ...demoAgentReply,
      id: 'saved-note-turn',
      meetingId: pastA.id,
      question: 'What did we decide about the release?',
      answer: 'Keep the evidence visible and ship the Notes collection.',
      createdAt: '2026-07-09T10:17:00+08:00',
      savedAsNote: true,
    }
    const savedNote = {
      id: 'local:note-agent-saved-note-turn.md',
      title: savedTurn.question,
      body: savedTurn.answer,
      source: 'agent' as const,
      createdAt: savedTurn.createdAt,
      updatedAt: savedTurn.createdAt,
      path: '/tmp/notes/note-agent-saved-note-turn.md',
      meetingId: pastA.id,
      meetingTitle: pastA.title,
      agentTurnId: savedTurn.id,
    }
    const listNotes = vi.spyOn(arcoBridge, 'listNotes').mockImplementation(async () => [savedNote])
    vi.spyOn(arcoBridge, 'readMeeting').mockImplementation(async (id) => (
      id === pastA.id
        ? detail(pastA, 'Historical evidence from A')
        : detail(liveB, 'Live evidence from B')
    ))

    render(<App />)
    await user.click(await screen.findByRole('button', { name: 'Open saved notes' }))

    expect(await screen.findByRole('heading', { level: 1, name: 'Notes' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Open saved notes' })).toHaveAttribute('aria-current', 'page')
    expect(await screen.findByRole('button', { name: pastA.title })).toBeVisible()
    expect(screen.getByText(savedTurn.question)).toBeVisible()
    expect(screen.getByRole('textbox', { name: 'Markdown note' })).toHaveValue(savedTurn.answer)
    expect(screen.queryByRole('main', { name: 'Ask Arco' })).not.toBeInTheDocument()

    await user.type(screen.getByRole('textbox', { name: 'Search notes' }), 'release')
    await waitFor(() => expect(listNotes).toHaveBeenLastCalledWith('release'))

    await user.click(screen.getByRole('button', { name: pastA.title }))
    expect(await screen.findByRole('heading', { level: 1, name: pastA.title })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Open meeting history' })).toHaveAttribute('aria-current', 'page')
  })

  it('teaches how to create the first note without inventing an empty editor', async () => {
    const user = userEvent.setup()
    vi.spyOn(arcoBridge, 'listNotes').mockResolvedValue([])

    render(<App />)
    await user.click(await screen.findByRole('button', { name: 'Open saved notes' }))

    expect(await screen.findByText('No notes yet')).toBeVisible()
    expect(screen.getByText('Create a Markdown note for a meeting to start writing.')).toBeVisible()
  })

  it('lets the user enter Notes and write a standalone Markdown note', async () => {
    const user = userEvent.setup()
    vi.spyOn(arcoBridge, 'listNotes').mockResolvedValue([])
    const saveNote = vi.spyOn(arcoBridge, 'saveNote').mockImplementation(async (input) => ({
      id: 'local:note-20260712.md',
      title: input.title,
      body: input.body,
      source: 'manual',
      createdAt: '2026-07-12T17:20:00+08:00',
      updatedAt: '2026-07-12T17:20:00+08:00',
      path: '/Users/demo/Library/Application Support/Arco/notes/note-20260712.md',
      meetingId: input.meetingId,
      meetingTitle: 'Untitled meeting',
      agentTurnId: null,
    }))

    render(<App />)
    await user.click(await screen.findByRole('button', { name: 'Open saved notes' }))
    await user.click(await screen.findByRole('button', { name: 'New note' }))
    await user.selectOptions(screen.getByRole('combobox', { name: 'Meeting for this note' }), 'demo-live')
    await user.type(screen.getByRole('textbox', { name: 'Note title' }), 'Interview follow-ups')
    await user.type(screen.getByRole('textbox', { name: 'Markdown note' }), '- Ask about the rollout\n- Confirm the owner')
    await user.click(screen.getByRole('button', { name: 'Save note' }))

    await waitFor(() => expect(saveNote).toHaveBeenCalledWith({
      id: null,
      meetingId: 'demo-live',
      title: 'Interview follow-ups',
      body: '- Ask about the rollout\n- Confirm the owner',
    }))
    expect(await screen.findByText('Saved')).toBeVisible()
  })

  it('opens General settings by default and navigates to audio, runtime, and privacy', async () => {
    const user = userEvent.setup()
    render(<App />)
    await user.click(await screen.findByRole('button', { name: 'Open settings' }))

    expect(await screen.findByRole('dialog', { name: 'General' })).toBeVisible()
    expect(screen.getByRole('combobox', { name: 'App language' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Change listening shortcut' })).toBeVisible()
    expect(screen.queryByRole('button', { name: 'Shortcuts' })).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /Audio & speakers/i }))
    expect(screen.getByRole('dialog', { name: 'Audio & speakers' })).toBeVisible()
    expect(screen.getByText('Recognition')).toBeVisible()
    expect(screen.getByText('Chinese')).toBeVisible()

    await user.click(screen.getByRole('button', { name: /Agent runtime/i }))
    const agentSettings = screen.getByRole('dialog', { name: 'Agent runtime' })
    expect(agentSettings).toBeVisible()
    expect(within(agentSettings).getAllByText('Codex CLI')).toHaveLength(1)
    expect(within(agentSettings).getByText('Claude Code')).toBeVisible()

    await user.click(screen.getByRole('button', { name: /Data & privacy/i }))
    expect(screen.getByRole('dialog', { name: 'Data & privacy' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Meeting transcript storage' })).toHaveTextContent('Default')
    expect(screen.getByRole('button', { name: 'Meeting transcript storage' })).toHaveTextContent('/Users/demo/Library/Application Support/Arco/transcripts')
    expect(screen.getByText('Stored in Arco on this Mac')).toBeVisible()
  })

  it('opens Audio & speakers directly from the idle Current audio control', async () => {
    const user = userEvent.setup()
    vi.spyOn(arcoBridge, 'listMeetings').mockResolvedValue([])
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(idleCapture)

    render(<App />)
    await user.click(await screen.findByRole('button', { name: 'Next meeting audio' }))

    expect(screen.getByRole('dialog', { name: 'Audio & speakers' })).toBeVisible()
    expect(screen.getByRole('radio', { name: /Hybrid meeting/i })).toBeChecked()
  })

  it('loads and saves Meeting output rules through the Settings subpage', async () => {
    const user = userEvent.setup()
    saveGenerationSettings({
      title: { enabled: true, promptOverride: 'Use the decision as the title.' },
      summary: { enabled: false, promptOverride: null },
    })
    render(<App />)

    await user.click(await screen.findByRole('button', { name: 'Open settings' }))
    await user.click(screen.getByRole('button', { name: 'Meeting output' }))
    expect(screen.getByRole('button', { name: /Automatic title/i })).toHaveTextContent('On · Custom')
    expect(screen.getByRole('button', { name: /End-of-meeting summary/i })).toHaveTextContent('Off')

    await user.click(screen.getByRole('button', { name: /Automatic title/i }))
    const prompt = screen.getByRole('textbox', { name: 'Prompt' })
    expect(prompt).toHaveValue('Use the decision as the title.')
    await user.clear(prompt)
    await user.type(prompt, 'Name the outcome, not the calendar slot.')
    await user.click(screen.getByRole('button', { name: 'Save changes' }))

    expect(loadGenerationSettings()).toEqual({
      title: { enabled: true, promptOverride: 'Name the outcome, not the calendar slot.' },
      summary: { enabled: false, promptOverride: null },
    })
    expect(screen.getByRole('button', { name: /Automatic title/i })).toHaveTextContent('On · Custom')
  })

  it('edits the settled primary and secondary configuration from Settings without changing it on cancel', async () => {
    const user = userEvent.setup()
    render(<App />)
    await user.click(await screen.findByRole('button', { name: 'Open settings' }))
    await user.click(screen.getByRole('button', { name: /Agent runtime/i }))
    await user.click(screen.getByRole('button', { name: 'Edit configuration' }))

    const setup = screen.getByRole('dialog', { name: 'Connect Codex or Claude' })
    expect(within(setup).getByRole('button', { name: 'Choose providers' })).toHaveAttribute('aria-current', 'step')
    expect(within(setup).getByRole('radio', { name: 'Codex as primary' })).toBeChecked()
    expect(within(setup).getByRole('radio', { name: 'Claude as secondary' })).toBeChecked()

    await user.click(within(setup).getByRole('button', { name: 'Cancel setup' }))

    expect(screen.queryByRole('dialog', { name: 'Connect Codex or Claude' })).not.toBeInTheDocument()
    expect(loadProviderConfig()).toEqual({ setupComplete: true, primary: 'codex', secondary: 'claude' })
  })
})

describe('capture session and viewed meeting invariants', () => {
  it('renames the selected meeting in place and updates the history row without a modal', async () => {
    const user = userEvent.setup()
    const renamed = { ...pastA, title: 'Decision review' }
    let meetings: MeetingSummary[] = [pastA]
    vi.spyOn(arcoBridge, 'listMeetings').mockImplementation(async () => meetings)
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(idleCapture)
    vi.spyOn(arcoBridge, 'readMeeting').mockResolvedValue(detail(pastA, 'Historical evidence from A'))
    const renameMeeting = vi.spyOn(arcoBridge, 'renameMeeting').mockImplementation(async () => {
      meetings = [renamed]
      return renamed
    })

    render(<App />)

    expect(await screen.findByRole('region', { name: 'Start listening' })).toBeVisible()
    await openHistory(user)
    await user.click(screen.getByRole('button', { name: new RegExp(pastA.title) }))
    expect(await screen.findByRole('heading', { level: 1, name: pastA.title })).toBeVisible()
    await user.click(screen.getByRole('button', { name: 'Rename meeting' }))
    const title = screen.getByRole('textbox', { name: 'Meeting title' })
    await user.clear(title)
    await user.type(title, '  Decision review  {Enter}')

    await waitFor(() => expect(renameMeeting).toHaveBeenCalledWith(pastA.id, 'Decision review'))
    expect(await screen.findByRole('heading', { level: 1, name: 'Decision review' })).toBeVisible()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()

    await openHistory(user)
    expect(screen.getByRole('button', { name: /Decision review/ })).toBeVisible()
  })

  it('uses the same untitled placeholder for a live meeting and its return banner', async () => {
    const user = userEvent.setup()
    const untitledLive = { ...liveB, title: null }
    vi.spyOn(arcoBridge, 'listMeetings').mockResolvedValue([untitledLive, pastA])
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue({ ...liveCapture, activeMeetingId: untitledLive.id })
    vi.spyOn(arcoBridge, 'readMeeting').mockImplementation(async (id) => (
      id === untitledLive.id
        ? detail(untitledLive, 'Live evidence without a title')
        : detail(pastA, 'Historical evidence from A')
    ))

    render(<App />)
    expect(await screen.findByRole('heading', { level: 1, name: 'Untitled meeting' })).toBeVisible()
    expect(screen.queryByText(/Meeting ·/i)).not.toBeInTheDocument()

    await openHistory(user)
    await user.click(screen.getByRole('button', { name: new RegExp(pastA.title) }))

    expect(await screen.findByRole(
      'heading',
      { level: 1, name: pastA.title },
      { timeout: 3_000 },
    )).toBeVisible()
    expect(screen.getByRole('button', { name: 'Return to live meeting Untitled meeting' })).toBeVisible()
    expect(screen.queryByText(/Meeting ·/i)).not.toBeInTheDocument()
  })

  it('restores the preferred meeting audio scenario on the next launch', async () => {
    window.localStorage.setItem('arco.audioMode', 'system')
    vi.spyOn(arcoBridge, 'listMeetings').mockResolvedValue([pastA])
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(idleCapture)
    vi.spyOn(arcoBridge, 'readMeeting').mockResolvedValue(detail(pastA, 'Historical evidence from A'))

    render(<App />)

    const captureRegion = await screen.findByRole('region', { name: 'Audio capture · Online · System audio' })
    expect(captureRegion).toHaveTextContent('Online')
    expect(captureRegion).not.toHaveTextContent('System')
    expect(within(captureRegion).queryByText('Room')).not.toBeInTheDocument()
  })

  it('opens the new live meeting when starting from idle while viewing an older meeting', async () => {
    const user = userEvent.setup()
    const nativeSetTimeout = window.setTimeout
    vi.spyOn(window, 'setTimeout').mockImplementation(((handler: TimerHandler, timeout?: number, ...args: unknown[]) => {
      if (timeout === 180) return 1
      return nativeSetTimeout(handler, timeout, ...args)
    }) as typeof window.setTimeout)
    let capture = idleCapture
    let started = false
    const readMeeting = vi.spyOn(arcoBridge, 'readMeeting').mockImplementation(async (id) => {
      if (id === liveB.id) return detail(liveB, 'First live words from B')
      return detail(pastA, 'Old evidence from A')
    })
    vi.spyOn(arcoBridge, 'listMeetings').mockImplementation(async () => started ? [liveB, pastA] : [pastA])
    vi.spyOn(arcoBridge, 'captureStatus').mockImplementation(async () => capture)
    vi.spyOn(arcoBridge, 'startCapture').mockImplementation(async () => {
      started = true
      capture = liveCapture
      return liveCapture
    })

    render(<App />)
    const idle = await screen.findByRole('region', { name: 'Start listening' })
    expect(screen.queryByRole('heading', { level: 1, name: pastA.title })).not.toBeInTheDocument()

    await user.click(within(idle).getByRole('button', { name: 'Start listening' }))

    expect(await screen.findByRole('heading', { level: 1, name: liveB.title })).toBeVisible()
    expect(screen.getByText('First live words from B')).toBeVisible()
    expect(readMeeting).toHaveBeenCalledWith(liveB.id)
  })

  it('polls the active live meeting while reviewing A and Current returns to B', async () => {
    const user = userEvent.setup()
    let pollCapture: (() => void) | null = null
    const nativeSetInterval = window.setInterval
    vi.spyOn(window, 'setInterval').mockImplementation(((handler: TimerHandler, timeout?: number, ...args: unknown[]) => {
      if (timeout === 1_200) {
        pollCapture = typeof handler === 'function' ? handler as () => void : null
        return 1
      }
      return nativeSetInterval(handler, timeout, ...args)
    }) as typeof window.setInterval)
    const readMeeting = vi.spyOn(arcoBridge, 'readMeeting').mockImplementation(async (id) => {
      if (id === liveB.id) return detail(liveB, 'Live evidence from B')
      return detail(pastA, 'Historical evidence from A')
    })
    vi.spyOn(arcoBridge, 'listMeetings').mockImplementation(async (query = '') => (
      query.trim() ? [pastA] : [liveB, pastA]
    ))
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(liveCapture)

    render(<App />)
    expect(await screen.findByRole('heading', { level: 1, name: liveB.title })).toBeVisible()
    await waitFor(() => expect(pollCapture).not.toBeNull())
    await openHistory(user)
    await user.type(screen.getByRole('textbox', { name: 'Search meetings' }), 'historical')
    await waitFor(() => expect(arcoBridge.listMeetings).toHaveBeenCalledWith('historical'))
    await user.click(screen.getByRole('button', { name: new RegExp(pastA.title) }))
    expect(await screen.findByRole('heading', { level: 1, name: pastA.title })).toBeVisible()
    expect(screen.getByRole('button', { name: `Return to live meeting ${liveB.title}` })).toBeVisible()

    readMeeting.mockClear()
    await act(async () => { pollCapture?.() })
    expect(readMeeting).toHaveBeenCalledWith(liveB.id)
    expect(readMeeting).not.toHaveBeenCalledWith(pastA.id)

    await user.click(screen.getByRole('button', { name: 'Open current meeting' }))
    expect(await screen.findByRole('heading', { level: 1, name: liveB.title })).toBeVisible()
    expect(screen.getByText('Live evidence from B')).toBeVisible()
  })

  it('keeps History visible until the requested meeting has loaded', async () => {
    const user = userEvent.setup()
    let resolveLive!: (meeting: MeetingDetail) => void
    const pendingLive = new Promise<MeetingDetail>((resolve) => { resolveLive = resolve })
    vi.spyOn(arcoBridge, 'listMeetings').mockResolvedValue([pastA, liveB])
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(idleCapture)
    vi.spyOn(arcoBridge, 'readMeeting').mockImplementation(async (id) => {
      if (id === liveB.id) return pendingLive
      return detail(pastA, 'Historical evidence from A')
    })

    render(<App />)
    expect(await screen.findByRole('region', { name: 'Start listening' })).toBeVisible()
    await openHistory(user)
    await user.click(screen.getByRole('button', { name: new RegExp(liveB.title) }))

    expect(screen.getByRole('heading', { level: 1, name: 'History' })).toBeVisible()
    expect(screen.queryByRole('complementary', { name: 'Meeting transcript' })).not.toBeInTheDocument()

    resolveLive(detail(liveB, 'Loaded evidence from B'))
    expect(await screen.findByRole('heading', { level: 1, name: liveB.title })).toBeVisible()
    expect(screen.getByText('Loaded evidence from B')).toBeVisible()
  })

  it('stays in History and preserves A when opening B fails', async () => {
    const user = userEvent.setup()
    vi.spyOn(arcoBridge, 'listMeetings').mockResolvedValue([pastA, liveB])
    vi.spyOn(arcoBridge, 'captureStatus').mockResolvedValue(idleCapture)
    vi.spyOn(arcoBridge, 'readMeeting').mockImplementation(async (id) => {
      if (id === liveB.id) throw new Error('B cannot be read')
      return detail(pastA, 'Historical evidence from A')
    })

    render(<App />)
    expect(await screen.findByRole('region', { name: 'Start listening' })).toBeVisible()
    await openHistory(user)
    await user.click(screen.getByRole('button', { name: new RegExp(liveB.title) }))

    expect(await screen.findByRole('heading', { level: 1, name: 'History' })).toBeVisible()
    expect(screen.getByRole('alert')).toHaveTextContent('B cannot be read')
    await user.click(screen.getByRole('button', { name: 'Open current meeting' }))
    expect(await screen.findByRole('region', { name: 'Start listening' })).toBeVisible()
    expect(screen.queryByText('Historical evidence from A')).not.toBeInTheDocument()
  })

  it('force-reads the stopped meeting so its final line appears before handoff', async () => {
    const user = userEvent.setup()
    let stopped = false
    let capture = liveCapture
    const stoppedSummary = { ...liveB, isLive: false, durationLabel: '1 min' }
    const readMeeting = vi.spyOn(arcoBridge, 'readMeeting').mockImplementation(async () => (
      stopped
        ? {
            summary: stoppedSummary,
            lines: [
              ...detail(stoppedSummary, 'Line before stop').lines,
              { id: 'live-b-final', timestamp: '15:00:07', speaker: 'In room 1', text: 'Final line flushed on stop', sequence: 2 },
            ],
          }
        : detail(liveB, 'Line before stop')
    ))
    vi.spyOn(arcoBridge, 'listMeetings').mockImplementation(async () => [stopped ? stoppedSummary : liveB])
    vi.spyOn(arcoBridge, 'captureStatus').mockImplementation(async () => capture)
    vi.spyOn(arcoBridge, 'stopCapture').mockImplementation(async () => {
      stopped = true
      capture = idleCapture
      return idleCapture
    })
    const generateMeetingOutput = vi.spyOn(arcoBridge, 'generateMeetingOutput').mockResolvedValue({
      kind: 'summary',
      status: 'ready',
      value: 'The final line remains part of the meeting record.',
      provider: 'codex',
      providerSessionId: null,
      providerTurnId: null,
      error: null,
      updatedAt: '2026-07-11T15:01:00+08:00',
    })

    render(<App />)
    expect(await screen.findByText('Line before stop')).toBeVisible()

    await user.click(screen.getByRole('button', { name: 'Stop listening' }))

    expect(await screen.findByRole('region', { name: 'Start listening' })).toBeVisible()
    await waitFor(() => expect(readMeeting.mock.calls.length).toBeGreaterThanOrEqual(3))
    expect(generateMeetingOutput).toHaveBeenCalledWith(expect.objectContaining({
      meetingId: liveB.id,
      kind: 'summary',
    }))
    await openHistory(user)
    await user.click(screen.getByRole('button', { name: new RegExp(liveB.title) }))
    expect(await screen.findByText('Final line flushed on stop')).toBeVisible()
  })
})
