#!/bin/bash
# Start meeting listener: recorder (system audio + mic mixed) | listen.py (Deepgram multi-speaker diarization) -> transcript.md
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TDIR="$HOME/.claude/meeting-transcripts"
mkdir -p "$TDIR"

if [ -f "$SKILL_DIR/.env" ]; then set -a; . "$SKILL_DIR/.env"; set +a; fi
if [ -z "$DEEPGRAM_API_KEY" ]; then
  echo "Missing DEEPGRAM_API_KEY (get a free key at https://deepgram.com, put it in $SKILL_DIR/.env)"
  exit 1
fi

# Build the recorder on first run (or after recorder.swift changes).
if [ ! -x "$SKILL_DIR/recorder" ]; then
  echo "Building recorder (first run)..."
  bash "$SKILL_DIR/bin/build.sh"
fi

# Stop any running instance first
pkill -f "skills/arco/recorder" 2>/dev/null
pkill -f "arco/listen" 2>/dev/null
sleep 1

MODE="${1:-both}"   # both (system + mic) | system | mic
TS=$(date +%Y%m%d-%H%M%S)
TRANSCRIPT="$TDIR/meeting-$TS.md"
ln -sf "$TRANSCRIPT" "$TDIR/current.md"
printf '# Meeting Transcript\n\n> Started: %s (live)\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$TRANSCRIPT"
rm -f "$TDIR/.log"

nohup bash -c "'$SKILL_DIR/recorder' '$MODE' | uv run --no-project --with websockets python '$SKILL_DIR/listen.py' '$TRANSCRIPT'" >>"$TDIR/.log" 2>&1 &

sleep 2
echo "Started (mode=$MODE, Deepgram multi-speaker diarization)"
echo "Transcript: $TRANSCRIPT"
echo "Assistant reads: $TDIR/current.md"
echo "Stop: bash $SKILL_DIR/bin/stop.sh"
echo "(First run: grant Screen Recording + Microphone in System Settings; do not mute system output)"
