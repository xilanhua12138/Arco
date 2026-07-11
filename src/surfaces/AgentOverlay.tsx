import { PanelRightClose, PanelRightOpen, X } from 'lucide-react'
import { useEffect, useState } from 'react'
import '../App.css'
import { InsightPanel } from '../components/InsightPanel'
import { TranscriptPane } from '../components/TranscriptPane'
import { useArco } from '../hooks/useArco'
import { useAgentWorkspace } from '../hooks/useAgentWorkspace'
import { arcoBridge } from '../lib/bridge'
import { loadProviderConfig, resolveProviderRoute } from '../lib/providerConfig'
import { useI18n } from '../i18n/i18n'
import './Surfaces.css'

export function AgentOverlay() {
  const { t } = useI18n()
  const arco = useArco()
  const agentWorkspace = useAgentWorkspace(t('agent.chooseWorkspaceDialogTitle'))
  const [providerConfig, setProviderConfig] = useState(loadProviderConfig)
  const [transcriptVisible, setTranscriptVisible] = useState(() => (
    window.localStorage.getItem('arco.agentTranscriptVisible') !== 'false'
  ))
  const providerRoute = resolveProviderRoute(providerConfig, arco.runtimes)
  const live = arco.capture.phase === 'recording' && arco.meeting?.summary.id === arco.capture.activeMeetingId

  const resizeForTranscript = (visible: boolean) => {
    setTranscriptVisible(visible)
    window.localStorage.setItem('arco.agentTranscriptVisible', String(visible))
    void arcoBridge.setAgentTranscriptVisible(visible)
  }

  useEffect(() => {
    const refreshSurface = () => {
      setProviderConfig(loadProviderConfig())
      void arco.syncCapture()
      void arcoBridge.setAgentTranscriptVisible(transcriptVisible)
    }
    const hide = (event: KeyboardEvent) => {
      if (event.key === 'Escape' || ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'w')) {
        event.preventDefault()
        void arcoBridge.hideAgentOverlay()
      }
    }
    window.addEventListener('focus', refreshSurface)
    window.addEventListener('storage', refreshSurface)
    window.addEventListener('keydown', hide)
    return () => {
      window.removeEventListener('focus', refreshSurface)
      window.removeEventListener('storage', refreshSurface)
      window.removeEventListener('keydown', hide)
    }
  }, [arco, transcriptVisible])

  return (
    <section className="agent-overlay-surface" role="dialog" aria-label={t('agent.askArco')} data-transcript={transcriptVisible ? 'open' : 'closed'}>
      <header className="agent-overlay-shared-header">
        <div className="agent-overlay-agent-header">
          <h2>{t('agent.askArco')}</h2>
          {!transcriptVisible && (
            <div className="agent-overlay-window-actions">
              <button type="button" className="agent-transcript-toggle agent-transcript-show" onClick={() => resizeForTranscript(true)} aria-label={t('agent.showTranscript')}>
                <PanelRightOpen size={15} aria-hidden="true" />
                {t('transcript.heading')}
              </button>
              <button type="button" className="agent-overlay-close" onClick={() => void arcoBridge.hideAgentOverlay()} aria-label={t('agent.close')}>
                <X size={17} aria-hidden="true" />
              </button>
            </div>
          )}
        </div>
        {transcriptVisible && (
          <div className="agent-overlay-transcript-header">
            <h2>{t('transcript.heading')}</h2>
            <div className="agent-overlay-window-actions">
              {live && <span className="agent-live-status">{t('agent.live')}</span>}
              <button type="button" className="agent-transcript-toggle" onClick={() => resizeForTranscript(false)} aria-label={t('agent.hideTranscript')}>
                <PanelRightClose size={16} aria-hidden="true" />
              </button>
              <button type="button" className="agent-overlay-close" onClick={() => void arcoBridge.hideAgentOverlay()} aria-label={t('agent.close')}>
                <X size={17} aria-hidden="true" />
              </button>
            </div>
          </div>
        )}
      </header>

      <div className="agent-overlay-workspace">
        <div className="agent-overlay-agent-slot">
          {providerRoute.provider ? (
            <InsightPanel
              key={arco.meeting?.summary.id ?? 'no-meeting'}
              meeting={arco.meeting}
              replies={arco.agentReplies}
              runtimes={arco.runtimes}
              provider={providerRoute.provider}
              primaryProvider={providerConfig.primary ?? providerRoute.provider}
              isFailover={providerRoute.isFailover}
              running={arco.agentRunning}
              showHeader={false}
              onAsk={arco.askAgent}
              onToggleSaved={arco.setAgentTurnSaved}
              workspace={agentWorkspace.workspace}
              onChooseWorkspace={agentWorkspace.chooseWorkspace}
            />
          ) : (
            <div className="agent-overlay-unavailable">
              <strong>{t('agent.askArco')}</strong>
              <p>{t('agent.connectFirst')}</p>
              <button type="button" onClick={() => void arcoBridge.focusMainWindow()}>{t('agent.openArco')}</button>
            </div>
          )}
        </div>
        {transcriptVisible && (
          <div className="agent-overlay-evidence-slot">
            <TranscriptPane
              key={arco.meeting?.summary.id ?? 'no-meeting'}
              meeting={arco.meeting}
              capture={arco.capture}
              loading={arco.loading}
              compact
              showHeader={false}
            />
          </div>
        )}
      </div>
    </section>
  )
}
