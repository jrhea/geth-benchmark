#!/usr/bin/env bash
#
# Write the markdown summary for a profiling run.
#
#   bash profile-summary.sh <results dir>
#
# Merges each side's per-pass profiles into base.pprof and feature.pprof, or one
# profile.pprof when both sides are the same commit, and renders them with go tool
# pprof. For two refs it leads with where CPU time moved between them.
set -uo pipefail
RES=${1:?usage: profile-summary.sh RESULTS_DIR}
N=${NODES:-30}
cd "$RES" || exit 1
# pprof does not care which toolchain it runs under, so never go fetching one
export GOTOOLCHAIN=local

meta() { python3 -c "import json,sys;print(json.load(open('bench-meta.json')).get(sys.argv[1]) or '')" "$1" 2>/dev/null; }
BASE_REF=$(meta base_ref); BASE_SHA=$(meta base_sha); BASE_LABEL=$(meta base_label)
FEAT_REF=$(meta feature_ref); FEAT_SHA=$(meta feature_sha); FEAT_LABEL=$(meta feature_label)
BLOCKS=$(meta blocks)

# The per-pass files, skipping any a pass left empty.
passes() { find . -path "./run*/$1/cpu.pprof" -size +0 | sort; }
merge() {  # into, from...
  local into=$1; shift
  [ $# -gt 0 ] || return 1
  go tool pprof -proto "$@" > "$into" 2>/dev/null && [ -s "$into" ]
}
top() {  # the rows, without the lines naming the binary and the build
  go tool pprof -top -nodecount="$N" "$@" 2>/dev/null | grep -v '^File:\|^Build ID:\|^Time:'
}
block() { echo '```'; cat; echo '```'; }

B=$(passes baseline); F=$(passes feature)
nb=$(printf '%s' "$B" | grep -c . || true); nf=$(printf '%s' "$F" | grep -c . || true)

if [ "$BASE_SHA" = "$FEAT_SHA" ]; then
  # one ref on both sides, so every pass is the same code
  # shellcheck disable=SC2086
  merge profile.pprof $B $F || { echo "no usable profiles were written"; exit 1; }
  echo "### Profile: \`${FEAT_LABEL:-$FEAT_REF}\`"
  echo
  echo "**${BLOCKS}** blocks per pass · $(( nb + nf )) passes · machine \`$(hostname)\` · \`${FEAT_SHA:0:10}\`"
  echo
  echo "CPU profiles cover the block replay only, not node startup or the rewind after each pass. A profiled run's timings are not a measurement."
  echo
  echo "#### Where the time goes"
  echo
  top profile.pprof | block
  echo
  echo "To explore it, download the artifact and run \`go tool pprof -http=:0 profile.pprof\`."
  exit 0
fi

merge base.pprof $B && hb=1 || hb=
merge feature.pprof $F && hf=1 || hf=
echo "### Profile: \`${BASE_LABEL:-$BASE_REF}\` → \`${FEAT_LABEL:-$FEAT_REF}\`"
echo
echo "**${BLOCKS}** blocks per pass · ${nb} base and ${nf} target passes · machine \`$(hostname)\`"
echo
echo "- **base** \`${BASE_REF}\` @ \`${BASE_SHA:0:10}\`"
echo "- **target** \`${FEAT_REF}\` @ \`${FEAT_SHA:0:10}\`"
echo
echo "CPU profiles cover the block replay only, not node startup or the rewind after each pass. A profiled run's timings are not a measurement."
echo
if [ -z "$hb" ] || [ -z "$hf" ]; then
  echo "Only one side has a usable profile, so there is nothing to compare."
  [ -n "$hb" ] && { echo; echo "#### base"; echo; top base.pprof | block; }
  [ -n "$hf" ] && { echo; echo "#### target"; echo; top feature.pprof | block; }
  [ -n "$hb$hf" ] || exit 1
  exit 0
fi
echo "#### Where CPU time moved"
echo
echo 'Target minus base, largest change first. A positive `flat` is time the target spends that the base does not, a negative one is time it saved.'
echo
top -diff_base base.pprof feature.pprof | block
echo
for side in base feature; do
  name=$side; [ "$side" = feature ] && name=target
  echo "<details><summary>$name, top $N</summary>"
  echo
  top "$side.pprof" | block
  echo
  echo "</details>"
  echo
done
echo "To explore the difference, download the artifact and run \`go tool pprof -http=:0 -diff_base base.pprof feature.pprof\`."
