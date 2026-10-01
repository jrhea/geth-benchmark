#!/usr/bin/env bash
#
# Profile each measured pass on its own, by following the harness's output.
#
#   reth-bench-compare ... 2>&1 | tee >(bash profile-watch.sh)
#
# Reads the harness log on stdin. When a measured pass starts, it asks that pass's
# geth for a CPU profile over RPC, written into the pass's own output directory,
# and stops it when the pass ends. So each profile covers the block replay and
# nothing else: not node startup, the readiness wait or the rewind afterwards. The
# warmup is left alone.
set -uo pipefail
RPC="${RPC:-http://127.0.0.1:8545}"
log() { echo "[$(date -u +%H:%M:%S)] profile: $*"; }
call() {
  curl -s --max-time 30 -X POST -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":[$2]}" "$RPC"
}
# A few tries, since a lost call is a lost pass. Prints the last answer.
try() {
  local out i
  for i in 1 2 3; do
    out=$(call "$@")
    case "$out" in *'"error"'*|"") sleep 0.2 ;; *) printf '%s' "$out"; return 0 ;; esac
  done
  printf '%s' "${out:-no answer}"
  return 1
}

cur= curdir=
while IFS= read -r line; do
  case "$line" in
    *"Running benchmark from block"*"(output: "*)
      # the harness names the pass directory, results/<ts>/baseline for one run
      # and results/<ts>/run2/feature for several
      dir=$(printf '%s' "$line" | sed -n 's/.*(output: "\(.*\)").*/\1/p')
      [ -n "$dir" ] || continue
      pass=${dir#*/results/*/}
      # it does not exist until the pass writes its results
      mkdir -p "$dir"
      if out=$(try debug_startCPUProfile "\"$dir/cpu.pprof\""); then
        log "started $pass"; cur=$pass curdir=$dir
      else
        log "could not start one for $pass: $out"
      fi
      ;;
    *"Benchmark completed"*)
      [ -n "$cur" ] || continue
      if out=$(try debug_stopCPUProfile ""); then
        log "stopped $cur"
      else
        # geth stops a running profile when it exits, so this one would still be
        # written, but covering the rewind too. Drop it rather than let it pass as
        # a clean one.
        rm -f "$curdir/cpu.pprof"
        log "could not stop the one for $cur, dropped it: $out"
      fi
      cur= curdir=
      ;;
  esac
done
