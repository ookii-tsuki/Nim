# N# frontend: C#'s type vocabulary, and the surface of the N# prelude.
#
# C#'s vocabulary is the language's, whatever any library declares. The surface is
# read from the prelude's own Nim sources, so no member name is hardcoded here.

import std/[os, syncio, strutils, sets, tables, algorithm]
import ../ast, ../idents, ../lineinfos, ../msgs, ../options, ../pathutils
import ../parser as nimparser
import ast

type
  NsRename* = tuple[cs: string, nim: string]

  NsTypeEntry* = tuple[nim: string, kind: NsTypeKind]
    ## One Nim type spelling, and how N# classifies it.

  NsBclType* = object
    ## A type the prelude declares.
    name*: string         ## as declared, which is its Nim spelling
    alias*: string        ## equal to this type
    base*: string         ## declared base type
    kind*: NsTypeKind     ## own kind, when neither of the above

  NsBclMember* = object
    ## A prelude proc seen as a member; the receiver is its first parameter.
    name*: string         ## "" means the library declares no such member
    path*: string         ## declaring module, as an import path
    recv*: string         ## receiver spelling, or a type-class key
    ret*: string          ## declared result spelling ("" for `void`)
    isStatic*: bool       ## declared over `typedesc[...]`: `int.MaxValue`
    retIsParam*: bool     ## the result is one of the declaration's own parameters

  NsStaticDecl* = tuple[typ, member, module: string]
    ## A `{.nsStatic: "T".}` pragma: the qualifier, the proc, and its module.

  NsBclSurface* = object
    ## The prelude's declarations, keyed by name and by receiver.
    types*: Table[string, NsBclType]
    members*: Table[string, seq[NsBclMember]]
    namespaces*: HashSet[string]
      ## The namespaces the prelude is written in, and their prefixes.
    staticDecls: seq[NsStaticDecl]
      ## Pending `{.nsStatic: "T".}` pragmas, resolved after every file is read.

const
  ## The prelude's location in the library, and the module every N# module gets.
  NsLibRoot* = "pure/ns"
  NsIntrinsicsPath* = "nsharp/intrinsics"

  ## C# type names whose Nim spelling differs; the rest pass through unchanged.
  NsPrimitiveTypes*: array[17, NsRename] = [
    ("int", "int32"), ("uint", "uint32"), ("long", "int64"),
    ("ulong", "uint64"), ("short", "int16"), ("ushort", "uint16"),
    ("byte", "uint8"), ("sbyte", "int8"), ("float", "float32"),
    ("double", "float64"), ("bool", "bool"), ("char", "char"),
    ("string", "string"), ("object", "RootRef"),
    ("nint", "int"), ("nuint", "uint"),
    ("Array", "openArray"),
  ]

  ## BCL class names C# accepts in place of the keyword, mapped to that keyword.
  NsBclTypeNames*: array[16, NsRename] = [
    ("Int32", "int"), ("UInt32", "uint"), ("Int64", "long"), ("UInt64", "ulong"),
    ("Int16", "short"), ("UInt16", "ushort"), ("Byte", "byte"),
    ("SByte", "sbyte"), ("Single", "float"), ("Double", "double"),
    ("Boolean", "bool"), ("Char", "char"), ("String", "string"),
    ("Object", "object"), ("IntPtr", "nint"), ("UIntPtr", "nuint"),
  ]

  ## Nim types the prelude builds on, and how N# classifies them.
  NsNimKinds*: array[37, NsTypeEntry] = [
    ("int8", tkInt), ("int16", tkInt), ("int32", tkInt), ("int64", tkInt),
    ("uint8", tkInt), ("uint16", tkInt), ("uint32", tkInt), ("uint64", tkInt),
    ("int", tkInt), ("uint", tkInt),
    ("float32", tkFloat), ("float64", tkFloat),
    ("bool", tkBool), ("char", tkChar), ("string", tkString),
    ("seq", tkSequence), ("openArray", tkSequence), ("array", tkSequence),
    ("Table", tkSequence), ("OrderedTable", tkSequence), ("HashSet", tkSequence),
    ("OrderedSet", tkSequence), ("Deque", tkSequence),
    ("Option", tkNullable),
    ("RootRef", tkClass), ("RootObj", tkClass),
    ("Exception", tkException), ("CatchableError", tkException),
    ("Defect", tkException), ("NilAccessDefect", tkException),
    ("OverflowDefect", tkException), ("IndexDefect", tkException),
    ("DivByZeroDefect", tkException), ("ObjectConversionDefect", tkException),
    ("RangeDefect", tkException), ("KeyError", tkException),
    ("ValueError", tkException),
  ]

  ## A generic constraint, and the key a member declared over it is filed under.
  NsTypeClassKeys*: array[5, NsRename] = [
    ("SomeInteger", "#int"), ("SomeFloat", "#float"),
    ("ref Exception", "#exception"), ("ref CatchableError", "#exception"),
    ("ref object", "#class"),
  ]

