#!/bin/bash
# Compile the Swift recorder and ad-hoc sign it.
# Re-run this after editing recorder.swift, or on first checkout.
set -e
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

swiftc "$SKILL_DIR/recorder.swift" -o "$SKILL_DIR/recorder" \
  -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia

# Ad-hoc signature keeps the Screen Recording / Microphone grant stable across runs.
codesign --force --sign - "$SKILL_DIR/recorder"

echo "Built $SKILL_DIR/recorder"
echo "First run will prompt for Screen Recording + Microphone permission."
