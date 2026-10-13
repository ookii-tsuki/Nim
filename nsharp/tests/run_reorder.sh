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
work="${TMPDIR:-/tmp}/ns_reorder"
mkdir -p "$work"
bin="$work/test_$$"
log="$work/compile.log"
fail=0
count=0

for ns in "$here"/*.ns "$here"/*/*.ns; do
  [ -f "$ns" ] || continue
  exp="${ns%.ns}.out"
  [ -f "$exp" ] || continue
  count=$((count + 1))
  if ! "$NIM" c --hints:off --warnings:off --lib:"$lib" -d:nsReverseDecls \
        -o:"$bin" "$ns" > "$log" 2>&1; then
    echo "REORDER COMPILE FAIL: ${ns#$root/}"
    grep -m3 "Error" "$log"
    fail=1
    continue
  fi
  if [ "$("$bin")" = "$(cat "$exp")" ]; then
    echo "ok (reversed): ${ns#$root/}"
  else
    echo "REORDER DIFF: ${ns#$root/}"
    "$bin" | diff - "$exp" | head -10
    fail=1
  fi
done
rm -f "$bin"
echo "reordered $count test(s)"
exit $fail
