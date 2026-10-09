#!/bin/sh
# N# <-> C# equivalence check.
#
# Every `.ns` test is deliberately valid C# (or deliberately invalid, for the
# `.fail` tests). This script compiles each one with the .NET SDK and requires
# that the C# program's stdout matches the very same `<name>.out` that the N#
# runner uses. That makes the .NET compiler the source of truth for observable
# behaviour instead of trusting the frontend's own expectations.
#
# A sibling `.ns` with neither a `.out` nor a `.fail` is treated as a module of
# the program (like p1b/Math.ns) and is compiled together with it.
#
# A `.csout` beside a test records what C# produces when it legitimately differs
# from the `.out`, for instance a bool reading `true` in N# and `True` in C#.
#
# Usage:  ./nsharp/tests/run_cs.sh
# Skips cleanly when `dotnet` is unavailable on PATH.

set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="${TMPDIR:-/tmp}/ns_cs_check"
## The expectations are what .NET prints under en-US (`∞`, `12.5%`), so the culture
## is pinned rather than taken from whoever runs the gate.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
fail=0
count=0

if ! command -v dotnet >/dev/null 2>&1; then
  echo "skip: dotnet not found on PATH"
  exit 0
fi

write_proj() {
cat > "$1/check.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>disable</Nullable>
    <ImplicitUsings>disable</ImplicitUsings>
    <AssemblyName>nscross</AssemblyName>
    <RootNamespace>nscross</RootNamespace>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="*.cs" />
  </ItemGroup>
</Project>
EOF
}

check_one() {
  ## One test, in its own work directory, so tests can be built side by side.
  ns="$1"
  work="$2"
  mkdir -p "$work"
  [ -f "$work/check.csproj" ] || write_proj "$work"
  bin="$work/bin/Release/net10.0/nscross"
  out="${ns%.ns}.out"
  [ -f "$ns" ] || return 0
  failmark="${ns%.ns}.fail"
  unsupmark="${ns%.ns}.unsupported"
  [ -f "$out" ] || [ -f "$failmark" ] || [ -f "$unsupmark" ] || return 0
  dir="$(dirname "$ns")"

  # program plus any sibling modules (no .out, .fail or .unsupported)
  rm -f "$work"/*.cs
  cp "$ns" "$work/Program.cs"
  for sib in "$dir"/*.ns; do
    [ -f "$sib" ] || continue
    [ "$sib" = "$ns" ] && continue
    [ -f "${sib%.ns}.out" ] && continue
    [ -f "${sib%.ns}.fail" ] && continue
    [ -f "${sib%.ns}.unsupported" ] && continue
    cp "$sib" "$work/$(basename "${sib%.ns}").cs"
  done

  if ! dotnet build "$work/check.csproj" -c Release --nologo -v q --no-incremental \
        > "$work/build.log" 2>&1; then
    if [ -f "$failmark" ]; then
      ## A `code: NSxxxx` marker is checked against the code C# reports, so the
      ## mirror holds unless the marker is in the N#-only band.
      want="$(sed -n 's/^code: *//p' "$failmark" | head -1)"
      case "$want" in
        NS[0-89]*)
          cs="$(grep -o 'error CS[0-9]*' "$work/build.log" |
                sed 's/error CS//' | sort -u | tr '\n' ' ')"
          if echo " $cs " | grep -q " ${want#NS} "; then
            echo "ok (C# rejects with the same code, ${want#NS}): ${ns#$root/}"
          else
            echo "FAIL ($want, but C# reports: ${cs:-none}): ${ns#$root/}"
            fail=1; touch "$work/FAILED"
          fi ;;
        *)
          echo "ok (C# rejects, as expected): ${ns#$root/}" ;;
      esac
    elif [ -f "$unsupmark" ]; then
      echo "FAIL (N# rejects it as unsupported, but it is not valid C# either): ${ns#$root/}"
      sed -n '1,10p' "$work/build.log"
      fail=1; touch "$work/FAILED"
    else
      echo "CS FAIL (C# would not compile): ${ns#$root/}"
      sed -n '1,20p' "$work/build.log"
      fail=1; touch "$work/FAILED"
    fi
    return 0
  fi

  if [ -f "$failmark" ]; then
    echo "FAIL (C# compiled but N# rejects): ${ns#$root/}"
    fail=1; touch "$work/FAILED"
    return 0
  fi

  if [ -f "$unsupmark" ]; then
    ## N# refuses it, and it really is valid C#: that is the point of the marker.
    echo "ok (C# accepts, N# does not support it yet): ${ns#$root/}"
    return 0
  fi

  got="$("$bin")"
  csout="${ns%.ns}.csout"
  if [ -f "$csout" ]; then
    ## The test records how C# differs, so that is what C# must produce.
    want="$(cat "$csout")"
    if [ "$got" = "$want" ]; then
      echo "ok (C# differs from .out, as .csout records): ${ns#$root/}"
    else
      echo "DIFF (C# vs .csout): ${ns#$root/}"
      echo "--- .csout ---"; echo "$want"
      echo "--- C# produced ---"; echo "$got"
      fail=1; touch "$work/FAILED"
    fi
    return 0
  fi
  want="$(cat "$out")"
  if [ "$got" = "$want" ]; then
    echo "ok (C# agrees): ${ns#$root/}"
  else
    echo "DIFF (C# vs .out): ${ns#$root/}"
    echo "--- .out (N# expectation) ---"; echo "$want"
    echo "--- C# produced ---"; echo "$got"
    fail=1; touch "$work/FAILED"
  fi
}

rm -rf "$work"
mkdir -p "$work"
jobs="${NS_CS_JOBS:-$(nproc 2>/dev/null || echo 2)}"
## Every test runs in a slot directory of its own; each test's output is kept and
## printed in order, so the log reads the same however the builds interleave.
i=0
for ns in "$here"/*.ns "$here"/*/*.ns; do
  [ -f "$ns" ] || continue
  out="${ns%.ns}.out"
  [ -f "$out" ] || [ -f "${ns%.ns}.fail" ] || [ -f "${ns%.ns}.unsupported" ] || continue
  i=$((i + 1))
  printf '%s %s %s\n' "$i" "$((i % jobs))" "$ns"
done > "$work/list"
count=$i
## Slot `k` is used by one test at a time: the tests of a slot run in sequence.
k=0
while [ "$k" -lt "$jobs" ]; do
  (
    ## `check_one` assigns `work`, so the top directory is kept under its own name.
    top="$work"
    while read -r idx slot ns; do
      [ "$slot" = "$k" ] || continue
      check_one "$ns" "$top/slot$k" > "$top/log.$idx" 2>&1 < /dev/null
    done < "$top/list"
  ) &
  k=$((k + 1))
done
wait
j=1
while [ "$j" -le "$count" ]; do
  cat "$work/log.$j"
  j=$((j + 1))
done
for d in "$work"/slot*; do
  [ -f "$d/FAILED" ] && fail=1
done

echo "cross-checked $count test(s) against the C# compiler"
exit $fail
