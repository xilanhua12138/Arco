#!/bin/bash
# Start meeting listener: recorder (system audio + mic mixed) | listen.py (Deepgram multi-speaker diarization) -> transcript.md
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TDIR="$HOME/.claude/meeting-transcripts"
mkdir -p "$TDIR"

MODE="${1:-both}"   # both (system + mic) | system | mic

if [ "$MODE" = "both" ] || [ "$MODE" = "mic" ]; then
  if bash "$SKILL_DIR/bin/mic-id.sh" --write-env --quiet; then
    echo "Default microphone ID refreshed."
  else
    echo "Warning: could not resolve default microphone ID; continuing with system default input."
  fi
fi

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

# Stop any running instance first. Raise the .stop flag so a live supervisor
# loop won't relaunch the pipeline while we're tearing it down, then clear it.
touch "$TDIR/.stop"
pkill -f "skills/arco/bin/supervise.sh" 2>/dev/null
pkill -f "skills/arco/recorder" 2>/dev/null
pkill -f "arco/listen" 2>/dev/null
sleep 1
rm -f "$TDIR/.stop"

TS=$(date +%Y%m%d-%H%M%S)
TRANSCRIPT="$TDIR/transcript-$TS.md"
ln -sf "$TRANSCRIPT" "$TDIR/current.md"
printf '# Meeting Transcript\n\n> Started: %s (live)\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$TRANSCRIPT"
rm -f "$TDIR/.log"

# Run under a supervisor so a dying recorder (e.g. Bluetooth mic switch) or a
# dropped pipeline auto-restarts; listen.py separately auto-reconnects Deepgram.
nohup bash "$SKILL_DIR/bin/supervise.sh" "$MODE" "$TRANSCRIPT" >>"$TDIR/.log" 2>&1 &

sleep 2
echo "Started (mode=$MODE, Deepgram multi-speaker diarization)"
echo "Transcript: $TRANSCRIPT"
echo "Assistant reads: $TDIR/current.md"
echo "Stop: bash $SKILL_DIR/bin/stop.sh"
echo "(First run: grant Screen Recording + Microphone in System Settings; do not mute system output)"
