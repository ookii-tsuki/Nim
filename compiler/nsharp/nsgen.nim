# N# frontend - namespace modules
#
# Nim has one module per file, and a C# namespace spans files, so each namespace
# this compilation uses is emitted as one generated module, `<N>.nim`, which
# `using N;` imports: all of the namespace's files lowered together, its types in
# one type section and every routine forward declared, so the files may name each
# other's types and members in any order.
#
# C# namespaces may also use each other. Such namespaces form an import cycle,
# which the generated modules declare with `import "N" {.cyclic.}`: Nim then
# checks the types and routine declarations of the whole cycle before any body.
# Written to <nimcache>/.nsgen, which is added to the module search path.

import std/[os, syncio, algorithm, sets, tables, strutils]
import ../ast, ../idents, ../lineinfos, ../msgs, ../options, ../pathutils,
       ../renderer
import ast, bcl, diagnostics, parser, lexer, symbols, sema, desugar

const
  NsGenDirName* = ".nsgen"
  NsExt = ".ns"
  ## The declaration keywords that introduce a type name. `record` is a C# class
  ## with a generated shape, which N# rejects, but the name is a type either way.
  NsTypeKeywords = ["class", "struct", "interface", "enum", "delegate", "record"]

type
  NsUsingSite* = tuple[ns: string, info: TLineInfo, path: string]
    ## One `using` found by the token scan, with the file it appears in.

var namespacesGenerated = false
  ## `parseModule` runs for every module; the first call drives discovery.

var pendingAliases: seq[NsUsingSite]
  ## `using A = X.Y;` sites, decided once every file is scanned.

var namespaceModules: Table[string, seq[NsNode]]
  ## Parsed modules of each generated namespace, keyed by the namespace name, so a
  ## module that imports one can classify its types.

var qualifiedRefs: Table[string, HashSet[string]]
  ## For each file, the dotted names it writes (`Tools.Widget.Make`): one whose
  ## longest prefix naming a namespace is not the file's own reaches that
  ## namespace qualified, with no `using`, which C# allows (`reachedNamespace`).

proc reachedNamespace(chain: string; isNamespace: proc (s: string): bool): string =
  ## The namespace a dotted name is qualified with: its longest proper prefix that
  ## names one (`Demo.App` in `Demo.App.Thing`, not `Demo`), or "".
  result = ""
  var prefix = ""
  let parts = chain.split('.')
  for part in parts[0 .. ^2]:
    prefix = (if prefix.len == 0: part else: prefix & "." & part)
    if isNamespace(prefix): result = prefix

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
      if i + 1 < toks.len and toks[i + 1].kind == nsDot and
         (i == 0 or (toks[i - 1].kind != nsDot and not (toks[i - 1].kind == nsIdent and
          toks[i - 1].text in ["using", "namespace"]) and
          not (i >= 2 and toks[i - 1].kind == nsIdent and toks[i - 1].text == "static" and
               toks[i - 2].kind == nsIdent and toks[i - 2].text == "using") and
          not (i >= 2 and toks[i - 1].kind == nsAssign and toks[i - 2].kind == nsIdent and
               i >= 3 and toks[i - 3].kind == nsIdent and toks[i - 3].text == "using"))):
        ## A dotted name outside a directive (`using A.B;`, `namespace A.B`, `using
        ## P = A.B;`), which names the namespace in its own way.
        qualifiedRefs.mgetOrPut(path, initHashSet[string]()).incl dottedName(toks, i)
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
      elif t.text in ["using", "import"] and
           depth == (if open.len > 0: open[^1].depth else: 0):
        ## A directive sits at file or namespace level; a `using` in a method body
        ## is the statement. `using A = X.Y;` imports `X.Y`, so the target is what counts as used.
        var start = i + 1
        var isAlias = false
        var isStatic = false
        if start < toks.len and toks[start].kind == nsIdent and toks[start].text == "static":
          ## `using static N.T;` imports a type's statics: the namespace is `N`.
          isStatic = true
          inc start
        if start + 1 < toks.len and toks[start].kind == nsIdent and
           toks[start + 1].kind == nsAssign:
          isAlias = true
          start += 2
        let name = dottedName(toks, start)
        ## A generic target aliases a type rather than a namespace, and the parser
        ## reports that.
        var generic = false
        var k = start
        while k < toks.len and toks[k].kind notin {nsSemi, nsEof}:
          if toks[k].kind == nsLt: generic = true
          inc k
        let site = newLineInfo(fileIdx, t.line, t.col)
        if name.len > 0 and (isStatic or generic):
          ## The target is a type; its namespace is what is used.
          let dot = name.rfind('.')
          if dot > 0: sites.add (ns: name[0 ..< dot], info: site, path: path)
        elif name.len > 0 and isAlias:
          ## `using A = X.Y;` aliases a namespace or a type, which only the whole
          ## compilation's declarations tell apart (`resolveAliasSites`).
          pendingAliases.add (ns: name, info: site, path: path)
        elif name.len > 0:
          ## `using X.Y;` means the namespace `X.Y` exists, and a namespace name is
          ## reachable from every file once it does.
          noteDeclaredNamespace(name)
          sites.add (ns: name, info: site, path: path)
    else: discard
    inc i

