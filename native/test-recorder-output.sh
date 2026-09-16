#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BINARY=$(mktemp "${TMPDIR:-/tmp}/arco-recorder-output-test.XXXXXX")
trap 'rm -f "$BINARY"' EXIT HUP INT TERM
swiftc -parse-as-library "$ROOT/native/RecorderOutput.swift" "$ROOT/native/tests/recorder-output-tests.swift" -o "$BINARY"
"$BINARY"
