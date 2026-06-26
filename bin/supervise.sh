#!/bin/bash
# Supervisor for the meeting listener pipeline: recorder | listen.py.
#
# listen.py self-heals dropped Deepgram WebSockets on its own. This loop handles
# the OTHER failure mode: the `recorder` process dying mid-meeting (e.g. a
# Bluetooth mic such as AirPods switching/sleeping changes the input device id),
# which sends stdin EOF to listen.py and ends the pipeline cleanly. As long as
# the user has not asked to stop (no .stop flag), relaunch the pipeline so the
# meeting keeps being transcribed without manual restarts.
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="$1"
TRANSCRIPT="$2"
TDIR="$HOME/.claude/meeting-transcripts"
STOPFLAG="$TDIR/.stop"

while [ ! -f "$STOPFLAG" ]; do
  "$SKILL_DIR/recorder" "$MODE" \
    | uv run --no-project --with websockets python "$SKILL_DIR/listen.py" "$TRANSCRIPT"
  # Pipeline exited. If the user asked to stop, leave. Otherwise the recorder
  # (or the whole pipe) died unexpectedly -- restart after a short pause.
  [ -f "$STOPFLAG" ] && break
  echo "[supervisor $(date '+%H:%M:%S')] pipeline exited; restarting in 2s" >> "$TDIR/.log"
  sleep 2
done