proc collectUsings(n: NsNode;
                   into: var seq[tuple[ns: string, info: TLineInfo]]) =
  ## Every `using` in a module or namespace body, with the directive's location.
  for d in (if n.body != nil: n.body.sons else: n.sons):
    if d.kind == nsnUsing:
      if d.name.len > 0: into.add (d.name, d.info)
    elif d.kind == nsnNamespace:
      collectUsings(d, into)

proc namespaceCycles(modules: Table[string, seq[NsNode]];
                     qualified: Table[string, seq[string]]): Table[string, HashSet[string]] =
  ## For each namespace being generated, the others it shares an import cycle with:
  ## those it reaches through `using`s, or `qualified` (`Tools.Widget`), and that
  ## reach it back.
  var uses = initTable[string, seq[string]]()
  for ns in modules.keys:
    var u: seq[tuple[ns: string, info: TLineInfo]] = @[]
    for m in modules[ns]: collectUsings(m, u)
    var names: seq[string] = @[]
    for x in u:
      if modules.hasKey(x.ns) and x.ns != ns and x.ns notin names: names.add x.ns
    for q in qualified.getOrDefault(ns):
      if modules.hasKey(q) and q != ns and q notin names: names.add q
    uses[ns] = names
  proc reach(start: string): HashSet[string] =
    result = initHashSet[string]()
    var stack = @[start]
    while stack.len > 0:
      let ns = stack.pop()
      for u in uses.getOrDefault(ns):
        if u notin result:
          result.incl u
          stack.add u
  var reaches = initTable[string, HashSet[string]]()
  for ns in modules.keys: reaches[ns] = reach(ns)
  result = initTable[string, HashSet[string]]()
  for ns in modules.keys:
    var peers = initHashSet[string]()
    for other in reaches[ns]:
      if other != ns and ns in reaches[other]: peers.incl other
    result[ns] = peers

proc markCyclicImports(n: PNode; peers: HashSet[string]; cache: IdentCache) =
  ## `import "N"` of a namespace in this one's cycle becomes
  ## `import "N" {.cyclic.}`.
  if peers.len == 0: return
  var paths = initHashSet[string]()
  for p in peers: paths.incl namespaceModulePath(p)
  for s in n:
    if s.kind notin {nkImportStmt, nkImportExceptStmt}: continue
    for k in 0 ..< (if s.kind == nkImportExceptStmt: 1 else: s.len):
      let x = s[k]
      if x.kind in {nkStrLit, nkRStrLit, nkTripleStrLit} and x.strVal in paths:
        s[k] = newTree(nkPragmaExpr, x.info, x,
                       newTree(nkPragma, x.info, newIdentNode(getIdent(cache, "cyclic"), x.info)))

proc symbolsOf(m: NsNode; config: ConfigRef): NsModuleScope =
  ## A file's own declarations, collected afresh: collecting merges a partial
  ## class's parts into its first declaration, so what an earlier module saw may
  ## lack the parts of another file.
  collectSymbols(m, config)

