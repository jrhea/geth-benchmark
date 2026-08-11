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
bash scripts/run.sh --base master --feature my-branch --label my-label
```

```bash
bash scripts/progress.sh my-label
```

```bash
bash scripts/latest-report.sh my-label
```

That is the whole workflow. `run.sh` returns immediately, `progress.sh` prints one
line, and the report is markdown ready to paste into a PR.

```
active  pass 4/7 (run 2 feature)  6412/14000 blocks  45%
```

One run at a time. A second launch is refused, because there is one datadir and
one port pair.

## Options

| | |
|---|---|
| `--base`, `--feature` | the two refs. Branch, tag or commit. Required. |
| `--label` | groups the run under `benchmarks/<label>/`. Required. Re-using one keeps the earlier runs. |
| `--base-label`, `--feature-label` | what the report heading calls each side. Default to the ref. |
| `--geth-args` | extra flags for the geth under test, applied to both sides. |
| `--blocks`, `--runs`, `--warmup` | 2000, 3, and the same as `--blocks`. |
| `--dry-run` | print the command instead of running it. |

`bash scripts/run.sh --help` lists the same.

**Compare against the fork point, not master's tip**, to isolate your change from
whatever landed since you branched. It needs no push, being already an ancestor of
master, and a bare hash reads badly as a heading, so name it:

```bash
bash scripts/run.sh --label alopt \
  --base "$(git merge-base master my-branch)" --base-label "fork point" \
  --feature my-branch --feature-label "pr/35388"
```

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

`progress.sh` covers most of it. Pass 1 is the warmup, then two per run, so
`--runs 3` is seven passes.

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

Moving it:

```bash
tsh ssh debian@geth-benchmark-1 'bash /home/debian/geth-benchmark/scripts/new-window.sh --blocks 2000'
```

It syncs to tip, rewinds to pin the head, refetches the cache, then prints the
rows to paste into the table above.

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
