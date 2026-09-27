#!/bin/zsh
# Click a note, type immediately, and time it until the character is really in that note's editor.
# Uses the app's own Debug probe, because this cannot be seen from outside.
#
#   scripts/bench-focus.sh <vault> [runs]
#   scripts/bench-vault.py 1000 20 /tmp/bench-20 PinTack/Resources/Tutorial/pin.png
#   scripts/bench-focus.sh /tmp/bench-20 5
#
# It reports the median, the range, how many keystrokes were DROPPED (any is a bug), and the
# resolution — the probe learns the character landed by asking the page, so nothing faster than one
# round trip to that page is measurable. THROWAWAY VAULTS ONLY.
set -euo pipefail
cd "$(dirname "$0")/.."
vault="$1"; runs="${2:-5}"
app="build/Debug/PinTack.app/Contents/MacOS/PinTack"
[[ -x "$app" ]] || xcodebuild -scheme PinTack -configuration Debug SYMROOT="$PWD/build" build -quiet
out="$(mktemp /tmp/pintack-focus.XXXXXX)"
PINTACK_VAULT="$vault" PINTACK_NO_HOTKEYS=1 PINTACK_NO_TOAST=1 \
  PINTACK_FOCUSPROBE="$runs" PINTACK_FOCUSPROBE_OUT="$out" "$app" >/dev/null 2>&1 || true
cat "$out"; rm -f "$out"
