import { fireEvent, render, screen, waitFor } from '@testing-library/react'
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
    await waitFor(() => expect(screen.getByRole('button', { name: 'Disable listening shortcut' })).toBeVisible())

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

  it('captures the shortcut from the window when native WebView focus leaves the button', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn().mockResolvedValue(true)
    render(
      <ShortcutRecorder
        value="CommandOrControl+Shift+Space"
        onChange={onChange}
        onStartRecording={vi.fn().mockResolvedValue(true)}
      />,
    )

    await user.click(screen.getByRole('button', { name: 'Change listening shortcut' }))
    fireEvent.keyDown(window, { key: 'l', code: 'KeyL', metaKey: true, altKey: true })

    await waitFor(() => expect(onChange).toHaveBeenCalledWith('CommandOrControl+Alt+KeyL'))
  })

  it('shows an explicit cancel action while recording and reports editing state', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn().mockResolvedValue(true)
    const onRecordingChange = vi.fn()
    const onStartRecording = vi.fn().mockResolvedValue(true)
    const onCancelRecording = vi.fn().mockResolvedValue(undefined)
    render(
      <ShortcutRecorder
        value="CommandOrControl+Shift+Space"
        onChange={onChange}
        onRecordingChange={onRecordingChange}
        onStartRecording={onStartRecording}
        onCancelRecording={onCancelRecording}
      />,
    )

    await user.click(screen.getByRole('button', { name: 'Change listening shortcut' }))
    expect(onStartRecording).toHaveBeenCalledOnce()
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeVisible()
    expect(screen.queryByRole('button', { name: 'Disable listening shortcut' })).not.toBeInTheDocument()
    expect(onRecordingChange).toHaveBeenLastCalledWith(true)

    await user.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(onChange).not.toHaveBeenCalled()
    expect(onCancelRecording).toHaveBeenCalledOnce()
    expect(onRecordingChange).toHaveBeenLastCalledWith(false)
  })
})
