#!/usr/bin/env python3
"""
Format a reth-bench-compare results directory as a markdown benchmark report.

bench.sh writes one at the end of every run. To regenerate it:

  ./report.py --results /home/debian/benchmarks/my-branch

Everything comes from the per-block CSVs the harness writes. The harness reports
means only, so percentiles and the paired per-block stats are computed here.

bench.sh leaves a bench-meta.json in the results dir with the refs, the commits it
built and the slow-block log path, and this reads it. Without that file, pass the
refs and the log path by hand.

--slowblock-log adds the execution breakdown. It needs geth run with
--debug.logslowblock 0 (0 logs every block, the default -1 disables it) and
--log.file:

  reth-bench-compare ... -- --debug.logslowblock 0 --log.file /tmp/slowblock.log

Every figure is computed per run and then averaged, and carries a +/- which is the
half-range across runs. One rule decides whether a difference counts:

  - two sides measured separately, such as base and target p50: their ranges must
    not overlap
  - a paired delta, which is a single series: its own range must exclude zero, so
    every run agreed on the sign

Both need --runs > 1. Thermal state, page cache warmth and GC timing shift every
block in a pass by the same amount, so they never appear as per-block scatter and
more blocks in one pass will not reveal them.

Mean and median both appear because they answer different questions. The median is
the typical block. The mean is total time, and it adds up, so a bucket's share of
a headline change can be read off it directly.

The mean of the per-block percentage changes is not reported. Small blocks
dominate it, since a fraction of a millisecond is a large percentage.
"""
import argparse
import csv
import json
import os
import re
import statistics as st
import subprocess
import sys
import time


def pct(vals, p):
    if not vals:
        return float("nan")
    s = sorted(vals)
    if len(s) == 1:
        return s[0]
    k = (len(s) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)




