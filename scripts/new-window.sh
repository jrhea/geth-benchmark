#!/usr/bin/env bash
#
# Move the benchmark window. Run ON the box as debian.
#
#   bash new-window.sh --blocks 2000
#
# No external RPC needed. The window blocks sit below the tip, so the local node
# already has them, and we cache them before the rewind removes them. Tip
# detection uses the beacon API that blsync uses.
#
# Options:
#   --blocks N        window size, default 2000
#   --margin N        gap between the pinned head and tip, default 200
#   --datadir PATH    default /datadrive/geth (only used in the summary)
#   --cache PATH      default /datadrive/blockcache
#   --max-rewind N    refuse to rewind further than this, default 50000
#   --source-rpc URL  fetch blocks from here instead of the local node
#   --pin N           pin at this exact block instead of tip-blocks-margin, and
#                     cache everything from there to tip. Use this to sit just
#                     above the snap-sync pivot so the window can grow.
#
# --max-rewind guards the datadir. setHead truncates the freezer and deletes
# bodies and receipts above the new head, unwinding state history with them.
# Closing the gap again means a fresh snap sync, which resets the pivot floor and
# discards the state history. For an older window, copy the datadir first:
#
#   sudo systemctl stop blsync-bench geth-bench
#   sudo cp -a /datadrive/geth /datadrive/geth-YYYY-MM-DD
#   bash new-window.sh --datadir /datadrive/geth-YYYY-MM-DD --max-rewind 2000000
set -uo pipefail

BLOCKS=2000
MARGIN=200
DATADIR=/datadrive/geth
CACHE=/datadrive/blockcache
MAX_REWIND=50000
SOURCE_RPC=""
PIN_AT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    --blocks) BLOCKS="$2"; shift 2 ;;
    --margin) MARGIN="$2"; shift 2 ;;
    --datadir) DATADIR="$2"; shift 2 ;;
    --cache) CACHE="$2"; shift 2 ;;
    --max-rewind) MAX_REWIND="$2"; shift 2 ;;
    --source-rpc) SOURCE_RPC="$2"; shift 2 ;;
    --pin) PIN_AT="$2"; shift 2 ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
LOCAL=http://127.0.0.1:8545
HERE="$(cd "$(dirname "$0")" && pwd)"

ethnum() {  # $1 = rpc url
  curl -s --max-time 20 -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "$1" \
    | python3 -c 'import sys,json; print(int(json.load(sys.stdin)["result"],16))'
}

beacon_exec_head() {
  local ep
  ep=$(echo "$BEACON_API" | cut -d, -f1)
  curl -s --max-time 20 -H "$BEACON_HEADER" "$ep/eth/v2/beacon/blocks/head" \
    | python3 -c 'import sys,json; print(int(json.load(sys.stdin)["data"]["message"]["body"]["execution_payload"]["block_number"]))'
}

# Beacon creds, for tip detection. The env file is 0600 root-owned so it needs
# sudo to read; pull out just the two fields rather than sourcing it.
BEACON_API=$(sudo grep -m1 '^BEACON_API=' /etc/bench/blsync.env | cut -d= -f2-)
BEACON_HEADER=$(sudo grep -m1 '^BEACON_HEADER=' /etc/bench/blsync.env | cut -d= -f2- | tr -d '"')
[ -n "$BEACON_API" ] && [ -n "$BEACON_HEADER" ] || {
  echo "could not read beacon config from /etc/bench/blsync.env"; exit 1; }

# ------------------------------------------------------------- sync to tip
log "starting geth + blsync"
sudo systemctl start geth-bench.service
sleep 12
sudo systemctl start blsync-bench.service

log "waiting for the node to reach tip"
while true; do
  sleep 30
  LH=$(ethnum "$LOCAL" 2>/dev/null) || { log "  local rpc not ready"; continue; }
  BH=$(beacon_exec_head 2>/dev/null) || { log "  beacon api not answering"; continue; }
  log "  local $LH, chain $BH, behind $(( BH - LH ))"
  [ $(( BH - LH )) -le 4 ] && break
done

TIP=$LH
if [ -n "$PIN_AT" ]; then
  # Explicit pin block. Cache everything from there up to tip, since --blocks is
  # chosen per run by the harness and the window grows as the chain advances.
  PIN=$PIN_AT
  BLOCKS=$(( TIP - PIN ))
  log "explicit pin at $PIN, caching the $BLOCKS blocks up to tip"
else
  PIN=$(( TIP - BLOCKS - MARGIN ))
fi
REWIND=$(( TIP - PIN ))
log "tip $TIP, want to pin at $PIN (rewind $REWIND)"

if [ "$REWIND" -gt "$MAX_REWIND" ]; then
  log "REFUSING: rewind of $REWIND exceeds --max-rewind $MAX_REWIND"
  log "see the comment at the top of this script, copy the datadir instead"
  exit 1
fi

# The snap-sync pivot is a hard floor. State history only exists from the pivot
# forward, so rewinding below it leaves the head with no reachable state, which is
# the same broken datadir as rewinding with blsync attached. Refuse rather than try.
PIVOT=$(sudo journalctl -u geth-bench -o cat 2>/dev/null \
  | grep -oE "Disabled snap-sync after pivot commitment +number=[0-9,]+" \
  | tail -1 | grep -oE "[0-9,]+$" | tr -d ',')
