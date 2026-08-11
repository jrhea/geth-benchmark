# geth-benchmark

Real-block `newPayload` benchmarks for go-ethereum. Work in progress.
How the benchmark works: [HOW-IT-WORKS.md](HOW-IT-WORKS.md)
Build history: [SETUP.md](SETUP.md)

## Connect

```bash
tsh ssh debian@geth-benchmark-1
```

## Machine

AMD EPYC 9454P, 48 cores / 96 threads (siblings pair N and N+48), 1 NUMA node,
125 GB RAM, 2x 3.5 TB NVMe as RAID0 = 7 TB on `/`, Ubuntu 26.04.

RAID0, no redundancy. Losing a disk loses the datadir.

## Paths

```
/datadrive/geth                    chain data, jwtsecret at geth/jwtsecret
/home/debian/geth-benchmark        this repo, scripts run from scripts/
/home/debian/benchmarks/<LABEL>/   one directory per experiment
        results/<timestamp>/       one per run of it, self-contained
                  baseline/        per-block CSVs
                  feature/         per-block CSVs
                  slowblock.log    geth per-block timings
                  reth-bench.log   reth-bench output, tagged by pass
                  bench-meta.json  refs, commits built, run parameters
                  report.md        the report for that run
        bin/                       the geth binaries it built
/home/debian/benchmarks/archive/   console logs from building the box
/home/debian/go-ethereum           geth source -> build/bin/geth
/home/debian/reth-bench-compare    the A/B harness
/home/debian/reth                  source for reth-bench
/etc/bench/blsync.env              beacon key + endpoints (0600 root)
/usr/local/bin                     reth-bench, reth-bench-compare, go, gofmt
```

The box holds a copy of this directory at `/home/debian/geth-benchmark`, so a
path here and a path there are the same path. Update the box by copying the
scripts over, or by cloning this once it is a repo. Nothing else belongs in the
home directory: runs go under `benchmarks/`, and each one keeps its results, logs
and report together.

## Start / stop

```bash
sudo systemctl start geth-bench blsync-bench
```

```bash
sudo systemctl stop blsync-bench geth-bench
```

Stop blsync first. Confirm geth flushed cleanly:

```bash
sudo journalctl -u geth-bench -n 20 -o cat | grep -E "Persisted|Blockchain stopped"
```

## Status

```bash
bash /home/debian/geth-benchmark/scripts/status.sh
```

```bash
sudo journalctl -u geth-bench -f -o cat
```

## Current window

Re-pinned 2026-08-04.

| | |
|---|---|
| pinned head | 25,677,500 |
| window | 25,677,501 .. 25,679,500 (2000 blocks) |
| snap-sync pivot floor | 25,676,837 (663 blocks of margin) |
| cache range | 25,676,776 .. 25,681,527 |
| cache dir | `/datadrive/blockcache` |
| backup | `/datadrive/geth-backup` (647 GB, same pinned state) |
| harness flag | `--rpc-url http://127.0.0.1:8600` |

"Pinned" means the node's head is deliberately left at a chosen block and not
following the chain: stop blsync, `debug_setHead(N)`, stop geth. It matters
because the harness reads the current head and replays the blocks *after* it, so
a fixed head means every run executes the identical blocks and results from
different days are comparable. If the head drifts, each run silently benchmarks a
different range.

Restore from the backup with geth stopped:

```bash
sudo rm -rf /datadrive/geth && sudo cp -a /datadrive/geth-backup /datadrive/geth
```

The backup is itself pinned, so a restore is runnable with no rewind.

## Block cache

reth-bench fetches every replay block over RPC, on the warmup and on both refs,
every run. The harness's rewind deletes those blocks from the node afterwards, so
they genuinely have to come from outside it. Instead of hitting a remote endpoint
three times per run, fetch the window once and serve it from disk.

```bash
sudo systemctl start blockcache            # serves /datadrive/blockcache on 127.0.0.1:8600
```

Then pass `--rpc-url http://127.0.0.1:8600` to the harness. Blocks are held in
memory, so the harness's `drop_caches` cannot put disk reads on the measurement
path. It runs in `system.slice`, so it stays on the housekeeping cores.

## Moving the window

```bash
bash scripts/new-window.sh --blocks 2000 --source-rpc https://<endpoint>
```

Syncs to tip, rewinds to pin the head, stops geth, refetches the cache, and
prints the numbers to record below.

**Only shallow rewinds on this datadir.** `setHead` truncates the freezer and
deletes bodies and receipts above the new head, so a deep rewind destroys months
of chain data and getting back to tip means a fresh snap sync that resets the
pivot floor and discards state history. For an older window, copy the datadir
first and run against the copy:

