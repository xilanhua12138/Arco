#!/bin/bash
# Stop meeting listener
pkill -f "skills/arco/recorder" 2>/dev/null
pkill -f "arco/listen" 2>/dev/null
echo "Stopped."
TDIR="$HOME/.claude/meeting-transcripts"
[ -L "$TDIR/current.md" ] && echo "Transcript: $(readlink "$TDIR/current.md")"