if [ -n "${PIVOT:-}" ]; then
  FLOOR=$(( PIVOT + 64 ))
  log "snap-sync pivot $PIVOT, floor $FLOOR"
  if [ "$PIN" -lt "$FLOOR" ]; then
    NEED=$(( FLOOR + BLOCKS + MARGIN ))
    WAIT=$(( (NEED - TIP) / 300 ))
    log "REFUSING: pin $PIN is below the pivot floor $FLOOR."
    log "  A ${BLOCKS}-block window needs tip >= $NEED, tip is $TIP."
    log "  That is $(( NEED - TIP )) blocks away, roughly ${WAIT}h at 300 blocks/hour."
    log "  Options: wait, use a smaller --blocks, or pin at the floor now and let"
    log "  the window grow (the harness only needs pin+blocks <= tip at run time)."
    exit 1
  fi
else
  log "WARNING: could not determine the snap-sync pivot from the journal."
  log "  If this datadir was snap synced recently, verify the pinned block is above it."
fi

# ------------------------------------------------------------- cache first
# Do this BEFORE the rewind. Every block we need is below the tip, so the local
# node has it now and will not after setHead deletes it.
FROM=$(( PIN - 64 ))   # reth-bench also reads N-32 and N-64 for safe/finalized
TO=$(( PIN + BLOCKS ))
FETCH_FROM="${SOURCE_RPC:-$LOCAL}"

log "caching blocks $FROM..$TO from $FETCH_FROM"
sudo systemctl stop blockcache.service 2>/dev/null || true
rm -rf "$CACHE"
mkdir -p "$CACHE"
if ! python3 "$HERE/blockcache/fetch.py" \
      --rpc-url "$FETCH_FROM" --from "$FROM" --to "$TO" --out "$CACHE"; then
  log "CACHE FETCH FAILED, leaving the node at tip and not rewinding"
  exit 1
fi

# Execution requests come from the beacon chain, not the EL. Do this before the
# rewind too, while we still know the node is healthy, and fail loudly: a missing
# requests.json means every request-bearing block gets rejected at benchmark time.
log "fetching execution requests from the beacon chain"
if ! python3 "$HERE/blockcache/fetch_requests.py" \
      --cache "$CACHE" \
      --beacon-api "$(echo "$BEACON_API" | cut -d, -f1)" \
      --beacon-header "$BEACON_HEADER"; then
  log "REQUESTS FETCH FAILED, leaving the node at tip and not rewinding"
  exit 1
fi

# ------------------------------------------------------------- pin
# Stop blsync first. If it is running when setHead lands it sends a
# forkchoiceUpdated pointing at the real tip, geth starts a beacon sync forward
# and marks the trie database as in-state-sync, and the pathdb layer goes stale.
# The shutdown journal write then fails with "layer stale" and the state at the
# pinned head is unrecoverable.
log "stopping blsync before the rewind"
sudo systemctl stop blsync-bench.service
for i in $(seq 1 30); do
  systemctl is-active --quiet blsync-bench.service || break
  sleep 1
done
if systemctl is-active --quiet blsync-bench.service; then
  log "REFUSING: blsync is still running, rewinding now would corrupt the datadir"
  exit 1
fi
sleep 3

log "rewinding to $PIN"
curl -s --max-time 60 -X POST -H 'content-type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"debug_setHead\",\"params\":[\"$(printf '0x%x' $PIN)\"]}" \
  "$LOCAL" >/dev/null
sleep 10

NOW=$(ethnum "$LOCAL")
log "head is now $NOW"
[ "$NOW" = "$PIN" ] || log "WARNING: expected $PIN, check the geth log"

# Flush cost scales with the rewind and can take several minutes. The unit uses
# TimeoutStopSec=infinity so it is never killed mid-write. Do not interrupt it.
# systemctl stop is unreliable from inside a systemd unit, so escalate to a direct
# SIGTERM if it has not landed in 30s, log progress, and give up loudly.
stop_geth_verified() {
  log "stopping geth (rewound $REWIND blocks, expect the flush to take a while)"
  sudo systemctl stop --no-block geth-bench.service 2>/dev/null || true
  local waited=0
  while pgrep -f "[g]eth --datadir" >/dev/null; do
    sleep 5; waited=$(( waited + 5 ))
    if [ "$waited" -eq 30 ]; then
      log "  stop has not taken effect in 30s, sending SIGTERM directly"
      pkill -TERM -f "[g]eth --datadir" 2>/dev/null || true
    fi
    if [ $(( waited % 60 )) -eq 0 ]; then
      log "  still flushing (${waited}s) - flush time scales with the rewind, do not interrupt"
    fi
    if [ "$waited" -ge 1800 ]; then
      log "  ABORT: geth still running after 30 minutes"
      return 1
    fi
  done
  return 0
}
stop_geth_verified || exit 1
if ! sudo journalctl -u geth-bench -n 40 -o cat | grep -q "Blockchain stopped"; then
  log "ABORT: no 'Blockchain stopped' in the log, so the datadir state is unverified."
  log "  Not reporting a window that may be built on a torn datadir. Restore with:"
  log "  sudo rm -rf /datadrive/geth && sudo cp -a /datadrive/geth-backup /datadrive/geth"
  exit 1
fi

log "starting the cache server"
sudo systemctl start blockcache.service

# The pin lives here rather than in each script, so moving the window cannot leave
# a benchmark rewinding to the previous one.
WINDOW=/home/debian/benchmarks/window.env
mkdir -p "$(dirname "$WINDOW")"
cat > "$WINDOW" <<EOF
PIN=$PIN
BLOCKS=$BLOCKS
EOF
log "wrote $WINDOW"

cat <<EOF

========= record this in README.md, "The block window" =========
  pinned head            $PIN
  window                 $(( PIN + 1 )) .. $TO  ($BLOCKS blocks)
  snap-sync pivot floor  ${FLOOR:-unknown}
  cache range            $FROM .. $TO
  block cache            $CACHE, served on 127.0.0.1:8600
  datadir                $DATADIR
================================================================
EOF
