import {
  ArrowUp,
  BookOpenText,
  Bookmark,
  Check,
  CircleAlert,
  Copy,
  FileSearch,
  FolderOpen,
  Link2,
  Plus,
  X,
} from 'lucide-react'
import { useState } from 'react'
import type {
  AskAgentInput,
  ContextScope,
  MeetingDetail,
  PersistedAgentTurn,
  ProviderId,
  RuntimeStatus,
} from '../types'
import { useI18n } from '../i18n/i18n'
import { workspaceName } from '../lib/agentWorkspace'

interface InsightPanelProps {
  meeting: MeetingDetail | null
  replies: PersistedAgentTurn[]
  runtimes: RuntimeStatus[]
  provider: ProviderId
  primaryProvider: ProviderId
  isFailover: boolean
  running: boolean
  onAsk: (input: AskAgentInput) => Promise<boolean> | boolean
  onToggleSaved: (meetingId: string, turnId: string, saved: boolean) => Promise<boolean> | boolean
  workspace?: string | null
  onChooseWorkspace?: () => Promise<string | null>
  live?: boolean
  onClose?: () => void
  showHeader?: boolean
}

const sourceIcon = (kind: PersistedAgentTurn['sources'][number]['kind']) => {
  if (kind === 'transcript') return <BookOpenText size={13} />
  if (kind === 'workspace') return <FileSearch size={13} />
  return <Link2 size={13} />
}

