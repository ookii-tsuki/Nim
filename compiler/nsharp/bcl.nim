# N# frontend - the library's surface, and C#'s own type vocabulary
#
# Two kinds of knowledge live here, and they are kept apart on purpose.
#
# C#'s vocabulary: the built-in type keywords, the BCL class names C# accepts in
# their place (`int`/`Int32`), and the handful of Nim type names the prelude is
# written in. C# lets a program name a type this way whatever any library
# declares, so this is the language's, not a library's.
#
# The library's surface: the types and members the N# prelude *declares*, read out
# of the prelude's own Nim sources. `sema.nim` and `desugar.nim` resolve
# `List<T>`, `x.Length`, `.Count`, `.Message`, `Console.WriteLine`,
# `int.MaxValue` and `catch (NullReferenceException)` against those declarations,
# so no member name is hardcoded in the compiler: the prelude is the authority,
# exactly as `int.high` reaches `high(int32)`. A member reached this way is an
# ordinary proc over `typedesc`/`openArray`/`Option`/an exception root, and it
# reaches the N# program through Nim's own dot-call -- there is no rename step to
# keep in step with the library.

import std/[os, syncio, strutils, sets, tables, algorithm]
import ../ast, ../idents, ../lineinfos, ../msgs, ../options, ../pathutils
import ../parser as nimparser
import ast

type
  NsRename* = tuple[cs: string, nim: string]

  NsTypeEntry* = tuple[nim: string, kind: NsTypeKind]
    ## One Nim type spelling, and how N# classifies it.

  NsBclType* = object
    ## A type the prelude declares: `List<T> = seq[T]`, `Console = object`.
    name*: string         ## the name as declared, which is its Nim spelling
    alias*: string        ## a type it is declared to be equal to ("seq")
    base*: string         ## its declared base type, for an object
    kind*: NsTypeKind     ## its own kind, when it has neither

  NsBclMember* = object
    ## A proc or template the prelude declares, seen as a member: the receiver is
    ## its first parameter. `name == ""` means the library declares no such member.
    name*: string
    path*: string         ## the module that declares it, as an import path
    recv*: string         ## the receiver's spelling, or the key of a type class
    ret*: string          ## the declared result spelling ("" for `void`)
    isStatic*: bool       ## declared over `typedesc[...]`: `int.MaxValue`
    retIsParam*: bool     ## the result is one of the declaration's own parameters

  NsBclSurface* = object
    ## What the prelude declares, in the shape the rest of the frontend asks about
    ## it. `types` is keyed by declared name, `members` by the receiver spelling
    ## (and by the key of the type class the receiver's kind stands for).
    types*: Table[string, NsBclType]
    members*: Table[string, seq[NsBclMember]]
    namespaces*: HashSet[string]
      ## The namespaces the library is *written in*, and each of their prefixes, so
      ## `System.Collections.Generic` is reached from `System`. A qualified name
      ## starting at one of these is a name the library's module declares, even when
      ## no declaration records it as a member (`System.Console.WriteLine` reaches a
      ## proc `Console` would own in C# but the prelude writes at module level).

