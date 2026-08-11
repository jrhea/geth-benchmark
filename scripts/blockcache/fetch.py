#!/usr/bin/env python3
"""
Fetch a range of blocks from a real RPC once and write them to disk.

  ./fetch.py --rpc-url https://... --from 25675685 --to 25677749 --out /datadrive/blockcache

Writes one file per block plus a meta.json. Safe to re-run, it skips blocks it
already has, so an interrupted fetch just resumes.

Note the range needs to start 64 blocks BELOW your benchmark window, because
reth-bench also reads N-32 and N-64 to fill in the safe and finalized hashes.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

TIMEOUT = 30
RETRIES = 5


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    req = urllib.request.Request(
        url,
        data=body.encode(),
        # some public endpoints 403 the default urllib user agent
        headers={"content-type": "application/json", "user-agent": "blockcache-fetch/1"},
    )
    last = None
    for attempt in range(RETRIES):
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                out = json.load(r)
            if "error" in out:
                raise RuntimeError(out["error"])
            return out["result"]
        except Exception as e:  # noqa: BLE001 - retry anything, public RPCs are flaky
            last = e
            # back off, public endpoints rate limit on bulk pulls
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"{method} failed after {RETRIES} tries: {last}")


def fetch_one(url, out_dir, number):
    path = os.path.join(out_dir, f"{number}.json")
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return "skip"
    block = rpc(url, "eth_getBlockByNumber", [hex(number), True])
    if block is None:
        raise RuntimeError(f"block {number} came back null, is the RPC synced past it?")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(block, f, separators=(",", ":"))
    os.replace(tmp, path)  # atomic, so an interrupted write never leaves a partial file
    return "fetched"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc-url", required=True)
    ap.add_argument("--from", dest="start", type=int, required=True)
    ap.add_argument("--to", dest="end", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()

    if args.end < args.start:
        sys.exit("--to must be >= --from")

    os.makedirs(args.out, exist_ok=True)

    chain_id = rpc(args.rpc_url, "eth_chainId", [])
    print(f"chain id {chain_id} ({int(chain_id, 16)})")

    numbers = list(range(args.start, args.end + 1))
    total = len(numbers)
    done = fetched = 0
    t0 = time.time()

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(fetch_one, args.rpc_url, args.out, n): n for n in numbers}
        for fut, n in futures.items():
            try:
                if fut.result() == "fetched":
                    fetched += 1
            except Exception as e:  # noqa: BLE001
                sys.exit(f"\nblock {n}: {e}")
            done += 1
            if done % 50 == 0 or done == total:
                rate = done / max(time.time() - t0, 0.001)
                print(f"  {done}/{total} ({rate:.0f}/s)", end="\r", flush=True)

    print()
    meta = {
        "chain_id": chain_id,
        "first_block": args.start,
        "last_block": args.end,
        "count": total,
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source_rpc": args.rpc_url,
    }
    with open(os.path.join(args.out, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)

    size = sum(
        os.path.getsize(os.path.join(args.out, f))
        for f in os.listdir(args.out)
        if f.endswith(".json")
    )
    print(f"{total} blocks ({fetched} new), {size / 1e9:.2f} GB in {args.out}")


if __name__ == "__main__":
    main()
