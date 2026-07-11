import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { GenerationSettings } from '../lib/generationSettings'
import { DEFAULT_TITLE_PROMPT, MAX_GENERATION_PROMPT_CHARS } from '../lib/generationSettings'
import { MeetingOutputSettings } from './MeetingOutputSettings'

const settings: GenerationSettings = {
  title: { enabled: true, promptOverride: null },
  summary: { enabled: true, promptOverride: 'Lead with the decision.' },
}

describe('MeetingOutputSettings', () => {
  it('starts with two concise configuration rows and no prompt editor', () => {
    render(<MeetingOutputSettings settings={settings} onSave={vi.fn()} />)

    const title = screen.getByRole('button', { name: /Automatic title/i })
    const summary = screen.getByRole('button', { name: /End-of-meeting summary/i })
    expect(title).toHaveTextContent('On · Arco default')
    expect(summary).toHaveTextContent('On · Custom')
    expect(screen.queryByRole('textbox', { name: 'Prompt' })).not.toBeInTheDocument()
    expect(screen.queryByText(DEFAULT_TITLE_PROMPT)).not.toBeInTheDocument()
  })

  it('keeps custom edits as a draft until Save and lets Cancel discard them', async () => {
    const user = userEvent.setup()
    const onSave = vi.fn()
    render(<MeetingOutputSettings settings={settings} onSave={onSave} />)

    await user.click(screen.getByRole('button', { name: /Automatic title/i }))
    expect(screen.getByRole('heading', { name: 'Automatic title' })).toBeVisible()
    expect(screen.getByRole('switch', { name: 'Generate automatically' })).toBeChecked()
    expect(screen.getByRole('switch', { name: 'Use custom prompt' })).not.toBeChecked()
    expect(screen.queryByRole('textbox', { name: 'Prompt' })).not.toBeInTheDocument()

    await user.click(screen.getByRole('switch', { name: 'Use custom prompt' }))
    const prompt = screen.getByRole('textbox', { name: 'Prompt' })
    expect(prompt).toHaveValue(DEFAULT_TITLE_PROMPT)
    expect(prompt).toHaveAttribute('maxlength', String(MAX_GENERATION_PROMPT_CHARS))
    await user.clear(prompt)
    await user.type(prompt, 'Use the decision as the title.')
    await user.click(screen.getByRole('button', { name: 'Cancel' }))

    expect(onSave).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: /Automatic title/i })).toHaveTextContent('On · Arco default')
  })

  it('saves a custom prompt without changing the other rule', async () => {
    const user = userEvent.setup()
    const onSave = vi.fn()
    render(<MeetingOutputSettings settings={settings} onSave={onSave} />)

    await user.click(screen.getByRole('button', { name: /Automatic title/i }))
    await user.click(screen.getByRole('switch', { name: 'Use custom prompt' }))
    const prompt = screen.getByRole('textbox', { name: 'Prompt' })
    await user.clear(prompt)
    await user.type(prompt, 'Use the decision as the title.')
    await user.click(screen.getByRole('button', { name: 'Save changes' }))

    expect(onSave).toHaveBeenCalledOnce()
    expect(onSave).toHaveBeenCalledWith({
      title: { enabled: true, promptOverride: 'Use the decision as the title.' },
      summary: settings.summary,
    })
  })

  it('turns an automatic rule off while preserving its saved prompt for later', async () => {
    const user = userEvent.setup()
    const onSave = vi.fn()
    render(<MeetingOutputSettings settings={settings} onSave={onSave} />)

    await user.click(screen.getByRole('button', { name: /End-of-meeting summary/i }))
    await user.click(screen.getByRole('switch', { name: 'Create automatically' }))
    expect(screen.queryByRole('switch', { name: 'Use custom prompt' })).not.toBeInTheDocument()
    expect(screen.queryByRole('textbox', { name: 'Prompt' })).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Save changes' }))

    expect(onSave).toHaveBeenCalledWith({
      title: settings.title,
      summary: { enabled: false, promptOverride: 'Lead with the decision.' },
    })
  })

  it('resets a saved override to the managed Arco default before saving', async () => {
    const user = userEvent.setup()
    const onSave = vi.fn()
    render(<MeetingOutputSettings settings={settings} onSave={onSave} />)

    await user.click(screen.getByRole('button', { name: /End-of-meeting summary/i }))
    const detail = screen.getByRole('region', { name: 'End-of-meeting summary settings' })
    expect(within(detail).getByRole('switch', { name: 'Use custom prompt' })).toBeChecked()
    expect(within(detail).getByRole('textbox', { name: 'Prompt' })).toHaveValue('Lead with the decision.')

    await user.click(within(detail).getByRole('button', { name: 'Reset to Arco default' }))
    expect(within(detail).getByRole('switch', { name: 'Use custom prompt' })).not.toBeChecked()
    expect(within(detail).queryByRole('textbox', { name: 'Prompt' })).not.toBeInTheDocument()
    await user.click(within(detail).getByRole('button', { name: 'Save changes' }))

    expect(onSave).toHaveBeenCalledWith({
      title: settings.title,
      summary: { enabled: true, promptOverride: null },
    })
  })
})
