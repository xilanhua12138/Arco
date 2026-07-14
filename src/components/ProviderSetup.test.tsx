import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { RuntimeStatus } from '../types'
import { I18nProvider } from '../i18n/i18n'
import { ProviderSetup } from './ProviderSetup'

const bothReady: RuntimeStatus[] = [
  { provider: 'codex', available: true, version: 'codex 1.0', path: '/bin/codex' },
  { provider: 'claude', available: true, version: 'claude 1.0', path: '/bin/claude' },
]

describe('ProviderSetup', () => {
  it('uses the canonical Arco artwork in setup branding', () => {
    const { container } = render(<ProviderSetup runtimes={bothReady} onTest={vi.fn()} onComplete={vi.fn()} />)

    const brandImage = container.querySelector<HTMLImageElement>('.provider-setup-brand img')
    expect(brandImage).toHaveAttribute('src', '/arco-icon.png')
    expect(brandImage).toHaveAttribute('alt', '')
  })

  it('starts as a locked, keyboard-operable five-step flow', async () => {
    const user = userEvent.setup()
    render(<ProviderSetup runtimes={bothReady} onTest={vi.fn()} onComplete={vi.fn()} />)

    expect(screen.getAllByRole('listitem')).toHaveLength(5)
    expect(screen.getByRole('button', { name: 'Welcome' })).toHaveAttribute('aria-current', 'step')
    expect(screen.getByRole('button', { name: 'Choose providers' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Test connection' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Shortcut' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Ready' })).toBeDisabled()
    expect(screen.queryByRole('button', { name: /close/i })).not.toBeInTheDocument()

    await user.tab()
    expect(screen.getByRole('button', { name: 'Welcome' })).toHaveFocus()
    await user.tab()
    expect(screen.getByRole('combobox', { name: 'App language' })).toHaveFocus()
    await user.tab()
    expect(screen.getByRole('button', { name: 'Continue' })).toHaveFocus()
    await user.keyboard('{Enter}')

    expect(screen.getByRole('button', { name: 'Choose providers' })).toHaveAttribute('aria-current', 'step')
    expect(screen.getByRole('heading', { name: 'Choose providers' })).toBeVisible()
  })

  it('lets a first-time user switch language before completing setup', async () => {
    window.localStorage.setItem('arco.locale', 'en')
    const user = userEvent.setup()
    render(
      <I18nProvider>
        <ProviderSetup mode="onboarding" runtimes={bothReady} onTest={vi.fn()} onComplete={vi.fn()} />
      </I18nProvider>,
    )

    await user.selectOptions(screen.getByRole('combobox', { name: 'App language' }), 'zh-CN')

    expect(screen.getByRole('heading', { name: '欢迎使用 Arco' })).toBeVisible()
    expect(screen.getByRole('button', { name: '继续' })).toBeVisible()
    expect(window.localStorage.getItem('arco.locale')).toBe('zh-CN')
  })

  it('shows installed and missing CLIs and prevents choosing an unavailable provider', async () => {
    const user = userEvent.setup()
    render(
      <ProviderSetup
        runtimes={[
          bothReady[0],
          { ...bothReady[1], available: false, version: null, path: null },
        ]}
        onTest={vi.fn()}
        onComplete={vi.fn()}
      />,
    )

    await user.click(screen.getByRole('button', { name: 'Continue' }))

    expect(screen.getByLabelText('Codex CLI status')).toHaveTextContent('Installed')
    expect(screen.getByLabelText('Claude Code status')).toHaveTextContent('Missing')
    expect(screen.getByRole('radio', { name: 'Codex as primary' })).toBeChecked()
    expect(screen.getByRole('radio', { name: 'Claude as primary' })).toBeDisabled()
    expect(screen.getByRole('radio', { name: 'Claude as secondary' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeEnabled()
  })

  it('can re-check installations in place after the user installs a CLI', async () => {
    const user = userEvent.setup()
    const onRefresh = vi.fn().mockResolvedValue(undefined)
    render(
      <ProviderSetup
        runtimes={bothReady}
        onRefresh={onRefresh}
        onTest={vi.fn()}
        onComplete={vi.fn()}
      />,
    )

    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('button', { name: 'Re-check installations' }))

    expect(onRefresh).toHaveBeenCalledOnce()
    expect(screen.getByRole('button', { name: 'Choose providers' })).toHaveAttribute('aria-current', 'step')
  })

  it('invalidates an old connection test and recomputes roles when re-check changes the primary', async () => {
    const user = userEvent.setup()
    const afterRefresh: RuntimeStatus[] = [
      { ...bothReady[0], available: false, version: null, path: null },
      bothReady[1],
    ]
    const onRefresh = vi.fn().mockResolvedValue(afterRefresh)
    const onTest = vi.fn().mockResolvedValue({ provider: 'codex', ok: true, message: 'Codex CLI is connected.' })
    const props = { onRefresh, onTest, onComplete: vi.fn() }
    const { rerender } = render(<ProviderSetup {...props} runtimes={bothReady} />)

    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('radio', { name: 'Claude as secondary' }))
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('button', { name: 'Test Codex' }))
    expect(await screen.findByText('Codex is ready.')).toBeVisible()
    await user.click(screen.getByRole('button', { name: 'Back' }))

    await user.click(screen.getByRole('button', { name: 'Re-check installations' }))
    rerender(<ProviderSetup {...props} runtimes={afterRefresh} />)

    expect(screen.getByRole('radio', { name: 'Claude as primary' })).toBeChecked()
    expect(screen.getByRole('radio', { name: 'No secondary provider' })).toBeChecked()
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    expect(screen.getByRole('button', { name: 'Test Claude' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeDisabled()
    expect(onTest).toHaveBeenCalledTimes(1)
    expect(onTest).not.toHaveBeenCalledWith('claude')
  })

  it('drops a secondary that becomes unavailable and completes with a legal configuration', async () => {
    const user = userEvent.setup()
    const afterRefresh: RuntimeStatus[] = [
      bothReady[0],
      { ...bothReady[1], available: false, version: null, path: null },
    ]
    const onRefresh = vi.fn().mockResolvedValue(afterRefresh)
    const onTest = vi.fn().mockResolvedValue({ provider: 'codex', ok: true, message: 'Codex CLI is connected.' })
    const onComplete = vi.fn()
    const initialConfig = { setupComplete: true, primary: 'codex', secondary: 'claude' } as const
    const props = { initialConfig, onRefresh, onTest, onComplete }
    const { rerender } = render(<ProviderSetup {...props} runtimes={bothReady} />)

    await user.click(screen.getByRole('button', { name: 'Re-check installations' }))
    rerender(<ProviderSetup {...props} runtimes={afterRefresh} />)

    expect(screen.getByRole('radio', { name: 'No secondary provider' })).toBeChecked()
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('button', { name: 'Test Codex' }))
    expect(await screen.findByText('Codex is ready.')).toBeVisible()
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    expect(screen.getByRole('heading', { name: 'Start from anywhere' })).toBeVisible()
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('button', { name: 'Save configuration' }))

    expect(onComplete).toHaveBeenCalledWith({ setupComplete: true, primary: 'codex', secondary: null })
  })

  it('opens existing configuration in edit mode and cancels without changing it', async () => {
    const user = userEvent.setup()
    const onCancel = vi.fn()
    const onComplete = vi.fn()
    render(
      <ProviderSetup
        runtimes={bothReady}
        initialConfig={{ setupComplete: true, primary: 'claude', secondary: 'codex' }}
        onTest={vi.fn()}
        onComplete={onComplete}
        onCancel={onCancel}
      />,
    )

    expect(screen.getByRole('button', { name: 'Choose providers' })).toHaveAttribute('aria-current', 'step')
    expect(screen.getByRole('radio', { name: 'Claude as primary' })).toBeChecked()
    expect(screen.getByRole('radio', { name: 'Codex as secondary' })).toBeChecked()

    await user.click(screen.getByRole('button', { name: 'Cancel setup' }))
    expect(onCancel).toHaveBeenCalledOnce()
    expect(onComplete).not.toHaveBeenCalled()
  })

  it('keeps primary and secondary distinct and treats secondary as optional', async () => {
    const user = userEvent.setup()
    render(<ProviderSetup runtimes={bothReady} onTest={vi.fn()} onComplete={vi.fn()} />)
    await user.click(screen.getByRole('button', { name: 'Continue' }))

    expect(screen.getByRole('radio', { name: 'No secondary provider' })).toBeChecked()
    expect(screen.getByRole('radio', { name: 'Codex as secondary' })).toBeDisabled()
    await user.click(screen.getByRole('radio', { name: 'Claude as secondary' }))
    expect(screen.getByRole('radio', { name: 'Claude as secondary' })).toBeChecked()

    await user.click(screen.getByRole('radio', { name: 'Claude as primary' }))
    expect(screen.getByRole('radio', { name: 'No secondary provider' })).toBeChecked()
    expect(screen.getByRole('radio', { name: 'Claude as secondary' })).toBeDisabled()
  })

  it('tests only the Claude primary and shows its exact failure reason', async () => {
    const user = userEvent.setup()
    const onTest = vi.fn().mockResolvedValue({
      provider: 'claude',
      ok: false,
      message: 'Claude Code timed out after 90 seconds.',
    })
    const onComplete = vi.fn()
    render(<ProviderSetup runtimes={bothReady} onTest={onTest} onComplete={onComplete} />)

    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('radio', { name: 'Claude as primary' }))
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('button', { name: 'Test Claude' }))

    expect(onTest).toHaveBeenCalledOnce()
    expect(onTest).toHaveBeenCalledWith('claude')
    expect(screen.getByRole('alert')).toHaveTextContent('Claude Code timed out after 90 seconds.')
    expect(screen.getByRole('button', { name: 'Continue' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Test connection' })).toHaveAttribute('aria-current', 'step')
    expect(onComplete).not.toHaveBeenCalled()
  })

  it('completes only after a successful primary test and returns the exact provider configuration', async () => {
    const user = userEvent.setup()
    const onTest = vi.fn().mockResolvedValue({ provider: 'codex', ok: true, message: 'Codex CLI is connected.' })
    const onComplete = vi.fn()
    render(<ProviderSetup runtimes={bothReady} onTest={onTest} onComplete={onComplete} />)

    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('radio', { name: 'Claude as secondary' }))
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.click(screen.getByRole('button', { name: 'Test Codex' }))

    expect(await screen.findByText('Codex is ready.')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeEnabled()
    await user.click(screen.getByRole('button', { name: 'Continue' }))

    expect(onComplete).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: 'Shortcut' })).toHaveAttribute('aria-current', 'step')
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    expect(screen.getByRole('button', { name: 'Ready' })).toHaveAttribute('aria-current', 'step')
    await user.click(screen.getByRole('button', { name: 'Save configuration' }))

    expect(onComplete).toHaveBeenCalledOnce()
    expect(onComplete).toHaveBeenCalledWith({
      setupComplete: true,
      primary: 'codex',
      secondary: 'claude',
    })
  })
})
