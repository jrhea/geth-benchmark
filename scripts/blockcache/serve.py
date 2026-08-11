#!/usr/bin/env python3
"""
Serve cached blocks over JSON-RPC so reth-bench never touches the network.

  ./serve.py --dir /datadrive/blockcache --port 8600

Then run the harness with --rpc-url http://127.0.0.1:8600

Implements only what the benchmark path actually calls:
  eth_chainId          reth-bench-compare validates this before it starts
  eth_getBlockByNumber the actual block fetch, full transactions
  eth_blockNumber      returns the highest cached block

Blocks are loaded into memory at startup on purpose. The harness runs
drop_caches before each benchmark, so serving from the page cache would put disk
reads on the measurement path. Resident memory removes that.
"""
import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BLOCKS = {}      # number -> raw json bytes
REQUESTS = {}    # str(number) -> list of "0x.." EIP-7685 items
CHAIN_ID = None
HIGHEST = None


def load(cache_dir):
    global CHAIN_ID, HIGHEST, REQUESTS
    meta_path = os.path.join(cache_dir, "meta.json")
    if not os.path.exists(meta_path):
        sys.exit(f"no meta.json in {cache_dir}, run fetch.py first")
    with open(meta_path) as f:
        meta = json.load(f)
    CHAIN_ID = meta["chain_id"]

    for name in os.listdir(cache_dir):
        if not name.endswith(".json") or name in ("meta.json", "requests.json"):
            continue
        num = int(name[:-5])
        with open(os.path.join(cache_dir, name), "rb") as f:
            BLOCKS[num] = f.read()

    rpath = os.path.join(cache_dir, "requests.json")
    if os.path.exists(rpath):
        with open(rpath) as f:
            REQUESTS.update(json.load(f))
        print(f"loaded execution requests for {len(REQUESTS)} block(s)")
    else:
        print("WARNING: no requests.json, blocks with execution requests will fail")

    if not BLOCKS:
        sys.exit(f"no blocks found in {cache_dir}")
    HIGHEST = max(BLOCKS)
    lowest = min(BLOCKS)
    missing = (HIGHEST - lowest + 1) - len(BLOCKS)
    size = sum(len(b) for b in BLOCKS.values())
    print(f"loaded {len(BLOCKS)} blocks {lowest}..{HIGHEST}, {size / 1e9:.2f} GB resident")
    if missing:
        print(f"WARNING: {missing} blocks missing inside that range")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass  # stay quiet, this runs during benchmarks

    def _send(self, payload: bytes, code=200):
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _result(self, req_id, raw_result: bytes):
        head = b'{"jsonrpc":"2.0","id":' + json.dumps(req_id).encode() + b',"result":'
        self._send(head + raw_result + b"}")

    def _error(self, req_id, message):
        self._send(
            json.dumps(
                {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": message}}
            ).encode()
        )

    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        try:
            req = json.loads(self.rfile.read(length))
        except Exception:  # noqa: BLE001
            self._send(b'{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"bad json"}}')
            return

        # batch requests
        if isinstance(req, list):
            parts = [self._one(r) for r in req]
            self._send(b"[" + b",".join(parts) + b"]")
            return

        self._send(self._one(req))

    def _one(self, req) -> bytes:
        rid = json.dumps(req.get("id")).encode()
        method = req.get("method")
        params = req.get("params") or []

        def ok(raw: bytes) -> bytes:
            return b'{"jsonrpc":"2.0","id":' + rid + b',"result":' + raw + b"}"

        if method == "eth_chainId":
            return ok(json.dumps(CHAIN_ID).encode())

        if method == "eth_blockNumber":
            return ok(json.dumps(hex(HIGHEST)).encode())

        if method == "bench_getExecutionRequests":
            # Non-standard, ours. Returns the exact executionRequests argument for
            # engine_newPayloadV4. Requests are not obtainable from the execution
            # layer at all (see fetch_requests.py), so a patched reth-bench asks
            # for them here and passes them straight through.
            num = params[0] if params else None
            try:
                n = int(num, 16) if isinstance(num, str) else int(num)
            except Exception:  # noqa: BLE001
                return ok(b"[]")
            return ok(json.dumps(REQUESTS.get(str(n), [])).encode())

        if method == "eth_getCode":
            # reth-bench calls this once at startup on an OP predeploy address to
            # decide is_optimism (bench/context.rs). Empty code means "not OP",
            # which is right for mainnet. Deliberately only answered for that one
            # address, so if a future reth-bench uses eth_getCode for real data it
            # fails loudly instead of silently seeing an empty account.
            addr = (params[0] if params else "") or ""
            if addr.lower() == "0x420000000000000000000000000000000000000f":
                return ok(b'"0x"')
            return (
                b'{"jsonrpc":"2.0","id":' + rid
                + b',"error":{"code":-32601,"message":"blockcache only answers '
                + b'eth_getCode for the OP predeploy probe, not ' + addr.encode() + b'"}}'
            )

        if method == "eth_getBlockByNumber":
            tag = params[0] if params else None
            if tag in ("latest", "safe", "finalized", "pending"):
                num = HIGHEST
            else:
                try:
                    num = int(tag, 16) if isinstance(tag, str) else int(tag)
                except Exception:  # noqa: BLE001
                    return ok(b"null")
            raw = BLOCKS.get(num)
            return ok(raw if raw is not None else b"null")

        return (
            b'{"jsonrpc":"2.0","id":' + rid
            + b',"error":{"code":-32601,"message":"not served by blockcache: '
            + str(method).encode() + b'"}}'
        )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--port", type=int, default=8600)
    ap.add_argument("--addr", default="127.0.0.1")
    args = ap.parse_args()

    load(args.dir)
    srv = ThreadingHTTPServer((args.addr, args.port), Handler)
    print(f"serving on http://{args.addr}:{args.port}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
