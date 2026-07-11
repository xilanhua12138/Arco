import { describe, expect, it } from 'vitest'
import { groupMeetings } from './meetingGroups'
import type { MeetingSummary } from '../types'

const meeting = (id: string, startedAt: string): MeetingSummary => ({
  id,
  title: id,
  startedAt,
  durationLabel: '1 min',
  preview: '',
  path: `/tmp/${id}.md`,
  utteranceCount: 1,
  isLive: false,
  source: 'arco',
  generatedSummary: null,
  titleGenerationStatus: 'idle',
  summaryGenerationStatus: 'idle',
})

describe('groupMeetings', () => {
  const now = new Date('2026-07-10T18:00:00+08:00')

  it('separates today, the previous six days, and older meetings', () => {
    const groups = groupMeetings(
      [
        meeting('today', '2026-07-10T00:00:00+08:00'),
        meeting('week', '2026-07-04T23:59:59+08:00'),
        meeting('older', '2026-07-03T23:59:59+08:00'),
      ],
      now,
    )

    expect(groups.map(({ label }) => label)).toEqual(['Today', 'This week', 'Earlier'])
    expect(groups[0].meetings.map(({ id }) => id)).toEqual(['today'])
    expect(groups[1].meetings.map(({ id }) => id)).toEqual(['week'])
    expect(groups[2].meetings.map(({ id }) => id)).toEqual(['older'])
  })

  it('puts malformed legacy dates in Earlier instead of dropping history', () => {
    const groups = groupMeetings([meeting('legacy-bad-date', 'not-a-date')], now)

    expect(groups).toHaveLength(1)
    expect(groups[0].label).toBe('Earlier')
    expect(groups[0].meetings[0].id).toBe('legacy-bad-date')
  })

  it('returns no empty group shells for an empty history', () => {
    expect(groupMeetings([], now)).toEqual([])
  })
})
