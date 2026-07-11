#!/bin/sh
# Build a reproducible local macOS package even when the repository lives in
# a File Provider-managed Documents folder. Such folders can attach FinderInfo
# xattrs to `.app` directories while Tauri is bundling, which makes codesign
# reject the bundle. Copying without resource metadata to a private staging
# directory keeps the source tree untouched and produces a verifiable app.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TARGET_DIR=$(cd "$ROOT/src-tauri" && cargo metadata --format-version 1 --no-deps \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')
APP="$TARGET_DIR/debug/bundle/macos/Arco.app"
ARTIFACT_DIR="$ROOT/artifacts"
ARCH=$(uname -m)
OUTPUT="$ARTIFACT_DIR/Arco-local-macos-$ARCH.zip"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/arco-package.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM

cd "$ROOT"
pnpm tauri build --debug --bundles app

COPYFILE_DISABLE=1 ditto --norsrc "$APP" "$STAGING/Arco.app"
codesign --force --deep --sign - "$STAGING/Arco.app"
codesign --verify --deep --strict --verbose=2 "$STAGING/Arco.app"

mkdir -p "$ARTIFACT_DIR"
rm -f "$OUTPUT"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$STAGING/Arco.app" "$OUTPUT"

if unzip -Z1 "$OUTPUT" | grep -qE '(^|/)\._'; then
  echo "Package contains AppleDouble metadata that would invalidate the app signature" >&2
  exit 1
fi

VERIFY_DIR="$STAGING/verify"
mkdir -p "$VERIFY_DIR"
COPYFILE_DISABLE=1 ditto -x -k --norsrc "$OUTPUT" "$VERIFY_DIR"
codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/Arco.app"
echo "Packaged $OUTPUT"
