#!/bin/sh
# Metamorphic gate. A test is rewritten in ways that cannot change its meaning --
# `x` to `this.x`, `=> e` to `{ return e; }` and back, `var` to the explicit type
# and back, extra parentheses, fully qualified type names (tools/nsoracle/Mutate.cs)
# -- and N# must print what it printed for the original.
#
# Roslyn is the judge of the mutants: the oracle writes a mutant only after it has
# compiled it and run it and seen the expected output, so a mutant is valid C# with
# a known result. A mutant N# gets wrong is therefore a bug in N#; one the oracle
# cannot verify is a bug in the mutator and always fails the gate.
#
# `mutate/known.txt` records the failures that are known (`<test> <mutation> <kind>`),
# as `diag/baseline.txt` does for the diagnostics: a new failure fails the gate, a
# known one that now passes is reported, and `--update` records the current set.
#
#   NS_MUTATIONS=this,parens   only these mutations (default: all)
#   NS_JOBS=<n>                tests in flight at once (default: the cores)
#
# Usage:  NIM=/path/to/nim ./nsharp/tests/run_mutate.sh [--update]
# Skips cleanly without `dotnet`. It is slow (one N# build per mutant), so run.sh
# runs it only when NS_MUTATE=1.

set -u
NIM="${NIM:-nim}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
lib="$root/lib"
oracleDir="$root/tools/nsoracle"
oracleDll="$oracleDir/bin/Release/net10.0/nsoracle.dll"
known="$here/mutate/known.txt"
work="${TMPDIR:-/tmp}/ns_mutate"
## The expectations are what .NET prints under en-US, as in run_cs.sh.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
. "$here/par.sh"

run_one() {
  ## One test: its mutants, verified by Roslyn, built and run by N#. Prints `ok` or
  ## a `FAILURE <kind> <test> <mutation>` line (and detail) for each; returns 1 if
  ## any failed.
  ns="$1"
  rel="${ns#$here/}"
  rc=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ns_mutate_one.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  expect="${ns%.ns}.csout"
  [ -f "$expect" ] || expect="${ns%.ns}.out"
  ## The main file plus every sibling `.ns` with no marker of its own: a module the
  ## main file is compiled with.
  sibs=""
  for sib in "$(dirname "$ns")"/*.ns; do
    [ -f "$sib" ] || continue
    [ "$sib" = "$ns" ] && continue
    [ -f "${sib%.ns}.out" ] && continue
    [ -f "${sib%.ns}.fail" ] && continue
    [ -f "${sib%.ns}.unsupported" ] && continue
    sibs="$sibs $sib"
  done
  # shellcheck disable=SC2086
  if ! dotnet "$oracleDll" --mutate "$tmp/m" "$expect" "$ns" $sibs > "$tmp/gen.txt" 2> "$tmp/gen.err"; then
    echo "FAILURE oracle $rel -"
    sed 's/^/  /' "$tmp/gen.err"
    return 1
  fi
  while read -r status mut detail; do
    case "$status" in
      unchanged) continue ;;
      invalid|differs)
        echo "FAILURE mutator-$status $rel $mut"
        echo "  $detail"
        rc=1
        continue ;;
    esac
    d="$tmp/w_$mut"
    mkdir -p "$d"
    cp "$tmp/m/$mut.ns" "$d/$(basename "$ns")"
    for sib in $sibs; do cp "$sib" "$d/"; done
    if ! timeout 180 "$NIM" c --hints:off --warnings:off --lib:"$lib" $(ns_flags "$ns") \
          --nimcache:"$(ns_nimcache "$root" "$ns" "_mut_$mut")" \
          -o:"$d/bin" "$d/$(basename "$ns")" > "$d/log" 2>&1; then
      code="$(grep -m1 -o 'Error: NS[0-9]*' "$d/log" | sed 's/Error: //')"
      echo "FAILURE n#-compile $rel $mut ${code:-nim}"
      grep -m2 "Error" "$d/log" | cut -c1-220 | sed 's/^/  /'
      rc=1
      continue
    fi
    timeout 60 "$d/bin" > "$d/got.txt" 2> /dev/null
    if [ "$(cat "$d/got.txt")" = "$(cat "${ns%.ns}.out")" ]; then
      echo "ok: $rel [$mut]"
    else
      echo "FAILURE n#-output $rel $mut"
      diff "${ns%.ns}.out" "$d/got.txt" | head -6 | sed 's/^/  /'
      rc=1
    fi
  done < "$tmp/gen.txt"
  return $rc
}

if [ "${1:-}" = "--one" ]; then
  run_one "$2"
  exit $?
fi

update=0
[ "${1:-}" = "--update" ] && update=1

if ! command -v dotnet >/dev/null 2>&1; then
  echo "skip: dotnet not found on PATH"
  exit 0
fi
mkdir -p "$work"
## The oracle is built the way run_sema.sh builds it: when missing or out of date.
if [ ! -f "$oracleDll" ] || \
   [ -n "$(find "$oracleDir" -name '*.cs' -newer "$oracleDll" 2>/dev/null)" ]; then
  if ! dotnet build "$oracleDir/nsoracle.csproj" -c Release --nologo -v q \
        > "$work/oracle.log" 2>&1; then
    echo "skip: could not build the Roslyn oracle"
    sed -n '1,20p' "$work/oracle.log"
    exit 0
  fi
fi

tests=""
for ns in "$here"/*/*.ns "$here"/modules/*/*.ns; do
  case "$ns" in "$here"/native/*) continue ;; esac   # C++-driven: run_native.sh
  [ -f "$ns" ] || continue
  [ -f "${ns%.ns}.out" ] || continue
  tests="$tests $ns"
done
# shellcheck disable=SC2086
ns_par_each "$work/results" $tests > "$work/all.log" 2>&1
checked=$(grep -c '^ok: \|^FAILURE n#' "$work/all.log")

## The current failures, `<test> <mutation> <kind>`, sorted by test and mutation.
grep '^FAILURE ' "$work/all.log" | awk '{print $3, $4, $2}' | sort > "$work/now.txt"

if [ "$update" = "1" ]; then
  ## A defect in the mutator is never recorded as known.
  grep -v ' mutator-\| oracle$' "$work/now.txt" > "$work/new_known.txt"
  mkdir -p "$(dirname "$known")"
  cp "$work/new_known.txt" "$known"
  echo "wrote $known ($(wc -l < "$known") known failure(s))"
fi
[ -f "$known" ] || : > "$known"
sort "$known" | cut -d' ' -f1,2 > "$work/known_keys.txt"
cut -d' ' -f1,2 "$work/now.txt" | sort > "$work/now_keys.txt"

fail=0
## Everything printed except the passes and the failures that are already known.
grep -v '^ok: ' "$work/all.log" | awk -v known="$work/known_keys.txt" '
  BEGIN { while ((getline line < known) > 0) k[line] = 1 }
  /^FAILURE / { key = $3 " " $4; show = !(key in k); if (show) print; next }
  /^  / { if (show) print; next }
  { print }' > "$work/report.txt"
if [ -s "$work/report.txt" ]; then
  fail=1
  echo "NEW mutation failures (a new failure, or a defect in the mutator):"
  cat "$work/report.txt"
fi
comm -23 "$work/known_keys.txt" "$work/now_keys.txt" | while read -r t m; do
  echo "fixed: $t [$m] passes now (run with --update to record)"
done
echo "mutated: $checked mutant(s) built by N#, $(wc -l < "$work/now.txt") failing," \
     "$(wc -l < "$known") known"
exit $fail
