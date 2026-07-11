import { expect, test } from '@playwright/test'

test('speaker avatars stay distinct, transparent, and optically aligned at transcript size', async ({ page }) => {
  await page.setViewportSize({ width: 1240, height: 820 })
  await page.addInitScript(() => {
    window.localStorage.setItem('arco.providerConfig', JSON.stringify({
      setupComplete: true,
      primary: 'codex',
      secondary: 'claude',
    }))
  })
  await page.goto('/?demo=1')

  const transcript = page.getByRole('complementary', { name: 'Meeting transcript' })
  const avatars = transcript.locator('.speaker-avatar')
  await expect(avatars).toHaveCount(12)

  const avatarState = await transcript.locator('.speaker-label').evaluateAll((labels) => labels.map((label) => {
    const avatar = label.querySelector<SVGElement>('.speaker-avatar')
    const name = label.querySelector<HTMLElement>('strong')
    const avatarBox = avatar?.getBoundingClientRect()
    const nameBox = name?.getBoundingClientRect()
    const style = avatar ? window.getComputedStyle(avatar) : null
    return {
      speaker: name?.textContent,
      index: avatar?.dataset.avatarIndex,
      tagName: avatar?.tagName.toLocaleLowerCase(),
      backgroundColor: style?.backgroundColor,
      backgroundImage: style?.backgroundImage,
      centerDelta: avatarBox && nameBox
        ? Math.abs((avatarBox.y + avatarBox.height / 2) - (nameBox.y + nameBox.height / 2))
        : null,
    }
  }))

  expect(new Set(avatarState.map(({ speaker, index }) => `${speaker}:${index}`)).size).toBe(4)
  expect(new Set(avatarState.filter(({ speaker }) => speaker === 'Remote 1').map(({ index }) => index))).toEqual(new Set(['4']))
  expect(avatarState.every(({ tagName }) => tagName === 'svg')).toBe(true)
  expect(avatarState.every(({ backgroundColor }) => backgroundColor === 'rgba(0, 0, 0, 0)')).toBe(true)
  expect(avatarState.every(({ backgroundImage }) => backgroundImage === 'none')).toBe(true)
  expect(Math.max(...avatarState.map(({ centerDelta }) => centerDelta ?? Number.POSITIVE_INFINITY))).toBeLessThanOrEqual(1)

  await page.screenshot({ path: 'test-results/arco-speaker-avatars-vector-light.png', fullPage: true })
  await page.emulateMedia({ colorScheme: 'dark' })
  await page.setViewportSize({ width: 1024, height: 750 })
  await page.screenshot({ path: 'test-results/arco-speaker-avatars-vector-dark.png', fullPage: true })
})
