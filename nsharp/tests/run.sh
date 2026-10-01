#!/bin/sh
# N# test runner. Compiles each `.ns` test with an N#-capable compiler.
#
#   * `<name>.ns` with a sibling `<name>.out`  -> stdout must match the `.out`
#   * `<name>.ns` with a sibling `<name>.fail` -> compilation must FAIL
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
  failmark="${ns%.ns}.fail"
  bin="/tmp/ns_test_$$"

  if [ -f "$failmark" ]; then
    count=$((count + 1))
    if "$NIM" c --hints:off --warnings:off --lib:"$lib" -o:"$bin" "$ns" \
          > /tmp/ns_test_compile.log 2>&1; then
      echo "FAIL (compiled but should not): ${ns#$root/}"
      fail=1
    else
      echo "ok (expected compile error): ${ns#$root/}"
    fi
    continue
  fi

  [ -f "$exp" ] || continue
  count=$((count + 1))
  if ! "$NIM" c --hints:off --warnings:off --lib:"$lib" -o:"$bin" "$ns" \
        > /tmp/ns_test_compile.log 2>&1; then
    echo "COMPILE FAIL: ${ns#$root/}"
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

# C#<->N# equivalence gate: recompile every test as C# and require the .NET
# compiler's output to match the same `.out`. Set NS_SKIP_CS=1 to skip.
if [ -z "${NS_SKIP_CS:-}" ] && [ -x "$here/run_cs.sh" ]; then
  echo "--- C# cross-check ---"
  "$here/run_cs.sh" || fail=1
fi

echo "ran $count test(s)"
exit $fail

