#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NATIVE_DIR="$ROOT/native"
RUNTIME_DIR="$NATIVE_DIR/runtime"
TARGET_DIR=${CARGO_TARGET_DIR:-"$ROOT/rust/arco-core/target"}

mkdir -p "$RUNTIME_DIR"
CARGO_TARGET_DIR="$TARGET_DIR" cargo build \
  --manifest-path "$ROOT/rust/arco-core/Cargo.toml" \
  --release \
  --features doubao-worker \
  --bin arco-doubao-transcriber
cp "$TARGET_DIR/release/arco-doubao-transcriber" "$RUNTIME_DIR/arco-doubao-transcriber"
"$NATIVE_DIR/codesign-local.sh" \
  "$RUNTIME_DIR/arco-doubao-transcriber" \
  app.arco.desktop.doubao-transcriber
echo "Built and signed $RUNTIME_DIR/arco-doubao-transcriber"
