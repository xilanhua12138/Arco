import { describe, expect, it } from 'vitest'
import { resolveSurface } from './surfaceRoute'

describe('surface routing', () => {
  it('routes the two utility windows without mounting the full desktop app', () => {
    expect(resolveSurface('?surface=hud')).toBe('hud')
    expect(resolveSurface('?demo=1&surface=agent-overlay')).toBe('agent-overlay')
  })

  it('falls back safely to the main surface for missing or unknown values', () => {
    expect(resolveSurface('')).toBe('main')
    expect(resolveSurface('?surface=unknown')).toBe('main')
  })
})
