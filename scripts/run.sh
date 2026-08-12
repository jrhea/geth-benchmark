#!/usr/bin/env bash
#
# Start a benchmark. Run this from your laptop, it goes over tsh.
#
#   bash run.sh --base master --feature my-branch
#
#   --base REF          what to compare against. Branch, tag, commit, or the word
#                       fork-point for where --feature diverged from master.
#   --feature REF       what to measure.
#   --label NAME        groups the run under /home/debian/benchmarks/NAME/.
#                       Defaults to the two refs, and is printed when it starts.
#   --base-label TEXT   what the report heading calls each side, when the ref
#   --feature-label TEXT  itself reads badly, such as a bare commit hash
#   --geth-args FLAGS   extra flags for the geth under test, both sides
#   --blocks N          default 2000
#   --runs N            default 3
#   --warmup N          default the same as --blocks
#   --dry-run           print the command instead of running it
set -uo pipefail
HOST="${BENCH_HOST:-debian@geth-benchmark-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
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

for v in BASE FEATURE; do
  [ -n "${!v}" ] || { echo "--$(echo $v | tr A-Z a-z) is required, try --help" >&2; exit 1; }
done

# Name it after the refs as they were given, before fork-point turns into a hash,
# so this and the workflow agree on where the run lands.
if [ -z "$LABEL" ]; then
  LABEL=$(bash "$HERE/mklabel.sh" "$FEATURE" "$BASE") || exit 1
  echo "label: $LABEL"
fi

# Resolve the fork point on the box. Its clone is the one that builds, and it has
# both refs fetched, so a laptop that has not fetched the branch cannot produce a
# stale answer here.
if [ "$BASE" = fork-point ] || [ "$BASE" = forkpoint ]; then
  echo "resolving the fork point of $FEATURE against origin/master..."
  RESOLVED=$(tsh ssh "$HOST" "bash -s $(printf %q "$FEATURE")" <<'REMOTE'
set -uo pipefail
cd /home/debian/go-ethereum || exit 1
git fetch -q origin --tags 2>/dev/null
F=$(git rev-parse --verify -q "origin/$1" || git rev-parse --verify -q "$1") || {
  echo "cannot resolve $1 on the box" >&2; exit 1; }
MB=$(git merge-base origin/master "$F") || {
  echo "no common ancestor between origin/master and $1" >&2; exit 1; }
echo "$MB $F $(git rev-list --count "$MB..origin/master")"
REMOTE
  ) || exit 1
  set -- $RESOLVED
  BASE=$1; FEAT_SHA=$2; BEHIND=$3
  if [ "$BASE" = "$FEAT_SHA" ]; then
    echo "the fork point is $FEATURE itself, so there is nothing to compare" >&2
    exit 1
  fi
  BASE_LABEL="${BASE_LABEL:-fork point}"
  echo "  $BASE  ($BEHIND commits behind origin/master)"
fi

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
