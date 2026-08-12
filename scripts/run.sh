#!/usr/bin/env bash
#
# Start a benchmark. Run this from your laptop, it goes over tsh.
#
#   bash run.sh --base master --feature my-branch
#
#   --base REF          what to compare against. Branch, tag, commit, or the word
#                       fork-point for where --feature diverged from master.
#   --feature REF       what to measure.
#
#   Either takes owner:ref to read it from someone else's go-ethereum, as long as
#   they are listed in forks.txt:
#
#     bash run.sh --base fork-point --feature rjl493456442:optimize-commit
#
#   --label NAME        groups the run under /home/debian/benchmarks/NAME/.
#                       Defaults to the two refs, and is printed when it starts.
#   --base-label TEXT   what the report heading calls each side, when the ref
#   --feature-label TEXT  itself reads badly, such as a bare commit hash
#   --geth-args FLAGS   extra flags for the geth under test, both sides
#   --blocks N          default 2000
#   --runs N            default 3
#   --warmup N          default the same as --blocks
#   --dry-run           print the launch command instead of running it. It still
#                       updates the box's clone and resolves the refs.
set -uo pipefail
HOST="${BENCH_HOST:-debian@geth-benchmark-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO=/home/debian/geth-benchmark
REMOTE=$REPO/scripts

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

# The box runs whatever is in its clone, so update it before anything reads a
# script from there, --dry-run included. A dispatch does the same, and local
# edits on the box are lost either way.
tsh ssh "$HOST" "cd $REPO && git fetch -q origin && git reset -q --hard origin/main &&
                 git submodule update --init -q" || exit 1

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
  echo "resolving the fork point of $FEATURE..."
  RESOLVED=$(tsh ssh "$HOST" "bash /home/debian/geth-benchmark/scripts/fork-point.sh $(printf %q "$FEATURE")") || exit 1
  set -- $RESOLVED
  BASE=$1; FEAT_SHA=$2; BEHIND=$3
  if [ "$BASE" = "$FEAT_SHA" ]; then
    echo "the fork point is $FEATURE itself, so there is nothing to compare" >&2
    exit 1
  fi
  BASE_LABEL="${BASE_LABEL:-fork point}"
  echo "  $BASE  ($BEHIND commits behind master)"
fi

# Only pass what was asked for, so bench.sh keeps its own defaults. start-bench.sh
# turns these into the unit's environment and owns its properties.
VARS=()
add() { [ -n "$2" ] && VARS+=("$1=$2"); return 0; }
add BASE "$BASE";                 add FEATURE "$FEATURE"
add LABEL "$LABEL";               add BASE_LABEL "$BASE_LABEL"
add FEATURE_LABEL "$FEATURE_LABEL"; add GETH_ARGS "$GETH_ARGS"
add BLOCKS "$BLOCKS";             add RUNS "$RUNS"
add WARMUP "$WARMUP"

CMD=
for e in "${VARS[@]}"; do CMD="$CMD$(printf '%q' "$e") "; done
CMD="${CMD}bash $REMOTE/start-bench.sh"

if [ -n "$DRY" ]; then printf '%s\n' "$CMD"; exit 0; fi

tsh ssh "$HOST" "$CMD" || exit 1
cat <<EOF

started. it takes about 40 minutes.

  progress:  bash scripts/progress.sh $LABEL
  report:    bash scripts/latest-report.sh $LABEL
EOF