const
  ## Where the N# prelude lives inside the library: the namespace tree N# imports,
  ## and the intrinsics every N# module is given. `NsIntrinsicsPath` is also the
  ## import path `desugar.nim` names it by, since the prelude is a Nim module like
  ## any other.
  NsLibRoot* = "pure/ns"
  NsIntrinsicsPath* = "nsharp/intrinsics"

  ## C# type names to the Nim spelling the prelude writes them in. Only names whose
  ## Nim spelling differs appear here; everything else is passed through unchanged.
  ## `Array` is C#'s built-in array type, whose members the prelude declares over
  ## `openArray`.
  NsPrimitiveTypes*: array[17, NsRename] = [
    ("int", "int32"), ("uint", "uint32"), ("long", "int64"),
    ("ulong", "uint64"), ("short", "int16"), ("ushort", "uint16"),
    ("byte", "uint8"), ("sbyte", "int8"), ("float", "float32"),
    ("double", "float64"), ("bool", "bool"), ("char", "char"),
    ("string", "string"), ("object", "RootRef"),
    ("nint", "int"), ("nuint", "uint"),
    ("Array", "openArray"),
  ]

  ## The BCL class name of a C# built-in type, which C# accepts in place of the
  ## keyword. Mapping to the keyword keeps one Nim spelling per type.
  NsBclTypeNames*: array[16, NsRename] = [
    ("Int32", "int"), ("UInt32", "uint"), ("Int64", "long"), ("UInt64", "ulong"),
    ("Int16", "short"), ("UInt16", "ushort"), ("Byte", "byte"),
    ("SByte", "sbyte"), ("Single", "float"), ("Double", "double"),
    ("Boolean", "bool"), ("Char", "char"), ("String", "string"),
    ("Object", "object"), ("IntPtr", "nint"), ("UIntPtr", "nuint"),
  ]

  ## Nim types the prelude builds on, and how N# classifies them. These are Nim's
  ## own names -- the stdlib types the prelude aliases, and the exception roots Nim
  ## raises -- which is why they are listed here rather than read out of `lib/`:
  ## they are what the prelude's declarations are *about*, not part of its surface.
  NsNimKinds*: array[35, NsTypeEntry] = [
    ("int8", tkInt), ("int16", tkInt), ("int32", tkInt), ("int64", tkInt),
    ("uint8", tkInt), ("uint16", tkInt), ("uint32", tkInt), ("uint64", tkInt),
    ("int", tkInt), ("uint", tkInt),
    ("float32", tkFloat), ("float64", tkFloat),
    ("bool", tkBool), ("char", tkChar), ("string", tkString),
    ("seq", tkSequence), ("openArray", tkSequence), ("array", tkSequence),
    ("Table", tkSequence), ("OrderedTable", tkSequence), ("HashSet", tkSequence),
    ("OrderedSet", tkSequence), ("Deque", tkSequence),
    ("Option", tkNullable),
    ("Exception", tkException), ("CatchableError", tkException),
    ("Defect", tkException), ("NilAccessDefect", tkException),
    ("OverflowDefect", tkException), ("IndexDefect", tkException),
    ("DivByZeroDefect", tkException), ("ObjectConversionDefect", tkException),
    ("RangeDefect", tkException), ("KeyError", tkException),
    ("ValueError", tkException),
  ]

  ## A generic constraint, and the key a member declared over it hangs off. A member
  ## written for a *class of types* (`SomeInteger`, `ref Exception`) therefore has
  ## one declaration, found through whatever concrete type a receiver turns out to
  ## have.
  NsTypeClassKeys*: array[5, NsRename] = [
    ("SomeInteger", "#int"), ("SomeFloat", "#float"),
    ("ref Exception", "#exception"), ("ref CatchableError", "#exception"),
    ("ref object", "#class"),
  ]

proc unqualified*(s: string): string =
  ## Drops the namespace qualifier from a type name: `A.B.C` becomes `C`. Imported
  ## symbols are flat, so the qualifier is decorative.
  let dot = s.rfind('.')
  if dot >= 0: s[dot + 1 .. ^1] else: s

proc canonicalTypeName*(s: string): string =
  ## The C# keyword spelling of a type name, without its qualifier:
  ## `System.Int32` and `Int32` both become `int`.
  result = unqualified(s)
  for r in NsBclTypeNames:
    if r.cs == result: return r.nim

proc nimTypeName*(s: string): string =
  ## Nim spelling of a C# type name, or its canonical form unchanged.
  result = canonicalTypeName(s)
  for r in NsPrimitiveTypes:
    if r.cs == result: return r.nim

proc kindKey*(k: NsTypeKind): string =
  ## The key a declaration written over a class of types hangs off. It is the
  ## bridge between the two sides of a member lookup: a *declared* constraint is
  ## read as one of these keys when the prelude is loaded, and a receiver's
  ## *resolved* kind is read as the same key when a member is looked up.
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

# --- the types the compilation declares --------------------------------------
#
# The frontend's own symbol tables cover the module and the namespaces it imports,
# which is everything `sema.nim` needs. The *parser* has no such table -- it runs
# per file, before anything is collected -- yet C# grammar has to know whether
# `(T)` starts a cast. The names the compilation declares are the answer, so the
# namespace scan records them here.

