#!/bin/bash
# Show meeting listener status + recent transcript
TDIR="$HOME/.claude/meeting-transcripts"
# Prefer the supervisor: the recorder briefly disappears during a restart, but
# as long as the supervisor is alive the listening task is still active.
if pgrep -f "skills/arco/bin/supervise.sh" >/dev/null || pgrep -f "skills/arco/recorder" >/dev/null; then
  echo "Listening"
else
  echo "Not running"
fi
if [ -L "$TDIR/current.md" ]; then
  echo "Transcript: $(readlink "$TDIR/current.md")"
  echo "Lines: $(grep -c 'Speaker' "$TDIR/current.md" 2>/dev/null || echo 0)"
  echo "--- recent ---"
  tail -8 "$TDIR/current.md" 2>/dev/null
fi
