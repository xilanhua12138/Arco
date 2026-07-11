import { AudioWaveform, Check, ChevronLeft, ChevronRight, Command, RefreshCw, X } from 'lucide-react'
import { useState } from 'react'
import type { ProviderId, RuntimeStatus } from '../types'
import { createProviderConfig, type ProviderConfig } from '../lib/providerConfig'
import { DEFAULT_LISTENING_SHORTCUT, formatListeningShortcut, type ListeningShortcut } from '../lib/listeningShortcut'
import { ShortcutRecorder } from './ShortcutRecorder'
import './ProviderSetup.css'
import { useI18n } from '../i18n/i18n'

interface ProviderSetupProps {
  mode?: 'onboarding' | 'provider'
  runtimes: RuntimeStatus[]
  initialConfig?: ProviderConfig
  listeningShortcut?: ListeningShortcut
  onChangeListeningShortcut?: (shortcut: ListeningShortcut) => boolean | Promise<boolean>
  onRefresh?: () => Promise<RuntimeStatus[] | void> | RuntimeStatus[] | void
  onTest: (provider: ProviderId) => Promise<boolean>
  onComplete: (config: ProviderConfig) => void
  onCancel?: () => void
  onSkip?: () => void
}

type TestState = 'idle' | 'testing' | 'passed' | 'failed'

const providers: ProviderId[] = ['codex', 'claude']

const providerName = (provider: ProviderId) => provider === 'codex' ? 'Codex' : 'Claude'
const runtimeName = (provider: ProviderId) => provider === 'codex' ? 'Codex CLI' : 'Claude Code'

const legalSelection = (
  preferredPrimary: ProviderId | null,
  preferredSecondary: ProviderId | null,
  runtimes: readonly RuntimeStatus[],
) => {
  const available = (provider: ProviderId) => (
    runtimes.some((runtime) => runtime.provider === provider && runtime.available)
  )
  const primary = preferredPrimary && available(preferredPrimary)
    ? preferredPrimary
    : providers.find(available) ?? null
  const secondary = preferredSecondary && available(preferredSecondary) && preferredSecondary !== primary
    ? preferredSecondary
    : null
  return { primary, secondary }
}

