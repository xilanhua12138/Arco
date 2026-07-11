import { describe, expect, it } from 'vitest'
import {
  DEFAULT_SUMMARY_PROMPT,
  DEFAULT_TITLE_PROMPT,
  GENERATION_SETTINGS_STORAGE_KEY,
  MAX_GENERATION_PROMPT_CHARS,
  defaultGenerationSettings,
  loadGenerationSettings,
  saveGenerationSettings,
} from './generationSettings'

describe('generation settings', () => {
  it('uses safe enabled defaults and falls back when storage is missing, malformed, or invalid', () => {
    const defaults = {
      title: { enabled: true, promptOverride: null },
      summary: { enabled: true, promptOverride: null },
    }

    expect(defaultGenerationSettings()).toEqual(defaults)
    expect(loadGenerationSettings()).toEqual(defaults)

    window.localStorage.setItem(GENERATION_SETTINGS_STORAGE_KEY, '{not json')
    expect(loadGenerationSettings()).toEqual(defaults)

    window.localStorage.setItem(GENERATION_SETTINGS_STORAGE_KEY, JSON.stringify({
      title: { enabled: 'yes', promptOverride: null },
      summary: { enabled: true, promptOverride: '' },
    }))
    expect(loadGenerationSettings()).toEqual(defaults)
  })

  it('persists independent title and summary rules without rewriting prompt text', () => {
    const settings = {
      title: { enabled: false, promptOverride: 'Keep the title literal.' },
      summary: { enabled: true, promptOverride: 'Lead with the decision.\nNever invent an owner.' },
    }

    saveGenerationSettings(settings)

    expect(JSON.parse(window.localStorage.getItem(GENERATION_SETTINGS_STORAGE_KEY) ?? '')).toEqual(settings)
    expect(loadGenerationSettings()).toEqual(settings)
  })

  it('ships distinct grounded defaults for a title and an end-of-meeting note', () => {
    expect(DEFAULT_TITLE_PROMPT).toContain('under 8 words')
    expect(DEFAULT_TITLE_PROMPT).toContain('Return only the title')
    expect(DEFAULT_SUMMARY_PROMPT).toContain('key decisions')
    expect(DEFAULT_SUMMARY_PROMPT).toContain('Do not invent owners')
    expect(DEFAULT_SUMMARY_PROMPT).not.toBe(DEFAULT_TITLE_PROMPT)
  })

  it('rejects an oversized override without replacing the last valid settings', () => {
    expect(MAX_GENERATION_PROMPT_CHARS).toBe(8_000)
    const valid = {
      title: { enabled: true, promptOverride: 'Use the clearest decision.' },
      summary: { enabled: true, promptOverride: null },
    }
    saveGenerationSettings(valid)

    expect(() => saveGenerationSettings({
      ...valid,
      title: { enabled: true, promptOverride: '界'.repeat(8_001) },
    })).toThrow('Invalid generation settings.')
    expect(loadGenerationSettings()).toEqual(valid)
  })
})
