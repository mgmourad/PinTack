#!/bin/zsh
# How much memory a desk of open notes costs (SPEC.md §17). A measurement, not a pass/fail check.
#
#   scripts/measure-memory.sh        # 50 notes
#   scripts/measure-memory.sh 100
#
# Runs the Debug app against a throwaway vault (never your real notes), opens the notes in steps,
# and prints the resident memory and footprint of PinTack plus every WebKit helper process macOS
# holds it responsible for, and how many WebContent processes there are.
set -euo pipefail
cd "$(dirname "$0")/.."
n="${1:-50}"
app="build/Debug/PinTack.app/Contents/MacOS/PinTack"
[[ -x "$app" ]] || xcodebuild -scheme PinTack -configuration Debug SYMROOT="$PWD/build" build -quiet
tmp="$(mktemp -d /tmp/pintack-mem.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
PINTACK_VAULT="$tmp/vault" PINTACK_NO_HOTKEYS=1 PINTACK_NO_TOAST=1 PINTACK_MEMPROBE="$n" \
  PINTACK_MEMPROBE_OUT="$tmp/report.txt" "$app" >/dev/null 2>&1 || true
cat "$tmp/report.txt"
echo
echo "rss = resident memory (counts pages shared between processes once per process);"
echo "fp  = physical footprint (what Activity Monitor calls Memory; the better number)."