var declaredTypes: HashSet[string]

proc noteDeclaredType*(name: string) =
  ## Records a type name the compilation declares. Called by the namespace scan,
  ## which sees every `.ns` file of the compilation before any of them is parsed.
  if name.len > 0: declaredTypes.incl name

proc isDeclaredType*(name: string): bool =
  ## True when the compilation declares a type of this name. Only the parser asks:
  ## telling a cast from a parenthesised expression is a grammar decision, and the
  ## grammar has no scope to consult.
  declaredTypes.contains(name)

var declaredNamespaces: HashSet[string]

proc namespacePrefixes*(name: string): seq[string] =
  ## A namespace and each of its prefixes: `A.B.C` gives `A`, `A.B` and `A.B.C`. All
  ## three name the same declarations, so all three are names a qualifier can start
  ## at.
  result = @[]
  var cur = ""
  for part in name.split('.'):
    if part.len == 0: continue
    cur = if cur.len == 0: part else: cur & "." & part
    result.add cur

proc noteDeclaredNamespace*(name: string) =
  ## Records a namespace, and each of its prefixes. C# namespaces are *global* -- a
  ## fully qualified `System.Console.WriteLine` is reachable from any file, with no
  ## `using` -- so they are recorded for the whole compilation, unlike an alias,
  ## which is a file-local name the parser keeps for itself. The namespace scan and
  ## the prelude fill this in, and it is what tells the root of a dotted name from a
  ## value.
  for p in namespacePrefixes(name):
    declaredNamespaces.incl p

proc isDeclaredNamespace*(name: string): bool =
  ## True when the compilation or the library declares a namespace of this name.
  declaredNamespaces.contains(name)

proc isLibraryNamespace*(s: NsBclSurface; name: string): bool =
  ## True when a namespace the prelude is written in has this name. Lowering needs
  ## it: a qualifier named after one of these is dropped in favour of the module that
  ## declares the name, while a namespace this compilation declares is reached by the
  ## file that declares or imports it.
  s.namespaces.contains(name)

proc namespaceModulePath*(ns: string): string =
  ## `A.B` as the module path `A/B`. `addFileExt` reads a trailing `.B` as a file
  ## extension, so the dots cannot be kept.
  result = newStringOfCap(ns.len)
  for c in ns:
    result.add(if c == '.': '/' else: c)

# --- the library's surface ---------------------------------------------------
#
# The prelude is Nim, so Nim's own parser reads it. Only declarations are
# collected; nothing is compiled, and the resulting table is what `sema.nim` and
# `desugar.nim` resolve a type or a member against.

proc declaredName(n: PNode): string =
  ## The name a definition declares, with the `*` export marker dropped, and an
  ## operator as its own text (`+`).
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
  ## The type a written type is headed by: `Table[K, V]` is a `Table`, and
  ## `var Queue[T]` a `Queue`.
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
  ## A generic constraint as the prelude writes it: `SomeInteger`, `ref Exception`,
  ## `ref object`. A member declared over one hangs off the class of types it names.
  if n == nil: return ""
  case n.kind
  of nkRefTy:
    if n.len > 0 and n[0] != nil and n[0].kind == nkObjectTy: result = "ref object"
    else: result = "ref " & headSpelling(n)
  of nkVarTy: result = "var " & headSpelling(n)
  else: result = headSpelling(n)

proc typeClassKeyOf(spelling: string): string =
  ## What a receiver spelling stands for: a type class through its own table, a
  ## concrete type by its name.
  for r in NsTypeClassKeys:
    if r.cs == spelling: return r.nim
  spelling

proc kindOfSpelling*(s: NsBclSurface; nim: string): NsTypeKind =
  ## The kind a Nim type spelling has: a Nim type the prelude builds on, a type the
  ## prelude declares (following its alias or base), or nothing.
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
  ## The Nim spelling of a C# type name: a keyword through C#'s own tables, a
  ## library type through its declaration, a Nim type the library builds on
  ## (`HashSet`) under its own name, and otherwise "".
  let canon = canonicalTypeName(name)
  for r in NsPrimitiveTypes:
    if r.cs == canon: return r.nim
  if s.types.hasKey(canon): return s.types[canon].name
  for e in NsNimKinds:
    if e.nim == canon: return canon
  ""

