# How the benchmark works

Three programs and three endpoints. The endpoints are the confusing part, so
they come first.

## The three endpoints

All three are on this box. Nothing reaches the network during a run.

```
              ┌──────────────────────────────────────────┐
              │  BLOCK CACHE  (--rpc-url, port 8600)     │
              │  scripts/blockcache/serve.py             │
              │  our own server, blocks held in memory   │
              │    eth_getBlockByNumber  block + txs     │
              │    bench_getExecutionRequests  our own   │
              │    eth_chainId, eth_blockNumber          │
              └──────────────────┬───────────────────────┘
                                 │
                                 │ "give me block N"
                                 ▼
       ┌────────────────────┐             ┌──────────────────────────┐
       │ reth-bench-compare │────────────▶│       reth-bench         │
       │  (the orchestrator)│  runs it    │  (the load generator)    │
       └─────────┬──────────┘             └────────────┬─────────────┘
                 │                                     │
                 │ localhost:8545                      │ localhost:8551
                 │ eth_syncing                         │ engine_newPayloadVN
                 │ eth_blockNumber                     │ engine_forkchoiceUpdatedVN
                 │ debug_setHead                       │ (JWT authenticated)
                 ▼                                     ▼
              ┌─────────────────────────────────────────────┐
              │       geth  (the thing being measured)      │
              │       datadir /datadrive/geth               │
              └─────────────────────────────────────────────┘
```

| endpoint | who calls it | what it is |
|---|---|---|
| `--rpc-url`, port 8600 | reth-bench | Our block cache. Serves the replay blocks from memory, plus the execution requests that go with them. Not measured. |
| `localhost:8551` | reth-bench | The engine API of the geth being tested. Where blocks get pushed in. This is what gets timed. |
| `localhost:8545` | reth-bench-compare | The normal JSON-RPC of the geth being tested. Used for `eth_syncing`, `eth_blockNumber`, and `debug_setHead`. |

## The block cache

reth-bench needs a source of blocks it can replay. `--rpc-url` points at
`scripts/blockcache/serve.py` on this box rather than at a real node.

**Why the node under test cannot be the source:** it is pinned at block T, and the
blocks being replayed are T+1 onward. It does not have them. That is the whole
point. reth-bench is pretending to be a consensus client feeding geth work it has
never seen.

**Why not a remote endpoint:** every block is fetched once per pass, on the warmup
and on both refs, every run, which is seven fetches of the whole window for a
`--runs 3` comparison. Fetch it once with `new-window.sh` and serve it from
memory instead. That also keeps the network off the measurement path entirely and
means the harness's `drop_caches` cannot turn a block fetch into a disk read.

What it answers:

| method | for |
|---|---|
| `eth_getBlockByNumber` | the block and all its transactions, everything needed to rebuild it as an engine API payload. reth-bench also asks for `N-32` and `N-64` to fill in the safe and finalized hashes in the forkchoice message. |
| `bench_getExecutionRequests` | not a real Ethereum method. See below. |
| `eth_chainId`, `eth_blockNumber` | the harness validates these before it starts. |
| `eth_getCode` | reth-bench probes an OP predeploy address to decide whether it is talking to an Optimism node. The cache answers empty for that one address and errors on anything else. |

## Execution requests, and why we invented an endpoint

EIP-7685 requests (deposits, withdrawals, consolidations) cannot be recovered from
the execution layer. geth derives them while executing a block and keeps only the
`requestsHash`. No `eth_` method returns them.

Without them reth-bench sends an empty list, geth hashes nothing, and every block
that carried requests is rejected for a blockhash mismatch. Roughly 5% of
post-Prague mainnet blocks carry them, so a run dies within a few blocks.

They do exist in the beacon chain. `scripts/blockcache/fetch_requests.py` reads
them from blinded beacon blocks when the window is built, encodes them, and checks
each one against the execution block's own `requestsHash` before writing them to
disk. The cache then serves them as `bench_getExecutionRequests`, and our
reth-bench fork asks for them and passes them through to `newPayloadV4`.

## The three programs

**geth** is the thing being measured. Started with `--nodiscover --maxpeers 0` so
it cannot get blocks from the p2p network. Everything it learns arrives over the
engine API.

**reth-bench** is the load generator. Fetch a block from the cache, convert
it to an execution payload, send `engine_newPayloadVN` then
`engine_forkchoiceUpdatedVN` to geth, record how long each call took. It only
speaks engine API, which is why it works against geth despite living in the reth
repo. Its engine endpoint defaults to `http://localhost:8551`, and the harness
does not override it.

**reth-bench-compare** is the orchestrator. It does the git and process work
around reth-bench: check out a ref, build it, start it, benchmark it, rewind it,
repeat for the other ref, then diff the two.

## One A/B run, step by step

For each of the two refs (baseline, then feature):

1. `git checkout <ref>` in the go-ethereum working directory.
2. `make geth`. Binaries are cached by commit, so a repeat run skips this.
3. Start geth on the datadir.
4. Poll `eth_syncing` on 8545 until the node says it is ready, then read
   `eth_blockNumber` to get the head. Call it `T`.
5. Benchmark range is `T` to `T + --blocks`.
6. Warmup run of reth-bench over the first slice of that range, results thrown
   away.
7. Real run: reth-bench walks the range, timing every `newPayload` and
   `forkchoiceUpdated`, writing per-block latencies to CSV.
8. `debug_setHead(T)` to rewind geth back to where it started.
9. Stop geth.

Then it compares the two CSVs and writes `comparison_report.json`.

**That file describes the final run only.** `--runs N` loops the whole sequence
above, and the harness's comparison generator is called once at the end with
whatever the last run left in it. Its numbers are also means with no percentiles.
`report.py` ignores it and works from the per-block CSVs, which is where the
per-run spread comes from.

Because step 8 puts the head back, both refs execute the **identical** blocks
against the **identical** starting state. That is what makes the comparison mean
anything.

## What gets measured

- `newPayload` latency, which is block execution plus state root computation
- `forkchoiceUpdated` latency, which is the head update and commit
- gas per second and blocks per second derived from those

Not measured: p2p, consensus, block building, or the block fetch.

## Two consequences worth remembering

**The datadir head decides the block range.** Step 4 reads the head and step 5
derives the range from it. Pin the datadir and every run forever uses the same
blocks. Let geth follow the chain and every run uses different blocks, so results
from different days are not comparable.

**`eth_syncing` is checked in step 4 and it lies.** During beacon header backfill
geth reports `false`, the harness accepts that as ready, and you get numbers
measured from a meaningless starting block. Only run this against a node you have
confirmed is fully synced.
