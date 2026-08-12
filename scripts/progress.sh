#!/usr/bin/env bash
#
# How far a benchmark has got. Run this from your laptop, it goes over tsh.
#
#   bash progress.sh [label] [blocks] [runs]
#
# With no label it reports whatever is running. blocks and runs default to 2000
# and 3, matching bench.sh, and only need passing if the run used something else.
set -uo pipefail
HOST="${BENCH_HOST:-debian@geth-benchmark-1}"

tsh ssh "$HOST" "bash -s $(printf %q "${1:-}") ${2:-2000} ${3:-3}" <<'REMOTE'
set -uo pipefail
LABEL=$1
BLOCKS=$2
RUNS=$3

# There is one bench unit, so check whose it is before reporting it as running.
STATE=$(systemctl is-active bench 2>/dev/null | head -1)
NOW=$(systemctl show bench -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^LABEL=//p')

if [ -z "$LABEL" ]; then
  [ -n "$NOW" ] || { echo "nothing running, pass a label"; exit 0; }
  LABEL=$NOW
  echo "$LABEL"
fi

RUN=/home/debian/benchmarks/$LABEL
PASSES=$(( 2 * RUNS + 1 ))
TOTAL=$(( PASSES * BLOCKS ))
MINE=false
[ "$STATE" = active ] && [ "$NOW" = "$LABEL" ] && MINE=true

# bench.sh builds geth and pins the head before it creates the directory, so a
# run can be several minutes in with nothing on disk yet.
if [ ! -d "$RUN" ]; then
  $MINE && echo "active  building and pinning, no blocks replayed yet" \
        || echo "no runs for $LABEL yet"
  exit 0
fi

# The log is at the top level while the run is going and moves in with the results
# when it ends. Only fall back to a finished run's copy when this label is not the
# one running, or a relaunch under a re-used label reports the previous run's 100%.
SB=$RUN/slowblock.log
if [ ! -f "$SB" ]; then
  $MINE && { echo "active  building and pinning, no blocks replayed yet"; exit 0; }
  SB=$(ls -1t "$RUN"/results/*/slowblock.log 2>/dev/null | head -1)
fi
# grep -c prints 0 AND exits 1 on a file with no matches, so an "|| echo 0"
# fallback would append a second 0. head -1 also guards against several files.
DONE=$(grep -c execution_ms "${SB:-/nonexistent}" 2>/dev/null | head -1)
[ -n "$DONE" ] || DONE=0
P=$(( DONE / BLOCKS + 1 )); [ "$P" -gt "$PASSES" ] && P=$PASSES

if [ "$P" -eq 1 ]; then
  WHERE=warmup
else
  M=$(( P - 1 ))                        # 1..2*RUNS
  RUN_N=$(( (M + 1) / 2 ))
  POS=$(( 2 - M % 2 ))                  # first or second pass of that run
  # runs alternate which reference leads
  [ $(( (RUN_N + POS) % 2 )) -eq 0 ] && WHERE="run $RUN_N base" || WHERE="run $RUN_N feature"
fi

NOTE=""
if $MINE; then
  # The report is written as soon as the last pass has its CSV, so at this point
  # it is usually already there while the harness finishes its rewind and flush.
  if [ "$DONE" -ge "$TOTAL" ]; then
    # this run's directory, not a report left behind by an earlier one
    D=$(ls -1dt "$RUN"/results/*/ 2>/dev/null | head -1)
    [ -f "${D%/}/report.md" ] && WHERE="report ready, still rewinding" || WHERE="rewinding"
  fi
else
  STATE=inactive
  [ -n "$NOW" ] && NOTE="   [$NOW is running]"
fi

echo "$STATE  pass $P/$PASSES ($WHERE)  $DONE/$TOTAL blocks  $(( DONE * 100 / TOTAL ))%$NOTE"
REMOTE
