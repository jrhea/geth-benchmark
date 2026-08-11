# Setup log

Commands run to build geth-benchmark-1, in order. Work in progress.
Operating instructions: [README.md](README.md)

Starting point: bare Ubuntu 26.04 from Ansible. git, curl, python3. No Go, Rust,
compiler, or chain data.

## 0. The machine

AMD EPYC 9454P, 48 cores / 96 threads (siblings pair N and N+48), 1 NUMA node,
125 GB RAM, 2x 3.5 TB NVMe as RAID0 = 7 TB on `/`, Ubuntu 26.04.

RAID0, no redundancy. Losing a disk loses the datadir.

## 1. Toolchain, repos, builds

All of this is in `scripts/setup-debian.sh`. Run on a fresh box.

```bash
bash scripts/setup-debian.sh
```

Installs: `build-essential pkg-config libssl-dev libclang-dev clang cmake jq
unzip`. Go 1.26.5 from the official tarball to `/usr/local/go`. Rust via rustup.
Clones go-ethereum (jrhea + upstream remotes), reth-bench-compare, and reth.
Builds `geth`, `reth-bench`, `reth-bench-compare` into `/usr/local/bin`.

This repo goes to `/home/debian/geth-benchmark`, so a path in these documents is
the same path on the box. Everything a run produces goes under
`/home/debian/benchmarks/<LABEL>/`. Nothing else belongs in the home directory,
and `scripts/blockcache/` has to stay where `blockcache.service` expects it.

Then, separately:

```bash
sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go
sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
```

Needed because Ubuntu's `.bashrc` exits early for non-interactive shells and
`/etc/profile.d` only loads for login shells. Without it `make geth` fails under
systemd, cron, and `ssh host 'cmd'`, but works when you type it by hand.

## 2. reth-bench source

Upstream deleted it: `5568b76d 2026-05-20 chore(bench): remove reth-bench (#24288)`.
crates.io `reth-bench` is an empty placeholder. Only surviving copy is Sina's
`bench/npv4` at `e1c99549`, which is also what reth-bench-compare's Cargo.toml
pinned. Forked it so we can't lose it:

```bash
git clone --filter=blob:none --branch bench/npv4 git@github.com:s1na/reth.git /tmp/reth-npv4
git -C /tmp/reth-npv4 push git@github.com:jrhea/reth.git bench/npv4
```

```bash
gh api -X POST repos/jrhea/reth/git/refs \
  -f ref=refs/heads/bench/npv4 \
  -f sha=e1c99549a68b374b861945c8ee74effe549a59cc
```

