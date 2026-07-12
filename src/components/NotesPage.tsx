import { ArrowUpRight, FileText, Plus, Save, Search, Trash2 } from 'lucide-react'
import { useState } from 'react'
import { useI18n } from '../i18n/i18n'
import type { MeetingSummary, NoteDocument, SaveNoteInput } from '../types'

interface NotesPageProps {
  notes: NoteDocument[]
  meetings: MeetingSummary[]
  query: string
  loading: boolean
  onQueryChange: (query: string) => void
  onOpenMeeting: (meetingId: string) => void
  onSaveNote: (input: SaveNoteInput) => Promise<NoteDocument | null>
  onDeleteNote: (noteId: string) => Promise<boolean>
}

interface NoteDraft {
  id: string | null
  title: string
  body: string
  source: NoteDocument['source']
  meetingId: string | null
  meetingTitle: string | null
  updatedAt: string | null
}

const draftFrom = (note: NoteDocument): NoteDraft => ({
  id: note.id,
  title: note.title,
  body: note.body,
  source: note.source,
  meetingId: note.meetingId,
  meetingTitle: note.meetingTitle,
  updatedAt: note.updatedAt,
})

const emptyDraft = (meetingId: string | null): NoteDraft => ({
  id: null,
  title: '',
  body: '',
  source: 'manual',
  meetingId,
  meetingTitle: null,
  updatedAt: null,
})