proc kindOfName*(s: NsBclSurface; name: string): NsTypeKind =
  ## The kind a type written by name has: C#'s (`int`, `List`), the library's
  ## (`Console`), or a Nim type the library builds on (`Table`, `HashSet`).
  let canon = canonicalTypeName(name)
  let nim = s.nimSpellingOf(canon)
  result = s.kindOfSpelling(if nim.len > 0: nim else: canon)

proc isKnownTypeName*(s: NsBclSurface; name: string): bool =
  ## True when the name is a type the frontend can place without a symbol table of
  ## its own: C#'s vocabulary, the library's declarations, a Nim type the library
  ## builds on, a type the compilation declares, or a namespace either of them
  ## declares. A cast is told from a parenthesised expression by this lookup.
  if name.len == 0: return false
  let canon = canonicalTypeName(name)
  for r in NsPrimitiveTypes:
    if r.cs == canon: return true
  s.types.hasKey(canon) or s.kindOfSpelling(canon) != tkUnknown or
    isDeclaredType(canon) or isDeclaredNamespace(canon)

proc member*(s: NsBclSurface; recvName: string; recvKind: NsTypeKind;
             name: string): NsBclMember =
  ## The library member `name` on a receiver, or a zeroed member when the library
  ## declares none. Which declarations apply is decided by the receiver's *resolved*
  ## type, so `x.Length` reaches the `openArray` declaration whether `x` was
  ## declared as a `List`, as an array, or as a `String` -- and a member declared
  ## over a class of types is reached through the key that class stands for.
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
  ## Files a declaration under its receiver. A receiver naming a Nim type the
  ## library only *builds on* is filed under the class of types it belongs to as
  ## well -- `openArray` under the sequences, `ref object` under the classes --
  ## because N# has no declaration of those types to look a member up on. A
  ## receiver the library declares keeps its own name: `List` *is* a `seq`, but the
  ## prelude says so by declaring the member over `List`.
  var keys: seq[string] = @[]
  if m.recv.len > 0:
    keys.add m.recv
    if not s.types.hasKey(m.recv):
      let kk = kindKey(s.kindOfSpelling(m.recv))
      if kk.len > 0 and kk notin keys: keys.add kk
  for k in keys:
    s.members.mgetOrPut(k, @[]).add m

proc collectNimFiles(root: string; into: var seq[string]) =
  ## Every `.nim` file under `root`, recursively. The prelude's namespaces map to
  ## directories, so the tree is walked rather than a list of modules kept here.
  if not dirExists(root): return
  for kind, path in walkDir(root):
    if kind == pcDir: collectNimFiles(path, into)
    elif kind == pcFile and splitFile(path).ext == ".nim": into.add path

proc isDefinition(n: PNode): bool =
  ## The nodes that declare something callable.
  n.kind in {nkProcDef, nkFuncDef, nkMethodDef, nkIteratorDef, nkConverterDef,
             nkTemplateDef, nkMacroDef}

proc loadTypes(s: var NsBclSurface; n: PNode) =
  ## The types a `type` section declares: what they are equal to, what they derive
  ## from, and their own kind when they are neither.
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

proc loadMembers(s: var NsBclSurface; n: PNode; module: string) =
  ## One declaration, seen as a member: the receiver is the first parameter, and a
  ## receiver spelled with one of the declaration's type parameters stands for what
  ## that parameter is constrained to.
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
  var sel = p0[1]
  var isStatic = false
  if sel != nil and sel.kind == nkVarTy and sel.len > 0: sel = sel[0]
  if sel != nil and sel.kind == nkBracketExpr and headSpelling(sel) == "typedesc":
    ## A member of a *type*: `int.MaxValue` is reached through a `typedesc`.
    isStatic = true
    sel = (if sel.len > 1: sel[1] else: nil)
  var recv = headSpelling(sel)
  if constraints.hasKey(recv): recv = constraints[recv]
  s.noteMember NsBclMember(name: name, path: module, recv: typeClassKeyOf(recv),
                           ret: ret, isStatic: isStatic,
                           retIsParam: ret.len > 0 and constraints.hasKey(ret))

