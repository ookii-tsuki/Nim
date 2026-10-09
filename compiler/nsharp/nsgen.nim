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
import ast, bcl, diagnostics, parser, lexer, symbols, sema, desugar

const
  NsGenDirName = ".nsgen"
  NsExt = ".ns"
  ## The declaration keywords that introduce a type name. `record` is a C# class
  ## with a generated shape, which N# rejects, but the name is a type either way.
  NsTypeKeywords = ["class", "struct", "interface", "enum", "delegate", "record"]

type
  NsUsingSite* = tuple[ns: string, info: TLineInfo, path: string]
    ## One `using` found by the token scan, with the file it appears in.

var namespacesGenerated = false
  ## `parseModule` runs for every module; the first call drives discovery.

var namespaceModules: Table[string, seq[NsNode]]
  ## Parsed modules of each generated namespace, keyed by the namespace name, so a
  ## module that imports one can classify its types.

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

proc noteTypeDecl(toks: seq[NsToken]; i: int) =
  ## Records the name a type declaration introduces. The parser has no symbol table
  ## of its own -- it runs per file, before anything is collected -- so the names the
  ## compilation declares are gathered here, where every file is seen, and looked up
  ## when a cast is told from a parenthesised expression.
  if i + 1 >= toks.len or toks[i + 1].kind != nsIdent: return
  var j = i + 1
  ## `delegate` is the one declaration with the return type in between, so its name
  ## is the identifier after that.
  if toks[i].text == "delegate" and j + 1 < toks.len and
     toks[j + 1].kind == nsIdent:
    inc j
  if toks[j].text notin NsTypeKeywords: noteDeclaredType(toks[j].text)

proc scanFile(source: string; path: string; fileIdx: FileIndex;
              namespaces: var seq[string]; sites: var seq[NsUsingSite]) =
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
          ## A namespace name is global in C#, so it is recorded compilation-wide:
          ## `Demo.Gadget.Create()` and `(Demo.Gadget)x` resolve from any file.
          noteDeclaredNamespace(name)
          var j = i + 1
          while j < toks.len and toks[j].kind notin {nsLBrace, nsSemi, nsEof}:
            inc j
          if j < toks.len and toks[j].kind == nsLBrace:
            open.add (name, depth + 1)
            i = j
            continue
      elif t.text in NsTypeKeywords:
        noteTypeDecl(toks, i)
      elif t.text in ["using", "import"]:
        ## `using A = X.Y;` imports `X.Y`, so the target is what counts as used.
        var start = i + 1
        if start + 1 < toks.len and toks[start].kind == nsIdent and
           toks[start + 1].kind == nsAssign:
          start += 2
        let name = dottedName(toks, start)
        ## A generic target aliases a type rather than a namespace, and the parser
        ## reports that.
        var generic = false
        var k = start
        while k < toks.len and toks[k].kind notin {nsSemi, nsEof}:
          if toks[k].kind == nsLt: generic = true
          inc k
        if name.len > 0 and not generic:
          ## `using X.Y;` means the namespace `X.Y` exists, and a namespace name is
          ## reachable from every file once it does.
          noteDeclaredNamespace(name)
          sites.add (ns: name, info: newLineInfo(fileIdx, t.line, t.col),
                     path: path)
    else: discard
    inc i

proc baseName(nsPath: string): string =
  splitFile(nsPath).name

proc collectUsings(n: NsNode;
                   into: var seq[tuple[ns: string, info: TLineInfo]]) =
  ## Every `using` in a module or namespace body, with the directive's location.
  for d in (if n.body != nil: n.body.sons else: n.sons):
    if d.kind == nsnUsing:
      if d.name.len > 0: into.add (d.name, d.info)
    elif d.kind == nsnNamespace:
      collectUsings(d, into)

proc reportNamespaceCycle(config: ConfigRef;
                          modules: Table[string, seq[NsNode]]) =
  ## Reports the first cycle among the namespaces being generated. A generated
  ## declaration half imports the other namespace's barrel, so a cycle between two
  ## of them cannot be compiled.
  var uses = initTable[string, seq[tuple[ns: string, info: TLineInfo]]]()
  for ns in modules.keys:
    var u: seq[tuple[ns: string, info: TLineInfo]] = @[]
    for m in modules[ns]: collectUsings(m, u)
    uses[ns] = u
  var state = initTable[string, int]()
  proc visit(ns: string): bool =
    state[ns] = 1
    for u in uses.getOrDefault(ns):
      if not modules.hasKey(u.ns): continue
      case state.getOrDefault(u.ns)
      of 1:
        nsError(config, u.info, ndNamespaceCycle, ns, u.ns)
        return true
      of 0:
        if visit(u.ns): return true
      else: discard
    state[ns] = 2
    false
  for ns in modules.keys:
    if state.getOrDefault(ns) == 0 and visit(ns): return

proc writeBarrel(genDir, nsPath: string) =
  ## Writes the namespace's public module. The two halves are named by their bare
  ## file name, which the barrel resolves in its own directory.
  let base = baseName(nsPath)
  let content = "import " & base & "_decl\n" &
                "export " & base & "_decl\n" &
                "import " & base & "_impl\n" &
                "export " & base & "_impl\n"
  writeFile(AbsoluteFile(genDir / nsPath & ".nim"), content)

