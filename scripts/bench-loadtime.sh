#!/bin/zsh
# How long a note's editor takes to come up from cold: when its WebKit process appears, and when
# that process stops growing (CodeMirror parsed, the page drawn). Watched from outside.
#
#   scripts/bench-loadtime.sh <vault> [expected-open-notes] [give-up-seconds] [Debug|Release]
#   scripts/bench-loadtime.sh /tmp/bench-1 1
#
# "settled" is an UPPER bound on "ready to type" — the page is usable before it stops allocating.
# For the real figure use the in-app probe: PINTACK_FOCUSPROBE (scripts/bench-focus.sh).
# THROWAWAY VAULTS ONLY.
set -euo pipefail
zmodload zsh/datetime          # EPOCHREALTIME
cd "$(dirname "$0")/.."
vault="$1"; want="${2:-1}"; limit="${3:-60}"; config="${4:-Debug}"
app="build/$config/PinTack.app/Contents/MacOS/PinTack"
[[ -x "$app" ]] || { echo "no $config build at $app — build it first"; exit 2; }

webkit_pids() { pgrep -f "com.apple.WebKit.WebContent" || true }
foot() { /usr/bin/footprint -p "$1" 2>/dev/null | awk '/Footprint:/ { for (i=1;i<=NF;i++) if ($i=="Footprint:") { v=$(i+1); gsub(",","",v); u=$(i+2); if (u=="MB") v=v*1024; else if (u=="GB") v=v*1048576; printf "%d", v; exit } }' || echo 0 }

before=("${(@f)$(webkit_pids)}")
start=$EPOCHREALTIME
PINTACK_VAULT="$vault" PINTACK_NO_HOTKEYS=1 PINTACK_NO_TOAST=1 "$app" >/dev/null 2>&1 &
apppid=$!
trap 'kill -9 $apppid 2>/dev/null || true' EXIT

first=""; all=""; stable=""; lastsum=0; samesince=""
while (( EPOCHREALTIME - start < limit )); do
  mine=()
  for p in "${(@f)$(webkit_pids)}"; do
    [[ -z "$p" ]] && continue
    [[ " ${before[*]} " == *" $p "* ]] || mine+=("$p")
  done
  [[ -z "$first" && ${#mine[@]} -ge 1 ]] && first=$(printf "%.2f" $(( EPOCHREALTIME - start )))
  [[ -z "$all" && ${#mine[@]} -ge $want ]] && all=$(printf "%.2f" $(( EPOCHREALTIME - start )))
  if [[ -n "$all" ]]; then
    sum=0; for p in $mine; do sum=$(( sum + $(foot $p) )); done
    if (( sum > 0 && sum >= lastsum * 99 / 100 && sum <= lastsum * 101 / 100 )); then
      [[ -z "$samesince" ]] && samesince=$EPOCHREALTIME
      (( EPOCHREALTIME - samesince > 2 )) && { stable=$(printf "%.2f" $(( EPOCHREALTIME - start - 2 ))); break; }
    else samesince=""; fi
    lastsum=$sum
  fi
  sleep 0.25
done
echo "first_page_process_s=${first:-none} all_${want}_pages_s=${all:-none} settled_s=${stable:-none}"
kill -9 $apppid 2>/dev/null || true
sleep 1
