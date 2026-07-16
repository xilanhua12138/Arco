#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PLATFORM="$ROOT/macos/ArcoNativeUI/Sources/ArcoApp/Platform"
SOURCES="$ROOT/macos/ArcoNativeUI/Sources"
PRODUCT_SOURCES="$SOURCES/ArcoNativeUI $SOURCES/ArcoApp"
OVERLAY="$PLATFORM/NativeOverlayMaterial.swift"
THEME="$ROOT/macos/ArcoNativeUI/Sources/ArcoNativeUI/Views/Theme.swift"
NOTES_VIEW="$ROOT/macos/ArcoNativeUI/Sources/ArcoNativeUI/SetupViews/NotesPageView.swift"
MAIN_SHELL="$ROOT/macos/ArcoNativeUI/Sources/ArcoNativeUI/AppViews/ArcoMainShellView.swift"
SETTINGS_SHEET="$ROOT/macos/ArcoNativeUI/Sources/ArcoNativeUI/AppViews/ArcoSettingsSheetView.swift"

if grep -R -E 'NSGlassEffectView|NSVisualEffectView' $PRODUCT_SOURCES >/dev/null; then
  echo "SwiftUI surfaces must not use AppKit material views" >&2
  exit 1
fi

grep -q 'GlassEffectContainer' "$OVERLAY"
grep -q '\.glassEffect(.regular' "$OVERLAY"
grep -q 'GlassEffectContainer' "$THEME"
grep -q '\.glassEffect(' "$THEME"
grep -q '\.interactive()' "$THEME"
grep -q '\.interactive()' "$PLATFORM/RecordingHUD.swift"
grep -q '\.interactive()' "$PLATFORM/AgentOverlay.swift"

grep -q '\.onChange(of: viewModel.draft)' "$NOTES_VIEW" || {
  echo "Notes must observe newly mounted draft state for title focus" >&2
  exit 1
}
grep -q 'titleFieldFocused = true' "$NOTES_VIEW" || {
  echo "A new Notes draft must focus its title like the source input" >&2
  exit 1
}

if awk '
  /if controller\.settingsOpen \{/ { candidate = NR }
  candidate && NR <= candidate + 2 && /Color\.clear/ { found = 1 }
  END { exit(found ? 0 : 1) }
' "$MAIN_SHELL"; then
  echo "Opening Settings must preserve the application sidebar behind the scrim" >&2
  exit 1
fi

if ! awk '
  /\.background\(ArcoNativeColors\.surfaceSettingsShell/ { shell = NR }
  shell && ! highlight && /\.overlay\(alignment: \.top\)/ { highlight = NR }
  shell && ! clip && /\.clipShape\(RoundedRectangle\(cornerRadius: 12/ { clip = NR }
  END { exit(shell && highlight && clip && highlight < clip ? 0 : 1) }
' "$SETTINGS_SHEET"; then
  echo "The Settings top highlight must be clipped by the full sheet shape" >&2
  exit 1
fi

if grep -R -E 'import (WebKit|JavaScriptCore)' $PRODUCT_SOURCES >/dev/null; then
  echo "The native SwiftUI frontend must not import a browser runtime" >&2
  exit 1
fi

echo "SwiftUI Liquid Glass source contract passed"
