import type { MeetingSummary } from '../types'

export interface MeetingStats {
  meetingCount: number
  totalMinutes: number
  transcriptLineCount: number
}

const durationMinutes = (label: string) => {
  const match = label.trim().match(/^(?:(\d+)\s*h(?:r|rs)?\s*)?(?:(\d+)\s*(?:m|min|mins|minutes?))?$/i)
  if (!match || (!match[1] && !match[2])) return 0
  return Number(match[1] ?? 0) * 60 + Number(match[2] ?? 0)
}

export function summarizeMeetings(meetings: MeetingSummary[]): MeetingStats {
  return meetings.reduce<MeetingStats>(
    (stats, meeting) => ({
      meetingCount: stats.meetingCount + 1,
      totalMinutes: stats.totalMinutes + durationMinutes(meeting.durationLabel),
      transcriptLineCount: stats.transcriptLineCount + meeting.utteranceCount,
    }),
    { meetingCount: 0, totalMinutes: 0, transcriptLineCount: 0 },
  )
}
