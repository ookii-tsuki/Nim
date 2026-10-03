#!/bin/sh
# N# parser golden-AST check (Stage 0a).
#
# Builds compiler/nsharp/tools/dumpast.nim, runs it over every `.ns` test, and
# diffs the result against nsharp/tests/ast/<name>.golden. This pins the current
# parse output so the parser refactor (stages 1-3) can be shown to be behaviour
# preserving; `run.sh`'s stdout comparison cannot show that on its own.
#
# Usage:
#   ./nsharp/tests/run_ast.sh            # verify against the committed goldens
#   ./nsharp/tests/run_ast.sh --update   # (re)generate the goldens
#   NIM1=/path/to/nim1 ./nsharp/tests/run_ast.sh
#
# Skips cleanly when the tool cannot be built. Set NS_SKIP_AST=1 in run.sh to
# skip the whole check.

set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
NIM1="${NIM1:-$root/bin/nim1}"
goldenDir="$here/ast"
work="${TMPDIR:-/tmp}/ns_ast"
tool="$work/dumpast"
fail=0
count=0
update=0
[ "${1:-}" = "--update" ] && update=1

mkdir -p "$work"

# Rebuild only when the tool is missing or older than the frontend sources;
# bootstrapping it costs about 30 seconds, which should not be paid on every
# suite run.
stale=0
[ -x "$tool" ] || stale=1
if [ "$stale" = "0" ] && \
   [ -n "$(find "$root/compiler/nsharp" -name '*.nim' -newer "$tool" 2>/dev/null)" ]; then
  stale=1
fi
if [ "$stale" = "1" ]; then
  if ! "$NIM1" c --skipUserCfg --skipParentCfg --hints:off --warnings:off \
        -o:"$tool" "$root/compiler/nsharp/tools/dumpast.nim" > "$work/build.log" 2>&1; then
    echo "skip: could not build the AST dump tool"
    sed -n '1,20p' "$work/build.log"
    exit 0
  fi
fi

for ns in "$here"/*.ns "$here"/*/*.ns; do
  [ -f "$ns" ] || continue
  count=$((count + 1))
  rel="${ns#$here/}"
  golden="$goldenDir/${rel%.ns}.golden"

  # stderr carries any N# diagnostic; stdout is the tree alone
  got="$("$tool" "$ns" 2>/dev/null)"

  if [ -z "$got" ]; then
    echo "EMPTY (no AST produced): nsharp/tests/$rel"
    fail=1
    continue
  fi

  if [ "$update" = "1" ]; then
    mkdir -p "$(dirname "$golden")"
    printf '%s\n' "$got" > "$golden"
    echo "wrote: nsharp/tests/ast/${rel%.ns}.golden"
    continue
  fi

  if [ ! -f "$golden" ]; then
    echo "MISSING golden: nsharp/tests/ast/${rel%.ns}.golden (run with --update)"
    fail=1
    continue
  fi

  if printf '%s\n' "$got" | diff -u "$golden" - > "$work/diff.txt" 2>&1; then
    echo "ok: nsharp/tests/$rel"
  else
    echo "AST CHANGED: nsharp/tests/$rel"
    sed -n '1,40p' "$work/diff.txt"
    fail=1
  fi
done

echo "checked $count AST golden(s)"
exit $fail