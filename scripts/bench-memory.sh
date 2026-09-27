#!/bin/zsh
# What a desk of open notes ACTUALLY costs: the PinTack process plus every WebKit process macOS
# starts for it. Watched from outside, the way Activity Monitor sees it, so nothing in the app has
# to be instrumented and a Release build measures the same as a Debug one.
#
#   scripts/bench-memory.sh <vault> [settle-seconds] [idle-cpu-seconds] [Debug|Release]
#
#   scripts/bench-vault.py 1000 20 /tmp/bench-20 PinTack/Resources/Tutorial/pin.png
#   scripts/bench-memory.sh /tmp/bench-20 30            # memory at 20 open notes
#   scripts/bench-memory.sh /tmp/bench-20 30 30         # …and idle CPU over 30 seconds
#
# Give notes time to settle: about 15 seconds plus half a second per open note. The numbers move by
# up to 20% on a busy machine, so compare like with like and take a median (scripts/bench-sweep.sh).
# THROWAWAY VAULTS ONLY — it launches the app against whatever folder you name.
set -euo pipefail
cd "$(dirname "$0")/.."
vault="$1"; settle="${2:-25}"; cpuwindow="${3:-0}"; config="${4:-Debug}"
app="build/$config/PinTack.app/Contents/MacOS/PinTack"
[[ -x "$app" ]] || { echo "no $config build at $app — build it first"; exit 2; }

webkit_pids() { pgrep -f "com.apple.WebKit" || true }
foot() {  # physical footprint in KILOBYTES; footprint(1) prints KB, MB or GB, so read the unit
  /usr/bin/footprint -p "$1" 2>/dev/null | awk '
    /Footprint:/ { for (i = 1; i <= NF; i++) if ($i == "Footprint:") {
        v = $(i + 1); gsub(",", "", v); u = $(i + 2)
        if (u == "MB") v = v * 1024; else if (u == "GB") v = v * 1024 * 1024
        printf "%d", v; exit } }' || echo 0
}
cputime() { ps -o time= -p "$1" 2>/dev/null | awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else if (NF==2) print $1*60+$2; else print 0 }' || echo 0 }

# Every WebKit process already running belongs to somebody else — Safari, Mail, this editor.
before=("${(@f)$(webkit_pids)}")
PINTACK_VAULT="$vault" PINTACK_NO_HOTKEYS=1 PINTACK_NO_TOAST=1 "$app" >/dev/null 2>&1 &
apppid=$!
trap 'kill -9 $apppid 2>/dev/null || true' EXIT
sleep "$settle"

new=()
for p in "${(@f)$(webkit_pids)}"; do
  [[ -z "$p" ]] && continue
  [[ " ${before[*]} " == *" $p "* ]] || new+=("$p")
done

appkb=$(foot $apppid); webkb=0; webcontent=0; gpu=0; net=0
for p in $new; do
  webkb=$(( webkb + $(foot $p) ))
  case "$(ps -o comm= -p $p 2>/dev/null)" in
    *WebContent*) webcontent=$(( webcontent + 1 ));;
    *GPU*)        gpu=$(( gpu + 1 ));;
    *Networking*) net=$(( net + 1 ));;
  esac
done

cpu0=$(cputime $apppid); for p in $new; do cpu0=$(( cpu0 + $(cputime $p) )); done
if (( cpuwindow > 0 )); then
  sleep "$cpuwindow"
  cpu1=$(cputime $apppid); for p in $new; do cpu1=$(( cpu1 + $(cputime $p) )); done
else cpu1=$cpu0; fi

printf "app_mb=%.1f webkit_mb=%.1f total_mb=%.1f webcontent=%d gpu=%d networking=%d helpers=%d idle_cpu_pct=%.1f\n" \
  $(( appkb / 1024.0 )) $(( webkb / 1024.0 )) $(( (appkb + webkb) / 1024.0 )) \
  $webcontent $gpu $net ${#new[@]} \
  $(( cpuwindow > 0 ? (cpu1 - cpu0) * 100.0 / cpuwindow : 0 ))
kill -9 $apppid 2>/dev/null || true
sleep 1
