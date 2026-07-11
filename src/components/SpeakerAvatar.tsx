const avatarColors = [
  '#59c96b', '#8b7be4', '#ff6f7d', '#2e90fa',
  '#f59e0b', '#14b8a6', '#ec4899', '#06b6d4',
  '#84cc16', '#6366f1', '#f97316', '#34d399',
  '#ef4444', '#a78bfa', '#0ea5a8', '#eab308',
]

const avatarGlyph = (index: number) => {
  switch (index) {
    case 0:
      return (
        <g fill="currentColor">
          <path d="M9 1.2 12.8 5 9.8 7.7 7.5 5.4Z" />
          <path d="M16.8 9 13 12.8 10.3 9.8 12.6 7.5Z" />
          <path d="M9 16.8 5.2 13 8.2 10.3 10.5 12.6Z" />
          <path d="M1.2 9 5 5.2 7.7 8.2 5.4 10.5Z" />
        </g>
      )
    case 1:
      return (
        <g fill="currentColor">
          <rect x="7.2" y="1.2" width="3.6" height="6.2" rx="1.8" />
          <rect x="10.6" y="7.2" width="6.2" height="3.6" rx="1.8" />
          <rect x="7.2" y="10.6" width="3.6" height="6.2" rx="1.8" />
          <rect x="1.2" y="7.2" width="6.2" height="3.6" rx="1.8" />
          <circle cx="9" cy="9" r="1.25" />
        </g>
      )
    case 2:
      return (
        <g stroke="currentColor" strokeWidth="1.7" strokeLinecap="round">
          <path d="m6.8 6.8 4.4 4.4m0-4.4-4.4 4.4" />
          <circle cx="5" cy="5" r="2.5" fill="none" />
          <circle cx="13" cy="5" r="2.5" fill="none" />
          <circle cx="5" cy="13" r="2.5" fill="none" />
          <circle cx="13" cy="13" r="2.5" fill="none" />
        </g>
      )
    case 3:
      return (
        <g fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round">
          <path d="M9 2.1a6.9 6.9 0 0 1 4.9 2" />
          <path d="M15.9 9a6.9 6.9 0 0 1-2 4.9" />
          <path d="M9 15.9a6.9 6.9 0 0 1-4.9-2" />
          <path d="M2.1 9a6.9 6.9 0 0 1 2-4.9" />
        </g>
      )
    case 4:
      return (
        <g fill="currentColor">
          <circle cx="9" cy="4.8" r="2.35" />
          <circle cx="13.2" cy="9" r="2.35" />
          <circle cx="9" cy="13.2" r="2.35" />
          <circle cx="4.8" cy="9" r="2.35" />
        </g>
      )
    case 5:
      return (
        <g fill="currentColor">
          <path d="m9 1.4 3.2 3.2L9 7.8 5.8 4.6Z" />
          <path d="m16.6 9-3.2 3.2L10.2 9l3.2-3.2Z" />
          <path d="m9 16.6-3.2-3.2L9 10.2l3.2 3.2Z" />
          <path d="m1.4 9 3.2-3.2L7.8 9l-3.2 3.2Z" />
          <rect x="7.5" y="7.5" width="3" height="3" rx=".8" />
        </g>
      )
    case 6:
      return (
        <g fill="none" stroke="currentColor" strokeLinecap="round">
          <ellipse cx="9" cy="9" rx="7" ry="3.8" strokeWidth="2" />
          <ellipse cx="9" cy="9" rx="3.8" ry="7" strokeWidth="2" transform="rotate(42 9 9)" />
          <circle cx="9" cy="9" r="1.7" fill="currentColor" stroke="none" />
        </g>
      )
    case 7:
      return (
        <g fill="currentColor">
          <path d="m9 1.3 2.2 1.3v2.5L9 6.4 6.8 5.1V2.6Z" />
          <path d="m4.8 5.8 2.2 1.3v2.5l-2.2 1.3-2.2-1.3V7.1Z" />
          <path d="m13.2 5.8 2.2 1.3v2.5l-2.2 1.3L11 9.6V7.1Z" />
          <path d="m9 10.6 2.2 1.3v2.5L9 15.7l-2.2-1.3v-2.5Z" />
          <circle cx="9" cy="8.6" r="1.7" />
        </g>
      )
    case 8:
      return (
        <g fill="none" stroke="currentColor" strokeWidth="2.3" strokeLinecap="round" strokeLinejoin="round">
          <path d="M6.3 2.2H2.2v4.1M11.7 2.2h4.1v4.1M15.8 11.7v4.1h-4.1M6.3 15.8H2.2v-4.1" />
          <rect x="7.2" y="7.2" width="3.6" height="3.6" rx="1" fill="currentColor" stroke="none" />
        </g>
      )
    case 9:
      return (
        <g fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round">
          <path d="M1.5 9c2-3.4 4.5-5.1 7.5-5.1S14.5 5.6 16.5 9" strokeWidth="2.3" />
          <path d="M1.5 9c2 3.4 4.5 5.1 7.5 5.1s5.5-1.7 7.5-5.1" strokeWidth="2.3" />
          <circle cx="9" cy="9" r="2.2" fill="currentColor" stroke="none" />
        </g>
      )
    case 10:
      return (
        <g fill="currentColor">
          <ellipse cx="9" cy="5.1" rx="2.7" ry="4" />
          <ellipse cx="9" cy="5.1" rx="2.7" ry="4" transform="rotate(120 9 9)" />
          <ellipse cx="9" cy="5.1" rx="2.7" ry="4" transform="rotate(240 9 9)" />
        </g>
      )
    case 11:
      return (
        <g fill="currentColor">
          {Array.from({ length: 6 }, (_, rotation) => (
            <path key={rotation} d="M8.1 1.1h1.8l1.4 4.6L9 7.7 6.7 5.7Z" transform={`rotate(${rotation * 60} 9 9)`} />
          ))}
        </g>
      )
    case 12:
      return (
        <g fill="none" stroke="currentColor" strokeWidth="2.1">
          <rect x="2" y="2" width="6" height="6" rx="2" />
          <rect x="10" y="2" width="6" height="6" rx="2" />
          <rect x="2" y="10" width="6" height="6" rx="2" />
          <rect x="10" y="10" width="6" height="6" rx="2" />
          <path d="M8 5h2M5 8v2M13 8v2M8 13h2" />
        </g>
      )
    case 13:
      return (
        <g fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
          <path d="M2 5.2c2.1-2.2 4.3-2.2 6.4 0s4.3 2.2 7.6 0" />
          <path d="M2 9c2.1-2.2 4.3-2.2 6.4 0s4.3 2.2 7.6 0" />
          <path d="M2 12.8c2.1-2.2 4.3-2.2 6.4 0s4.3 2.2 7.6 0" />
        </g>
      )
    case 14:
      return (
        <g fill="currentColor">
          <path d="M9 1.2 12.2 6 9 7.8 5.8 6Z" />
          <path d="M16.8 9 12 12.2 10.2 9 12 5.8Z" />
          <path d="M9 16.8 5.8 12 9 10.2l3.2 1.8Z" />
          <path d="M1.2 9 6 5.8 7.8 9 6 12.2Z" />
        </g>
      )
    default:
      return (
        <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="m4 13 5-9 5 9ZM4 13h10" />
          <circle cx="9" cy="4" r="2" fill="currentColor" stroke="none" />
          <circle cx="4" cy="13" r="2" fill="currentColor" stroke="none" />
          <circle cx="14" cy="13" r="2" fill="currentColor" stroke="none" />
        </g>
      )
  }
}

export function SpeakerAvatar({ index }: { index: number }) {
  const normalizedIndex = ((index % 16) + 16) % 16
  return (
    <svg
      className="speaker-avatar"
      data-avatar-index={normalizedIndex}
      viewBox="0 0 18 18"
      aria-hidden="true"
      focusable="false"
      style={{ color: avatarColors[normalizedIndex] }}
    >
      <g transform="translate(2.88 .3) scale(.68 .62)">
        {avatarGlyph(normalizedIndex)}
      </g>
      <path d="M2.7 16.5c.55-3.45 3-5.2 6.3-5.2s5.75 1.75 6.3 5.2Z" fill="currentColor" />
    </svg>
  )
}
