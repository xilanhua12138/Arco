import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import { AgentOverlay } from './surfaces/AgentOverlay.tsx'
import { RecordingHud } from './surfaces/RecordingHud.tsx'
import { resolveSurface } from './surfaces/surfaceRoute.ts'
import { I18nProvider } from './i18n/i18n.ts'

const surface = resolveSurface(window.location.search)
document.documentElement.dataset.surface = surface
document.documentElement.dataset.runtime = '__TAURI_INTERNALS__' in window ? 'desktop' : 'browser'

const root = surface === 'hud'
  ? <RecordingHud />
  : surface === 'agent-overlay'
    ? <AgentOverlay />
    : <App />

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <I18nProvider>{root}</I18nProvider>
  </StrictMode>,
)
