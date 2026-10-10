#!/bin/sh
# N# test runner. Compiles each `.ns` test with an N#-capable compiler.
#
#   * `<name>.ns` with a sibling `<name>.out`  -> stdout must match the `.out`
#   * `<name>.ns` with a sibling `<name>.fail` -> compilation must FAIL
#   * `<name>.ns` with a sibling `<name>.warn` -> compiles and runs as above, and the
#     compilation must also report the diagnostic the marker names
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

for ns in "$here"/*.ns "$here"/*/*.ns; do
  [ -f "$ns" ] || continue
  exp="${ns%.ns}.out"
  failmark="${ns%.ns}.fail"
  unsupmark="${ns%.ns}.unsupported"
  bin="/tmp/ns_test_$$"

  if [ -f "$failmark" ] || [ -f "$unsupmark" ]; then
    count=$((count + 1))
    marker="$failmark"
    [ -f "$unsupmark" ] && marker="$unsupmark"
    if "$NIM" c --hints:off --warnings:off --lib:"$lib" -o:"$bin" "$ns" \
          > /tmp/ns_test_compile.log 2>&1; then
      echo "FAIL (compiled but should not): ${ns#$root/}"
      fail=1
    elif want="$(sed -n 's/^code: *//p' "$marker" | head -1)"; [ -n "$want" ] &&
         ! grep -q "$want" /tmp/ns_test_compile.log; then
      echo "FAIL (marker names $want): ${ns#$root/}"
      sed -n '1,5p' /tmp/ns_test_compile.log
      fail=1
    elif [ -f "$unsupmark" ]; then
      echo "ok (rejected; valid C# that N# does not support yet): ${ns#$root/}"
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
    continue
  fi
  # A `.warn` marker pins a diagnostic that must be *reported* and not be fatal, so
  # the compile has to be repeated with warnings on: the run above silences them.
  warnmark="${ns%.ns}.warn"
  [ -f "$warnmark" ] || continue
  want="$(sed -n 's/^code: *//p' "$warnmark" | head -1)"
  if ! "$NIM" c --hints:off --lib:"$lib" -o:"$bin" "$ns" \
        > /tmp/ns_test_warn.log 2>&1; then
    echo "FAIL (warning expected, but the compile failed): ${ns#$root/}"
    sed -n '1,5p' /tmp/ns_test_warn.log
    fail=1
  elif [ -n "$want" ] && ! grep -q "$want" /tmp/ns_test_warn.log; then
    echo "FAIL (marker names $want): ${ns#$root/}"
    sed -n '1,5p' /tmp/ns_test_warn.log
    fail=1
  else
    echo "ok (warns $want, and still runs): ${ns#$root/}"
  fi
done

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

# Diagnostics gate: wrong programs must keep reporting Roslyn's error codes.
# Set NS_SKIP_DIAG=1 to skip.
if [ -z "${NS_SKIP_DIAG:-}" ] && [ -x "$here/run_diag.sh" ]; then
  echo "--- diagnostics ---"
  NIM1="$NIM" "$here/run_diag.sh" || fail=1
fi

echo "ran $count test(s)"
exit $fail