def read_side(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            rows.append(
                {
                    "block": int(r["block_number"]),
                    "gas": int(r["gas_used"]),
                    "np": int(r["new_payload_latency"]) / 1000.0,   # us -> ms
                    "fcu": int(r["fcu_latency"]) / 1000.0,
                    "total": int(r["total_latency"]) / 1000.0,
                }
            )
    return rows


def summarize(rows):
    np_ms = [r["np"] for r in rows]
    total_gas = sum(r["gas"] for r in rows)
    total_ms = sum(r["total"] for r in rows)
    return {
        "blocks": len(rows),
        "total_gas": total_gas,
        "mgas_s": (total_gas / 1e6) / (total_ms / 1000.0) if total_ms else float("nan"),
        "mean": st.fmean(np_ms),
        "p50": pct(np_ms, 50),
        "p95": pct(np_ms, 95),
        "p99": pct(np_ms, 99),
        "min": min(np_ms),
        "max": max(np_ms),
    }


# ------------------------------------------------------- paired-delta plumbing

def deltas(base_map, targ_map):
    """Per-block percent change, each block against itself."""
    return [
        (targ_map[k] - v) / v * 100.0
        for k, v in base_map.items()
        if k in targ_map and v > 0
    ]


def faster_pct(ds):
    return sum(1 for d in ds if d < 0) / len(ds) * 100.0 if ds else float("nan")


def half_range(vals):
    """Half-range in the values' own units, for quantities already in percent.

    Use this rather than spread() for deltas. The half-range of -1.4/-1.5/-1.6 is
    0.1 points, not 7%.
    """
    return (max(vals) - min(vals)) / 2 if len(vals) > 1 else None


def excludes_zero(vals):
    """Did every run agree on the sign? None when there is only one run."""
    if len(vals) < 2:
        return None
    return min(vals) > 0 or max(vals) < 0


def disjoint(a, b):
    """Do two sides' run ranges avoid overlapping? None with only one run."""
    if len(a) < 2 or len(b) < 2:
        return None
    return max(b) < min(a) or min(b) > max(a)


# ------------------------------------------------------------- slow-block log

SLOW_RE = re.compile(r'(\{"level".*\})\s*$')


def read_slowblocks(path):
    """Parse geth's --debug.logslowblock JSON lines and split them into passes.

    Every pass replays the same block range and geth appends to one file, so
    passes are separated by the block number going backwards. Splitting on that
    rather than on timestamps avoids comparing geth's local-time log prefix
    against the report's UTC stamps.
    """
    passes, cur, last = [], [], None
    with open(path) as f:
        for line in f:
            m = SLOW_RE.search(line)
            if not m:
                continue
            try:
                d = json.loads(m.group(1))
            except ValueError:
                continue
            n = d["block"]["number"]
            if last is not None and n <= last:
                passes.append(cur)
                cur = []
            cur.append(d)
            last = n
    if cur:
        passes.append(cur)
    return passes


BUCKETS = [
    ("execution", lambda d: d["timing"]["execution_ms"]),
    ("state read", lambda d: d["timing"]["state_read_ms"]),
    ("state hash", lambda d: d["timing"]["state_hash_ms"]),
    ("commit", lambda d: d["timing"]["commit_ms"]),
    ("block total", lambda d: d["timing"]["total_ms"]),
]
RATES = [
    ("account cache hits", lambda d: d["cache"]["account"]["hit_rate"]),
    ("storage cache hits", lambda d: d["cache"]["storage"]["hit_rate"]),
    ("code cache hits", lambda d: d["cache"]["code"]["hit_rate"]),
]


def series(pass_, get):
    return {d["block"]["number"]: get(d) for d in pass_}


# Shown in milliseconds per side. These give the size of the bucket, the delta
# columns give the change.
MS_COLS = (
    ("p50", lambda v: pct(v, 50)),
    ("p95", lambda v: pct(v, 95)),
)


def pass_pairs(passes, n_runs):
    """[(base_pass, feature_pass), ...], one per run, orientation resolved.

    The harness alternates which reference goes first (cli.rs: if run % 2 == 1),
    so the log holds base,feature on odd runs and feature,base on even ones.
    Nothing in the log says which is which, and getting it backwards inverts every
    delta in the breakdown, so derive it from the run index and check it against
    the harness's labelled CSVs in verify_orientation().
    """
    extra = len(passes) - 2 * n_runs        # 1 if a warmup pass ran, else 0
    if extra not in (0, 1):
        return None, (
            f"expected {2 * n_runs} or {2 * n_runs + 1} passes for {n_runs} runs, "
            f"found {len(passes)}"
        )
    out = []
    for k in range(1, n_runs + 1):
        a, b = passes[extra + 2 * (k - 1)], passes[extra + 2 * k - 1]
        out.append((a, b) if k % 2 == 1 else (b, a))
    return out, None


def verify_orientation(pairs, runs):
    """Confirm each pass really is the side we think it is.

    The harness writes per-side CSVs into labelled directories, so those are
    ground truth. A pass tracks its own CSV block for block including the noise, so
    the right assignment is the one with the smaller mismatch. Returns the runs
    where the log disagrees with the CSVs.
    """
    bad = []
    for i, ((bp, tp), (_, brows, trows)) in enumerate(zip(pairs, runs), start=1):
        bcsv = {r["block"]: r["np"] for r in brows}
        tcsv = {r["block"]: r["np"] for r in trows}

        def cost(p, csv):
            v = [
                abs(d["timing"]["total_ms"] - csv[d["block"]["number"]])
                for d in p
                if d["block"]["number"] in csv
            ]
            return st.fmean(v) if v else float("inf")

        if cost(bp, tcsv) + cost(tp, bcsv) < cost(bp, bcsv) + cost(tp, tcsv):
            bad.append(i)
    return bad


def bucket_series(pairs, runs):
    """{bucket: [(base series, target series), ...]}, one entry per run.

    Every bucket but engine overhead comes from geth's timers. Overhead is
    newPayload latency minus geth's block total, so it needs the harness CSVs too.
    It is the engine API work outside geth's timers, roughly a fifth of newPayload.
    """
    out = {name: [] for name, _ in BUCKETS}
    out["engine overhead"] = []
    total = dict(BUCKETS)["block total"]
    for (bp, tp), (_, brows, trows) in zip(pairs, runs):
        for name, get in BUCKETS:
            out[name].append((series(bp, get), series(tp, get)))
        bnp = {r["block"]: r["np"] for r in brows}
        tnp = {r["block"]: r["np"] for r in trows}
        out["engine overhead"].append((
            {k: bnp[k] - v for k, v in series(bp, total).items() if k in bnp},
            {k: tnp[k] - v for k, v in series(tp, total).items() if k in tnp},
        ))
    return out


def breakdown(pairs, runs):
    """Per-bucket p50/p95 per side and the paired delta, each with its run spread.

    Computed per run and then averaged so every number carries a ± and is judged by
    the same rule as the Results rows.
    """
    rows, total_n = [], 0
    for name, per_run_series in bucket_series(pairs, runs).items():
        per_run = []
        for bs, ts_ in per_run_series:
            bv = [v for k, v in bs.items() if k in ts_]
            tv = [v for k, v in ts_.items() if k in bs]
            d = deltas(bs, ts_)
            r = {
                # median of the per-block changes, which is not the change in
                # the median. This one pairs each block with itself.
                "paired": st.median(d) if d else float("nan"),
                "faster": faster_pct(d),
                "n": len(d),
                # this is the delta that adds up. Block total plus engine
                # overhead equals newPayload exactly.
                "d_mean": (st.fmean(tv) - st.fmean(bv)) / st.fmean(bv) * 100.0,
            }
            for agg, f in MS_COLS:
                b, t = f(bv), f(tv)
                r["b_" + agg], r["t_" + agg] = b, t
                # drives the mark on the target cell
                r["d_" + agg] = (t - b) / b * 100.0 if b else float("nan")
            per_run.append(r)

        row = {"name": name}
        for k in per_run[0]:
            if k == "n":
                continue
            vals = [r[k] for r in per_run]
            row[k] = st.fmean(vals)
            row[k + "_sp"] = half_range(vals)
        # a delta counts when every run agreed on the sign
        for k in ("paired", "d_mean"):
            row[k + "_est"] = excludes_zero([r[k] for r in per_run])
        # p50 and p95 are two separately measured sides, so the test is whether
        # their run ranges overlap, the same rule the Results table uses
        for agg, _ in MS_COLS:
            row[f"d_{agg}_est"] = disjoint([r["b_" + agg] for r in per_run],
                                           [r["t_" + agg] for r in per_run])
        # 50% is this column's no-change point, so shift and reuse the same test
        row["faster_est"] = excludes_zero([r["faster"] - 50 for r in per_run])
        rows.append(row)
        total_n = max(total_n, sum(r["n"] for r in per_run))

    rates = []
    for name, get in RATES:
        bv = [get(d) for bp, _ in pairs for d in bp]
        tv = [get(d) for _, tp in pairs for d in tp]
        rates.append((name, st.fmean(bv), st.fmean(tv)))
    return rows, rates, total_n


# ------------------------------------------------------------------- results

def discover_runs(results_dir):
    """Return [(run_label, baseline_rows, feature_rows), ...].

    With --runs > 1 the harness writes results/<ts>/runN/{baseline,feature}/.
    Fall back to the single-run layout when no runN directories exist.
    """
    runs = []
    names = sorted(
        (d for d in os.listdir(results_dir) if re.fullmatch(r"run\d+", d)),
        key=lambda d: int(d[3:]),
    )
    for name in names:
        b = os.path.join(results_dir, name, "baseline", "combined_latency.csv")
        f = os.path.join(results_dir, name, "feature", "combined_latency.csv")
        if os.path.exists(b) and os.path.exists(f):
            runs.append((name, read_side(b), read_side(f)))
    if not runs:
        b = os.path.join(results_dir, "baseline", "combined_latency.csv")
        f = os.path.join(results_dir, "feature", "combined_latency.csv")
        runs.append(("run1", read_side(b), read_side(f)))
    return runs


def spread(values):
    """Half-range as a percent of the mean.

    Not a standard deviation. With 3 runs an SD is barely determined, and
    half-range is what a reader takes '±' to mean.
    """
    if len(values) < 2:
        return None
    m = st.fmean(values)
    if m == 0:
        return None
    return (max(values) - min(values)) / 2 / m * 100.0


def places(hr, dec):
    """Enough decimals for the ± to show a digit. A printed '±0.0' says nothing,
    and it looks wrong next to a delta that has a visible spread."""
    while hr and round(hr, dec) == 0 and dec < 3:
        dec += 1
    return dec


def fmt_val(value, hr, dec=None, unit=""):
    """'81.9 ±0.2 ms', '72% ±1%'. The ± is in the column's own units."""
    if dec is None:
        dec = 2 if abs(value) < 10 else 1
    dec = places(hr, dec)
    if unit == "%":
        v = f"{value:.{dec}f}%"
        return v if hr is None else f"{v} ±{hr:.{dec}f}%"
    v = f"{value:.{dec}f}"
    body = v if hr is None else f"{v} ±{hr:.{dec}f}"
    return f"{body} {unit}".strip()


def fmt_delta(d, hr):
    """'-1.5% ±0.1%'. Both in points, since the column is already a percentage."""
    dec = places(hr, 1)
    v = f"{d:+.{dec}f}%"
    return v if hr is None else f"{v} ±{hr:.{dec}f}%"


def direction(delta_pct, lower_is_better=True):
    return "▲" if (delta_pct < 0 if lower_is_better else delta_pct > 0) else "▼"




def newest_csv_time(root):
    """When the last pass finished, taken from the results themselves."""
    newest = 0.0
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if fn == "combined_latency.csv":
                newest = max(newest, os.path.getmtime(os.path.join(dirpath, fn)))
    return time.strftime("%Y-%m-%d %H:%M", time.gmtime(newest)) if newest else "?"


def blocks_label(n):
    return f"{n // 1000}k" if n >= 1000 and n % 1000 == 0 else str(n)




# --------------------------------------------------------------- git lookups

def git(repo, *a):
    """stdout on success, None on any failure. Empty string is a valid success."""
    try:
        r = subprocess.run(
            ("git", "-C", repo) + a, capture_output=True, text=True, timeout=30
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def remote_url(repo, name):
    raw = git(repo, "remote", "get-url", name)
    if not raw:
        return None
    m = re.search(r"github\.com[:/]+([^/]+/[^/.]+?)(?:\.git)?$", raw)
    return f"https://github.com/{m.group(1)}" if m else None


def ref_info(repo, ref, sha, base_ref=None):
    """Commit, subject, link and position relative to base. Degrades to a bare
    label when the repo is not reachable, so a report is still generated."""
    info = {"ref": ref, "sha": sha, "subject": None, "url": None,
            "ahead": None, "behind": None}
    if not repo or not os.path.isdir(os.path.join(repo, ".git")):
        return info
    if not info["sha"]:
        info["sha"] = git(repo, "rev-parse", ref)
    if not info["sha"]:
        return info
    info["subject"] = git(repo, "log", "-1", "--format=%s", info["sha"])
    # Link to upstream when the commit is on upstream/master, otherwise to the
    # fork. A branch commit does not exist in ethereum/go-ethereum, its link
    # would 404.
    remote = "origin"
    if git(repo, "merge-base", "--is-ancestor", info["sha"], "upstream/master") is not None:
        remote = "upstream"
    info["url"] = remote_url(repo, remote)
    if base_ref and base_ref != ref:
        lr = git(repo, "rev-list", "--left-right", "--count", f"{base_ref}...{info['sha']}")
        if lr and len(lr.split()) == 2:
            behind, ahead = (int(x) for x in lr.split())
            info["ahead"], info["behind"] = ahead, behind
    return info


def ref_line(role, info, go_version):
    """- **base** `master` @ [`7a1b11564c`](url) — subject · go1.26.5 · N ahead"""
    bits = [f"- **{role}** `{info['ref']}`"]
    if info["sha"]:
        short = info["sha"][:10]
        bits.append(
            f"@ [`{short}`]({info['url']}/commit/{info['sha']})" if info["url"]
            else f"@ `{short}`"
        )
    if info["subject"]:
        bits.append(f"— `{info['subject']}`")
    tail = []
    if go_version:
        tail.append(go_version)
    if info["ahead"] is not None:
        tail.append(
            f"{info['ahead']} commit{'s' if info['ahead'] != 1 else ''} ahead, "
            f"{info['behind']} behind"
        )
    line = " ".join(bits)
    return f"{line} · {' · '.join(tail)}" if tail else line


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True,
                    help="a run directory, or one of the timestamped ones in it")
    ap.add_argument("--base-label", default=None)
    ap.add_argument("--target-label", default=None)
    ap.add_argument("--machine", default=None)
    ap.add_argument("--repo", default="/home/debian/go-ethereum",
                    help="go-ethereum checkout, for commit subjects and links")
    ap.add_argument("--slowblock-log", default=None,
                    help="geth log written with --debug.logslowblock 0 --log.file")
    args = ap.parse_args()

    R = args.results.rstrip("/")
    # accept the run directory as well as one of the timestamped ones inside it.
    # bench.sh clears the run directory first so there is normally one, but the
    # harness appends if it is driven by hand, so say which one was picked.
    inner = os.path.join(R, "results")
    if os.path.isdir(inner):
        # the names sort chronologically, unlike mtime, which anything can bump
        stamped = sorted(d for d in os.listdir(inner)
                         if re.fullmatch(r"\d{8}_\d{6}", d))
        if not stamped:
            raise SystemExit(f"no results in {inner}")
        if len(stamped) > 1:
            print(f"{len(stamped)} result sets in {inner}, using the newest "
                  f"({stamped[-1]}); the others are "
                  f"{', '.join(stamped[:-1])}", file=sys.stderr)
        R = os.path.join(inner, stamped[-1])
    # The harness writes comparison_report.json after its final rewind and flush,
    # minutes after the last pass has its CSV, and everything in it is recomputed
    # here from those CSVs anyway. Read it only as a label fallback.
    meta = {}
    cr = os.path.join(R, "comparison_report.json")
    if os.path.exists(cr):
        with open(cr) as f:
            meta = json.load(f)

    # bench.sh records the run's parameters and the commits it built, above the
    # results before they exist and beside them afterwards
    bm = {}
    for cand in (os.path.join(R, "bench-meta.json"),
                 os.path.join(R, "..", "..", "bench-meta.json")):
        if os.path.exists(cand):
            with open(cand) as f:
                bm = json.load(f)
            break

    machine = args.machine or bm.get("machine") or "geth-benchmark-1"
    slowblock = args.slowblock_log or bm.get("slowblock_log")

    runs = discover_runs(R)
    n_runs = len(runs)
    per_run = [(lbl, summarize(bb), summarize(tt)) for lbl, bb, tt in runs]

    # mean across runs, with the half-range as the +/-
    def agg(side_idx, key):
        vals = [r[side_idx][key] for r in per_run]
        return st.fmean(vals), half_range(vals)

    base_label = (args.base_label or bm.get("base_label") or bm.get("base_ref")
                  or meta.get("baseline", {}).get("ref_name", "base"))
    targ_label = (args.target_label or bm.get("feature_label") or bm.get("feature_ref")
                  or meta.get("feature", {}).get("ref_name", "target"))
    base_info = ref_info(args.repo, base_label, bm.get("base_sha"))
    # compare against the commit, not the label, which may not be a git ref
    targ_info = ref_info(args.repo, targ_label, bm.get("feature_sha"),
                         base_ref=base_info["sha"] or base_label)
    go_version = None
    try:
        gv = subprocess.run(("go", "version"), capture_output=True, text=True, timeout=30)
        if gv.returncode == 0:
            go_version = gv.stdout.split()[2]
    except (OSError, subprocess.SubprocessError, IndexError):
        pass

    # Each block against itself, which cancels block-to-block variation and is far
    # less noisy than comparing aggregates. Computed per run and then averaged, the
    # same way the breakdown does it, so the value and its ± come from one method.
    np_maps = [
        ({r["block"]: r["np"] for r in bb}, {r["block"]: r["np"] for r in tt})
        for _, bb, tt in runs
    ]
    run_deltas = [deltas(b, t) for b, t in np_maps]
    run_medians = [st.median(d) for d in run_deltas]
    paired_median, med_sp = st.fmean(run_medians), half_range(run_medians)
    faster = st.fmean([faster_pct(d) for d in run_deltas])
    # change in total time, per run
    run_means = [
        (st.fmean(t.values()) - st.fmean(b.values())) / st.fmean(b.values()) * 100.0
        for b, t in np_maps
    ]
    mean_delta, mean_sp = st.fmean(run_means), half_range(run_means)

    lo, hi = min(r["block"] for r in runs[0][1]), max(r["block"] for r in runs[0][1])
    out = []
    out.append(f"### Bench: `{base_label}` → `{targ_label}`\n")
    out.append(
        f"**{blocks_label(len(runs[0][1]))}** payload · blocks {lo}–{hi} · "
        f"{n_runs} run{'s' if n_runs != 1 else ''}/side · machine `{machine}`"
    )
    # the results dir is stamped when the harness starts, which includes the
    # builds. comparison_report.json only covers the final run.
    started = bm.get("started")
    if not started:
        m = re.fullmatch(r"(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})\d{2}", os.path.basename(R))
        started = (f"{m[1]}-{m[2]}-{m[3]} {m[4]}:{m[5]}" if m else newest_csv_time(R))
    out.append(f"ran {started} – {newest_csv_time(R)} UTC")
    # both sides ran with these, and a run that had them is not comparable to one
    # that did not, so it belongs in the header rather than in someone's memory
    if bm.get("geth_args"):
        out.append(f"both sides with `{bm['geth_args']}`")
    out.append("")
    out.append(ref_line("base", base_info, go_version))
    out.append(ref_line("target", targ_info, go_version) + "\n")

    # "2000 blocks x 3 runs" rather than "n=6000". The same blocks are measured
    # once per run, so repeats tighten each block's estimate, they do not add
    # blocks.
    n_label = (f"{len(runs[0][1])} blocks × {n_runs} runs" if n_runs > 1
               else f"n={len(run_deltas[0])}")
    out.append(
        f"**Paired per-block newPayload** ({n_label}): "
        f"median **{fmt_delta(paired_median, med_sp)}** · "
        f"mean {fmt_delta(mean_delta, mean_sp)} · "
        f"**{faster:.0f}% of blocks faster**\n"
    )

    out.append("#### Results\n")
    out.append(f"| metric | base (`{base_label}`) | target (`{targ_label}`) | Δ |")
    out.append("| :--- | ---: | ---: | ---: |")
    rows = [
        ("throughput MGas/s", "mgas_s", "", False),
        ("mean newPayload", "mean", "ms", True),
        ("p50 newPayload", "p50", "ms", True),
        ("p95 newPayload", "p95", "ms", True),
        ("p99 newPayload", "p99", "ms", True),
    ]
    for name, key, unit, lower_better in rows:
        bv, bs = agg(1, key)
        tv, ts_ = agg(2, key)
        d = (tv - bv) / bv * 100.0
        # A row counts only when the two sides' run ranges do not overlap, so no
        # run-to-run drift within the observed spread could flip the sign. Using
        # both ranges keeps a noisy target from raising the bar for a quiet base.
        if disjoint([r[1][key] for r in per_run], [r[2][key] for r in per_run]) is False:
            m = "≈"
        else:
            m = direction(d, lower_better)
        out.append(
            f"| {name} | {fmt_val(bv, bs, 1, unit)} | "
            f"{fmt_val(tv, ts_, 1, unit)} | **{d:+.1f}%** {m} |"
        )
    out.append(
        "\n▲ improvement · ▼ regression · ≈ not established · ± half-range across runs\n"
    )
    if n_runs < 2:
        out.append("Single run per side: no ±, nothing to judge against.\n")

    out.append(f"#### Per-run ({n_runs} run{'s' if n_runs != 1 else ''}/side)\n")
    out.append("| side | run | MGas/s | mean | p50 | p95 | p99 | min | max | total gas |")
    out.append("| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for side_name, idx in (("base", 1), ("target", 2)):
        for k, (lbl, bs_, ts_) in enumerate(per_run, start=1):
            sm = bs_ if idx == 1 else ts_
            out.append(
                f"| {side_name} | {k} | {sm['mgas_s']:.1f} | {sm['mean']:.1f} ms | "
                f"{sm['p50']:.1f} ms | {sm['p95']:.1f} ms | {sm['p99']:.1f} ms | "
                f"{sm['min']:.1f} ms | {sm['max']:.1f} ms | {sm['total_gas'] / 1e9:.1f} Ggas |"
            )
    out.append("")

    if slowblock and os.path.exists(slowblock):
        passes = read_slowblocks(slowblock)
        pairs, err = pass_pairs(passes, n_runs)
        bad = verify_orientation(pairs, runs) if pairs else []
        if err:
            out.append(f"\n> Skipping the execution breakdown: {err}.\n")
        elif bad:
            # refuse rather than risk printing a sign-flipped breakdown
            out.append(
                f"\n> Skipping the execution breakdown: the pass order in "
                f"`{slowblock}` does not match the harness's own CSVs for run(s) "
                f"{', '.join(map(str, bad))}, so which pass belongs to which side is "
                f"not certain and the deltas could come out inverted.\n"
            )
        else:
            brows, rates, n = breakdown(pairs, runs)
            bl = (f"{n // len(pairs)} blocks × {len(pairs)} runs" if len(pairs) > 1
                  else f"n={n}")
            out.append(f"#### Execution breakdown (per block, {bl})\n")
            heads = [f"base {a} | target {a}" for a, _ in MS_COLS]
            out.append(
                f"| bucket | {' | '.join(heads)} | mean Δ | median Δ | "
                f"blocks faster |"
            )
            out.append("| :--- " + "| ---: " * (2 * len(MS_COLS) + 3) + "|")
            for r in brows:
                cells = []
                for agg, _ in MS_COLS:
                    bv, tv = r["b_" + agg], r["t_" + agg]
                    bh, th = r[f"b_{agg}_sp"], r[f"t_{agg}_sp"]
                    # one precision per pair, so a steady target is not printed to
                    # more places than the base beside it
                    start = 2 if abs(bv) < 10 else 1
                    dec = max(places(bh, start), places(th, start))
                    am = ("≈" if r[f"d_{agg}_est"] is False
                          else direction(r[f"d_{agg}"]))
                    cells.append(fmt_val(bv, bh, dec, "ms"))
                    cells.append(f"{fmt_val(tv, th, dec, 'ms')} {am}")
                mm = "≈" if r["d_mean_est"] is False else direction(r["d_mean"])
                # bold the median delta when it counts
                b = "**" if r["paired_est"] else ""
                pm = "≈" if r["paired_est"] is False else direction(r["paired"])
                # above 50% is the good direction here
                fm = ("≈" if r["faster_est"] is False
                      else direction(r["faster"] - 50, False))
                out.append(
                    f"| {r['name']} | {' | '.join(cells)} | "
                    f"{fmt_delta(r['d_mean'], r['d_mean_sp'])} {mm} | "
                    f"{b}{fmt_delta(r['paired'], r['paired_sp'])}{b} {pm} | "
                    f"{fmt_val(r['faster'], r['faster_sp'], 0, '%')} {fm} |"
                )
            out.append("")
            out.append("| rate | base | target |")
            out.append("| :--- | ---: | ---: |")
            for name, b_, t_ in rates:
                out.append(f"| {name} | {b_:.1f}% | {t_:.1f}% |")
            out.append("")
    elif slowblock:
        out.append(f"\n> No slow-block log at {slowblock}, so no execution breakdown.\n")
    else:
        out.append(
            "\n> No execution breakdown. Run the harness with "
            "`-- --debug.logslowblock 0 --log.file <path>` and pass that path to "
            "--slowblock-log.\n"
        )

    print("\n".join(out))


if __name__ == "__main__":
    main()
