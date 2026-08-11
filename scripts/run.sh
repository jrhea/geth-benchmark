#!/usr/bin/env bash
#
# Start a benchmark. Run this from your laptop, it goes over tsh.
#
#   bash run.sh --base master --feature my-branch --label my-label
#
#   --base REF          what to compare against. Branch, tag or commit.
#   --feature REF       what to measure.
#   --label NAME        groups the run under /home/debian/benchmarks/NAME/
#   --base-label TEXT   what the report heading calls each side, when the ref
#   --feature-label TEXT  itself reads badly, such as a bare commit hash
#   --geth-args FLAGS   extra flags for the geth under test, both sides
#   --blocks N          default 2000
#   --runs N            default 3
#   --warmup N          default the same as --blocks
#   --dry-run           print the command instead of running it
set -uo pipefail
HOST="${BENCH_HOST:-debian@geth-benchmark-1}"
REMOTE=/home/debian/geth-benchmark/scripts

BASE= FEATURE= LABEL= BASE_LABEL= FEATURE_LABEL= GETH_ARGS=
BLOCKS= RUNS= WARMUP= DRY=

while [ $# -gt 0 ]; do
  case "$1" in
    --base)          BASE=$2; shift 2 ;;
    --feature)       FEATURE=$2; shift 2 ;;
    --label)         LABEL=$2; shift 2 ;;
    --base-label)    BASE_LABEL=$2; shift 2 ;;
    --feature-label) FEATURE_LABEL=$2; shift 2 ;;
    --geth-args)     GETH_ARGS=$2; shift 2 ;;
    --blocks)        BLOCKS=$2; shift 2 ;;
    --runs)          RUNS=$2; shift 2 ;;
    --warmup)        WARMUP=$2; shift 2 ;;
    --dry-run)       DRY=1; shift ;;
    -h|--help)       awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "unknown option $1, try --help" >&2; exit 1 ;;
  esac
done

for v in BASE FEATURE LABEL; do
  [ -n "${!v}" ] || { echo "--$(echo $v | tr A-Z a-z) is required, try --help" >&2; exit 1; }
done

# Only set what was asked for, so bench.sh keeps its own defaults.
SETENV=()
add() { [ -n "$2" ] && SETENV+=("--setenv=$1=$2"); return 0; }
add BASE "$BASE";                 add FEATURE "$FEATURE"
add LABEL "$LABEL";               add BASE_LABEL "$BASE_LABEL"
add FEATURE_LABEL "$FEATURE_LABEL"; add GETH_ARGS "$GETH_ARGS"
add BLOCKS "$BLOCKS";             add RUNS "$RUNS"
add WARMUP "$WARMUP"

# bench.slice keeps it off the housekeeping cores, TimeoutStopSec=infinity keeps
# systemd from killing a geth that is still flushing.
CMD="sudo systemd-run --unit=bench --slice=bench.slice --uid=debian --gid=debian"
CMD="$CMD --collect --property=TimeoutStopSec=infinity"
for e in "${SETENV[@]}"; do CMD="$CMD $(printf '%q' "$e")"; done
CMD="$CMD bash $REMOTE/bench.sh"

if [ -n "$DRY" ]; then printf '%s\n' "$CMD"; exit 0; fi

tsh ssh "$HOST" "$CMD" || exit 1
cat <<EOF

started. it takes about 40 minutes.

  progress:  bash scripts/progress.sh $LABEL
  report:    bash scripts/latest-report.sh $LABEL
EOF
