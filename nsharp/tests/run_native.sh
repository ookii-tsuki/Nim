#!/bin/sh
# N# <-> C++ interop gate.
#
# Each `native/<name>.ns` with a `<name>.cpp` beside it is an N# program driven by
# C++: it is compiled with the C++ backend (goto exceptions, no Nim `main`), the
# `.cpp` linked in, and its stdout compared with `<name>.nout`. The bindings it
# uses are `.ns` files beside it (`Toybox.ns`), over the header-only test engine in
# `native/toybox/`.
#
# Usage:  NIM=/path/to/nim1 ./nsharp/tests/run_native.sh
# Skips cleanly when no C++20 compiler is on PATH.

set -u
NIM="${NIM:-nim}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
lib="$root/lib"
dir="$here/native"
fail=0
count=0

if ! command -v g++ >/dev/null 2>&1 && ! command -v clang++ >/dev/null 2>&1; then
  echo "skip: no C++ compiler on PATH"
  exit 0
fi

for ns in "$dir"/*.ns; do
  [ -f "$ns" ] || continue
  cpp="${ns%.ns}.cpp"
  exp="${ns%.ns}.nout"
  [ -f "$cpp" ] && [ -f "$exp" ] || continue
  count=$((count + 1))
  bin="/tmp/ns_native_$$"
  if ! "$NIM" cpp --noMain --exceptions:goto --hints:off --warnings:off --lib:"$lib" \
        --passC:"-std=c++20 -I$dir/toybox" --compile:"$cpp" -o:"$bin" "$ns" \
        > /tmp/ns_native_compile.log 2>&1; then
    echo "COMPILE FAIL: ${ns#$root/}"
    grep -E "Error|error:" /tmp/ns_native_compile.log | head -10
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
  rm -f "$bin"
done

echo "native: ran $count test(s)"
exit $fail
