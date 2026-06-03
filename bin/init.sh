#!/bin/bash
# Prepare Arco for first use: check local tools, create .env if needed,
# prefetch Python deps, build/sign the recorder, and verify Deepgram config.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TDIR="${ARCO_TRANSCRIPT_DIR:-$HOME/.claude/meeting-transcripts}"
ENV_FILE="$SKILL_DIR/.env"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Arco is macOS-only because it uses ScreenCaptureKit."
  exit 1
fi

missing=()
for cmd in swiftc codesign uv; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing required command(s): ${missing[*]}"
  echo "Install Xcode Command Line Tools for swiftc/codesign, and install uv for Python deps."
  echo "Xcode tools: xcode-select --install"
  echo "uv: https://docs.astral.sh/uv/"
  exit 1
fi

mkdir -p "$TDIR"

if [ ! -f "$ENV_FILE" ]; then
  cp "$SKILL_DIR/.env.example" "$ENV_FILE"
  echo "Created $ENV_FILE from .env.example"
fi

echo "Preparing Python dependency: websockets"
uv run --no-project --with websockets python -c "import websockets; print('websockets ready')"

if [ ! -x "$SKILL_DIR/recorder" ] || [ "$SKILL_DIR/recorder.swift" -nt "$SKILL_DIR/recorder" ]; then
  bash "$SKILL_DIR/bin/build.sh"
else
  echo "Recorder already built: $SKILL_DIR/recorder"
fi

set -a
. "$ENV_FILE"
set +a

if [ -z "${DEEPGRAM_API_KEY:-}" ]; then
  echo
  echo "Initialization incomplete: add DEEPGRAM_API_KEY to $ENV_FILE, then rerun:"
  echo "  bash $SKILL_DIR/bin/init.sh"
  echo
  echo "After initialization passes, start listening with:"
  echo "  bash $SKILL_DIR/bin/start.sh both"
  exit 2
fi

echo "Deepgram API key found."
echo "Initialization complete."
echo "Start listening with:"
echo "  bash $SKILL_DIR/bin/start.sh both"
