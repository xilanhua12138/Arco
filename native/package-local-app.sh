#!/bin/sh
# Build a reproducible drag-to-Applications macOS DMG even when the repository
# lives in a File Provider-managed folder. Copying without resource metadata to
# a private staging directory keeps the app signature valid before hdiutil
# creates the user-facing installer image.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/Arco.app"
ARTIFACT_DIR="$ROOT/artifacts"
ARCH=$(uname -m)
OUTPUT="$ARTIFACT_DIR/Arco-macos-$ARCH.dmg"
VOLUME_NAME="Arco Installer"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/arco-package.XXXXXX")
DMG_ROOT="$STAGING/dmg-root"
MOUNT_POINT="/Volumes/$VOLUME_NAME"
BACKGROUND="$STAGING/background.png"
RW_DMG="$STAGING/Arco-rw.dmg"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
MOUNTED=0

unregister_app() {
  if [ -x "$LSREGISTER" ] && [ -d "$1" ]; then
    "$LSREGISTER" -u "$1" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then
    unregister_app "$MOUNT_POINT/Arco.app"
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGING"
}
trap cleanup EXIT HUP INT TERM

cd "$ROOT"
if [ "${ARCO_PACKAGE_SKIP_BUILD:-0}" != "1" ]; then
  "$ROOT/native/build-recorder.sh"
  "$ROOT/native/build-deepgram-transcriber.sh"
  "$ROOT/native/build-elevenlabs-transcriber.sh"
  "$ROOT/native/build-doubao-transcriber.sh"
  "$ROOT/native/build-local-transcriber.sh"
  "$ROOT/native/build-native-app.sh"
fi

if [ ! -x "$APP/Contents/MacOS/Arco" ]; then
  echo "Arco.app is missing its main desktop executable" >&2
  exit 1
fi
if [ ! -x "$APP/Contents/Resources/native/arco-deepgram-transcriber" ]; then
  echo "Arco.app is missing the bundled Rust Deepgram runtime" >&2
  exit 1
fi
if [ ! -x "$APP/Contents/Resources/native/arco-elevenlabs-transcriber" ]; then
  echo "Arco.app is missing the bundled Rust ElevenLabs runtime" >&2
  exit 1
fi
if [ ! -x "$APP/Contents/Resources/native/arco-doubao-transcriber" ]; then
  echo "Arco.app is missing the bundled Rust Doubao runtime" >&2
  exit 1
fi
MAIN_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")
if [ "$MAIN_EXECUTABLE" != "Arco" ]; then
  echo "Arco.app selected the wrong main executable: $MAIN_EXECUTABLE" >&2
  exit 1
fi
if [ -e "$APP/Contents/MacOS/arco-deepgram-transcriber" ]; then
  echo "Deepgram sidecar was incorrectly selected as the app executable" >&2
  exit 1
fi
if [ -e "$APP/Contents/MacOS/arco-elevenlabs-transcriber" ]; then
  echo "ElevenLabs sidecar was incorrectly selected as the app executable" >&2
  exit 1
fi
if [ -e "$APP/Contents/MacOS/arco-doubao-transcriber" ]; then
  echo "Doubao sidecar was incorrectly selected as the app executable" >&2
  exit 1
fi
unregister_app "$APP"

COPYFILE_DISABLE=1 ditto --norsrc "$APP" "$STAGING/Arco.app"
"$ROOT/native/codesign-local.sh" \
  "$STAGING/Arco.app/Contents/Resources/native/recorder" \
  app.arco.desktop.recorder
"$ROOT/native/codesign-local.sh" \
  "$STAGING/Arco.app/Contents/Resources/native/arco-deepgram-transcriber" \
  app.arco.desktop.deepgram-transcriber
"$ROOT/native/codesign-local.sh" \
  "$STAGING/Arco.app/Contents/Resources/native/arco-elevenlabs-transcriber" \
  app.arco.desktop.elevenlabs-transcriber
"$ROOT/native/codesign-local.sh" \
  "$STAGING/Arco.app/Contents/Resources/native/arco-doubao-transcriber" \
  app.arco.desktop.doubao-transcriber
