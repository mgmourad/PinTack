#!/bin/zsh
# Runs one of the bench scripts N times per point and prints the median — a single measurement
# cannot tell a change from the noise, and this project has been fooled by one before.
#
#   scripts/bench-sweep.sh <runs> <vault:label:settle> [more…]
#   scripts/bench-sweep.sh 5 /tmp/bench-1:1\ note:18 /tmp/bench-20:20\ notes:30
#
# Writes a CSV to $OUT (default /tmp/bench-results.csv) and prints a median table.
# Run it on a quiet machine: a busy one reads up to 20% higher.
set -euo pipefail
here="$(dirname "$0")"
runs="$1"; shift
out="${OUT:-/tmp/bench-results.csv}"
echo "label,run,app_mb,webkit_mb,total_mb,webcontent" > "$out"
for spec in "$@"; do
  vault="${spec%%:*}"; rest="${spec#*:}"; label="${rest%%:*}"; settle="${rest##*:}"
  for run in $(seq 1 $runs); do
    line=$("$here/bench-memory.sh" "$vault" "$settle" 0 "${CONFIG:-Debug}")
    echo "$label,$run,$(echo $line | sed -n 's/.*app_mb=\([0-9.]*\).*/\1/p'),$(echo $line | sed -n 's/.*webkit_mb=\([0-9.]*\).*/\1/p'),$(echo $line | sed -n 's/.*total_mb=\([0-9.]*\).*/\1/p'),$(echo $line | sed -n 's/.*webcontent=\([0-9]*\).*/\1/p')" >> "$out"
    echo "$label run $run: $line"
  done
done
echo
python3 - "$out" <<'PY'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
by = {}
for r in rows: by.setdefault(r['label'], []).append(r)
print(f"{'point':<14}{'n':>3}{'app MB':>9}{'webkit MB':>11}{'TOTAL MB':>10}{'spread':>8}{'webcontent':>12}")
for label, rs in by.items():
    tot = [float(r['total_mb']) for r in rs]
    print(f"{label:<14}{len(rs):>3}{statistics.median(float(r['app_mb']) for r in rs):9.0f}"
          f"{statistics.median(float(r['webkit_mb']) for r in rs):11.0f}{statistics.median(tot):10.0f}"
          f"{max(tot)-min(tot):8.1f}{rs[0]['webcontent']:>12}")
PY
