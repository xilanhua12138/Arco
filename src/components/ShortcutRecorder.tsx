import { useCallback, useEffect, useRef, useState } from 'react'
import { formatListeningShortcut, listeningShortcutFromKeyboardEvent, type ListeningShortcut } from '../lib/listeningShortcut'
import { useI18n } from '../i18n/i18n'

interface ShortcutRecorderProps {
  value: ListeningShortcut
  onChange: (shortcut: ListeningShortcut) => boolean | Promise<boolean>
  onRecordingChange?: (recording: boolean) => void
  onStartRecording?: () => boolean | Promise<boolean>
  onCancelRecording?: () => void | Promise<void>
}

export function ShortcutRecorder({
  value,
  onChange,
  onRecordingChange,
  onStartRecording,
  onCancelRecording,
}: ShortcutRecorderProps) {
  const { t } = useI18n()
  const [recording, setRecording] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const recordingRef = useRef(false)
  const committingRef = useRef(false)
  const cancelRecordingRef = useRef(onCancelRecording)

  useEffect(() => {
    cancelRecordingRef.current = onCancelRecording
  }, [onCancelRecording])

  useEffect(() => () => {
    if (recordingRef.current) void cancelRecordingRef.current?.()
  }, [])

  const setRecordingState = useCallback((next: boolean) => {
    recordingRef.current = next
    setRecording(next)
    onRecordingChange?.(next)
  }, [onRecordingChange])

  const beginRecording = async () => {
    setMessage(null)
    const started = await onStartRecording?.()
    if (started === false) {
      setMessage(t('shortcut.cannotEdit'))
      return
    }
    setRecordingState(true)
  }

  const commit = useCallback(async (shortcut: ListeningShortcut) => {
    if (committingRef.current) return
    committingRef.current = true
    setMessage(null)
    try {
      const changed = await onChange(shortcut)
      if (changed === false) {
        committingRef.current = false
        setMessage(t('shortcut.inUse'))
        return
      }
    } catch {
      committingRef.current = false
      setMessage(t('shortcut.inUse'))
      return
    }
    committingRef.current = false
    setRecordingState(false)
  }, [onChange, setRecordingState, t])

  const cancelRecording = useCallback(() => {
    committingRef.current = false
    setRecordingState(false)
    setMessage(null)
    void onCancelRecording?.()
  }, [onCancelRecording, setRecordingState])

  useEffect(() => {
    if (!recording) return
    const captureShortcut = (event: KeyboardEvent) => {
      event.preventDefault()
      event.stopPropagation()
      if (event.key === 'Escape') {
        cancelRecording()
        return
      }
      const shortcut = listeningShortcutFromKeyboardEvent(event)
      if (!shortcut) {
        setMessage(t('shortcut.modifierRequired'))
        return
      }
      void commit(shortcut)
    }
    window.addEventListener('keydown', captureShortcut, true)
    return () => window.removeEventListener('keydown', captureShortcut, true)
  }, [cancelRecording, commit, recording, t])

  return (
    <div className="shortcut-recorder">
      <button
        type="button"
        className={`shortcut-recorder-key ${recording ? 'shortcut-recorder-key-recording' : ''}`}
        aria-label={t('shortcut.change')}
        onClick={() => void beginRecording()}
      >
        {recording ? t('shortcut.press') : value === null ? t('shortcut.off') : formatListeningShortcut(value)}
      </button>
      {recording ? (
        <button
          type="button"
          className="shortcut-recorder-disable"
          aria-label={t('common.cancel')}
          onClick={cancelRecording}
        >
          {t('common.cancel')}
        </button>
      ) : (
        <button
          type="button"
          className="shortcut-recorder-disable"
          aria-label={t('shortcut.disable')}
          disabled={value === null}
          onClick={() => void commit(null)}
        >
          {value === null ? t('shortcut.disabled') : t('shortcut.turnOff')}
        </button>
      )}
      {message && <p className="shortcut-recorder-message" role="status">{message}</p>}
    </div>
  )
}
