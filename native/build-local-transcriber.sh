#!/bin/sh
set -eu

NATIVE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_DIR="$NATIVE_DIR/local-transcriber"
RUNTIME_DIR="$NATIVE_DIR/runtime"
LICENSE_DIR="$RUNTIME_DIR/licenses"

swift build --package-path "$PACKAGE_DIR" -c release --product arco-local-transcriber
BIN_DIR=$(swift build --package-path "$PACKAGE_DIR" -c release --show-bin-path)
mkdir -p "$RUNTIME_DIR"
cp "$BIN_DIR/arco-local-transcriber" "$RUNTIME_DIR/arco-local-transcriber"
mkdir -p "$LICENSE_DIR"
rm -f "$LICENSE_DIR/FluidAudio-LICENSE.txt" "$LICENSE_DIR/SwiftWhisper-LICENSE.txt"
cp "$PACKAGE_DIR/.build/checkouts/FluidAudio/LICENSE" "$LICENSE_DIR/FluidAudio-LICENSE.txt"
cp "$PACKAGE_DIR/.build/checkouts/SwiftWhisper/LICENSE" "$LICENSE_DIR/SwiftWhisper-LICENSE.txt"
chmod 644 "$LICENSE_DIR/FluidAudio-LICENSE.txt" "$LICENSE_DIR/SwiftWhisper-LICENSE.txt"
chmod 755 "$RUNTIME_DIR/arco-local-transcriber"
chmod 644 "$LICENSE_DIR/FluidAudio-LICENSE.txt" "$LICENSE_DIR/SwiftWhisper-LICENSE.txt"
"$NATIVE_DIR/codesign-local.sh" \
  "$RUNTIME_DIR/arco-local-transcriber" \
  app.arco.desktop.local-transcriber
echo "Built and signed $RUNTIME_DIR/arco-local-transcriber"
