# geth-benchmark

Real-block `newPayload` benchmarks for go-ethereum.

Two git refs go in, and a report comes out saying which one executes mainnet
blocks faster. It builds both, replays the same 2000 real mainnet blocks into each
over the engine API, alternates which side goes first, and repeats three times.
That takes about 40 minutes and runs on a dedicated box, `geth-benchmark-1`, with
pinned cores and a fixed clock so that repeated runs are comparable.

| | |
|---|---|
| [RESULTS.md](RESULTS.md) | what the report contains and how to read it |
| [HOW-IT-WORKS.md](HOW-IT-WORKS.md) | the programs, the endpoints, and what talks to what |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | when a run fails |
| [SETUP.md](SETUP.md) | the machine, and how it was built |


## Running a benchmark

Two ways, same options and same results.

**From the Actions tab**, at **Actions -> bench -> Run workflow**. Fill in the
form, and the report lands in the run summary when it finishes. This needs write
access to this repo, because a benchmark builds and executes the ref it is given.

**From your laptop**, over `tsh`:

```bash
bash scripts/run.sh --base fork-point --feature jrhea:trie-prefetch-batch
```

Say you have a branch called `trie-prefetch-batch` pushed to your fork, and you
want to know whether it actually helps. That command prints:

```
label: jrhea-trie-prefetch-batch-vs-fork-point
resolving the fork point of jrhea:trie-prefetch-batch...
  a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0  (3 commits behind master)

started. it takes about 40 minutes.

  progress:  bash scripts/progress.sh jrhea-trie-prefetch-batch-vs-fork-point
  report:    bash scripts/latest-report.sh jrhea-trie-prefetch-batch-vs-fork-point
```

It returns straight away, and the run keeps going if you close your laptop.

### What to compare

`--base` and `--feature` are the two refs, and both are required. Each takes a
branch, a tag or a commit.

`--base fork-point` is usually what you want. It finds where your branch diverged
from master and compares against that, so the difference is your change and not
whatever else landed in master since you branched. The alternative, `--base
master`, mixes the two together.

**A bare ref means upstream `ethereum/go-ethereum`**, so `master` and tags always
mean the canonical ones. Anything living in a fork needs its owner named, your own
branches included:

```bash
bash scripts/run.sh --base fork-point --feature jrhea:my-branch
bash scripts/run.sh --base fork-point --feature rjl493456442:optimize-commit
```

Push your branch to your fork first, and from the Actions form the owner is the
fork dropdown instead of a prefix. Only owners listed in [forks.txt](forks.txt)
resolve, and that file is a trust boundary rather than a convenience: whatever ref
you name gets fetched, built and executed on the box as a user with passwordless
root. Adding a line to it is the whole authorization, so it goes through a PR.

### Naming the run

`--label` decides where results are kept, under `benchmarks/<label>/`. Leave it
out and the run is named after the two refs, which is what the example above did.
Re-using a label is fine and keeps the earlier runs, since each one gets its own
timestamped directory inside. Whatever you pass gets cleaned into something safe
for a directory name, so a label with spaces comes back hyphenated. The label is
always printed when the run starts.

`--base-label` and `--feature-label` only change what the report heading calls
each side. Worth setting when a ref reads badly, like a bare commit hash.

### How much to measure

`--blocks` is how many blocks each pass replays, 2000 by default, which is the
size of the pinned window. `--runs` is how many times each side is measured, 3 by
default. `--warmup` matches `--blocks` unless you say otherwise.

Leave all three alone for a real measurement. Three runs is what makes a small
difference believable, and the report has no error bars with fewer. Shrink them
only for a smoke test:

```bash
bash scripts/run.sh --base master --feature master --blocks 20 --runs 1
```

### Measuring under a different configuration

`--geth-args` adds flags to the geth under test. They apply to both sides, so the
comparison stays about the code:

```bash
bash scripts/run.sh --base fork-point --feature jrhea:my-branch --geth-args "--cache.noprefetch"
```

The report records the flags in its header, because a run with them is not
comparable to one without. To measure a *flag* rather than a code change, run
`master` against `master` twice, once with it and once without, then compare the
two reports.

### Before committing 40 minutes