proc mergeNamespace(into, s: NsModuleScope; skip: HashSet[string] = initHashSet[string]()) =
  ## Another file's declarations joining a module's scope; a name already there is
  ## the module's own, and `skip` stays out.
  for k, v in s.classes:
    if k notin skip and not into.classes.hasKey(k): into.classes[k] = v
  for k, v in s.delegates:
    if k notin skip and not into.delegates.hasKey(k): into.delegates[k] = v
  for e in s.enums:
    if e notin skip:
      into.enums.incl e
      if s.enumBases.hasKey(e): into.enumBases[e] = s.enumBases[e]
  for k, v in s.enumMembers:
    if k notin skip and not into.enumMembers.hasKey(k): into.enumMembers[k] = v
  for e in s.libIfaces: into.libIfaces.incl e
  for e in s.libValueIfaces: into.libValueIfaces.incl e
  for q in s.namespaces: into.namespaces.incl q

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
      let s = symbolsOf(m, config)
      result.mergeNamespace(s)
      for u in s.usings: pending.add u
  ## Namespaces reached only qualified (`Tools.Widget`): their types join the scope,
  ## so they are classified, but are reachable only qualified (`qualifiedTypes`); one
  ## named like a type already in scope or the library's stays out
  ## (`qualifiedOnly`). The namespaces they `using` are not this module's.
  var own = initHashSet[string]()
  proc noteOwn(n: NsNode) =
    if n.kind == nsnNamespace:
      own.incl n.name
      if n.body != nil:
        for d in n.body.sons: noteOwn(d)
  for d in module.sons: noteOwn(d)
  var files = initHashSet[string]()
  for d in module.sons: files.incl toFullPath(config, d.info)
  var reached: seq[string] = @[]
  proc isNamespace(s: string): bool = isDeclaredNamespace(s)
  for f in files:
    for chain in qualifiedRefs.getOrDefault(f):
      let q = reachedNamespace(chain, isNamespace)
      if q.len > 0 and namespaceModules.hasKey(q) and q notin seen and q notin own and
         q notin reached:
        reached.add q
  reached.sort()
  let surface = bclSurface(config)
  for ns in reached:
    result.qualifiedNs.add ns
    ## An enclosing namespace of the module's own (`Tools` of `Tools.App`) is in
    ## scope bare, as C# has it.
    var ownAncestor = false
    for o in own:
      if o.startsWith(ns & "."): ownAncestor = true
    var prefix = ""
    for part in ns.split('.'):
      prefix = (if prefix.len == 0: part else: prefix & "." & part)
      result.namespaces.incl prefix
    var clashing = initHashSet[string]()
    for m in namespaceModules[ns]:
      let s = symbolsOf(m, config)
      var names: seq[string] = @[]
      for k in s.classes.keys: names.add k
      for k in s.delegates.keys: names.add k
      for e in s.enums: names.add e
      for k in names:
        if result.classes.hasKey(k) or result.delegates.hasKey(k) or
           k in result.enums or surface.isLibraryTypeName(k):
          clashing.incl k
          result.qualifiedOnly[ns & "." & k] = s.classes.getOrDefault(k, NsClassSymbol(name: k))
          ## Its nested types (`Tools.Console.Inner`), reached through it.
          for nk, nv in s.classes:
            if nv.enclosing == k: result.qualifiedOnly[ns & "." & k & "." & nk] = nv
        elif not ownAncestor:
          result.qualifiedTypes.incl k
      result.mergeNamespace(s, clashing)
    var excluded: seq[string] = @[]
    for k in clashing: excluded.add k
    excluded.sort()
    result.qualifiedExcept[ns] = excluded
  result.resolveBases()

