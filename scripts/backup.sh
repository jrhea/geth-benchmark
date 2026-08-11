#!/usr/bin/env bash
# Take a clean backup of the benchmark datadir. Run ON the box.
set -uo pipefail
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
# Matches a running geth and nothing else. A bare "geth" would also match these
# scripts, which live under a path containing the word.
GETH_PROC="/[g]eth(_[0-9a-f]+)? --datadir"

SRC=/datadrive/geth
DST=/datadrive/geth-backup

log "stopping every geth so the copy is not torn"
sudo systemctl stop --no-block geth-bench.service blsync-bench.service gr1.service 2>/dev/null || true
pkill -TERM -f "$GETH_PROC" 2>/dev/null || true
for i in $(seq 1 600); do pgrep -f "$GETH_PROC" >/dev/null || break; sleep 2; done
if pgrep -f "$GETH_PROC" >/dev/null; then log "ABORT: geth still running, refusing to copy a live datadir"; exit 1; fi
log "no geth running"

# a torn source makes a useless backup, so require evidence of a clean stop
if sudo journalctl -u gr1 -n 40 -o cat 2>/dev/null | grep -q "Blockchain stopped"; then
  log "clean shutdown confirmed"
else
  log "WARNING: no 'Blockchain stopped' in the last unit's log; backing up anyway,"
  log "         but treat this backup as crash-consistent rather than clean"
fi

log "free space before: $(df -h / | tail -1 | awk '{print $4}')"
log "source size: $(sudo du -sh $SRC | cut -f1)"

sudo rm -rf "$DST"
log "copying $SRC -> $DST (this takes a while, do not interrupt)"
time sudo cp -a "$SRC" "$DST"
RC=$?
log "cp exit=$RC"
log "backup size: $(sudo du -sh $DST | cut -f1)"
log "free space after: $(df -h / | tail -1 | awk '{print $4}')"
log "BACKUP_DONE"
