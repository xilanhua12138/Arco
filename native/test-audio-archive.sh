#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BINARY=$(mktemp "${TMPDIR:-/tmp}/arco-audio-archive-test.XXXXXX")
trap 'rm -f "$BINARY"' EXIT HUP INT TERM
swiftc -parse-as-library "$ROOT/native/AudioArchive.swift" "$ROOT/native/tests/audio-archive-tests.swift" -o "$BINARY"
"$BINARY"
