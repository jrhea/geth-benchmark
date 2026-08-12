#!/usr/bin/env bash
#
# Standard A/B benchmark runner. Run ON the box as debian.
#
#   BASE=master FEATURE=my-branch bash bench.sh
#
# Optional: BLOCKS (2000), RUNS (3), WARMUP (defaults to BLOCKS). A warmup only
# covers the blocks it replays, so keep it equal to the window. LABEL groups the
# run on disk and defaults to the two refs, see mklabel.sh.
#
# BASE and FEATURE take a branch, a tag or a commit. BASE_LABEL and FEATURE_LABEL
# set what the report calls them, which is worth setting when the ref is a hash:
#
#   BASE=a1b2c3d4 BASE_LABEL="fork point" FEATURE=my-branch bash bench.sh
#
# GETH_ARGS adds flags to the geth under test, on both sides:
#
#   GETH_ARGS="--cache.noprefetch" BASE=master FEATURE=mine bash bench.sh
#
# Writes to /home/debian/benchmarks/<LABEL>/results/<timestamp>/, report included.
#
# Setup uses pkill rather than systemctl stop, which is unreliable from inside a
# systemd unit. Every wait here logs progress and gives up loudly.
set -uo pipefail
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
# Matches a running geth and nothing else. A bare "geth" would also match these
# scripts, which live under a path containing the word.
GETH_PROC="/[g]eth(_[0-9a-f]+)? --datadir"
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${BASE:?set BASE}"
FEATURE="${FEATURE:?set FEATURE}"
LABEL="${LABEL:-$(bash "$HERE/mklabel.sh" "$FEATURE" "$BASE")}"
RUNS="${RUNS:-3}"
# extra flags for the geth under test, applied to both sides
GETH_ARGS="${GETH_ARGS:-}"
BASE_LABEL="${BASE_LABEL:-$BASE}"
FEATURE_LABEL="${FEATURE_LABEL:-$FEATURE}"
RUNS_DIR=/home/debian/benchmarks

# The pinned head and window size come from whatever new-window.sh last set up.
# Keeping a copy here would mean a window move silently rewinds every run to the
# previous one. Anything passed in still wins, so a short smoke test is easy.
BLOCKS_IN="${BLOCKS:-}"
WARMUP_IN="${WARMUP:-}"
WINDOW=$RUNS_DIR/window.env
[ -r "$WINDOW" ] || {
  echo "no $WINDOW. Run new-window.sh, or write it by hand:" >&2
  echo "  printf 'PIN=25677500\\nBLOCKS=2000\\n' > $WINDOW" >&2
  exit 1
}
# shellcheck disable=SC1090
. "$WINDOW"
PIN="${PIN:?$WINDOW sets no PIN}"
BLOCKS="${BLOCKS_IN:-${BLOCKS:?$WINDOW sets no BLOCKS}}"
WARMUP="${WARMUP_IN:-$BLOCKS}"
LOCAL=http://127.0.0.1:8545
CACHE=http://127.0.0.1:8600
OUT=$RUNS_DIR/${LABEL}
SB=$OUT/slowblock.log

write_meta() {
  cat > "$1" <<EOF
{
  "base_ref": "$BASE",
  "base_label": "$BASE_LABEL",
  "base_sha": "$BASE_SHA",
  "feature_ref": "$FEATURE",
  "feature_label": "$FEATURE_LABEL",
  "feature_sha": "$FEATURE_SHA",
  "blocks": $BLOCKS,
  "runs": $RUNS,
  "warmup": $WARMUP,
  "pinned_head": $PIN,
  "machine": "$(hostname)",
  "slowblock_log": "$SB",
  "geth_args": "$GETH_ARGS",
  "started": "$STARTED"
}
EOF
}

head_num() { curl -s --max-time 8 -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "$LOCAL" 2>/dev/null \
  | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["result"],16))' 2>/dev/null; }
