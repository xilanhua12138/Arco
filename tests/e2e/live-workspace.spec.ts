import { expect, test, type Page } from '@playwright/test'

const configuredProviders = JSON.stringify({
  setupComplete: true,
  primary: 'codex',
  secondary: 'claude',
})

async function gotoConfigured(page: Page, url = '/') {
  await page.addInitScript(({ value }) => {
    window.localStorage.setItem('arco.providerConfig', value)
    if (!window.sessionStorage.getItem('arco.e2eLocaleSeeded')) {
      window.localStorage.setItem('arco.locale', 'en')
      window.sessionStorage.setItem('arco.e2eLocaleSeeded', 'true')
    }
  }, { value: configuredProviders })
  await page.goto(url)
}

test('recording HUD is a native-sized global control island, not another app page', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 720 })
  await page.addInitScript(() => {
    window.localStorage.setItem('arco.demoCapture', JSON.stringify({
      phase: 'recording',
      activeMeetingId: 'demo-live',
      startedAt: new Date(Date.now() - 128_000).toISOString(),
      message: null,
    }))
  })
  await page.goto('/?surface=hud&demo=1')

  const hud = page.getByRole('region', { name: 'Arco recording controls' })
  await expect(hud).toBeVisible()
  await expect(page.getByRole('button', { name: 'Stop recording' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Ask Arco' })).toBeVisible()
  await expect(page.locator('.app-sidebar')).toHaveCount(0)
  await expect(page.locator('.transcript-surface')).toHaveCount(0)

  const box = await hud.boundingBox()
  expect(box).not.toBeNull()
  expect(Math.round(box!.width)).toBe(368)
  expect(Math.round(box!.height)).toBe(56)
  expect(Math.round(720 - box!.y - box!.height)).toBe(24)
  await page.screenshot({ path: 'test-results/arco-recording-hud.png', fullPage: true })

  await page.getByRole('button', { name: 'Stop recording' }).click()
  await expect(page.getByText('Saved')).toBeVisible()
})

test('Agent overlay is a focused always-on-top conversation surface', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 720 })
  await page.addInitScript(() => {
    window.localStorage.setItem('arco.providerConfig', JSON.stringify({
      setupComplete: true,
      primary: 'codex',
      secondary: 'claude',
    }))
    window.localStorage.setItem('arco.demoCapture', JSON.stringify({
      phase: 'recording',
      activeMeetingId: 'demo-live',
      startedAt: new Date(Date.now() - 128_000).toISOString(),
      message: null,
    }))
    window.localStorage.removeItem('arco.demoAgentTurns')
  })
  await page.goto('/?surface=agent-overlay&demo=1')

  const overlay = page.getByRole('dialog', { name: 'Ask Arco' })
  await expect(overlay).toBeVisible()
  await expect(page.getByText('Live', { exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Answer what was asked' })).toBeVisible()
  await expect(page.getByRole('textbox', { name: 'Ask the agent about this meeting' })).toBeVisible()
  await expect(page.locator('.app-sidebar')).toHaveCount(0)
  await expect(page.getByRole('complementary', { name: 'Meeting transcript' })).toBeVisible()
  await expect(page.getByText(/It should know enough about my work/)).toBeVisible()

  const [agentHeadingBox, quickActionsBox, composerBox] = await Promise.all([
    overlay.getByRole('heading', { name: 'Ask Arco' }).boundingBox(),
    overlay.locator('.quick-action-list').boundingBox(),
    overlay.locator('.ask-composer').boundingBox(),
  ])
  expect(agentHeadingBox).not.toBeNull()
  expect(quickActionsBox).not.toBeNull()
  expect(composerBox).not.toBeNull()
  expect(Math.abs(agentHeadingBox!.x - quickActionsBox!.x)).toBeLessThanOrEqual(1)
  expect(Math.abs(composerBox!.x - quickActionsBox!.x)).toBeLessThanOrEqual(1)
  expect(Math.abs(
    composerBox!.x + composerBox!.width - (quickActionsBox!.x + quickActionsBox!.width),
  )).toBeLessThanOrEqual(1)

  const box = await overlay.boundingBox()
  expect(box).not.toBeNull()
  expect(Math.round(box!.width)).toBe(720)
  expect(Math.round(box!.height)).toBe(560)
  expect(Math.round(box!.x)).toBe(540)
  expect(Math.round(box!.y)).toBe(20)
  await page.screenshot({ path: 'test-results/arco-agent-overlay.png', fullPage: true })

  await page.getByRole('button', { name: 'Hide transcript' }).click()
  await expect(page.getByRole('complementary', { name: 'Meeting transcript' })).toHaveCount(0)
  await expect(overlay).toHaveCSS('width', '432px')
  await expect(page.getByRole('button', { name: 'Show transcript' })).toBeVisible()
  await page.screenshot({ path: 'test-results/arco-agent-overlay-collapsed.png', fullPage: true })

  await page.getByRole('button', { name: 'Show transcript' }).click()
  await expect(page.getByRole('complementary', { name: 'Meeting transcript' })).toBeVisible()
  await expect(overlay).toHaveCSS('width', '720px')
})

test('global utility surfaces remain light when system appearance is dark', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 720 })
  await page.emulateMedia({ colorScheme: 'dark' })
  await page.addInitScript(() => {
    window.localStorage.setItem('arco.providerConfig', JSON.stringify({
      setupComplete: true,
      primary: 'codex',
      secondary: 'claude',
    }))
    window.localStorage.setItem('arco.demoCapture', JSON.stringify({
      phase: 'recording',
      activeMeetingId: 'demo-live',
      startedAt: new Date(Date.now() - 128_000).toISOString(),
      message: null,
    }))
    window.localStorage.removeItem('arco.demoAgentTurns')
  })

  await page.goto('/?surface=hud&demo=1')
  await expect(page.locator('html')).toHaveCSS('color-scheme', 'light')
  await expect(page.getByText('Recording')).toHaveCSS('color', 'rgb(17, 17, 17)')
  await expect(page.getByRole('button', { name: 'Stop recording' })).toHaveCSS('color', 'rgb(255, 255, 255)')
  await page.screenshot({ path: 'test-results/arco-recording-hud-light-forced.png', fullPage: true })

  await page.goto('/?surface=agent-overlay&demo=1')
  await expect(page.locator('html')).toHaveCSS('color-scheme', 'light')
  await expect(page.getByRole('heading', { name: 'Ask Arco' })).toHaveCSS('color', 'rgb(17, 17, 17)')
  await expect(page.getByRole('button', { name: 'Answer what was asked' })).toBeVisible()
  await expect(page.getByRole('complementary', { name: 'Meeting transcript' })).toBeVisible()
  await page.screenshot({ path: 'test-results/arco-agent-overlay-light-forced.png', fullPage: true })
})

