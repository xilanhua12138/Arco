#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROFILE=${ARCO_BUILD_PROFILE:-release}
SWIFT_CONFIGURATION=release
if [ "$PROFILE" = "debug" ]; then
  SWIFT_CONFIGURATION=debug
fi

RUST_TARGET_DIR="$ROOT/rust/arco-core/target"
SWIFT_PACKAGE="$ROOT/macos/ArcoNativeUI"
APP="$ROOT/build/Arco.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

"$ROOT/native/verify-native-ui.sh"

if [ "$PROFILE" = "release" ]; then
  MACOSX_DEPLOYMENT_TARGET=14.0 cargo build \
    --manifest-path "$ROOT/rust/arco-core/Cargo.toml" \
    --release \
    --lib
else
  MACOSX_DEPLOYMENT_TARGET=14.0 cargo build \
    --manifest-path "$ROOT/rust/arco-core/Cargo.toml" \
    --lib
fi

ARCO_RUST_PROFILE="$PROFILE" swift build \
  --package-path "$SWIFT_PACKAGE" \
  -c "$SWIFT_CONFIGURATION" \
  --product Arco
BIN_DIR=$(ARCO_RUST_PROFILE="$PROFILE" swift build \
  --package-path "$SWIFT_PACKAGE" \
  -c "$SWIFT_CONFIGURATION" \
  --show-bin-path)

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES/native"
cp "$BIN_DIR/Arco" "$MACOS/Arco"
cp "$SWIFT_PACKAGE/App/Info.plist" "$CONTENTS/Info.plist"
cp "$SWIFT_PACKAGE/App/Resources/Arco.icns" "$RESOURCES/Arco.icns"
cp "$SWIFT_PACKAGE/App/Resources/ArcoStatusTemplate.png" "$RESOURCES/ArcoStatusTemplate.png"
if [ -d "$ROOT/native/runtime" ]; then
  ditto "$ROOT/native/runtime" "$RESOURCES/native"
fi

chmod 755 "$MACOS/Arco"
for helper in \
  recorder \
  arco-gpt-live \
  arco-deepgram-transcriber \
  arco-elevenlabs-transcriber \
  arco-doubao-transcriber \
  arco-local-transcriber
do
  if [ -f "$RESOURCES/native/$helper" ]; then
    chmod 755 "$RESOURCES/native/$helper"
  fi
done

if [ "${ARCO_SKIP_CODESIGN:-0}" != "1" ]; then
  [ ! -x "$RESOURCES/native/recorder" ] || "$ROOT/native/codesign-local.sh" "$RESOURCES/native/recorder" app.arco.desktop.recorder
  [ ! -x "$RESOURCES/native/arco-gpt-live" ] || "$ROOT/native/codesign-local.sh" "$RESOURCES/native/arco-gpt-live" app.arco.desktop.gpt-live
  [ ! -x "$RESOURCES/native/arco-deepgram-transcriber" ] || "$ROOT/native/codesign-local.sh" "$RESOURCES/native/arco-deepgram-transcriber" app.arco.desktop.deepgram-transcriber
  [ ! -x "$RESOURCES/native/arco-elevenlabs-transcriber" ] || "$ROOT/native/codesign-local.sh" "$RESOURCES/native/arco-elevenlabs-transcriber" app.arco.desktop.elevenlabs-transcriber
  [ ! -x "$RESOURCES/native/arco-doubao-transcriber" ] || "$ROOT/native/codesign-local.sh" "$RESOURCES/native/arco-doubao-transcriber" app.arco.desktop.doubao-transcriber
  [ ! -x "$RESOURCES/native/arco-local-transcriber" ] || "$ROOT/native/codesign-local.sh" "$RESOURCES/native/arco-local-transcriber" app.arco.desktop.local-transcriber
  "$ROOT/native/codesign-local.sh" "$APP" app.arco.desktop
  codesign --verify --deep --strict --verbose=2 "$APP"
  ARCO_BOUNDARY_SKIP_CODESIGN=0 "$ROOT/native/verify-native-boundaries.sh" "$APP"
else
  ARCO_BOUNDARY_SKIP_CODESIGN=1 "$ROOT/native/verify-native-boundaries.sh" "$APP"
fi

echo "Built $APP"
