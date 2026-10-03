# N# frontend - namespace modules
#
# A C# namespace is not a file: any number of files may declare `namespace UI`,
# and code in one of them may freely name the others' types and members. Nim has
# one module per file and rejects mutually importing modules, so a namespace
# spanning files cannot be compiled as those files directly.
#
# Instead each used namespace is emitted as three generated Nim modules:
#
#   <N>_decl.nim   every type declared by <N>'s files, in one type section
#   <N>_impl.nim   every proc declared by <N>'s files   (imports <N>_decl)
#   <N>.nim        the barrel: imports and re-exports both   <- what `using N` gets
#
# Concatenating all of a namespace's implementations into the single <N>_impl
# module is what makes a method in one file able to call one in another: they are
# plain procs in the same module, so Nim's within-module forward references apply.
# The same holds for types in <N>_decl, where Nim resolves mutually recursive
# types inside one type section.
#
# The decl/impl split also breaks a common cross-namespace cycle: if A's methods
# use B's types and B's methods use A's types, then A_impl imports only B_decl and
# B_impl imports only A_decl, which is acyclic. (Mutual *type* references across
# namespaces still cycle; that is a documented limitation.)
#
# The split is not expressible in N# itself (there is no re-export and no way to
# separate a type from its procs in source), which is why the generated files are
# Nim, rendered from the lowered `PNode`s.
#
# Resolution: the generated directory goes in front of the module search path, so
# `using N;` - which lowers to `import "N"` - finds `<N>.nim` there.

import std/[os, syncio, algorithm, sets, tables]
import ../ast, ../idents, ../lineinfos, ../msgs, ../options, ../pathutils,
       ../renderer
import ast, parser, lexer, symbols, sema, desugar

const
  NsGenDirName = ".nsgen"
  NsExt = ".ns"

var namespacesGenerated = false
  ## Generation runs once per compiler process; `parseModule` is called for every
  ## module, and only the first call (the main module) drives discovery.

proc namespaceOf(module: NsNode): string =
  ## The one namespace a file declares, or "" when the file declares none, more
  ## than one, or anything outside a namespace. Only the plain case - a file that
  ## holds exactly one `namespace X { ... }` block plus `using`s - is grouped.
  ## Dotted names never reach the filesystem, so they are not grouped either.
  result = ""
  var count = 0
  for d in module.sons:
    case d.kind
    of nsnNamespace:
      inc count
      result = d.name
    of nsnUsing, nsnEmpty: discard
    else:
      return ""   # declarations outside any namespace: not a namespace file
  if count != 1 or '.' in result: return ""

proc collectNsFiles(root: string): seq[string] =
  ## Every `.ns` file under `root`, recursively, skipping the generated dir.
  result = @[]
  for kind, path in walkDir(root):
    if kind == pcDir:
      if splitFile(path).name == NsGenDirName: continue
      result.add collectNsFiles(path)
    elif kind == pcFile and splitFile(path).ext == NsExt:
      result.add path

proc scanFile(source: string; namespaces: var seq[string];
              usings: var HashSet[string]) =
  ## Token-level discovery of `namespace X` and `using X` at any nesting depth.
  ## Deliberately not a parse: discovery must not diagnose, because a file that is
  ## not part of this compilation may be malformed, and a namespace only has to be
  ## *found* before we know whether it is used. Strings and comments are already
  ## gone by the time tokens exist, so `"namespace"` in a literal cannot match.
  let toks = tokenize(source)
  var i = 0
  while i < toks.len:
    let t = toks[i]
    if t.kind == nsIdent and (t.text == "namespace" or
                              t.text in ["using", "import"]):
      var name = ""
      var j = i + 1
      if j < toks.len and toks[j].kind == nsIdent:
        name.add toks[j].text
        inc j
        while j + 1 < toks.len and toks[j].kind == nsDot and
              toks[j+1].kind == nsIdent:
          name.add "."
          name.add toks[j+1].text
          j += 2
      if name.len > 0:
        if t.text == "namespace": namespaces.add name
        else: usings.incl name
      i = j
    else:
      inc i