`--dry-run` prints the command it would run and stops. It still resolves the refs,
so it also tells you whether your branch and fork point exist.

`bash scripts/run.sh --help` lists every option.

**One run at a time.** There is a single datadir and a single port pair, so a
second launch from the command line is refused and a second dispatch waits its
turn.

## Checking progress

The quickest answer, with no arguments at all, reports whatever is running:

```bash
bash scripts/progress.sh
```

```
active  pass 4/7 (run 2 feature)  6412/14000 blocks  45%
```

Pass 1 is the warmup and then there are two per run, so the default `--runs 3` is
seven passes. Pass a label to ask about a specific benchmark instead:

```bash
bash scripts/progress.sh jrhea-trie-prefetch-batch-vs-fork-point
```

For live per-block output, tagged with the pass it belongs to:

```bash
tsh ssh debian@geth-benchmark-1 'tail -f /home/debian/benchmarks/jrhea-trie-prefetch-batch-vs-fork-point/reth-bench.log'
```

For what the runner itself is doing, including the builds:

```bash
tsh ssh debian@geth-benchmark-1 'sudo journalctl -u bench -f -o cat'
```

A run started from the Actions tab needs the same commands to watch it. Its `run
it` step prints `Running as unit: bench.service` and then nothing until the run
ends, because the output goes to the box's journal rather than back to the runner.
The label does show up in the run summary as soon as it is resolved, which is the
one thing the page is good for while you wait.

**Expected pace**, so you can tell slow from stuck: a 2000-block pass replays in
about 200s, plus node start, rewind and flush, so **5-6 minutes per pass** and
**40 minutes** for seven. A run that ends in under 20 minutes failed, and
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) covers why.

## Viewing results

Reports live with the run that produced them, at
`benchmarks/<label>/results/<timestamp>/report.md`. What the numbers mean is
[RESULTS.md](RESULTS.md).

```bash
bash scripts/latest-report.sh jrhea-trie-prefetch-batch-vs-fork-point
```

It prints the newest run's report as markdown, ready to paste into a PR. It
refuses rather than quietly handing you an older run's report when the newest one
has not written one yet.

With no label, it lists every benchmark, its most recent run, and whether that run
produced a report:

```bash
bash scripts/latest-report.sh
```

```
  LABEL                          LATEST RUN         REPORT
  jrhea-trie-prefetch-batch-... 20260805_165916    yes
  jrhea-txpool-reheap-vs-master  20260807_174135    yes
  fjl-slot-cache-vs-fork-point   20260804_195120    not written
```

To read it rendered instead of raw in a terminal:

```bash
bash scripts/latest-report.sh jrhea-trie-prefetch-batch-vs-fork-point > /tmp/report.md && open /tmp/report.md
```

An older run, once a label has several:

```bash
tsh ssh debian@geth-benchmark-1 'cat /home/debian/benchmarks/jrhea-trie-prefetch-batch-vs-fork-point/results/20260807_174135/report.md'
```

Runs started from the Actions tab also attach the report, the metadata and the
per-block CSVs to the run as an artifact, which is the easiest way to get the raw
latencies onto your own machine.

To regenerate a report, after changing `report.py` or to relabel the sides. Pass
the run directory and it picks the newest results inside:

```bash
tsh ssh debian@geth-benchmark-1 'python3 /home/debian/geth-benchmark/scripts/report.py --results /home/debian/benchmarks/jrhea-trie-prefetch-batch-vs-fork-point'
```

It needs nothing else, because each run leaves a `bench-meta.json` holding the
refs and the commits that were built. `--base-label` and `--target-label` override
the heading.

## Changing the block window

Every run replays the same blocks. The node's head is pinned and the harness
replays what comes after it, so if the head ever drifts, each run quietly
benchmarks a different range and results stop being comparable.

Where it sits today:

| | |
|---|---|
| pinned head | 25,677,500 |
| window | 25,677,501 .. 25,679,500 (2000 blocks) |
| snap-sync pivot floor | 25,676,837 (663 blocks of margin) |
| cache range | 25,676,776 .. 25,681,527 |
| block cache | `/datadrive/blockcache`, served on `127.0.0.1:8600` |
| datadir backup | `/datadrive/geth-backup`, same pinned state |

