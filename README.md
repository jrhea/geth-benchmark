# geth-benchmark

Real-block `newPayload` benchmarks for go-ethereum, on the `geth-benchmark-1` box.

Replays real mainnet blocks into two builds of geth over the engine API and
reports the difference. One run takes about 40 minutes.

| | |
|---|---|
| [RESULTS.md](RESULTS.md) | what the report contains and how to read it |
| [HOW-IT-WORKS.md](HOW-IT-WORKS.md) | the three programs and three endpoints |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | when a run fails |
| [SETUP.md](SETUP.md) | the machine, and how it was built |

## Run one

Push both refs to `jrhea/go-ethereum` first. That includes `master`: the box
builds `origin/master`, not upstream.

Everything below runs from your laptop and goes over `tsh`.

```bash
bash scripts/run.sh --base master --feature my-branch
```

It names the run after the two refs and prints the name, which is what groups it
on disk:

```
label: my-branch-vs-master
started. it takes about 40 minutes.
```

```bash
bash scripts/progress.sh
```

```bash
bash scripts/latest-report.sh my-branch-vs-master
```

That is the whole workflow. `run.sh` returns immediately, `progress.sh` prints one
line for whatever is running, and the report is markdown ready to paste into a PR.

```
active  pass 4/7 (run 2 feature)  6412/14000 blocks  45%
```

Or start it from the Actions tab, which takes the same options and leaves the
report in the job summary: **Actions -> bench -> Run workflow**. That needs write
access to this repo, since a benchmark builds and runs the ref it is given.

One run at a time, because there is one datadir and one port pair. A second launch
from the command line is refused, and a second dispatch queues behind the first.

## Options

| | |
|---|---|
| `--base`, `--feature` | the two refs. Branch, tag or commit. Required. |
| `--label` | groups the run under `benchmarks/<label>/`. Defaults to `<feature>-vs-<base>`. Re-using one keeps the earlier runs. |
| `--base-label`, `--feature-label` | what the report heading calls each side. Default to the ref. |
| `--geth-args` | extra flags for the geth under test, applied to both sides. |
| `--blocks`, `--runs`, `--warmup` | 2000, 3, and the same as `--blocks`. |
| `--dry-run` | print the command instead of running it. |

`bash scripts/run.sh --help` lists the same.

**Compare against the fork point, not master's tip**, to isolate your change from
whatever landed in master since you branched:

```bash
bash scripts/run.sh --base fork-point --feature my-branch --label my-label
```

It resolves `git merge-base origin/master <feature>` on the box, whose clone is the
one that builds, so a laptop that has not fetched the branch cannot give a stale
answer. It prints what it picked and how far behind master that is:

```
resolving the fork point of my-branch against origin/master...
  cae76d5a3c3c7baad83bde2bd6c2d3ae8baca7d3  (0 commits behind origin/master)
```

`0 commits behind` means the branch is rebased on current master, so the fork point
and master's tip are the same commit. The distinction only bites for a branch that
has fallen behind.

The heading gets `fork point` rather than the bare hash, unless you pass
`--base-label` yourself. It refuses if the fork point turns out to be the feature
commit itself, since there would be nothing to compare.

**`--geth-args` measures your change under a different configuration.** It applies
to both sides, so the comparison stays about the code, and the report records it
in the header because a run with it is not comparable to one without:

```bash
bash scripts/run.sh --base master --feature my-branch --label noprefetch \
  --geth-args "--cache.noprefetch"
```

To measure a *flag* rather than a code change, run `master` against `master` with
it and again without, then compare the two per-run tables.

## Watching a run

`progress.sh` covers most of it, and with no label it reports whatever is running.
Pass 1 is the warmup, then two per run, so `--runs 3` is seven passes.

For live per-block output, tagged with the pass it belongs to:

```bash
tsh ssh debian@geth-benchmark-1 'tail -f /home/debian/benchmarks/my-label/reth-bench.log'
```

**Expected pace**, so you can tell slow from stuck: a 2000-block pass replays in
~200s, plus node start, rewind and flush, so **5-6 minutes per pass** and **40
minutes** for seven. A run that ends in under 20 minutes failed, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Reading results

Reports live with the run that produced them, at
`benchmarks/<label>/results/<timestamp>/report.md`. What the numbers mean is
[RESULTS.md](RESULTS.md).

```bash
bash scripts/latest-report.sh
```

With no label it lists every benchmark, its most recent run, and whether that run
has a report:

```
  LABEL                          LATEST RUN         REPORT
  alopt                          20260805_165916    yes
  precompile-cache-gas-gate      20260807_174135    yes
  bench                          20260804_195120    not written
```

To read it rendered rather than raw in a terminal:

```bash
bash scripts/latest-report.sh my-label > /tmp/report.md && open /tmp/report.md
```

An older run, once a label has several:

```bash
tsh ssh debian@geth-benchmark-1 'cat /home/debian/benchmarks/my-label/results/20260807_174135/report.md'
```

To regenerate one, after changing `report.py` or to relabel the sides. Pass the
run directory and it picks the newest results inside:

