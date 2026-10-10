#!/bin/sh
# Diagnostics gate: every program under nsharp/tests/diag/cases/ is wrong C#. Roslyn
# names the error each one must get; N# should report the same code (as NSxxxx)
# rather than let it reach Nim, or accept the program.
#
# Each case is classified:
#   match     N# reports Roslyn's code
#   code:NSx  N# reports a code of its own, but not Roslyn's
#   nim       the error surfaced as Nim's, not as an N# diagnostic
#   accepted  N# compiled the program
#
# `diag/baseline.txt` records Roslyn's code and the last accepted status of each
# case. A case that matched and no longer does fails the gate; one that improved
# is reported, and `--update` records it (and asks Roslyn again, which needs
# `dotnet`). Without `--update` the gate needs no `dotnet`.
#
# Usage:  ./nsharp/tests/run_diag.sh [--update]

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
NIM1="${NIM1:-$root/bin/nim1}"
oracle="$root/tools/nsoracle/bin/Release/net10.0/nsoracle.dll"
base="$here/diag/baseline.txt"
work="${TMPDIR:-/tmp}/ns_diag"
update=0
[ "${1:-}" = "--update" ] && update=1
mkdir -p "$work"

if [ "${1:-}" = "--one" ]; then
  ## One case, run by the parallel loop below: "<name> <status>".
  f="$2"; n="$(basename "$f" .ns)"
  out="$(timeout 120 "$NIM1" c --hints:off --warnings:off --lib:"$root/lib" \
         -o:"$work/$n.bin" "$f" 2>&1)"
  if [ $? -eq 0 ]; then echo "$n accepted"; exit 0; fi
  line="$(printf '%s\n' "$out" | grep -m1 'Error:')"
  code="$(printf '%s\n' "$line" | sed -n 's/.*Error: NS\([0-9][0-9]*\).*/\1/p')"
  if [ -n "$code" ]; then echo "$n NS$code"; else echo "$n nim"; fi
  exit 0
fi

ls "$here"/diag/cases/*.ns | xargs -P 8 -n 1 "$0" --one | sort > "$work/got.txt"

if [ "$update" = "1" ]; then
  [ -f "$oracle" ] || { echo "run_diag: --update needs the oracle ($oracle)"; exit 2; }
  : > "$work/new.txt"
  while read -r n got; do
    want="$(dotnet "$oracle" --diag "$here/diag/cases/$n.ns" | sed -n '1s/^CS\([0-9]*\).*/\1/p')"
    st="$got"
    if [ "$got" = "NS$want" ]; then st=match
    elif [ "$got" != nim ] && [ "$got" != accepted ]; then st="code:$got"; fi
    echo "$n CS$want $st" >> "$work/new.txt"
  done < "$work/got.txt"
  cp "$work/new.txt" "$base"
  echo "wrote $base"
fi

fail=0; total=0; matched=0
while read -r n want st; do
  total=$((total + 1))
  got="$(grep "^$n " "$work/got.txt" | cut -d' ' -f2)"
  now="$got"
  if [ "$got" = "NS${want#CS}" ]; then now=match
  elif [ "$got" != nim ] && [ "$got" != accepted ]; then now="code:$got"; fi
  [ "$now" = match ] && matched=$((matched + 1))
  if [ "$st" = match ] && [ "$now" != match ]; then
    echo "REGRESSED: diag/cases/$n.ns wants $want, now $now"; fail=1
  elif [ "$st" != match ] && [ "$now" = match ]; then
    echo "improved: diag/cases/$n.ns now reports $want (run with --update to record)"
  fi
done < "$base"
echo "diagnostics: $matched of $total cases report Roslyn's code"
exit $fail