Moving it means syncing to tip, which can take hours, so it runs on the box under
systemd rather than in your `tsh` session where a dropped connection would kill it
halfway:

```bash
tsh ssh debian@geth-benchmark-1 'sudo systemd-run --unit=newwindow --uid=debian --gid=debian --collect --property=TimeoutStopSec=infinity bash /home/debian/geth-benchmark/scripts/new-window.sh --blocks 2000'
```

Then watch it:

```bash
tsh ssh debian@geth-benchmark-1 'sudo journalctl -u newwindow -f -o cat'
```

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

What it does, in order:

1. Starts geth and blsync and waits until the local head is within 4 blocks of the
   beacon chain's execution head. This is the slow part.
2. Picks the pin: `tip - blocks - margin`, or exactly `--pin N`.
3. Refuses if that rewind is deeper than `--max-rewind`, or if the pin falls below
   the snap-sync pivot floor, where there is no state left to execute from.
4. Caches the blocks *before* rewinding, from `pin - 64` through `pin + blocks`.
   The rewind deletes them from the node, and reth-bench reads N-32 and N-64 for
   the safe and finalized hashes, hence the 64.
5. Fetches those blocks' EIP-7685 execution requests from the beacon chain and
   checks each against the block's own `requestsHash`.
6. Stops blsync and confirms it stopped, then rewinds with `debug_setHead`. blsync
   running during a rewind leaves the datadir unrecoverable.
7. Stops geth, waits out the flush however long it takes, and checks the log for a
   clean shutdown.
8. Starts the block cache and prints the rows to record.

Useful options, with the rest under `--help`:

| | |
|---|---|
| `--blocks N` | window size, default 2000 |
| `--margin N` | gap between the pinned head and tip, default 200 |
| `--pin N` | pin at exactly this block and cache from there to tip, instead of `tip - blocks - margin`. Use it to sit just above the pivot floor so the window can grow as the chain advances. |
| `--max-rewind N` | refuse to rewind further than this, default 50000 |
| `--datadir PATH` | work on a copy instead of `/datadrive/geth` |

Step 8 writes `benchmarks/window.env`, which is where the pinned head and window
size actually live:

```
PIN=25677500
BLOCKS=2000
```

Benchmarks read that file and refuse to start without it, so moving the window
cannot leave a run rewinding to the previous pin. The table above is for humans,
so update it to match after a move.

**Only shallow rewinds on this datadir.** `setHead` deletes bodies and receipts
above the new head, so a deep rewind destroys months of chain data and getting
back to tip means a fresh snap sync. To benchmark an older window, copy the
datadir and work on the copy with `--datadir` and a larger `--max-rewind`. A copy
is about 690 GB and ten minutes, and eight fit in free space.

Restoring the backup, with geth stopped:

```bash
tsh ssh debian@geth-benchmark-1 'sudo rm -rf /datadrive/geth && sudo cp -a /datadrive/geth-backup /datadrive/geth'
```

## Maintenance

Start with the health check, which reports the services, the head, disk and
whether the performance settings survived the last reboot:

```bash
bash scripts/status.sh
```

```
services
  geth-bench     inactive   slice=bench.slice
  blsync-bench   inactive   slice=system.slice

head
  local  25677500
  behind (no age in recent log, likely at tip)

disk
  root    1.3T used, 5.3T free (20%)
  datadir 646G

performance settings
  governor  performance  (want: performance)
  boost     0  (1 = on)
```

`inactive` is the correct state between benchmarks. geth and blsync are stopped
and disabled at boot so that nothing moves the pinned head, and a benchmark stops
them itself before it starts. You only need to start them by hand to let the node
follow the chain again:

```bash
tsh ssh debian@geth-benchmark-1 'sudo systemctl start geth-bench blsync-bench'
```

Stopping them, blsync first, since it must not be writing during a rewind:

```bash
tsh ssh debian@geth-benchmark-1 'sudo systemctl stop blsync-bench geth-bench'
```

geth can take minutes to flush. Confirm it got there before doing anything else
with the datadir:

```bash
tsh ssh debian@geth-benchmark-1 'sudo journalctl -u geth-bench -n 20 -o cat | grep -E "Persisted|Blockchain stopped"'
```
