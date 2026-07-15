import { describe, expect, it } from 'vitest'

const stylesheets = import.meta.glob('../**/*.css', {
  eager: true,
  import: 'default',
  query: '?raw',
}) as Record<string, string>

describe('native desktop material policy', () => {
  it('keeps every surface free of CSS backdrop filters so Liquid Glass is rendered exactly once', () => {
    for (const [path, stylesheet] of Object.entries(stylesheets)) {
      expect(stylesheet, path).not.toMatch(/backdrop-filter\s*:/)
    }
  })

  it('does not paint simulated lensing, chroma, or texture over AppKit Liquid Glass', () => {
    for (const [path, stylesheet] of Object.entries(stylesheets)) {
      expect(stylesheet, path).not.toMatch(/--glass-(?:sheen|chroma)/)
      expect(stylesheet, path).not.toMatch(/--stage-(?:ambient-wash|matrix-wash|dot)/)
    }
  })
})
