#!/usr/bin/env bash
#
# Turn a ref into a commit, fetching it from the repo that owns it.
#
#   bash resolve-ref.sh master                          upstream go-ethereum
#   bash resolve-ref.sh rjl493456442:optimize-commit    a ref in someone's fork
#   bash resolve-ref.sh jrhea:my-branch                 a ref in ours
#
# No owner means upstream, so master and tags always mean the canonical ones. A
# branch of your own needs naming, since upstream does not have it.
#
# The owner has to be listed in forks.txt. Whatever the ref names gets built and
# run here, so that file is the trust boundary, not this script's parsing.
#
# Branches, tags and commits all resolve, though a commit has to still be
# reachable from a ref there, which one orphaned by a force push is not.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${GETH_REPO:-/home/debian/go-ethereum}"
LIST="${FORKS:-$HERE/../forks.txt}"
SPEC="${1:?usage: resolve-ref.sh [owner:]ref}"
# A pasted ref often carries whitespace, and no git ref may contain any.
SPEC=$(printf '%s' "$SPEC" | tr -d '[:space:]')

case "$SPEC" in
  *:*) OWNER=${SPEC%%:*}; REF=${SPEC#*:} ;;
  *)   OWNER=ethereum;    REF=$SPEC ;;
esac

# A full hash we already have is that commit, whoever owns it, so there is
# nothing to fetch. This is the fork point's path, which arrives as a hash.
case "$REF" in
  *[!0-9a-f]*) ;;
  ????????????????????????????????????????)
    git -C "$REPO" rev-parse --verify -q "$REF^{commit}" && exit 0 ;;
esac

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
