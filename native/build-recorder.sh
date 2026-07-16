#!/bin/sh
# Optional developer helper. The desktop runtime also builds this source into
# its Application Support directory on first capture, so no binary is checked in.
set -eu

NATIVE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=${1:-"$NATIVE_DIR/recorder"}
case "$(uname -m)" in
  arm64) TARGET="arm64-apple-macosx14.0" ;;
  x86_64) TARGET="x86_64-apple-macosx14.0" ;;
  *) echo "Unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
esac

swiftc "$NATIVE_DIR/recorder.swift" -o "$OUTPUT" \
  -target "$TARGET" \
  -framework ScreenCaptureKit \
  -framework AVFoundation \
  -framework AudioToolbox \
  -framework CoreAudio \
  -framework CoreMedia \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker "$NATIVE_DIR/recorder-Info.plist"
"$NATIVE_DIR/codesign-local.sh" "$OUTPUT" app.arco.desktop

# The native app packages this staging directory as `Resources/native`.
# Keeping the runtime payload separate avoids shipping tests, caches, and
# build helpers with the application.
if [ "$OUTPUT" = "$NATIVE_DIR/recorder" ]; then
  RUNTIME_DIR="$NATIVE_DIR/runtime"
  mkdir -p "$RUNTIME_DIR"
  cp "$OUTPUT" "$RUNTIME_DIR/recorder"
  cp "$NATIVE_DIR/recorder.swift" "$RUNTIME_DIR/recorder.swift"
  cp "$NATIVE_DIR/recorder-Info.plist" "$RUNTIME_DIR/recorder-Info.plist"
fi
echo "Built and signed $OUTPUT"
