#!/bin/sh
# N# semantic conformance gate: the meaning is what C# says, not just the parse.
#
#   compiler/nsharp/tools/dumpsema.nim   what the N# frontend resolved
#   tools/nsoracle                       what Roslyn resolves for the same file
#
# Every `.ns` test is deliberately valid C# (see run_cs.sh), so the oracle
# compiles the same file with Roslyn and the gate fails when the two projections
# disagree on a namespace or a type.
#
# The committed golden under nsharp/tests/sema/<name>.golden is the Roslyn
# output; `--update` regenerates it. Beside it a `.skipped` ledger enumerates
# every member access this stage does *not* project, so a blind spot is ratcheted
# rather than silently growing.
#
# Usage:
#   ./nsharp/tests/run_sema.sh            # verify against the committed goldens
#   ./nsharp/tests/run_sema.sh --update   # (re)generate the goldens from Roslyn
#   NIM1=/path/to/nim1 ./nsharp/tests/run_sema.sh
#
# Skips cleanly when the N# tool cannot be built or `dotnet` is not on PATH.

set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
NIM1="${NIM1:-$root/bin/nim1}"
goldenDir="$here/sema"
work="${TMPDIR:-/tmp}/ns_sema"
tool="$work/dumpsema"
oracleDir="$root/tools/nsoracle"
oracleDll="$oracleDir/bin/Release/net10.0/nsoracle.dll"
fail=0
count=0
update=0
[ "${1:-}" = "--update" ] && update=1

mkdir -p "$work"

# Build the N# half only when it is missing or older than the frontend sources.
stale=0
[ -x "$tool" ] || stale=1
if [ "$stale" = "0" ] && \
   [ -n "$(find "$root/compiler/nsharp" -name '*.nim' -newer "$tool" 2>/dev/null)" ]; then
  stale=1
fi
if [ "$stale" = "1" ]; then
  if ! "$NIM1" c --skipUserCfg --skipParentCfg --hints:off --warnings:off \
        -o:"$tool" "$root/compiler/nsharp/tools/dumpsema.nim" > "$work/build.log" 2>&1; then
    echo "skip: could not build the semantic dump tool"
    sed -n '1,20p' "$work/build.log"
    exit 0
  fi
fi

# The Roslyn half, built the same way; without it the N# half is still checked
# against the committed goldens.
have_dotnet=0
if command -v dotnet >/dev/null 2>&1; then
  if [ -f "$oracleDll" ] && \
     [ -z "$(find "$oracleDir" -name '*.cs' -newer "$oracleDll" 2>/dev/null)" ]; then
    have_dotnet=1
  elif dotnet build "$oracleDir/nsoracle.csproj" -c Release --nologo -v q \
        > "$work/oracle.log" 2>&1; then
    have_dotnet=1
  else
    echo "skip: could not build the Roslyn oracle"
    sed -n '1,20p' "$work/oracle.log"
  fi
fi

if [ "$update" = "1" ] && [ "$have_dotnet" = "0" ]; then
  echo "skip: --update needs dotnet (the goldens come from Roslyn)"
  exit 0
fi

for ns in "$here"/*.ns "$here"/*/*.ns; do
  [ -f "$ns" ] || continue
  [ -f "${ns%.ns}.out" ] || continue
  count=$((count + 1))
  rel="${ns#$here/}"
  golden="$goldenDir/${rel%.ns}.golden"
  ledger="$goldenDir/${rel%.ns}.skipped"

  # The main file plus every sibling `.ns` with no marker of its own: a module
  # the main file is compiled with.
  files="$ns"
  dir="$(dirname "$ns")"
  for sib in "$dir"/*.ns; do
    [ -f "$sib" ] || continue
    [ "$sib" = "$ns" ] && continue
    [ -f "${sib%.ns}.out" ] && continue
    [ -f "${sib%.ns}.fail" ] && continue
    [ -f "${sib%.ns}.unsupported" ] && continue
    files="$files $sib"
  done

  if [ "$update" = "1" ]; then
    want="$(dotnet "$oracleDll" $files)"
    mkdir -p "$(dirname "$golden")"
    printf '%s\n' "$want" > "$golden"
    printf '%s\n' "$(dotnet "$oracleDll" --ledger $files)" > "$ledger"
    echo "wrote: nsharp/tests/sema/${rel%.ns}.golden"
    echo "wrote: nsharp/tests/sema/${rel%.ns}.skipped"
    continue
  fi

  if [ ! -f "$golden" ]; then
    echo "MISSING golden: nsharp/tests/sema/${rel%.ns}.golden (run with --update)"
    fail=1
    continue
  fi
  want="$(cat "$golden")"

  # The oracle must still reproduce the golden; if it does not, Roslyn or its BCL
  # moved and the golden is stale.
  if [ "$have_dotnet" = "1" ]; then
    fresh="$(dotnet "$oracleDll" $files)"
    if [ "$fresh" != "$want" ]; then
      echo "ORACLE DRIFT (Roslyn no longer reproduces the golden): nsharp/tests/$rel"
      printf '%s\n' "$want" > "$work/want.txt"
      printf '%s\n' "$fresh" > "$work/fresh.txt"
      diff "$work/want.txt" "$work/fresh.txt"
      fail=1
      continue
    fi

    # The out-of-scope ledger is ratcheted the same way.
    if [ ! -f "$ledger" ]; then
      echo "MISSING ledger: nsharp/tests/sema/${rel%.ns}.skipped (run with --update)"
      fail=1
    else
      freshled="$(dotnet "$oracleDll" --ledger $files)"
      if [ "$freshled" != "$(cat "$ledger")" ]; then
        echo "OUT-OF-SCOPE CHANGED: nsharp/tests/$rel"
        printf '%s\n' "$(cat "$ledger")" > "$work/lwant.txt"
        printf '%s\n' "$freshled" > "$work/lfresh.txt"
        diff "$work/lwant.txt" "$work/lfresh.txt"
        fail=1
      fi
    fi
  fi

  got="$("$tool" "$ns" 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    echo "ok: nsharp/tests/$rel"
  else
    echo "SEMA DIVERGES (N# vs C#): nsharp/tests/$rel"
    printf '%s\n' "$want" > "$work/want.txt"
    printf '%s\n' "$got" > "$work/got.txt"
    diff "$work/want.txt" "$work/got.txt"
    fail=1
  fi
done

echo "checked $count semantic projection(s)"
exit $fail
