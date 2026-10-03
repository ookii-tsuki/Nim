# N# frontend - namespace modules
#
# Nim has one module per file and rejects mutual imports, so a C# namespace, which
# spans files, is emitted as three generated modules:
#
#   <N>_decl.nim   its types, in one type section
#   <N>_impl.nim   its procs, forward declared first
#   <N>.nim        barrel importing and re-exporting both, which `using N;` resolves
#
# One module per namespace lets a method in one file call one in another; one type
# section lets the files' types reference each other. Written to <nimcache>/.nsgen,
# which is added to the module search path.

import std/[os, syncio, algorithm, sets, tables]
import ../ast, ../idents, ../lineinfos, ../msgs, ../options, ../pathutils,
       ../renderer
import ast, bcl, parser, lexer, symbols, sema, desugar

const
  NsGenDirName = ".nsgen"
  NsExt = ".ns"
  ## Root of the N# namespace tree, where a file's path is its C# namespace.
  NsLibRoot = "pure/ns"

var namespacesGenerated = false
  ## `parseModule` runs for every module; the first call drives discovery.

proc declaringNamespaces(ns: NsNode; name: string; names: var seq[string]) =
  ## Appends `name` if the namespace declares anything itself, then recurses into
  ## nested blocks. `namespace A { namespace B { } }` declares into `A.B`.
  var nested: seq[NsNode] = @[]
  var declares = false
  if ns.body != nil:
    for d in ns.body.sons:
      case d.kind
      of nsnNamespace: nested.add d
      of nsnUsing, nsnEmpty: discard
      else: declares = true
  if declares: names.add name
  for d in nested: declaringNamespaces(d, d.name, names)

proc namespaceOf(module: NsNode): string =
  ## The single namespace the file declares into, or "". A file that spans several
  ## namespaces, or declares outside one, is compiled on its own.
  var names: seq[string] = @[]
  for d in module.sons:
    case d.kind
    of nsnNamespace: declaringNamespaces(d, d.name, names)
    of nsnUsing, nsnEmpty: discard
    else:
      return ""   # declarations outside any namespace: not a namespace file
  if names.len != 1: return ""
  names[0]

proc collectNsFiles(root: string): seq[string] =
  ## Every `.ns` file under `root`, recursively, skipping the generated dir.
  result = @[]
  for kind, path in walkDir(root):
    if kind == pcDir:
      if splitFile(path).name == NsGenDirName: continue
      result.add collectNsFiles(path)
    elif kind == pcFile and splitFile(path).ext == NsExt:
      result.add path

proc dottedName(toks: seq[NsToken]; start: int): string =
  ## `A.B.C` from `start`, or "" when there is no identifier there.
  result = ""
  var j = start
  if j < toks.len and toks[j].kind == nsIdent:
    result.add toks[j].text
    inc j
    while j + 1 < toks.len and toks[j].kind == nsDot and
          toks[j+1].kind == nsIdent:
      result.add "."
      result.add toks[j+1].text
      j += 2

proc scanFile(source: string; namespaces: var seq[string];
              usings: var HashSet[string]) =
  ## Collects the `namespace` and `using` names in a file by scanning its tokens.
  ## Scanning avoids diagnosing a file that may not belong to this compilation.
  ## Brace depth marks the end of a namespace block, so a method body's braces do
  ## not close it, and nested blocks compose into one dotted name.
  let toks = tokenize(source)
  var open: seq[tuple[name: string, depth: int]] = @[]
  var depth = 0
  var i = 0
  while i < toks.len:
    let t = toks[i]
    case t.kind
    of nsLBrace:
      inc depth
    of nsRBrace:
      if open.len > 0 and open[^1].depth == depth: open.setLen(open.len - 1)
      dec depth
    of nsIdent:
      if t.text == "namespace":
        var name = dottedName(toks, i + 1)
        if name.len > 0:
          if open.len > 0: name = open[^1].name & "." & name
          namespaces.add name
          var j = i + 1
          while j < toks.len and toks[j].kind notin {nsLBrace, nsSemi, nsEof}:
            inc j
          if j < toks.len and toks[j].kind == nsLBrace:
            open.add (name, depth + 1)
            i = j
            continue
      elif t.text in ["using", "import"]:
        let name = dottedName(toks, i + 1)
        if name.len > 0: usings.incl name
    else: discard
    inc i

proc baseName(nsPath: string): string =
  splitFile(nsPath).name

proc writeBarrel(genDir, nsPath: string) =
  ## Writes the namespace's public module. The two halves are named by their bare
  ## file name, which the barrel resolves in its own directory.
  let base = baseName(nsPath)
  let content = "import " & base & "_decl\n" &
                "export " & base & "_decl\n" &
                "import " & base & "_impl\n" &
                "export " & base & "_impl\n"
  writeFile(AbsoluteFile(genDir / nsPath & ".nim"), content)