```bash
sudo systemctl stop blsync-bench geth-bench
sudo cp -a /datadrive/geth /datadrive/geth-YYYY-MM-DD
bash scripts/new-window.sh --datadir /datadrive/geth-YYYY-MM-DD --max-rewind 2000000 ...
```

A copy is ~690 GB, about 10 minutes on this NVMe, and 8 fit in free space.

## Prompt for a fresh session

Paste this, filling in the two refs. It exists because the setup has enough
non-obvious constraints that an agent starting cold will otherwise rediscover them
the expensive way.

```
Benchmark <BASE_REF> against <TARGET_REF> on geth-benchmark-1.

Read geth-benchmark/README.md first and follow it. The box needs a patched
harness, a pinned head, and a populated block cache. Don't re-derive any of
that. Read the Gotchas section before debugging anything: several of those
failures are silent rather than loud, including one that inflated block times
~8x without erroring.

The box mirrors that repo at /home/debian/geth-benchmark, so run
/home/debian/geth-benchmark/scripts/bench.sh. It does 3 runs/side at 2000
blocks with slow-block logging and writes the report. Everything it produces
lands in /home/debian/benchmarks/<LABEL>/. Nothing belongs in the home
directory.

Both refs must exist in /home/debian/go-ethereum on the box (git fetch --all
there if not).

Every noise figure in the report is measured from that run's own passes. Judge
deltas against those, never against a stored number. An aggregate row counts only
if the two sides' run ranges do not overlap. Lead with the paired per-block
median. Be sceptical of p99, it is the weakest metric on this box.

If a run fails, read benchmarks/<LABEL>/reth-bench.log. That's where
reth-bench's errors go, and nowhere else.
```

## Benchmark

**1. Push both refs to `jrhea/go-ethereum`**, which is `origin` on the box. That
includes `master`: the box benchmarks `origin/master`, not upstream, so push
master first if you want a current one.

**2. Launch it.** `bench.sh` stops the maintenance node, checks the pinned head,
runs the harness and writes the report.

```bash
tsh ssh debian@geth-benchmark-1 'sudo systemd-run --unit=bench --slice=bench.slice --uid=debian --gid=debian --collect --property=TimeoutStopSec=infinity --setenv=BASE=master --setenv=FEATURE=my-branch --setenv=LABEL=my-label bash /home/debian/geth-benchmark/scripts/bench.sh'
```

| env | |
|---|---|
| `BASE`, `FEATURE` | the two refs. Branch, tag or commit. |
| `LABEL` | groups this experiment under `/home/debian/benchmarks/<LABEL>/`. Re-using one keeps the earlier runs: each lands in its own `results/<timestamp>/` with its own logs. |
| `BASE_LABEL`, `FEATURE_LABEL` | what the report heading calls each side. Default to the ref itself. |
| `BLOCKS`, `RUNS`, `WARMUP` | 2000, 3, and `BLOCKS`. |
| `GETH_ARGS` | extra flags for the geth under test, applied to **both** sides. |

Benchmarking against the **fork point** rather than master's tip isolates your
change from whatever landed in master since you branched, which is usually what
you want. It needs no push of its own, since it is already an ancestor of master:

```bash
git merge-base master my-branch
```

A bare hash reads badly as a heading, so give it a name. Same for a feature ref
you want shown as something other than the branch name:

```bash
--setenv=BASE=a1b2c3d4 --setenv='BASE_LABEL=fork point' \
--setenv=FEATURE=my-branch --setenv='FEATURE_LABEL=pr/35388' \
--setenv=LABEL=alopt
```

`BASE_LABEL` is the left side of the heading, `FEATURE_LABEL` the right. `LABEL`
appears nowhere in the report, it only picks the directory:

```
### Bench: `fork point` → `pr/35388`         <- BASE_LABEL, FEATURE_LABEL

- **base** `fork point` @ [`a1b2c3d4e5`](...)
- **target** `pr/35388` @ [`dc435da7f8`](...)
```

```
/home/debian/benchmarks/alopt/...            <- LABEL
```

Renaming a side changes only what it is called. The commit built is recorded and
linked either way.

`GETH_ARGS` reaches the geth being benchmarked, so you can measure a change under
a different configuration. It applies to both sides, which keeps the comparison
about the code:

```bash
--setenv=GETH_ARGS=--cache.noprefetch
```

Several flags need quoting so they arrive as one value:

```bash
--setenv='GETH_ARGS=--cache.noprefetch --cache 8192'
```

The report records them in its header, since a run with them is not comparable to
one without:

```
both sides with `--cache.noprefetch`
```

To measure the flag itself rather than a code change, run `master` against
`master` with it set, then again without, and compare the two per-run tables.

**3. Wait 35-45 minutes**, checking with `progress.sh` below. One run at a time:
there is one datadir and one port pair, and two at once corrupt each other while
both look fine.

