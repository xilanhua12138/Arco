import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { SettingsSheet } from './SettingsSheet'

const runtimes = [
  { provider: 'codex' as const, available: true, version: 'codex 0.137.0', path: '/bin/codex' },
  { provider: 'claude' as const, available: false, version: null, path: null },
]

async function renderProviderSettings(onEditProviders = vi.fn()) {
  const user = userEvent.setup()
  render(
    <SettingsSheet
      open
      runtimes={runtimes}
      isDesktop
      providerConfig={{ setupComplete: true, primary: 'codex', secondary: null }}
      onEditProviders={onEditProviders}
      onClose={vi.fn()}
    />,
  )
  await user.click(screen.getByRole('button', { name: /Agent runtime/i }))
  return { user, onEditProviders }
}

describe('SettingsSheet provider configuration', () => {
  it('presents one settled primary and secondary configuration instead of per-use switching', async () => {
    await renderProviderSettings()

    const configuration = screen.getByRole('region', { name: 'Current configuration' })
    expect(within(configuration).getByText('Primary provider')).toBeVisible()
    expect(within(configuration).getByText('Codex')).toBeVisible()
    expect(within(configuration).getByText('Secondary provider')).toBeVisible()
    expect(within(configuration).getByText('Not configured')).toBeVisible()
    expect(within(configuration).queryByText('CLI preference')).not.toBeInTheDocument()
    expect(within(configuration).queryByText('Codex CLI')).not.toBeInTheDocument()
    expect(screen.queryByRole('radio')).not.toBeInTheDocument()
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument()
  })

  it('shows what is installed on this Mac without turning runtime status into configuration', async () => {
    await renderProviderSettings()

    const localRuntimes = screen.getByRole('region', { name: 'Local CLI status' })
    expect(within(localRuntimes).getByText('codex 0.137.0')).toBeVisible()
    expect(within(localRuntimes).getByText('Installed')).toBeVisible()
    expect(within(localRuntimes).getByText('Claude Code')).toBeVisible()
    expect(within(localRuntimes).getByText('Missing')).toBeVisible()
  })

  it('opens the dedicated setup flow from a single secondary action', async () => {
    const onEditProviders = vi.fn()
    const { user } = await renderProviderSettings(onEditProviders)

    await user.click(screen.getByRole('button', { name: 'Edit configuration' }))

    expect(onEditProviders).toHaveBeenCalledOnce()
  })
})