The `gh api` version does **not** work, it 404s. Forks share an object store so
the commit is readable, but creating a ref needs the object in your own repo.
Use the clone-and-push. `--filter=blob:none` keeps full history (so the push
isn't rejected like a shallow clone) while skipping file contents.

A fork only copies the default branch, so forking `paradigmxyz/reth` does not
give you `bench/npv4`.

Cargo.toml now points those five crates at `jrhea/reth`, same commit, so binaries
are identical.

## 3. Chain data

Rejected: copying the 685 GB datadir from `geth-bench-05`. Measured first:

| | throughput |
|---|---|
| 1 stream | 32 MB/s |
| 4 streams | 30 MB/s aggregate |

6 ms RTT and no gain from parallelism means a hard ~250 Mbps cap, so ~6 hours
with nothing to tune. Don't retry parallel rsync to that host. It also required
stopping bench-05 for the duration, and that datadir was written by a modified
geth build.

Did instead: snap sync driven by `blsync` (geth's beacon light client, built from
`cmd/blsync`). geth can't follow the chain post-merge alone.

Flags that need explaining:

- `--history.chain postprague` resolves to a cutoff at block 22,431,084. The snap
  downloader *skips* bodies and receipts before it rather than downloading and
  deleting, so ~3.2 M blocks instead of 25.6 M. Headers still fetched for all
  blocks. This node can't replay anything before that block.
- `--history.state 0` keeps state history for the whole chain instead of the
  default 90,000 blocks. State history is what `debug_setHead` rewinds through,
  and the harness rewinds after every run, so the default caps how far back a
  replay window can sit at about 12.5 days. Costs roughly 65 KB/block, so about
  170 GB/year. It only accumulates going forward and pruned history can't be
  recreated, which is why it is set now rather than when it is needed. Note you
  cannot snap sync to an old pivot to recover, peers only serve recent state
  roots, so the alternative would be a full sync.
- `--cache 16384` for sync speed. Doesn't affect benchmarks, the harness passes
  its own flags.

Beacon endpoints, comma-separated in `--beacon.api`, three implementations for
redundancy:

```
https://lighthouse.mainnet.ebeacon.ethnodeops.xyz
https://nimbus.mainnet.ebeacon.ethnodeops.xyz
https://lodestar.mainnet.ebeacon.ethnodeops.xyz
```

They need an `X-API-Key` header. Endpoints and key live in `/etc/bench/blsync.env`
at 0600 root-owned, deliberately not in the unit files, which are world readable
at 0644. `BEACON_HEADER` is quoted because the value contains a space. systemd
strips the quotes, and quoting also lets shell scripts source the file.

The credentials came from bench-05, read out of its running container:

```bash
sudo docker inspect blsync --format "{{.Path}} {{range .Args}}{{.}} {{end}}"
```

Checkpoint was cross-checked against two of those endpoints before use. Sync
finished overnight at ~690 GB.

## 4. systemd services

First attempt used `setsid nohup geth ... &`. Died 11 hours later with a clean
SIGTERM. Not OOM, not disk, no reboot, `KillUserProcesses=no`. Journal, 20
seconds before:

```
teleport[30129]: WARN [NODE] error while creating host users
  AccessDeniedError host user creation not authorized for this user
  ...srv/sess.go:310 (*SessionRegistry).UpsertHostUser
```

`debian` is Teleport-managed, its session cleanup killed the process tree.
`setsid` escapes the terminal but not the session cgroup.

```bash
BEACON_KEY=<key> bash scripts/install-units.sh
```

Unit files also checked in at `scripts/systemd/`. Choices:

- `TimeoutStopSec=infinity` on geth. Flush cost scales with the rewind (460 blocks
  = 9s, 2200 = 117s, 4687 = over 300s), so any finite value is a guess that
  eventually fires and causes the exact corruption it was meant to prevent. A hung
  shutdown is visible and killable; a half-written trie journal is silent loss.
- `BindsTo=geth-bench` on blsync, so it stops with geth instead of failing in a loop.
- `ExecStartPre` waits for port 8551. geth being "active" doesn't mean authrpc is listening.
- `--beacon.checkpoint.file` so restarts resume from saved light-client state.
- geth and blsync are not enabled at boot: a reboot would start geth, blsync would
  drive it forward, and the pinned head would silently move. See README.
- `blockcache` *is* enabled at boot, by `install-units.sh`. It holds no state and
  serves read-only, and a reboot without it means every benchmark aborts on a
  missing block source. `bench-cpu-tuning` likewise, from
  `apply-performance.sh`, because sysfs writes do not persist.
- `blockcache.service` runs `scripts/blockcache/serve.py` from this repo's copy on
  the box, so that path has to stay where it is.

## 5. Persistent sudo for `debian`

Teleport grants `debian` `NOPASSWD: ALL` through a file it creates per session,
`/etc/sudoers.d/teleport-<session-uuid>-debian`, and removes when the session
ends. A benchmark runs detached in a systemd unit long after the launching
session has gone, and it needs sudo throughout: `bench.sh` starts the pinning
geth with `systemd-run`, and the harness drops the page cache before every pass.
Occasionally one of those calls was refused, killing the run:

```
sudo: I'm sorry debian. I'm afraid I can't do that
```

Grant it independently of any session:

```bash
printf 'debian ALL=(root) NOPASSWD: ALL\n' | sudo tee /etc/sudoers.d/99-bench >/dev/null
sudo chmod 0440 /etc/sudoers.d/99-bench
sudo visudo -c
```

`visudo -c` must print `parsed OK`. Keep a session open until it does, since a
malformed sudoers file locks everyone out of sudo and an open session is the way
back in.

A narrower whitelist is not worth it. The benchmark needs `systemd-run` with
arbitrary arguments and `sh -c "echo 3 > /proc/sys/vm/drop_caches"`, and the
first is a root shell by definition, so restricting to those buys nothing over
`ALL` while breaking every time a script changes. This grants exactly what
Teleport already grants during a session, minus the dependency on one being open.

## 6. The harness needs patches (all pushed)

This box does NOT work with stock `reth-bench-compare` or stock `reth-bench`.
Both are patched in jrhea forks; the box builds from them.

**`jrhea/reth` @ `bench/npv4`**, one commit:

- `fix(bench): fetch execution requests for newPayloadV4`. EIP-7685 requests are
  not recoverable from the execution layer: geth derives them while executing,
  keeps only `requestsHash`, and no `eth_` RPC returns them. `block_to_new_payload`
  therefore sent an empty list, geth hashed nothing, and every block that actually
  carried requests was rejected with a blockhash mismatch. ~5% of post-Prague
  mainnet blocks are affected, so a run died within a few blocks. Now fetched via
  a non-standard `bench_getExecutionRequests` served by our block cache from
  beacon data (see `scripts/blockcache/fetch_requests.py`).

**`jrhea/reth-bench-compare`**, four commits:

- `fix(geth): stop wait_for_ready timing out on a ready node`. Two causes:
  `--history.transactions 0` meant index the entire chain (~6 min), and the
  readiness check read `current_block != highest_block` as syncing when
  `highest_block == 0` just means geth has no sync target.
- `feat: add --runs, tee reth-bench output to disk, survive setHead RPC timeouts`.
  See README for `--runs`. The tee matters because reth-bench's panic message went
  only to `debug!`, so failures left nothing to diagnose. The setHead change is
  geth's 30s HTTP write timeout, described in the README gotchas.
- `fix: treat --warmup-blocks 0 as no warmup instead of an empty replay`.
- `fix: tee the measured passes to the run log, not just the warmup`. The tee was
  wired into the warmup only, so `reth-bench.log` held one pass out of seven.
  Passes are now tagged with their output directory, so `tail -f` shows which run
  and side each line belongs to.

If the box is ever rebuilt, both forks must be cloned and built, or benchmarks
will fail in ways that look like infrastructure problems.

## 7. Performance settings

Applied. Re-run or change with `scripts/apply-performance.sh`.

- governor `performance`, so every core sits at 2749 MHz instead of ramping between 1500 and 3812
- turbo boost off, hard ceiling at base clock, so sustained runs cannot thermally droop
- both set by `bench-cpu-tuning.service`, enabled at boot since sysfs writes do not persist

Core layout (48 physical 0-47, SMT siblings are N+48):

| cores | who |
|---|---|
| 0-19 | `bench.slice`: geth and reth-bench |
| 48-67 | siblings of the bench cores, kept empty |
| 20-23, 68-71 | spare |
| 24-47, 72-95 | `system.slice` and `user.slice` |

`bench.slice` is a top level slice, a sibling of `system.slice`. That is
deliberate: in cgroup v2 a child's cpuset is intersected with its parent's, so
putting it under a restricted `system.slice` would have blocked the bench cores.

Verify:

```bash
grep Cpus_allowed_list /proc/self/status                      # 24-47,72-95 in a shell
taskset -pc $(systemctl show geth-bench -p MainPID --value)   # 0-19 for geth
```

Still run paired A/B in alternating order. It matters more than any of the above.

## Not done

- Why `systemctl stop` silently no-ops from inside a systemd unit. Routed around,
  not explained.
- Patch the harness to pin geth and reth-bench to separate cores (they share 0-19).
- A way for other people to request runs. See the notes below.
- Run-request system. Must be serialized: one datadir, one port pair, two
  concurrent runs corrupt each other while both look fine. Options cheapest
  first: self-hosted GitHub Actions runner with `workflow_dispatch`, PR comment
  bot, Discord bot. Discord: use the gateway/WebSocket so the bot dials out and
  needs no inbound port; must ACK in 3s, token expires at 15 min, runs take ~1h,
  so post results as a new message. Ref inputs are the security boundary, they
  get built and executed on a box holding the datadir, a Teleport identity, and
  an OpenBao agent.