**4. Read the report**, see [Viewing results](#viewing-results).

It must run inside `bench.slice` or it lands in `user.slice` on the housekeeping
cores. `bench.sh` force-moves each local branch onto `origin/<ref>` before
building, so a re-run of the same branch name picks up new commits.

To test a *setting* rather than a code change, run `master` against `master` with
the setting applied and read the per-run table: every pass is listed, so a cold
first pass or a shifted steady state is visible directly. Compare two settings by
running each and checking whether the two per-run ranges overlap.

## Viewing results

Reports are markdown, meant to be pasted into a PR or a chat as they are. Each
one lives with the run that produced it, at
`/home/debian/benchmarks/<LABEL>/results/<timestamp>/report.md`.

**Print the latest run of a benchmark.** Runs from your laptop over tsh:

```bash
bash scripts/latest-report.sh my-label
```

**See what is on the box.** No argument lists every benchmark, its most recent
run, and whether that run has a report:

```bash
bash scripts/latest-report.sh
```

```
  LABEL                          LATEST RUN         REPORT
  alopt                          20260805_165916    yes
  precompile-cache-gas-gate      20260807_174135    yes
  bench                          20260804_195120    not written
```

**Read it rendered** rather than as raw markdown in a terminal. Save it and open
it in whatever renders markdown for you:

```bash
bash scripts/latest-report.sh my-label > /tmp/report.md && open /tmp/report.md
```

**An older run**, when a label has several. Copy the timestamp from the listing:

```bash
tsh ssh debian@geth-benchmark-1 'cat /home/debian/benchmarks/my-label/results/20260807_174135/report.md'
```

**Regenerate one**, after changing `report.py` or to relabel the sides. Pass the
run directory and it picks the newest results inside:

```bash
tsh ssh debian@geth-benchmark-1 'python3 /home/debian/geth-benchmark/scripts/report.py --results /home/debian/benchmarks/my-label'
```

That prints to stdout. To overwrite the saved copy in place:

```bash
tsh ssh debian@geth-benchmark-1 'D=$(ls -1dt /home/debian/benchmarks/my-label/results/*/ | head -1); python3 /home/debian/geth-benchmark/scripts/report.py --results $D > $D/report.md'
```

It needs no other arguments because `bench.sh` leaves a `bench-meta.json` holding
the refs, the commits it built and the slow-block log path. `--base-label` and
`--target-label` override what the heading calls each side.

## The report

One format for every benchmark, produced by `scripts/report.py`. Sections: refs
and commits, paired per-block headline, `Results`, per-run, execution breakdown.

It reports numbers and marks each one `▲`/`▼`/`≈`. It says nothing about *why* a
change behaves the way it does. Add that by hand when you post it.

Two things it needs that are easy to forget:

- **`--runs 3`.** Without several passes per side there is no ±, and the report
  says so rather than inventing one.
- **`-- --debug.logslowblock 0 --log.file <path>`** for the execution breakdown.
  `0` logs every block, the default `-1` disables it.

The breakdown depends on knowing which pass in the slow-block log was which side.
Nothing in the log says, and the harness alternates the order (`cli.rs:513`), so
report.py derives it from the run index and checks it against the harness's
labelled CSVs. If they disagree it skips the breakdown rather than print it
inverted, since a sign flip there turns a regression into an improvement and looks
entirely plausible.

## Checking on a running benchmark

One line: whether it is alive, which pass and side, and how far through.

```bash
tsh ssh debian@geth-benchmark-1 'bash /home/debian/geth-benchmark/scripts/progress.sh my-label'
```

```
active  pass 4/7 (run 2 feature)  6412/14000 blocks  45%
```

Takes `LABEL [blocks] [runs]`, defaulting to 2000 and 3. Pass 1 is the warmup,
then two per run. The count comes from the slow-block log, which geth writes on
every pass.

Live per-block output, tagged with the pass it belongs to:

```bash
tsh ssh debian@geth-benchmark-1 'tail -f /home/debian/benchmarks/my-label/reth-bench.log'
```

```
[run2/feature] ... Payload 25678412 processed at 0.41 Ggas/s ... newPayload latency: 74.1ms
```

**Expected pace**, so you can tell slow from stuck. A 2000-block pass replays in
~200s. Add ~30s node start, ~45s rewind and up to ~2min flush, so **~5-6 min per
pass**, and **35-45 minutes** for 7 passes.

If it looks stuck, find out whether geth is working or waiting before doing
anything:

```bash
tsh ssh debian@geth-benchmark-1 'uptime; pgrep -af "[g]eth_" | head -2
sudo journalctl -u geth-bench -n 3 -o cat'
```

Load near zero with no recent geth log lines means waiting, not working. Check
for a wedged stop (see Gotchas) rather than assuming a long flush.

## Reading the numbers

**Every run measures its own noise.** Nothing is judged against a stored number.
The box, the window and geth all change, so last week's spread is not today's. With
`--runs 3` the run carries what it needs.

Every figure has a `±`, the half-range across that side's passes, and one rule in
two forms decides what counts:

- **Two sides measured separately**, the summary rows and the p50/p95 columns.
  Their ranges must **not overlap**, so no run-to-run drift within what actually
  happened could flip the sign.
- **A paired delta**, which is a single series. Its own per-run range must
  **exclude zero**, so every run agreed on the sign.

Anything failing its test gets `≈`, whatever the delta looks like.

**Lead with the median Δ in the breakdown.** Each block is compared against
itself, which cancels block-to-block variation, so it resolves well below 1% where
the aggregates cannot. `blocks faster` beside it is a robustness check, since no
single slow block can move a count, but it is not the test.

Buckets differ a lot in how steady they are, and the `±` shows it. A half-point
move in a bucket whose median wanders a full point between runs is nothing, while
the same move in a steady bucket is real.

**Mean and median both**, because they answer different questions and the gap
between them is often the point. `median Δ` is the typical block. `mean Δ` is the
change in total time, which is what turns into wall clock, and it adds up, so a
bucket's share of a headline change can be read off it. Agreement means the change
is uniform, divergence means it sits in the tail.

The one statistic not reported is the mean of the per-block *percentage* changes.
Small blocks dominate it, since a fraction of a millisecond is a large percentage.

Two things worth knowing before you look:

- **p99 is by far the weakest metric.** Its spread runs an order of magnitude
  looser than throughput. Be sceptical of tail claims.
- **`state read` is the noisiest breakdown bucket.** Sub-2% movement there is not
  a finding.

A healthy run looks like ±0.2% throughput, ±0.4% p50, ±0.8% p95, ±3.4% p99, at
~345 MGas/s over the current window. Much looser than that, suspect the box rather
than the code.

## Warmup

Keep it equal to `--blocks`, which is the default. Two measured facts decide this.

**Skipping it is expensive.** A cold pass runs ~10% down on throughput and much
worse on the tail (p95 +23%, p99 +27%). Only the first pass is cold, since every
later pass is warmed by the one before it, but that cold pass lands in the measured
data and wrecks the ± you decide with: p95 goes ±0.8% to ±11.5%, p99 ±3.4% to
±13.5%.

**A shorter warmup does not help proportionally.** The benefit is close to linear
in warmup length, because a warmup only helps the blocks it actually replays. A
warmup covering a quarter of the window recovers about a quarter of the benefit.
Per-block, the penalty starts exactly where the warmup stopped and then decays as
the pass warms itself. So there is no saving available here, and a short warmup is
the worst of both.

## Gotchas

- `eth_syncing` returns `false` during header backfill. The harness reads that as "ready" and benchmarks from a garbage block. Use `scripts/status.sh` or the log.
- `nohup`/`setsid` get killed by Teleport session cleanup. Use systemd. Verify: `systemctl show geth-bench -p Slice` must be `system.slice`.
- The harness needs `reth-bench` on `PATH`. Upstream deleted it, it comes from `jrhea/reth` branch `bench/npv4`.
- Anything else running during a benchmark lands in the results.
- Services are not enabled at boot on purpose, see below.
- **`systemctl stop` silently no-ops when issued from inside a systemd unit.** The identical command from a shell works instantly. Unexplained. `new-window.sh` escalates to `pkill -TERM` after 30s. Do the same in any new script, and never write an unbounded wait loop.
- **`--history.transactions 0` means the ENTIRE chain, not "off".** N is a count back from the head, so `1` is the minimum. Get it wrong and geth indexes in the background, which inflates block times ~8x with no error.
- **geth's HTTP RPC has a hard 30s write timeout** (`rpc/http.go`, not a flag). A 2000-block `debug_setHead` takes ~45s and returns `-32002 request timed out`, but the rewind still completes. The harness polls the head instead of trusting the response.
- reth-bench panics on an empty block range (`the row has at least one element`), so `--warmup-blocks 0` is handled in the harness by skipping the phase.
- **After `debug_setHead`, restart geth before replaying anything.** In the same
  session the node cannot serve `newPayload` at the new head and reth-bench dies
  immediately with "no canonical state found for parent of requested block".
  `new-window.sh` and the harness both already stop geth after a rewind.

## Why geth is not enabled at boot

A reboot would start geth, blsync would drive it forward, and the pinned head
would silently move, changing the block range out from under every later run.
Leave them disabled unless you want the node following the chain:

```bash
sudo systemctl enable geth-bench blsync-bench
```

## Performance settings

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
