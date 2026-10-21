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

. "$here/par.sh"

if ! command -v g++ >/dev/null 2>&1 && ! command -v clang++ >/dev/null 2>&1; then
  echo "skip: no C++ compiler on PATH"
  exit 0
fi

asan="${NS_NATIVE_ASAN--fsanitize=address}"   # NS_NATIVE_ASAN= turns it off

run_one() {
  ## One test, built in a directory and a Nim cache of its own; returns 1 on failure.
  ns="$1"
  cpp="${ns%.ns}.cpp"
  exp="${ns%.ns}.nout"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ns_native.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  bin="$tmp/bin"
  ## `<name>.flags`, when present, replaces the default allocator flag.
  flags="-d:useMalloc"
  [ -f "${ns%.ns}.flags" ] && flags="$(cat "${ns%.ns}.flags")"
  ## AddressSanitizer (over malloc, so it sees Nim's heap too) turns a reference
  ## count C++ got wrong -- a field freed twice, or never -- into a failure.
  # shellcheck disable=SC2086
  if ! "$NIM" cpp --noMain --exceptions:goto --hints:off --warnings:off --lib:"$lib" \
        $flags --passC:"-std=c++20 -I$dir/toybox $asan" --passL:"$asan" \
        --nimcache:"$(ns_nimcache "$root" "$ns" _cpp)" \
        --compile:"$cpp" -o:"$bin" "$ns" \
        > "$tmp/compile.log" 2>&1; then
    echo "COMPILE FAIL: ${ns#$root/}"
    grep -E "Error|error:" "$tmp/compile.log" | head -10
    return 1
  fi
  got="$("$bin" 2>"$tmp/err.log")" || {
    echo "FAIL (exit status): ${ns#$root/}"; head -20 "$tmp/err.log"; return 1; }
  want="$(cat "$exp")"
  if [ "$got" = "$want" ]; then
    echo "ok: ${ns#$root/}"
  else
    echo "FAIL: ${ns#$root/}"
    echo "--- expected ---"; echo "$want"
    echo "--- got ---"; echo "$got"
    return 1
  fi
}

if [ "${1:-}" = "--one" ]; then
  run_one "$2"
  exit $?
fi

tests=""
for ns in "$dir"/*.ns; do
  [ -f "$ns" ] || continue
  [ -f "${ns%.ns}.cpp" ] && [ -f "${ns%.ns}.nout" ] || continue
  tests="$tests $ns"
  count=$((count + 1))
done
# shellcheck disable=SC2086
ns_par_each "${TMPDIR:-/tmp}/ns_native_results" $tests || fail=1

echo "native: ran $count test(s)"
exit $fail
