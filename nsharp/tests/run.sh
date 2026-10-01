#!/bin/sh
# N# test runner. Compiles each `.ns` test with an N#-capable compiler and
# diffs stdout against the matching `.out` file.
#
# Usage:  NIM=/path/to/nim ./nsharp/tests/run.sh
# Build an N#-capable compiler first (see nsharp/ARCHITECTURE.md section 3.1).

set -u
NIM="${NIM:-nim}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
lib="$root/lib"
fail=0
count=0

for ns in "$here"/*.ns "$here"/*/*.ns; do
  [ -f "$ns" ] || continue
  exp="${ns%.ns}.out"
  [ -f "$exp" ] || continue
  count=$((count + 1))
  bin="/tmp/ns_test_$$"
  if ! "$NIM" c --hints:off --warnings:off --lib:"$lib" -o:"$bin" "$ns" \
        > /tmp/ns_test_compile.log 2>&1; then
    echo "COMPILE FAIL: $ns"
    cat /tmp/ns_test_compile.log
    fail=1
    continue
  fi
  got="$("$bin")"
  want="$(cat "$exp")"
  if [ "$got" = "$want" ]; then
    echo "ok: ${ns#$root/}"
  else
    echo "FAIL: ${ns#$root/}"
    echo "--- expected ---"; echo "$want"
    echo "--- got ---"; echo "$got"
    fail=1
  fi
done

echo "ran $count test(s)"
exit $fail
