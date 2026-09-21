#!/bin/sh
# Check the actual app executable after relocation and with damaged resources.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP=${1:-"$ROOT/build/Arco.app"}
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/arco-resource-test.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
COPYFILE_DISABLE=1 ditto --norsrc "$APP" "$STAGING/Arco.app"
TEST_APP="$STAGING/Arco.app"
"$TEST_APP/Contents/MacOS/Arco" --self-test-resources

# A broken installation should report a failed self-test, never SIGTRAP (133).
expect_resource_failure() {
    codesign --force --sign - "$TEST_APP" >/dev/null 2>&1
    result=0
    "$TEST_APP/Contents/MacOS/Arco" --self-test-resources > "$STAGING/result.txt" 2>&1 || result=$?
    cat "$STAGING/result.txt"
    [ "$result" -eq 1 ] || { echo "Expected graceful resource failure, got $result" >&2; exit 1; }
    grep -q 'Resource check failed:' "$STAGING/result.txt"
}
rm "$TEST_APP/Contents/Resources/ArcoNativeUI_ArcoNativeUI.bundle/Aura/LiveKitAura.metal.txt"
expect_resource_failure
rm -rf "$TEST_APP/Contents/Resources/ArcoNativeUI_ArcoNativeUI.bundle"
expect_resource_failure
echo "Packaged resource relocation and missing-resource checks passed"