export function ProviderSetup({
  mode = 'provider',
  runtimes,
  initialConfig,
  listeningShortcut = DEFAULT_LISTENING_SHORTCUT,
  onChangeListeningShortcut = () => true,
  onRefresh,
  onTest,
  onComplete,
  onCancel,
  onSkip,
}: ProviderSetupProps) {
  const { locale, setLocale, t } = useI18n()
  const editingExistingConfig = Boolean(initialConfig?.setupComplete && initialConfig.primary)
  const initialStep = editingExistingConfig ? 1 : 0
  const [step, setStep] = useState(initialStep)
  const [furthestStep, setFurthestStep] = useState(initialStep)
  const [selectedPrimary, setSelectedPrimary] = useState<ProviderId | null>(
    editingExistingConfig ? initialConfig?.primary ?? null : null,
  )
  const [secondary, setSecondary] = useState<ProviderId | null>(
    editingExistingConfig ? initialConfig?.secondary ?? null : null,
  )
  const [testState, setTestState] = useState<TestState>('idle')
  const [testedProvider, setTestedProvider] = useState<ProviderId | null>(null)
  const [refreshing, setRefreshing] = useState(false)
  const [configurationError, setConfigurationError] = useState<string | null>(null)
  const steps = [
    t('onboarding.step.welcome'),
    t('onboarding.step.providers'),
    t('onboarding.step.test'),
    t('onboarding.step.shortcut'),
    t('onboarding.step.ready'),
  ]

  const runtimeFor = (provider: ProviderId) => runtimes.find((runtime) => runtime.provider === provider)
  const currentSelection = legalSelection(selectedPrimary, secondary, runtimes)
  const primary = currentSelection.primary
  const effectiveSecondary = currentSelection.secondary
  const primaryAvailable = primary ? Boolean(runtimeFor(primary)?.available) : false
  const primaryTestPassed = testState === 'passed' && testedProvider === primary

  const moveTo = (nextStep: number) => {
    if (nextStep > furthestStep) return
    if (nextStep >= 3 && !primaryTestPassed) return
    setStep(nextStep)
  }

  const revealStep = (nextStep: number) => {
    setFurthestStep((current) => Math.max(current, nextStep))
    setStep(nextStep)
  }

  const changePrimary = (provider: ProviderId) => {
    if (!runtimeFor(provider)?.available) return
    setSelectedPrimary(provider)
    setSecondary((current) => current === provider ? null : current)
    setTestState('idle')
    setTestedProvider(null)
    setConfigurationError(null)
    setFurthestStep(1)
  }

  const changeSecondary = (provider: ProviderId | null) => {
    if (provider && (!runtimeFor(provider)?.available || provider === primary)) return
    setSecondary(provider)
    setConfigurationError(null)
    setFurthestStep((current) => Math.min(current, 2))
  }

  const testPrimary = async () => {
    if (!primary || !primaryAvailable || testState === 'testing') return
    const providerUnderTest = primary
    setTestState('testing')
    setTestedProvider(providerUnderTest)
    setConfigurationError(null)
    try {
      setTestState(await onTest(providerUnderTest) ? 'passed' : 'failed')
    } catch {
      setTestState('failed')
    }
  }

  const refreshInstallations = async () => {
    if (!onRefresh || refreshing) return
    setTestState('idle')
    setTestedProvider(null)
    setConfigurationError(null)
    setFurthestStep(1)
    setRefreshing(true)
    try {
      const refreshed = await onRefresh()
      const normalized = legalSelection(
        selectedPrimary,
        secondary,
        refreshed ?? runtimes,
      )
      setSelectedPrimary(normalized.primary)
      setSecondary(normalized.secondary)
    } catch {
      const normalized = legalSelection(selectedPrimary, secondary, runtimes)
      setSelectedPrimary(normalized.primary)
      setSecondary(normalized.secondary)
    } finally {
      setRefreshing(false)
    }
  }

  const finish = () => {
    if (!primaryTestPassed) {
      setStep(2)
      setFurthestStep(2)
      return
    }
    try {
      onComplete(createProviderConfig(primary, effectiveSecondary, runtimes))
    } catch {
      setConfigurationError(t('onboarding.configurationChanged'))
      setTestState('idle')
      setTestedProvider(null)
      setFurthestStep(1)
      setStep(1)
    }
  }

  return (
    <div className="provider-setup-backdrop">
      <section
        className="provider-setup"
        role="dialog"
        aria-modal="true"
        aria-labelledby="provider-setup-title"
      >
        <aside className="provider-setup-progress" aria-label={t('onboarding.progress')}>
          <div className="provider-setup-brand">
            <img src="/arco-icon.png" alt="" draggable={false} />
            Arco
          </div>
          <ol>
            {steps.map((label, index) => {
              const complete = index < step
              return (
                <li key={label}>
                  <button
                    type="button"
                    aria-label={label}
                    aria-current={index === step ? 'step' : undefined}
                    disabled={index > furthestStep}
                    onClick={() => moveTo(index)}
                  >
                    <span aria-hidden="true">{complete ? <Check size={13} /> : index + 1}</span>
                    {label}
                  </button>
                </li>
              )
            })}
          </ol>
        </aside>

        <div className="provider-setup-main">
          <header className="provider-setup-header">
            <h1 id="provider-setup-title">{mode === 'onboarding' ? t('onboarding.welcome') : t('onboarding.connect')}</h1>
            <div className="provider-setup-header-actions">
              <label className="provider-setup-language">
                <span className="sr-only">{t('settings.appLanguage')}</span>
                <select
                  aria-label={t('settings.appLanguage')}
                  value={locale}
                  onChange={(event) => setLocale(event.target.value as 'en' | 'zh-CN')}
                >
                  <option value="zh-CN">简体中文</option>
                  <option value="en">English</option>
                </select>
              </label>
              {onCancel && (
                <button type="button" className="provider-setup-cancel" onClick={onCancel} aria-label={t('onboarding.cancel')}>
                  <X size={18} aria-hidden="true" />
                </button>
              )}
            </div>
          </header>

          <div className="provider-setup-content" key={step}>
            {step === 0 && (
              <section aria-labelledby="provider-intro-heading" className="provider-setup-intro">
                <AudioWaveform size={34} strokeWidth={1.5} aria-hidden="true" />
                <h2 id="provider-intro-heading">{t('onboarding.stayInConversation')}</h2>
                <p>{t('onboarding.intro')}</p>
                <div className="provider-intro-receipt"><span>1</span> {t('onboarding.listen')} <span>2</span> {t('onboarding.ask')} <span>3</span> {t('onboarding.leaveWithSummary')}</div>
              </section>
            )}

            {step === 1 && (
              <section aria-labelledby="provider-choice-heading">
                <div className="provider-choice-heading-row">
                  <div>
                    <h2 id="provider-choice-heading">{t('onboarding.chooseProviders')}</h2>
                    <p className="provider-setup-lede">{t('onboarding.providersHelp')}</p>
                  </div>
                  {onRefresh && (
                    <button
                      type="button"
                      className="provider-refresh-button"
                      aria-label={t('onboarding.recheckInstallations')}
                      disabled={refreshing}
                      onClick={refreshInstallations}
                    >
                      <RefreshCw size={14} className={refreshing ? 'provider-test-spinning' : ''} aria-hidden="true" />
                      {refreshing ? t('onboarding.checking') : t('onboarding.recheck')}
                    </button>
                  )}
                </div>

                <div className="provider-installations" aria-label={t('onboarding.detectedTools')}>
                  {providers.map((provider) => {
                    const runtime = runtimeFor(provider)
                    const installed = Boolean(runtime?.available)
                    return (
                      <div key={provider} aria-label={t('onboarding.runtimeStatus', { runtime: runtimeName(provider) })}>
                        <span className={`provider-mark provider-mark-${provider}`} aria-hidden="true">
                          {provider === 'codex' ? 'C' : 'A'}
                        </span>
                        <span>
                          <strong>{runtimeName(provider)}</strong>
                          <small>{runtime?.version ?? t('common.notDetected')}</small>
                        </span>
                        <span className={`provider-availability ${installed ? 'provider-availability-ready' : ''}`}>
                          {installed ? t('common.installed') : t('common.missing')}
                        </span>
                      </div>
                    )
                  })}
                </div>

                <div className="provider-role-fields">
                  <fieldset>
                    <legend>{t('onboarding.primary')}</legend>
                    <div className="provider-choice-row">
                      {providers.map((provider) => (
                        <label key={provider} className={primary === provider ? 'provider-choice-selected' : ''}>
                          <input
                            type="radio"
                            name="primary-provider"
                            aria-label={t('onboarding.asPrimary', { provider: providerName(provider) })}
                            checked={primary === provider}
                            disabled={!runtimeFor(provider)?.available}
                            onChange={() => changePrimary(provider)}
                          />
                          <span>{providerName(provider)}</span>
                          {primary === provider && <Check size={14} aria-hidden="true" />}
                        </label>
                      ))}
                    </div>
                  </fieldset>

                  <fieldset>
                    <legend>{t('onboarding.secondary')} <span>{t('common.optional')}</span></legend>
                    <div className="provider-choice-row provider-choice-row-secondary">
                      <label className={effectiveSecondary === null ? 'provider-choice-selected' : ''}>
                        <input
                          type="radio"
                          name="secondary-provider"
                          aria-label={t('onboarding.noSecondary')}
                          checked={effectiveSecondary === null}
                          onChange={() => changeSecondary(null)}
                        />
                        <span>{t('common.none')}</span>
                        {effectiveSecondary === null && <Check size={14} aria-hidden="true" />}
                      </label>
                      {providers.map((provider) => (
                        <label key={provider} className={effectiveSecondary === provider ? 'provider-choice-selected' : ''}>
                          <input
                            type="radio"
                            name="secondary-provider"
                            aria-label={t('onboarding.asSecondary', { provider: providerName(provider) })}
                            checked={effectiveSecondary === provider}
                            disabled={!runtimeFor(provider)?.available || primary === provider}
                            onChange={() => changeSecondary(provider)}
                          />
                          <span>{providerName(provider)}</span>
                          {effectiveSecondary === provider && <Check size={14} aria-hidden="true" />}
                        </label>
                      ))}
                    </div>
                  </fieldset>
                </div>

                {!primaryAvailable && (
                  <p className="provider-setup-message" role="alert">{t('onboarding.installCli')}</p>
                )}
                {configurationError && <p className="provider-setup-message" role="alert">{configurationError}</p>}
              </section>
            )}

            {step === 2 && (
              <section aria-labelledby="provider-test-heading" className="provider-test">
                <h2 id="provider-test-heading">{t('onboarding.testConnection')}</h2>
                <p>{t('onboarding.testHelp', { provider: primary ? providerName(primary) : t('onboarding.primaryFallback') })}</p>
                <button
                  type="button"
                  className="provider-test-button"
                  disabled={!primaryAvailable || testState === 'testing'}
                  onClick={testPrimary}
                >
                  <RefreshCw size={16} className={testState === 'testing' ? 'provider-test-spinning' : ''} aria-hidden="true" />
                  {testState === 'testing' ? t('onboarding.testing') : t('onboarding.testProvider', { provider: primary ? providerName(primary) : t('onboarding.connection') })}
                </button>
                {primaryTestPassed && (
                  <p className="provider-test-result provider-test-result-success" role="status">
                    <Check size={15} aria-hidden="true" /> {t('onboarding.providerReady', { provider: testedProvider ? providerName(testedProvider) : t('onboarding.primaryProvider') })}
                  </p>
                )}
                {testState === 'failed' && (
                  <p className="provider-test-result provider-test-result-error" role="alert">
                    {t('onboarding.providerFailed', { provider: testedProvider ? providerName(testedProvider) : t('onboarding.theProvider') })}
                  </p>
                )}
              </section>
            )}

            {step === 3 && (
              <section aria-labelledby="provider-shortcut-heading" className="provider-shortcut">
                <Command size={30} strokeWidth={1.5} aria-hidden="true" />
                <h2 id="provider-shortcut-heading">{t('onboarding.startAnywhere')}</h2>
                <p>{t('onboarding.shortcutHelp')}</p>
                <ShortcutRecorder value={listeningShortcut} onChange={onChangeListeningShortcut} />
                <small>{t('onboarding.shortcutSettings')}</small>
              </section>
            )}

            {step === 4 && (
              <section aria-labelledby="provider-complete-heading" className="provider-complete">
                <span className="provider-complete-check" aria-hidden="true"><Check size={24} /></span>
                <h2 id="provider-complete-heading">{t('onboarding.youAreReady')}</h2>
                <dl>
                  <div><dt>{t('onboarding.primary')}</dt><dd>{primary ? providerName(primary) : t('common.notSet')}</dd></div>
                  <div><dt>{t('onboarding.secondary')}</dt><dd>{effectiveSecondary ? providerName(effectiveSecondary) : t('common.none')}</dd></div>
                  <div><dt>{t('onboarding.startListening')}</dt><dd>{listeningShortcut ? formatListeningShortcut(listeningShortcut) : t('shortcut.off')}</dd></div>
                </dl>
              </section>
            )}
          </div>

          <footer className="provider-setup-actions">
            <div>
            {mode === 'onboarding' && onSkip && (
              <button type="button" className="provider-setup-skip" onClick={onSkip}>{t('onboarding.skip')}</button>
            )}
            {step > 0 && (
              <button type="button" className="provider-setup-back" onClick={() => setStep((current) => current - 1)}>
                <ChevronLeft size={16} aria-hidden="true" /> {t('common.back')}
              </button>
            )}
            </div>
            {step < 4 ? (
              <button
                type="button"
                className="provider-setup-next"
                disabled={(step === 1 && !primaryAvailable) || (step === 2 && !primaryTestPassed)}
                onClick={() => revealStep(step + 1)}
              >
                {t('common.continue')} <ChevronRight size={16} aria-hidden="true" />
              </button>
            ) : (
              <button type="button" className="provider-setup-next" onClick={finish}>
                {mode === 'onboarding' ? t('onboarding.openArco') : t('onboarding.saveConfiguration')} <Check size={16} aria-hidden="true" />
              </button>
            )}
          </footer>
        </div>
      </section>
    </div>
  )
}