export function InsightPanel({
  meeting,
  replies,
  runtimes,
  provider,
  primaryProvider,
  isFailover,
  running,
  onAsk,
  onToggleSaved,
  workspace = null,
  onChooseWorkspace = async () => null,
  live = false,
  onClose,
  showHeader = false,
}: InsightPanelProps) {
  const { t } = useI18n()
  const [scope, setScope] = useState<ContextScope>('transcript')
  const [question, setQuestion] = useState('')
  const [copiedReply, setCopiedReply] = useState<number | null>(null)
  const [requestError, setRequestError] = useState(false)
  const [contextMenuOpen, setContextMenuOpen] = useState(false)
  const [savingTurnId, setSavingTurnId] = useState<string | null>(null)
  const runtime = runtimes.find((candidate) => candidate.provider === provider)
  const workspaceMissing = scope === 'workspace' && !workspace
  const quickPrompts = [
    { label: t('agent.quick.answer.label'), prompt: t('agent.quick.answer.prompt') },
    { label: t('agent.quick.unresolved.label'), prompt: t('agent.quick.unresolved.prompt') },
    { label: t('agent.quick.challenge.label'), prompt: t('agent.quick.challenge.prompt') },
  ]
  const submit = async (prompt = question) => {
    if (!meeting || !prompt.trim() || running || !runtime?.available || workspaceMissing) return
    setRequestError(false)
    try {
      const succeeded = await onAsk({
        provider,
        usedFallback: isFailover,
        question: prompt,
        meetingId: meeting.summary.id,
        contextScope: scope,
        workspace: scope === 'workspace' ? workspace ?? undefined : undefined,
      })
      if (!succeeded) {
        if (!question.trim()) setQuestion(prompt.trim())
        setRequestError(true)
        return
      }
      setQuestion('')
    } catch {
      if (!question.trim()) setQuestion(prompt.trim())
      setRequestError(true)
    }
  }

  const copyReply = async (reply: PersistedAgentTurn, index: number) => {
    await navigator.clipboard.writeText(reply.answer)
    setCopiedReply(index)
    window.setTimeout(() => setCopiedReply(null), 1_500)
  }

  return (
    <main
      className="insight-panel agent-workspace"
      id="agent-workspace"
      aria-labelledby={showHeader ? 'agent-heading' : undefined}
      aria-label={showHeader ? undefined : t('agent.askArco')}
    >
      {showHeader && (
        <header className="insight-header agent-workspace-header">
          <h2 id="agent-heading">{t('agent.askArco')}</h2>
          {(live || onClose) && (
            <div className="agent-overlay-header-actions">
              {live && <span className="agent-live-status">{t('agent.live')}</span>}
              {onClose && (
                <button type="button" className="agent-overlay-close" onClick={onClose} aria-label={t('agent.close')}>
                  <X size={17} aria-hidden="true" />
                </button>
              )}
            </div>
          )}
        </header>
      )}

      <div className="insight-scroll agent-workspace-body">
        {!runtime?.available && (
          <div className="inline-notice inline-notice-warning" role="status">
            <CircleAlert size={16} />
            <span>
              <strong>{t('agent.notFound', { runtime: provider === 'codex' ? 'Codex CLI' : 'Claude Code' })}</strong>
              {t('agent.notFoundHelp')}
            </span>
          </div>
        )}

        {isFailover && (
          <div className="inline-notice agent-failover-notice" role="status">
            <CircleAlert size={16} />
            <span>{t('agent.failover', {
              primary: primaryProvider === 'codex' ? 'Codex' : 'Claude',
              provider: provider === 'codex' ? 'Codex' : 'Claude',
            })}</span>
          </div>
        )}

        {replies.length === 0 && (
          <section className="quick-actions" aria-label={t('agent.suggestedActions')}>
            <div className="quick-action-list">
              {quickPrompts.map(({ label, prompt }) => (
                <button
                  type="button"
                  key={label}
                  onClick={() => submit(prompt)}
                  disabled={running || !runtime?.available || workspaceMissing}
                >
                  <strong>{label}</strong>
                  <ArrowUp size={14} />
                </button>
              ))}
            </div>
          </section>
        )}

        {replies.map((reply, index) => (
          <article className="agent-reply" key={reply.id}>
            {reply.usedFallback && (
              <span className="reply-provider-fallback">{t('agent.fallback', { provider: reply.provider === 'codex' ? 'Codex' : 'Claude' })}</span>
            )}
            <h3 className="agent-turn-question">{reply.question}</h3>
            {reply.answer.split(/\n{2,}/).map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
            {reply.sources.length > 0 && (
              <section className="context-used" aria-label={t('agent.contextUsedAria')}>
                <h3>{t('agent.contextUsed')}</h3>
                <ol className="source-list">
                  {reply.sources.map((source, sourceIndex) => (
                    <li key={`${source.kind}-${source.reference}`}>
                      <span>{String(sourceIndex + 1).padStart(2, '0')}</span>
                      {sourceIcon(source.kind)}
                      <span>{source.label}</span>
                    </li>
                  ))}
                </ol>
              </section>
            )}
            <div className="reply-actions">
              <button
                type="button"
                disabled={savingTurnId === reply.id}
                aria-label={reply.savedAsNote ? t('agent.savedNote') : t('agent.saveAsNote')}
                onClick={async () => {
                  setSavingTurnId(reply.id)
                  await onToggleSaved(reply.meetingId, reply.id, !reply.savedAsNote)
                  setSavingTurnId(null)
                }}
              >
                {reply.savedAsNote ? <Check size={13} /> : <Bookmark size={13} />}
                {savingTurnId === reply.id ? t('common.saving') : reply.savedAsNote ? t('agent.savedNote') : t('agent.saveAsNote')}
              </button>
              <button type="button" onClick={() => copyReply(reply, index)}>
                {copiedReply === index ? <Check size={13} /> : <Copy size={13} />}
                {copiedReply === index ? t('agent.copied') : t('agent.copy')}
              </button>
            </div>
          </article>
        ))}

        {running && (
          <div className="agent-thinking" role="status">
            <span /><span /><span />
            {t('agent.thinking')}
          </div>
        )}
      </div>

      <form
        className="ask-composer"
        onSubmit={(event) => {
          event.preventDefault()
          void submit()
        }}
      >
        <div className="composer-context-rail" aria-label={t('agent.referenceContext')}>
          <span className="composer-context-chip composer-context-chip-fixed">
            <BookOpenText size={12} aria-hidden="true" />
            {t('agent.scope.transcript')}
          </span>
          {scope === 'workspace' && workspace && (
            <button
              type="button"
              className="composer-context-chip"
              aria-label={t('agent.changeWorkspace')}
              title={workspace}
              onClick={() => void onChooseWorkspace()}
            >
              <FolderOpen size={12} aria-hidden="true" />
              <span>{workspaceName(workspace)}</span>
            </button>
          )}
        </div>
        <textarea
          id="agent-question"
          value={question}
          onChange={(event) => setQuestion(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
              event.preventDefault()
              void submit()
            }
          }}
          placeholder={t('agent.placeholder')}
          rows={3}
          aria-label={t('agent.questionAria')}
          disabled={!meeting}
        />
        {requestError && (
          <p className="agent-request-error" role="status">{t('agent.requestError')}</p>
        )}
        <div className="composer-footer">
          <div className="composer-context-picker">
            <button
              type="button"
              className="composer-add-context"
              aria-label={t('agent.addContext')}
              aria-expanded={contextMenuOpen}
              onClick={() => setContextMenuOpen((open) => !open)}
            >
              <Plus size={16} aria-hidden="true" />
            </button>
            {contextMenuOpen && (
              <div className="composer-context-menu" role="menu" aria-label={t('agent.contextMenu')}>
                {workspace && scope === 'transcript' && (
                  <button
                    type="button"
                    role="menuitem"
                    onClick={() => {
                      setScope('workspace')
                      setContextMenuOpen(false)
                    }}
                  >
                    <FolderOpen size={14} aria-hidden="true" />
                    {t('agent.useWorkspace', { workspace: workspaceName(workspace) })}
                  </button>
                )}
                {scope === 'workspace' && (
                  <button
                    type="button"
                    role="menuitem"
                    onClick={() => {
                      setScope('transcript')
                      setContextMenuOpen(false)
                    }}
                  >
                    <BookOpenText size={14} aria-hidden="true" />
                    {t('agent.useTranscriptOnly')}
                  </button>
                )}
                <button
                  type="button"
                  role="menuitem"
                  onClick={async () => {
                    const selected = await onChooseWorkspace()
                    if (selected) setScope('workspace')
                    setContextMenuOpen(false)
                  }}
                >
                  <FolderOpen size={14} aria-hidden="true" />
                  {workspace ? t('agent.chooseAnotherWorkspace') : t('agent.chooseWorkspace')}
                </button>
              </div>
            )}
          </div>
          <button
            type="submit"
            className="send-button"
            disabled={!question.trim() || running || !meeting || !runtime?.available || workspaceMissing}
            aria-label={t('agent.send')}
          >
            <ArrowUp size={16} />
          </button>
        </div>
      </form>
    </main>
  )
}
