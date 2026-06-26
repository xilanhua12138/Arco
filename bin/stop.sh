#!/bin/bash
# Stop meeting listener
TDIR="$HOME/.claude/meeting-transcripts"
# Raise the stop flag BEFORE killing so the supervisor loop won't relaunch the
# pipeline in the gap between killing the recorder and killing the supervisor.
touch "$TDIR/.stop"
pkill -f "skills/arco/bin/supervise.sh" 2>/dev/null
pkill -f "skills/arco/recorder" 2>/dev/null
pkill -f "arco/listen" 2>/dev/null
echo "Stopped."
[ -L "$TDIR/current.md" ] && echo "Transcript: $(readlink "$TDIR/current.md")"
