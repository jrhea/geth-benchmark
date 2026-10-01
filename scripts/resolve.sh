#!/usr/bin/env bash
#
# Turn a dispatch's inputs into the refs and label a run uses. Run this ON the box.
#
#   FEATURE_FORK=jrhea FEATURE=my-branch BASE_FORK=ethereum BASE=fork-point bash resolve.sh
#
# Takes BASE, BASE_FORK, FEATURE, FEATURE_FORK and LABEL from the environment, and
# MODE=single to profile one ref, which makes the feature both sides. Writes
# feature, label, base and base_label to $GITHUB_OUTPUT, or stdout outside
# Actions. Both workflows call this, so they cannot disagree about what a run is.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${GETH_REPO:-/home/debian/go-ethereum}"
OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
BASE="${BASE:-}"
LABEL="${LABEL:-}"

# The dropdown already names the repo, so spell it out either way. fork-point is
# a keyword rather than a branch, so it never takes one.
FEATURE="$FEATURE_FORK:$FEATURE"
if [ "${MODE:-compare}" = single ]; then
  BASE=$FEATURE
elif [ "$BASE" != fork-point ]; then
  BASE="$BASE_FORK:$BASE"
fi
echo "feature=$FEATURE" >> "$OUTPUT"

# Name it from the refs as given, before fork-point becomes a hash. A given label
# becomes a directory name too, so it gets cleaned as well.
if [ -n "$LABEL" ]; then
  LABEL=$(bash "$HERE/mklabel.sh" "$LABEL") || exit 1
elif [ "${MODE:-compare}" = single ]; then
  LABEL=$(bash "$HERE/mklabel.sh" "$FEATURE") || exit 1
else
  LABEL=$(bash "$HERE/mklabel.sh" "$FEATURE" "$BASE") || exit 1
fi
echo "label=$LABEL" >> "$OUTPUT"
echo "label: $LABEL"
# the exact one, which run-name cannot know
echo "label \`$LABEL\`" >> "$SUMMARY"

cd "$REPO" || exit 1
git fetch -q origin --tags || exit 1
if [ "$BASE" = fork-point ]; then
  # master from upstream, whoever the feature belongs to, so base_fork does not
  # apply here
  FP=$(bash "$HERE/fork-point.sh" "$FEATURE") || exit 1
  set -- $FP
  BASE=$1
  echo "base_label=fork point" >> "$OUTPUT"
  echo "fork point: $BASE ($3 commits behind master)"
else
  echo "base_label=" >> "$OUTPUT"
fi
echo "base=$BASE" >> "$OUTPUT"
