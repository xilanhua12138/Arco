import { ArrowDown, AudioWaveform, FileText } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import type { CaptureState, MeetingDetail } from '../types'
import { localizedSpeakerLabel, useI18n } from '../i18n/i18n'
import { SpeakerAvatar } from './SpeakerAvatar'

interface TranscriptPaneProps {
  meeting: MeetingDetail | null
  capture: CaptureState
  loading: boolean
  compact?: boolean
  showHeader?: boolean
}

const speakerAvatarIndex = (speaker: string) => {
  const normalized = speaker.toLocaleLowerCase()
  const speakerNumber = Math.max(1, Number(speaker.match(/\d+/)?.[0] ?? 1))
  const lane = normalized.startsWith('remote')
    ? 4
    : normalized.startsWith('in room')
      ? 8
      : normalized.startsWith('speaker')
        ? 0
        : 12
  const index = lane === 12
    ? 12 + [...normalized].reduce((hash, character) => hash + character.charCodeAt(0), 0) % 4
    : lane + (speakerNumber - 1) % 4
  return index
}

type SummaryListBlock = { type: 'unordered-list' | 'ordered-list'; items: string[] }
type SummaryBlock =
  | { type: 'heading'; text: string }
  | { type: 'paragraph'; text: string }
  | SummaryListBlock

