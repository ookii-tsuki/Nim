# N# frontend - entry point called by the compiler core
#
# The compiler core reaches the frontend through two call sites, both guarded by
# `when defined(nsharp)`: `compiler/syntaxes.nim` (parseFile dispatch) and
# `compiler/pipelines.nim` (module pipeline dispatch). See
# ../nsharp/ARCHITECTURE.md for the minimal-diff rationale.
#
# The pipeline, one module per phase:
#
#   parser.nim   tokens -> ast.NsNode          (grammar only)
#   symbols.nim  ast.NsNode -> module scope    (declaration collection)
#   sema.nim     checks + name resolution      (over the tree, diagnosing)
#   desugar.nim  ast.NsNode -> Nim PNode       (the C#-to-Nim translation)

import std/[os, syncio]
import ../ast, ../idents, ../lineinfos, ../options, ../msgs, ../pathutils
import parser, symbols, sema, desugar, nsgen

proc isNsharpFile*(config: ConfigRef; fileIdx: FileIndex): bool =
  ## True when `fileIdx` names a `.ns` source file.
  let path = toFullPath(config, fileIdx)
  result = splitFile(path.string).ext == ".ns"

proc compileNsSource*(source: string; fileIdx: FileIndex; cache: IdentCache;
                      config: ConfigRef): PNode =
  ## The whole frontend: parse, collect declarations, check, lower. Exposed
  ## separately from `parseModule` so tools can drive it from a string.
  let module = parseNsModule(source, fileIdx, config)
  let scope = collectSymbols(module, config)
  checkModule(module, scope, config)
  result = lowerModule(module, scope, cache)

proc parseModule*(fileIdx: FileIndex; cache: IdentCache;
                  config: ConfigRef): PNode =
  ## Parses an `.ns` file into an `nkStmtList` of ordinary Nim `PNode`s.
  let path = toFullPath(config, fileIdx)
  ## Namespaces are resolved across files, so they must be discovered and
  ## generated before this module's imports are resolved. `parseModule` for the
  ## main module runs first, which is when the scan happens (it is idempotent).
  ensureNamespaces(config, cache, AbsoluteFile(path.string))
  var source = ""
  try:
    source = readFile(path.string)
  except CatchableError:
    localError(config, newLineInfo(fileIdx, 1, 1),
               "N#: cannot read " & path.string)
    return newNodeI(nkStmtList, newLineInfo(fileIdx, 1, 1))
  result = compileNsSource(source, fileIdx, cache, config)

