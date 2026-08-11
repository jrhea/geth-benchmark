#!/usr/bin/env bash
# Full bench-harness setup on a fresh box. Runs as debian, sudo for /usr/local.
# apt packages and /usr/local/go are already present system-wide.
#
# Run it from a clone of this repo, which holds reth and reth-bench-compare as
# submodules so their versions are pinned rather than whatever the branch tip
# happens to be:
#
#   git clone https://github.com/jrhea/geth-benchmark.git ~/geth-benchmark
#   bash ~/geth-benchmark/scripts/setup-debian.sh
set -uo pipefail

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

export CARGO_TERM_COLOR=never
# the repo root, so the submodules are found whatever directory this is run from
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# ---------- PATH, written generically so any user works ----------
log "=== profile.d ==="
sudo tee /etc/profile.d/bench-toolchain.sh >/dev/null <<'EOF'
export PATH="/usr/local/go/bin:$HOME/.cargo/bin:/usr/local/bin:$PATH"
export GOPATH="$HOME/go"
EOF
sudo chmod +x /etc/profile.d/bench-toolchain.sh
# tsh ssh runs non-login shells, so .bashrc needs it too
grep -q 'bench-toolchain' "$HOME/.bashrc" 2>/dev/null \
  || echo '. /etc/profile.d/bench-toolchain.sh' >> "$HOME/.bashrc"

export PATH="/usr/local/go/bin:$HOME/.cargo/bin:/usr/local/bin:$PATH"
export GOPATH="$HOME/go"

# ---------- Rust ----------
if ! command -v cargo >/dev/null 2>&1; then
  log "=== rustup ==="
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path
  export PATH="$HOME/.cargo/bin:$PATH"
fi
log "rust: $(rustc --version), cargo: $(cargo --version)"

# ---------- go-ethereum ----------
log "=== go-ethereum ==="
if [ ! -d "$HOME/go-ethereum/.git" ]; then
  git clone -q https://github.com/jrhea/go-ethereum.git "$HOME/go-ethereum"
fi
cd "$HOME/go-ethereum"
git remote get-url upstream >/dev/null 2>&1 \
  || git remote add upstream https://github.com/ethereum/go-ethereum.git
git fetch -q origin --tags
git fetch -q upstream --tags
log "remote refs: $(git branch -r | wc -l)"
if make geth > "$HOME/build-geth.log" 2>&1; then
  log "geth OK: $($HOME/go-ethereum/build/bin/geth version | awk '/^Version:/{print $2}')"
else
  log "GETH BUILD FAILED"; tail -20 "$HOME/build-geth.log"
fi

# ---------- rust builds, concurrent ----------
log "=== fetching the pinned reth and reth-bench-compare ==="
git -C "$REPO" submodule update --init --recursive --depth 1 \
  || { log "SUBMODULE FETCH FAILED"; exit 1; }
log "reth HEAD:  $(git -C "$REPO/reth" rev-parse --short HEAD)"
log "rbc  HEAD:  $(git -C "$REPO/reth-bench-compare" rev-parse --short HEAD)"

log "=== building reth-bench + reth-bench-compare concurrently ==="
(
  cd "$REPO/reth" && cargo build --release -p reth-bench -j 48 \
    > "$HOME/build-reth-bench.log" 2>&1
  echo $? > "$HOME/.rc-rb"
) &
(
  cd "$REPO/reth-bench-compare" && cargo build --release -j 48 \
    > "$HOME/build-rbc.log" 2>&1
  echo $? > "$HOME/.rc-rbc"
) &
wait

RC_RB=$(cat "$HOME/.rc-rb" 2>/dev/null || echo 1)
RC_RBC=$(cat "$HOME/.rc-rbc" 2>/dev/null || echo 1)

if [ "$RC_RB" = "0" ]; then
  sudo install -m 0755 "$REPO/reth/target/release/reth-bench" /usr/local/bin/reth-bench
  log "reth-bench installed ($(reth-bench --help 2>&1 | grep -c new-payload-fcu) fcu subcmd found)"
else
  log "RETH-BENCH FAILED (rc=$RC_RB)"; tail -25 "$HOME/build-reth-bench.log"
fi

if [ "$RC_RBC" = "0" ]; then
  sudo install -m 0755 "$REPO/reth-bench-compare/target/release/reth-bench-compare" \
    /usr/local/bin/reth-bench-compare
  log "reth-bench-compare installed: $(reth-bench-compare --version 2>&1 | head -1)"
else
  log "RBC FAILED (rc=$RC_RBC)"; tail -25 "$HOME/build-rbc.log"
fi

rm -f "$HOME/.rc-rb" "$HOME/.rc-rbc"
log "SETUP_DONE rc_reth_bench=$RC_RB rc_rbc=$RC_RBC"
