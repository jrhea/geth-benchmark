#!/usr/bin/env bash
#
# Quick health check for geth-benchmark-1. Run this from your laptop, it goes
# over tsh. No arguments.
#
# Note it reads the head from the log rather than eth_syncing, because
# eth_syncing returns false during beacon header backfill even when the node is
# far behind.
set -uo pipefail

HOST="${BENCH_HOST:-debian@geth-benchmark-1}"

tsh ssh "$HOST" 'bash -s' <<'REMOTE'
echo "services"
for u in geth-bench blsync-bench; do
  printf "  %-14s %-10s %s\n" "$u" \
    "$(systemctl is-active $u.service 2>&1)" \
    "slice=$(systemctl show $u.service -p Slice --value 2>&1)"
done

echo
echo "head"
HEAD=$(curl -s --max-time 5 -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://127.0.0.1:8545 2>/dev/null \
  | python3 -c 'import sys,json; print(int(json.load(sys.stdin)["result"],16))' 2>/dev/null)
if [ -n "${HEAD:-}" ]; then
  echo "  local  $HEAD"
else
  echo "  local  (rpc not answering, node probably stopped)"
fi

# "age" in geth's import log tells you how far behind it is, which is more
# honest than eth_syncing
AGE=$(sudo journalctl -u geth-bench -n 200 -o cat 2>/dev/null \
  | grep -oE 'age=[0-9a-z]+' | tail -1)
[ -n "${AGE:-}" ] && echo "  behind $AGE" || echo "  behind (no age in recent log, likely at tip)"

echo
echo "peers"
PEERS=$(curl -s --max-time 5 -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
  http://127.0.0.1:8545 2>/dev/null \
  | python3 -c 'import sys,json; print(int(json.load(sys.stdin)["result"],16))' 2>/dev/null)
echo "  ${PEERS:-n/a}"

echo
echo "disk"
df -h / | tail -1 | awk '{print "  root    "$3" used, "$4" free ("$5")"}'
echo "  datadir $(sudo du -sh /datadrive/geth 2>/dev/null | cut -f1)"

echo
echo "performance settings"
echo "  governor  $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)  (want: performance)"
echo "  boost     $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)  (1 = on)"

echo
echo "last geth log lines"
sudo journalctl -u geth-bench -n 4 -o cat 2>/dev/null | sed 's/^/  /'
REMOTE
