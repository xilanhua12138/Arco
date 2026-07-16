#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_APP=${1:-"$ROOT/build/Arco.app"}
VERIFY="$ROOT/native/verify-native-boundaries.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/arco-boundaries.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

[ -d "$SOURCE_APP" ] || {
  echo "Boundary-test source app is missing: $SOURCE_APP" >&2
  exit 1
}

ARCO_BOUNDARY_SKIP_CODESIGN=0 "$VERIFY" "$SOURCE_APP" >/dev/null

fresh_app() {
  rm -rf "$TMP/Arco.app"
  ditto "$SOURCE_APP" "$TMP/Arco.app"
}

expect_rejected_without_signature_check() {
  label=$1
  if ARCO_BOUNDARY_SKIP_CODESIGN=1 "$VERIFY" "$TMP/Arco.app" >/dev/null 2>&1; then
    echo "FAIL: verifier accepted $label" >&2
    exit 1
  fi
}

fresh_app
rm "$TMP/Arco.app/Contents/Resources/native/arco-deepgram-transcriber"
expect_rejected_without_signature_check "an app missing a required cloud worker"

fresh_app
cp \
  "$TMP/Arco.app/Contents/Resources/native/arco-local-transcriber" \
  "$TMP/Arco.app/Contents/Resources/native/arco-deepgram-transcriber"
expect_rejected_without_signature_check "CoreML and FluidAudio leaking into a cloud worker"

fresh_app
cp /usr/bin/true "$TMP/Arco.app/Contents/MacOS/Arco"
chmod 755 "$TMP/Arco.app/Contents/MacOS/Arco"
expect_rejected_without_signature_check "a main executable without the embedded Rust C ABI"

fresh_app
rm "$TMP/Arco.app/Contents/Resources/native/recorder"
expect_rejected_without_signature_check "an app missing the recorder worker"

fresh_app
cp "$TMP/Arco.app/Contents/Resources/native/arco-deepgram-transcriber" \
  "$TMP/Arco.app/Contents/Resources/native/FluidVoice"
expect_rejected_without_signature_check "a FluidVoice binary in the application bundle"

fresh_app
touch "$TMP/Arco.app/Contents/Resources/index.html"
expect_rejected_without_signature_check "a browser frontend resource in the native bundle"

fresh_app
codesign --remove-signature "$TMP/Arco.app/Contents/MacOS/Arco"
if ARCO_BOUNDARY_SKIP_CODESIGN=0 "$VERIFY" "$TMP/Arco.app" >/dev/null 2>&1; then
  echo "FAIL: verifier accepted an invalid application signature" >&2
  exit 1
fi

echo "Native boundary verifier negative contracts passed"
