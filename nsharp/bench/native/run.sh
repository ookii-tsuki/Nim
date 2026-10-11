#!/bin/sh
# Native interop benchmarks: each `<name>.ns` (driven by `<name>.cpp`) against
# `<name>_ref.cpp`, the same workload in plain C++, both over the test engine in
# ../../tests/native/toybox. Prints the best of three wall-clock times.
#
# Usage:  NIM=/path/to/nim1 ./run.sh [name...]
set -u
NIM="${NIM:-nim}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
tb="$root/nsharp/tests/native/toybox"
names="${*:-$(cd "$here" && ls *_ref.cpp | sed 's/_ref\.cpp$//')}"
best() {
  b=""
  for k in 1 2 3; do
    s=$(date +%s.%N); "$1" > /tmp/ns_nbench.out; e=$(date +%s.%N)
    t=$(echo "$e - $s" | bc)
    if [ -z "$b" ] || [ "$(echo "$t < $b" | bc)" = 1 ]; then b=$t; fi
  done
  echo "$b"
}
printf "%-12s %9s %9s %7s  %s\n" bench "N# (s)" "C++ (s)" ratio output
for n in $names; do
  ## Built beside a copy of the engine's binding, as a program using it is.
  src="/tmp/ns_nbench_src_$n"
  rm -rf "$src"; mkdir -p "$src"
  cp "$here/$n.ns" "$root/nsharp/tests/native/Toybox.ns" "$src/"
  "$NIM" cpp -d:release --noMain --exceptions:goto --hints:off --warnings:off \
    --lib:"$root/lib" --nimcache:"/tmp/ns_nbench_$n" --passC:"-std=c++20 -I$tb" \
    --compile:"$here/$n.cpp" -o:"/tmp/ns_nbench_$n.bin" "$src/$n.ns" > /tmp/ns_nbench.log 2>&1 ||
    { echo "$n: N# build failed"; tail -5 /tmp/ns_nbench.log; continue; }
  g++ -O3 -std=c++20 -I"$tb" -o "/tmp/ns_nbench_${n}_ref" "$here/${n}_ref.cpp" ||
    { echo "$n: C++ build failed"; continue; }
  tn=$(best "/tmp/ns_nbench_$n.bin"); on=$(cat /tmp/ns_nbench.out)
  tc=$(best "/tmp/ns_nbench_${n}_ref"); oc=$(cat /tmp/ns_nbench.out)
  same=$([ "$on" = "$oc" ] && echo same || echo "DIFFERS ($on vs $oc)")
  printf "%-12s %9.3f %9.3f %7.2f  %s\n" "$n" "$tn" "$tc" "$(echo "$tn / $tc" | bc -l)" "$same"
done
