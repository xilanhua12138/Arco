#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NATIVE_DIR="$ROOT/native"
RUNTIME_DIR="$NATIVE_DIR/runtime"
TARGET_DIR=$(cd "$ROOT/src-tauri" && cargo metadata --format-version 1 --no-deps \
  | node -e 'let input=""; process.stdin.on("data", chunk => input += chunk); process.stdin.on("end", () => console.log(JSON.parse(input).target_directory))')

mkdir -p "$RUNTIME_DIR"
cargo build --manifest-path "$ROOT/src-tauri/Cargo.toml" --release --features doubao-sidecar --bin arco-doubao-transcriber
cp "$TARGET_DIR/release/arco-doubao-transcriber" "$RUNTIME_DIR/arco-doubao-transcriber"
"$NATIVE_DIR/codesign-local.sh" \
  "$RUNTIME_DIR/arco-doubao-transcriber" \
  app.arco.desktop.doubao-transcriber
echo "Built and signed $RUNTIME_DIR/arco-doubao-transcriber"
