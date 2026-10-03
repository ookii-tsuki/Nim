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
# Usage:  ./nsharp/tests/run_cs.sh
# Skips cleanly when `dotnet` is unavailable on PATH.

set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="${TMPDIR:-/tmp}/ns_cs_check"
fail=0
count=0

if ! command -v dotnet >/dev/null 2>&1; then
  echo "skip: dotnet not found on PATH"
  exit 0
fi

rm -rf "$work"
mkdir -p "$work"
cat > "$work/check.csproj" <<'EOF'
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
bin="$work/bin/Release/net10.0/nscross"

for ns in "$here"/*.ns "$here"/*/*.ns; do
  [ -f "$ns" ] || continue
  out="${ns%.ns}.out"
  failmark="${ns%.ns}.fail"
  unsupmark="${ns%.ns}.unsupported"
  [ -f "$out" ] || [ -f "$failmark" ] || [ -f "$unsupmark" ] || continue
  count=$((count + 1))
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
      echo "ok (C# rejects, as expected): ${ns#$root/}"
    elif [ -f "$unsupmark" ]; then
      echo "FAIL (N# rejects it as unsupported, but it is not valid C# either): ${ns#$root/}"
      sed -n '1,10p' "$work/build.log"
      fail=1
    else
      echo "CS FAIL (C# would not compile): ${ns#$root/}"
      sed -n '1,20p' "$work/build.log"
      fail=1
    fi
    continue
  fi

  if [ -f "$failmark" ]; then
    echo "FAIL (C# compiled but N# rejects): ${ns#$root/}"
    fail=1
    continue
  fi

  if [ -f "$unsupmark" ]; then
    ## N# refuses it, and it really is valid C#: that is the point of the marker.
    echo "ok (C# accepts, N# does not support it yet): ${ns#$root/}"
    continue
  fi

  got="$("$bin")"
  want="$(cat "$out")"
  if [ "$got" = "$want" ]; then
    echo "ok (C# agrees): ${ns#$root/}"
  else
    echo "DIFF (C# vs .out): ${ns#$root/}"
    echo "--- .out (N# expectation) ---"; echo "$want"
    echo "--- C# produced ---"; echo "$got"
    fail=1
  fi
done

echo "cross-checked $count test(s) against the C# compiler"
exit $fail
