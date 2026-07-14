import {
  ArrowUp,
  BookOpenText,
  Bookmark,
  Check,
  ChevronRight,
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
  AgentStreamingTurn,
  ContextScope,
  MeetingDetail,
  PersistedAgentTurn,
  ProviderId,
  RuntimeStatus,
} from '../types'
import { useI18n } from '../i18n/i18n'
import { workspaceName } from '../lib/agentWorkspace'
import { MarkdownContent } from './MarkdownContent'

interface InsightPanelProps {
  meeting: MeetingDetail | null
  replies: PersistedAgentTurn[]
  runtimes: RuntimeStatus[]
  provider: ProviderId | null
  primaryProvider: ProviderId | null
  isFailover: boolean
  running: boolean
  onAsk: (input: AskAgentInput) => Promise<boolean> | boolean
  onToggleSaved: (meetingId: string, turnId: string, saved: boolean) => Promise<boolean> | boolean
  workspace?: string | null
  onChooseWorkspace?: () => Promise<string | null>
  live?: boolean
  onClose?: () => void
  showHeader?: boolean
  onConnectAgent?: () => void
  streamingTurn?: AgentStreamingTurn | null
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
  onConnectAgent,
  streamingTurn = null,
}: InsightPanelProps) {
  const { t } = useI18n()
  const [scope, setScope] = useState<ContextScope>('transcript')
  const [question, setQuestion] = useState('')
  const [copiedReply, setCopiedReply] = useState<number | null>(null)
  const [requestError, setRequestError] = useState(false)
  const [contextMenuOpen, setContextMenuOpen] = useState(false)
  const [openContextTurnId, setOpenContextTurnId] = useState<string | null>(null)
  const [savingTurnId, setSavingTurnId] = useState<string | null>(null)
  const [pendingQuestion, setPendingQuestion] = useState<string | null>(null)
  const activeStreamingTurn = streamingTurn?.meetingId === meeting?.summary.id
    ? streamingTurn
    : null
  const streamingStatus = activeStreamingTurn?.phase === 'starting'
    ? t('agent.stream.starting')
    : activeStreamingTurn?.phase === 'using-tools'
      ? t('agent.stream.usingTools')
      : activeStreamingTurn?.phase === 'finalizing'
        ? t('agent.stream.finalizing')
        : t('agent.thinking')
  const runtime = provider
    ? runtimes.find((candidate) => candidate.provider === provider)
    : undefined
  const workspaceMissing = scope === 'workspace' && !workspace
  const quickPrompts = [
    { label: t('agent.quick.answer.label'), prompt: t('agent.quick.answer.prompt') },
    { label: t('agent.quick.unresolved.label'), prompt: t('agent.quick.unresolved.prompt') },
    { label: t('agent.quick.challenge.label'), prompt: t('agent.quick.challenge.prompt') },
  ]
  const submit = async (displayQuestion = question, agentPrompt?: string) => {
    const normalizedQuestion = displayQuestion.trim()
    const normalizedAgentPrompt = agentPrompt?.trim()
    if (!meeting || !provider || !normalizedQuestion || running || pendingQuestion || !runtime?.available || workspaceMissing) return
    setRequestError(false)
    setPendingQuestion(normalizedQuestion)
    setQuestion('')
    try {
      const succeeded = await onAsk({
        provider,
        usedFallback: isFailover,
        question: normalizedQuestion,
        agentPrompt: normalizedAgentPrompt || undefined,
        meetingId: meeting.summary.id,
        contextScope: scope,
        workspace: scope === 'workspace' ? workspace ?? undefined : undefined,
      })
      if (!succeeded) {
        setQuestion(normalizedQuestion)
        setRequestError(true)
        setPendingQuestion(null)
        return
      }
      setPendingQuestion(null)
    } catch {
      setQuestion(normalizedQuestion)
      setRequestError(true)
      setPendingQuestion(null)
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
        {!provider && (
          <section className="agent-dock-state" aria-label={t('agent.connectAgentTitle')}>
            <div>
              <h3>{t('agent.connectAgentTitle')}</h3>
              <p>{t('agent.connectFirst')}</p>
              {onConnectAgent && (
                <button type="button" onClick={onConnectAgent}>{t('agent.setUpAgent')}</button>
              )}
            </div>
          </section>
        )}

        {provider && !meeting && (
          <section className="agent-dock-state" aria-label={t('agent.waitingForMeeting')}>
            <div>
              <h3>{t('agent.waitingForMeeting')}</h3>
              <p>{t('agent.startListeningHelp')}</p>
            </div>
          </section>
        )}

        {provider && meeting && <>
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

        {replies.length === 0 && !pendingQuestion && (
          <section className="quick-actions" aria-label={t('agent.suggestedActions')}>
            <div className="quick-action-list">
              {quickPrompts.map(({ label, prompt }) => (
                <button
                  type="button"
                  key={label}
                  onClick={() => submit(label, prompt)}
                  disabled={running || Boolean(pendingQuestion) || !runtime?.available || workspaceMissing}
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
            <MarkdownContent className="agent-reply-markdown">{reply.answer}</MarkdownContent>
            <div className="reply-actions">
              {reply.sources.length > 0 && (
                <button
                  type="button"
                  className="context-disclosure"
                  aria-expanded={openContextTurnId === reply.id}
                  aria-controls={`context-used-${reply.id}`}
                  onClick={() => setOpenContextTurnId((current) => current === reply.id ? null : reply.id)}
                >
                  <ChevronRight size={13} aria-hidden="true" />
                  {t('agent.contextUsed')} · {reply.sources.length}
                </button>
              )}
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
              <button
                type="button"
                aria-label={copiedReply === index ? t('agent.copied') : t('agent.copy')}
                onClick={() => copyReply(reply, index)}
              >
                {copiedReply === index ? <Check size={13} /> : <Copy size={13} />}
                <span className="reply-copy-label">
                  {copiedReply === index ? t('agent.copied') : t('agent.copy')}
                </span>
              </button>
            </div>
            {openContextTurnId === reply.id && (
              <section
                className="context-used"
                id={`context-used-${reply.id}`}
                aria-label={t('agent.contextUsedAria')}
              >
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
          </article>
        ))}

        {pendingQuestion && (
          <article className="agent-reply agent-pending-turn">
            <h3 className="agent-turn-question">{pendingQuestion}</h3>
            {activeStreamingTurn?.answer ? (
              <MarkdownContent className="agent-reply-markdown">{activeStreamingTurn.answer}</MarkdownContent>
            ) : (
              <div className="agent-thinking" role="status">
                <span /><span /><span />
                {streamingStatus}
              </div>
            )}
          </article>
        )}

        {running && !pendingQuestion && (
          <div className="agent-thinking" role="status">
            <span /><span /><span />
            {streamingStatus}
          </div>
        )}
        </>}
      </div>

      {provider && meeting && <form
        className="ask-composer"
        onSubmit={(event) => {
          event.preventDefault()
          void submit()
        }}
      >
        <div className="composer-context-rail" aria-label={t('agent.referenceContext')}>
          <span className="composer-context-chip composer-context-chip-fixed">
            <BookOpenText size={11} aria-hidden="true" />
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
              <FolderOpen size={11} aria-hidden="true" />
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
          rows={2}
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
            disabled={!question.trim() || running || Boolean(pendingQuestion) || !meeting || !runtime?.available || workspaceMissing}
            aria-label={t('agent.send')}
          >
            <ArrowUp size={16} />
          </button>
        </div>
      </form>}
    </main>
  )
}