export function NotesPage({
  notes,
  meetings,
  query,
  loading,
  onQueryChange,
  onOpenMeeting,
  onSaveNote,
  onDeleteNote,
}: NotesPageProps) {
  const { t, formatDate } = useI18n()
  const [draft, setDraft] = useState<NoteDraft | null>(null)
  const [dirty, setDirty] = useState(false)
  const [saving, setSaving] = useState(false)
  const [savedReceipt, setSavedReceipt] = useState(false)
  const visibleDraft = draft ?? (notes[0] ? draftFrom(notes[0]) : null)

  const noteTime = (value: string | null) => {
    if (!value) return ''
    const date = new Date(value)
    return Number.isNaN(date.getTime())
      ? t('common.unknownTime')
      : formatDate(date, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
  }
  const updateDraft = (patch: Partial<NoteDraft>) => {
    setDraft({ ...(visibleDraft ?? emptyDraft(meetings[0]?.id ?? null)), ...patch })
    setDirty(true)
    setSavedReceipt(false)
  }
  const replaceDraft = (next: NoteDraft) => {
    if (dirty && !window.confirm(t('notes.discardConfirm'))) return
    setDraft(next)
    setDirty(false)
    setSavedReceipt(false)
  }
  const saveDraft = async () => {
    if (!visibleDraft?.title.trim() || !visibleDraft.meetingId || saving) return
    setSaving(true)
    const saved = await onSaveNote({
      id: visibleDraft.id,
      meetingId: visibleDraft.meetingId,
      title: visibleDraft.title.trim(),
      body: visibleDraft.body,
    })
    setSaving(false)
    if (!saved) return
    setDraft(draftFrom(saved))
    setDirty(false)
    setSavedReceipt(true)
  }

  return (
    <main className="history-page notes-page" aria-labelledby="notes-heading">
      <header className="page-header history-page-header notes-page-header">
        <div className="page-title-block"><h1 id="notes-heading">{t('notes.heading')}</h1></div>
        <div className="notes-header-actions">
          <label className="history-search notes-search">
            <Search size={17} aria-hidden="true" />
            <span className="sr-only">{t('notes.search')}</span>
            <input
              aria-label={t('notes.search')}
              value={query}
              onChange={(event) => onQueryChange(event.target.value)}
              placeholder={t('notes.searchPlaceholder')}
            />
          </label>
          <button
            type="button"
            className="notes-new-button"
            onClick={() => replaceDraft(emptyDraft(meetings[0]?.id ?? null))}
            disabled={meetings.length === 0}
          >
            <Plus size={15} aria-hidden="true" /> {t('notes.new')}
          </button>
        </div>
      </header>

      <section className="notes-workspace" aria-label={t('notes.workspace')}>
        <aside className="notes-index" aria-label={t('notes.results')}>
          {loading ? (
            <div className="notes-loading" role="status" aria-label={t('notes.loading')}>
              {[0, 1, 2].map((item) => <span key={item} />)}
            </div>
          ) : notes.length === 0 ? (
            <div className="notes-index-empty">
              <FileText size={18} aria-hidden="true" />
              <strong>{query.trim() ? t('notes.noMatches') : t('notes.empty')}</strong>
              <span>{query.trim() ? t('notes.noMatchesHelp') : t('notes.emptyHelp')}</span>
            </div>
          ) : (
            <div className="notes-index-list">
              {notes.map((note) => (
                <button
                  type="button"
                  className={visibleDraft?.id === note.id ? 'note-index-row note-index-row-active' : 'note-index-row'}
                  key={note.id}
                  aria-current={visibleDraft?.id === note.id ? 'page' : undefined}
                  onClick={() => replaceDraft(draftFrom(note))}
                >
                  <strong>{note.title}</strong>
                  <span>{note.body.trim().split('\n').find(Boolean) || t('notes.emptyBody')}</span>
                  <small>{note.meetingTitle || t('common.untitledMeeting')} · {note.source === 'agent' ? t('notes.agentNote') : noteTime(note.updatedAt)}</small>
                </button>
              ))}
            </div>
          )}
        </aside>

        <section className="note-editor" aria-label={t('notes.editor')}>
          {!visibleDraft ? (
            <div className="note-editor-empty">
              <FileText size={22} aria-hidden="true" />
              <h2>{t('notes.writeFirst')}</h2>
              <p>{t('notes.writeFirstHelp')}</p>
              <button
                type="button"
                aria-label={t('notes.writeFirst')}
                disabled={meetings.length === 0}
                onClick={() => setDraft(emptyDraft(meetings[0]?.id ?? null))}
              >
                <Plus size={15} aria-hidden="true" /> {t('notes.new')}
              </button>
            </div>
          ) : (
            <form
              className="note-editor-form"
              onSubmit={(event) => {
                event.preventDefault()
                void saveDraft()
              }}
              onKeyDown={(event) => {
                if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') {
                  event.preventDefault()
                  void saveDraft()
                }
              }}
            >
              <header className="note-editor-toolbar">
                <div className="note-editor-receipt">
                  {visibleDraft.source === 'agent' ? t('notes.agentNote') : t('notes.markdownFile')}
                  {visibleDraft.updatedAt && <span>· {noteTime(visibleDraft.updatedAt)}</span>}
                  {dirty && <span>· {t('notes.unsaved')}</span>}
                  {savedReceipt && <strong>{t('common.saved')}</strong>}
                </div>
                <div>
                  {visibleDraft.meetingId && (
                    <button
                      type="button"
                      className="note-editor-secondary"
                      onClick={() => {
                        if (!dirty || window.confirm(t('notes.discardConfirm'))) {
                          onOpenMeeting(visibleDraft.meetingId!)
                        }
                      }}
                    >
                      {visibleDraft.meetingTitle || t('common.untitledMeeting')} <ArrowUpRight size={13} />
                    </button>
                  )}
                  {visibleDraft.id && (
                    <button
                      type="button"
                      className="note-editor-danger"
                      aria-label={t('notes.delete')}
                      onClick={async () => {
                        if (!window.confirm(t('notes.deleteConfirm'))) return
                        if (await onDeleteNote(visibleDraft.id!)) {
                          setDraft(null)
                          setDirty(false)
                        }
                      }}
                    >
                      <Trash2 size={14} aria-hidden="true" />
                    </button>
                  )}
                  <button
                    type="submit"
                    className="note-editor-save"
                    disabled={!visibleDraft.title.trim() || !visibleDraft.meetingId || saving || (!dirty && Boolean(visibleDraft.id))}
                  >
                    <Save size={14} aria-hidden="true" />
                    {saving ? t('common.saving') : t('notes.save')}
                  </button>
                </div>
              </header>

              <label className="sr-only" htmlFor="note-title">{t('notes.title')}</label>
              <input
                id="note-title"
                className="note-title-input"
                aria-label={t('notes.title')}
                value={visibleDraft.title}
                onChange={(event) => updateDraft({ title: event.target.value })}
                placeholder={t('notes.titlePlaceholder')}
                maxLength={120}
                autoFocus={!visibleDraft.id}
              />
              <label className="note-meeting-field">
                <span>{t('notes.meeting')}</span>
                <select
                  aria-label={t('notes.meeting')}
                  value={visibleDraft.meetingId ?? ''}
                  disabled={visibleDraft.source === 'agent'}
                  onChange={(event) => updateDraft({
                    meetingId: event.target.value || null,
                    meetingTitle: meetings.find((meeting) => meeting.id === event.target.value)?.title ?? null,
                  })}
                >
                  <option value="" disabled>{t('notes.chooseMeeting')}</option>
                  {meetings.map((meeting) => (
                    <option value={meeting.id} key={meeting.id}>
                      {meeting.title?.trim() || t('common.untitledMeeting')}
                    </option>
                  ))}
                </select>
              </label>
              <label className="sr-only" htmlFor="note-body">{t('notes.markdownEditor')}</label>
              <textarea
                id="note-body"
                className="note-body-input"
                aria-label={t('notes.markdownEditor')}
                value={visibleDraft.body}
                onChange={(event) => updateDraft({ body: event.target.value })}
                placeholder={t('notes.bodyPlaceholder')}
                spellCheck
              />
            </form>
          )}
        </section>
      </section>
    </main>
  )
}
