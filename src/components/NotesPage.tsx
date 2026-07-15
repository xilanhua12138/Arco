import {
  ArrowUpRight,
  Bold,
  Eye,
  FileText,
  Italic,
  ListChecks,
  PanelLeft,
  PencilLine,
  Plus,
  Strikethrough,
  Table2,
  Trash2,
} from 'lucide-react'
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type MouseEvent } from 'react'
import { useI18n } from '../i18n/i18n'
import type { MeetingSummary, NoteDocument, SaveNoteInput } from '../types'
import { MarkdownContent } from './MarkdownContent'
import { PlatformActionButton } from './PlatformActionButton'
import { PlatformNotesToolbar, type NotesToolbarAction } from './PlatformNotesToolbar'
import { PlatformSearchField } from './PlatformSearchField'

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

interface NoteContextMenu {
  note: NoteDocument
  x: number
  y: number
}

const hasTauriRuntime = () => '__TAURI_INTERNALS__' in window
const BLOCK_PREFIX = /^(?:#{1,6}\s+|>\s+|(?:[-+*]\s+(?:\[[ xX]\]\s+)?)|\d+\.\s+)/

const sameDraftContent = (left: NoteDraft, right: NoteDraft) => (
  left.id === right.id
  && left.title === right.title
  && left.body === right.body
  && left.meetingId === right.meetingId
)

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

const plainTextPreview = (body: string, fallback: string) => {
  const firstLine = body.split('\n').map((line) => line.trim()).find(Boolean)
  if (!firstLine) return fallback

  return firstLine
    .replace(/^#{1,6}\s*/, '')
    .replace(/^(?:[-+*>]|\d+\.)\s+/, '')
    .replace(/\[([^\]]+)]\([^)]+\)/g, '$1')
    .replace(/[*_`~#]/g, '')
    .replace(/\s+/g, ' ')
    .trim() || fallback
}

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
  const [formatOpen, setFormatOpen] = useState(false)
  const [indexOpen, setIndexOpen] = useState(true)
  const [contextMenu, setContextMenu] = useState<NoteContextMenu | null>(null)
  const bodyInputRef = useRef<HTMLTextAreaElement>(null)
  const latestDraftRef = useRef<NoteDraft | null>(null)
  const saveInFlightRef = useRef(false)
  const visibleDraft = draft ?? (notes[0] ? draftFrom(notes[0]) : null)

  useLayoutEffect(() => {
    latestDraftRef.current = visibleDraft
  }, [visibleDraft])

  useEffect(() => {
    if (!contextMenu) return
    const close = () => setContextMenu(null)
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') close()
    }
    window.addEventListener('pointerdown', close)
    window.addEventListener('keydown', closeOnEscape)
    return () => {
      window.removeEventListener('pointerdown', close)
      window.removeEventListener('keydown', closeOnEscape)
    }
  }, [contextMenu])

  const noteTime = (value: string | null) => {
    if (!value) return ''
    const date = new Date(value)
    return Number.isNaN(date.getTime())
      ? t('common.unknownTime')
      : formatDate(date, { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
  }
  const updateDraft = (patch: Partial<NoteDraft>) => {
    const next = { ...(visibleDraft ?? emptyDraft(meetings[0]?.id ?? null)), ...patch }
    latestDraftRef.current = next
    setDraft(next)
    setDirty(true)
    setSavedReceipt(false)
  }
  const replaceDraft = (next: NoteDraft) => {
    if (dirty && !window.confirm(t('notes.discardConfirm'))) return
    latestDraftRef.current = next
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
  const insertAtSelection = (content: string) => {
    const input = bodyInputRef.current
    if (!input || editorMode !== 'write') return
    const body = visibleDraft?.body ?? ''
    const start = input.selectionStart
    const end = input.selectionEnd
    updateDraft({ body: `${body.slice(0, start)}${content}${body.slice(end)}` })
    restoreSelection(start + content.length, start + content.length)
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
      .map((line) => `${prefix}${line.replace(BLOCK_PREFIX, '')}`)
      .join('\n')
    updateDraft({ body: `${body.slice(0, lineStart)}${replacement}${body.slice(lineEnd)}` })
    restoreSelection(lineStart + prefix.length, lineStart + replacement.length)
  }
  const insertTable = () => {
    insertAtSelection('| Column 1 | Column 2 |\n| --- | --- |\n|  |  |')
  }
  const persistDraft = useCallback(async (snapshot: NoteDraft) => {
    if (!snapshot.title.trim() || !snapshot.meetingId || saveInFlightRef.current) return
    saveInFlightRef.current = true
    setSaving(true)
    const saved = await onSaveNote({
      id: snapshot.id,
      meetingId: snapshot.meetingId,
      title: snapshot.title.trim(),
      body: snapshot.body,
    })
    saveInFlightRef.current = false
    setSaving(false)
    if (!saved) return
    const latest = latestDraftRef.current
    if (latest && sameDraftContent(latest, snapshot)) {
      const savedDraft = draftFrom(saved)
      latestDraftRef.current = savedDraft
      setDraft(savedDraft)
      setDirty(false)
      setSavedReceipt(true)
      return
    }
    if (latest && snapshot.id === null && latest.id === null) {
      const identifiedDraft = { ...latest, id: saved.id, updatedAt: saved.updatedAt }
      latestDraftRef.current = identifiedDraft
      setDraft(identifiedDraft)
    }
  }, [onSaveNote])

  useEffect(() => {
    if (!dirty || !visibleDraft?.title.trim() || !visibleDraft.meetingId || saveInFlightRef.current) return
    const snapshot = visibleDraft
    const timeout = window.setTimeout(() => void persistDraft(snapshot), 650)
    return () => window.clearTimeout(timeout)
  }, [dirty, persistDraft, visibleDraft])

  const deleteNoteDocument = useCallback(async (note: NoteDocument) => {
    if (!window.confirm(t('notes.deleteConfirm'))) return
    if (!await onDeleteNote(note.id)) return
    if (latestDraftRef.current?.id === note.id) {
      const nextNote = notes.find((candidate) => candidate.id !== note.id)
      const nextDraft = nextNote ? draftFrom(nextNote) : null
      latestDraftRef.current = nextDraft
      setDraft(nextDraft)
      setDirty(false)
      setSavedReceipt(false)
    }
  }, [notes, onDeleteNote, t])

  const openNoteContextMenu = async (event: MouseEvent<HTMLButtonElement>, note: NoteDocument) => {
    event.preventDefault()
    if (!hasTauriRuntime()) {
      setContextMenu({ note, x: event.clientX, y: event.clientY })
      return
    }
    try {
      const [{ Menu }, { LogicalPosition }] = await Promise.all([
        import('@tauri-apps/api/menu'),
        import('@tauri-apps/api/dpi'),
      ])
      const menu = await Menu.new({
        items: [{
          id: 'delete-note',
          text: t('notes.delete'),
          action: () => void deleteNoteDocument(note),
        }],
      })
      await menu.popup(new LogicalPosition(event.clientX, event.clientY))
      await menu.close()
    } catch (error) {
      console.warn('Arco could not open the native note context menu.', error)
      setContextMenu({ note, x: event.clientX, y: event.clientY })
    }
  }

  const handleNativeToolbarAction = (action: NotesToolbarAction) => {
    switch (action) {
      case 'title': applyLineFormat('# '); break
      case 'heading': applyLineFormat('## '); break
      case 'subheading': applyLineFormat('### '); break
      case 'body': applyLineFormat(''); break
      case 'monostyled': applyInlineFormat('`', '`', t('notes.formatCodeText')); break
      case 'bold': applyInlineFormat('**', '**', t('notes.formatText')); break
      case 'italic': applyInlineFormat('_', '_', t('notes.formatText')); break
      case 'strikethrough': applyInlineFormat('~~', '~~', t('notes.formatText')); break
      case 'bullet': applyLineFormat('* '); break
      case 'dash': applyLineFormat('- '); break
      case 'numbered': applyLineFormat('1. '); break
      case 'checklist': applyLineFormat('- [ ] '); break
      case 'quote': applyLineFormat('> '); break
      case 'table': insertTable(); break
      case 'code': applyInlineFormat('`', '`', t('notes.formatCodeText')); break
      case 'write': setEditorMode('write'); break
      case 'preview': setEditorMode('preview'); break
    }
  }

  const toolbarLabels = {
    format: t('notes.formatToolbar'),
    title: t('notes.formatTitle'),
    heading: t('notes.formatHeading'),
    subheading: t('notes.formatSubheading'),
    body: t('notes.formatBody'),
    monostyled: t('notes.formatMonostyled'),
    bold: t('notes.formatBold'),
    italic: t('notes.formatItalic'),
    strikethrough: t('notes.formatStrikethrough'),
    bullet: t('notes.formatBulletList'),
    dash: t('notes.formatDashList'),
    numbered: t('notes.formatNumberedList'),
    checklist: t('notes.formatChecklist'),
    quote: t('notes.formatQuote'),
    table: t('notes.formatTable'),
    code: t('notes.formatCode'),
    write: t('notes.write'),
    preview: t('notes.preview'),
  }

  const formatToolbar = visibleDraft ? (
    <PlatformNotesToolbar
      labels={toolbarLabels}
      mode={editorMode}
      onAction={handleNativeToolbarAction}
    >
      <div className="note-format-toolbar" role="toolbar" aria-label={t('notes.formatToolbar')}>
        <div className="note-format-actions">
          <button
            type="button"
            className="note-format-trigger"
            aria-expanded={formatOpen}
            disabled={editorMode === 'preview'}
            onClick={() => setFormatOpen((open) => !open)}
          >
            {t('notes.formatToolbar')}
          </button>
          <button type="button" aria-label={t('notes.formatChecklist')} title={t('notes.formatChecklist')} disabled={editorMode === 'preview'} onMouseDown={(event) => event.preventDefault()} onClick={() => applyLineFormat('- [ ] ')}><ListChecks size={17} /></button>
          <button type="button" aria-label={t('notes.formatTable')} title={t('notes.formatTable')} disabled={editorMode === 'preview'} onMouseDown={(event) => event.preventDefault()} onClick={insertTable}><Table2 size={17} /></button>
        </div>
        {formatOpen && (
          <div className="note-format-popover" role="menu" aria-label={t('notes.formatToolbar')}>
            <div className="note-format-inline-row">
              {[
                [toolbarLabels.bold, <Bold size={19} />, 'bold'],
                [toolbarLabels.italic, <Italic size={19} />, 'italic'],
                [toolbarLabels.strikethrough, <Strikethrough size={19} />, 'strikethrough'],
              ].map(([label, icon, action]) => (
                <button key={action as string} type="button" role="menuitem" aria-label={label as string} onMouseDown={(event) => event.preventDefault()} onClick={() => { handleNativeToolbarAction(action as NotesToolbarAction); setFormatOpen(false) }}>{icon}</button>
              ))}
            </div>
            <span className="note-format-menu-divider" aria-hidden="true" />
            {[
              ['title', toolbarLabels.title], ['heading', toolbarLabels.heading], ['subheading', toolbarLabels.subheading],
              ['body', toolbarLabels.body], ['monostyled', toolbarLabels.monostyled], ['bullet', toolbarLabels.bullet],
              ['dash', toolbarLabels.dash], ['numbered', toolbarLabels.numbered], ['quote', toolbarLabels.quote],
            ].map(([action, label]) => (
              <button key={action} type="button" role="menuitem" className={`note-format-menu-${action}`} onMouseDown={(event) => event.preventDefault()} onClick={() => { handleNativeToolbarAction(action as NotesToolbarAction); setFormatOpen(false) }}>
                {action === 'body' && <span aria-hidden="true">✓</span>}{label}
              </button>
            ))}
          </div>
        )}
      </div>
    </PlatformNotesToolbar>
  ) : <span className="note-format-toolbar-placeholder" aria-hidden="true" />

  const indexToggle = (
    <PlatformActionButton
      nativeId="notes-list-toggle"
      className="notes-index-toggle"
      label={indexOpen ? t('notes.hideList') : t('notes.showList')}
      symbol="sidebar.left"
      variant="toolbar"
      onPress={() => setIndexOpen((open) => !open)}
    >
      <PanelLeft size={16} aria-hidden="true" />
    </PlatformActionButton>
  )

  return (
    <main className="history-page notes-page" aria-labelledby="notes-heading">
      <h1 id="notes-heading" className="sr-only">{t('notes.heading')}</h1>
      <section className={indexOpen ? 'notes-workspace' : 'notes-workspace notes-workspace-index-collapsed'} aria-label={t('notes.workspace')}>
        {indexToggle}
        {indexOpen && <aside className="notes-index" aria-label={t('notes.results')} aria-busy={loading}>
          <header className="notes-index-header">
            <div>
              <h2>{t('notes.heading')}</h2>
              <small>{t('notes.count', { count: notes.length })}</small>
            </div>
          </header>
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
                  onContextMenu={(event) => void openNoteContextMenu(event, note)}
                >
                  <strong>{note.title}</strong>
                  <span>{plainTextPreview(note.body, t('notes.emptyBody'))}</span>
                  <small>{note.meetingTitle || t('common.untitledMeeting')} · {note.source === 'agent' ? t('notes.agentNote') : noteTime(note.updatedAt)}</small>
                </button>
              ))}
            </div>
          )}
        </aside>}

        <section className="note-editor" aria-label={t('notes.editor')}>
          <header className="notes-editor-command-bar" role="group" aria-label={t('notes.controls')}>
            <div className="notes-editor-leading">
              <PlatformActionButton
                nativeId="notes-new"
                className="notes-new-button"
                label={t('notes.new')}
                symbol="square.and.pencil"
                variant="toolbar"
                layoutVersion={indexOpen ? 'index-open' : 'index-closed'}
                onPress={() => replaceDraft(emptyDraft(meetings[0]?.id ?? null))}
                disabled={meetings.length === 0}
              >
                <PencilLine size={16} aria-hidden="true" />
                <span className="sr-only">{t('notes.new')}</span>
              </PlatformActionButton>
            </div>

            {formatToolbar}

            <PlatformSearchField
              className="notes-search"
              label={t('notes.search')}
              value={query}
              onChange={onQueryChange}
              placeholder={t('notes.searchPlaceholder')}
            />
          </header>

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
                if (visibleDraft) void persistDraft(visibleDraft)
              }}
              onKeyDown={(event) => {
                if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') {
                  event.preventDefault()
                  void persistDraft(visibleDraft)
                }
              }}
            >
              <header className="note-editor-toolbar" role="group" aria-label={t('notes.documentControls')}>
                <div className="note-editor-modes">
                  <button type="button" className={editorMode === 'write' ? 'note-editor-mode-active' : ''} aria-pressed={editorMode === 'write'} onClick={() => setEditorMode('write')}><PencilLine size={13} /> {t('notes.write')}</button>
                  <button type="button" className={editorMode === 'preview' ? 'note-editor-mode-active' : ''} aria-pressed={editorMode === 'preview'} onClick={() => setEditorMode('preview')}><Eye size={13} /> {t('notes.preview')}</button>
                </div>
                <div className="note-editor-receipt">
                  <span className="note-editor-document-kind">
                    {visibleDraft.source === 'agent' ? t('notes.agentNote') : t('notes.markdownFile')}
                  </span>
                  {visibleDraft.updatedAt && <time dateTime={visibleDraft.updatedAt}>{noteTime(visibleDraft.updatedAt)}</time>}
                  {dirty && <span>{t('notes.unsaved')}</span>}
                  {saving && <span>{t('common.saving')}</span>}
                  {savedReceipt && <strong>{t('common.saved')}</strong>}
                </div>
              </header>

              <div className="note-document-editor">
                <div className="note-editor-content">
                  <div className="note-document-canvas">
                    <div className="note-editor-document-meta" role="group" aria-label={t('notes.metadata')}>
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
                      <div className="note-meeting-row">
                        <div className="note-meeting-field">
                          <label htmlFor="note-meeting-select">{t('notes.meetingLabel')}</label>
                          <div className="note-meeting-control">
                          <select
                            id="note-meeting-select"
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
                            {visibleDraft.meetingId && (
                              <button
                                type="button"
                                className="note-editor-secondary"
                                aria-label={t('notes.openMeeting', {
                                  title: visibleDraft.meetingTitle || t('common.untitledMeeting'),
                                })}
                                title={t('notes.openMeeting', {
                                  title: visibleDraft.meetingTitle || t('common.untitledMeeting'),
                                })}
                                onClick={() => {
                                  if (!dirty || window.confirm(t('notes.discardConfirm'))) {
                                    onOpenMeeting(visibleDraft.meetingId!)
                                  }
                                }}
                              >
                                <ArrowUpRight size={13} aria-hidden="true" />
                              </button>
                            )}
                          </div>
                        </div>
                      </div>
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
      {contextMenu && (
        <div
          className="note-context-menu"
          role="menu"
          style={{ left: contextMenu.x, top: contextMenu.y }}
          onPointerDown={(event) => event.stopPropagation()}
        >
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              const note = contextMenu.note
              setContextMenu(null)
              void deleteNoteDocument(note)
            }}
          >
            <Trash2 size={14} aria-hidden="true" />
            {t('notes.delete')}
          </button>
        </div>
      )}
    </main>
  )
}
