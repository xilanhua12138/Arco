import { Info, Pencil } from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import type { CaptureState, MeetingDetail, MeetingSummary } from '../types'
import { formatDurationLabel, localizedSpeakerLabel, useI18n } from '../i18n/i18n'

interface TopBarProps {
  meeting: MeetingSummary | null
  meetingDetail?: MeetingDetail | null
  capture: CaptureState
  onRenameMeeting: (meetingId: string, title: string | null) => Promise<boolean>
}

export function TopBar({ meeting, meetingDetail = null, capture, onRenameMeeting }: TopBarProps) {
  const { t } = useI18n()
  const [openMeetingId, setOpenMeetingId] = useState<string | null>(null)
  const [editingMeetingId, setEditingMeetingId] = useState<string | null>(null)
  const [titleDraft, setTitleDraft] = useState('')
  const [savingTitle, setSavingTitle] = useState(false)
  const detailsAnchorRef = useRef<HTMLDivElement>(null)
  const detailsTriggerRef = useRef<HTMLButtonElement>(null)
  const titleTriggerRef = useRef<HTMLButtonElement>(null)
  const titleInputRef = useRef<HTMLInputElement>(null)
  const titleSaveInFlightRef = useRef(false)
  const detailsOpen = Boolean(meeting && openMeetingId === meeting.id)
  const recording = capture.phase === 'recording' && meeting?.id === capture.activeMeetingId
  const detail = meetingDetail?.summary.id === meeting?.id ? meetingDetail : null
  const speakers = useMemo(
    () => [...new Set(detail?.lines.map((line) => line.speaker).filter(Boolean) ?? [])],
    [detail],
  )
  const remoteSpeakers = speakers.filter((speaker) => speaker.toLocaleLowerCase().startsWith('remote'))
  const roomSpeakers = speakers.filter((speaker) => speaker.toLocaleLowerCase().startsWith('in room'))
  const utteranceCount = detail?.lines.length ?? meeting?.utteranceCount ?? 0
  const editingTitle = Boolean(meeting && editingMeetingId === meeting.id)
  const displayTitle = meeting
    ? meeting.title?.trim() || t('common.untitledMeeting')
    : t('topbar.startConversation')

  useEffect(() => {
    if (!editingTitle) return
    titleInputRef.current?.focus()
    titleInputRef.current?.select()
  }, [editingTitle])

  const beginTitleEdit = () => {
    if (!meeting) return
    setTitleDraft(meeting.title?.trim() ?? '')
    setEditingMeetingId(meeting.id)
  }

  const cancelTitleEdit = () => {
    setEditingMeetingId(null)
    setTitleDraft('')
    window.setTimeout(() => titleTriggerRef.current?.focus(), 0)
  }

  const commitTitle = async () => {
    if (!meeting || editingMeetingId !== meeting.id || titleSaveInFlightRef.current) return
    const normalized = titleDraft.trim() || null
    if (normalized === (meeting.title?.trim() || null)) {
      cancelTitleEdit()
      return
    }
    titleSaveInFlightRef.current = true
    setSavingTitle(true)
    const saved = await onRenameMeeting(meeting.id, normalized)
    titleSaveInFlightRef.current = false
    setSavingTitle(false)
    if (saved) {
      setEditingMeetingId(null)
      setTitleDraft('')
      window.setTimeout(() => titleTriggerRef.current?.focus(), 0)
    } else {
      window.setTimeout(() => titleInputRef.current?.focus(), 0)
    }
  }

  useEffect(() => {
    if (!detailsOpen) return

    const closeOnPointerDown = (event: PointerEvent) => {
      if (!detailsAnchorRef.current?.contains(event.target as Node)) setOpenMeetingId(null)
    }
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      setOpenMeetingId(null)
      detailsTriggerRef.current?.focus()
    }

    document.addEventListener('pointerdown', closeOnPointerDown)
    document.addEventListener('keydown', closeOnEscape)
    return () => {
      document.removeEventListener('pointerdown', closeOnPointerDown)
      document.removeEventListener('keydown', closeOnEscape)
    }
  }, [detailsOpen])

  return (
    <header className="page-header current-page-header">
      <div className="page-title-block">
        <div className="page-title-line">
          {meeting ? (
            editingTitle ? (
              <h1 className="meeting-title-heading-editing">
                <input
                  ref={titleInputRef}
                  className="meeting-title-input"
                  aria-label={t('topbar.meetingTitle')}
                  value={titleDraft}
                  maxLength={80}
                  disabled={savingTitle}
                  onChange={(event) => setTitleDraft(event.target.value)}
                  onBlur={() => void commitTitle()}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter') {
                      event.preventDefault()
                      void commitTitle()
                    } else if (event.key === 'Escape') {
                      event.preventDefault()
                      cancelTitleEdit()
                    }
                  }}
                />
              </h1>
            ) : (
              <div className="meeting-title-display">
                <h1>{displayTitle}</h1>
                <button
                  ref={titleTriggerRef}
                  type="button"
                  className="meeting-title-button"
                  aria-label={t('topbar.renameMeeting')}
                  title={t('topbar.renameMeeting')}
                  onClick={beginTitleEdit}
                >
                  <Pencil size={15} aria-hidden="true" />
                </button>
              </div>
            )
          ) : (
            <h1>{displayTitle}</h1>
          )}
          {recording && (
            <span className="meeting-live-status" role="status" aria-label={t('topbar.recordingStatus')}>
              <i aria-hidden="true" />
              {t('common.listening')}
            </span>
          )}
        </div>
      </div>

      <div className="page-primary-actions">
        {meeting && (
          <div className="meeting-details-anchor" ref={detailsAnchorRef}>
            <button
              ref={detailsTriggerRef}
              type="button"
              className={`meeting-details-button ${detailsOpen ? 'meeting-details-button-active' : ''}`}
              aria-label={t('topbar.meetingDetails')}
              aria-expanded={detailsOpen}
              aria-controls="meeting-details-popover"
              title={t('topbar.meetingDetails')}
              onClick={() => setOpenMeetingId(detailsOpen ? null : meeting.id)}
            >
              <Info size={17} aria-hidden="true" />
            </button>

            {detailsOpen && (
              <div
                id="meeting-details-popover"
                className="meeting-details-popover"
                role="dialog"
                aria-label={t('topbar.meetingDetails')}
              >
                <dl className="meeting-details-list">
                  <div><dt>{t('topbar.duration')}</dt><dd>{formatDurationLabel(meeting.durationLabel, t)}</dd></div>
                  <div><dt>{t('topbar.transcript')}</dt><dd>{t(utteranceCount === 1 ? 'topbar.utteranceCountOne' : 'topbar.utteranceCount', { count: utteranceCount })} · {t(speakers.length === 1 ? 'topbar.speakerCountOne' : 'topbar.speakerCount', { count: speakers.length })}</dd></div>
                  <div><dt>{t('topbar.storage')}</dt><dd>{t('common.onThisMac')}</dd></div>
                  <div><dt>{t('topbar.transcription')}</dt><dd>Deepgram</dd></div>
                  <div aria-label={t('topbar.systemSpeakers', { speakers: remoteSpeakers.map((speaker) => localizedSpeakerLabel(speaker, t)).join(', ') || t('common.waiting') })}>
                    <dt>{t('topbar.system')}</dt><dd>{remoteSpeakers.map((speaker) => localizedSpeakerLabel(speaker, t)).join(', ') || t('common.waiting')}</dd>
                  </div>
                  <div aria-label={t('topbar.roomSpeakers', { speakers: roomSpeakers.map((speaker) => localizedSpeakerLabel(speaker, t)).join(', ') || t('common.waiting') })}>
                    <dt>{t('topbar.room')}</dt><dd>{roomSpeakers.map((speaker) => localizedSpeakerLabel(speaker, t)).join(', ') || t('common.waiting')}</dd>
                  </div>
                </dl>
                <p className="meeting-details-note">{t('topbar.locationLabels')}</p>
              </div>
            )}
          </div>
        )}
      </div>
    </header>
  )
}
