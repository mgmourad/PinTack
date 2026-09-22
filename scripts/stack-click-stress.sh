#!/bin/zsh
# A hundred clicks on a pile of five notes, one a second, with a marker showing each one.
#
#   scripts/stack-click-stress.sh [clicks]
#
# Runs the Debug app against a throwaway vault — never your own notes — and prints every click with
# the pile before and after it, then a summary of anything that went wrong.
set -euo pipefail
cd "$(dirname "$0")/.."
n="${1:-100}"
app="build/Debug/PinTack.app/Contents/MacOS/PinTack"
[[ -x "$app" ]] || xcodebuild -scheme PinTack -configuration Debug SYMROOT="$PWD/build" build -quiet
tmp="$(mktemp -d /tmp/pintack-stress.XXXXXX)"
PINTACK_VAULT="$tmp/vault" PINTACK_NO_HOTKEYS=1 PINTACK_NO_TOAST=1 PINTACK_STACK_STRESS="$n" \
  PINTACK_STACK_STRESS_OUT="$tmp/report.txt" "$app" 2>/dev/null | grep "STACK STRESS" || true
echo
echo "report: $tmp/report.txt"
