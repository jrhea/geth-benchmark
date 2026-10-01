#!/usr/bin/env bash
#
# How far a benchmark has got. Run this from your laptop, it goes over tsh.
#
#   bash progress.sh [label] [blocks] [runs]
#
# With no label it reports whatever is running. For the run that is going it uses
# that run's own blocks and runs, so they only need passing for an earlier one,
# where they default to 2000 and 3 like bench.sh. Profile runs are found too.
set -uo pipefail
HOST="${BENCH_HOST:-debian@geth-benchmark-1}"

tsh ssh "$HOST" "bash -s $(printf %q "${1:-}") $(printf %q "${2:-}") $(printf %q "${3:-}")" <<'REMOTE'
set -uo pipefail
LABEL=$1
BLOCKS=$2
RUNS=$3
B=/home/debian/benchmarks

# There is one bench unit, so check whose it is before reporting it as running.
STATE=$(systemctl is-active bench 2>/dev/null | head -1)
UNIT=$(systemctl show bench -p Environment --value 2>/dev/null | tr ' ' '\n')
unit() { printf '%s\n' "$UNIT" | sed -n "s/^$1=//p"; }
NOW=$(unit LABEL)

if [ -z "$LABEL" ]; then
  [ -n "$NOW" ] || { echo "nothing running, pass a label"; exit 0; }
  LABEL=$NOW
  echo "$LABEL"
fi

MINE=false
[ "$STATE" = active ] && [ "$NOW" = "$LABEL" ] && MINE=true
# a profile runs once, and a smoke test replays fewer blocks
if $MINE; then
  BLOCKS=${BLOCKS:-$(unit BLOCKS)}
  RUNS=${RUNS:-$(unit RUNS)}
fi
BLOCKS=${BLOCKS:-2000}
RUNS=${RUNS:-3}

# Profile runs keep to a directory of their own, and write profile.md, not a report.
RUN=$B/bench/$LABEL DONEFILE=report.md
if $MINE; then
  [ -n "$(unit PROFILE)" ] && RUN=$B/profile/$LABEL DONEFILE=profile.md
elif [ ! -d "$RUN" ] && [ -d "$B/profile/$LABEL" ]; then
  RUN=$B/profile/$LABEL DONEFILE=profile.md
fi
PASSES=$(( 2 * RUNS + 1 ))
TOTAL=$(( PASSES * BLOCKS ))

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
    [ -f "${D%/}/$DONEFILE" ] && WHERE="${DONEFILE%.md} ready, still rewinding" || WHERE="rewinding"
  fi
else
  STATE=inactive
  [ -n "$NOW" ] && NOTE="   [$NOW is running]"
fi

echo "$STATE  pass $P/$PASSES ($WHERE)  $DONE/$TOTAL blocks  $(( DONE * 100 / TOTAL ))%$NOTE"
REMOTE