"$ROOT/native/codesign-local.sh" \
  "$STAGING/Arco.app/Contents/Resources/native/arco-local-transcriber" \
  app.arco.desktop.local-transcriber
"$ROOT/native/codesign-local.sh" "$STAGING/Arco.app" app.arco.desktop
codesign --verify --deep --strict --verbose=2 "$STAGING/Arco.app"
ARCO_BOUNDARY_SKIP_CODESIGN=0 \
  "$ROOT/native/verify-native-boundaries.sh" "$STAGING/Arco.app"
DESIGNATED_REQUIREMENT=$(codesign -d -r- "$STAGING/Arco.app" 2>&1)
case "$DESIGNATED_REQUIREMENT" in
  *cdhash*)
    echo "Arco package still has a build-specific ad-hoc designated requirement" >&2
    exit 1
    ;;
esac

mkdir -p "$ARTIFACT_DIR"
rm -f "$OUTPUT"
mkdir -p "$DMG_ROOT"
COPYFILE_DISABLE=1 ditto --norsrc "$STAGING/Arco.app" "$DMG_ROOT/Arco.app"
ln -s /Applications "$DMG_ROOT/Applications"
sips \
  -s format png \
  -z 840 1320 \
  -s dpiWidth 144 \
  -s dpiHeight 144 \
  "$ROOT/native/dmg-background.svg" \
  --out "$BACKGROUND" >/dev/null

COPYFILE_DISABLE=1 hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_ROOT" \
  -format UDRW \
  -ov \
  "$RW_DMG" >/dev/null

if [ -e "$MOUNT_POINT" ]; then
  echo "Cannot style the DMG while $MOUNT_POINT is already mounted. Eject it and try again." >&2
  exit 1
fi
hdiutil attach -readwrite -nobrowse -mountpoint "$MOUNT_POINT" "$RW_DMG" >/dev/null
MOUNTED=1
mkdir -p "$MOUNT_POINT/.background"
COPYFILE_DISABLE=1 ditto --norsrc "$BACKGROUND" "$MOUNT_POINT/.background/background.png"
osascript "$ROOT/native/dmg-layout.applescript" "$VOLUME_NAME" "$MOUNT_POINT" >/dev/null
sync
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=0

hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$OUTPUT" >/dev/null

hdiutil verify "$OUTPUT" >/dev/null
if [ -e "$MOUNT_POINT" ]; then
  echo "Cannot verify the DMG while $MOUNT_POINT is already mounted. Eject it and try again." >&2
  exit 1
fi
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$OUTPUT" >/dev/null
MOUNTED=1
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/Arco.app"
ARCO_BOUNDARY_SKIP_CODESIGN=0 \
  "$ROOT/native/verify-native-boundaries.sh" "$MOUNT_POINT/Arco.app"
if [ ! -x "$MOUNT_POINT/Arco.app/Contents/Resources/native/arco-elevenlabs-transcriber" ]; then
  echo "DMG is missing the bundled ElevenLabs runtime" >&2
  exit 1
fi
if [ ! -x "$MOUNT_POINT/Arco.app/Contents/Resources/native/arco-doubao-transcriber" ]; then
  echo "DMG is missing the bundled Doubao runtime" >&2
  exit 1
fi
if [ ! -L "$MOUNT_POINT/Applications" ]; then
  echo "DMG is missing the Applications shortcut" >&2
  exit 1
fi
if [ ! -f "$MOUNT_POINT/.background/background.png" ]; then
  echo "DMG is missing its branded background" >&2
  exit 1
fi
if find "$MOUNT_POINT" -name '._*' -print -quit | grep -q .; then
  echo "DMG contains AppleDouble metadata that would invalidate the app signature" >&2
  exit 1
fi
unregister_app "$MOUNT_POINT/Arco.app"
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=0
(cd "$ARTIFACT_DIR" && shasum -a 256 "$(basename "$OUTPUT")") > "$OUTPUT.sha256"
echo "Packaged $OUTPUT"
