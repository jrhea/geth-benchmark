#!/usr/bin/env bash
#
# Print where a ref diverged from master, and how far master has moved since.
#
#   bash fork-point.sh my-branch
#   bash fork-point.sh rjl493456442:optimize-commit
#
# Prints "<fork point> <ref's commit> <commits master is ahead>".
#
# Always upstream's master, whoever the ref belongs to. A fork's own master is
# usually an abandoned snapshot that the branch descends from, so the merge base
# comes back as that snapshot rather than where the branch actually diverged.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${GETH_REPO:-/home/debian/go-ethereum}"
SPEC="${1:?usage: fork-point.sh [owner:]ref}"
MASTER=ethereum:master

F=$(bash "$HERE/resolve-ref.sh" "$SPEC") || exit 1
M=$(bash "$HERE/resolve-ref.sh" "$MASTER") || exit 1
MB=$(git -C "$REPO" merge-base "$M" "$F") || {
  echo "no common ancestor between $MASTER and $SPEC" >&2; exit 1; }
echo "$MB $F $(git -C "$REPO" rev-list --count "$MB..$M")"
