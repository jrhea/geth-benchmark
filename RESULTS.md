# Reading the results

What the report contains, and how to tell a real difference from noise.
Running one: [README.md](README.md)

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
