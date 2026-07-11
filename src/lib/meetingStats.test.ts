import { describe, expect, it } from 'vitest'
import { summarizeMeetings } from './meetingStats'
import type { MeetingSummary } from '../types'

const meeting = (id: string, durationLabel: string, utteranceCount: number): MeetingSummary => ({
  id,
  title: id,
  startedAt: '2026-07-11T10:00:00+08:00',
  durationLabel,
  preview: '',
  path: `/tmp/${id}.md`,
  utteranceCount,
  isLive: false,
  source: 'arco',
  generatedSummary: null,
  titleGenerationStatus: 'idle',
  summaryGenerationStatus: 'idle',
})

describe('summarizeMeetings', () => {
  it('totals native and legacy duration labels without inventing values for malformed labels', () => {
    const stats = summarizeMeetings([
      meeting('native-short', '2m', 3),
      meeting('native-long', '1h 05m', 12),
      meeting('legacy', '38 min', 8),
      meeting('malformed', 'Live', 5),
    ])

    expect(stats).toEqual({ meetingCount: 4, totalMinutes: 105, transcriptLineCount: 28 })
  })

  it('returns exact zero values for an empty history', () => {
    expect(summarizeMeetings([])).toEqual({ meetingCount: 0, totalMinutes: 0, transcriptLineCount: 0 })
  })
})