proc unqualified*(s: string): string =
  ## `A.B.C` as `C`; imported symbols are flat, so the qualifier is decorative.
  let dot = s.rfind('.')
  if dot >= 0: s[dot + 1 .. ^1] else: s

proc canonicalTypeName*(s: string): string =
  ## The type as C# spells it, without its qualifier: `System.Int32` is `int`.
  result = unqualified(s)
  for r in NsBclTypeNames:
    if r.cs == result: return r.nim

proc nimTypeName*(s: string): string =
  ## Nim spelling of a C# type name, or its canonical form unchanged.
  result = canonicalTypeName(s)
  for r in NsPrimitiveTypes:
    if r.cs == result: return r.nim

proc kindKey*(k: NsTypeKind): string =
  ## The key a declared constraint and a resolved receiver kind both map to.
  case k
  of tkInt: "#int"
  of tkFloat: "#float"
  of tkBool: "#bool"
  of tkChar: "#char"
  of tkString: "#string"
  of tkSequence: "#seq"
  of tkException: "#exception"
  of tkClass: "#class"
  of tkDelegate: "#delegate"
  of tkNullable: "#nullable"
  of tkUnknown, tkType: ""

# --- the names the compilation declares --------------------------------------
#
# The parser has no symbol table, but C# grammar must tell a cast from `(T)`, so
# the namespace scan records every type and namespace it sees.

var declaredTypes: HashSet[string]

proc noteDeclaredType*(name: string) =
  if name.len > 0: declaredTypes.incl name

proc isDeclaredType*(name: string): bool =
  ## The parser asks, to tell a cast from a parenthesised expression.
  declaredTypes.contains(name)

var declaredNamespaces: HashSet[string]

proc namespacePrefixes*(name: string): seq[string] =
  ## A namespace and each of its prefixes: `A.B.C` gives `A`, `A.B`, `A.B.C`.
  result = @[]
  var cur = ""
  for part in name.split('.'):
    if part.len == 0: continue
    cur = if cur.len == 0: part else: cur & "." & part
    result.add cur

proc noteDeclaredNamespace*(name: string) =
  ## C# namespaces are global, so they are recorded for the whole compilation.
  for p in namespacePrefixes(name):
    declaredNamespaces.incl p

proc isDeclaredNamespace*(name: string): bool =
  ## True when the compilation or the library declares a namespace of this name.
  declaredNamespaces.contains(name)

proc isLibraryNamespace*(s: NsBclSurface; name: string): bool =
  ## A namespace the prelude itself is written in.
  s.namespaces.contains(name)

proc namespaceModulePath*(ns: string): string =
  ## `A.B` as `A/B`; dots cannot be kept, `addFileExt` would read `.B` as a suffix.
  result = newStringOfCap(ns.len)
  for c in ns:
    result.add(if c == '.': '/' else: c)

# --- the library's surface ---------------------------------------------------
#
# Nim's own parser reads the prelude; only declarations are collected, and
# nothing is compiled.

proc declaredName(n: PNode): string =
  ## The declared name, with the `*` export marker dropped.
  if n == nil: return ""
  case n.kind
  of nkPostfix: result = (if n.len > 1: declaredName(n[1]) else: "")
  of nkAccQuoted:
    result = ""
    for i in 0 ..< n.len: result.add declaredName(n[i])
  of nkIdent: result = n.ident.s
  of nkSym: result = n.sym.name.s
  else: result = ""

proc headSpelling(n: PNode): string =
  ## The type a written type is headed by: `Table[K, V]` is `Table`.
  if n == nil: return ""
  case n.kind
  of nkIdent, nkSym, nkAccQuoted: result = declaredName(n)
  of nkBracketExpr, nkVarTy, nkRefTy, nkPtrTy, nkDistinctTy:
    result = (if n.len > 0: headSpelling(n[0]) else: "")
  of nkObjectTy:
    result = (if n.len > 1: headSpelling(n[1]) else: "")
  of nkOfInherit: result = (if n.len > 0: headSpelling(n[0]) else: "")
  else: result = ""

