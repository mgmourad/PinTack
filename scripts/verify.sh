#!/usr/bin/env bash
# Everything that can say "this build is broken", in one command.
#
#   scripts/verify.sh
#
# Two layers, and BOTH must pass:
#   1. xcodebuild test — the unit tests (vault format, plugin security, image maths, …).
#   2. the self-test   — the app launching itself, driving its own windows and web views, and
#                        asserting what actually happened. It exits non-zero on any failed check,
#                        which is what makes it usable here rather than something a person reads.
#
# It runs against a THROWAWAY vault, never your notes.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/vault" "$WORK/out"

echo "── building ──"
xcodebuild -scheme PinTack -configuration Debug SYMROOT="$PWD/build" build | tail -1

echo "── unit tests ──"
xcodebuild -scheme PinTack SYMROOT="$PWD/build" test 2>&1 | grep -E "Executed .* tests|\*\* TEST" | tail -2

echo "── self-test (the app driving itself) ──"
PINTACK_VAULT="$WORK/vault" PINTACK_SELFTEST_DIR="$WORK/out" \
  PINTACK_SELFTEST_QUIT=1 PINTACK_NO_TOAST=1 \
  build/Debug/PinTack.app/Contents/MacOS/PinTack >/dev/null 2>&1 || {
    echo
    echo "SELF-TEST FAILED. What it checked and what went wrong:"
    grep -E "^FAIL|^SELFTEST" "$WORK/out/report.txt" || true
    echo
    echo "Full report and screenshots were in $WORK/out (now removed); re-run with"
    echo "PINTACK_SELFTEST_DIR set to somewhere permanent to keep them."
    exit 1
  }
tail -1 "$WORK/out/report.txt"
echo
echo "All green."