const summaryInlineText = (value: string) => value
  .replace(/\*\*([^*]+)\*\*/g, '$1')
  .replace(/__([^_]+)__/g, '$1')
  .replace(/`([^`]+)`/g, '$1')
  .trim()

const summaryBlocks = (summary: string): SummaryBlock[] => {
  const blocks: SummaryBlock[] = []
  let paragraph: string[] = []
  let continuingList = false

  const flushParagraph = () => {
    if (paragraph.length > 0) {
      blocks.push({ type: 'paragraph', text: summaryInlineText(paragraph.join(' ')) })
    }
    paragraph = []
  }

  for (const rawLine of summary.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (!line) {
      flushParagraph()
      continuingList = false
      continue
    }

    const heading = line.match(/^#{1,6}\s+(.+)$/)
    if (heading) {
      flushParagraph()
      blocks.push({ type: 'heading', text: summaryInlineText(heading[1]) })
      continuingList = false
      continue
    }

    const unordered = line.match(/^[-*•]\s+(.+)$/)
    const ordered = line.match(/^\d+[.)]\s+(.+)$/)
    if (unordered || ordered) {
      flushParagraph()
      const type = unordered ? 'unordered-list' : 'ordered-list'
      const item = summaryInlineText((unordered ?? ordered)?.[1] ?? '')
      const previous = blocks.at(-1)
      if (continuingList && previous?.type === type) previous.items.push(item)
      else blocks.push({ type, items: [item] })
      continuingList = true
      continue
    }

    continuingList = false
    paragraph.push(line)
  }

  flushParagraph()
  return blocks
}

function MeetingSummaryDocument({ summary }: { summary: string }) {
  const { t } = useI18n()
  return (
    <section className="meeting-summary-document" role="region" aria-label={t('transcript.summaryAria')}>
      <h2>{t('transcript.summary')}</h2>
      <div className="meeting-summary-copy">
        {summaryBlocks(summary).map((block, index) => {
          if (block.type === 'heading') return <h3 key={`heading-${index}`}>{block.text}</h3>
          if (block.type === 'paragraph') return <p key={`paragraph-${index}`}>{block.text}</p>
          const List = block.type === 'ordered-list' ? 'ol' : 'ul'
          return (
            <List key={`list-${index}`}>
              {block.items.map((item, itemIndex) => <li key={`${item}-${itemIndex}`}>{item}</li>)}
            </List>
          )
        })}
      </div>
    </section>
  )
}

const TranscriptHeader = () => {
  const { t } = useI18n()
  return (
    <header className="transcript-surface-header">
      <h2>{t('transcript.heading')}</h2>
    </header>
  )
}

export function TranscriptPane({ meeting, capture, loading, compact = false, showHeader = true }: TranscriptPaneProps) {
  const { t } = useI18n()
  const scrollRef = useRef<HTMLDivElement>(null)
  const [followingLive, setFollowingLive] = useState(true)
  const lastSequence = meeting?.lines.at(-1)?.sequence
  const active = capture.phase === 'recording' && meeting?.summary.id === capture.activeMeetingId
  const generatedSummary = meeting?.summary.generatedSummary?.trim() ?? ''
  const transcriptEmpty = meeting?.lines.length === 0

  useEffect(() => {
    if (!followingLive || !active) return
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: 'smooth' })
  }, [lastSequence, followingLive, active])

  const handleScroll = () => {
    const element = scrollRef.current
    if (!element) return
    setFollowingLive(element.scrollHeight - element.scrollTop - element.clientHeight < 72)
  }

  const jumpToLive = () => {
    const element = scrollRef.current
    element?.scrollTo({ top: element.scrollHeight, behavior: 'smooth' })
    setFollowingLive(true)
  }

  if (loading) {
    return (
      <aside className={`transcript-pane transcript-surface transcript-loading ${compact ? 'transcript-pane-compact' : ''}`} aria-label={t('transcript.loading')}>
        {showHeader && <TranscriptHeader />}
        <div className="transcript-loading-body">
          <div className="skeleton skeleton-label" />
          <div className="skeleton skeleton-heading" />
          {Array.from({ length: 6 }, (_, index) => (
            <div className="skeleton-line" key={index}>
              <span className="skeleton skeleton-time" />
              <span className="skeleton skeleton-copy" />
            </div>
          ))}
        </div>
      </aside>
    )
  }

  if (!meeting) {
    return (
      <aside className={`transcript-pane transcript-surface ${compact ? 'transcript-pane-compact' : ''}`} aria-label={t('transcript.aria')}>
        {showHeader && <TranscriptHeader />}
        <div className="empty-workspace">
          <span className="empty-icon"><FileText size={22} /></span>
          <h2>{t('transcript.noneSelected')}</h2>
          <p>{t('transcript.noneSelectedHelp')}</p>
        </div>
      </aside>
    )
  }

  return (
    <aside className={`transcript-pane transcript-surface ${compact ? 'transcript-pane-compact' : ''}`} aria-label={t('transcript.aria')}>
      {showHeader && <TranscriptHeader />}
      <div className="transcript-scroll" ref={scrollRef} onScroll={handleScroll}>
        <article className={`transcript-document ${transcriptEmpty ? 'transcript-document-empty' : ''}`}>
          {generatedSummary && <MeetingSummaryDocument summary={generatedSummary} />}
          <div className={`transcript-lines ${transcriptEmpty ? 'transcript-lines-empty' : ''}`}>
            {meeting.lines.length === 0 ? (
              <div className="awaiting-audio">
                <AudioWaveform size={24} />
                <h2>{active ? t('transcript.awaitingWords') : t('transcript.noTranscript')}</h2>
                <p>{active ? t('transcript.awaitingWordsHelp') : t('transcript.noTranscriptHelp')}</p>
              </div>
            ) : (
              meeting.lines.map((line) => {
                return (
                  <section className="utterance" key={line.id}>
                    {compact ? (
                      <>
                        <div className="compact-utterance-meta">
                          <div className="speaker-label" aria-label={`${localizedSpeakerLabel(line.speaker, t)}, ${line.speaker.toLocaleLowerCase().startsWith('remote') ? t('transcript.systemAudio') : t('transcript.roomMic')}`}>
                            <SpeakerAvatar index={speakerAvatarIndex(line.speaker)} />
                            <strong>{localizedSpeakerLabel(line.speaker, t)}</strong>
                          </div>
                          <time>{line.timestamp}</time>
                        </div>
                        <div className="utterance-content"><p>{line.text}</p></div>
                      </>
                    ) : (
                      <>
                        <time>{line.timestamp}</time>
                        <div className="utterance-content">
                          <div className="speaker-label" aria-label={`${localizedSpeakerLabel(line.speaker, t)}, ${line.speaker.toLocaleLowerCase().startsWith('remote') ? t('transcript.systemAudio') : t('transcript.roomMic')}`}>
                            <SpeakerAvatar index={speakerAvatarIndex(line.speaker)} />
                            <strong>{localizedSpeakerLabel(line.speaker, t)}</strong>
                          </div>
                          <p>{line.text}</p>
                        </div>
                      </>
                    )}
                  </section>
                )
              })
            )}
            {active && meeting.lines.length > 0 && !compact && (
              <div className="listening-tail" aria-label={t('common.listening')}>
                <span /><span /><span />
                {t('common.listening')}
              </div>
            )}
          </div>
        </article>
      </div>

      {active && !followingLive && (
        <button className="jump-live-button" type="button" onClick={jumpToLive}>
          <ArrowDown size={14} /> {t('transcript.jumpToLive')}
        </button>
      )}
    </aside>
  )
}