proc constraintSpelling(n: PNode): string =
  ## A constraint as written: `SomeInteger`, `ref Exception`, `ref object`.
  if n == nil: return ""
  case n.kind
  of nkRefTy:
    if n.len > 0 and n[0] != nil and n[0].kind == nkObjectTy: result = "ref object"
    else: result = "ref " & headSpelling(n)
  of nkVarTy: result = "var " & headSpelling(n)
  else: result = headSpelling(n)

proc typeClassKeyOf(spelling: string): string =
  ## A type class through its own table, a concrete type by name.
  for r in NsTypeClassKeys:
    if r.cs == spelling: return r.nim
  spelling

proc kindOfSpelling*(s: NsBclSurface; nim: string): NsTypeKind =
  ## The kind of a Nim spelling, following a prelude type's alias or base.
  result = tkUnknown
  var cur = nim
  var seen = initHashSet[string]()
  while cur.len > 0 and cur notin seen:
    seen.incl cur
    var known = false
    for e in NsNimKinds:
      if e.nim == cur:
        result = e.kind
        known = true
    if known: return
    if s.types.hasKey(cur):
      let t = s.types[cur]
      if t.alias.len > 0: cur = t.alias
      elif t.base.len > 0: cur = t.base
      else: return t.kind
    else: return tkUnknown

proc nimSpellingOf*(s: NsBclSurface; name: string): string =
  ## The Nim spelling of a C# type name, or "" when it names no such type.
  let canon = canonicalTypeName(name)
  for r in NsPrimitiveTypes:
    if r.cs == canon: return r.nim
  if s.types.hasKey(canon): return s.types[canon].name
  for e in NsNimKinds:
    if e.nim == canon: return canon
  ""

proc kindOfName*(s: NsBclSurface; name: string): NsTypeKind =
  ## The kind of a type named in C# (`int`), by the library (`Console`), or in Nim.
  let canon = canonicalTypeName(name)
  let nim = s.nimSpellingOf(canon)
  result = s.kindOfSpelling(if nim.len > 0: nim else: canon)

proc isKnownTypeName*(s: NsBclSurface; name: string): bool =
  ## Whether the name is a type this frontend can place; tells a cast from `(T)`.
  if name.len == 0: return false
  let canon = canonicalTypeName(name)
  for r in NsPrimitiveTypes:
    if r.cs == canon: return true
  s.types.hasKey(canon) or s.kindOfSpelling(canon) != tkUnknown or
    isDeclaredType(canon) or isDeclaredNamespace(canon)

proc member*(s: NsBclSurface; recvName: string; recvKind: NsTypeKind;
             name: string): NsBclMember =
  ## The member on a receiver, or a zeroed member when the library declares none.
  result = NsBclMember()
  if name.len == 0: return
  var keys: seq[string] = @[]
  let nim = s.nimSpellingOf(recvName)
  if nim.len > 0: keys.add nim
  let kk = kindKey(recvKind)
  if kk.len > 0: keys.add kk
  for key in keys:
    for m in s.members.getOrDefault(key):
      if m.name == name: return m

proc noteMember(s: var NsBclSurface; m: NsBclMember) =
  ## Files a declaration under its receiver, and under that receiver's type class
  ## unless the prelude declares the receiver as a type in its own right.
  var keys: seq[string] = @[]
  if m.recv.len > 0:
    keys.add m.recv
    if not s.types.hasKey(m.recv):
      let kk = kindKey(s.kindOfSpelling(m.recv))
      if kk.len > 0 and kk notin keys: keys.add kk
  for k in keys:
    s.members.mgetOrPut(k, @[]).add m

proc collectNimFiles(root: string; into: var seq[string]) =
  ## Every `.nim` file under `root`, recursively.
  if not dirExists(root): return
  for kind, path in walkDir(root):
    if kind == pcDir: collectNimFiles(path, into)
    elif kind == pcFile and splitFile(path).ext == ".nim": into.add path

proc isDefinition(n: PNode): bool =
  ## The nodes that declare something callable.
  n.kind in {nkProcDef, nkFuncDef, nkMethodDef, nkIteratorDef, nkConverterDef,
             nkTemplateDef, nkMacroDef}

