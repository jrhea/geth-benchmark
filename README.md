# geth-benchmark

Real-block `newPayload` benchmarks for go-ethereum, on the `geth-benchmark-1` box.

Replays real mainnet blocks into two builds of geth over the engine API and
reports the difference between them. A run takes about 40 minutes.

- [RESULTS.md](RESULTS.md) what the report contains and how to read it
- [HOW-IT-WORKS.md](HOW-IT-WORKS.md) the three programs and three endpoints
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) when a run fails
- [SETUP.md](SETUP.md) the machine, and how it was built

## Connect

```bash
tsh ssh debian@geth-benchmark-1
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
for a wedged stop, see TROUBLESHOOTING.md, rather than assuming a long flush.

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
