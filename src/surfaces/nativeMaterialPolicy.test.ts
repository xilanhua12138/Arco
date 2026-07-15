import { describe, expect, it } from 'vitest'

const stylesheets = import.meta.glob('../**/*.css', {
  eager: true,
  import: 'default',
  query: '?raw',
}) as Record<string, string>

const readHexToken = (stylesheet: string, token: string) => {
  const match = stylesheet.match(new RegExp(`${token}\\s*:\\s*(#[0-9a-f]{6})`, 'i'))
  expect(match, `${token} must use an opaque six-digit color`).not.toBeNull()
  return match![1]
}

const contrastRatio = (foreground: string, background: string) => {
  const luminance = (color: string) => {
    const channels = color.slice(1).match(/.{2}/g)!.map((channel) => {
      const value = Number.parseInt(channel, 16) / 255
      return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
    })
    return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
  }
  const lighter = Math.max(luminance(foreground), luminance(background))
  const darker = Math.min(luminance(foreground), luminance(background))
  return (lighter + 0.05) / (darker + 0.05)
}

describe('native desktop material policy', () => {
  it('keeps every surface free of CSS backdrop filters so Liquid Glass is rendered exactly once', () => {
    for (const [path, stylesheet] of Object.entries(stylesheets)) {
      expect(stylesheet, path).not.toMatch(/backdrop-filter\s*:/)
    }
  })

  it('keeps AppKit responsible for glass while preserving Arco ambient color and dot artwork', () => {
    const allStyles = Object.values(stylesheets).join('\n')

    for (const [path, stylesheet] of Object.entries(stylesheets)) {
      expect(stylesheet, path).not.toMatch(/--glass-(?:sheen|chroma)/)
    }

    expect(allStyles).toMatch(/--stage-ambient-wash\s*:/)
    expect(allStyles).toMatch(/--stage-matrix-wash\s*:/)
    expect(allStyles).toMatch(/--stage-dot\s*:/)
    expect(allStyles).toMatch(/\.page-stage::before\s*{[^}]*var\(--stage-ambient-wash\)/s)
    expect(allStyles).toMatch(/\.page-stage::after\s*{[^}]*radial-gradient\(var\(--stage-dot\)/s)
  })

  it('keeps the WebView content canvas opaque while the native shell owns translucency', () => {
    const allStyles = Object.values(stylesheets).join('\n')

    expect(allStyles).toMatch(/--surface-stage-base\s*:\s*#[0-9a-f]{6}/i)
    expect(allStyles).toMatch(/\.app-shell\s*{[^}]*background:\s*var\(--surface-stage-base\)/s)
    expect(allStyles).toMatch(/\.page-stage\s*{[^}]*background-color:\s*var\(--surface-stage-base\)/s)
  })

  it('keeps shared history and notes text opaque and readable on the document surface', () => {
    const indexStyles = Object.entries(stylesheets).find(([path]) => path.endsWith('/index.css'))?.[1]
    expect(indexStyles, 'index.css must be included in the material policy').toBeDefined()

    const document = readHexToken(indexStyles!, '--surface-document')
    const ink = readHexToken(indexStyles!, '--ink')
    const muted = readHexToken(indexStyles!, '--ink-muted')
    const faint = readHexToken(indexStyles!, '--ink-faint')

    expect(contrastRatio(ink, document)).toBeGreaterThanOrEqual(9)
    expect(contrastRatio(muted, document)).toBeGreaterThanOrEqual(5.5)
    expect(contrastRatio(faint, document)).toBeGreaterThanOrEqual(4.5)
  })

  it('defines compact macOS interaction timing and a reduced-motion fallback', () => {
    const allStyles = Object.values(stylesheets).join('\n')

    expect(allStyles).toMatch(/--motion-press\s*:\s*110ms/)
    expect(allStyles).toMatch(/--motion-state\s*:\s*220ms/)
    expect(allStyles).toMatch(/@keyframes macos-content-in\s*{\s*from\s*{\s*opacity:\s*[^;}]+;?\s*}\s*to\s*{\s*opacity:\s*[^;}]+;?\s*}\s*}/)
    expect(allStyles).toMatch(/@keyframes macos-popover-in/)
    expect(allStyles).toMatch(/@media \(prefers-reduced-motion: reduce\)/)
  })

  it('keeps the notes toolbar controls on one 40 point macOS alignment line', () => {
    const allStyles = Object.values(stylesheets).join('\n')

    expect(allStyles).toMatch(/\.note-format-toolbar-surface\s*{[^}]*min-height:\s*40px/s)
    expect(allStyles).toMatch(/\.note-format-toolbar-surface\s*{[^}]*width:\s*122px/s)
    expect(allStyles).toMatch(/\.notes-search\s*{[^}]*height:\s*40px/s)
    expect(allStyles).toMatch(/\.notes-new-button\s*{[^}]*height:\s*40px/s)
    expect(allStyles).toMatch(/\.notes-editor-command-bar \.note-format-toolbar-surface\s*{[^}]*top:\s*50%[^}]*transform:\s*translate\(-50%,\s*-50%\)/s)
    expect(allStyles).toMatch(/\.notes-editor-command-bar\s*{[^}]*height:\s*58px[^}]*align-items:\s*center[^}]*padding:\s*0 14px/s)
    expect(allStyles).toMatch(/\.notes-index-toggle\s*{[^}]*top:\s*9px/s)
    expect(allStyles).toMatch(/\.note-meeting-control\s*{[^}]*display:\s*inline-flex[^}]*gap:\s*4px/s)
  })
})
