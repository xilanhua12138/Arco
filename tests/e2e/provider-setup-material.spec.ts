import { expect, test } from '@playwright/test'

test('provider configuration uses stable opaque reading surfaces', async ({ page }) => {
  await page.addInitScript(() => {
    window.localStorage.setItem('arco.locale', 'en')
    window.localStorage.setItem('arco.providerConfig', JSON.stringify({
      setupComplete: true,
      primary: 'codex',
      secondary: 'claude',
    }))
  })
  await page.goto('/')

  await page.getByRole('button', { name: 'Open settings' }).click()
  await page.getByRole('button', { name: /Agent runtime/i }).click()
  await page.getByRole('button', { name: 'Edit configuration' }).click()

  const material = await page.locator('.provider-setup').evaluate((dialog) => {
    const surface = getComputedStyle(dialog)
    const progress = getComputedStyle(dialog.querySelector('.provider-setup-progress')!)
    const main = getComputedStyle(dialog.querySelector('.provider-setup-main')!)
    return {
      surfaceBackground: surface.backgroundColor,
      surfaceBackdrop: surface.backdropFilter,
      progressBackground: progress.backgroundColor,
      mainBackground: main.backgroundColor,
    }
  })

  expect(material).toEqual({
    surfaceBackground: 'rgb(248, 250, 252)',
    surfaceBackdrop: 'none',
    progressBackground: 'rgb(239, 243, 246)',
    mainBackground: 'rgb(252, 252, 253)',
  })

  await page.screenshot({ path: 'test-results/arco-provider-opaque.png', fullPage: true })
})
