#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP=${1:-"$ROOT/build/Arco.app"}
MAIN="$APP/Contents/MacOS/Arco"
NATIVE="$APP/Contents/Resources/native"
LOCAL_WORKER="$NATIVE/arco-local-transcriber"
SKIP_CODESIGN=${ARCO_BOUNDARY_SKIP_CODESIGN:-0}

fail() {
  echo "$1" >&2
  exit 1
}

require_executable() {
  [ -x "$1" ] || fail "Required native executable is missing: $1"
}

reject_links() {
  binary=$1
  pattern=$2
  message=$3
  if otool -L "$binary" | grep -E "$pattern" >/dev/null; then
    fail "$message: $binary"
  fi
}

require_link() {
  binary=$1
  pattern=$2
  message=$3
  otool -L "$binary" | grep -E "$pattern" >/dev/null || fail "$message: $binary"
}

signed_identifier() {
  codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^Identifier=//p' | head -n 1
}

verify_signature() {
  binary=$1
  expected=$2
  codesign --verify --strict "$binary" >/dev/null 2>&1 || fail "Invalid code signature: $binary"
  actual=$(signed_identifier "$binary")
  [ "$actual" = "$expected" ] || fail "Unexpected signing identifier for $binary: $actual"
}

require_executable "$MAIN"

HELPERS="recorder arco-gpt-live arco-deepgram-transcriber arco-elevenlabs-transcriber arco-doubao-transcriber arco-local-transcriber"
for helper in $HELPERS; do
  require_executable "$NATIVE/$helper"
done
if [ -e "$NATIVE/libarco_audio_rt.a" ] || [ -e "$NATIVE/arco_audio_rt.h" ]; then
  fail "Recorder build inputs escaped into the application runtime payload"
fi
if find "$NATIVE" -maxdepth 1 -type f \( -name 'libarco_audio_rt*.dylib' -o -name 'libarco_audio_rt*.so' \) -print -quit | grep -q .; then
  fail "The recorder audio runtime must be statically linked"
fi

case "$(file -b "$MAIN")" in
  *Mach-O*) ;;
  *) fail "The application entry point is not a Mach-O executable: $MAIN" ;;
esac

MAIN_ARCHS=$(lipo -archs "$MAIN")
[ -n "$MAIN_ARCHS" ] || fail "Could not determine application architectures"
for helper in $HELPERS; do
  binary="$NATIVE/$helper"
  case "$(file -b "$binary")" in
    *Mach-O*) ;;
    *) fail "Native helper is not a Mach-O executable: $binary" ;;
  esac
  archs=$(lipo -archs "$binary")
  [ "$archs" = "$MAIN_ARCHS" ] || fail "Architecture mismatch: Arco=$MAIN_ARCHS, $helper=$archs"
done

# The UI process owns presentation and the Rust control plane only. Capture and
# inference frameworks are confined to killable helper processes.
reject_links \
  "$MAIN" \
  'WebKit|JavaScriptCore|CoreML|AVFoundation|AVFAudio|ScreenCaptureKit|AudioToolbox|CoreAudio' \
  "The SwiftUI process links a browser, capture, or local-model framework"

for helper in arco-deepgram-transcriber arco-elevenlabs-transcriber arco-doubao-transcriber; do
  reject_links \
    "$NATIVE/$helper" \
    'WebKit|JavaScriptCore|CoreML|AVFoundation|AVFAudio|ScreenCaptureKit|AudioToolbox|CoreAudio' \
    "A cloud transcriber links a browser, capture, or local-model framework"
done

require_link "$NATIVE/recorder" 'ScreenCaptureKit.framework' "The recorder is missing ScreenCaptureKit"
require_link "$NATIVE/recorder" 'AVFoundation.framework' "The recorder is missing AVFoundation"
reject_links "$NATIVE/recorder" 'CoreML.framework' "The recorder must not load local models"
reject_links "$NATIVE/recorder" 'libarco_audio_rt' "The recorder dynamically links its Rust audio runtime"
if otool -l "$NATIVE/recorder" | grep -q 'LC_RPATH'; then
  fail "The recorder must not depend on a runtime search path"
fi
RECORDER_SYMBOLS=$(nm -gU "$NATIVE/recorder" 2>/dev/null) || fail "Could not inspect the recorder symbol table"
for symbol in \
  _arco_audio_rt_source_create \
  _arco_audio_rt_push_planar_f32 \
  _arco_audio_rt_push_audio_buffer_list \
  _arco_audio_rt_consumer_drain_i16 \
  _arco_audio_rt_io_proc
