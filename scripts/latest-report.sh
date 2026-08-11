#!/usr/bin/env bash
#
# Print a benchmark's most recent report. Run this from your laptop, it goes
# over tsh.
#
#   bash latest-report.sh my-branch
#   bash latest-report.sh              # list what is on the box
#
# Reports live with the run that produced them, in results/<timestamp>/, so the
# newest one takes a lookup rather than a fixed path.
set -uo pipefail
HOST="${BENCH_HOST:-debian@geth-benchmark-1}"

tsh ssh "$HOST" "bash -s ${1:-}" <<'REMOTE'
B=/home/debian/benchmarks
LABEL="${1:-}"

if [ -z "$LABEL" ]; then
  printf "  %-30s %-18s %s\n" LABEL "LATEST RUN" REPORT
  for d in "$B"/*/; do
    n=$(basename "$d")
    [ "$n" = archive ] && continue
    t=$(ls -1dt "$d"results/*/ 2>/dev/null | head -1)
    if [ -z "$t" ]; then
      printf "  %-30s %-18s %s\n" "$n" "-" "no runs"
    elif [ -f "$t/report.md" ]; then
      printf "  %-30s %-18s %s\n" "$n" "$(basename "$t")" "yes"
    else
      printf "  %-30s %-18s %s\n" "$n" "$(basename "$t")" "not written"
    fi
  done
  exit 0
fi

[ -d "$B/$LABEL" ] || { echo "no benchmark called $LABEL, run without arguments to list" >&2; exit 1; }
# Newest run first, then its report. Picking the newest report.md by mtime would
# quietly hand over an older run's when the latest has not written one yet.
d=$(ls -1dt "$B/$LABEL"/results/*/ 2>/dev/null | head -1); d=${d%/}
[ -n "$d" ] || { echo "$LABEL has no runs yet" >&2; exit 1; }
if [ ! -f "$d/report.md" ]; then
  echo "$LABEL: newest run $(basename "$d") has no report yet, it may still be running" >&2
  prev=$(ls -1dt "$B/$LABEL"/results/*/report.md 2>/dev/null | head -1)
  [ -n "$prev" ] && echo "  an earlier one: cat $prev" >&2
  exit 1
fi
cat "$d/report.md"
REMOTE
