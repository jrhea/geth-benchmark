#!/usr/bin/env bash
#
# Print the label a run gets when it was not given one.
#
#   bash mklabel.sh <feature> <base>
#
#   my-branch master        my-branch-vs-master
#   feature/foo fork-point  feature-foo-vs-fork-point
#
# run.sh, bench.sh and the workflow all call this, so a run started three ways
# lands in the same directory.
set -uo pipefail
FEATURE=${1:?usage: mklabel.sh FEATURE BASE}
BASE=${2:-}

# It becomes a directory name, so drop anything that would need quoting.
clean() {
  printf '%s' "$1" | sed -e 's/[^A-Za-z0-9._-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

# A full commit hash is unreadable at length, and 8 identifies it.
short() {
  case "$1" in
    *[!0-9a-f]*)   printf '%s' "$1" ;;
    ????????????*) printf '%.8s' "$1" ;;
    *)             printf '%s' "$1" ;;
  esac
}

L=$(clean "$(short "$FEATURE")")
[ -n "$BASE" ] && L="$L-vs-$(clean "$(short "$BASE")")"
printf '%s\n' "$L"