```bash
tsh ssh debian@geth-benchmark-1 'python3 /home/debian/geth-benchmark/scripts/report.py --results /home/debian/benchmarks/my-label'
```

It needs nothing else because `bench.sh` leaves a `bench-meta.json` holding the
refs and the commits it built. `--base-label` and `--target-label` override the
heading.

## The block window

Every run replays the same blocks, because the node's head is pinned and the
harness replays what comes after it. If the head drifts, each run silently
benchmarks a different range.

| | |
|---|---|
| pinned head | 25,677,500 |
| window | 25,677,501 .. 25,679,500 (2000 blocks) |
| snap-sync pivot floor | 25,676,837 (663 blocks of margin) |
| cache range | 25,676,776 .. 25,681,527 |
| block cache | `/datadrive/blockcache`, served on `127.0.0.1:8600` |
| datadir backup | `/datadrive/geth-backup`, same pinned state |

Moving it. This one runs on the box under systemd, because syncing to tip can take
hours and a dropped `tsh` session would kill it partway through:

```bash
tsh ssh debian@geth-benchmark-1 'sudo systemd-run --unit=newwindow --uid=debian --gid=debian --collect --property=TimeoutStopSec=infinity bash /home/debian/geth-benchmark/scripts/new-window.sh --blocks 2000'
```

```bash
tsh ssh debian@geth-benchmark-1 'sudo journalctl -u newwindow -f -o cat'
```

What it does, in order:

1. Starts geth and blsync and waits until the local head is within 4 blocks of the
   beacon chain's execution head. This is the slow part.
2. Picks the pin: `tip - blocks - margin`, or exactly `--pin N`.
3. Refuses if that rewind is deeper than `--max-rewind`, or if the pin falls below
   the snap-sync pivot floor, where there is no state to execute from.
4. Caches the blocks *before* rewinding, from `pin - 64` through `pin + blocks`.
   The rewind deletes them from the node, and reth-bench reads N-32 and N-64 for
   the safe and finalized hashes, hence the 64 below.
5. Fetches those blocks' EIP-7685 execution requests from the beacon chain and
   checks each against the block's own `requestsHash`.
6. Stops blsync and confirms it stopped, then rewinds with `debug_setHead`. blsync
   running during a rewind leaves the datadir unrecoverable.
7. Stops geth, waits out the flush however long it takes, and checks the log for a
   clean shutdown.
8. Starts the block cache and prints the rows to record.

It looks like this:

```
[12:08:47] starting geth + blsync
[12:08:59] waiting for the node to reach tip
[12:09:29]   local 25676914, chain 25681455, behind 4541
...
[12:24:20] caching blocks 25676776..25681527 from http://127.0.0.1:8545
[12:24:52] fetching execution requests from the beacon chain
155 of the cached blocks have requests, range 25676802..25681526
verified all 155 block(s), 158 request item(s)
[12:25:47] stopping blsync before the rewind
[12:25:50] rewinding to 25676840
[12:26:30] head is now 25676840
[12:26:30] stopping geth
[12:31:32] starting the cache server
```

Step 8 also writes `benchmarks/window.env`, which is where the pinned head and
window size actually live:

```
PIN=25677500
BLOCKS=2000
```

`bench.sh` reads it and refuses to start without it, so a window move cannot leave
a benchmark rewinding to the previous pin. Passing `--blocks` still wins, which is
how a 20-block smoke test works. The table above is for humans; this file is what
the scripts use, so update the table to match after moving the window.

Useful options, with the rest under `--help`:

| | |
|---|---|
| `--blocks N` | window size, default 2000 |
| `--margin N` | gap between the pinned head and tip, default 200 |
| `--pin N` | pin at exactly this block and cache from there to tip, instead of `tip - blocks - margin`. Use it to sit just above the pivot floor so the window can grow as the chain advances. |
| `--max-rewind N` | refuse to rewind further than this, default 50000 |
| `--datadir PATH` | work on a copy instead of `/datadrive/geth` |

**Only shallow rewinds on this datadir.** `setHead` deletes bodies and receipts
above the new head, so a deep rewind destroys months of chain data and getting
back to tip means a fresh snap sync. For an older window, copy the datadir and
run against the copy, with `--datadir` and a larger `--max-rewind`. A copy is
~690 GB, about 10 minutes, and 8 fit in free space.

Restoring the backup, with geth stopped:

```bash
sudo rm -rf /datadrive/geth && sudo cp -a /datadrive/geth-backup /datadrive/geth
```

## The maintenance node

geth and blsync are stopped between benchmarks and disabled at boot, so nothing
moves the pinned head. `bench.sh` stops them itself, so you only need these to
let the node follow the chain again:

```bash
sudo systemctl start geth-bench blsync-bench
```

```bash
sudo systemctl stop blsync-bench geth-bench
```

Stop blsync first, and confirm geth flushed cleanly:

```bash
sudo journalctl -u geth-bench -n 20 -o cat | grep -E "Persisted|Blockchain stopped"
```

Health check, from your laptop:

```bash
bash scripts/status.sh
```
