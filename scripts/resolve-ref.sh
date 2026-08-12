#!/usr/bin/env bash
#
# Turn a ref into a commit, fetching from a fork when one is named.
#
#   bash resolve-ref.sh my-branch                       a ref in jrhea/go-ethereum
#   bash resolve-ref.sh rjl493456442:optimize-commit    a ref in someone's fork
#
# A fork owner has to be listed in forks.txt. Whatever the ref names gets built
# and run here, so that file is the trust boundary, not this script's parsing.
#
# A fork resolves branches, tags and commits, though a commit has to still be
# reachable from a ref there, which one orphaned by a force push is not.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${GETH_REPO:-/home/debian/go-ethereum}"
LIST="${FORKS:-$HERE/../forks.txt}"
SPEC="${1:?usage: resolve-ref.sh [owner:]ref}"

case "$SPEC" in
  *:*) OWNER=${SPEC%%:*}; REF=${SPEC#*:} ;;
  *)   OWNER=; REF=$SPEC ;;
esac

# No owner, so it is one of ours. Prefer the remote, since a local branch of the
# same name can be left over from an earlier run.
if [ -z "$OWNER" ]; then
  git -C "$REPO" rev-parse --verify -q "origin/$REF^{commit}" ||
    git -C "$REPO" rev-parse --verify -q "$REF^{commit}" || {
      echo "cannot resolve $REF in $REPO" >&2; exit 1; }
  exit 0
fi

[ -r "$LIST" ] || { echo "no fork list at $LIST" >&2; exit 1; }
if ! sed -e 's/#.*//' -e 's/[[:space:]]//g' "$LIST" | grep -qixF "$OWNER"; then
  echo "$OWNER is not in $(basename "$LIST"), so its refs cannot be benchmarked" >&2
  echo "add it there in a PR if that is what you want" >&2
  exit 1
fi

# Keep it under a ref of its own rather than reading FETCH_HEAD, which the next
# fetch overwrites and can leave the commit unreachable.
URL="https://github.com/$OWNER/go-ethereum.git"
DEST="refs/forks/$OWNER/$REF"
git -C "$REPO" fetch -q --no-tags "$URL" "+$REF:$DEST" || {
  echo "cannot fetch $REF from $URL" >&2; exit 1; }
git -C "$REPO" rev-parse --verify "$DEST^{commit}"
