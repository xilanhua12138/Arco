#!/bin/bash
# Incrementally read the transcript: emit only what was appended since last read.
# Uses a byte-offset pointer so Claude doesn't re-ingest the whole file each time.
#   read.sh           -> print new bytes since last read, advance pointer
#   read.sh --reset   -> forget pointer, then print everything from the start
#   read.sh --all     -> print whole file without touching the pointer
TDIR="$HOME/.claude/meeting-transcripts"
CUR="$TDIR/current.md"
POS_FILE="$TDIR/.read-pos"

# Resolve the symlink so the pointer is tied to the real session file.
REAL="$(readlink "$CUR" 2>/dev/null || true)"
[ -z "$REAL" ] && REAL="$CUR"
if [ ! -f "$REAL" ]; then
  echo "(no transcript yet)"
  exit 0
fi

if [ "$1" = "--all" ]; then
  cat "$REAL"
  exit 0
fi
if [ "$1" = "--reset" ]; then
  rm -f "$POS_FILE"
fi

LAST_FILE=""; LAST_POS=0
if [ -f "$POS_FILE" ]; then
  LAST_FILE="$(sed -n '1p' "$POS_FILE")"
  LAST_POS="$(sed -n '2p' "$POS_FILE")"
fi
# New session (file changed) or truncated/rotated -> start from the beginning.
case "$LAST_POS" in (*[!0-9]*|"") LAST_POS=0;; esac
[ "$LAST_FILE" != "$REAL" ] && LAST_POS=0

SIZE=$(wc -c < "$REAL" 2>/dev/null | tr -d ' ')
SIZE=${SIZE:-0}
[ "$LAST_POS" -gt "$SIZE" ] && LAST_POS=0

if [ "$LAST_POS" -lt "$SIZE" ]; then
  tail -c +$((LAST_POS + 1)) "$REAL"
else
  echo "(no new lines since last read)"
fi

printf '%s\n%s\n' "$REAL" "$SIZE" > "$POS_FILE"
