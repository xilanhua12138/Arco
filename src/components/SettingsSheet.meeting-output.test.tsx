import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { SettingsSheet } from './SettingsSheet'

describe('SettingsSheet meeting output', () => {
  it('adds one progressive Meeting output page between audio and runtime settings', async () => {
    const user = userEvent.setup()
    const onChangeGenerationSettings = vi.fn()
    render(
      <SettingsSheet
        open
        runtimes={[]}
        isDesktop
        generationSettings={{
          title: { enabled: true, promptOverride: null },
          summary: { enabled: false, promptOverride: null },
        }}
        onChangeGenerationSettings={onChangeGenerationSettings}
        onClose={vi.fn()}
      />,
    )

    const navigation = screen.getByRole('complementary', { name: 'Settings sections' })
    const navigationLabels = Array.from(navigation.querySelectorAll('button')).map((button) => button.textContent?.trim())
    expect(navigationLabels).toEqual(['General', 'Audio & speakers', 'Meeting output', 'Agent runtime', 'Data & privacy'])
    expect(screen.queryByRole('button', { name: 'Shortcuts' })).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Meeting output' }))
    expect(screen.getByRole('dialog', { name: 'Meeting output' })).toBeVisible()
    expect(screen.getByText('How Arco names and wraps up meetings')).toBeVisible()
    expect(screen.getByRole('button', { name: /Automatic title/i })).toHaveTextContent('On · Arco default')
    expect(screen.getByRole('button', { name: /End-of-meeting summary/i })).toHaveTextContent('Off')
    expect(onChangeGenerationSettings).not.toHaveBeenCalled()
  })
})
