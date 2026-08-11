#!/usr/bin/env bash
#
# Installs the geth-bench and blsync-bench systemd services on geth-benchmark-1.
# Run this ON the box, as the debian user:
#
#   BEACON_KEY=<key> bash install-units.sh
#
# The key is the X-API-Key for the ebeacon endpoints. Get it from the existing
# /etc/bench/blsync.env on this box or on geth-bench-05. It is deliberately not
# stored in this repo.
#
# Safe to re-run. It stops the services, rewrites the units, and starts them again.
set -uo pipefail

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

BEACON_KEY="${BEACON_KEY:?set BEACON_KEY, see comment at top of this script}"

BIN=/home/debian/go-ethereum/build/bin
DATADIR=/datadrive/geth
JWT="$DATADIR/geth/jwtsecret"
BEACON_API="https://lighthouse.mainnet.ebeacon.ethnodeops.xyz,https://nimbus.mainnet.ebeacon.ethnodeops.xyz,https://lodestar.mainnet.ebeacon.ethnodeops.xyz"

# Bootstrap checkpoint. blsync only needs this the first time. After that it
# reads its own checkpoint file, so this going stale does not matter much.
log "fetching a current finalized checkpoint"
CP=$(curl -s --max-time 15 -H "X-API-Key: $BEACON_KEY" \
  "https://lighthouse.mainnet.ebeacon.ethnodeops.xyz/eth/v1/beacon/headers/finalized" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["root"])')
[ -n "${CP:-}" ] || { log "could not fetch a checkpoint, is the key right?"; exit 1; }
log "checkpoint $CP"

# Secrets go here, not in the unit file. Unit files are world readable.
log "writing /etc/bench/blsync.env"
sudo mkdir -p /etc/bench
# BEACON_HEADER is quoted because its value contains a space. systemd strips the
# quotes, and quoting also lets shell scripts source this file.
sudo tee /etc/bench/blsync.env >/dev/null <<EOF
BEACON_API=$BEACON_API
BEACON_HEADER="X-API-Key: $BEACON_KEY"
BEACON_CHECKPOINT=$CP
EOF
sudo chown root:root /etc/bench/blsync.env
sudo chmod 600 /etc/bench/blsync.env

log "writing /etc/systemd/system/geth-bench.service"
sudo tee /etc/systemd/system/geth-bench.service >/dev/null <<'EOF'
[Unit]
Description=geth (mainnet benchmark node)
Documentation=https://geth.ethereum.org
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=debian
Group=debian
# CPU isolation lives in apply-performance.sh, which defines this slice. If it
# has not run yet, systemd creates bench.slice unconfined and geth still works.
Slice=bench.slice
ExecStart=/home/debian/go-ethereum/build/bin/geth \
  --datadir /datadrive/geth \
  --syncmode snap \
  --history.chain postprague \
  --history.state 0 \
  --history.logs.disable \
  --history.transactions 1 \
  --cache 16384 \
  --http --http.addr 127.0.0.1 --http.api eth,debug,net,web3 \
  --authrpc.addr 127.0.0.1 --authrpc.port 8551 \
  --authrpc.jwtsecret /datadrive/geth/geth/jwtsecret
Restart=on-failure
RestartSec=10
# NEVER let systemd kill a flushing geth. The flush cost scales with how far the
# head was just rewound (measured: 460 blocks = 9s, 2200 = 117s, 4687 = >300s),
# so any finite value is a guess that eventually fires and causes the exact
# corruption it was meant to prevent. A hung shutdown is visible and can be killed
# by hand; a half-written trie journal is silent data loss.
TimeoutStopSec=infinity
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

log "writing /etc/systemd/system/blsync-bench.service"
sudo tee /etc/systemd/system/blsync-bench.service >/dev/null <<'EOF'
[Unit]
Description=blsync (beacon light client driving geth-bench)
After=geth-bench.service
# stop blsync automatically if geth goes away for any reason
BindsTo=geth-bench.service

[Service]
Type=simple
User=debian
Group=debian
EnvironmentFile=/etc/bench/blsync.env
# geth being "active" does not mean authrpc is accepting connections yet
ExecStartPre=/bin/bash -c 'for i in $(seq 1 60); do (echo > /dev/tcp/127.0.0.1/8551) 2>/dev/null && exit 0; sleep 2; done; exit 1'
ExecStart=/home/debian/go-ethereum/build/bin/blsync \
  --beacon.api ${BEACON_API} \
  --beacon.api.header=${BEACON_HEADER} \
  --beacon.checkpoint ${BEACON_CHECKPOINT} \
  --beacon.checkpoint.file /datadrive/geth/blsync-checkpoint.json \
  --blsync.engine.api http://127.0.0.1:8551 \
  --blsync.jwtsecret /datadrive/geth/geth/jwtsecret
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

log "writing /etc/systemd/system/blockcache.service"
# assumes fetch.py and serve.py are in /home/debian/geth-benchmark/scripts/blockcache/
sudo tee /etc/systemd/system/blockcache.service >/dev/null <<'EOF'
[Unit]
Description=Local block cache served over JSON-RPC for reth-bench
After=network-online.target

[Service]
Type=simple
User=debian
Group=debian
# system.slice is confined to the housekeeping cores by apply-performance.sh, so
# this inherits them and cannot steal CPU from geth on the bench cores.
Slice=system.slice
# python block-buffers stdout when it is not a tty, so logs never reach journald
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 /home/debian/geth-benchmark/scripts/blockcache/serve.py \
  --dir /datadrive/blockcache \
  --addr 127.0.0.1 \
  --port 8600
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 /etc/systemd/system/geth-bench.service \
               /etc/systemd/system/blsync-bench.service \
               /etc/systemd/system/blockcache.service

log "restarting services"
sudo systemctl stop blsync-bench.service 2>/dev/null || true
sudo systemctl stop geth-bench.service 2>/dev/null || true
sleep 3
sudo systemctl daemon-reload
sudo systemctl reset-failed geth-bench.service blsync-bench.service 2>/dev/null || true
sudo systemctl start geth-bench.service
sleep 12
sudo systemctl start blsync-bench.service
sleep 20

# The cache holds no state and serves read-only, so it should come back after a
# reboot. Without it every benchmark aborts on a missing block source.
log "enabling the block cache at boot"
sudo systemctl enable --now blockcache.service

log "result"
for u in geth-bench blsync-bench blockcache; do
  printf "  %-14s %-8s %-8s slice=%s\n" "$u" \
    "$(systemctl is-active $u.service)" \
    "$(systemctl is-enabled $u.service 2>&1)" \
    "$(systemctl show $u.service -p Slice --value)"
done
echo "  (slice must be system.slice, not a user slice)"
log "geth and blsync are not enabled at boot on purpose: a reboot would let blsync"
log "move the pinned head. See the README section on what starts at boot."
