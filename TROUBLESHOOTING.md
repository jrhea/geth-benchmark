# When a run fails

Failure modes, most of them silent rather than loud. Read this before debugging
anything on the box.

A run that ends in under 20 minutes failed; a healthy one takes about 40. The
journal is the first place to look:

```bash
tsh ssh debian@geth-benchmark-1 'sudo journalctl -u bench -n 30 -o cat'
```

- `eth_syncing` returns `false` during header backfill. The harness reads that as "ready" and benchmarks from a garbage block. Use `scripts/status.sh` or the log.
- `nohup`/`setsid` get killed by Teleport session cleanup. Use systemd. Verify: `systemctl show geth-bench -p Slice` must be `system.slice`.
- The harness needs `reth-bench` on `PATH`. Upstream deleted it, it comes from `jrhea/reth` branch `bench/npv4`.
- Anything else running during a benchmark lands in the results.
- **`systemctl stop` silently no-ops when issued from inside a systemd unit.** The identical command from a shell works instantly. Unexplained. `new-window.sh` escalates to `pkill -TERM` after 30s. Do the same in any new script, and never write an unbounded wait loop.
- **`--history.transactions 0` means the ENTIRE chain, not "off".** N is a count back from the head, so `1` is the minimum. Get it wrong and geth indexes in the background, which inflates block times ~8x with no error.
- **geth's HTTP RPC has a hard 30s write timeout** (`rpc/http.go`, not a flag). A 2000-block `debug_setHead` takes ~45s and returns `-32002 request timed out`, but the rewind still completes. The harness polls the head instead of trusting the response.
- reth-bench panics on an empty block range (`the row has at least one element`), so `--warmup-blocks 0` is handled in the harness by skipping the phase.
- **A reboot leaves the block cache down.** It is enabled at boot, but if it is not running every benchmark aborts within a second and the message carries the fix: `sudo systemctl start blockcache`.
- **`sudo: I'm sorry debian. I'm afraid I can't do that`** means the sudoers rule is gone. `debian` gets permanent sudo from `/etc/sudoers.d/99-bench`; without it Teleport grants it only for the life of a session, and a run detached in a systemd unit loses it partway through. See SETUP.md section 5.
- **`stale token` from the engine API**, ending in a reth-bench panic, is one JWT being reused past geth's 60 second limit. The transport refreshes 15 seconds early; if this recurs, that margin was not enough.
- **A second launch is refused, not queued.** `ABORT: a benchmark is already running`. There is one datadir and one port pair, so two runs would rewind the same chain data underneath each other while both looked healthy.
- **`pgrep`/`pkill` patterns must not match the word `geth` alone.** The scripts live under `/home/debian/geth-benchmark`, so a bare pattern matches them and the block cache server, and kills them. Match `/[g]eth(_[0-9a-f]+)? --datadir`.
- **After `debug_setHead`, restart geth before replaying anything.** In the same
  session the node cannot serve `newPayload` at the new head and reth-bench dies
  immediately with "no canonical state found for parent of requested block".
  `new-window.sh` and the harness both already stop geth after a rewind.

## Why geth is not enabled at boot

A reboot would start geth, blsync would drive it forward, and the pinned head
would silently move, changing the block range out from under every later run.
Leave them disabled unless you want the node following the chain:

```bash
sudo systemctl enable geth-bench blsync-bench
```
