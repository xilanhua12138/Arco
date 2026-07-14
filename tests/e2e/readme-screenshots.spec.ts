import { expect, test, type Page } from '@playwright/test'
import { readFile } from 'node:fs/promises'

test.use({ deviceScaleFactor: 2 })

const providerConfig = JSON.stringify({
  setupComplete: true,
  primary: 'codex',
  secondary: 'claude',
})

async function openDemo(page: Page, url = '/?demo=1') {
  await page.addInitScript(({ config }) => {
    window.localStorage.setItem('arco.providerConfig', config)
    window.localStorage.setItem('arco.locale', 'en')
  }, { config: providerConfig })
  await page.goto(url)
}

async function attachWorkspaceAndAsk(page: Page) {
  const agent = page.getByRole('main', { name: 'Ask Arco' })
  await agent.getByRole('button', { name: 'Add context' }).click()
  await agent.getByRole('menuitem', { name: 'Choose workspace' }).click()
  await expect(agent.getByRole('button', { name: 'Change workspace' })).toHaveText('Arco')
  await agent.getByRole('button', { name: 'Answer what was asked' }).click()
  await expect(agent.getByRole('heading', { name: 'Answer what was asked' })).toBeVisible()
  await expect(agent.getByText(/Arco becomes more than a recorder/)).toBeVisible()
  await expect(agent.getByText('This transcript')).toBeVisible()
}

const loadPublicPageBackdrop = () => readFile('tests/e2e/fixtures/github-arco-page.jpg')

async function captureRecordingHudMarkup(page: Page) {
  await page.setViewportSize({ width: 1440, height: 900 })
  await page.addInitScript(() => {
    window.localStorage.setItem('arco.locale', 'en')
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
  return hud.evaluate((element) => element.outerHTML)
}

async function placeSurfaceOnDesktop(page: Page, backdrop: Buffer) {
  const backgroundImage = `url(data:image/jpeg;base64,${backdrop.toString('base64')})`

  await page.evaluate((image) => {
    document.documentElement.style.backgroundImage = image
    document.documentElement.style.backgroundPosition = 'center'
    document.documentElement.style.backgroundRepeat = 'no-repeat'
    document.documentElement.style.backgroundSize = 'cover'
  }, backgroundImage)
}

test('capture the live transcript and workspace-grounded Agent after a real interaction', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 920 })
  await openDemo(page)
  await expect(page.getByRole('complementary', { name: 'Meeting transcript' })).toBeVisible()
  await attachWorkspaceAndAsk(page)
  await page.screenshot({
    path: 'docs/images/arco-live-agent.png',
    fullPage: true,
    animations: 'disabled',
  })
})

test('capture the global Agent and recording HUD in one live desktop scene', async ({ page, context }) => {
  const hudPage = await context.newPage()
  const hudMarkup = await captureRecordingHudMarkup(hudPage)
  await hudPage.close()

  await page.setViewportSize({ width: 1440, height: 900 })
  await openDemo(page)
  await attachWorkspaceAndAsk(page)
  const backdrop = await loadPublicPageBackdrop()
  await page.goto('/?surface=agent-overlay&demo=1')
  await placeSurfaceOnDesktop(page, backdrop)

  const overlay = page.getByRole('dialog', { name: 'Ask Arco' })
  await expect(overlay).toBeVisible()
  await expect(page.getByRole('complementary', { name: 'Meeting transcript' })).toBeVisible()
  await expect(overlay.getByText(/Arco becomes more than a recorder/)).toBeVisible()
  await overlay.getByRole('button', { name: 'Add context' }).click()
  await overlay.getByRole('menuitem', { name: 'Use Arco workspace' }).click()
  await expect(overlay.getByRole('button', { name: 'Change workspace' })).toHaveText('Arco')
  const jumpToLive = page.getByRole('button', { name: 'Jump to live' })
  await expect(jumpToLive).toBeHidden({ timeout: 10_000 })
  await page.evaluate((markup) => {
    const container = document.createElement('div')
    container.innerHTML = markup
    const hud = container.firstElementChild
    if (!(hud instanceof HTMLElement)) throw new Error('Recording HUD markup is missing')
    hud.style.position = 'fixed'
    hud.style.left = '50%'
    hud.style.bottom = '24px'
    hud.style.width = '368px'
    hud.style.height = '56px'
    hud.style.transform = 'translateX(-50%)'
    hud.style.zIndex = '10'
    document.body.append(hud)
  }, hudMarkup)
  await expect(page.getByRole('region', { name: 'Arco recording controls' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Stop recording' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Ask Arco' })).toBeVisible()
  await page.screenshot({
    path: 'docs/images/arco-agent-overlay.png',
    fullPage: true,
    animations: 'disabled',
  })
})

test('README presents the in-meeting interaction once and thanks FluidVoice', async () => {
  const [english, chinese] = await Promise.all([
    readFile('README.md', 'utf8'),
    readFile('README.zh-CN.md', 'utf8'),
  ])

  expect(english).toContain('## Ask without leaving the conversation')
  expect(english).not.toContain('## Stay in the conversation')
  expect(chinese).toContain('## 不离开当前对话，直接提问')
  for (const readme of [english, chinese]) {
    expect(readme.match(/docs\/images\/arco-agent-overlay\.png/g)).toHaveLength(1)
    expect(readme).not.toContain('docs/images/arco-recording-hud.png')
    expect(readme).toContain('https://github.com/altic-dev/FluidVoice')
  }
})

test('capture History after exercising search and restoring the full list', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 920 })
  await openDemo(page)
  await page.getByRole('button', { name: 'Open meeting history' }).click()

  const search = page.getByRole('textbox', { name: 'Search meetings' })
  await search.fill('Estrella')
  await expect(page.getByRole('button', { name: /Benchmark review with Estrella/ })).toBeVisible()
  await expect(page.getByRole('button', { name: /Interview host roadmap/ })).toHaveCount(0)
  await search.clear()
  await expect(page.getByRole('button', { name: /Interview host roadmap/ })).toBeVisible()

  await page.screenshot({
    path: 'docs/images/arco-history.png',
    fullPage: true,
    animations: 'disabled',
  })
})
