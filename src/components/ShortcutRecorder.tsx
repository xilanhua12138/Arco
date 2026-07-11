import { useState } from 'react'
import { formatListeningShortcut, listeningShortcutFromKeyboardEvent, type ListeningShortcut } from '../lib/listeningShortcut'
import { useI18n } from '../i18n/i18n'

interface ShortcutRecorderProps {
  value: ListeningShortcut
  onChange: (shortcut: ListeningShortcut) => boolean | Promise<boolean>
}

export function ShortcutRecorder({ value, onChange }: ShortcutRecorderProps) {
  const { t } = useI18n()
  const [recording, setRecording] = useState(false)
  const [message, setMessage] = useState<string | null>(null)

  const commit = async (shortcut: ListeningShortcut) => {
    setMessage(null)
    const changed = await onChange(shortcut)
    if (changed === false) {
      setMessage(t('shortcut.inUse'))
      return
    }
    setRecording(false)
  }

  return (
    <div className="shortcut-recorder">
      <button
        type="button"
        className={`shortcut-recorder-key ${recording ? 'shortcut-recorder-key-recording' : ''}`}
        aria-label={t('shortcut.change')}
        onClick={() => {
          setMessage(null)
          setRecording(true)
        }}
        onKeyDown={(event) => {
          if (!recording) return
          event.preventDefault()
          event.stopPropagation()
          if (event.key === 'Escape') {
            setRecording(false)
            setMessage(null)
            return
          }
          const shortcut = listeningShortcutFromKeyboardEvent(event)
          if (!shortcut) {
            setMessage(t('shortcut.modifierRequired'))
            return
          }
          void commit(shortcut)
        }}
      >
        {recording ? t('shortcut.press') : value === null ? t('shortcut.off') : formatListeningShortcut(value)}
      </button>
      <button
        type="button"
        className="shortcut-recorder-disable"
        aria-label={t('shortcut.disable')}
        disabled={value === null}
        onClick={() => void commit(null)}
      >
        {value === null ? t('shortcut.disabled') : t('shortcut.turnOff')}
      </button>
      {message && <p className="shortcut-recorder-message" role="status">{message}</p>}
    </div>
  )
}
