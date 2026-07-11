import { ChevronLeft, ChevronRight } from 'lucide-react'
import { useState } from 'react'
import {
  DEFAULT_SUMMARY_PROMPT,
  DEFAULT_TITLE_PROMPT,
  MAX_GENERATION_PROMPT_CHARS,
  type GenerationSettings,
} from '../lib/generationSettings'
import './MeetingOutputSettings.css'
import { useI18n } from '../i18n/i18n'

type RuleKey = keyof GenerationSettings

interface MeetingOutputSettingsProps {
  settings: GenerationSettings
  onSave: (settings: GenerationSettings) => void
}

export function MeetingOutputSettings({ settings, onSave }: MeetingOutputSettingsProps) {
  const { t } = useI18n()
  const [detail, setDetail] = useState<RuleKey | null>(null)
  const [draftEnabled, setDraftEnabled] = useState(true)
  const [useCustomPrompt, setUseCustomPrompt] = useState(false)
  const [draftPrompt, setDraftPrompt] = useState('')
  const ruleCopy: Record<RuleKey, {
    title: string
    description: string
    automaticLabel: string
    defaultPrompt: string
  }> = {
    title: {
      title: t('output.automaticTitle'),
      description: t('output.automaticTitleDescription'),
      automaticLabel: t('output.generateAutomatically'),
      defaultPrompt: DEFAULT_TITLE_PROMPT,
    },
    summary: {
      title: t('output.summary'),
      description: t('output.summaryDescription'),
      automaticLabel: t('output.createAutomatically'),
      defaultPrompt: DEFAULT_SUMMARY_PROMPT,
    },
  }
  const ruleStatus = (rule: GenerationSettings[RuleKey]) => {
    if (!rule.enabled) return t('common.off')
    return rule.promptOverride ? t('output.onCustom') : t('output.onDefault')
  }

  const openDetail = (key: RuleKey) => {
    const rule = settings[key]
    setDetail(key)
    setDraftEnabled(rule.enabled)
    setUseCustomPrompt(Boolean(rule.promptOverride))
    setDraftPrompt(rule.promptOverride ?? ruleCopy[key].defaultPrompt)
  }

  const cancel = () => setDetail(null)

  if (!detail) {
    return (
      <div className="meeting-output-list" aria-label={t('output.rules')}>
        {(Object.keys(ruleCopy) as RuleKey[]).map((key) => {
          const copy = ruleCopy[key]
          return (
            <button type="button" className="meeting-output-row" key={key} onClick={() => openDetail(key)}>
              <span className="meeting-output-row-copy">
                <strong>{copy.title}</strong>
                <small>{copy.description}</small>
              </span>
              <span className="meeting-output-row-state">{ruleStatus(settings[key])}</span>
              <ChevronRight size={15} aria-hidden="true" />
            </button>
          )
        })}
      </div>
    )
  }

  const copy = ruleCopy[detail]
  const promptIsEmpty = useCustomPrompt && !draftPrompt.trim()

  const save = () => {
    if (promptIsEmpty) return
    onSave({
      ...settings,
      [detail]: {
        enabled: draftEnabled,
        promptOverride: useCustomPrompt ? draftPrompt.trim() : null,
      },
    })
    setDetail(null)
  }

  return (
    <section className="meeting-output-detail" role="region" aria-label={t('output.settingsAria', { title: copy.title })}>
      <button type="button" className="meeting-output-back" onClick={cancel} aria-label={t('output.back')}>
        <ChevronLeft size={14} aria-hidden="true" />
        {t('settings.output')}
      </button>

      <header className="meeting-output-detail-heading">
        <h3>{copy.title}</h3>
        <p>{copy.description}</p>
      </header>

      <div className="meeting-output-controls">
        <label className="meeting-output-control-row">
          <span>
            <strong>{copy.automaticLabel}</strong>
            <small>{detail === 'title' ? t('output.titleDetail') : t('output.summaryDetail')}</small>
          </span>
          <input
            type="checkbox"
            role="switch"
            aria-label={copy.automaticLabel}
            checked={draftEnabled}
            onChange={(event) => setDraftEnabled(event.target.checked)}
          />
        </label>

        {draftEnabled && (
          <>
            <label className="meeting-output-control-row">
              <span>
                <strong>{t('output.customPrompt')}</strong>
                <small>{useCustomPrompt ? t('output.customPromptReplacement') : t('output.customPromptDefault')}</small>
              </span>
              <input
                type="checkbox"
                role="switch"
                aria-label={t('output.customPrompt')}
                checked={useCustomPrompt}
                onChange={(event) => {
                  const enabled = event.target.checked
                  setUseCustomPrompt(enabled)
                  if (enabled && !draftPrompt) setDraftPrompt(copy.defaultPrompt)
                }}
              />
            </label>

            {useCustomPrompt ? (
              <div className="meeting-output-prompt-field">
                <label htmlFor={`meeting-output-prompt-${detail}`}>{t('output.prompt')}</label>
                <textarea
                  id={`meeting-output-prompt-${detail}`}
                  aria-label={t('output.prompt')}
                  value={draftPrompt}
                  onChange={(event) => setDraftPrompt(event.target.value)}
                  maxLength={MAX_GENERATION_PROMPT_CHARS}
                  rows={7}
                  spellCheck
                />
                <div className="meeting-output-prompt-meta">
                  <small>{promptIsEmpty ? t('output.promptEmpty') : t('output.promptTranscript')}</small>
                  <button
                    type="button"
                    onClick={() => {
                      setUseCustomPrompt(false)
                      setDraftPrompt(copy.defaultPrompt)
                    }}
                  >
                    {t('output.resetDefault')}
                  </button>
                </div>
              </div>
            ) : (
              <details className="meeting-output-default-prompt">
                <summary>{t('output.viewDefaultPrompt')}</summary>
                <p>{copy.defaultPrompt}</p>
              </details>
            )}
          </>
        )}
      </div>

      <footer className="meeting-output-actions">
        <button type="button" className="meeting-output-cancel" onClick={cancel}>{t('common.cancel')}</button>
        <button type="button" className="meeting-output-save" onClick={save} disabled={promptIsEmpty}>{t('common.saveChanges')}</button>
      </footer>
    </section>
  )
}
