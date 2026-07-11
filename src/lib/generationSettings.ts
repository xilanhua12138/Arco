export const GENERATION_SETTINGS_STORAGE_KEY = 'arco.generationSettings'
export const MAX_GENERATION_PROMPT_CHARS = 8_000

export const DEFAULT_TITLE_PROMPT = `Create a concise, specific title for this meeting.
Use the main topic, decision, or outcome.
Write in the transcript's primary language and keep it under 8 words or 16 CJK characters.
Do not include dates, speaker labels, or words such as "meeting".
Return only the title.`

export const DEFAULT_SUMMARY_PROMPT = `Create a concise end-of-meeting note in the transcript's primary language.
Start with the outcome, then capture key decisions, unresolved questions, and action items.
Do not invent owners, commitments, or deadlines.
Leave out sections that were not discussed.
Ground every point in the transcript.`

export interface GenerationRule {
  enabled: boolean
  promptOverride: string | null
}

export interface GenerationSettings {
  title: GenerationRule
  summary: GenerationRule
}

export const defaultGenerationSettings = (): GenerationSettings => ({
  title: { enabled: true, promptOverride: null },
  summary: { enabled: true, promptOverride: null },
})

const parseRule = (value: unknown): GenerationRule | null => {
  if (!value || typeof value !== 'object') return null
  const candidate = value as Record<string, unknown>
  if (typeof candidate.enabled !== 'boolean') return null
  if (
    candidate.promptOverride !== null &&
    (
      typeof candidate.promptOverride !== 'string'
      || !candidate.promptOverride.trim()
      || [...candidate.promptOverride].length > MAX_GENERATION_PROMPT_CHARS
    )
  ) return null

  return {
    enabled: candidate.enabled,
    promptOverride: candidate.promptOverride as string | null,
  }
}

const parseGenerationSettings = (value: unknown): GenerationSettings | null => {
  if (!value || typeof value !== 'object') return null
  const candidate = value as Record<string, unknown>
  const title = parseRule(candidate.title)
  const summary = parseRule(candidate.summary)
  return title && summary ? { title, summary } : null
}

export function loadGenerationSettings(): GenerationSettings {
  try {
    const stored = window.localStorage.getItem(GENERATION_SETTINGS_STORAGE_KEY)
    if (!stored) return defaultGenerationSettings()
    return parseGenerationSettings(JSON.parse(stored)) ?? defaultGenerationSettings()
  } catch {
    return defaultGenerationSettings()
  }
}

export function saveGenerationSettings(settings: GenerationSettings): void {
  const parsed = parseGenerationSettings(settings)
  if (!parsed) throw new Error('Invalid generation settings.')
  window.localStorage.setItem(GENERATION_SETTINGS_STORAGE_KEY, JSON.stringify(parsed))
}
