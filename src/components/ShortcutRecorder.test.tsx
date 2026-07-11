import { fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { ShortcutRecorder } from './ShortcutRecorder'

describe('ShortcutRecorder', () => {
  it('records a modified global shortcut and can disable it', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn().mockResolvedValue(true)
    render(<ShortcutRecorder value="CommandOrControl+Shift+Space" onChange={onChange} />)

    const recorder = screen.getByRole('button', { name: 'Change listening shortcut' })
    await user.click(recorder)
    fireEvent.keyDown(recorder, { key: 'l', code: 'KeyL', metaKey: true, altKey: true })
    expect(onChange).toHaveBeenCalledWith('CommandOrControl+Alt+KeyL')

    await user.click(screen.getByRole('button', { name: 'Disable listening shortcut' }))
    expect(onChange).toHaveBeenCalledWith(null)
  })

  it('cancels recording with Escape and explains invalid keys', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn().mockResolvedValue(true)
    render(<ShortcutRecorder value="CommandOrControl+Shift+Space" onChange={onChange} />)
    const recorder = screen.getByRole('button', { name: 'Change listening shortcut' })

    await user.click(recorder)
    fireEvent.keyDown(recorder, { key: 'Escape', code: 'Escape' })
    expect(onChange).not.toHaveBeenCalled()

    await user.click(recorder)
    fireEvent.keyDown(recorder, { key: 'l', code: 'KeyL' })
    expect(screen.getByText('Include ⌘, Control, Option, or Shift.')).toBeVisible()
    expect(onChange).not.toHaveBeenCalled()
  })
})