proc loadDecl(s: var NsBclSurface; n: PNode; module: string) =
  if n == nil: return
  case n.kind
  of nkTypeSection: s.loadTypes(n)
  of nkStmtList:
    for i in 0 ..< n.len: s.loadDecl(n[i], module)
  else:
    if isDefinition(n): s.loadMembers(n, module)

proc modulePathOf(file, root: string): string =
  ## The import path of a prelude file: its path under the prelude root, without the
  ## extension, which is how a `using` names the module a declaration belongs to.
  result = relativePath(file, root)
  if result.len == 0 or result == file: result = splitFile(file).name
  let dot = result.rfind('.')
  if dot > 0: result = result[0 ..< dot]
  result = result.replace('\\', '/')

proc preludeRoot(config: ConfigRef): string =
  ## The library directory the prelude is read from: the one this compilation is
  ## built against, because that is the prelude the generated imports resolve to. A
  ## tool that drives the frontend without a configured library path -- the AST dump
  ## tool, which only wants the tree -- falls back to the library beside these
  ## sources, so it resolves what a real build resolves instead of resolving
  ## nothing.
  result = config.libpath.string
  if not dirExists(result / NsLibRoot):
    let beside = currentSourcePath().parentDir.parentDir.parentDir / "lib"
    if dirExists(beside / NsLibRoot): result = beside

proc loadPrelude(s: var NsBclSurface; config: ConfigRef) =
  ## Reads the prelude's declarations. The prelude is Nim, so Nim's own parser
  ## reads it; nothing is compiled, and a file that cannot be read is skipped
  ## rather than reported -- the frontend's job is to compile the program, not to
  ## audit the library it is compiled against.
  let lib = preludeRoot(config)
  let nsRoot = lib / NsLibRoot
  var files: seq[tuple[path, module: string]] = @[]
  var nsFiles: seq[string] = @[]
  collectNimFiles(nsRoot, nsFiles)
  for f in nsFiles:
    files.add (f, modulePathOf(f, nsRoot))
    ## The library's namespaces are global like any other, so a fully qualified
    ## `System.Console.WriteLine` resolves without a `using`, and lowering can name
    ## the module a qualified declaration belongs to. The intrinsics is not a
    ## namespace and is left out.
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
  ## One surface per library, keyed by its path: the prelude does not change under
  ## a running compiler, and reading it once keeps a compile cheap.

proc bclSurface*(config: ConfigRef): NsBclSurface =
  ## The prelude's surface, read once and then answered from memory. Everything the
  ## frontend resolves about a type or a member comes from here.
  let key = preludeRoot(config)
  if surfaceCache.hasKey(key): return surfaceCache[key]
  var s = NsBclSurface(types: initTable[string, NsBclType](),
                       members: initTable[string, seq[NsBclMember]](),
                       namespaces: initHashSet[string]())
  s.loadPrelude(config)
  surfaceCache[key] = s
  s

proc isExceptionType*(s: NsBclSurface; name: string;
                      chain: seq[string] = @[]): bool =
  ## True when a type is an exception type. `name` is the type as written -- a
  ## library type, a Nim defect, or a class this module declares -- and `chain` is
  ## this module's class chain for it when it is one of its own, so a class deriving
  ## from an exception is one too. The library's own declarations and Nim's
  ## exception roots decide; nothing is known from the spelling of a name.
  ## A class declared this way is emitted as a value `object` (so `except T` can
  ## match it) but raised as `ref T`, because Nim can only raise a reference.
  if name.len > 0:
    let nim = s.nimSpellingOf(name)
    if s.kindOfSpelling(if nim.len > 0: nim else: name) == tkException: return true
  for c in chain:
    if s.kindOfSpelling(c) == tkException: return true
  false

