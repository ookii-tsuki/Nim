#!/bin/sh
# N# vs C# performance comparison.
#
# Each `.ns` here is valid C# that prints a checksum. It is built twice -- by N#
# (`nim c -d:release`) and by the .NET SDK (`dotnet -c Release`) -- the outputs are
# compared, and each program is timed (best of $NS_BENCH_RUNS runs, default 3).
#
# Usage:  NIM=../../bin/nim1 ./run_bench.sh [name...]
# Extra N# flags go in NS_BENCH_FLAGS (e.g. NS_BENCH_FLAGS=-d:danger).

set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
lib="$root/lib"
NIM="${NIM:-nim}"
runs="${NS_BENCH_RUNS:-3}"
flags="${NS_BENCH_FLAGS:--d:release}"
work="${TMPDIR:-/tmp}/ns_bench"
mkdir -p "$work"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

best_time() {
  ## Best wall time in seconds of `$runs` runs of "$1", output to "$2".
  best=""
  i=0
  while [ "$i" -lt "$runs" ]; do
    s=$(date +%s.%N)
    "$1" > "$2" 2>&1
    e=$(date +%s.%N)
    t=$(echo "$e - $s" | bc)
    if [ -z "$best" ] || [ "$(echo "$t < $best" | bc)" = 1 ]; then best=$t; fi
    i=$((i + 1))
  done
  printf '%.3f' "$best"
}

if [ $# -gt 0 ]; then
  set -- $(for n in "$@"; do echo "$here/$n.ns"; done)
else
  set -- "$here"/*.ns
fi

printf '%-12s %10s %10s %8s  %s\n' bench "N# (s)" "C# (s)" ratio output
for ns in "$@"; do
  name=$(basename "$ns" .ns)
  d="$work/$name"
  mkdir -p "$d/cs"
  if ! "$NIM" c --hints:off --warnings:off $flags --lib:"$lib" -o:"$d/ns_bin" "$ns" \
       > "$d/build.log" 2>&1; then
    printf '%-12s %10s\n' "$name" "BUILD FAIL"; tail -5 "$d/build.log"; continue
  fi
  cp "$ns" "$d/cs/Program.cs"
  cat > "$d/cs/bench.csproj" <<'P'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>disable</Nullable>
    <ImplicitUsings>disable</ImplicitUsings>
    <InvariantGlobalization>true</InvariantGlobalization>
    <TieredPGO>true</TieredPGO>
  </PropertyGroup>
</Project>
P
  if ! dotnet build -c Release -o "$d/cs/out" "$d/cs" > "$d/cs.log" 2>&1; then
    printf '%-12s %10s\n' "$name" "C# BUILD FAIL"; continue
  fi
  tn=$(best_time "$d/ns_bin" "$d/ns.out")
  tc=$(best_time "$d/cs/out/bench" "$d/cs.out")
  same=$(cmp -s "$d/ns.out" "$d/cs.out" && echo same || echo DIFFERS)
  ratio=$(echo "scale=2; $tn / $tc" | bc)
  printf '%-12s %10s %10s %8s  %s\n' "$name" "$tn" "$tc" "$ratio" "$same"
done
