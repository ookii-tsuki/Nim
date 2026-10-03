#
#           N# frontend - AST dump tool (Stage 0a: the golden-AST test net)
#
# Parses an `.ns` file and prints its parse output as a deterministic text tree.
#
# The frontend has no parser-level test seam: the only feedback today is the
# stdout of a compiled program, which cannot show whether a parser change was
# behaviour preserving. This tool is that seam. It drives `parseNsModule`
# directly rather than adding a hook to the compiler, so the compiler tree stays
# untouched (the minimal-diff constraint).
#
# It dumps the *parse output* on purpose, not post-`sem` output. Almost all the
# lowering happens during the parse (class members become top-level procs,
# `switch` becomes `case`, `new T[n]` becomes `newSeq[T](n)`, a lambda gets its
# parameter types from the declared delegate type, ...). Pinning exactly that
# fused behaviour is what makes the stage 1-3 refactor verifiable.
#
# Usage:
#   bin/nim1 c -o:/tmp/dumpast compiler/nsharp/tools/dumpast.nim
#   /tmp/dumpast path/to/file.ns          # the lowered Nim tree (golden tests)
#   /tmp/dumpast --ns path/to/file.ns     # the N# syntax tree, before lowering
#
# The `--ns` mode prints the parser's own output, which is what stage 2/3 work
# needs to look at; the default mode is what run_ast.sh pins.
#
# Normally exercised through nsharp/tests/run_ast.sh.

import std/[os, strutils, syncio]
import ../../ast, ../../idents, ../../lineinfos, ../../msgs, ../../options,
       ../../pathutils
import ../ast as nsast, ../parser, ../frontend

proc esc(s: string): string =
  ## One node per line, so a literal must never contain a raw newline.
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add c

proc nsTreeRepr*(n: PNode; indent = 0): string =
  ## Node kind, its payload if it has one, then children indented by two spaces.
  ## No spans and no source text: the golden files must stay readable and must
  ## not churn when unrelated line numbers move.
  result = repeat("  ", indent) & $n.kind
  case n.kind
  of nkIdent: result.add " '" & n.ident.s & "'"
  of nkSym: result.add " '" & n.sym.name.s & "'"
  of nkStrLit, nkRStrLit, nkTripleStrLit:
    result.add " \"" & esc(n.strVal) & "\""
  of nkCharLit, nkIntLit, nkInt8Lit, nkInt16Lit, nkInt32Lit, nkInt64Lit,
     nkUIntLit, nkUInt8Lit, nkUInt16Lit, nkUInt32Lit, nkUInt64Lit:
    result.add " " & $n.intVal
  of nkFloatLit, nkFloat32Lit, nkFloat64Lit, nkFloat128Lit:
    result.add " " & $n.floatVal
  else: discard
  result.add "\n"
  # leaf nodes have no `sons` field, so `n.len` would raise FieldDefect
  for i in 0 ..< n.safeLen:
    result.add nsTreeRepr(n[i], indent + 1)

proc main() =
  var nsMode = false
  var path = ""
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a == "--ns": nsMode = true
    elif path.len == 0: path = a
  if path.len == 0:
    stderr.write("usage: dumpast [--ns] <file.ns>\n")
    quit(2)
  var source = ""
  try:
    source = readFile(path)
  except CatchableError:
    stderr.write("dumpast: cannot read " & path & "\n")
    quit(2)
  let conf = newConfigRef()
  # `localError` quits once `errorCounter >= errorMax` (default 1), which would
  # abort the parse of an expected-failure test before any tree exists. The tool
  # wants the tree, not diagnostic gating, so keep going.
  conf.errorMax = high(int)
  let fileIdx = conf.fileInfoIdx(AbsoluteFile(path))
  if nsMode:
    stdout.write nsast.repr(parseNsModule(source, fileIdx, conf))
  else:
    let cache = newIdentCache()
    stdout.write nsTreeRepr(compileNsSource(source, fileIdx, cache, conf))

when isMainModule:
  main()