proc collectWithNamespaces*(module: NsNode; config: ConfigRef): NsModuleScope =
  ## Declaration collection for a module, extended with the declarations of the
  ## namespaces it imports. Classification needs them: a type declared by another
  ## file is otherwise unknown, so `/` stays floating point and `.Count` does not
  ## resolve to the collection the library declares it on.
  result = collectSymbols(module, config)
  var seen = initHashSet[string]()
  var pending = result.usings
  while pending.len > 0:
    let ns = pending.pop()
    if ns in seen: continue
    seen.incl ns
    for m in namespaceModules.getOrDefault(ns):
      let s = collectSymbols(m, config)
      for k, v in s.classes:
        if not result.classes.hasKey(k): result.classes[k] = v
      for k, v in s.delegates:
        if not result.delegates.hasKey(k): result.delegates[k] = v
      for e in s.enums: result.enums.incl e
      for e in s.libIfaces: result.libIfaces.incl e
      for q in s.namespaces: result.namespaces.incl q
      for u in s.usings: pending.add u
  result.resolveBases()

proc generateNamespace(config: ConfigRef; cache: IdentCache; nsPath, genDir: string;
                       files: seq[NsNode]) =
  ## Lowers all of the namespace's files as one module, then splits the result.
  let info = files[0].info
  ## Merging the files' declarations gives the namespace one scope.
  var merged = nsn(nsnModule, info)
  for m in files:
    for d in m.sons: merged.add d

  let scope = collectWithNamespaces(merged, config)
  checkModule(merged, scope, config)
  let parts = splitModuleOutput(lowerModule(merged, scope, cache, config))

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

  ## Imports precede the forward declarations, which may name imported types.
  for i in 0 ..< parts.impls.len:
    if isImportStmt(parts.impls[i]):
      impls.add parts.impls[i]

  ## Gives a member with no statements an explicit `discard`, since an empty body
  ## renders as invalid Nim.
  for i in 0 ..< parts.impls.len:
    let s = parts.impls[i]
    if s.kind == nkProcDef and s[6] != nil and s[6].kind == nkStmtList and
       s[6].len == 0:
      let sl = newNodeI(nkStmtList, s.info)
      sl.add newTree(nkDiscardStmt, s.info, newNodeI(nkEmpty, s.info))
      s[6] = sl

  ## `lowerModule` already forward declares every routine, so a method in one file
  ## of the namespace may call one defined in another.
  for i in 0 ..< parts.impls.len:
    if not isImportStmt(parts.impls[i]):
      impls.add parts.impls[i]

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
  var sites: seq[NsUsingSite] = @[]
  var nsFiles = initHashSet[string]()
  for path in paths:
    nsFiles.incl splitFile(path).name
    var source = ""
    try:
      source = readFile(path)
    except CatchableError:
      continue
    var names: seq[string] = @[]
    scanFile(source, path, config.fileInfoIdx(AbsoluteFile(path)), names, sites)
    for ns in names:
      declared.mgetOrPut(ns, @[]).add path

  let genDir = getNimcacheDir(config).string / NsGenDirName
  createDir(AbsoluteDir(genDir))
  ## Added ahead of the search path so a generated barrel is found.
  config.searchPaths.insert(AbsoluteDir(genDir), 0)

  ## Only the namespaces this compilation pulls in are parsed and generated,
  ## starting from the main module's own `using`s. The tree may hold `.ns` files
  ## that belong to other compilations, and those are neither reported on nor
  ## generated.
  var pending: seq[string] = @[]
  for s in sites:
    if s.path == mainPath.string and s.ns in declared: pending.add s.ns
  while pending.len > 0:
    let ns = pending.pop()
    if namespaceModules.hasKey(ns): continue
    ## Parsing happens here, so diagnostics come only from namespaces this
    ## compilation pulls in.
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
    namespaceModules[ns] = mods
    var uses: seq[tuple[ns: string, info: TLineInfo]] = @[]
    for m in mods: collectUsings(m, uses)
    for u in uses:
      if u.ns in declared and not namespaceModules.hasKey(u.ns):
        pending.add u.ns

  ## A `using` this compilation owns must name a namespace declared in the tree or
  ## a module, which is what C# reports as CS0246.
  var owned = initHashSet[string]()
  owned.incl mainPath.string
  for ns in namespaceModules.keys:
    for p in declared[ns]: owned.incl p
  for s in sites:
    if s.path notin owned: continue
    if s.ns in declared or s.ns in nsFiles: continue
    if findModule(config, namespaceModulePath(s.ns), mainPath.string).isEmpty:
      nsError(config, s.info, ndNamespaceNotFound, s.ns)

  reportNamespaceCycle(config, namespaceModules)

  ## Every namespace is parsed before any is generated, so classifying one does not
  ## depend on generation order.
  var toGenerate: seq[string] = @[]
  for ns in namespaceModules.keys:
    if namespaceModules[ns].len > 0: toGenerate.add ns
  toGenerate.sort()
  for ns in toGenerate:
    generateNamespace(config, cache, namespaceModulePath(ns), genDir,
                      namespaceModules[ns])