proc writeBarrel(genDir, ns: string) =
  ## The public entry point of a namespace: a real Nim module that a `.nim`
  ## consumer could import too. Built by concatenation rather than `add` calls,
  ## which would be ambiguous with `ast.add`.
  let content = "import " & ns & "_decl\n" &
                "export " & ns & "_decl\n" &
                "import " & ns & "_impl\n" &
                "export " & ns & "_impl\n"
  writeFile(AbsoluteFile(genDir & "/" & ns & ".nim"), content)

proc generateNamespace(config: ConfigRef; cache: IdentCache; ns, genDir: string;
                       files: seq[NsNode]) =
  ## Lowers all of `ns`'s files as one module, then splits the result.
  let info = files[0].info
  ## The merged module is the concatenation of the files' top-level declarations:
  ## each is `using`s plus a `namespace N { ... }` block, and lowering flattens
  ## the block, so the namespace ends up with one combined scope.
  var merged = nsn(nsnModule, info)
  for m in files:
    for d in m.sons: merged.add d

  let scope = collectSymbols(merged, config)
  checkModule(merged, scope, config)
  let parts = splitModuleOutput(lowerModule(merged, scope, cache))

  ## The declaration half: the imports, then every type in ONE type section. One
  ## section matters because Nim only resolves mutually recursive types inside a
  ## single section, and two of the namespace's files may name each other's types.
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
  declImport.add newAtom(nkStrLit, ns & "_decl", info)
  impls.add declImport

  ## An empty body renders as nothing, which is not valid Nim; a member with no
  ## statements (`{}`, or a generated `init`) gets an explicit `discard`.
  for i in 0 ..< parts.impls.len:
    let s = parts.impls[i]
    if s.kind == nkProcDef and s[6] != nil and s[6].kind == nkStmtList and
       s[6].len == 0:
      let sl = newNodeI(nkStmtList, s.info)
      sl.add newTree(nkDiscardStmt, s.info, newNodeI(nkEmpty, s.info))
      s[6] = sl

  ## Every proc is forward declared first. Inside one module a call to a proc
  ## defined further down needs a witness, and that is exactly the cross-file case
  ## this module exists for: a method in one of the namespace's files calling one
  ## defined in another. The declarations are copies with the body emptied.
  for i in 0 ..< parts.impls.len:
    let s = parts.impls[i]
    if s.kind == nkProcDef:
      let fwd = copyTree(s)
      fwd[6] = newNodeI(nkEmpty, s.info)
      impls.add fwd
  for i in 0 ..< parts.impls.len: impls.add parts.impls[i]

  let fid = files[0].info.fileIndex
  renderModule(decls, genDir / (ns & "_decl.nim"), {}, fid, config)
  renderModule(impls, genDir / (ns & "_impl.nim"), {}, fid, config)
  writeBarrel(genDir, ns)

proc ensureNamespaces*(config: ConfigRef; cache: IdentCache;
                       mainPath: AbsoluteFile) =
  ## Discovers the namespaces near the main module and, for each one that is
  ## actually named by a `using`, generates its decl/impl/barrel modules and puts
  ## the generated directory on the module search path. Idempotent.
  if namespacesGenerated: return
  namespacesGenerated = true

  let root = splitFile(mainPath.string).dir
  if root.len == 0: return
  var paths = collectNsFiles(root)
  paths.sort()   # deterministic output regardless of directory order
  if paths.len == 0: return

  ## Discovery is a token scan, not a parse: an unrelated `.ns` file in the tree
  ## that does not parse must not break this compilation, and a namespace only
  ## has to be found, not checked, before we know whether it is used at all.
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
  ## In front of the search path, so a generated barrel is found; a same-named
  ## sibling `.ns` file still wins (see the note in `findModule`).
  config.searchPaths.insert(AbsoluteDir(genDir), 0)

  for ns in toGenerate:
    ## Only now are the declaring files parsed for real, so a diagnostic can only
    ## come from a file that is actually part of a namespace being compiled.
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
      generateNamespace(config, cache, ns, genDir, mods)
