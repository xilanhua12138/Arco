import { Sparkles, Square } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { arcoBridge } from '../lib/bridge'
import type { CaptureState } from '../types'
import { useI18n } from '../i18n/i18n'
import './Surfaces.css'

const startingCapture: CaptureState = {
  phase: 'starting',
  activeMeetingId: null,
  startedAt: null,
  message: null,
}

function formatElapsed(startedAt: string | null, now: number): string {
  if (!startedAt) return '00:00'
  const elapsed = Math.max(0, Math.floor((now - new Date(startedAt).getTime()) / 1_000))
  const hours = Math.floor(elapsed / 3_600)
  const minutes = Math.floor((elapsed % 3_600) / 60)
  const seconds = elapsed % 60
  return hours > 0
    ? [hours, minutes, seconds].map((part) => String(part).padStart(2, '0')).join(':')
    : [minutes, seconds].map((part) => String(part).padStart(2, '0')).join(':')
}

export function RecordingHud() {
  const { t } = useI18n()
  const [capture, setCapture] = useState<CaptureState>(startingCapture)
  const [now, setNow] = useState(Date.now)
  const [saving, setSaving] = useState(false)
  const [saved, setSaved] = useState(false)

  useEffect(() => {
    let cancelled = false
    const refresh = async () => {
      try {
        const next = await arcoBridge.captureStatus()
        if (!cancelled && !saving && !saved) setCapture(next)
      } catch {
        if (!cancelled) setCapture((current) => ({ ...current, phase: 'error' }))
      }
    }
    void refresh()
    const interval = window.setInterval(refresh, 700)
    return () => {
      cancelled = true
      window.clearInterval(interval)
    }
  }, [saved, saving])

  useEffect(() => {
    const interval = window.setInterval(() => setNow(Date.now()), 1_000)
    return () => {
      window.clearInterval(interval)
    }
  }, [])

  const status = useMemo(() => {
    if (saved) return t('hud.saved')
    if (saving || capture.phase === 'stopping') return t('common.saving')
    if (capture.phase === 'starting') return t('common.starting')
    if (capture.phase === 'error') return t('hud.recordingStopped')
    return t('common.recording')
  }, [capture.phase, saved, saving, t])
  const controlsLocked = saving || saved || capture.phase === 'starting' || capture.phase === 'stopping'

  const stop = async () => {
    if (saving || saved) return
    setSaving(true)
    setCapture((current) => ({ ...current, phase: 'stopping' }))
    try {
      const next = await arcoBridge.stopCapture()
      setCapture(next)
      setSaved(true)
    } catch {
      setCapture((current) => ({ ...current, phase: 'error' }))
    } finally {
      setSaving(false)
    }
  }

  return (
    <section className="recording-hud" aria-label={t('hud.controls')}>
      <div className="recording-hud-status" role="status" aria-live="polite">
        <span className="recording-dot" aria-hidden="true" />
        <strong>{status}</strong>
        {!saved && !saving && capture.phase === 'recording' && (
          <time role="timer" dateTime={capture.startedAt ?? undefined}>{formatElapsed(capture.startedAt, now)}</time>
        )}
      </div>
      <span className="recording-hud-divider" aria-hidden="true" />
      <button
        type="button"
        className="hud-button hud-stop-button"
        aria-label={t('hud.stop')}
        disabled={controlsLocked}
        onClick={() => void stop()}
      >
        <Square size={11} fill="currentColor" aria-hidden="true" />
        {t('common.stop')}
      </button>
      <button
        type="button"
        className="hud-button hud-agent-button"
        disabled={controlsLocked || capture.phase !== 'recording'}
        onClick={() => void arcoBridge.toggleAgentOverlay()}
      >
        <Sparkles size={14} aria-hidden="true" />
        {t('hud.askArco')}
      </button>
    </section>
  )
}
