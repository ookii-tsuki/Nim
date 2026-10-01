#
#           N# frontend — entry point called by the compiler core
#
# The compiler core reaches the N# frontend through exactly two call sites,
# both guarded by `when defined(nsharp)`:
#   * `compiler/syntaxes.nim`  (parseFile dispatch)
#   * `compiler/pipelines.nim` (module pipeline dispatch)
# See ../nsharp/ARCHITECTURE.md for the minimal-diff rationale.

import std/[os, syncio]
import ../ast, ../idents, ../lineinfos, ../options, ../msgs, ../pathutils
import keywords, lexer, parser

proc isNsharpFile*(config: ConfigRef; fileIdx: FileIndex): bool =
  ## True when `fileIdx` names a `.ns` source file.
  let path = toFullPath(config, fileIdx)
  result = splitFile(path.string).ext == ".ns"

proc parseModule*(fileIdx: FileIndex; cache: IdentCache;
                  config: ConfigRef): PNode =
  ## Parses an `.ns` file into an `nkStmtList` of ordinary Nim `PNode`s.
  let path = toFullPath(config, fileIdx)
  var source = ""
  try:
    source = readFile(path.string)
  except CatchableError:
    localError(config, newLineInfo(fileIdx, 1, 1),
               "N#: cannot read " & path.string)
    return newNodeI(nkStmtList, newLineInfo(fileIdx, 1, 1))
  result = parseNsModule(source, fileIdx, cache, config)
