#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE="$ROOT/macos/ArcoNativeUI"
PLATFORM="$PACKAGE/Sources/ArcoApp/Platform"
cargo build --manifest-path "$ROOT/rust/arco-core/Cargo.toml" --release --lib
ARCO_RUST_PROFILE=release swift build --package-path "$PACKAGE" --product ArcoNativeUI
BIN=$(ARCO_RUST_PROFILE=release swift build --package-path "$PACKAGE" --show-bin-path)
# Compile the actual production coordinator and glass surface, so this checks
# AppKit/SwiftUI integration rather than a screenshot-only approximation.
swiftc -parse-as-library -g -I "$BIN/Modules" -L "$BIN" -lArcoNativeUI \
    -L "$ROOT/rust/arco-core/target/release" -larco_core -framework Security \
    "$PLATFORM/WindowCoordinator.swift" "$PLATFORM/WindowGeometry.swift" \
    "$PLATFORM/NativeOverlayMaterial.swift" "$ROOT/native/tests/HUDWindowTests.swift" \
    -o "$BIN/ArcoHUDWindowTests"
"$BIN/ArcoHUDWindowTests"
