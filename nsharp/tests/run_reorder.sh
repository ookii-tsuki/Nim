#!/bin/sh
# Declaration-order gate: C# lets a program declare its types and members in any
# order, so every `.ns` test with a `.out` is compiled again with its declarations
# reversed (`-d:nsReverseDecls`: the types of each module and namespace, and the
# methods, constructors and operators of each class) and must print the same.
# Fields, properties, enum members and statements keep their order; C# makes
# theirs observable.
#
# Usage:  NIM=/path/to/nim ./nsharp/tests/run_reorder.sh

set -u
NIM="${NIM:-nim}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
lib="$root/lib"
. "$here/par.sh"

run_one() {
  ## One test, compiled with its declarations reversed in a directory and a Nim
  ## cache of its own; returns 1 when it failed.
  ns="$1"
  exp="${ns%.ns}.out"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ns_reorder.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  if ! "$NIM" c --hints:off --warnings:off --lib:"$lib" -d:nsReverseDecls \
        --nimcache:"$(ns_nimcache "$root" "$ns" _rev)" -o:"$tmp/bin" "$ns" \
        > "$tmp/compile.log" 2>&1; then
    echo "REORDER COMPILE FAIL: ${ns#$root/}"
    grep -m3 "Error" "$tmp/compile.log"
    return 1
  fi
  ## An exception nothing catches (a `.exit` marker) reports on stderr, which
  ## `run.sh` checks; only the output is compared here.
  if [ "$( (sh -c 'exec "$0" 2> /dev/null' "$tmp/bin"; true) 2> /dev/null )" = "$(cat "$exp")" ]; then
    echo "ok (reversed): ${ns#$root/}"
  else
    echo "REORDER DIFF: ${ns#$root/}"
    "$tmp/bin" | diff - "$exp" | head -10
    return 1
  fi
}

if [ "${1:-}" = "--one" ]; then
  run_one "$2"
  exit $?
fi

fail=0
count=0
tests=""
for ns in "$here"/*/*.ns "$here"/modules/*/*.ns; do
  [ -f "$ns" ] || continue
  [ -f "${ns%.ns}.out" ] || continue
  tests="$tests $ns"
  count=$((count + 1))
done
# shellcheck disable=SC2086
ns_par_each "${TMPDIR:-/tmp}/ns_reorder_results" $tests || fail=1
echo "reordered $count test(s)"
exit $fail
