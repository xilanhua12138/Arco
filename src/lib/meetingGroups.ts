import type { MeetingSummary } from '../types'

export interface MeetingGroup {
  id: 'today' | 'thisWeek' | 'earlier'
  label: 'Today' | 'This week' | 'Earlier'
  meetings: MeetingSummary[]
}

const groupLabel: Record<MeetingGroup['id'], MeetingGroup['label']> = {
  today: 'Today',
  thisWeek: 'This week',
  earlier: 'Earlier',
}

const startOfDay = (date: Date) => new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()

export function groupMeetings(meetings: MeetingSummary[], now = new Date()): MeetingGroup[] {
  const today = startOfDay(now)
  const sixDaysAgo = today - 6 * 24 * 60 * 60 * 1_000
  const buckets: Record<MeetingGroup['id'], MeetingSummary[]> = {
    today: [],
    thisWeek: [],
    earlier: [],
  }

  for (const meeting of meetings) {
    const startedAt = new Date(meeting.startedAt).getTime()
    if (Number.isNaN(startedAt)) {
      buckets.earlier.push(meeting)
    } else if (startedAt >= today) {
      buckets.today.push(meeting)
    } else if (startedAt >= sixDaysAgo) {
      buckets.thisWeek.push(meeting)
    } else {
      buckets.earlier.push(meeting)
    }
  }

  return (Object.keys(buckets) as MeetingGroup['id'][])
    .map((id) => ({ id, label: groupLabel[id], meetings: buckets[id] }))
    .filter((group) => group.meetings.length > 0)
}
