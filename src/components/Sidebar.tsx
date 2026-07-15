import {
  AudioWaveform,
  Clock3,
  NotebookPen,
  Radio,
  Settings2,
  Square,
  Waves,
} from 'lucide-react'
import type { AudioMode, CaptureState, MeetingSummary } from '../types'
import { useI18n } from '../i18n/i18n'
import { PlatformActionButton } from './PlatformActionButton'
import { PlatformGlassSurface } from './PlatformGlassSurface'

type AppPage = 'current' | 'history' | 'notes' | 'review'

interface SidebarProps {
  page: AppPage
  meeting: MeetingSummary | null
  capture: CaptureState
  audioMode?: AudioMode
  audioModeLocked?: boolean
  onChangePage: (page: AppPage) => void
  onToggleCapture: (resumeMeetingId?: string) => void
  onOpenSettings: () => void
}

export function Sidebar({
  page,
  meeting,
  capture,
  audioMode = 'both',
  onChangePage,
  onToggleCapture,
  onOpenSettings,
}: SidebarProps) {
  const { t } = useI18n()
  const historySelected = page === 'history' || page === 'review'
  const notesSelected = page === 'notes'
  const recording = capture.phase === 'recording'
  const busy = capture.phase === 'starting' || capture.phase === 'stopping'
  const showCaptureAction = page !== 'current' || recording
  const captureLabel = capture.phase === 'recording'
    ? t('capture.stop')
    : capture.phase === 'starting'
      ? t('common.starting')
      : capture.phase === 'stopping'
        ? t('common.stopping')
        : t(page === 'review' ? 'capture.continue' : 'capture.start')
  const captureStatus = capture.phase === 'recording'
    ? t('common.listening')
    : capture.phase === 'starting'
      ? t('capture.starting')
      : capture.phase === 'stopping'
        ? t('capture.stopping')
        : t('capture.ready')
  const mode = audioMode === 'both'
    ? { label: t('capture.mode.hybrid'), sourceLabel: t('capture.source.both') }
    : audioMode === 'system'
      ? { label: t('capture.mode.online'), sourceLabel: t('capture.source.system') }
      : { label: t('capture.mode.room'), sourceLabel: t('capture.source.room') }

  return (
    <aside className="app-sidebar">
      <div className="sidebar-drag-space" data-tauri-drag-region />

      <div className="sidebar-brand" aria-label="Arco">
        <span className="brand-mark" aria-hidden="true">
          <img src="/arco-icon.png" alt="" draggable={false} />
        </span>
        <strong>Arco</strong>
      </div>

      <nav className="primary-navigation" aria-label={t('nav.main')}>
        <button
          type="button"
          className={`nav-item ${page === 'current' ? 'nav-item-active' : ''}`}
          onClick={() => onChangePage('current')}
          aria-current={page === 'current' ? 'page' : undefined}
          aria-label={t('nav.openCurrent')}
        >
          <Radio size={18} />
          <span>{t('nav.current')}</span>
        </button>
        <button
          id="history-trigger"
          type="button"
          className={`nav-item ${historySelected ? 'nav-item-active' : ''}`}
          onClick={() => onChangePage('history')}
          aria-current={historySelected ? 'page' : undefined}
          aria-label={t('nav.openHistory')}
        >
          <Clock3 size={18} />
          <span>{t('nav.history')}</span>
        </button>
        <button
          id="notes-trigger"
          type="button"
          className={`nav-item ${notesSelected ? 'nav-item-active' : ''}`}
          onClick={() => onChangePage('notes')}
          aria-current={notesSelected ? 'page' : undefined}
          aria-label={t('nav.openNotes')}
        >
          <NotebookPen size={18} />
          <span>{t('nav.notes')}</span>
        </button>
      </nav>

      <div className="sidebar-spacer" />

      <PlatformGlassSurface
        nativeId="sidebar-capture"
        className={`capture-card ${recording ? 'capture-card-live' : ''}`}
        cornerRadius={16}
        tone={recording ? 'accent' : 'elevated'}
        ariaLabel={t('capture.audioLabel', { mode: mode.label, source: mode.sourceLabel })}
      >
        <div className="capture-card-heading">
          <span className="capture-card-icon" aria-hidden="true">
            {recording ? <AudioWaveform size={16} /> : <Waves size={16} />}
          </span>
          <span>
            <strong>{captureStatus}</strong>
            <small>{mode.label}</small>
          </span>
        </div>

        {showCaptureAction && (
          <PlatformActionButton
            nativeId="capture-toggle"
            className={`capture-card-button ${recording ? 'capture-card-button-stop' : ''}`}
            label={captureLabel}
            symbol={recording ? 'stop.fill' : 'waveform'}
            variant="prominent"
            onPress={() => onToggleCapture(page === 'review' ? meeting?.id : undefined)}
            disabled={busy}
          >
            {recording ? <Square size={12} fill="currentColor" /> : <Waves size={15} />}
            {captureLabel}
          </PlatformActionButton>
        )}
      </PlatformGlassSurface>

      <footer className="sidebar-utilities">
        <PlatformActionButton
          nativeId="settings-open"
          id="settings-trigger"
          className="sidebar-settings-button"
          label={t('nav.openSettings')}
          symbol="slider.horizontal.3"
          variant="toolbar"
          onPress={onOpenSettings}
          ariaHasPopup="dialog"
        >
          <Settings2 size={14} />
          <span>{t('common.settings')}</span>
        </PlatformActionButton>
      </footer>
    </aside>
  )
}