proc loadTypes(s: var NsBclSurface; n: PNode) =
  ## The alias, base and kind a `type` section declares.
  for i in 0 ..< n.len:
    let d = n[i]
    if d == nil or d.kind != nkTypeDef or d.len < 3: continue
    var t = NsBclType(name: declaredName(d[0]))
    if t.name.len == 0: continue
    let body = d[2]
    if body != nil:
      case body.kind
      of nkObjectTy, nkRefTy, nkPtrTy:
        t.base = headSpelling(body)
        if t.base.len == 0: t.kind = tkClass
      of nkProcTy, nkIteratorTy: t.kind = tkDelegate
      else:
        let a = headSpelling(body)
        if a.len > 0 and a != t.name: t.alias = a
    s.types[t.name] = t

proc nsStaticOf(n: PNode): string =
  ## The type a declaration's `{.nsStatic: "T".}` pragma names, or "".
  for i in 0 ..< n.len:
    let p = n[i]
    if p == nil or p.kind != nkPragma: continue
    for j in 0 ..< p.len:
      let e = p[j]
      if e != nil and e.kind == nkExprColonExpr and e.len == 2 and
         declaredName(e[0]) == "nsStatic" and
         e[1] != nil and e[1].kind in {nkStrLit..nkTripleStrLit}:
        return e[1].strVal
  ""

proc loadMembers(s: var NsBclSurface; n: PNode; module: string) =
  ## One declaration as a member: the receiver is its first parameter, and a type
  ## parameter receiver stands for what that parameter is constrained to.
  if n.len < 4: return
  let name = declaredName(n[0])
  if name.len == 0: return
  var constraints = initTable[string, string]()
  if n[2] != nil and n[2].kind == nkGenericParams:
    for i in 0 ..< n[2].len:
      let gp = n[2][i]
      if gp == nil or gp.kind != nkIdentDefs or gp.len < 3: continue
      constraints[declaredName(gp[0])] = constraintSpelling(gp[1])
  let fp = n[3]
  if fp == nil or fp.kind != nkFormalParams or fp.len < 2: return
  let ret = headSpelling(fp[0])
  let p0 = fp[1]
  if p0 == nil or p0.kind != nkIdentDefs or p0.len < 2: return
  ## An `IdentDefs` lists names first, so a grouped parameter's type is at `[^2]`.
  var sel = (if p0.len >= 3: p0[p0.len - 2] else: p0[1])
  var isStatic = false
  if sel != nil and sel.kind == nkVarTy and sel.len > 0: sel = sel[0]
  if sel != nil and sel.kind == nkBracketExpr and headSpelling(sel) == "typedesc":
    ## A member of a type: `int.MaxValue` is reached through a `typedesc`.
    isStatic = true
    sel = (if sel.len > 1: sel[1] else: nil)
  var recv = headSpelling(sel)
  if constraints.hasKey(recv):
    ## An unconstrained type parameter names no type; `nsStatic` gives it one.
    let c = constraints[recv]
    recv = (if c.len > 0: c else: "#param")
  s.noteMember NsBclMember(name: name, path: module, recv: typeClassKeyOf(recv),
                           ret: ret, isStatic: isStatic,
                           retIsParam: ret.len > 0 and constraints.hasKey(ret))
  let qualifier = nsStaticOf(n)
  if qualifier.len > 0:
    ## Queued for `applyStatics`, which runs once every file has been read.
    s.staticDecls.add (typ: qualifier, member: name, module: module)

proc sameDecl(a, b: NsBclMember): bool =
  ## The same declaration filed under different receiver keys.
  a.name == b.name and a.path == b.path and a.recv == b.recv and
    a.ret == b.ret and a.isStatic == b.isStatic

proc applyStatics(s: var NsBclSurface; config: ConfigRef) =
  ## Re-files each `{.nsStatic: "T".}` member under the type its qualifier names and
  ## marks it `static`. An entry that matches nothing is a bug in the prelude, so it
  ## is reported rather than skipped.
  for e in s.staticDecls:
    let recv = s.nimSpellingOf(e.typ)
    if recv.len == 0:
      internalError(config, "nsStatic: the prelude declares no type '" & e.typ &
                    "' (on " & e.module & "." & e.member & ")")
      continue
    let targetKind = s.kindOfSpelling(recv)
    var keys: seq[string] = @[]
    for k in s.members.keys: keys.add k
    ## Every distinct declaration of this name in the module, deduped by receiver.
    var cands: seq[NsBclMember] = @[]
    for key in keys:
      for m in s.members[key]:
        if m.name != e.member or m.path != e.module: continue
        var dup = false
        for c in cands:
          if sameDecl(c, m): dup = true
        if not dup: cands.add m
    ## One candidate: the name is the identity. Several: the receiver's kind decides.
    var chosen: seq[NsBclMember] = @[]
    if cands.len == 1: chosen = cands
    else:
      for c in cands:
        if s.kindOfSpelling(c.recv) == targetKind: chosen.add c
    if chosen.len == 0:
      internalError(config, "nsStatic: the prelude declares no member '" & e.member &
                    "' of '" & e.typ & "' (" & e.module & ")")
      continue
    ## Move exactly the chosen declarations; same-named ones stay put.
    for key in keys:
      var kept: seq[NsBclMember] = @[]
      for m in s.members[key]:
        var drop = false
        for c in chosen:
          if sameDecl(c, m): drop = true
        if not drop: kept.add m
      s.members[key] = kept
    for c in chosen:
      var sm = c
      sm.recv = recv
      sm.isStatic = true
      s.noteMember sm

