#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PID=
DURATION=1800
INTERVAL=5
OUTPUT=
MINIMUM_SECONDS=1200

usage() {
  printf '%s\n' "Usage: $0 [--pid PID] [--duration SECONDS] [--interval SECONDS] [--output CSV] [--minimum-seconds SECONDS]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pid) PID=${2:-}; shift 2 ;;
    --duration) DURATION=${2:-}; shift 2 ;;
    --interval) INTERVAL=${2:-}; shift 2 ;;
    --output) OUTPUT=${2:-}; shift 2 ;;
    --minimum-seconds) MINIMUM_SECONDS=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

for value in "$DURATION" "$INTERVAL" "$MINIMUM_SECONDS"; do
  if ! awk -v value="$value" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }'; then
    usage
    exit 2
  fi
done
case "$PID" in
  ""|*[!0-9]*)
    if [ -n "$PID" ]; then usage; exit 2; fi ;;
esac
if [ -z "$PID" ]; then
  PID=$(pgrep -n -x mailficient || true)
fi
if [ -z "$PID" ] || [ ! -r "/proc/$PID/status" ]; then
  printf '%s\n' "Start the normal Mailficient application first, or pass --pid PID." >&2
  exit 2
fi
if [ -z "$OUTPUT" ]; then
  OUTPUT="mailficient-memory-$(date +%Y%m%d-%H%M%S).csv"
fi

printf '%s\n' "elapsed_s,rss_kib,pss_kib,high_water_kib" >"$OUTPUT"
start=$(date +%s)
deadline=$(awk -v start="$start" -v duration="$DURATION" 'BEGIN { print start + duration }')
printf 'Profiling Mailficient PID %s for %s seconds. Trigger repeated Get Mail refreshes during this run.\n' "$PID" "$DURATION"
printf 'Writing %s\n' "$OUTPUT"

while kill -0 "$PID" 2>/dev/null; do
  now=$(date +%s)
  elapsed=$((now - start))
  rss=$(awk '/^VmRSS:/ { print $2; found=1 } END { if (!found) print 0 }' "/proc/$PID/status")
  high_water=$(awk '/^VmHWM:/ { print $2; found=1 } END { if (!found) print 0 }' "/proc/$PID/status")
  if [ -r "/proc/$PID/smaps_rollup" ]; then
    pss=$(awk '/^Pss:/ { print $2; found=1; exit } END { if (!found) print 0 }' "/proc/$PID/smaps_rollup")
  else
    pss=0
  fi
  printf '%s,%s,%s,%s\n' "$elapsed" "$rss" "$pss" "$high_water" >>"$OUTPUT"
  if awk -v now="$now" -v deadline="$deadline" 'BEGIN { exit !(now >= deadline) }'; then
    break
  fi
  sleep "$INTERVAL"
done

if [ ! -r "/proc/$PID/status" ]; then
  printf '%s\n' "Mailficient exited before the requested profile duration ended." >&2
fi
python3 "$ROOT_DIR/tools/analyze-memory-profile.py" "$OUTPUT" --minimum-seconds "$MINIMUM_SECONDS"
