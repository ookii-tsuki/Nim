#!/bin/sh
# N# test runner. Compiles each `.ns` test with an N#-capable compiler.
#
#   * `<name>.ns` with a sibling `<name>.out`  -> stdout must match the `.out`
#   * `<name>.ns` with a sibling `<name>.fail` -> compilation must FAIL
#   * `<name>.ns` with a sibling `<name>.warn` -> compiles and runs as above, and the
#     compilation must also report the diagnostic the marker names
#   * `<name>.ns` with a sibling `<name>.exit` -> runs as above, and must end with
#     the exit status on the marker's first line and the stderr on the rest, its
#     stack-trace lines (`   at ...`) aside: an exception nothing catches
#
# A `.fail`, `.unsupported` or `.warn` marker may name the diagnostic it expects with
# a `code: NSxxxx` line, which the output must then carry.
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

. "$here/par.sh"

run_one() {
  ## One test: prints what the serial loop did, and returns 1 when it failed. It
  ## builds in a directory and a Nim cache of its own, so tests run side by side.
  ns="$1"
  exp="${ns%.ns}.out"
  failmark="${ns%.ns}.fail"
  unsupmark="${ns%.ns}.unsupported"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ns_test.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  bin="$tmp/bin"
  log="$tmp/compile.log"
  cache="$(ns_nimcache "$root" "$ns" "")"

  if [ -f "$failmark" ] || [ -f "$unsupmark" ]; then
    marker="$failmark"
    [ -f "$unsupmark" ] && marker="$unsupmark"
    if "$NIM" c --hints:off --warnings:off --lib:"$lib" --nimcache:"$cache" \
          -o:"$bin" "$ns" > "$log" 2>&1; then
      echo "FAIL (compiled but should not): ${ns#$root/}"
      return 1
    elif want="$(sed -n 's/^code: *//p' "$marker" | head -1)"; [ -n "$want" ] &&
         ! grep -q "$want" "$log"; then
      echo "FAIL (marker names $want): ${ns#$root/}"
      sed -n '1,5p' "$log"
      return 1
    elif [ -f "$unsupmark" ]; then
      echo "ok (rejected; valid C# that N# does not support yet): ${ns#$root/}"
    else
      echo "ok (expected compile error): ${ns#$root/}"
    fi
    return 0
  fi

  if ! "$NIM" c --hints:off --warnings:off --lib:"$lib" --nimcache:"$cache" \
        -o:"$bin" "$ns" > "$log" 2>&1; then
    echo "COMPILE FAIL: ${ns#$root/}"
    cat "$log"
    return 1
  fi
  exitmark="${ns%.ns}.exit"
  if [ -f "$exitmark" ]; then
    ## The shell reports a signal's death on its own stderr, which is not the test's.
    got="$( (sh -c 'exec "$0" 2> "$1"' "$bin" "$tmp/stderr"; echo $? > "$tmp/status") 2> /dev/null )"
    st="$(cat "$tmp/status")"
    err="$(grep -v '^   at ' "$tmp/stderr")"
    if [ "$st" != "$(head -1 "$exitmark")" ] || [ "$err" != "$(tail -n +2 "$exitmark")" ]; then
      echo "FAIL (exit status $st, or stderr, differs from .exit): ${ns#$root/}"
      echo "--- stderr ---"; echo "$err"
      return 1
    fi
  else
    got="$("$bin")"
  fi
  want="$(cat "$exp")"
  if [ "$got" = "$want" ]; then
    echo "ok: ${ns#$root/}"
  else
    echo "FAIL: ${ns#$root/}"
    echo "--- expected ---"; echo "$want"
    echo "--- got ---"; echo "$got"
    return 1
  fi
  # A `.warn` marker pins a diagnostic that must be *reported* and not be fatal, so
  # the compile has to be repeated with warnings on: the run above silences them.
  warnmark="${ns%.ns}.warn"
  [ -f "$warnmark" ] || return 0
  want="$(sed -n 's/^code: *//p' "$warnmark" | head -1)"
  if ! "$NIM" c --hints:off --lib:"$lib" --nimcache:"$cache" -o:"$bin" "$ns" \
        > "$tmp/warn.log" 2>&1; then
    echo "FAIL (warning expected, but the compile failed): ${ns#$root/}"
    sed -n '1,5p' "$tmp/warn.log"
    return 1
  elif [ -n "$want" ] && ! grep -q "$want" "$tmp/warn.log"; then
    echo "FAIL (marker names $want): ${ns#$root/}"
    sed -n '1,5p' "$tmp/warn.log"
    return 1
  fi
  echo "ok (warns $want, and still runs): ${ns#$root/}"
}

if [ "${1:-}" = "--one" ]; then
  run_one "$2"
  exit $?
fi

## The tests: a program with an expectation, or one that must not compile.
tests=""
for ns in "$here"/*/*.ns "$here"/modules/*/*.ns; do
  [ -f "$ns" ] || continue
  [ -f "${ns%.ns}.fail" ] || [ -f "${ns%.ns}.unsupported" ] || [ -f "${ns%.ns}.out" ] || continue
  tests="$tests $ns"
  count=$((count + 1))
done
# shellcheck disable=SC2086
ns_par_each "${TMPDIR:-/tmp}/ns_test_results" $tests || fail=1

# Parser golden-AST check: pins the parse output so the parser refactor is
# verifiable. Set NS_SKIP_AST=1 to skip.
if [ -z "${NS_SKIP_AST:-}" ] && [ -x "$here/run_ast.sh" ]; then
  echo "--- AST golden check ---"
  "$here/run_ast.sh" || fail=1
fi

# C#<->N# equivalence gate: recompile every test as C# and require the .NET
# compiler's output to match the same `.out`. Set NS_SKIP_CS=1 to skip.
if [ -z "${NS_SKIP_CS:-}" ] && [ -x "$here/run_cs.sh" ]; then
  echo "--- C# cross-check ---"
  "$here/run_cs.sh" || fail=1
fi

# Semantic conformance gate (Stage 0b): the facts the frontend resolved must equal
# the facts Roslyn resolves for the same file. Skips cleanly without `dotnet`.
# Set NS_SKIP_SEMA=1 to skip.
if [ -z "${NS_SKIP_SEMA:-}" ] && [ -x "$here/run_sema.sh" ]; then
  echo "--- semantic conformance ---"
  "$here/run_sema.sh" || fail=1
fi

# Declaration-order gate: every test again with its declarations reversed, since
# C# lets types and members come in any order. Set NS_SKIP_REORDER=1 to skip.
if [ -z "${NS_SKIP_REORDER:-}" ] && [ -x "$here/run_reorder.sh" ]; then
  echo "--- declaration order ---"
  NIM="$NIM" "$here/run_reorder.sh" > /tmp/ns_reorder.log 2>&1 || fail=1
  grep -v '^ok' /tmp/ns_reorder.log
fi

# C++ interop gate: N# programs driven by C++, through native bindings. Set
# NS_SKIP_NATIVE=1 to skip.
if [ -z "${NS_SKIP_NATIVE:-}" ] && [ -x "$here/run_native.sh" ]; then
  echo "--- native interop ---"
  NIM="$NIM" "$here/run_native.sh" || fail=1
fi

# Diagnostics gate: wrong programs must keep reporting Roslyn's error codes.
# Set NS_SKIP_DIAG=1 to skip.
if [ -z "${NS_SKIP_DIAG:-}" ] && [ -x "$here/run_diag.sh" ]; then
  echo "--- diagnostics ---"
  NIM1="$NIM" "$here/run_diag.sh" || fail=1
fi

echo "ran $count test(s)"
exit $fail

