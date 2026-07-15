import { AudioLines, ChevronRight } from 'lucide-react'
import { groupMeetings } from '../lib/meetingGroups'
import type { MeetingSummary } from '../types'
import { formatDurationLabel, useI18n } from '../i18n/i18n'
import { PlatformSearchField } from './PlatformSearchField'

interface HistoryPageProps {
  meetings: MeetingSummary[]
  selectedMeetingId: string | null
  query: string
  onQueryChange: (query: string) => void
  onSelectMeeting: (id: string) => void
}

export function HistoryPage({
  meetings,
  selectedMeetingId,
  query,
  onQueryChange,
  onSelectMeeting,
}: HistoryPageProps) {
  const { t, formatDate } = useI18n()
  const groups = groupMeetings(meetings)
  const meetingTime = (value: string) => {
    const date = new Date(value)
    return Number.isNaN(date.getTime())
      ? t('common.unknownTime')
      : formatDate(date, { hour: '2-digit', minute: '2-digit' })
  }
  const meetingDate = (value: string) => {
    const date = new Date(value)
    return Number.isNaN(date.getTime()) ? '' : formatDate(date, { month: 'short', day: 'numeric' })
  }

  return (
    <main className="history-page" aria-labelledby="history-heading">
      <header className="page-header history-page-header">
        <div className="page-title-block">
          <h1 id="history-heading">{t('history.heading')}</h1>
        </div>

        <PlatformSearchField
          label={t('history.search')}
          value={query}
          onChange={onQueryChange}
          placeholder={t('history.searchPlaceholder')}
        />
      </header>

      <div className="history-results" aria-live="polite" aria-label={t('history.results')}>
        {groups.length === 0 ? (
          <div className="history-empty">
            <span><AudioLines size={22} /></span>
            <h2>{t('history.noMatches')}</h2>
            <p>{t('history.noMatchesHelp')}</p>
          </div>
        ) : (
          groups.map((group) => (
            <section className="history-group" key={group.id}>
              <h2>{t(`history.group.${group.id}`)}</h2>
              <div className="history-list">
                {group.meetings.map((meeting) => (
                  <button
                    type="button"
                    className={`history-meeting-row ${meeting.id === selectedMeetingId ? 'history-meeting-row-selected' : ''}`}
                    key={meeting.id}
                    onClick={() => onSelectMeeting(meeting.id)}
                    aria-current={meeting.id === selectedMeetingId ? 'page' : undefined}
                  >
                    <span className="history-row-time">
                      <strong>{meetingTime(meeting.startedAt)}</strong>
                      <small>{meetingDate(meeting.startedAt)}</small>
                    </span>
                    <span className="history-row-copy">
                      <span className="history-row-title">
                        {meeting.isLive && <i className="live-mini-dot" aria-hidden="true" />}
                        <strong>{meeting.title?.trim() || t('common.untitledMeeting')}</strong>
                      </span>
                      <span className="history-row-preview">{meeting.preview || t('history.previewFallback')}</span>
                    </span>
                    <span className="history-row-meta">
                      <small>{formatDurationLabel(meeting.durationLabel, t)}</small>
                      <small>{t(meeting.utteranceCount === 1 ? 'history.lineCountOne' : 'history.lineCount', { count: meeting.utteranceCount })}</small>
                      <ChevronRight size={17} aria-hidden="true" />
                    </span>
                  </button>
                ))}
              </div>
            </section>
          ))
        )}
      </div>
    </main>
  )
}
