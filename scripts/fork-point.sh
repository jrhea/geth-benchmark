#!/usr/bin/env bash
#
# Print where a ref diverged from master, and how far master has moved since.
#
#   bash fork-point.sh my-branch
#   bash fork-point.sh rjl493456442:optimize-commit
#
# Prints "<fork point> <ref's commit> <commits master is ahead>".
#
# master comes from the same repo as the ref, so a branch in someone's fork is
# measured against their master. Against ours it would land earlier than the real
# fork point whenever their branch sits on commits our mirror has not got, which
# quietly puts upstream changes the author never wrote into the comparison.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${GETH_REPO:-/home/debian/go-ethereum}"
SPEC="${1:?usage: fork-point.sh [owner:]ref}"

case "$SPEC" in
  *:*) MASTER="${SPEC%%:*}:master" ;;
  *)   MASTER=master ;;
esac

F=$(bash "$HERE/resolve-ref.sh" "$SPEC") || exit 1
M=$(bash "$HERE/resolve-ref.sh" "$MASTER") || exit 1
MB=$(git -C "$REPO" merge-base "$M" "$F") || {
  echo "no common ancestor between $MASTER and $SPEC" >&2; exit 1; }
echo "$MB $F $(git -C "$REPO" rev-list --count "$MB..$M")"