proc generateNamespace(config: ConfigRef; cache: IdentCache; nsPath, genDir: string;
                       files: seq[NsNode]) =
  ## Lowers all of the namespace's files as one module, then splits the result.
  let info = files[0].info
  ## Merging the files' declarations gives the namespace one scope.
  var merged = nsn(nsnModule, info)
  for m in files:
    for d in m.sons: merged.add d

  let scope = collectSymbols(merged, config)
  checkModule(merged, scope, config)
  let parts = splitModuleOutput(lowerModule(merged, scope, cache))

  ## All types in one type section: Nim resolves mutually recursive types only
  ## within a single section, and the files' types may reference each other.
  var decls = newNodeI(nkStmtList, info)
  var typeSec = newNodeI(nkTypeSection, info)
  for i in 0 ..< parts.decls.len:
    let s = parts.decls[i]
    if s.kind == nkTypeSection:
      for j in 0 ..< s.len: typeSec.add s[j]
    else:
      decls.add s
  if typeSec.len > 0: decls.add typeSec

  ## The implementation half names the types, so it imports the declaration half.
  var impls = newNodeI(nkStmtList, info)
  let declImport = newNodeI(nkImportStmt, info)
  declImport.add newAtom(nkStrLit, baseName(nsPath) & "_decl", info)
  impls.add declImport

  ## Gives a member with no statements an explicit `discard`, since an empty body
  ## renders as invalid Nim.
  for i in 0 ..< parts.impls.len:
    let s = parts.impls[i]
    if s.kind == nkProcDef and s[6] != nil and s[6].kind == nkStmtList and
       s[6].len == 0:
      let sl = newNodeI(nkStmtList, s.info)
      sl.add newTree(nkDiscardStmt, s.info, newNodeI(nkEmpty, s.info))
      s[6] = sl

  ## Forward declares every proc, which lets a method in one file of the namespace
  ## call one defined in another. Bodies are emptied copies.
  for i in 0 ..< parts.impls.len:
    let s = parts.impls[i]
    if s.kind == nkProcDef:
      let fwd = copyTree(s)
      fwd[6] = newNodeI(nkEmpty, s.info)
      impls.add fwd
  for i in 0 ..< parts.impls.len: impls.add parts.impls[i]

  let fid = files[0].info.fileIndex
  ## A dotted namespace maps to subdirectories.
  let nsSub = splitFile(nsPath).dir
  if nsSub.len > 0: createDir(AbsoluteDir(genDir / nsSub))
  renderModule(decls, genDir / (nsPath & "_decl.nim"), {}, fid, config)
  renderModule(impls, genDir / (nsPath & "_impl.nim"), {}, fid, config)
  writeBarrel(genDir, nsPath)

proc ensureNamespaces*(config: ConfigRef; cache: IdentCache;
                       mainPath: AbsoluteFile) =
  ## Discovers the namespaces near the main module and, for each one that is
  ## actually named by a `using`, generates its decl/impl/barrel modules and puts
  ## the generated directory on the module search path. Idempotent.
  if namespacesGenerated: return
  namespacesGenerated = true

  ## `using System;` becomes `import "System"`, so the namespace root goes on the
  ## search path ahead of `conf.libpath`, whose `system.nim` a case-insensitive
  ## filesystem could otherwise match.
  let nsLibRoot = AbsoluteDir(config.libpath.string / NsLibRoot)
  if not config.searchPaths.contains(nsLibRoot):
    config.searchPaths.insert(nsLibRoot, 0)

  let root = splitFile(mainPath.string).dir
  if root.len == 0: return
  var paths = collectNsFiles(root)
  paths.sort()   # deterministic output regardless of directory order
  if paths.len == 0: return

  ## Discovery scans tokens, so a file in the tree that does not parse cannot stop
  ## the compilation. A namespace only has to be found, not checked.
  var declared = initTable[string, seq[string]]()
  var used = initHashSet[string]()
  for path in paths:
    var source = ""
    try:
      source = readFile(path)
    except CatchableError:
      continue
    var names: seq[string] = @[]
    scanFile(source, names, used)
    for ns in names:
      declared.mgetOrPut(ns, @[]).add path

  var toGenerate: seq[string] = @[]
  for ns in declared.keys:
    if ns in used: toGenerate.add ns
  if toGenerate.len == 0: return
  toGenerate.sort()

  let genDir = getNimcacheDir(config).string / NsGenDirName
  createDir(AbsoluteDir(genDir))
  ## Added ahead of the search path so a generated barrel is found.
  config.searchPaths.insert(AbsoluteDir(genDir), 0)

  for ns in toGenerate:
    ## Parsing happens here so diagnostics come only from namespaces being compiled.
    var mods: seq[NsNode] = @[]
    for path in declared[ns]:
      var source = ""
      try:
        source = readFile(path)
      except CatchableError:
        continue
      let fid = config.fileInfoIdx(AbsoluteFile(path))
      let m = parseNsModule(source, fid, config)
      if namespaceOf(m) == ns: mods.add m
    if mods.len > 0:
      generateNamespace(config, cache, namespaceModulePath(ns), genDir, mods)
