#!/bin/zsh
# The tutorial's pictures, taken from the running app (SPEC.md §8.4).
#
#   scripts/make-tutorial-shots.sh
#
# Builds one scene per slide against a throwaway vault — never your own notes — photographs the
# windows, and writes the PNGs into PinTack/Resources/Tutorial/, which the app bundles. Re-run it
# whenever a feature's look changes; the pictures are checked in, so Release needs no Debug build.
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/Debug/PinTack.app/Contents/MacOS/PinTack"
[[ -x "$app" ]] || xcodebuild -scheme PinTack -configuration Debug SYMROOT="$PWD/build" build -quiet
out="$PWD/PinTack/Resources/Tutorial"
mkdir -p "$out"
tmp="$(mktemp -d /tmp/pintack-tutorial.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
PINTACK_VAULT="$tmp/vault" PINTACK_NO_HOTKEYS=1 PINTACK_NO_TOAST=1 PINTACK_TUTORIAL_SHOTS="$out" "$app" 2>/dev/null || true
ls -1 "$out"