proc generateNamespace(config: ConfigRef; cache: IdentCache; nsPath, genDir: string;
                       files: seq[NsNode]; peers: HashSet[string]) =
  ## Lowers all of the namespace's files as one module. `peers` are the namespaces
  ## it shares an import cycle with.
  let info = files[0].info
  ## Merging the files' declarations gives the namespace one scope.
  var merged = nsn(nsnModule, info)
  for m in files:
    for d in m.sons: merged.add d

  let scope = collectWithNamespaces(merged, config)
  checkModule(merged, scope, config)
  ## `lowerModule` puts every type in one type section and forward declares every
  ## routine, so a method in one file of the namespace may call one in another.
  let module = lowerModule(merged, scope, cache, config)
  markCyclicImports(module, peers, cache)

  ## Gives a member with no statements an explicit `discard`, since an empty body
  ## renders as invalid Nim.
  for i in 0 ..< module.len:
    let s = module[i]
    if s.kind == nkProcDef and s[6] != nil and s[6].kind == nkStmtList and
       s[6].len == 0:
      let sl = newNodeI(nkStmtList, s.info)
      sl.add newTree(nkDiscardStmt, s.info, newNodeI(nkEmpty, s.info))
      s[6] = sl

  let fid = files[0].info.fileIndex
  ## A dotted namespace maps to subdirectories.
  let nsSub = splitFile(nsPath).dir
  if nsSub.len > 0: createDir(AbsoluteDir(genDir / nsSub))
  ## Private fields too: a field not exported is still the class's.
  renderModule(module, genDir / (nsPath & ".nim"), {renderNonExportedFields}, fid, config)

proc ensureNamespaces*(config: ConfigRef; cache: IdentCache;
                       mainPath: AbsoluteFile) =
  ## Discovers the namespaces near the main module and, for each one that is
  ## actually named by a `using`, generates its module and puts
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
  ## An alias of a declared or library type uses the type's namespace; any other
  ## names a namespace.
  let surface = bclSurface(config)
  for a in pendingAliases:
    let last = a.ns.split('.')[^1]
    if not isDeclaredNamespace(a.ns) and
       (isDeclaredType(last) or surface.isKnownTypeName(last)):
      let dot = a.ns.rfind('.')
      if dot > 0: sites.add (ns: a.ns[0 ..< dot], info: a.info, path: a.path)
    else:
      noteDeclaredNamespace(a.ns)
      sites.add a
  pendingAliases = @[]

  let genDir = getNimcacheDir(config).string / NsGenDirName
  createDir(AbsoluteDir(genDir))
  ## Added ahead of the search path so a generated namespace module is found.
  config.searchPaths.insert(AbsoluteDir(genDir), 0)

  ## Only the namespaces this compilation pulls in are parsed and generated,
  ## starting from the main module's own `using`s. The tree may hold `.ns` files
  ## that belong to other compilations, and those are neither reported on nor
  ## generated.
  var pending: seq[string] = @[]
  for s in sites:
    if s.path == mainPath.string and s.ns in declared: pending.add s.ns
  proc isDeclared(s: string): bool = s in declared
  proc reachedFrom(path: string): seq[string] =
    ## What a file reaches qualified: not a namespace it declares itself.
    for chain in qualifiedRefs.getOrDefault(path):
      let q = reachedNamespace(chain, isDeclared)
      if q.len > 0 and path notin declared[q] and q notin result: result.add q
  for q in reachedFrom(mainPath.string): pending.add q
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
    for path in declared[ns]:
      for q in reachedFrom(path):
        if not namespaceModules.hasKey(q): pending.add q

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

  ## Namespaces that use each other are one import cycle.
  var qualified = initTable[string, seq[string]]()
  for ns in namespaceModules.keys:
    for path in declared[ns]:
      for q in reachedFrom(path): qualified.mgetOrPut(ns, @[]).add q
  let cycles = namespaceCycles(namespaceModules, qualified)

  ## Every namespace is parsed before any is generated, so classifying one does not
  ## depend on generation order.
  var toGenerate: seq[string] = @[]
  for ns in namespaceModules.keys:
    ## A sibling `<N>.ns` is the module `import "N"` finds beside the main one, so
    ## none is generated, nor kept from an earlier build: every module imports
    ## that file (`siblingNamespaces`).
    let sibling = root / namespaceFilePath(ns)
    if namespaceModules[ns].len > 0 and not fileExists(sibling & ".ns"): toGenerate.add ns
    else:
      removeFile(genDir / (namespaceFilePath(ns) & ".nim"))
      if fileExists(sibling & ".ns"): siblingNamespaces[ns] = sibling
  toGenerate.sort()
  for ns in toGenerate:
    generateNamespace(config, cache, namespaceModulePath(ns), genDir,
                      namespaceModules[ns], cycles.getOrDefault(ns))
