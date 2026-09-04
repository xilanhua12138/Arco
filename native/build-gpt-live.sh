#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NATIVE_DIR="$ROOT/native"
RUNTIME_DIR="$NATIVE_DIR/runtime"
TARGET_DIR=${CARGO_TARGET_DIR:-"$ROOT/rust/arco-gpt-live/target"}

mkdir -p "$RUNTIME_DIR"
MACOSX_DEPLOYMENT_TARGET=14.0 CARGO_TARGET_DIR="$TARGET_DIR" cargo build \
  --manifest-path "$ROOT/rust/arco-gpt-live/Cargo.toml" \
  --release \
  --bin arco-gpt-live
cp "$TARGET_DIR/release/arco-gpt-live" "$RUNTIME_DIR/arco-gpt-live"
"$NATIVE_DIR/codesign-local.sh" \
  "$RUNTIME_DIR/arco-gpt-live" \
  app.arco.desktop.gpt-live
echo "Built and signed $RUNTIME_DIR/arco-gpt-live"
