#!/bin/sh
# Optional developer helper. The desktop runtime also builds this source into
# its Application Support directory on first capture, so no binary is checked in.
set -eu

NATIVE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$NATIVE_DIR/.." && pwd)
AUDIO_RUNTIME_DIR="$ROOT/rust/arco-audio-rt"
AUDIO_RUNTIME_HEADER="$NATIVE_DIR/arco_audio_rt.h"
# AEC3 is built into the Rust static library; end users need no extra runtime.
for tool in meson ninja pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing recorder build tool: $tool (brew install meson ninja pkgconf)" >&2
    exit 1
  }
done
OUTPUT=${1:-"$NATIVE_DIR/recorder"}
case "$(uname -m)" in
  arm64)
    TARGET="arm64-apple-macosx14.0"
    RUST_TARGET="aarch64-apple-darwin"
    ;;
  x86_64)
    TARGET="x86_64-apple-macosx14.0"
    RUST_TARGET="x86_64-apple-darwin"
    ;;
  *) echo "Unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
esac

MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release --locked \
  --target "$RUST_TARGET" \
  --manifest-path "$AUDIO_RUNTIME_DIR/Cargo.toml"
AUDIO_RUNTIME_ARCHIVE="$AUDIO_RUNTIME_DIR/target/$RUST_TARGET/release/libarco_audio_rt.a"
if [ ! -f "$AUDIO_RUNTIME_ARCHIVE" ]; then
  echo "Rust audio runtime archive is missing: $AUDIO_RUNTIME_ARCHIVE" >&2
  exit 1
fi
if [ ! -f "$AUDIO_RUNTIME_HEADER" ]; then
  echo "Rust audio runtime header is missing: $AUDIO_RUNTIME_HEADER" >&2
  exit 1
fi

COMBINED_SOURCE=$(mktemp "${TMPDIR:-/tmp}/arco-recorder.XXXXXX.swift")
trap 'rm -f "$COMBINED_SOURCE"' EXIT HUP INT TERM
cat "$NATIVE_DIR/recorder.swift" "$NATIVE_DIR/AudioArchive.swift" > "$COMBINED_SOURCE"
swiftc -O "$COMBINED_SOURCE" \
  -import-objc-header "$AUDIO_RUNTIME_HEADER" \
  "$AUDIO_RUNTIME_ARCHIVE" \
  -o "$OUTPUT" \
  -target "$TARGET" \
  -framework ScreenCaptureKit \
  -framework AVFoundation \
  -framework AudioToolbox \
  -framework CoreAudio \
  -framework CoreMedia \
  -lc++ \
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
  cp "$NATIVE_DIR/AudioArchive.swift" "$RUNTIME_DIR/AudioArchive.swift"
  cp "$NATIVE_DIR/recorder.swift" "$RUNTIME_DIR/recorder.swift"
  cp "$NATIVE_DIR/recorder-Info.plist" "$RUNTIME_DIR/recorder-Info.plist"
  mkdir -p "$RUNTIME_DIR/licenses"
  cp "$NATIVE_DIR/licenses/WebRTC-AEC3.txt" "$RUNTIME_DIR/licenses/WebRTC-AEC3.txt"
  # The archive and header are build inputs, never runtime dependencies.
  rm -f "$RUNTIME_DIR/libarco_audio_rt.a" "$RUNTIME_DIR/arco_audio_rt.h"
fi
echo "Built and signed $OUTPUT"