test('first launch reaches a real Deepgram audio check and starts the first meeting', async ({ page }) => {
  await page.setViewportSize({ width: 1240, height: 820 })
  await page.addInitScript(() => window.localStorage.setItem('arco.locale', 'en'))
  await page.goto('/?demo=empty')

  const landing = page.getByRole('main', { name: 'Stay in the conversation' })
  const setupBrandArtwork = page.locator('.onboarding-brand img')
  await expect(landing).toBeVisible()
  await expect(landing.locator('.onboarding-landing-bar')).toHaveAttribute('data-tauri-drag-region', 'true')
  await expect(page.getByRole('navigation', { name: 'Main navigation' })).toHaveCount(0)
  await expect(landing.getByRole('heading', { name: 'Stay in the conversation' })).toHaveCSS('font-family', /Avenir Next/)
  await expect(setupBrandArtwork).toHaveCSS('background-color', 'rgba(0, 0, 0, 0)')
  await expect(setupBrandArtwork).toHaveCSS('box-shadow', 'none')
  await expect(landing.getByText('About 2 minutes')).toBeVisible()
  await page.screenshot({ path: 'test-results/arco-onboarding-welcome.png', fullPage: true, animations: 'disabled' })

  await landing.getByRole('button', { name: 'Continue' }).click()
  const setup = page.locator('.onboarding-wizard')
  await expect(setup.getByRole('heading', { name: 'Your meeting Agent' })).toBeVisible()
  await expect(setup.locator('.onboarding-header')).toHaveAttribute('data-tauri-drag-region', 'true')
  const testCodexButton = setup.getByRole('button', { name: 'Test Codex' })
  const codexReadyStatus = setup.getByText('Codex is ready.')
  await testCodexButton.click()
  await expect(codexReadyStatus).toBeVisible()
  const [testButtonBox, readyStatusBox] = await Promise.all([
    testCodexButton.boundingBox(),
    codexReadyStatus.boundingBox(),
  ])
  expect(testButtonBox).not.toBeNull()
  expect(readyStatusBox).not.toBeNull()
  const centerDelta = Math.abs(
    testButtonBox!.y + testButtonBox!.height / 2
      - (readyStatusBox!.y + readyStatusBox!.height / 2),
  )
  expect(centerDelta).toBeLessThanOrEqual(1)
  await setup.getByRole('button', { name: 'Continue' }).click()

  await expect(setup.getByRole('heading', { name: 'Choose transcription' })).toBeVisible()
  await setup.getByLabel('Deepgram API key').fill('dg_live_abcdefghijklmnopqrstuvwxyz')
  await setup.getByRole('button', { name: 'Verify & save' }).click()
  await expect(setup.getByText('Deepgram is ready.')).toBeVisible()
  await page.screenshot({ path: 'test-results/arco-onboarding-transcription.png', fullPage: true, animations: 'disabled' })
  await setup.getByRole('button', { name: 'Continue' }).click()

  await expect(setup.getByRole('heading', { name: 'Check your audio' })).toBeVisible()
  await expect(setup.getByRole('radiogroup', { name: 'Meeting type' })).toHaveCount(0)
  await setup.getByRole('button', { name: 'Check system audio' }).click()
  await expect(setup.getByText('System audio is ready')).toBeVisible()
  await expect(setup.getByRole('button', { name: 'Continue' })).toBeDisabled()
  await setup.getByRole('button', { name: 'Check microphone' }).click()
  await expect(setup.getByText('Microphone is ready')).toBeVisible()
  await expect(setup.getByRole('status')).toHaveText('Audio is ready. You can continue.')
  await setup.getByRole('button', { name: 'Continue' }).click()

  await expect(setup.getByRole('heading', { name: 'Start from anywhere' })).toBeVisible()
  await setup.getByRole('button', { name: 'Continue' }).click()
  await expect(setup.getByRole('button', { name: 'First meeting' })).toHaveAttribute('aria-current', 'step')
  await page.screenshot({ path: 'test-results/arco-onboarding-ready.png', fullPage: true, animations: 'disabled' })
  await setup.getByRole('button', { name: 'Start listening' }).click()

  await expect(setup).toHaveCount(0)
  const agent = page.getByRole('main', { name: 'Ask Arco' })
  await expect(agent).toBeVisible()
  await expect(page.getByRole('complementary', { name: 'Meeting transcript' })).toBeVisible()
  await expect(page.getByRole('button', { name: /Open Agent|Close Agent/i })).toHaveCount(0)
  await expect(agent.getByLabel('Current provider')).toHaveCount(0)
  await expect(agent.getByRole('combobox', { name: 'Agent provider' })).toHaveCount(0)
})

test('first launch can choose transcript-only on-device setup without a cloud key', async ({ page }) => {
  await page.setViewportSize({ width: 1024, height: 720 })
  await page.addInitScript(() => window.localStorage.setItem('arco.locale', 'en'))
  await page.goto('/?demo=empty')
  const landing = page.getByRole('main', { name: 'Stay in the conversation' })

  await landing.getByRole('button', { name: 'Continue' }).click()
  const setup = page.locator('.onboarding-wizard')
  await setup.getByRole('radio', { name: 'Continue without an Agent' }).click()
  await setup.getByRole('button', { name: 'Continue' }).click()
  await setup.getByRole('radio', { name: 'On this Mac' }).click()
  await setup.getByRole('button', { name: 'Download speech model' }).click()
  await expect(setup.getByRole('button', { name: 'Download speaker model' })).toBeEnabled()
  await setup.getByRole('button', { name: 'Download speaker model' }).click()
  await expect(setup.getByText('Ready on this Mac')).toHaveCount(2)
  await setup.getByRole('button', { name: 'Continue' }).click()
  await setup.getByRole('button', { name: 'Check system audio' }).click()
  await expect(setup.getByText('System audio is ready')).toBeVisible()
  await setup.getByRole('button', { name: 'Check microphone' }).click()
  await expect(setup.getByText('Microphone is ready')).toBeVisible()
  await setup.getByRole('button', { name: 'Continue' }).click()
  await setup.getByRole('button', { name: 'Continue' }).click()
  await setup.getByRole('button', { name: 'Open Arco' }).click()

  await expect(setup).toHaveCount(0)
  await expect(page.getByRole('region', { name: 'Start listening' })).toBeVisible()
  const persisted = await page.evaluate(() => ({
    provider: window.localStorage.getItem('arco.providerConfig'),
    transcription: window.localStorage.getItem('arco.transcriptionConfig'),
    audioMode: window.localStorage.getItem('arco.audioMode'),
  }))
  expect(persisted.provider).toContain('"setupComplete":false')
  expect(persisted.transcription).toContain('"provider":"local"')
  expect(persisted.audioMode).toBe('both')
  const widths = await page.evaluate(() => ({ viewport: window.innerWidth, page: document.documentElement.scrollWidth }))
  expect(widths.page).toBeLessThanOrEqual(widths.viewport)
})

