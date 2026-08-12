#!/usr/bin/env bash
#
# Start bench.sh in its own systemd unit. Run this ON the box as debian.
#
#   BASE=master FEATURE=my-branch bash start-bench.sh
#
# Takes the same variables bench.sh does and passes on only the ones that were
# set, so bench.sh keeps its own defaults. Both entry points come through here,
# so the unit's properties cannot drift between them.
#
# WAIT=1 blocks until the run finishes and exits with its status. A dispatch
# needs that, or the job goes green at launch. An interactive launch does not.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

SET=()
for v in BASE BASE_LABEL FEATURE FEATURE_LABEL LABEL BLOCKS RUNS WARMUP GETH_ARGS; do
  [ -n "${!v:-}" ] && SET+=("--setenv=$v=${!v}")
done

# bench.slice keeps it off the housekeeping cores, TimeoutStopSec=infinity keeps
# systemd from killing a geth that is still flushing.
exec sudo systemd-run --unit=bench --slice=bench.slice --uid=debian --gid=debian \
  --collect --property=TimeoutStopSec=infinity ${WAIT:+--wait} \
  "${SET[@]}" bash "$HERE/bench.sh"