wait_gone() {
  local budget=${1:-1200} waited=0
  while pgrep -f "$GETH_PROC" >/dev/null; do
    sleep 5; waited=$((waited+5))
    [ $((waited % 60)) -eq 0 ] && log "    waiting for geth to exit (${waited}s)"
    [ "$waited" -ge "$budget" ] && { log "    GIVING UP after ${budget}s"; return 1; }
  done
  return 0
}

# One datadir and one port pair, so runs must not overlap. Two at once rewind the
# same chain data underneath each other and both look healthy while doing it.
# Held for the life of the script, released when it exits however it exits.
mkdir -p "$RUNS_DIR"
exec 9>"$RUNS_DIR/.lock"
if ! flock -n 9; then
  log "ABORT: a benchmark is already running"
  OTHER=$(systemctl show bench -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^LABEL=//p')
  [ -n "$OTHER" ] && log "  it is $OTHER"
  exit 1
fi

log "refs: base=$BASE feature=$FEATURE  blocks=$BLOCKS runs=$RUNS warmup=$WARMUP"
[ -n "$GETH_ARGS" ] && log "extra geth flags: $GETH_ARGS"
cd /home/debian/go-ethereum
git fetch -q origin --tags
git fetch -q upstream 2>/dev/null || true
# Move each local branch onto its remote, or a second run of the same branch name
# builds whatever was checked out the first time. Nothing is developed on this
# box, so a forced move is safe. Detach first because the harness leaves HEAD on
# a branch and git will not move the one that is checked out.
git checkout -q --detach 2>/dev/null || true
for r in "$BASE" "$FEATURE"; do
  git rev-parse --verify -q "origin/$r" >/dev/null &&
    git branch -f "$r" "origin/$r" >/dev/null 2>&1
  log "  $r -> $(git rev-parse --short "$r" 2>/dev/null || echo UNRESOLVED)"
done
# Pin the commits now. A branch can move between the run and the report.
BASE_SHA=$(git rev-parse "$BASE" 2>/dev/null || echo "")
FEATURE_SHA=$(git rev-parse "$FEATURE" 2>/dev/null || echo "")
STARTED=$(date -u '+%Y-%m-%d %H:%M')

# The harness gets its blocks from here and gives up if it cannot, so check
# before spending several minutes pinning the head.
curl -s --max-time 10 -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
  "$CACHE" >/dev/null 2>&1 || {
    log "ABORT: no block cache on $CACHE. sudo systemctl start blockcache"
    exit 1
  }

log "clearing the field"
for u in blsync-bench geth-bench; do sudo systemctl stop --no-block "$u.service" 2>/dev/null || true; done
pkill -TERM -f "$GETH_PROC" 2>/dev/null || true
wait_gone 1200 || exit 1

log "verifying the pinned head"
# Keep systemd-run's own error. Discarding it turned any failure to start into a
# silent 200 second wait and then "rpc never came up", which says nothing.
if ! ERR=$(sudo systemd-run --unit=bench_pin --uid=debian --gid=debian --collect \
  --property=TimeoutStopSec=infinity \
  /home/debian/go-ethereum/build/bin/geth --datadir /datadrive/geth \
    --authrpc.jwtsecret /datadrive/geth/geth/jwtsecret \
    --http --http.addr 127.0.0.1 --http.api eth,debug,net,web3 \
    --authrpc.addr 127.0.0.1 --authrpc.port 8551 \
    --history.chain postprague --history.state 0 \
    --history.logs.disable --history.transactions 1 --cache 16384 2>&1); then
  log "ABORT: could not start the pinning geth"
  log "  $ERR"
  exit 1
fi
for i in $(seq 1 40); do
  H=$(head_num); [ -n "$H" ] && break
  # if it died there is no point waiting out the rest of the budget
  systemctl is-active --quiet bench_pin || {
    log "ABORT: the pinning geth exited early, see: journalctl -u bench_pin -n 30"
    exit 1
  }
  sleep 5
done
[ -n "${H:-}" ] || { log "ABORT: rpc never came up, see: journalctl -u bench_pin -n 30"; exit 1; }
log "  head=$H (pin $PIN)"
if [ "$H" != "$PIN" ]; then
  log "  rewinding $(( H - PIN ))"
  curl -s --max-time 900 -X POST -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"debug_setHead\",\"params\":[\"$(printf '0x%x' $PIN)\"]}" "$LOCAL" >/dev/null || true
  for i in $(seq 1 180); do [ "$(head_num)" = "$PIN" ] && break; sleep 5; done
  [ "$(head_num)" = "$PIN" ] || { log "ABORT: rewind did not land"; exit 1; }
  log "  head now $PIN"
fi
pkill -TERM -f "$GETH_PROC" 2>/dev/null || true
wait_gone 1800 || exit 1
sudo systemctl reset-failed bench_pin.service 2>/dev/null || true
log "  geth down, head pinned"

mkdir -p "$OUT"
# Past runs stay. These two are the only files a run appends to, and geth opens
# its log with O_APPEND, so a crashed run would otherwise leak passes into this
# one and throw off the pass count in the breakdown.
rm -f "$SB" "$OUT/reth-bench.log"
write_meta "$OUT/bench-meta.json"

# Write the report as soon as the last pass has its CSV. The harness then spends
# a couple more minutes on its final rewind and flush, and there is no reason to
# wait for that to read the numbers.
# Count up from what is already here. A re-used label keeps its earlier runs, and
# counting the whole tree would meet the target at once, then regenerate the
# previous run's report instead of waiting for this one.
HAVE=$(find "$OUT/results" -name combined_latency.csv 2>/dev/null | wc -l)
(
  want=$(( HAVE + 2 * RUNS ))
  for _ in $(seq 1 720); do
    [ "$(find "$OUT/results" -name combined_latency.csv 2>/dev/null | wc -l)" -ge "$want" ] && break
    sleep 10
  done
  RES=$(ls -1dt "$OUT"/results/*/ 2>/dev/null | head -1); RES=${RES%/}
  [ -n "$RES" ] || exit 0
  python3 "$HERE/report.py" --results "$RES" > "$RES/report.md" 2>/dev/null &&
    log "early report ready: $RES/report.md"
) &
EARLY=$!

log "running the harness (it will build $FEATURE first, a few minutes)"
reth-bench-compare --client geth \
  --baseline-ref "$BASE" --feature-ref "$FEATURE" \
  --blocks "$BLOCKS" --runs "$RUNS" --warmup-blocks "$WARMUP" \
  --datadir /datadrive/geth \
  --rpc-url $CACHE \
  --output-dir "$OUT" \
  -- --debug.logslowblock 0 --log.file "$SB" $GETH_ARGS
RC=$?
kill "$EARLY" 2>/dev/null; wait "$EARLY" 2>/dev/null
log "harness exit=$RC"
RES=$(ls -1dt $OUT/results/*/ 2>/dev/null | head -1)
RES="${RES%/}"
log "results: $RES"
log "slow-block lines: $(grep -c execution_ms "$SB" 2>/dev/null || echo 0)"

[ -n "$RES" ] || { log "no results dir, nothing to report"; exit "$RC"; }

# Move the logs in with that run's CSVs, so re-running the label leaves each set
# self-contained instead of sharing one log at the top.
mv -f "$SB" "$RES/slowblock.log" 2>/dev/null && SB="$RES/slowblock.log"
mv -f "$OUT/reth-bench.log" "$RES/reth-bench.log" 2>/dev/null || true
write_meta "$RES/bench-meta.json"

log "writing the report"
if python3 "$HERE/report.py" --results "$RES" > "$RES/report.md"; then
  log "report: $RES/report.md"
else
  log "REPORT FAILED, the raw results are still in $RES"
fi
exit "$RC"