test('onboarding resumes at audio check after an app reload and keeps downloaded model choices', async ({ page }) => {
  await page.setViewportSize({ width: 1024, height: 720 })
  await page.addInitScript(() => window.localStorage.setItem('arco.locale', 'en'))
  await page.goto('/?demo=empty')

  await page.getByRole('main', { name: 'Stay in the conversation' }).getByRole('button', { name: 'Continue' }).click()
  const setup = page.locator('.onboarding-wizard')
  await setup.getByRole('radio', { name: 'Continue without an Agent' }).click()
  await setup.getByRole('button', { name: 'Continue' }).click()
  await setup.getByRole('radio', { name: 'On this Mac' }).click()
  await setup.getByRole('combobox', { name: 'Speech recognition model' }).selectOption('whisper-base')
  await setup.getByRole('button', { name: 'Download speech model' }).click()
  await setup.getByRole('button', { name: 'Download speaker model' }).click()
  await expect(setup.getByText('Ready on this Mac')).toHaveCount(2)
  await setup.getByRole('button', { name: 'Continue' }).click()
  await expect(setup.getByRole('heading', { name: 'Check your audio' })).toBeVisible()

  const draftBeforeReload = await page.evaluate(() => window.localStorage.getItem('arco.onboarding.draft.v1'))
  expect(draftBeforeReload).toContain('"step":3')
  expect(draftBeforeReload).toContain('"model":"whisper-base"')
  await page.reload()

  await expect(page.getByRole('main', { name: 'Stay in the conversation' })).toHaveCount(0)
  await expect(page.getByRole('heading', { name: 'Check your audio' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Audio check' })).toHaveAttribute('aria-current', 'step')
  await expect(page.getByRole('button', { name: 'Agent' })).toBeEnabled()
  await expect(page.getByRole('button', { name: 'Transcription' })).toBeEnabled()
  await expect(page.getByRole('button', { name: 'Shortcut' })).toBeDisabled()

  await page.getByRole('button', { name: 'Transcription' }).click()
  await expect(page.getByRole('combobox', { name: 'Speech recognition model' })).toHaveValue('whisper-base')
  await expect(page.getByText('Ready on this Mac')).toHaveCount(2)
})

test('an idle Current keeps one focused launch surface until listening begins', async ({ page }) => {
  await page.setViewportSize({ width: 1240, height: 820 })
  await gotoConfigured(page, '/?demo=empty')

  const idle = page.getByRole('region', { name: 'Start listening' })
  await expect(idle.getByRole('heading', { name: 'Start listening' })).toBeVisible()
  await expect(idle.getByText('Start a new meeting when you are ready. Its live transcript and Agent will appear here.')).toHaveCount(0)
  await expect(idle.getByRole('region', { name: 'On this Mac' })).toContainText('0')
  await expect(idle.getByRole('region', { name: 'Shortcuts' }).locator('kbd')).toHaveText(['⌘', '⇧', 'Space', '⌘', 'K'])
  await expect(page.getByRole('button', { name: 'Start listening' })).toHaveCount(1)
  await expect(page.getByRole('heading', { name: 'Transcript' })).toHaveCount(0)
  await expect(page.getByRole('main', { name: 'Ask Arco' })).toHaveCount(0)

  const listeningTime = idle.locator('.current-idle-stat').filter({ hasText: 'Listening time' }).locator('dd')
  await listeningTime.evaluate((element) => { element.textContent = '7 小时 13 分钟' })
  await expect(listeningTime).toHaveCSS('text-overflow', 'clip')
  await expect(listeningTime).toHaveCSS('white-space', 'normal')
  const listeningTimeBox = await listeningTime.evaluate((element) => ({
    clientWidth: element.clientWidth,
    scrollWidth: element.scrollWidth,
  }))
  expect(listeningTimeBox.scrollWidth).toBeLessThanOrEqual(listeningTimeBox.clientWidth)
  await page.screenshot({ path: 'test-results/arco-first-meeting-empty.png', fullPage: true, animations: 'disabled' })

  await page.setViewportSize({ width: 1024, height: 700 })
  const idleViewport = await page.evaluate(() => ({
    innerWidth: window.innerWidth,
    documentWidth: document.documentElement.scrollWidth,
    bodyWidth: document.body.scrollWidth,
  }))
  expect(idleViewport.documentWidth).toBeLessThanOrEqual(idleViewport.innerWidth)
  expect(idleViewport.bodyWidth).toBeLessThanOrEqual(idleViewport.innerWidth)

  await idle.getByRole('button', { name: 'Start listening' }).click()
  await expect(page.getByRole('complementary', { name: 'Meeting transcript' })).toBeVisible()
  const agent = page.getByRole('main', { name: 'Ask Arco' })
  await expect(agent).toBeVisible()
  await expect(agent.getByRole('textbox', { name: 'Ask the agent about this meeting' })).toBeVisible()
})

test('the listening shortcut can be changed from Settings and updates the idle shortcut receipt', async ({ page }) => {
  await gotoConfigured(page, '/?demo=empty')
  await page.getByRole('button', { name: 'Open settings' }).click()
  const settings = page.getByRole('dialog', { name: 'General' })
  const recorder = settings.getByRole('button', { name: 'Change listening shortcut' })
  await recorder.click()
  await page.keyboard.press('Meta+Alt+L')
  await expect(recorder).toContainText('⌘ ⌥ L')
  await settings.getByRole('button', { name: 'Close settings' }).click()
  await expect(page.getByRole('region', { name: 'Shortcuts' }).locator('kbd')).toHaveText(['⌘', '⌥', 'L', '⌘', 'K'])
})

test('Current keeps transcript primary with Agent visible at its right', async ({ page }) => {
  await page.setViewportSize({ width: 1240, height: 820 })
  await gotoConfigured(page)

  const dragSpace = await page.locator('.page-drag-space').boundingBox()
  const pageHeader = await page.locator('.page-header').boundingBox()
  const sidebarBrand = await page.locator('.sidebar-brand').boundingBox()
  expect(dragSpace).not.toBeNull()
  expect(pageHeader).not.toBeNull()
  expect(sidebarBrand).not.toBeNull()
  expect(Math.round(dragSpace!.height)).toBe(32)
  expect(Math.round(pageHeader!.y)).toBe(41)
  // The sidebar clears the native macOS traffic lights; the page header only
  // needs the standard draggable titlebar clearance.
  expect(Math.round(sidebarBrand!.y)).toBe(53)
  await expect(page.locator('body')).toHaveCSS('font-family', /Avenir Next/)
  await expect(page.getByRole('heading', { level: 1, name: 'Product direction · weekly working session' })).toHaveCSS('font-family', /Avenir Next/)
  await expect(page.locator('.utterance time').first()).toHaveCSS('font-family', /SFMono/)
  await expect(page.locator('.brand-mark')).toHaveCSS('background-color', 'rgba(0, 0, 0, 0)')
  await expect(page.locator('.brand-mark')).toHaveCSS('box-shadow', 'none')

  const agent = page.getByRole('main', { name: 'Ask Arco' })
  const transcript = page.getByRole('complementary', { name: 'Meeting transcript' })
  await expect(page.getByRole('heading', { level: 1, name: 'Product direction · weekly working session' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Open current meeting' })).toHaveAttribute('aria-current', 'page')
  await expect(agent).toBeVisible()
  await expect(agent.getByRole('heading', { name: 'Ask Arco' })).toHaveCSS('font-size', '16px')
  await expect(transcript).toBeVisible()
  await expect(transcript.getByRole('heading', { name: 'Transcript' })).toHaveCSS('font-size', '16px')
  await expect(page.getByRole('button', { name: /Open Agent|Close Agent/i })).toHaveCount(0)
  await expect(page.getByRole('dialog', { name: 'Ask Arco' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Stop listening' })).toHaveCount(1)
  await expect(page.getByLabel('Remote 1, system audio').first()).toBeVisible()
  await expect(page.getByLabel('In room 2, room mic').first()).toBeVisible()
  await expect(transcript.locator('.utterance')).toHaveCount(12)
  await expect(transcript.locator('.utterance .speaker-label')).toHaveCount(12)
  await expect(transcript.locator('.utterance .speaker-avatar')).toHaveCount(12)
  const firstSpeakerAvatar = transcript.locator('.speaker-avatar').first()
  const avatarSurface = await firstSpeakerAvatar.evaluate((element) => {
    const style = window.getComputedStyle(element)
    return {
      tagName: element.tagName.toLocaleLowerCase(),
      backgroundColor: style.backgroundColor,
      backgroundImage: style.backgroundImage,
    }
  })
  const speakerCenterDelta = await firstSpeakerAvatar.evaluate((avatar) => {
    const name = avatar.parentElement?.querySelector('strong')
    if (!name) return null
    const avatarBox = avatar.getBoundingClientRect()
    const nameBox = name.getBoundingClientRect()
    return Math.abs((avatarBox.y + avatarBox.height / 2) - (nameBox.y + nameBox.height / 2))
  })
  expect(avatarSurface).toEqual({
    tagName: 'svg',
    backgroundColor: 'rgba(0, 0, 0, 0)',
    backgroundImage: 'none',
  })
  expect(speakerCenterDelta).not.toBeNull()
  expect(speakerCenterDelta!).toBeLessThanOrEqual(1)
  await expect(page.getByText('You', { exact: true })).toHaveCount(0)
  await page.waitForTimeout(500)
  await expect(page.getByRole('button', { name: 'Jump to live' })).toHaveCount(0)

  await page.screenshot({ path: 'test-results/arco-final-current-light.png', fullPage: true })

  await page.getByRole('button', { name: 'Meeting details' }).click()
  const details = page.getByRole('dialog', { name: 'Meeting details' })
  await expect(details).toBeVisible()
  await expect(details.getByLabel('System audio speakers: Remote 1, Remote 2')).toContainText('Remote 1, Remote 2')
  await expect(details.getByLabel('Room microphone speakers: In room 1, In room 2')).toContainText('In room 1, In room 2')
  await page.screenshot({ path: 'test-results/arco-meeting-details-popover.png', fullPage: true })
  await page.keyboard.press('Escape')
  await expect(details).toHaveCount(0)
})

test('a meeting title is edited in place, persists, and updates History', async ({ page }) => {
  await page.setViewportSize({ width: 1240, height: 820 })
  await gotoConfigured(page)

  await page.getByRole('button', { name: 'Rename meeting' }).click()
  const title = page.getByRole('textbox', { name: 'Meeting title' })
  await expect(title).toBeFocused()
  await expect(title).toHaveValue('Product direction · weekly working session')
  await page.screenshot({ path: 'test-results/arco-meeting-title-editing.png', fullPage: true })
  await title.fill('Decision review')
  await title.press('Enter')

  await expect(page.getByRole('heading', { level: 1, name: 'Decision review' })).toBeVisible()
  await page.getByRole('button', { name: 'Open meeting history' }).click()
  await expect(page.getByRole('button', { name: /Decision review/ })).toBeVisible()

  await page.reload()
  await expect(page.getByRole('heading', { level: 1, name: 'Decision review' })).toBeVisible()

  await page.getByRole('button', { name: 'Rename meeting' }).click()
  await page.getByRole('textbox', { name: 'Meeting title' }).fill('')
  await page.getByRole('textbox', { name: 'Meeting title' }).press('Enter')
  await expect(page.getByRole('heading', { level: 1, name: 'Untitled meeting' })).toBeVisible()
})

test('Current exposes native glass through chrome while keeping both reading surfaces stable', async ({ page }) => {
  await page.setViewportSize({ width: 1240, height: 820 })
  await gotoConfigured(page)

  const material = await page.locator('.app-shell').evaluate((shell) => {
    const sidebar = shell.querySelector<HTMLElement>('.app-sidebar')
    const activeNav = shell.querySelector<HTMLElement>('.nav-item-active')
    const captureCard = shell.querySelector<HTMLElement>('.capture-card')
    const pageStage = shell.querySelector<HTMLElement>('.page-stage')
    const workspace = shell.querySelector<HTMLElement>('.current-workspace')
    const transcript = shell.querySelector<HTMLElement>('.transcript-surface')
    const agent = shell.querySelector<HTMLElement>('.agent-workspace')
    if (!sidebar || !activeNav || !captureCard || !pageStage || !workspace || !transcript || !agent) {
      throw new Error('Current material surfaces are incomplete')
    }
    const shellRect = shell.getBoundingClientRect()
    const stageRect = pageStage.getBoundingClientRect()
    const stageStyle = getComputedStyle(pageStage)

    return {
      reducedTransparency: window.matchMedia('(prefers-reduced-transparency: reduce)').matches,
      shellBackground: getComputedStyle(shell).backgroundColor,
      sidebarBackground: getComputedStyle(sidebar).backgroundColor,
      sidebarBackdrop: getComputedStyle(sidebar).backdropFilter,
      activeNavBackdrop: getComputedStyle(activeNav).backdropFilter,
      captureBackdrop: getComputedStyle(captureCard).backdropFilter,
      pageStageBackground: getComputedStyle(pageStage).backgroundColor,
      pageStageTopRightRadius: stageStyle.borderTopRightRadius,
      pageStageBottomRightRadius: stageStyle.borderBottomRightRadius,
      pageStageBoxShadow: stageStyle.boxShadow,
      pageStageRightGap: shellRect.right - stageRect.right,
      workspaceBackground: getComputedStyle(workspace).backgroundColor,
      workspaceBackdrop: getComputedStyle(workspace).backdropFilter,
      transcriptBackground: getComputedStyle(transcript).backgroundColor,
      agentBackground: getComputedStyle(agent).backgroundColor,
    }
  })
  const alpha = (color: string) => {
    const match = color.match(/rgba?\([^,]+,[^,]+,[^,]+(?:,\s*([\d.]+))?\)/)
    return match?.[1] === undefined ? 1 : Number(match[1])
  }

  if (material.reducedTransparency) {
    expect(alpha(material.shellBackground)).toBeGreaterThan(0.7)
    expect(material.sidebarBackdrop).toBe('none')
    expect(material.workspaceBackdrop).toBe('none')
  } else {
    expect(alpha(material.shellBackground)).toBeLessThan(0.35)
    expect(alpha(material.sidebarBackground)).toBeLessThan(0.45)
    expect(material.sidebarBackdrop).toContain('blur(')
    expect(material.activeNavBackdrop).toContain('blur(')
    expect(material.captureBackdrop).toContain('blur(')
    expect(alpha(material.pageStageBackground)).toBeLessThan(0.12)
    expect(alpha(material.workspaceBackground)).toBeLessThan(0.24)
    expect(material.workspaceBackdrop).toContain('blur(')
  }
  expect(Number.parseFloat(material.pageStageTopRightRadius)).toBeGreaterThanOrEqual(16)
  expect(Number.parseFloat(material.pageStageBottomRightRadius)).toBeGreaterThanOrEqual(16)
  expect(material.pageStageRightGap).toBeGreaterThanOrEqual(7)
  expect(material.pageStageBoxShadow).toContain('inset')
  expect(alpha(material.transcriptBackground)).toBeGreaterThan(0.9)
  expect(alpha(material.agentBackground)).toBeGreaterThan(0.9)
})

test('History is searchable and opens a meeting as History review', async ({ page }) => {
  await gotoConfigured(page)
  await page.getByRole('button', { name: 'Open meeting history' }).click()

  await expect(page.getByRole('heading', { level: 1, name: 'History' })).toBeVisible()
  const historyStageMaterial = await page.locator('.page-stage').evaluate((stage) => {
    const stageStyle = getComputedStyle(stage)
    const ambientStyle = getComputedStyle(stage, '::before')
    const matrixStyle = getComputedStyle(stage, '::after')
    return {
      topLeftRadius: stageStyle.borderTopLeftRadius,
      stageBackground: stageStyle.backgroundImage,
      ambientOverlayBackground: ambientStyle.backgroundImage,
      matrixTop: matrixStyle.top,
      matrixBackground: matrixStyle.backgroundImage,
      matrixMask: matrixStyle.maskImage,
    }
  })
  expect(Number.parseFloat(historyStageMaterial.topLeftRadius)).toBeGreaterThanOrEqual(16)
  expect(historyStageMaterial.stageBackground.match(/gradient\(/g)?.length ?? 0).toBeGreaterThanOrEqual(4)
  expect(historyStageMaterial.ambientOverlayBackground).toBe('none')
  expect(Number.parseFloat(historyStageMaterial.matrixTop)).toBe(0)
  expect(historyStageMaterial.matrixBackground.match(/gradient\(/g)?.length ?? 0).toBe(1)
  expect(historyStageMaterial.matrixMask).toBe('none')
  const historyViewport = await page.locator('.history-results').evaluate((results) => {
    const style = getComputedStyle(results)
    return {
      topLeftRadius: style.borderTopLeftRadius,
      topRightRadius: style.borderTopRightRadius,
      overflowY: style.overflowY,
    }
  })
  expect(Number.parseFloat(historyViewport.topLeftRadius)).toBeGreaterThanOrEqual(10)
  expect(Number.parseFloat(historyViewport.topRightRadius)).toBeGreaterThanOrEqual(10)
  expect(historyViewport.overflowY).toBe('auto')
  await expect(page.getByRole('button', { name: 'Open meeting history' })).toHaveAttribute('aria-current', 'page')
  await expect(page.getByRole('main', { name: 'Ask Arco' })).toHaveCount(0)
  await expect(page.getByRole('complementary', { name: 'Meeting transcript' })).toHaveCount(0)

  await expect(page.getByLabel('Filter meetings')).toHaveCount(0)
  await expect(page.getByText('Your conversations')).toHaveCount(0)
  await expect(page.getByText('Transcripts stay on this Mac.')).toHaveCount(0)
  await page.waitForTimeout(250)
  await page.screenshot({ path: 'test-results/arco-final-history-light.png', fullPage: true })

  await page.getByRole('textbox', { name: 'Search meetings' }).fill('Benchmark review')
  await expect(page.getByRole('button', { name: /Benchmark review with Estrella/i })).toBeVisible()

  await page.getByRole('textbox', { name: 'Search meetings' }).fill('definitely-not-in-any-meeting')
  await expect(page.getByText('No matching meetings')).toBeVisible()
  await expect(page.getByText('Try a phrase from the transcript or clear your search.')).toBeVisible()

  await page.getByRole('textbox', { name: 'Search meetings' }).fill('Benchmark review')
  const benchmark = page.getByRole('button', { name: /Benchmark review with Estrella/i })
  await expect(benchmark).toBeVisible()
  await benchmark.click()

  await expect(page.getByRole('heading', { level: 1, name: 'Benchmark review with Estrella' })).toBeVisible()
  await expect(page.getByRole('main', { name: 'Ask Arco' })).toBeVisible()
  const transcript = page.getByRole('complementary', { name: 'Meeting transcript' })
  await expect(transcript).toBeVisible()
  await expect(transcript.getByRole('heading', { name: 'Summary' })).toBeVisible()
  await expect(transcript.getByText(/benchmark/i).first()).toBeVisible()
  await expect(page.getByRole('button', { name: /Return to live meeting Product direction/i })).toBeVisible()
  await page.screenshot({ path: 'test-results/arco-product-reviewing-during-live.png', fullPage: true })
  await expect(page.getByRole('button', { name: 'Open meeting history' })).toHaveAttribute('aria-current', 'page')
  await expect(page.getByRole('button', { name: 'Open current meeting' })).not.toHaveAttribute('aria-current')

  await page.getByRole('button', { name: 'Back to History' }).click()

  await expect(page.getByRole('heading', { level: 1, name: 'History' })).toBeVisible()
  await expect(page.getByRole('textbox', { name: 'Search meetings' })).toHaveValue('Benchmark review')
  await expect(page.getByRole('button', { name: /Benchmark review with Estrella/i })).toBeVisible()
})

test('Agent chooses a workspace once and reuses it without a per-question path field', async ({ page }) => {
  await gotoConfigured(page, '/?demo=1')

  const agent = page.getByRole('main', { name: 'Ask Arco' })
  await expect(agent).toBeVisible()
  await expect(agent.getByText(/Home folder|Personal folder/i)).toHaveCount(0)
  await agent.getByRole('button', { name: 'Add context' }).click()
  await agent.getByRole('menuitem', { name: 'Choose workspace' }).click()
  const quickAction = agent.getByRole('button', { name: /Answer what was asked/i })

  await expect(agent.getByRole('textbox', { name: 'Workspace path' })).toHaveCount(0)
  await expect(agent.getByRole('button', { name: 'Change workspace' })).toHaveText('Arco')
  await expect(quickAction).toBeEnabled()
  await expect(agent.getByText('This transcript')).toBeVisible()
  await page.screenshot({ path: 'test-results/arco-agent-workspace-selected.png', fullPage: true })

  await quickAction.click()
  await expect(agent.getByText(/Arco becomes more than a recorder/)).toBeVisible()
  const contextDisclosure = agent.getByRole('button', { name: 'Context used · 2' })
  await expect(contextDisclosure).toHaveAttribute('aria-expanded', 'false')
  await expect(agent.getByText('Current transcript · 14:02–14:06')).toHaveCount(0)

  await contextDisclosure.click()

  await expect(contextDisclosure).toHaveAttribute('aria-expanded', 'true')
  await expect(agent.getByText('Current transcript · 14:02–14:06')).toBeVisible()

  await page.reload()
  const reopenedAgent = page.getByRole('main', { name: 'Ask Arco' })
  await reopenedAgent.getByRole('button', { name: 'Add context' }).click()
  await reopenedAgent.getByRole('menuitem', { name: 'Use Arco workspace' }).click()
  await expect(reopenedAgent.getByRole('button', { name: 'Change workspace' })).toHaveText('Arco')
  await expect(reopenedAgent.getByRole('textbox', { name: 'Workspace path' })).toHaveCount(0)
})

test('Agent panel keeps one aligned document rhythm at compact desktop widths', async ({ page }) => {
  await page.setViewportSize({ width: 1024, height: 750 })
  await gotoConfigured(page, '/?demo=1')

  const agent = page.getByRole('main', { name: 'Ask Arco' })
  await agent.getByRole('button', { name: 'Add context' }).click()
  await agent.getByRole('menuitem', { name: 'Choose workspace' }).click()
  await agent.getByRole('button', { name: /Answer what was asked/i }).click()
  await expect(agent.getByRole('heading', { level: 3, name: 'Answer what was asked' })).toBeVisible()
  await expect(agent.getByRole('button', { name: 'Answer what was asked' })).toHaveCount(0)
  await expect(agent.getByRole('status')).toContainText('Reading this meeting and your selected context…')
  await expect(agent.getByText(/Arco becomes more than a recorder/)).toBeVisible()

  const agentBox = await agent.boundingBox()
  const composer = agent.locator('.ask-composer')
  const composerBox = await composer.boundingBox()
  expect(agentBox).not.toBeNull()
  expect(composerBox).not.toBeNull()
  expect(Math.round(composerBox!.x)).toBe(Math.round(agentBox!.x))
  expect(Math.round(composerBox!.width)).toBe(Math.round(agentBox!.width))

  const firstReply = agent.locator('.agent-reply').first()
  await expect(firstReply).toHaveCSS('margin-top', '0px')
  await expect(firstReply).toHaveCSS('padding-top', '0px')
  await expect(firstReply).toHaveCSS('border-top-width', '0px')

  const answer = firstReply.locator('p').first()
  await expect(answer).toHaveCSS('font-size', '14px')
  await expect(answer).toHaveCSS('line-height', '22px')
  await expect(composer).toHaveCSS('border-radius', '0px')
  await expect(composer).toHaveCSS('margin', '0px')
  await expect(agent.getByRole('textbox', { name: 'Ask the agent about this meeting' })).toHaveAttribute('rows', '2')

  const contextChips = composer.locator('.composer-context-chip')
  await expect(contextChips).toHaveCount(2)
  for (let index = 0; index < 2; index += 1) {
    const chip = contextChips.nth(index)
    await expect(chip).toHaveCSS('font-size', '10px')
    await expect(chip).toHaveCSS('font-weight', '400')
    await expect(chip).toHaveCSS('padding', '4px 7px')
    const box = await chip.boundingBox()
    expect(box).not.toBeNull()
    expect(box!.height).toBeLessThanOrEqual(22)
  }

  const actionButtons = agent.locator('.reply-actions button')
  await expect(actionButtons).toHaveCount(3)
  for (let index = 0; index < 3; index += 1) {
    const button = actionButtons.nth(index)
    await expect(button).toHaveCSS('font-size', '11px')
    const box = await button.boundingBox()
    expect(box).not.toBeNull()
    expect(box!.height).toBeGreaterThanOrEqual(30)
  }
})

test('Agent answers render Markdown as document content instead of syntax text', async ({ page }) => {
  await page.addInitScript(() => {
    window.localStorage.setItem('arco.demoAgentTurns', JSON.stringify([{
      id: 'markdown-turn',
      meetingId: 'demo-live',
      provider: 'codex',
      question: 'Summarize the recommendation',
      answer: [
        '**Direct answer: keep the transcript visible. **',
        '',
        '- Preserve the evidence',
        '- Render `Markdown` safely',
        '',
        '| State | Result |',
        '| --- | --- |',
        '| Ready | Sent |',
      ].join('\n'),
      sources: [],
      contextScope: 'transcript',
      createdAt: new Date().toISOString(),
      savedAsNote: false,
      usedFallback: false,
    }]))
  })
  await gotoConfigured(page, '/?demo=1')

  const reply = page.locator('.agent-reply').first()
  await expect(reply.locator('strong')).toHaveText('Direct answer: keep the transcript visible.')
  await expect(reply.getByRole('listitem')).toHaveCount(2)
  await expect(reply.locator('code')).toHaveText('Markdown')
  await expect(reply.getByRole('table')).toContainText('Ready')
  await expect(reply).not.toContainText('**Direct answer: keep the transcript visible. **')
  await page.screenshot({ path: 'test-results/arco-agent-markdown.png', fullPage: true })
})

test('Agent uses the configured primary without a per-question provider switch', async ({ page }) => {
  await gotoConfigured(page, '/?demo=1')
  const agent = page.getByRole('main', { name: 'Ask Arco' })

  await expect(agent.getByLabel('Current provider')).toHaveCount(0)
  await expect(agent.getByRole('combobox', { name: 'Agent provider' })).toHaveCount(0)
  await agent.getByRole('button', { name: /Answer what was asked/i }).click()
  await expect(agent.getByText(/Arco becomes more than a recorder/)).toBeVisible()
  await expect(agent.getByText(/native session/i)).toHaveCount(0)
  await page.waitForTimeout(400)
  await page.screenshot({ path: 'test-results/arco-configured-primary-agent.png', fullPage: true })
})

test('a user-confirmed Agent note survives reloading the app', async ({ page }) => {
  await gotoConfigured(page, '/?demo=1')
  let agent = page.getByRole('main', { name: 'Ask Arco' })
  await agent.getByRole('button', { name: /Answer what was asked/i }).click()
  await expect(agent.getByText(/Arco becomes more than a recorder/)).toBeVisible()
  await agent.getByRole('button', { name: 'Save as note' }).click()
  await expect(agent.getByRole('button', { name: 'Saved note' })).toBeVisible()
  await page.waitForTimeout(400)
  await page.screenshot({ path: 'test-results/arco-product-saved-note.png', fullPage: true })

  await page.reload()
  agent = page.getByRole('main', { name: 'Ask Arco' })
  await expect(agent.getByText(/Arco becomes more than a recorder/)).toBeVisible()
  await expect(agent.getByRole('button', { name: 'Saved note' })).toBeVisible()
})

test('saved Agent answers are browsable from Notes and retain their meeting source', async ({ page }) => {
  await page.setViewportSize({ width: 1240, height: 820 })
  await gotoConfigured(page, '/?demo=1')
  const agent = page.getByRole('main', { name: 'Ask Arco' })
  await agent.getByRole('button', { name: /Answer what was asked/i }).click()
  await agent.getByRole('button', { name: 'Save as note' }).click()

  await page.getByRole('button', { name: 'Open saved notes' }).click()

  await expect(page.getByRole('heading', { level: 1, name: 'Notes' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Product direction · weekly working session', exact: true })).toBeVisible()
  await expect(page.getByRole('textbox', { name: 'Markdown note' })).toHaveValue(/Arco becomes more than a recorder/)
  await expect(page.getByRole('button', { name: 'Open saved notes' })).toHaveAttribute('aria-current', 'page')
  await page.screenshot({ path: 'test-results/arco-notes-1240x820.png', fullPage: true })

  await page.getByRole('button', { name: 'Preview' }).click()
  await expect(page.locator('.note-markdown-preview')).toContainText('Arco becomes more than a recorder')
  await page.waitForTimeout(400)
  await page.screenshot({ path: 'test-results/arco-notes-preview-1240x820.png', fullPage: true })
  await page.getByRole('button', { name: 'Write' }).click()
  await expect(page.getByRole('textbox', { name: 'Markdown note' })).toBeVisible()

  await page.setViewportSize({ width: 1080, height: 750 })
  await expect(page.getByRole('heading', { level: 1, name: 'Notes' })).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(1080)
  await page.screenshot({ path: 'test-results/arco-notes-1080x750.png', fullPage: true })

  await page.emulateMedia({ colorScheme: 'dark' })
  await page.setViewportSize({ width: 1024, height: 750 })
  await expect(page.locator('body')).toHaveCSS('color-scheme', 'light')
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(1024)
})

test('a user can write multiple Markdown notes for the same meeting and reopen them', async ({ page }) => {
  await gotoConfigured(page, '/?demo=1')
  await page.getByRole('button', { name: 'Open saved notes' }).click()

  await page.getByRole('button', { name: 'New note' }).click()
  const titleBox = await page.getByRole('textbox', { name: 'Note title' }).boundingBox()
  const meetingBox = await page.locator('.note-meeting-field').boundingBox()
  expect(titleBox).not.toBeNull()
  expect(meetingBox).not.toBeNull()
  expect(meetingBox!.y - (titleBox!.y + titleBox!.height)).toBeGreaterThanOrEqual(8)
  await expect(page.getByRole('combobox', { name: 'Meeting for this note' })).toHaveValue('demo-live')
  await page.getByRole('textbox', { name: 'Note title' }).fill('Interview follow-ups')
  await page.getByRole('textbox', { name: 'Markdown note' }).fill('- Ask about the rollout\n- Confirm the owner')
  await page.getByRole('button', { name: 'Save note' }).click()
  await expect(page.getByText('Saved', { exact: true })).toBeVisible()

  await page.getByRole('button', { name: 'New note' }).click()
  await page.getByRole('textbox', { name: 'Note title' }).fill('Open questions')
  await page.getByRole('textbox', { name: 'Markdown note' }).fill('1. Who owns launch readiness?')
  await page.getByRole('button', { name: 'Save note' }).click()
  await expect(page.getByText('Saved', { exact: true })).toBeVisible()

  await expect(page.getByRole('button', { name: /Interview follow-ups/ })).toBeVisible()
  await expect(page.getByRole('button', { name: /Open questions/ })).toBeVisible()

  await page.reload()
  await page.getByRole('button', { name: 'Open saved notes' }).click()
  await page.getByRole('button', { name: /Interview follow-ups/ }).click()
  await expect(page.getByRole('textbox', { name: 'Markdown note' })).toHaveValue('- Ask about the rollout\n- Confirm the owner')
  await expect(page.getByRole('combobox', { name: 'Meeting for this note' })).toHaveValue('demo-live')
})

test('the normal browser preview never returns the fixed Agent fixture as a real CLI answer', async ({ page }) => {
  await gotoConfigured(page)
  const agent = page.getByRole('main', { name: 'Ask Arco' })

  await agent.getByRole('button', { name: /Answer what was asked/i }).click()

  await expect(page.getByRole('alert')).toContainText('Browser preview cannot call your local CLI')
  await expect(agent.getByText(/Arco becomes more than a recorder/)).toHaveCount(0)
  await expect(agent.getByRole('textbox', { name: 'Ask the agent about this meeting' })).toHaveValue(
    'Answer what was asked',
  )
})

test('Settings uses navigable sections in one centered sheet', async ({ page }) => {
  await gotoConfigured(page)
  await page.getByRole('button', { name: 'Open settings' }).click()

  await expect(page.getByRole('dialog', { name: 'General' })).toBeVisible()
  await expect(page.getByRole('combobox', { name: 'App language' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Change listening shortcut' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Shortcuts' })).toHaveCount(0)
  await page.screenshot({ path: 'test-results/arco-general-settings-light.png', fullPage: true })
  const settingsMaterial = await page.locator('.settings-main').evaluate((surface) => ({
    background: getComputedStyle(surface).backgroundColor,
    backdrop: getComputedStyle(surface).backdropFilter,
  }))
  const settingsAlpha = settingsMaterial.background.match(/rgba?\([^,]+,[^,]+,[^,]+(?:,\s*([\d.]+))?\)/)?.[1]
  expect(settingsAlpha === undefined ? 1 : Number(settingsAlpha)).toBeLessThan(0.8)
  expect(settingsMaterial.backdrop).toContain('blur(')
  await page.getByRole('button', { name: 'Audio & speakers' }).click()
  const recognition = page.locator('summary').filter({ hasText: /^Recognition/ })
  await expect(recognition).toBeVisible()
  await expect(page.getByText('Chinese', { exact: true })).toBeVisible()
  await expect(page.getByText('Remote 1… · In room 1…')).toHaveCount(0)
  await expect(page.getByText(/Deepgram separates multiple speakers/i)).not.toBeVisible()
  await page.screenshot({ path: 'test-results/arco-product-audio-modes.png', fullPage: true })
  await recognition.click()
  await expect(page.getByText(/Deepgram separates multiple speakers/i)).toBeVisible()
  await expect(page.getByText('Deepgram · multichannel diarization')).toBeVisible()
  await page.screenshot({ path: 'test-results/arco-product-audio-recognition.png', fullPage: true })
  await page.getByRole('button', { name: /Agent runtime/i }).click()
  await expect(page.getByRole('dialog', { name: 'Agent runtime' })).toBeVisible()
  await expect(page.getByText('Codex CLI').first()).toBeVisible()
  await expect(page.getByText('Claude Code', { exact: true })).toBeVisible()
  await page.screenshot({ path: 'test-results/arco-provider-settings.png', fullPage: true })

  await page.getByRole('button', { name: 'Edit configuration' }).click()
  const providerSetup = page.getByRole('dialog', { name: 'Connect Codex or Claude' })
  await expect(providerSetup.getByRole('button', { name: 'Choose providers' })).toHaveAttribute('aria-current', 'step')
  await expect(providerSetup.getByRole('radio', { name: 'Codex as primary' })).toBeChecked()
  await expect(providerSetup.getByRole('radio', { name: 'Claude as secondary' })).toBeChecked()
  await page.screenshot({ path: 'test-results/arco-provider-edit.png', fullPage: true })
  await providerSetup.getByRole('button', { name: 'Cancel setup' }).click()

  await page.getByRole('button', { name: 'Open settings' }).click()
  await page.getByRole('button', { name: /Data & privacy/i }).click()
  await expect(page.getByRole('dialog', { name: 'Data & privacy' })).toBeVisible()
  await expect(page.getByRole('combobox', { name: 'App language' })).toHaveCount(0)
  const transcriptStorage = page.getByRole('button', { name: 'Meeting transcript storage' })
  await expect(transcriptStorage).toContainText('Default')
  await expect(transcriptStorage).toContainText('/Users/demo/Library/Application Support/Arco/transcripts')
  await expect(transcriptStorage).toBeDisabled()
  await expect(page.getByText('Stop the current meeting before changing this folder.')).toBeVisible()
  await expect(page.getByText('Stored in Arco on this Mac')).toBeVisible()

  await page.screenshot({ path: 'test-results/arco-final-settings-light.png', fullPage: true })
})

test('transcript storage has a default, supports a custom folder, and restores the default', async ({ page }) => {
  await gotoConfigured(page, '/?demo=1')
  await page.getByRole('button', { name: 'Stop listening' }).click()
  await page.getByRole('button', { name: 'Open settings' }).click()
  await page.getByRole('button', { name: 'Data & privacy' }).click()

  const transcriptStorage = page.getByRole('button', { name: 'Meeting transcript storage' })
  await expect(transcriptStorage).toContainText('Default')
  await transcriptStorage.click()
  await expect(transcriptStorage).toContainText('Custom')
  await expect(transcriptStorage).toContainText('/Users/demo/Documents/Arco Meetings')
  await page.screenshot({ path: 'test-results/arco-transcript-storage-custom.png', fullPage: true })

  await page.getByRole('button', { name: 'Close settings' }).click()
  await page.reload()
  await page.getByRole('button', { name: 'Open settings' }).click()
  await page.getByRole('button', { name: 'Data & privacy' }).click()
  await expect(page.getByRole('button', { name: 'Meeting transcript storage' })).toContainText('Custom')
  await page.getByRole('button', { name: 'Restore default' }).click()
  await expect(page.getByRole('button', { name: 'Meeting transcript storage' })).toContainText('Default')
})

test('Recognition keeps Deepgram built-in and exposes independent local diarization models', async ({ page }) => {
  await page.setViewportSize({ width: 1080, height: 750 })
  await gotoConfigured(page, '/?demo=1')
  await page.getByRole('button', { name: 'Stop listening' }).click()
  await page.getByRole('button', { name: 'Open settings' }).click()
  await page.getByRole('button', { name: 'Audio & speakers' }).click()

  const settings = page.getByRole('dialog', { name: 'Audio & speakers' })
  await settings.locator('summary').filter({ hasText: /^Recognition/ }).click()
  const deepgramSetup = settings.getByRole('group', { name: 'Deepgram setup' })
  const getDeepgramKey = deepgramSetup.getByRole('link', { name: 'Get a Deepgram key' })
  await expect(getDeepgramKey).toHaveAttribute(
    'href',
    'https://console.deepgram.com/',
  )
  const deepgramConsole = page.waitForEvent('popup')
  await getDeepgramKey.click()
  const deepgramConsolePage = await deepgramConsole
  await expect(deepgramConsolePage).toHaveURL(/console\.deepgram\.com/)
  await deepgramConsolePage.close()
  await deepgramSetup.getByLabel('Deepgram API key').fill('0123456789abcdef0123456789abcdef')
  await deepgramSetup.getByRole('button', { name: 'Verify & save' }).click()
  await expect(deepgramSetup.getByText('Deepgram is ready')).toBeVisible()
  await expect(settings.getByText('Deepgram built-in', { exact: true }).first()).toBeVisible()
  await expect(settings.getByRole('radio', { name: /LS-EEND/i })).toHaveCount(0)
  await expect(deepgramSetup).not.toContainText(/uv|python|\.env|DEEPGRAM_API_KEY=/i)
  await page.screenshot({ path: 'test-results/arco-deepgram-setup.png', fullPage: true })
  await settings.getByText('This Mac', { exact: true }).click()
  const recognitionSummary = settings.locator('summary').filter({ hasText: /^Recognition/ })
  await expect(recognitionSummary).toContainText('Nemotron Speech 3.5 not downloaded')
  await expect(recognitionSummary).toContainText('Streaming Sortformer not downloaded')
  await expect(recognitionSummary.getByLabel('Required local models are not downloaded')).toBeVisible()
  await page.screenshot({ path: 'test-results/arco-local-models-missing.png', fullPage: true })

  const model = settings.getByRole('combobox', { name: 'On-device model' })
  await expect(model).toHaveValue('nemotron-speech-3.5-streaming')
  await expect(model.locator('option')).toHaveText([
    'Nemotron Speech 3.5 · ~670 MB',
    'Whisper Tiny · ~75 MB',
    'Whisper Base · ~142 MB',
    'Whisper Small · ~466 MB',
    'Whisper Medium · ~1.5 GB',
    'Whisper Large · ~2.9 GB',
  ])
  await expect(settings.getByRole('radio', { name: /Streaming Sortformer/i })).toBeChecked()
  await expect(settings.getByRole('radio', { name: /LS-EEND Meeting/i })).not.toBeChecked()
  await expect(settings.getByRole('radio', { name: /LS-EEND General/i })).not.toBeChecked()
  const downloadSortformer = settings.getByRole('button', { name: 'Download Streaming Sortformer' })
  await expect(downloadSortformer).toBeVisible()
  await downloadSortformer.click()
  await expect(downloadSortformer).toBeHidden()
  await expect(settings.getByText('Ready', { exact: true })).toBeVisible()
  await expect(settings.getByText('Audio and transcript stay on this Mac.')).toBeVisible()
  await expect(settings.getByRole('radio', { name: /Streaming Sortformer.*up to 4 speakers per audio source/i })).toBeChecked()

  await settings.getByRole('radio', { name: /LS-EEND General/i }).click()
  const downloadGeneral = settings.getByRole('button', { name: 'Download LS-EEND General' })
  await downloadGeneral.click()
  await expect(downloadGeneral).toBeHidden()
  await expect(settings.getByRole('radio', { name: /LS-EEND General.*up to 10 speakers per audio source/i })).toBeChecked()

  await model.selectOption('whisper-small')
  await settings.getByRole('button', { name: 'Download and use Whisper Small' }).click()
  await expect(settings.getByText('Ready on this Mac')).toBeVisible()
  await settings.getByRole('combobox', { name: 'Recognition language' }).selectOption('en-US')
  await expect(recognitionSummary).toContainText('Whisper Small · LS-EEND General')
  await expect(recognitionSummary.getByLabel('Required local models are not downloaded')).toBeHidden()
  await page.screenshot({ path: 'test-results/arco-local-recognition-settings.png', fullPage: true })
  await settings.getByRole('button', { name: 'Close settings' }).click()

  await page.getByRole('button', { name: 'Open settings' }).click()
  await page.getByRole('button', { name: 'Audio & speakers' }).click()
  const reopened = page.getByRole('dialog', { name: 'Audio & speakers' })
  await reopened.locator('summary').filter({ hasText: /^Recognition/ }).click()
  await expect(reopened.getByRole('combobox', { name: 'On-device model' })).toHaveValue('whisper-small')
  await expect(reopened.getByRole('combobox', { name: 'Recognition language' })).toHaveValue('en-US')
})

test('Meeting output reveals prompt editing only on demand and persists each rule', async ({ page }) => {
  await gotoConfigured(page)
  await page.getByRole('button', { name: 'Open settings' }).click()
  await page.getByRole('button', { name: /Meeting output/i }).click()

  const settings = page.getByRole('dialog', { name: 'Meeting output' })
  await expect(settings.getByRole('button', { name: /Automatic title/i })).toContainText('On · Arco default')
  await expect(settings.getByRole('button', { name: /End-of-meeting summary/i })).toContainText('On · Arco default')
  await expect(settings.getByRole('textbox', { name: 'Prompt' })).toHaveCount(0)
  await page.screenshot({ path: 'test-results/arco-meeting-output-settings.png', fullPage: true })

  await settings.getByRole('button', { name: /Automatic title/i }).click()
  await expect(settings.getByRole('heading', { name: 'Automatic title' })).toBeVisible()
  await settings.getByRole('switch', { name: 'Use custom prompt' }).click()
  const prompt = settings.getByRole('textbox', { name: 'Prompt' })
  await page.screenshot({ path: 'test-results/arco-meeting-output-prompt.png', fullPage: true })
  await prompt.fill('Name the meeting from its clearest decision. Return only the title.')
  await settings.getByRole('button', { name: 'Save changes' }).click()

  await expect(settings.getByRole('button', { name: /Automatic title/i })).toContainText('On · Custom')
  await settings.getByRole('button', { name: 'Close settings' }).click()

  await page.getByRole('button', { name: 'Open settings' }).click()
  await page.getByRole('button', { name: /Meeting output/i }).click()
  const reopened = page.getByRole('dialog', { name: 'Meeting output' })
  await expect(reopened.getByRole('button', { name: /Automatic title/i })).toContainText('On · Custom')
  await reopened.getByRole('button', { name: /Automatic title/i }).click()
  await expect(reopened.getByRole('textbox', { name: 'Prompt' })).toHaveValue(
    'Name the meeting from its clearest decision. Return only the title.',
  )
})

test('1024 layout stays light under dark system appearance without overflow', async ({ page }) => {
  await page.setViewportSize({ width: 1024, height: 768 })
  await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce' })
  await gotoConfigured(page)
  await expect(page.locator('html')).toHaveCSS('color-scheme', 'light')

  const agent = page.getByRole('main', { name: 'Ask Arco' })
  const transcript = page.getByRole('complementary', { name: 'Meeting transcript' })
  const agentBox = await agent.boundingBox()
  const transcriptBox = await transcript.boundingBox()
  expect(agentBox).not.toBeNull()
  expect(transcriptBox).not.toBeNull()
  expect(transcriptBox!.x).toBeLessThan(agentBox!.x)
  expect(transcriptBox!.width).toBeGreaterThan(agentBox!.width)
  expect(transcriptBox!.x + transcriptBox!.width).toBeLessThanOrEqual(agentBox!.x + 1)
  await expect(page.getByRole('button', { name: 'Stop listening' })).toHaveCount(1)
  await expect(page.getByRole('button', { name: /Open Agent|Close Agent/i })).toHaveCount(0)

  const viewport = await page.evaluate(() => ({
    innerWidth: window.innerWidth,
    documentWidth: document.documentElement.scrollWidth,
    bodyWidth: document.body.scrollWidth,
  }))
  expect(viewport.documentWidth).toBeLessThanOrEqual(viewport.innerWidth)
  expect(viewport.bodyWidth).toBeLessThanOrEqual(viewport.innerWidth)
  expect(agentBox!.x + agentBox!.width).toBeLessThanOrEqual(viewport.innerWidth)

  await page.screenshot({ path: 'test-results/arco-transcript-first-light-forced-1024.png', fullPage: true })
})

test('1080 light layout preserves the Transcript-first split without horizontal overflow', async ({ page }) => {
  await page.setViewportSize({ width: 1080, height: 750 })
  await gotoConfigured(page)

  const agent = page.getByRole('main', { name: 'Ask Arco' })
  const transcript = page.getByRole('complementary', { name: 'Meeting transcript' })
  const agentBox = await agent.boundingBox()
  const transcriptBox = await transcript.boundingBox()

  expect(agentBox).not.toBeNull()
  expect(transcriptBox).not.toBeNull()
  expect(transcriptBox!.x).toBeLessThan(agentBox!.x)
  expect(transcriptBox!.width).toBeGreaterThan(agentBox!.width)
  expect(transcriptBox!.x + transcriptBox!.width).toBeLessThanOrEqual(agentBox!.x + 1)

  const viewport = await page.evaluate(() => ({
    innerWidth: window.innerWidth,
    documentWidth: document.documentElement.scrollWidth,
    bodyWidth: document.body.scrollWidth,
  }))
  expect(viewport.documentWidth).toBeLessThanOrEqual(viewport.innerWidth)
  expect(viewport.bodyWidth).toBeLessThanOrEqual(viewport.innerWidth)

  await page.screenshot({ path: 'test-results/arco-transcript-first-light-1080.png', fullPage: true })
})

test('capture can stop and start again without leaving Current', async ({ page }) => {
  await page.setViewportSize({ width: 1240, height: 820 })
  await gotoConfigured(page)

  await page.getByRole('button', { name: 'Stop listening' }).click()
  const idle = page.getByRole('region', { name: 'Start listening' })
  const start = idle.getByRole('button', { name: 'Start listening' })
  await expect(start).toBeEnabled()
  await expect(page.getByRole('button', { name: 'Start listening' })).toHaveCount(1)
  await expect(page.getByRole('button', { name: 'Open current meeting' })).toHaveAttribute('aria-current', 'page')
  await expect(page.getByText(/microphone cannot be treated as one person/i)).toHaveCount(0)
  await expect(idle.getByRole('region', { name: 'On this Mac' })).toBeVisible()
  await page.waitForTimeout(500)
  await page.screenshot({ path: 'test-results/arco-idle-current-with-history.png', fullPage: true, animations: 'disabled' })

  await page.getByRole('button', { name: 'Open meeting history' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'History' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Start listening' })).toHaveCount(1)
  await page.getByRole('button', { name: 'Open current meeting' }).click()
  await expect(page.getByRole('region', { name: 'Start listening' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Start listening' })).toHaveCount(1)

  await start.click()
  await expect(page.getByRole('button', { name: 'Stop listening' })).toBeEnabled()
})

test('the next meeting can be explicitly set to online-only audio', async ({ page }) => {
  await gotoConfigured(page)
  await page.getByRole('button', { name: 'Stop listening' }).click()
  await page.getByRole('button', { name: 'Open settings' }).click()
  await page.getByRole('button', { name: 'Audio & speakers' }).click()
  const settings = page.getByRole('dialog', { name: 'Audio & speakers' })
  await settings.locator('label').filter({ hasText: 'Online meeting' }).click()
  await page.screenshot({ path: 'test-results/arco-product-audio-mode-online.png', fullPage: true })
  await settings.getByRole('button', { name: 'Close settings' }).click()

  const capture = page.getByRole('region', { name: 'Audio capture · Online · System audio' })
  await expect(capture).toContainText('Online')
  await expect(capture.getByText('System')).toHaveCount(0)
  await expect(capture.getByText('Room')).toHaveCount(0)
})

test('the interface switches to Chinese across the workspace and keeps it after reload', async ({ page }) => {
  await page.setViewportSize({ width: 1240, height: 820 })
  await gotoConfigured(page)

  await page.getByRole('button', { name: 'Open settings' }).click()
  await page.getByRole('combobox', { name: 'App language' }).selectOption('zh-CN')

  const settings = page.getByRole('dialog', { name: '通用' })
  await expect(settings).toBeVisible()
  await expect(settings.getByText('界面语言', { exact: true })).toBeVisible()
  await expect(settings.getByRole('button', { name: '修改聆听快捷键' })).toBeVisible()
  await expect(page.getByRole('button', { name: '音频与说话人' })).toBeVisible()
  await page.screenshot({ path: 'test-results/arco-i18n-zh-settings-1240.png', fullPage: true })
  await settings.getByRole('button', { name: '关闭设置' }).click()

  await expect(page.getByRole('button', { name: '打开当前会议' })).toBeVisible()
  await expect(page.getByRole('main', { name: '询问 Arco' })).toBeVisible()
  await expect(page.getByRole('complementary', { name: '会议转写' })).toBeVisible()
  await page.screenshot({ path: 'test-results/arco-i18n-zh-1240.png', fullPage: true })

  await page.reload()
  await expect(page.getByRole('button', { name: '打开设置' })).toBeVisible()
  await expect(page.locator('html')).toHaveAttribute('lang', 'zh-CN')
  await page.setViewportSize({ width: 1024, height: 768 })
  await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce' })
  await expect(page.locator('html')).toHaveCSS('color-scheme', 'light')
  await page.screenshot({ path: 'test-results/arco-i18n-zh-light-forced-1024.png', fullPage: true })

  const viewport = await page.evaluate(() => ({
    innerWidth: window.innerWidth,
    documentWidth: document.documentElement.scrollWidth,
    bodyWidth: document.body.scrollWidth,
  }))
  expect(viewport.documentWidth).toBeLessThanOrEqual(viewport.innerWidth)
  expect(viewport.bodyWidth).toBeLessThanOrEqual(viewport.innerWidth)
})

test('first launch can switch to Chinese before provider setup', async ({ page }) => {
  await page.setViewportSize({ width: 1240, height: 820 })
  await page.addInitScript(() => {
    window.localStorage.removeItem('arco.providerConfig')
    window.localStorage.removeItem('arco.onboarding.v1')
    window.localStorage.setItem('arco.locale', 'en')
  })
  await page.goto('/?demo=1')

  await page.getByRole('combobox', { name: 'App language' }).selectOption('zh-CN')

  await expect(page.getByRole('heading', { name: '专注于正在发生的对话' })).toBeVisible()
  await expect(page.getByRole('button', { name: '继续' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Agent' })).toHaveCount(0)
  await page.getByRole('button', { name: '继续' }).click()
  await expect(page.getByRole('button', { name: 'Agent' })).toHaveAttribute('aria-current', 'step')
  await page.screenshot({ path: 'test-results/arco-i18n-zh-onboarding-1240.png', fullPage: true })
})
