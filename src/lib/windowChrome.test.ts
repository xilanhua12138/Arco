import { describe, expect, it } from 'vitest'
import appCss from '../App.css?raw'
import onboardingCss from '../components/Onboarding.css?raw'
import defaultCapabilityJson from '../../src-tauri/capabilities/default.json?raw'
import tauriConfigJson from '../../src-tauri/tauri.conf.json?raw'

describe('native window chrome geometry', () => {
  it('allows the webview drag regions to move the native window', () => {
    const defaultCapability = JSON.parse(defaultCapabilityJson) as {
      permissions: string[]
    }

    expect(defaultCapability.permissions).toContain('core:window:allow-start-dragging')
  })

  it('keeps the macOS traffic lights aligned with the sidebar content grid', () => {
    const tauriConfig = JSON.parse(tauriConfigJson) as {
      app: {
        windows: Array<{
          trafficLightPosition?: { x: number; y: number }
        }>
      }
    }

    expect(tauriConfig.app.windows[0]?.trafficLightPosition).toEqual({ x: 27, y: 26 })
    expect(appCss).toContain('--sidebar-titlebar-clearance: 44px;')
    expect(appCss).toMatch(
      /\.app-sidebar\s*\{[\s\S]*?padding:\s*var\(--sidebar-titlebar-clearance\) 12px 8px;/,
    )
    expect(onboardingCss).toMatch(
      /\.onboarding-landing-bar\s*\{[\s\S]*?min-height:\s*104px;[\s\S]*?align-items:\s*flex-start;[\s\S]*?padding:\s*64px 42px 0;/,
    )
    expect(onboardingCss).toMatch(
      /\.onboarding-landing-tools\s*\{[\s\S]*?position:\s*absolute;[\s\S]*?top:\s*20px;[\s\S]*?right:\s*42px;/,
    )
  })
})
