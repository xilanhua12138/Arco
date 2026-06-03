#!/bin/bash
# Resolve the current macOS default microphone and optionally persist its ID.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$SKILL_DIR/.env"
WRITE_ENV=0
QUIET=0

for arg in "$@"; do
  case "$arg" in
    --write-env) WRITE_ENV=1 ;;
    --quiet) QUIET=1 ;;
    *)
      echo "Usage: $0 [--write-env] [--quiet]"
      exit 2
      ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Arco microphone discovery is macOS-only."
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Missing swiftc; install Xcode Command Line Tools."
  exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cat >"$TMPDIR/default-mic.swift" <<'SWIFT'
import AVFoundation
import Foundation

guard let device = AVCaptureDevice.default(for: .audio) else {
    FileHandle.standardError.write("No default microphone device found\n".data(using: .utf8)!)
    exit(1)
}

print("id=\(device.uniqueID)")
print("name=\(device.localizedName)")
SWIFT

swiftc "$TMPDIR/default-mic.swift" -o "$TMPDIR/default-mic"
OUT="$("$TMPDIR/default-mic")"
MIC_ID="$(printf '%s\n' "$OUT" | sed -n 's/^id=//p' | head -1)"
MIC_NAME="$(printf '%s\n' "$OUT" | sed -n 's/^name=//p' | head -1)"

if [ -z "$MIC_ID" ]; then
  echo "Could not resolve default microphone ID."
  exit 1
fi

quote_value() {
  printf "'"
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

if [ "$WRITE_ENV" -eq 1 ]; then
  touch "$ENV_FILE"
  TMP_ENV="$(mktemp)"
  grep -v -E '^(ARCO_MIC_DEVICE_ID|ARCO_MIC_DEVICE_NAME)=' "$ENV_FILE" >"$TMP_ENV" || true
  {
    printf "ARCO_MIC_DEVICE_ID="
    quote_value "$MIC_ID"
    printf "\n"
    printf "ARCO_MIC_DEVICE_NAME="
    quote_value "$MIC_NAME"
    printf "\n"
  } >>"$TMP_ENV"
  mv "$TMP_ENV" "$ENV_FILE"
fi

if [ "$QUIET" -eq 0 ]; then
  echo "Default microphone: $MIC_NAME"
  echo "ARCO_MIC_DEVICE_ID=$MIC_ID"
fi