proc loadDecl(s: var NsBclSurface; n: PNode; module: string) =
  if n == nil: return
  case n.kind
  of nkTypeSection: s.loadTypes(n)
  of nkStmtList:
    for i in 0 ..< n.len: s.loadDecl(n[i], module)
  else:
    if isDefinition(n): s.loadMembers(n, module)

proc modulePathOf(file, root: string): string =
  ## A prelude file's import path: its path under the root, without the extension.
  result = relativePath(file, root)
  if result.len == 0 or result == file: result = splitFile(file).name
  let dot = result.rfind('.')
  if dot > 0: result = result[0 ..< dot]
  result = result.replace('\\', '/')

proc preludeRoot(config: ConfigRef): string =
  ## The library this compilation is built against; a tool with no configured
  ## library falls back to the one beside these sources.
  result = config.libpath.string
  if not dirExists(result / NsLibRoot):
    let beside = currentSourcePath().parentDir.parentDir.parentDir / "lib"
    if dirExists(beside / NsLibRoot): result = beside

proc loadPrelude(s: var NsBclSurface; config: ConfigRef) =
  ## Reads the prelude's declarations. A file that cannot be read is skipped:
  ## compiling the program is the frontend's job, auditing the library is not.
  let lib = preludeRoot(config)
  let nsRoot = lib / NsLibRoot
  var files: seq[tuple[path, module: string]] = @[]
  var nsFiles: seq[string] = @[]
  collectNimFiles(nsRoot, nsFiles)
  for f in nsFiles:
    files.add (f, modulePathOf(f, nsRoot))
    ## The library's namespaces are global, so a qualified name needs no `using`.
    let nsName = modulePathOf(f, nsRoot).replace('/', '.')
    for p in namespacePrefixes(nsName):
      s.namespaces.incl p
    noteDeclaredNamespace(nsName)
  let intrinsics = lib / "pure" / addFileExt(NsIntrinsicsPath, "nim")
  if fileExists(intrinsics): files.add (intrinsics, NsIntrinsicsPath)
  files.sort()
  let cache = newIdentCache()
  for entry in files:
    var source = ""
    try:
      source = readFile(entry.path)
    except CatchableError:
      continue
    s.loadDecl(nimparser.parseString(source, cache, config, entry.path),
               entry.module)

var surfaceCache: Table[string, NsBclSurface]
  ## One surface per library path; the prelude cannot change under a running
  ## compiler, so it is read once.

proc bclSurface*(config: ConfigRef): NsBclSurface =
  ## The prelude's surface, read once and then answered from memory.
  let key = preludeRoot(config)
  if surfaceCache.hasKey(key): return surfaceCache[key]
  var s = NsBclSurface(types: initTable[string, NsBclType](),
                       members: initTable[string, seq[NsBclMember]](),
                       namespaces: initHashSet[string]())
  s.loadPrelude(config)
  ## Resolved here rather than per file: the type may be in another module.
  s.applyStatics(config)
  surfaceCache[key] = s
  s

proc isExceptionType*(s: NsBclSurface; name: string;
                      chain: seq[string] = @[]): bool =
  ## Whether a type is an exception type, as the library's declarations and Nim's
  ## exception roots decide. `chain` carries this module's own class chain, so a
  ## class deriving from an exception is one too.
  if name.len > 0:
    let nim = s.nimSpellingOf(name)
    if s.kindOfSpelling(if nim.len > 0: nim else: name) == tkException: return true
  for c in chain:
    if s.kindOfSpelling(c) == tkException: return true
  false