do
  printf '%s\n' "$RECORDER_SYMBOLS" | grep -q " $symbol$" || fail "Recorder is missing statically linked Rust symbol $symbol"
done
require_link "$LOCAL_WORKER" 'CoreML.framework' "CoreML must remain in the local-transcriber worker"
require_link "$LOCAL_WORKER" 'AVFAudio.framework' "The local-transcriber worker is missing its audio runtime"
reject_links "$LOCAL_WORKER" 'WebKit|JavaScriptCore|ScreenCaptureKit' "The local worker links an unrelated UI or capture framework"

for binary in "$MAIN" "$NATIVE/recorder" "$NATIVE/arco-deepgram-transcriber" \
  "$NATIVE/arco-gpt-live" "$NATIVE/arco-elevenlabs-transcriber" "$NATIVE/arco-doubao-transcriber" "$LOCAL_WORKER"; do
  if strings "$binary" | grep -F 'FluidVoice' >/dev/null; then
    fail "FluidVoice must not be embedded in any Arco executable: $binary"
  fi
done

for binary in "$MAIN" "$NATIVE/recorder" "$NATIVE/arco-deepgram-transcriber" \
  "$NATIVE/arco-gpt-live" "$NATIVE/arco-elevenlabs-transcriber" "$NATIVE/arco-doubao-transcriber"; do
  if strings "$binary" | grep -F 'FluidAudio' >/dev/null; then
    fail "FluidAudio escaped the isolated local-transcriber worker: $binary"
  fi
done
strings "$LOCAL_WORKER" | grep -F 'FluidAudio' >/dev/null || fail "The packaged local worker is missing FluidAudio"

if find "$APP/Contents" -type f \( \
  -iname '*FluidVoice*' -o \
  -name '*.html' -o -name '*.htm' -o -name '*.js' -o -name '*.jsx' -o -name '*.tsx' \
\) -print -quit | grep -q .; then
  fail "The native application bundle contains FluidVoice or browser-frontend resources"
fi

# Inspect the final executable, not a possibly stale archive. These definitions
# prove that the Rust static library was actually linked into this exact app.
MAIN_SYMBOLS=$(nm -gU "$MAIN" 2>/dev/null) || fail "Could not inspect the final Arco symbol table"
for symbol in \
  _arco_runtime_create \
  _arco_runtime_dispatch \
  _arco_runtime_destroy \
  _arco_string_free \
  _arco_last_error_message
do
  printf '%s\n' "$MAIN_SYMBOLS" | grep -q " $symbol$" || fail "Final Arco executable is missing Rust C ABI symbol $symbol"
done

UNRESOLVED_SYMBOLS=$(nm -u "$MAIN" 2>/dev/null) || fail "Could not inspect unresolved Arco symbols"
if printf '%s\n' "$UNRESOLVED_SYMBOLS" | grep -E ' _?arco_' >/dev/null; then
  fail "Final Arco executable still has unresolved Rust C ABI symbols"
fi

grep -Eq 'crate-type[[:space:]]*=[[:space:]]*\[[^]]*"staticlib"' \
  "$ROOT/rust/arco-core/Cargo.toml" || fail "arco-core is no longer configured as a Rust staticlib"
if grep -Eq '^name = "(tauri|tauri-runtime|wry|tao)"$' "$ROOT/rust/arco-core/Cargo.lock"; then
  fail "A Tauri/WebView runtime re-entered the Rust dependency graph"
fi

if [ "$SKIP_CODESIGN" != "1" ]; then
  verify_signature "$MAIN" app.arco.desktop
  verify_signature "$NATIVE/recorder" app.arco.desktop.recorder
  verify_signature "$NATIVE/arco-gpt-live" app.arco.desktop.gpt-live
  verify_signature "$NATIVE/arco-deepgram-transcriber" app.arco.desktop.deepgram-transcriber
  verify_signature "$NATIVE/arco-elevenlabs-transcriber" app.arco.desktop.elevenlabs-transcriber
  verify_signature "$NATIVE/arco-doubao-transcriber" app.arco.desktop.doubao-transcriber
  verify_signature "$LOCAL_WORKER" app.arco.desktop.local-transcriber
  codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || fail "The application bundle signature is invalid"
fi

echo "SwiftUI / embedded Rust staticlib / isolated model-worker boundary passed"
