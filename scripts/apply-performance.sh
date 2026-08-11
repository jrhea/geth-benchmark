#!/usr/bin/env bash
#
# Performance settings for benchmark repeatability. Run ON the box as debian.
#
#   bash apply-performance.sh
#
# Sets governor to performance, disables turbo boost, and carves the CPUs into
# a benchmark set and a housekeeping set. Persists across reboot.
#
# Core layout on this box (48 physical 0-47, SMT siblings are N+48):
#   0-19    bench.slice        geth + reth-bench
#   48-67   reserved idle      siblings of the bench cores, kept empty
#   20-23   spare
#   24-47   system.slice + user.slice
#   72-95   system.slice + user.slice
set -uo pipefail

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

BENCH_CPUS="0-19"
HOUSE_CPUS="24-47,72-95"

# ---------------------------------------------------------------- clocks
# sysfs writes do not survive a reboot, so put them in a oneshot unit
log "writing bench-cpu-tuning.service"
sudo tee /etc/systemd/system/bench-cpu-tuning.service >/dev/null <<'EOF'
[Unit]
Description=Fix CPU clocks for benchmark repeatability
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
# performance governor: every core sits at scaling_max instead of ramping
ExecStart=/bin/bash -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g"; done'
# boost off: hard ceiling at base clock, so sustained runs cannot thermally droop
ExecStart=/bin/bash -c 'echo 0 > /sys/devices/system/cpu/cpufreq/boost'

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now bench-cpu-tuning.service

# ---------------------------------------------------------------- cpusets
log "creating bench.slice ($BENCH_CPUS)"
sudo tee /etc/systemd/system/bench.slice >/dev/null <<EOF
[Unit]
Description=Benchmark workloads (isolated CPUs)
Before=slices.target

[Slice]
AllowedCPUs=$BENCH_CPUS
EOF

# bench.slice is a top level slice, a sibling of system.slice and user.slice.
# That matters: in cgroup v2 a child's cpuset is intersected with its parent's,
# so a restricted system.slice would have blocked geth-bench from the bench cores.
#
# geth-bench.service sets Slice=bench.slice itself, in install-units.sh. This
# script only defines and confines the slice.

# clean up the drop-in an earlier version of this script used to write
sudo rm -rf /etc/systemd/system/geth-bench.service.d

sudo systemctl daemon-reload

log "confining system.slice and user.slice to $HOUSE_CPUS"
# user.slice covers interactive sessions, so anything you run by hand while a
# benchmark is going cannot land on a bench core
# no --runtime flag, so it persists to /etc/systemd/system.control/
sudo systemctl set-property system.slice AllowedCPUs="$HOUSE_CPUS"
sudo systemctl set-property user.slice AllowedCPUs="$HOUSE_CPUS"

log "restarting geth-bench into its new slice"
WAS_ACTIVE=$(systemctl is-active geth-bench.service)
if [ "$WAS_ACTIVE" = "active" ]; then
  sudo systemctl stop blsync-bench.service 2>/dev/null || true
  sudo systemctl stop geth-bench.service
  sudo systemctl start geth-bench.service
  sleep 12
  sudo systemctl start blsync-bench.service
fi

# ---------------------------------------------------------------- verify
sleep 5
log "=== result ==="
echo "  governor      $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
echo "  boost         $(cat /sys/devices/system/cpu/cpufreq/boost)  (0 = off)"
echo "  cur freq      $(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / 1000 )) MHz"
echo "  bench.slice   $(cat /sys/fs/cgroup/bench.slice/cpuset.cpus.effective 2>/dev/null)"
echo "  system.slice  $(cat /sys/fs/cgroup/system.slice/cpuset.cpus.effective 2>/dev/null)"
echo "  user.slice    $(cat /sys/fs/cgroup/user.slice/cpuset.cpus.effective 2>/dev/null)"
echo "  geth slice    $(systemctl show geth-bench.service -p Slice --value)"
echo "  geth cpus     $(cat /sys/fs/cgroup/bench.slice/geth-bench.service/cpuset.cpus.effective 2>/dev/null)"
log "done"
