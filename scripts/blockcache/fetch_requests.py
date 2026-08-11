#!/usr/bin/env python3
"""
Fetch EIP-7685 execution requests for cached blocks from the beacon chain.

  ./fetch_requests.py --cache /datadrive/blockcache

Why this exists: engine_newPayloadV4 takes executionRequests as a separate
argument, and they are NOT recoverable from the execution layer. geth derives
them while executing, uses them to check the header's requestsHash, and throws
them away. No eth_ RPC exposes them and they are not in the stored block body.
The only place they survive is the beacon block.

Reads blinded beacon blocks rather than full ones. Requests are not part of the
execution payload, so blinding drops the transactions but keeps the requests,
which makes the response about 19x smaller.

Writes <cache>/requests.json mapping block number -> the exact array that
engine_newPayloadV4 wants. Every entry is verified by hashing it with geth's
CalcRequestsHash scheme and comparing against that block's requestsHash, so a
bad encoding fails here with a clear message instead of surfacing later as an
opaque "blockhash mismatch".
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import sys
import urllib.request

# sha256 of the empty input: what requestsHash is when a block has no requests
EMPTY_REQUESTS_HASH = "0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
TIMEOUT = 30


def beacon_get(base, header, path):
    req = urllib.request.Request(base.rstrip("/") + path)
    name, _, value = header.partition(":")
    req.add_header(name.strip(), value.strip())
    req.add_header("user-agent", "blockcache-requests/1")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def hx(s):
    return bytes.fromhex(s[2:] if s.startswith("0x") else s)


def encode_requests(er):
    """Encode beacon execution_requests as EIP-7685 items: type_byte ++ data.

    One item per type holding every request of that type concatenated, matching
    how geth builds them (ParseDepositLogs for 0x00, the system-call return for
    0x01 and 0x02). Empty types are omitted entirely. All three request structs
    are fixed-size SSZ, so plain concatenation is the whole encoding.
    """
    items = []

    # 0x00 deposit: pubkey48 + withdrawal_credentials32 + amount8 + signature96 + index8
    d = b"".join(
        hx(x["pubkey"])
        + hx(x["withdrawal_credentials"])
        + int(x["amount"]).to_bytes(8, "little")
        + hx(x["signature"])
        + int(x["index"]).to_bytes(8, "little")
        for x in er.get("deposits", [])
    )
    if d:
        items.append(b"\x00" + d)

    # 0x01 withdrawal: source_address20 + validator_pubkey48 + amount8
    w = b"".join(
        hx(x["source_address"])
        + hx(x["validator_pubkey"])
        + int(x["amount"]).to_bytes(8, "little")
        for x in er.get("withdrawals", [])
    )
    if w:
        items.append(b"\x01" + w)

    # 0x02 consolidation: source_address20 + source_pubkey48 + target_pubkey48
    c = b"".join(
        hx(x["source_address"]) + hx(x["source_pubkey"]) + hx(x["target_pubkey"])
        for x in er.get("consolidations", [])
    )
    if c:
        items.append(b"\x02" + c)

    return items


def calc_requests_hash(items):
    """geth's core/types/block.go CalcRequestsHash: sha256 over the concatenated
    per-item sha256 digests, skipping items that carry only a type byte."""
    h2 = hashlib.sha256()
    for it in items:
        if len(it) > 1:
            h2.update(hashlib.sha256(it).digest())
    return "0x" + h2.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", required=True)
    ap.add_argument("--beacon-api", help="defaults to the first entry in /etc/bench/blsync.env")
    ap.add_argument("--beacon-header", help="defaults to /etc/bench/blsync.env")
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()

    base, header = args.beacon_api, args.beacon_header
    if not base or not header:
        # env file is 0600 root-owned, so the caller normally passes these in
        try:
            with open("/etc/bench/blsync.env") as f:
                env = dict(
                    line.strip().split("=", 1) for line in f if "=" in line
                )
            base = base or env["BEACON_API"].strip('"').split(",")[0]
            header = header or env["BEACON_HEADER"].strip('"')
        except Exception as e:  # noqa: BLE001
            sys.exit(f"need --beacon-api/--beacon-header (could not read env file: {e})")

    # which cached blocks actually have requests
    want = {}
    for name in os.listdir(args.cache):
        if not name.endswith(".json") or name in ("meta.json", "requests.json"):
            continue
        with open(os.path.join(args.cache, name)) as f:
            b = json.load(f)
        rh = b.get("requestsHash")
        if rh and rh.lower() != EMPTY_REQUESTS_HASH:
            want[int(b["number"], 16)] = rh.lower()

    if not want:
        print("no cached block has requests, writing an empty map")
        with open(os.path.join(args.cache, "requests.json"), "w") as f:
            json.dump({}, f)
        return

    lo, hi = min(want), max(want)
    print(f"{len(want)} of the cached blocks have requests, range {lo}..{hi}")

    # map block numbers to slots. slots and block numbers drift only by the number
    # of empty slots, so interpolate from head and walk a padded range.
    # the blinded endpoint is v1 and does not accept the "head" alias, so resolve
    # the head slot first and then fetch that slot by number
    hd = beacon_get(base, header, "/eth/v1/beacon/headers/head")
    head_slot = int(hd["data"]["header"]["message"]["slot"])
    hb = beacon_get(base, header, f"/eth/v1/beacon/blinded_blocks/{head_slot}")
    head_block = int(hb["data"]["message"]["body"]["execution_payload_header"]["block_number"])
    pad = 64
    slot_lo = head_slot - (head_block - lo) - pad
    slot_hi = head_slot - (head_block - hi) + pad
    print(f"scanning slots {slot_lo}..{slot_hi} ({slot_hi - slot_lo + 1} blinded blocks)")

    found = {}

    def one(slot):
        try:
            d = beacon_get(base, header, f"/eth/v1/beacon/blinded_blocks/{slot}")
        except Exception:  # noqa: BLE001 - missed slots legitimately 404
            return None
        body = d["data"]["message"]["body"]
        num = int(body["execution_payload_header"]["block_number"])
        if num not in want:
            return None
        return num, encode_requests(body.get("execution_requests", {}))

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        for res in pool.map(one, range(slot_lo, slot_hi + 1)):
            if res:
                found[res[0]] = res[1]

    # verify every entry against the header it has to reproduce
    bad = []
    for num, expected in sorted(want.items()):
        items = found.get(num)
        if items is None:
            bad.append(f"  block {num}: no beacon block found in the scanned range")
            continue
        got = calc_requests_hash(items)
        if got != expected:
            bad.append(f"  block {num}: computed {got}, header says {expected}")

    if bad:
        print(f"FAILED verification for {len(bad)} block(s):")
        print("\n".join(bad[:10]))
        sys.exit(1)

    out = {str(k): ["0x" + i.hex() for i in v] for k, v in found.items()}
    with open(os.path.join(args.cache, "requests.json"), "w") as f:
        json.dump(out, f, indent=1)

    total = sum(len(v) for v in found.values())
    print(f"verified all {len(found)} block(s), {total} request item(s)")
    print(f"wrote {os.path.join(args.cache, 'requests.json')}")


if __name__ == "__main__":
    main()
