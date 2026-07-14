import {
  ArrowUpRight,
  Bold,
  Code2,
  Eye,
  FileText,
  Heading2,
  Italic,
  List,
  ListChecks,
  ListOrdered,
  PencilLine,
  Plus,
  Quote,
  Save,
  Search,
  Trash2,
} from 'lucide-react'
import { useRef, useState } from 'react'
import { useI18n } from '../i18n/i18n'
import type { MeetingSummary, NoteDocument, SaveNoteInput } from '../types'
import { MarkdownContent } from './MarkdownContent'

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
  const [editorMode, setEditorMode] = useState<'write' | 'preview'>('write')
  const bodyInputRef = useRef<HTMLTextAreaElement>(null)
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
    setEditorMode('write')
  }
  const restoreSelection = (start: number, end: number) => {
    window.requestAnimationFrame(() => {
      bodyInputRef.current?.focus()
      bodyInputRef.current?.setSelectionRange(start, end)
    })
  }
  const applyInlineFormat = (before: string, after: string, placeholder: string) => {
    const input = bodyInputRef.current
    if (!input || editorMode !== 'write') return
    const start = input.selectionStart
    const end = input.selectionEnd
    const selected = visibleDraft?.body.slice(start, end) ?? ''
    const content = selected || placeholder
    const replacement = `${before}${content}${after}`
    updateDraft({
      body: `${visibleDraft?.body.slice(0, start) ?? ''}${replacement}${visibleDraft?.body.slice(end) ?? ''}`,
    })
    restoreSelection(start + before.length, start + before.length + content.length)
  }
  const applyLineFormat = (prefix: string) => {
    const input = bodyInputRef.current
    if (!input || editorMode !== 'write') return
    const body = visibleDraft?.body ?? ''
    const start = input.selectionStart
    const end = input.selectionEnd
    const lineStart = body.lastIndexOf('\n', Math.max(0, start - 1)) + 1
    const nextBreak = body.indexOf('\n', end)
    const lineEnd = nextBreak === -1 ? body.length : nextBreak
    const selectedLines = body.slice(lineStart, lineEnd)
    const replacement = selectedLines
      .split('\n')
      .map((line) => `${prefix}${line}`)
      .join('\n')
    updateDraft({ body: `${body.slice(0, lineStart)}${replacement}${body.slice(lineEnd)}` })
    restoreSelection(lineStart + prefix.length, lineStart + replacement.length)
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
        <aside className="notes-index" aria-label={t('notes.results')} aria-busy={loading}>
          {loading && notes.length === 0 ? (
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

              <div className="note-document-editor">
                <div className="note-format-toolbar" role="toolbar" aria-label={t('notes.formatToolbar')}>
                  <div className="note-format-actions">
                    <button type="button" aria-label={t('notes.formatHeading')} title={t('notes.formatHeading')} disabled={editorMode === 'preview'} onMouseDown={(event) => event.preventDefault()} onClick={() => applyLineFormat('## ')}><Heading2 size={15} /></button>
                    <button type="button" aria-label={t('notes.formatBold')} title={t('notes.formatBold')} disabled={editorMode === 'preview'} onMouseDown={(event) => event.preventDefault()} onClick={() => applyInlineFormat('**', '**', t('notes.formatText'))}><Bold size={15} /></button>
                    <button type="button" aria-label={t('notes.formatItalic')} title={t('notes.formatItalic')} disabled={editorMode === 'preview'} onMouseDown={(event) => event.preventDefault()} onClick={() => applyInlineFormat('_', '_', t('notes.formatText'))}><Italic size={15} /></button>
                    <span className="note-format-divider" aria-hidden="true" />
                    <button type="button" aria-label={t('notes.formatBulletList')} title={t('notes.formatBulletList')} disabled={editorMode === 'preview'} onMouseDown={(event) => event.preventDefault()} onClick={() => applyLineFormat('- ')}><List size={15} /></button>
                    <button type="button" aria-label={t('notes.formatNumberedList')} title={t('notes.formatNumberedList')} disabled={editorMode === 'preview'} onMouseDown={(event) => event.preventDefault()} onClick={() => applyLineFormat('1. ')}><ListOrdered size={15} /></button>
                    <button type="button" aria-label={t('notes.formatChecklist')} title={t('notes.formatChecklist')} disabled={editorMode === 'preview'} onMouseDown={(event) => event.preventDefault()} onClick={() => applyLineFormat('- [ ] ')}><ListChecks size={15} /></button>
                    <button type="button" aria-label={t('notes.formatQuote')} title={t('notes.formatQuote')} disabled={editorMode === 'preview'} onMouseDown={(event) => event.preventDefault()} onClick={() => applyLineFormat('> ')}><Quote size={15} /></button>
                    <button type="button" aria-label={t('notes.formatCode')} title={t('notes.formatCode')} disabled={editorMode === 'preview'} onMouseDown={(event) => event.preventDefault()} onClick={() => applyInlineFormat('`', '`', t('notes.formatCodeText'))}><Code2 size={15} /></button>
                  </div>
                  <div className="note-editor-modes">
                    <button type="button" className={editorMode === 'write' ? 'note-editor-mode-active' : ''} aria-pressed={editorMode === 'write'} onClick={() => setEditorMode('write')}><PencilLine size={13} /> {t('notes.write')}</button>
                    <button type="button" className={editorMode === 'preview' ? 'note-editor-mode-active' : ''} aria-pressed={editorMode === 'preview'} onClick={() => setEditorMode('preview')}><Eye size={13} /> {t('notes.preview')}</button>
                  </div>
                </div>
                <div className="note-editor-content">
                  <div className="note-document-canvas">
                    <div className="note-editor-document-meta">
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
                        <span>{t('notes.meetingLabel')}</span>
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
                    </div>
                    {editorMode === 'write' ? (
                      <>
                        <label className="sr-only" htmlFor="note-body">{t('notes.markdownEditor')}</label>
                        <textarea
                          ref={bodyInputRef}
                          id="note-body"
                          className="note-body-input"
                          aria-label={t('notes.markdownEditor')}
                          value={visibleDraft.body}
                          onChange={(event) => updateDraft({ body: event.target.value })}
                          placeholder={t('notes.bodyPlaceholder')}
                          spellCheck
                        />
                      </>
                    ) : visibleDraft.body.trim() ? (
                      <MarkdownContent className="note-markdown-preview">{visibleDraft.body}</MarkdownContent>
                    ) : (
                      <p className="note-preview-empty">{t('notes.previewEmpty')}</p>
                    )}
                  </div>
                </div>
              </div>
            </form>
          )}
        </section>
      </section>
    </main>
  )
}
