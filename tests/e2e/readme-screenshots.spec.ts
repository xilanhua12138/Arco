import { expect, test, type Page } from '@playwright/test'

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
  await expect(agent.getByRole('heading', {
    name: 'What is the strongest direct answer to the latest question in this meeting?',
  })).toBeVisible()
  await expect(agent.getByText(/Arco becomes more than a recorder/)).toBeVisible()
  await expect(agent.getByText('This transcript')).toBeVisible()
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

test('capture the global Agent after restoring its meeting conversation', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 720 })
  await openDemo(page)
  await attachWorkspaceAndAsk(page)
  await page.goto('/?surface=agent-overlay&demo=1')

  const overlay = page.getByRole('dialog', { name: 'Ask Arco' })
  await expect(overlay).toBeVisible()
  await expect(page.getByRole('complementary', { name: 'Meeting transcript' })).toBeVisible()
  await expect(overlay.getByText(/Arco becomes more than a recorder/)).toBeVisible()
  await overlay.getByRole('button', { name: 'Add context' }).click()
  await overlay.getByRole('menuitem', { name: 'Use Arco workspace' }).click()
  await expect(overlay.getByRole('button', { name: 'Change workspace' })).toHaveText('Arco')
  const jumpToLive = page.getByRole('button', { name: 'Jump to live' })
  if (await jumpToLive.isVisible()) {
    await jumpToLive.click()
    await expect(jumpToLive).toBeHidden()
  }
  await overlay.screenshot({
    path: 'docs/images/arco-agent-overlay.png',
    animations: 'disabled',
  })
})

test('capture the recording HUD only after verifying both global actions', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 720 })
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
  await expect(page.getByRole('button', { name: 'Stop recording' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Ask Arco' })).toBeVisible()
  await hud.screenshot({
    path: 'docs/images/arco-recording-hud.png',
    animations: 'disabled',
  })
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
