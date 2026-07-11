import { AudioWaveform, Clock3, History, LockKeyhole, MessageSquareText, Search, SlidersHorizontal } from 'lucide-react'
import type { AudioMode, CaptureState, MeetingSummary } from '../types'
import { formatListeningShortcut, type ListeningShortcut } from '../lib/listeningShortcut'
import { summarizeMeetings } from '../lib/meetingStats'
import { useI18n } from '../i18n/i18n'

interface CurrentIdleStateProps {
  capture: CaptureState
  meetings: MeetingSummary[]
  audioMode: AudioMode
  shortcut: ListeningShortcut
  onStart: () => void
  onOpenAudioSettings: () => void
}

export function CurrentIdleState({
  capture,
  meetings,
  audioMode,
  shortcut,
  onStart,
  onOpenAudioSettings,
}: CurrentIdleStateProps) {
  const { formatNumber, t } = useI18n()
  const busy = capture.phase === 'starting' || capture.phase === 'stopping'
  const stats = summarizeMeetings(meetings)
  const hours = Math.floor(stats.totalMinutes / 60)
  const minutes = stats.totalMinutes % 60
  const listeningTime = hours > 0
    ? t('capture.statsHoursMinutes', { hours, minutes })
    : t('capture.statsMinutes', { minutes })
  const formattedListeningShortcut = formatListeningShortcut(shortcut)
  const listeningKeycaps = formattedListeningShortcut
    .split(' ')
    .map((key) => key === 'fn' ? 'Fn' : key)
  const audioLabel = audioMode === 'both'
    ? t('capture.audio.hybrid')
    : audioMode === 'system'
      ? t('capture.audio.online')
      : t('capture.audio.room')

  return (
    <section className="current-idle" aria-label={t('capture.idleTitle')}>
      <div className="current-idle-hero">
        <div className="current-idle-wave" aria-hidden="true">
          <span /><span /><span /><span /><span /><span /><span />
        </div>
        <h1>{t('capture.idleTitle')}</h1>
        <button
          type="button"
          className="current-idle-primary"
          disabled={busy}
          onClick={onStart}
        >
          <AudioWaveform size={19} aria-hidden="true" />
          {busy ? t(capture.phase === 'stopping' ? 'common.stopping' : 'common.starting') : t('capture.start')}
        </button>
        <div className="current-idle-quick-controls">
          <button type="button" onClick={onOpenAudioSettings} aria-label={t('capture.nextMeetingAudio')}>
            <SlidersHorizontal size={14} aria-hidden="true" />
            {audioLabel}
          </button>
        </div>
        <p className="current-idle-local-receipt">
          <LockKeyhole size={12} aria-hidden="true" />
          {t('capture.idleSavedToHistory')}
        </p>
      </div>

      <div className="current-idle-overview">
        <section className="current-idle-stats" aria-labelledby="current-idle-stats-heading">
          <h2 id="current-idle-stats-heading">{t('capture.statsHeading')}</h2>
          <dl>
            <div className="current-idle-stat">
              <dt><History size={15} aria-hidden="true" />{t('capture.statsMeetings')}</dt>
              <dd>{formatNumber(stats.meetingCount)}</dd>
            </div>
            <div className="current-idle-stat">
              <dt><Clock3 size={15} aria-hidden="true" />{t('capture.statsListeningTime')}</dt>
              <dd>{listeningTime}</dd>
            </div>
            <div className="current-idle-stat">
              <dt><MessageSquareText size={15} aria-hidden="true" />{t('capture.statsTranscriptLines')}</dt>
              <dd>{formatNumber(stats.transcriptLineCount)}</dd>
            </div>
          </dl>
        </section>

        <section className="current-idle-shortcuts" aria-labelledby="current-idle-shortcuts-heading">
          <h2 id="current-idle-shortcuts-heading">{t('capture.shortcutsHeading')}</h2>
          <dl>
            <div>
              <dt><AudioWaveform size={14} aria-hidden="true" />{t('capture.shortcutStartStop')}</dt>
              <dd className="current-idle-keycaps" aria-label={formattedListeningShortcut}>
                {listeningKeycaps.map((key, index) => <kbd key={`${key}-${index}`}>{key}</kbd>)}
              </dd>
            </div>
            <div>
              <dt><Search size={14} aria-hidden="true" />{t('capture.shortcutSearchHistory')}</dt>
              <dd className="current-idle-keycaps" aria-label="⌘ K"><kbd>⌘</kbd><kbd>K</kbd></dd>
            </div>
          </dl>
        </section>
      </div>
    </section>
  )
}
