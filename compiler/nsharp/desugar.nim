# N# frontend - lowering to Nim
#
# The C#-to-Nim translation: NsNode in, ordinary Nim PNodes out. The name mapping
# itself lives in bcl.nim.
#
# A value-returning method, local function or generated `init`/`new` proc is
# `{.discardable.}` (see procPragmas), since C# lets a call statement drop a result.

import std/[strutils, tables, algorithm, sets, sequtils]
import ../ast, ../idents, ../lineinfos, ../options
import ast, bcl, symbols, numeric

const
  NsCond = "nsCond"
    ## The temporary a `?.` chain binds its guarded value to. Each link lowers inside
    ## its own block, so one name cannot collide across a chain.

type
  NsFromImports = ref object
    ## The prelude modules a lowering had to name a declaration from, and the names
    ## to take from each. A member of a type is reachable wherever the type is
    ## reachable in C#, but Nim resolves a proc in the module that *uses* it, and the
    ## namespace that declares the type is not necessarily imported at the use site
    ## (`var xs = Other.List(); xs.Count`). So the declaration `sema.nim` resolved is
    ## imported by name, and nothing else: `from X import Count` leaves the module's
    ## *types* out of scope, which is what C# does with a namespace it does not have.
    byModule: Table[string, seq[string]]
    instances: seq[PNode]
      ## every concrete instance of a generic class the module names (`Box[int32]`),
      ## whose overrides the module instantiates (`forceOverrides`)
    instanceKeys: HashSet[string]
    memberRenames: HashSet[string]
      ## the members of this compilation's types named like one of its types
      ## (`public Color Color { get; }`): Nim cannot have a proc and a type of one
      ## name in a module, so such a member is `nsM_Color` (`memberIdent`)
    userTypes: HashSet[string]
      ## the type names this compilation declares, which a library member of the
      ## same name is called module-qualified around (`System.Message(e)`)

type
  Lowerer = object
    scope: NsModuleScope
    surface: NsBclSurface   ## what the prelude declares
    imports: NsFromImports  ## the prelude declarations the lowered code names
    counter: ref int        ## numbers the temporaries a lowering introduces
    usingPaths: HashSet[string]
      ## The modules this module's own `using` directives import, so a member whose
      ## namespace is already imported is not named twice.
    cache: IdentCache
    thisName: string        ## "self" in instance members, "" in static ones
    frameScope: string
      ## `Demo.Program.<Main>` while a member is lowered: its lambdas and local
      ## functions name their stack frames after it, as .NET's do.
    frameCount: ref int     ## numbers those lambdas and local functions
    frameLocals: ref Table[string, int]
      ## each local function's number, so its forward declaration and its
      ## definition record the same frame
    entryPoint: PNode       ## the emitted `Main` proc, if there was one
    familyProcs: seq[PNode]
      ## The helpers of each native family (`nsObjProcs`, `nsHandleProcs`), which
      ## every routine converting to or from its handles calls: emitted right
      ## after the declarations, so a member may name a native class declared
      ## after it.
    nativeProcs: seq[PNode]
    helpersIncluded: bool
      ## `nsobj.hpp` is included: once per module, by its first native type.
    pinvokeLinked: int
      ## `[DllImport("__Internal")]` methods so far, which number their C names (one
      ## C function per overload); with any, the module defines `NS_ASMNAME`...
    pinvokeLoaded: bool
      ## ... and one from a library: it imports `nsharp/pinvoke`.
      ## Each native type's members, emitted after every family's helpers, so any
      ## routine may name a native type, or call its members, declared after it.
    staticInits: seq[PNode]
      ## One `nsStaticInit<C>` proc per class with static initialisers or a static
      ## constructor. They are emitted after every declaration and called before
      ## `Main`, so they may name any member of the module.
    nilChecks: bool         ## whether the compilation has the nil check on
    curClass: NsNode        ## the class whose members are being lowered
    curBase: string         ## its base class, for `base.M()`
    curBaseType: NsNode     ## the base as written, with its type arguments
    inIterator: bool        ## lowering an iterator block: its `try` statements
                            ## register their `finally` for `Dispose` (`nsDisp`)
    curIsException: bool    ## whether it is lowered as a value object raised by `ref`
    curNamespace: string    ## the enclosing namespace, for `object.ToString()`
    ownNamespaces: HashSet[string]
      ## the namespaces this module declares itself, which a `using` need not import
    clsTypeParams: seq[string]
      ## the type parameters of the class being lowered: its own name is `C[T]`
    procTypeParams: seq[string]
      ## the generic parameters a routine emitted now takes (class's, then method's)
    objTypes: bool
      ## a native class names its C++ struct, not its handle: a base type, `self`
    hoist: NsHoist
      ## the handle locals in scope whose object pointer is kept (`nsP_x`)
    noCache: bool
      ## lowering a statement that may move engine objects: handles resolve afresh
    nonneg: seq[string]
      ## the counters of the `for` loops being lowered that are never negative
    checked: bool
      ## lowering inside `checked`: integer `+`, `-`, `*` and negation go through
      ## the intrinsics' `nsCk*`, which throw with .NET's message
  NsHoist = ref object
    names: seq[tuple[name, cls: string]]
    moves: Table[string, bool]   ## memo: whether an N# member may move engine objects

proc note(l: NsFromImports; module, name: string) =
  ## Records one declaration to import by name, once.
  if module.len == 0 or name.len == 0: return
  if not l.byModule.hasKey(module): l.byModule[module] = @[]
  if name notin l.byModule[module]: l.byModule[module].add name

proc id(l: Lowerer; s: string; info: TLineInfo): PNode =
  newAtom(l.cache.getIdentExact(s), info)

proc empty(info: TLineInfo): PNode {.inline.} = newNodeI(nkEmpty, info)

proc emptyList(info: TLineInfo): PNode {.inline.} = newNodeI(nkStmtList, info)

proc identDefs(l: Lowerer; name: string; typ: PNode; info: TLineInfo): PNode =
  result = newTree(nkIdentDefs, info, l.id(name, info), typ, empty(info))


proc nameNode(l: Lowerer; name: string; info: TLineInfo): PNode =
  ## A declared name: an operator (`$`, `[]=`) quoted, so a module rendered as text
  ## reads back (`proc \`$\`*`).
  result = l.id(name, info)
  if name.len > 0 and name[0] notin {'a'..'z', 'A'..'Z', '_'}:
    result = newTree(nkAccQuoted, info, result)

proc unmanagedEntryName(cls, m: string): string =
  ## `nsUC_<C>_<M>`: the C entry of an `[UnmanagedCallersOnly]` method.
  "nsUC_" & cls & "_" & m

proc cMirrorName(name: string): string =
  ## The C struct a struct crosses to C as.
  "nsC_" & canonicalTypeName(name)

proc exportId(l: Lowerer; name: string; info: TLineInfo): PNode =
  newTree(nkPostfix, info, l.id("*", info), l.nameNode(name, info))


proc clsType(l: Lowerer; name: string; info: TLineInfo): PNode =
  ## The class being lowered as a type: `C`, or `C[T, U]` when it is generic.
  result = l.id(name, info)
  if l.clsTypeParams.len > 0 and l.curClass != nil and name == l.curClass.name:
    result = newTree(nkBracketExpr, info, result)
    for t in l.clsTypeParams: result.add l.id(t, info)

proc genericParams(l: Lowerer; names: seq[string]; info: TLineInfo): PNode =
  ## `[T, U]` for a routine or a type.
  if names.len == 0: return newNodeI(nkEmpty, info)
  result = newNodeI(nkGenericParams, info)
  let defs = newNodeI(nkIdentDefs, info)
  for n in names: defs.add l.id(n, info)
  defs.add newNodeI(nkEmpty, info)
  defs.add newNodeI(nkEmpty, info)
  result.add defs

proc qualifierNamespace(l: Lowerer; n: NsNode): string =
  ## The longest prefix of a dotted qualifier that names a namespace the *library*
  ## is written in, or "" when the chain does not start at one: `System.Console`
  ## gives `System`, while `P.Gadget` and `Demo.Gadget` give nothing, because a
  ## namespace this compilation declares is reached by the file that declares or
  ## imports it.
  result = ""
  var parts: seq[string] = @[]
  var cur = n
  while cur != nil and cur.kind == nsnMember:
    parts.add cur.name
    cur = cur.body
  if cur == nil or cur.kind != nsnIdent: return
  parts.add cur.name
  ## `parts` is the chain from the receiver outwards, so the prefixes are built from
  ## its end: `System`, `System.Console`, ... and the longest match is the last one.
  var dotted = ""
  for i in countdown(parts.len - 1, 0):
    dotted = if dotted.len == 0: parts[i] else: dotted & "." & parts[i]
    if l.surface.isLibraryNamespace(dotted): result = dotted

proc isUserReceiver(l: Lowerer; recv: NsNode): bool =
  ## Whether a member is reached on a value or type this compilation declares.
  if recv == nil or recv.kind in {nsnThis, nsnBase}: return true
  let tn = canonicalTypeName(recv.typeName).split('<')[0]
  tn.len > 0 and (l.scope.classes.hasKey(tn) or l.scope.enums.contains(tn))

proc memberIdent(l: Lowerer; name: string; recv: NsNode; info: TLineInfo): PNode =
  ## A member's Nim name: `nsM_X` for one named like a type of this compilation
  ## (see `memberRenames`), the C# name otherwise.
  if l.imports != nil and name in l.imports.memberRenames and l.isUserReceiver(recv):
    l.id("nsM_" & name, info)
  elif recv != nil and not l.isUserReceiver(recv) and
       canonicalTypeName(recv.typeName).split('<')[0] & "." & name in l.surface.renamedMembers:
    ## The library declares it under the same spelling, for the same reason.
    l.id("nsM_" & name, info)
  else: l.id(name, info)

proc nativeMemberId(l: Lowerer; name: string; info: TLineInfo): PNode =
  ## A `[Native]` member's exported Nim name, renamed as `memberIdent` reaches it;
  ## its C++ name comes from its pattern, so the rename does not reach C++.
  if l.imports != nil and name.strip(leading = false, chars = {'='}) in l.imports.memberRenames:
    l.exportId("nsM_" & name, info)
  else: l.exportId(name, info)

proc noteMemberImport(l: Lowerer; n: NsNode) =
  ## Records the prelude declaration a member access resolved to, so the module can
  ## name it. Nothing is recorded for a member this module declares, for one the
  ## library does not declare, or for an intrinsics one -- every module imports
  ## those already.
  if l.imports == nil or n == nil or n.body == nil: return
  var rk = n.body.typeKind
  if rk == tkType: rk = l.surface.kindOfName(n.body.typeName)
  var recv = n.body.typeName
  if recv.len == 0: recv = n.body.name
  let m = l.surface.member(recv, rk, n.name)
  if m.path == NsIntrinsicsPath: return
  if m.name.len > 0:
    l.imports.note(m.path, (if m.recv & "." & m.name in l.surface.renamedMembers: "nsM_" & m.name
                            else: m.name))
    return
  ## The library declares nothing of this shape, but the qualifier names one of its
  ## namespaces: the name belongs to that namespace's *module*, since the qualifier
  ## C# drops (`System.Console.WriteLine`) is what said so. A receiver this module
  ## declares is left alone -- its declaration is the one in scope.
  if l.scope.classes.hasKey(recv) or l.scope.delegates.hasKey(recv) or
     l.scope.enums.contains(recv):
    return
  let ns = l.qualifierNamespace(n.body)
  if ns.len > 0: l.imports.note(namespaceModulePath(ns), n.name)

# --- dispatch ----------------------------------------------------------------

proc isDispatchedMember(cls, m: NsNode): bool =
  ## A member in a dispatch slot is a Nim `method`. Only a class has slots: a struct
  ## is sealed, so its `override string ToString()` is an ordinary proc.
  cls.classKind == ckClass and not m.attrs.isStatic and
    (m.attrs.isVirtual or m.attrs.isAbstract or m.attrs.isOverride)

proc asMethod(l: Lowerer; cls, m: NsNode; def: PNode): PNode =
  ## Turns a lowered member into a `method`: `{.base.}` where C# opens the slot
  ## (`virtual`, `abstract`), and a body that throws for an abstract one, which C#
  ## never lets run because the class cannot be instantiated.
  result = def
  if not isDispatchedMember(cls, m): return
  result = newNodeI(nkMethodDef, def.info, 7)
  for i in 0 .. 6: result[i] = def[i]
  if m.attrs.isVirtual or m.attrs.isAbstract:
    let pr = (if def[4].kind == nkPragma: copyTree(def[4]) else: newNodeI(nkPragma, def.info))
    pr.add l.id("base", def.info)
    result[4] = pr
  if m.attrs.isAbstract:
    let raiseCall = newNodeI(nkCall, def.info)
    raiseCall.add l.id("newException", def.info)
    raiseCall.add l.id("Defect", def.info)
    raiseCall.add newAtom(nkStrLit, "abstract member called: " & m.name, def.info)
    result[6] = newTree(nkStmtList, def.info, newTree(nkRaiseStmt, def.info, raiseCall))

proc isMaskedShift(n: NsNode): bool =
  ## C# masks a shift count to the left operand's width (`1 << 33` is `2`), which a
  ## C shift by that much leaves undefined, so any count but a constant below 32
  ## goes through the library's masking procs. `>>>` always does.
  ## A user-defined `operator <<` is an ordinary call.
  if n.sons.len < 2 or n.sons[0] == nil or n.sons[0].typeKind notin {tkInt, tkChar}:
    return false
  let count = n.sons[1]
  if n.name == "ushr": return true
  n.name in ["shl", "shr"] and not (count != nil and count.kind == nsnIntLit and
                                    count.intVal >= 0 and count.intVal < 32)

proc shiftProc(op: string): string =
  case op
  of "shl": "nsShl"
  of "shr": "nsShr"
  of "ushr": "nsUShr"
  else: op

# (interfaces: see below)
# --- types ------------------------------------------------------------------

proc boxedImpl(l: Lowerer; name: string): bool =
  ## A class an interface value holds boxed: a struct (a copy, as C# boxes it), or
  ## an N# class deriving a native one (its handle, or N# reference).
  l.scope.classes.hasKey(name) and (l.scope.classes[name].classKind == ckStruct or
    (l.scope.nativeBased(name) and not l.scope.isNative(name)))

proc writtenName(n: NsNode): string =
  ## A receiver as written, `A.B.C`, when it is a chain of names; "" otherwise.
  if n == nil: return ""
  case n.kind
  of nsnIdent: n.name
  of nsnTypeName: n.name
  of nsnMember:
    let head = writtenName(n.body)
    if head.len == 0: "" else: head & "." & n.name
  else: ""

proc qualifiedName(l: Lowerer; written: string; info: TLineInfo; arity = 0): PNode =
  ## `Ns.T` written with its namespace: `Module.T`, the namespace's module naming
  ## it, so two namespaces' `T`s stay apart. The module is imported for qualified
  ## access only (`from "Ns" import nil`), so it brings nothing else into scope.
  ## nil for anything else: no qualifier, a class's nested type, a namespace this
  ## module declares, or a C# keyword type (`System.Int32`).
  ##
  ## A type the *library* declares (`System.Func<int, int>`, `System.Exception`) is
  ## the type itself: it is named as it is without the qualifier -- `Func2`, with
  ## the arity the library gives a generic delegate -- and imported by name from the
  ## module that declares it, since the program may say no `using` for it.
  let dot = written.rfind('.')
  if dot <= 0 or l.imports == nil: return nil
  let prefix = written[0 ..< dot]
  let last = written[dot + 1 .. ^1]
  if prefix in l.ownNamespaces or l.scope.classes.hasKey(unqualified(prefix)): return nil
  if l.surface.isLibraryNamespace(prefix) and not l.scope.classes.hasKey(last):
    let tn = nimTypeName(last)
    let withArity = tn & $arity
    let declared = (if l.surface.types.hasKey(withArity): withArity else: tn)
    if l.surface.types.hasKey(declared):
      l.imports.note(l.surface.types[declared].path, declared)
      return l.id(declared, info)
    if l.surface.isKnownTypeName(last):
      ## One Nim's own `system` declares (`Exception`): in scope everywhere.
      return l.id(tn, info)
  if not (isDeclaredNamespace(prefix) or l.surface.isLibraryNamespace(prefix)): return nil
  if nimTypeName(last) != last: return nil
  if prefix in l.scope.qualifiedNs:
    ## A namespace reached only qualified, which the module imports once named.
    l.scope.qualifiedUsed.incl prefix.split('.')[0]
  let path = namespaceModulePath(prefix)
  if not l.imports.byModule.hasKey(path): l.imports.byModule[path] = @[]
  newTree(nkDotExpr, info, l.id(path.split('/')[^1], info), l.id(last, info))

proc typeKey(n: PNode): string =
  ## A type expression spelled out, to tell instances apart.
  case n.kind
  of nkIdent: n.ident.s
  of nkBracketExpr, nkRefTy, nkPtrTy, nkTupleTy, nkIdentDefs, nkProcTy, nkFormalParams:
    var r = $n.kind & "("
    for x in n: r.add typeKey(x) & ","
    r & ")"
  else: $n.kind

proc isConcreteType(l: Lowerer; n: PNode): bool =
  ## Every name in `n` is a type the program or the library declares, or Nim's
  ## own: no type parameter, whichever routine or class it belongs to.
  case n.kind
  of nkIdent:
    let s = n.ident.s
    s notin l.procTypeParams and s notin l.clsTypeParams and
      (l.scope.classes.hasKey(s) or l.scope.enums.contains(s) or
       l.scope.delegates.hasKey(s) or l.surface.types.hasKey(s) or
       s in ["int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64",
             "int", "uint", "float32", "float64", "float", "bool", "char", "string",
             "RootRef", "Option", "NsArray", "NsMdArray"])
  else:
    for i in 0 ..< n.safeLen:
      if not l.isConcreteType(n[i]): return false
    true

proc typeToNim(l: Lowerer; t: NsNode; info: TLineInfo): PNode
proc objTypeToNim(l: Lowerer; t: NsNode; info: TLineInfo): PNode =
  ## A type as an object type: what `of`, `except` and a base clause name, where
  ## an exception class is not its `ref`.
  var ol = l
  ol.objTypes = true
  ol.typeToNim(t, info)

proc convCallee(t: PNode): PNode =
  ## A type used as a conversion: `(ref T)(x)` needs the parentheses.
  if t.kind == nkRefTy: newTree(nkPar, t.info, t) else: t

proc typeToNim(l: Lowerer; t: NsNode; info: TLineInfo): PNode =
  ## C# type reference to Nim type expression. `nsnEmpty`/`nsnVoidType` become
  ## `nkEmpty`, which is how "no type" is spelled in a Nim parameter list.
  if t == nil: return empty(info)
  case t.kind
  of nsnEmpty, nsnVoidType:
    result = empty(info)
  of nsnPointerType:
    ## `T*` is `ptr T`, `void*` Nim's `pointer`; a struct's pointer reaches its C
    ## layout (`nsC_<S>`), which is what C memory holds.
    if t.typ == nil or t.typ.kind == nsnVoidType: return l.id("pointer", info)
    let pointee =
      if t.typ.kind == nsnTypeName and l.scope.isMarshalableStruct(canonicalTypeName(t.typ.name)):
        l.id(cMirrorName(t.typ.name), info)
      else: l.typeToNim(t.typ, info)
    result = newTree(nkPtrTy, info, pointee)
  of nsnFnPtrType:
    ## `delegate* unmanaged<A, B, R>`: a C function, `proc (a0: A; a1: B): R {.cdecl.}`.
    let fp = newNodeI(nkFormalParams, info)
    fp.add (if t.sons.len > 0: l.typeToNim(t.sons[^1], info) else: empty(info))
    for i in 0 ..< t.sons.len - 1:
      fp.add l.identDefs("a" & $i, l.typeToNim(t.sons[i], info), info)
    let conv = (if t.strVal.len == 0: "nimcall" elif t.name == "stdcall": "stdcall" else: "cdecl")
    result = newTree(nkProcTy, info, fp, newTree(nkPragma, info, l.id(conv, info)))
  of nsnArrayType:
    ## `T[,]` is the library's `NsMdArray[T]`, a `T[]` its `NsArray[T]`: both
    ## references, as C# arrays are.
    result = newTree(nkBracketExpr, info,
                     l.id((if t.intVal > 1: "NsMdArray" else: "NsArray"), info),
                     l.typeToNim(t.typ, info))
  of nsnTupleType:
    ## A C# tuple is a Nim tuple whose fields are `Item1..ItemN`; element names are
    ## aliases `sema.nim` resolves to positions.
    result = newNodeI(nkTupleTy, info)
    for k, e in t.sons:
      result.add newTree(nkIdentDefs, info, l.id("Item" & $(k + 1), info),
                         l.typeToNim(e.typ, info), empty(info))
  of nsnNullableType:
    ## A value type needs `Option`; a reference is nullable already, so `Node?` is
    ## just `Node`, which is how C# reads it.
    var valueTyped = t.typeKind == tkNullable
    if t.typeKind == tkUnknown and t.typ != nil and t.typ.kind == nsnTypeName and
       t.typ.sons.len == 0:
      ## Inside a type argument (`Func<int?>`), which sema does not classify: a
      ## built-in value type, or a struct or enum this compilation declares.
      let inner = canonicalTypeName(t.typ.name)
      valueTyped = isNumericName(inner) or inner in ["bool", "char"] or
        l.scope.enums.contains(inner) or
        (l.scope.classes.hasKey(inner) and l.scope.classes[inner].decl != nil and
         l.scope.classes[inner].decl.classKind == ckStruct)
    if valueTyped:
      result = newTree(nkBracketExpr, info, l.id("Option", info),
                       l.typeToNim(t.typ, info))
    else:
      result = l.typeToNim(t.typ, info)
  of nsnTypeName:
    if '.' in t.name:
      ## A native class held through a handle keeps its own spelling (`NsH_...`).
      let last = unqualified(t.name)
      if not l.scope.classes.hasKey(last) or l.scope.handleRoot(last).len == 0:
        let q = l.qualifiedName(t.name, info, t.sons.len)
        if q != nil:
          if t.sons.len == 0: return q
          result = newTree(nkBracketExpr, info, q)
          for a in t.sons: result.add l.typeToNim(a, info)
          return
    var name = nimTypeName(t.name)
    ## `Func<T, R>`: a name C# overloads by arity is declared once per arity by the
    ## library, with the arity as a suffix (`Func2`), and that declaration is used.
    let arity = name & $t.sons.len
    if not l.scope.classes.hasKey(name) and l.surface.types.hasKey(arity):
      name = arity
    if not l.objTypes and l.scope.classes.hasKey(name):
      let root = l.scope.handleRoot(name)
      if root.len > 0:
        ## A handle class is held through its handle: `NsH_Node[Ball]`.
        return newTree(nkBracketExpr, info, l.id("NsH_" & root, info), l.id(name, info))
    result = l.id(name, info)
    if t.sons.len == 0 and not l.objTypes and
       l.surface.isExceptionType(name, l.scope.baseChain(name)):
      ## An exception class is a value object raised as a `ref`: a variable, field,
      ## parameter or result of one holds the reference, so it may be null and keeps
      ## the object's dynamic type (`Exception e = caught;`).
      return newTree(nkRefTy, info, result)
    if t.sons.len > 0:
      let be = newNodeI(nkBracketExpr, info)
      be.add result
      for a in t.sons: be.add l.typeToNim(a, info)
      result = be
      if l.imports != nil and l.scope.classes.hasKey(name) and
         l.scope.classes[name].classKind == ckClass and l.isConcreteType(be):
        let key = typeKey(be)
        if key notin l.imports.instanceKeys:
          l.imports.instanceKeys.incl key
          l.imports.instances.add copyTree(be)
  else:
    result = empty(info)

proc baseConv(l: Lowerer; info: TLineInfo): PNode =
  ## `this` seen as its base class: `Base(self)`, or `(ref Base)(self)` for an
  ## exception class, whose `self` is a `ref`.
  ## A generic base is named with its arguments, `Repo[int32](self)`.
  let base =
    if l.curBaseType != nil and l.curBaseType.sons.len > 0: l.typeToNim(l.curBaseType, info)
    else: l.id(nimTypeName(l.curBase), info)
  let target =
    if l.curIsException: newTree(nkRefTy, info, base)
    else: base
  result = newTree(nkCall, info, (if l.curIsException: newTree(nkPar, info, target)
                                  else: target), l.id("self", info))

proc baseCall(l: Lowerer; name: string; args: seq[PNode]; info: TLineInfo): PNode =
  ## `base.M(args)`: `procCall M(Base(self), args)`, which calls the base's own
  ## implementation instead of dispatching again.
  let call = newNodeI(nkCall, info)
  call.add l.memberIdent(name, nil, info)
  call.add l.baseConv(info)
  for a in args: call.add a
  result = newTree(nkCommand, info, l.id("procCall", info), call)

proc expr(l: Lowerer; n: NsNode): PNode
proc fresh(l: Lowerer; base: string): string
proc throwToNim(l: Lowerer; n: NsNode): PNode
proc checkedExprToNim(l: Lowerer; n: NsNode): PNode
proc assignToNim(l: Lowerer; n: NsNode): PNode
proc assignCore(l: Lowerer; n: NsNode): PNode
proc stabilize(l: Lowerer; target, later: NsNode; pre: var seq[PNode]): NsNode
proc withStableTarget(l: Lowerer; n: NsNode; pre: var seq[PNode]): NsNode
proc nativeParamType(l: Lowerer; t: NsNode; info: TLineInfo): PNode

proc paramDef(l: Lowerer; p: NsNode; sink = false): PNode =
  ## One parameter: `ref`/`out` are Nim `var` parameters (`in` is a read-only
  ## reference, which a Nim parameter already is), `params T[]` is `varargs[T]`,
  ## and a default value is Nim's. A constructor's or setter's plain parameter is
  ## `sink`: what it is given is usually stored, so the caller moves its last use
  ## in rather than copying it (a reference count, or a whole string).
  result = newNodeI(nkIdentDefs, p.info)
  result.add l.id(p.name, p.info)
  var t = l.typeToNim(p.typ, p.info)
  case p.paramMod
  of "ref", "out": t = newTree(nkVarTy, p.info, t)
  of "params":
    ## `params T[] xs` is an array the caller builds from its trailing arguments
    ## (see `argsToNim`), or passes whole; none at all is an empty one.
    if p.typ != nil and p.typ.kind == nsnArrayType and p.body == nil:
      result.add t
      result.add newTree(nkCall, p.info, l.id("nsNewArray", p.info),
                         l.typeToNim(p.typ.typ, p.info), newIntNode(nkIntLit, 0))
      return
  of "":
    if sink: t = newTree(nkBracketExpr, p.info, l.id("sink", p.info), t)
  else: discard
  result.add t
  ## A default an overload could be confused by is passed at each call instead.
  result.add (if p.body != nil and not p.noDefault: l.expr(p.body) else: empty(p.info))

proc exportedName(l: Lowerer; attrs: NsAttrs; name: string; info: TLineInfo): PNode =
  ## A C# member is exported to Nim unless it is private.
  if attrs.isExported:
    result = newTree(nkPostfix, info, l.id("*", info), l.nameNode(name, info))
  else:
    result = l.nameNode(name, info)


proc procPragmas(l: Lowerer; params: PNode; info: TLineInfo): PNode =
  ## `discardable` for a value-returning method or generated proc (`init`/`new`).
  ## Accessors and operators pass `withPragmas = false`: C# never calls them as a
  ## statement.
  if params.len > 0 and params[0].kind == nkEmpty:
    result = empty(info)
  else:
    let pragma = newNodeI(nkPragma, info)
    pragma.add l.id("discardable", info)
    result = pragma


proc mkProc(l: Lowerer; nameNode, params, body: PNode; info: TLineInfo;
            withPragmas = false; kind = nkProcDef): PNode =
  result = newNodeI(kind, info, 7)
  result[0] = nameNode
  result[1] = empty(info)
  result[2] = l.genericParams(l.procTypeParams, info)
  result[3] = params
  result[4] = if withPragmas: l.procPragmas(params, info) else: empty(info)
  result[5] = empty(info)
  result[6] = body


proc formalParams(l: Lowerer; ret: NsNode; params: seq[NsNode];
                  info: TLineInfo): PNode =
  result = newNodeI(nkFormalParams, info)
  result.add l.typeToNim(ret, info)
  for p in params: result.add l.paramDef(p)

# --- expressions ------------------------------------------------------------

proc stmtSeq(l: Lowerer; blk: NsNode): PNode
proc nilableReceiver(l: Lowerer; n: NsNode): bool
proc noneFromName(l: Lowerer; name: string; info: TLineInfo): PNode
proc someNamed(l: Lowerer; v: PNode; name: string; info: TLineInfo): PNode
proc noneCall(l: Lowerer; t: NsNode; info: TLineInfo): PNode
proc someCall(l: Lowerer; v: PNode; inner: NsNode; info: TLineInfo): PNode
proc presentOf(l: Lowerer; v: NsNode; info: TLineInfo): PNode
proc wrappedArg(l: Lowerer; a: NsNode): PNode

proc hasYield(n: NsNode): bool =
  ## Whether a body is an iterator block: it holds a `yield` of its own, not one of
  ## a nested local function.
  if n == nil or n.kind in {nsnLambda, nsnLocalFunc}: return false
  if n.kind == nsnYield: return true
  if hasYield(n.body): return true
  for x in n.sons:
    if hasYield(x): return true
  false


proc copyNsNode(n: NsNode): NsNode =
  ## A shallow copy: the same children, so a rewrite can replace some of them.
  result = NsNode()
  result[] = n[]

proc isTypeParamValue(l: Lowerer; e: NsNode): bool =
  ## A value whose static type is one of the enclosing type parameters.
  e != nil and e.kind != nsnNull and e.typeName.len > 0 and
    (e.typeName in l.procTypeParams or e.typeName in l.clsTypeParams)

proc rootName(t: NsNode): NsNode =
  ## The variable a target is reached from: `p` in `p`, `p.X.Y`, `p[i].X`.
  var t = t
  while t != nil and t.kind in {nsnMember, nsnIndex} and t.body != nil: t = t.body
  t

proc isValueParam(l: Lowerer; p: NsNode): bool =
  ## A parameter whose type is a value type, so writing a field of it writes the
  ## parameter itself: a struct, a tuple, a `T?`.
  if p.typ == nil: return false
  case p.typ.kind
  of nsnNullableType, nsnTupleType: true
  of nsnTypeName:
    let cn = canonicalTypeName(p.typ.name)
    l.scope.classes.hasKey(cn) and l.scope.classes[cn].classKind == ckStruct
  else: false

proc writtenParams(l: Lowerer; params: seq[NsNode]; body: NsNode): seq[NsNode] =
  ## The by-value parameters a body changes: assigns, steps, passes by `ref`/`out`,
  ## or, for a value type, writes a field of or calls a method on (a struct method
  ## may change `this`). C# lets a value parameter be assigned like any local
  ## (ECMA-334 15.6.2.2); a Nim parameter cannot be, so these get a local copy.
  result = @[]
  var byName = initTable[string, NsNode]()
  for p in params:
    if p != nil and p.name.len > 0 and p.paramMod notin ["ref", "out"]:
      byName[p.name] = p
  if byName.len == 0 or body == nil: return
  var hit = initHashSet[string]()
  proc note(l: Lowerer; t: NsNode; direct: bool) =
    let r = rootName(t)
    if r == nil or r.kind != nsnIdent or not byName.hasKey(r.name): return
    if direct or r != t and l.isValueParam(byName[r.name]): hit.incl r.name
  proc walk(l: Lowerer; n: NsNode) =
    if n == nil: return
    case n.kind
    of nsnAssign:
      if n.sons.len > 0 and n.sons[0] != nil:
        let t = n.sons[0]
        if t.kind == nsnTupleLit:
          for x in t.sons: l.note((if x.kind == nsnNamedArg: x.body else: x), x.kind == nsnIdent)
        else: l.note(t, t.kind == nsnIdent)
    of nsnIncDec: l.note(n.body, n.body != nil and n.body.kind == nsnIdent)
    of nsnRefArg: l.note(n.body, n.body != nil and n.body.kind == nsnIdent)
    of nsnDeconstruct:
      ## `(a, b) = (b, a)`: every target that is not a new declaration.
      for x in n.sons:
        if x != nil and x.kind != nsnLocalDecl: l.note(x, x.kind == nsnIdent)
    of nsnCall:
      if n.body != nil and n.body.kind == nsnMember and n.body.body != nil:
        l.note(n.body.body, false)
        let r = rootName(n.body.body)
        if r != nil and r == n.body.body and r.kind == nsnIdent and
           byName.hasKey(r.name) and l.isValueParam(byName[r.name]):
          hit.incl r.name
    else: discard
    l.walk(n.body)
    for x in n.sons: l.walk(x)
    for x in n.inits: l.walk(x)
  l.walk(body)
  for p in params:
    if p != nil and p.name in hit: result.add p

proc shadowParams(l: Lowerer; params: seq[NsNode]; body: NsNode;
                  info: TLineInfo): seq[PNode] =
  ## `var p = p` for every parameter the body changes.
  result = @[]
  for p in l.writtenParams(params, body):
    result.add newTree(nkVarSection, info, newTree(nkIdentDefs, info,
      l.id(p.name, info), empty(info), l.id(p.name, info)))

proc prependAll(into: PNode; pre: seq[PNode]): PNode =
  ## `into` (a statement list) with `pre` in front.
  if pre.len == 0: return into
  result = newNodeI(nkStmtList, into.info)
  for x in pre: result.add x
  if into.kind == nkStmtList:
    for x in into: result.add x
  else: result.add into

# --- stack frames ---------------------------------------------------------------
#
# Each member's procs carry `{.nsFrame: "Demo.Program.Run(Int32 n)".}`, so a stack
# trace names the C# member as .NET's does (see `nsharp/pragmas`). A proc with no
# C# counterpart (an allocator, a wrapper) records no frame at all.

proc clrTypeName(l: Lowerer; t: NsNode): string =
  ## A type as .NET's stack traces write it: `Int32`, `String`, ``List`1``,
  ## `Int32[]`, ``Nullable`1``.
  if t == nil: return "Object"
  case t.kind
  of nsnArrayType:
    result = l.clrTypeName(t.typ) & "[" & repeat(',', max(int(t.intVal), 1) - 1) & "]"
  of nsnNullableType:
    ## `int?` is ``Nullable`1``; a reference type's `?` is only an annotation.
    let inner = l.clrTypeName(t.typ)
    const values = ["Int32", "UInt32", "Int64", "UInt64", "Int16", "UInt16", "Byte",
                    "SByte", "Single", "Double", "Decimal", "Boolean", "Char", "IntPtr",
                    "UIntPtr"]
    let own = (if t.typ != nil and t.typ.kind == nsnTypeName: canonicalTypeName(t.typ.name) else: "")
    let lib = (if own.len > 0: l.surface.nimSpellingOf(own) else: "")
    let ownValue = own.len > 0 and (l.scope.enums.contains(own) or
                   l.scope.classes.hasKey(own) and l.scope.classes[own].classKind == ckStruct or
                   not l.scope.classes.hasKey(own) and lib.len > 0 and
                   l.surface.types.hasKey(lib) and l.surface.types[lib].isValue and
                   not l.surface.isExceptionType(lib)) or
                   t.typ != nil and t.typ.kind == nsnTupleType
    result = (if inner in values or ownValue: "Nullable`1" else: inner)
  of nsnTupleType: result = "ValueTuple`" & $t.sons.len
  of nsnTypeName:
    var name = t.name
    let dot = name.rfind('.')
    if dot >= 0: name = name[dot + 1 .. ^1]
    result =
      case name
      of "int": "Int32"
      of "uint": "UInt32"
      of "long": "Int64"
      of "ulong": "UInt64"
      of "short": "Int16"
      of "ushort": "UInt16"
      of "byte": "Byte"
      of "sbyte": "SByte"
      of "float": "Single"
      of "double": "Double"
      of "decimal": "Decimal"
      of "bool": "Boolean"
      of "char": "Char"
      of "string": "String"
      of "object", "dynamic": "Object"
      of "nint": "IntPtr"
      of "nuint": "UIntPtr"
      else: name
    if t.sons.len > 0: result.add "`" & $t.sons.len
  else: result = "Object"

const NsResultLocal = "nsResult"
  ## A local or parameter C# names `result`, which Nim's implicit `result` takes.

proc clrParams(l: Lowerer; params: seq[NsNode]): string =
  ## `Int32 a, String& b`: a `ref`, `out` or `in` parameter's type is a reference.
  result = ""
  for i, p in params:
    if i > 0: result.add ", "
    result.add l.clrTypeName(p.typ)
    if p.paramMod in ["ref", "out", "in"]: result.add '&'
    result.add ' ' & (if p.name == NsResultLocal: "result" else: p.name)

proc renameResultLocals(n: NsNode) =
  ## `int result`, `out int result`, `(result) => ...`: Nim's `result` is the
  ## routine's own, so a local, parameter or pattern variable of that name, and every
  ## bare name that reads one, is `nsResult` instead. A member named `result` is
  ## reached as one (`this.result`), and keeps its name.
  if n == nil: return
  if n.name == "result" and n.kind in {nsnIdent, nsnParam, nsnLocalDecl, nsnForeach,
                                       nsnCatch, nsnOutDecl, nsnPatVar, nsnPatType,
                                       nsnLocalFunc}:
    n.name = NsResultLocal
  for x in n.sons: renameResultLocals(x)
  for x in n.params: renameResultLocals(x)
  for x in n.inits: renameResultLocals(x)
  for x in n.initArgs: renameResultLocals(x)
  for x in n.primary: renameResultLocals(x)
  renameResultLocals(n.body)

proc renameResultArgs(n: NsNode) =
  ## ... and `F(result: 3)`, a named argument for a parameter renamed so.
  if n == nil: return
  if n.kind == nsnNamedArg and n.name == "result" and n.argParam != nil and
     n.argParam.name == NsResultLocal:
    n.name = NsResultLocal
  for x in n.sons: renameResultArgs(x)
  for x in n.params: renameResultArgs(x)
  for x in n.inits: renameResultArgs(x)
  for x in n.initArgs: renameResultArgs(x)
  renameResultArgs(n.body)

proc frameOwner(l: Lowerer; cls: NsNode): string =
  ## `Demo.Outer.Box`1`: the type a member's frame names (a stack trace joins a
  ## nested type to its outer one with a dot, where `Type.FullName` writes `+`).
  result = (if cls.outer.len > 0: cls.outer.replace('+', '.') & "." & cls.name else: cls.name)
  if cls.typeParams.len > 0: result.add "`" & $cls.typeParams.len
  if l.curNamespace.len > 0: result = l.curNamespace & "." & result

proc addPragma(pd, e: PNode) =
  if pd[4].kind == nkEmpty: pd[4] = newNodeI(nkPragma, pd.info)
  pd[4].add e

proc framed(l: Lowerer; pd: PNode; name: string) =
  pd.addPragma newTree(nkExprColonExpr, pd.info, l.id("nsFrame", pd.info),
                       newStrNode(nkStrLit, name))

proc unframed(l: Lowerer; pd: PNode) =
  pd.addPragma newTree(nkExprColonExpr, pd.info, l.id("stackTrace", pd.info),
                       l.id("off", pd.info))

proc nestedFrame(l: Lowerer; kind, name: string; params: seq[NsNode]): string =
  ## A lambda's or local function's frame inside the member being lowered:
  ## `Demo.Program.<Main>b__0()`, `Demo.Program.<Main>g__Local|1(Int32 n)`. .NET
  ## numbers them by its own ordinals; these count in source order.
  if l.frameScope.len == 0 or l.frameCount == nil: return ""
  var k = l.frameCount[]
  if kind == "g__" and l.frameLocals != nil and l.frameLocals[].hasKey(name):
    k = l.frameLocals[][name]
  else:
    if kind == "g__" and l.frameLocals != nil: l.frameLocals[][name] = k
    inc l.frameCount[]
  result = l.frameScope & kind & name & (if kind == "g__": "|" else: "") &
           $k & "(" & l.clrParams(params) & ")"

proc memberFrameName(m: NsNode): string =
  ## The name .NET gives a member's method: `<Main>$` for top-level statements,
  ## `Finalize` for a finalizer.
  if m.strVal == "topLevel": "<Main>$"
  elif m.strVal == "finalizer": "Finalize"
  else: m.name

proc procNameOf(pd: PNode): string =
  var n = pd[0]
  if n.kind == nkPostfix: n = n[1]
  if n.kind == nkAccQuoted:
    result = ""
    for x in n: result.add x.ident.s
  elif n.kind == nkIdent: result = n.ident.s
  else: result = ""

proc nameFrames(l: Lowerer; cls, m: NsNode; procs: openArray[PNode]) =
  ## The frames of the procs one member lowered to: the member's own, named as
  ## .NET names it (`get_X`, `..ctor`, `op_Addition`, `get_Item`), and none for
  ## the procs that only call it.
  let owner = l.frameOwner(cls)
  var first = true
  for pd in procs:
    if pd == nil or pd.kind notin {nkProcDef, nkMethodDef, nkFuncDef, nkConverterDef} or
       pd.len < 7 or pd[6].kind == nkEmpty:
      continue
    let pn = procNameOf(pd)
    var frame = ""
    case m.kind
    of nsnMethodDecl:
      if first:
        var name = memberFrameName(m)
        if m.explicitIface.len > 0:
          name = (if l.curNamespace.len > 0 and '.' notin m.explicitIface:
                    l.curNamespace & "." else: "") & m.explicitIface & "." & name
        if m.typeParams.len > 0:
          name.add '['
          for i, t in m.typeParams:
            if i > 0: name.add ','
            name.add t.name
          name.add ']'
        frame = owner & "." & name & "(" & l.clrParams(m.params) & ")"
    of nsnPropertyDecl:
      if pn.startsWith("nsAdd_"):
        frame = owner & ".add_" & m.name & "(" & l.clrTypeName(m.typ) & " value)"
      elif pn.startsWith("nsRemove_"):
        frame = owner & ".remove_" & m.name & "(" & l.clrTypeName(m.typ) & " value)"
      else:
        frame = owner & "." & (if pn.endsWith("="): "set_" & m.name & "(" & l.clrTypeName(m.typ) & " value)"
                               else: "get_" & m.name & "()")
    of nsnIndexerDecl:
      let ps = l.clrParams(m.params)
      frame = owner & "." & (if pn.endsWith("="):
                               "set_Item(" & ps & (if ps.len > 0: ", " else: "") &
                               l.clrTypeName(m.typ) & " value)"
                             else: "get_Item(" & ps & ")")
    of nsnOperatorDecl:
      if first:
        let unary = m.params.len == 1
        let op =
          case m.name
          of "+": (if unary: "op_UnaryPlus" else: "op_Addition")
          of "-": (if unary: "op_UnaryNegation" else: "op_Subtraction")
          of "*": "op_Multiply"
          of "/": "op_Division"
          of "%": "op_Modulus"
          of "==": "op_Equality"
          of "!=": "op_Inequality"
          of "<": "op_LessThan"
          of ">": "op_GreaterThan"
          of "<=": "op_LessThanOrEqual"
          of ">=": "op_GreaterThanOrEqual"
          of "!": "op_LogicalNot"
          of "~": "op_OnesComplement"
          of "++": "op_Increment"
          of "--": "op_Decrement"
          of "&": "op_BitwiseAnd"
          of "|": "op_BitwiseOr"
          of "^": "op_ExclusiveOr"
          of "<<": "op_LeftShift"
          of ">>": "op_RightShift"
          of ">>>": "op_UnsignedRightShift"
          of "true": "op_True"
          of "false": "op_False"
          of "implicit": "op_Implicit"
          of "explicit": "op_Explicit"
          else: "op_" & m.name
        frame = owner & "." & op & "(" & l.clrParams(m.params) & ")"
    of nsnCtorDecl:
      if pn.startsWith("init"): frame = owner & "..ctor(" & l.clrParams(m.params) & ")"
      elif pn.startsWith("nsStaticCtor_"): frame = owner & "..cctor()"
    else: discard
    first = false
    if frame.len > 0: l.framed(pd, frame) else: l.unframed(pd)

proc lambdaToNim(l: Lowerer; n: NsNode): PNode =
  ## A lambda as a Nim closure. `sema.nim` wrote the types of the delegate it
  ## converts to; one it could not place keeps `auto`, which Nim infers when the
  ## lambda is passed where a concrete proc type is expected.
  var l = l
  l.inIterator = false
  ## It may run any time later: no handle's object is kept across into it.
  if l.hoist != nil: l.hoist = NsHoist(moves: l.hoist.moves)
  let fp = newNodeI(nkFormalParams, n.info)
  if n.typ != nil: fp.add l.typeToNim(n.typ, n.info)
  else: fp.add l.id("auto", n.info)
  for p in n.params:
    let defs = newNodeI(nkIdentDefs, p.info)
    defs.add l.id(p.name, p.info)
    if p.typ != nil: defs.add l.typeToNim(p.typ, p.info)
    else: defs.add l.id("auto", p.info)
    defs.add empty(p.info)
    fp.add defs
  result = newNodeI(nkLambda, n.info, 7)
  for i in 0 .. 6: result[i] = empty(n.info)
  result[3] = fp
  var body = n.body
  if body != nil and body.strVal == "expr" and body.sons.len == 1 and n.typ != nil and
     n.typ.kind in {nsnVoidType, nsnEmpty}:
    ## `() => x++` for a delegate returning nothing: the expression is a statement
    ## (12.19.4), so its value, if it has one, is dropped.
    let st = nsn(nsnExprStmt, body.sons[0].info)
    st.body = body.sons[0]
    body = copyNsNode(body)
    body.strVal = ""
    body.sons = @[st]
  result[6] = if body != nil: prependAll(l.stmtSeq(body), l.shadowParams(n.params, body, n.info))
              else: emptyList(n.info)
  let frame = l.nestedFrame("b__", "", n.params)
  if frame.len > 0: l.framed(result, frame)
  if n.captures.len > 0:
    ## It captures loop-body cells: made by a factory taking them, so it keeps
    ## this iteration's (see `markLoopCells`).
    let ffp = newNodeI(nkFormalParams, n.info)
    ffp.add l.id("auto", n.info)
    let call = newNodeI(nkCall, n.info)
    for c in n.captures:
      ffp.add newTree(nkIdentDefs, n.info, l.id(c, n.info),
                      newTree(nkCall, n.info, l.id("typeof", n.info), l.id(c, n.info)),
                      empty(n.info))
    let factory = newNodeI(nkLambda, n.info, 7)
    for i in 0 .. 6: factory[i] = empty(n.info)
    factory[3] = ffp
    factory[6] = newTree(nkStmtList, n.info, result)
    call.add newTree(nkPar, n.info, factory)
    for c in n.captures: call.add l.id(c, n.info)
    result = call

proc mayMutate(n: NsNode): bool =
  ## Whether evaluating `n` may change a variable: it calls something, assigns, or
  ## steps one. A lambda's body does not run where the lambda is written.
  if n == nil or n.kind in {nsnLambda, nsnLocalFunc}: return false
  if n.kind in {nsnCall, nsnAssign, nsnIncDec, nsnNew}: return true
  if mayMutate(n.body): return true
  for x in n.sons:
    if mayMutate(x): return true
  false

proc isLocation(n: NsNode): bool =
  ## A variable, field or element: something Nim reads where it is used rather
  ## than where it is written.
  n != nil and n.typeKind != tkType and
    (n.kind == nsnIdent or n.kind == nsnIndex or
     (n.kind == nsnMember and n.body != nil))

proc ordered(l: Lowerer; operand: NsNode; later: openArray[NsNode]): PNode =
  ## C# evaluates operands left to right, so `x + F()` reads `x` before `F` runs.
  ## Nim reads a variable operand only when the operation happens, after every
  ## call in it, so one that a later operand may change is copied first by `nsVal`.
  result = l.expr(operand)
  if not isLocation(operand): return
  for x in later:
    if mayMutate(x):
      return newTree(nkCall, operand.info, l.id("nsVal", operand.info), result)

proc nameableType(l: Lowerer; t: NsNode): bool =
  ## Whether the caller can spell `t`: not a type parameter of the callee.
  if t == nil: return false
  case t.kind
  of nsnArrayType, nsnNullableType: l.nameableType(t.typ)
  of nsnTypeName:
    let n = canonicalTypeName(t.name)
    if t.sons.len == 0 and n notin l.procTypeParams and n notin l.clsTypeParams and
       not l.scope.classes.hasKey(n) and not l.scope.enums.contains(n) and
       not l.scope.delegates.hasKey(n) and not l.surface.isKnownTypeName(n) and
       nimTypeName(n) == n and
       n notin ["int", "long", "short", "byte", "sbyte", "uint", "ulong", "ushort",
                "float", "double", "decimal", "bool", "char", "string", "object"]:
      return false
    for x in t.sons:
      if not l.nameableType(x): return false
    true
  else: true

proc arrayOf(l: Lowerer; et: NsNode; elems: PNode; info: TLineInfo): PNode =
  ## The array of the elements in the bracket `elems`: `nsArrayFrom[T]([...])`,
  ## whose literal takes `T` as its element type, or with a type the caller cannot
  ## name, Nim's inference over `@[...]`.
  if et != nil and l.nameableType(et):
    newTree(nkCall, info, newTree(nkBracketExpr, info, l.id("nsArrayFrom", info),
                                  l.typeToNim(et, info)), elems)
  else:
    newTree(nkCall, info, l.id("nsArrayOf", info), newTree(nkPrefix, info, l.id("@", info), elems))

proc argsToNim(l: Lowerer; call: NsNode): seq[PNode] =
  ## A call's arguments, each with the conversion `sema.nim` chose, read in order
  ## (see `ordered`); a `ref`/`out` argument is the variable itself.
  result = @[]
  var pack: PNode = nil
  for i, a in call.sons:
    var arg = l.wrappedArg(a)
    let v = (if a.kind == nsnNamedArg: a.body else: a)
    if v != nil and v.kind != nsnRefArg and v.conv.len == 0 and v.argConv == acNone and
       isLocation(v):
      for x in call.sons[i + 1 .. ^1]:
        if mayMutate(x):
          arg = newTree(nkCall, a.info, l.id("nsVal", a.info), arg)
          break
    if a.argForward and not a.argElement:
      ## Passed on to a C++ constructor as it is: converted to the parameter's type,
      ## and kept from C's `varargs` treatment of a `string`.
      let pt = (if a.argParam != nil: a.argParam.typ else: nil)
      if pt != nil and pt.kind == nsnTypeName and l.nameableType(pt) and v != nil and
         v.kind != nsnNull:
        ## A native class's constructor takes C++'s types (`const char*`).
        arg = newTree(nkCall, a.info, (if a.argNative: l.nativeParamType(pt, a.info)
                                       else: l.typeToNim(pt, a.info)), arg)
      result.add newTree(nkCall, a.info, l.id("nsFwd", a.info), arg)
      continue
    if a.argElement and a.argParam != nil and a.argParam.typ != nil and
       a.argParam.typ.kind == nsnArrayType:
      ## An element of a `params` array: the trailing arguments become one array.
      if pack == nil:
        pack = newNodeI(nkBracket, a.info)
        let et = a.argParam.typ.typ
        result.add l.arrayOf(et, pack, a.info)
      let et = a.argParam.typ.typ
      if et.kind == nsnTypeName and l.nameableType(et) and v != nil and v.kind != nsnNull:
        ## Each element converted to the element type, as in an array literal.
        arg = newTree(nkCall, a.info, l.typeToNim(et, a.info), arg)
      pack.add arg
      continue
    result.add arg

proc newToNim(l: Lowerer; n: NsNode): PNode
proc stmt(l: Lowerer; n: NsNode): PNode

proc newWithInits(l: Lowerer; n: NsNode): PNode =
  ## `new T(...) { inits }`: `block: (var tmp = newT(...); <inits>; tmp)`, the
  ## statements being the ones `sema.nim` derived from the initialiser.
  let info = n.info
  let inits = n.inits
  n.inits = @[]
  let created = l.newToNim(n)
  n.inits = inits
  let body = newNodeI(nkStmtList, info)
  body.add newTree(nkVarSection, info, newTree(nkIdentDefs, info, l.id(n.strVal, info),
                                              empty(info), created))
  for st in inits: body.add l.stmt(st)
  body.add l.id(n.strVal, info)
  result = newTree(nkBlockExpr, info, empty(info), body)

proc newToNim(l: Lowerer; n: NsNode): PNode =
  ## `new T(args)` becomes `newT(args)`, carrying generic arguments over.
  if n.inits.len > 0 and n.strVal.len > 0: return l.newWithInits(n)
  if n.typ != nil and n.typ.kind == nsnTypeName and n.typ.sons.len == 0 and
     not l.scope.classes.hasKey(canonicalTypeName(n.typ.name)) and
     l.surface.isExceptionType(nimTypeName(n.typ.name)):
    ## `new InvalidOperationException(msg)` of the library: `nsNewException(T, msg)`,
    ## a `ref`, as `throw` makes it, with the message .NET's constructor makes.
    let q = l.qualifiedName(n.typ.name, n.info, 0)
    result = newTree(nkCall, n.info, l.id("nsNewException", n.info),
                     (if q != nil: q else: l.id(nimTypeName(n.typ.name), n.info)))
    for a in n.sons: result.add l.expr(a)
    if l.imports != nil: l.imports.note(namespaceModulePath("System"), "nsNewException")
    return
  if n.typ != nil and n.typ.kind == nsnTypeName and n.typ.name in l.procTypeParams:
    ## `new T()` on a type parameter (`where T : new()`): every class declares
    ## `nsCreate` over its typedesc, and the intrinsics do for value types.
    return newTree(nkCall, n.info, l.id("nsCreate", n.info), l.id(n.typ.name, n.info))
  if n.typ != nil and n.typ.kind == nsnTypeName and n.sons.len == 0 and
     l.scope.classes.hasKey(canonicalTypeName(n.typ.name)) and
     l.scope.classes[canonicalTypeName(n.typ.name)].classKind == ckStruct and
     not l.scope.isNative(canonicalTypeName(n.typ.name)):
    var declared = false
    for ps in l.scope.classes[canonicalTypeName(n.typ.name)].ctorParams:
      if ps.len == 0: declared = true
    if not declared and l.scope.classes[canonicalTypeName(n.typ.name)].ctorParams.len > 0:
      ## `new S()` on a struct that declares only other constructors: its default,
      ## every field zero (ECMA-334 16.4.9).
      return newTree(nkCall, n.info, l.id("default", n.info), l.typeToNim(n.typ, n.info))
  var callee =
    if n.typ != nil and n.typ.kind == nsnTypeName:
      l.id("new" & nimTypeName(n.typ.name), n.info)
    else:
      l.id("new", n.info)
  if n.typ != nil and n.typ.kind == nsnTypeName and '.' in n.typ.name:
    ## `new Ns.T(...)`: `Module.newT`, as the type is named.
    let q = l.qualifiedName(n.typ.name, n.info, n.typ.sons.len)
    if q != nil and q.kind == nkDotExpr:
      callee = newTree(nkDotExpr, n.info, q[0], l.id("new" & nimTypeName(n.typ.name), n.info))
    elif q != nil and q.kind == nkIdent:
      ## A library type, named without its namespace.
      callee = l.id("new" & q.ident.s, n.info)
      if l.imports != nil and l.surface.types.hasKey(q.ident.s) and
         not l.surface.isExceptionType(q.ident.s):
        ## The constructor lives beside the type, so it is imported with it.
        l.imports.note(l.surface.types[q.ident.s].path, "new" & q.ident.s)
  if n.typ != nil and n.typ.kind == nsnTypeName and n.typ.sons.len > 0:
    ## Spelled through `typeToNim` too, which notes the instance it names.
    discard l.typeToNim(n.typ, n.info)
    let be = newNodeI(nkBracketExpr, n.info)
    be.add callee
    for a in n.typ.sons: be.add l.typeToNim(a, n.info)
    callee = be
  result = newNodeI(nkCall, n.info)
  result.add callee
  for a in l.argsToNim(n): result.add a

proc isUserStatic(l: Lowerer; m: NsNode): bool =
  ## `C.M` naming a static method of a class this compilation declares.
  let owner = m.body.typeName
  if not l.scope.classes.hasKey(owner): return false
  let info = l.scope.findMemberInfo(owner, m.name)
  info.isMethod and info.isStatic and not info.isExtension and m.name != "Main"

proc typeRef(l: Lowerer; t: NsNode): PNode =
  ## A type used as a value (a static member's receiver): `C`, or `C[int32]` when it
  ## carries type arguments.
  result = l.qualifiedName(writtenName(t), t.info)
  if result == nil: result = l.id(nimTypeName(t.typeName), t.info)
  if t.typeArgs.len > 0:
    result = newTree(nkBracketExpr, t.info, result)
    for a in t.typeArgs: result.add l.typeToNim(a, t.info)

proc qualifiedOnlyRef(l: Lowerer; t: NsNode): PNode =
  ## A type of a namespace reached qualified that the scope leaves out
  ## (`Tools.Console`, `Tools.Console.Inner`): its namespace's module naming it.
  let c = l.scope.qualifiedOnly[writtenName(t)]
  if c.namespace.len == 0: return l.typeRef(t)
  let path = namespaceModulePath(c.namespace)
  if l.imports != nil and not l.imports.byModule.hasKey(path): l.imports.byModule[path] = @[]
  newTree(nkDotExpr, t.info, l.id(path.split('/')[^1], t.info), l.id(c.name, t.info))

proc checkNil(l: Lowerer; recvNs: NsNode; recv: PNode; info: TLineInfo): PNode
proc recvOf(l: Lowerer; n: NsNode): PNode
proc isHoisted(l: Lowerer; name: string): bool
proc assignsLocal(n: NsNode; name: string): bool
proc cacheResets(l: Lowerer; info: TLineInfo): seq[PNode]
proc afterThrow(l: Lowerer; body: PNode): PNode
proc isManagedNativeField(l: Lowerer; cls, field: string): bool
proc isHandleValue(l: Lowerer; n: NsNode): bool
proc memberReceiverChecked(l: Lowerer; n: NsNode): PNode

proc indexArgToNim(l: Lowerer; a: NsNode): PNode =
  ## An array or string index: `^k` is Nim's own; a C# range `a..b` excludes `b`,
  ## so it is Nim's `a ..< b`, and an open end is `.. ^1`.
  let info = a.info
  if a.kind == nsnFromEnd:
    return newTree(nkPrefix, info, l.id("^", info), l.expr(a.body))
  if a.kind != nsnRange: return l.expr(a)
  let start = (if a.sons[0] == nil: newIntNode(nkIntLit, 0) else: l.indexArgToNim(a.sons[0]))
  let stop = a.sons[1]
  if stop == nil or (stop.kind == nsnFromEnd and stop.body.kind == nsnIntLit and
                     stop.body.intVal == 0):
    return newTree(nkInfix, info, l.id("..", info), start,
                   newTree(nkPrefix, info, l.id("^", info), newIntNode(nkIntLit, 1)))
  newTree(nkInfix, info, l.id("..<", info), start, l.indexArgToNim(stop))

proc typedescQualifier(l: Lowerer; qual: NsNode; member: string): string =
  ## The library's spelling of a type qualifier (`int32` for `int`) when the library
  ## declares the member over that type's `typedesc`; "" for any other qualifier,
  ## such as a static class whose members take no type (`Console.WriteLine`).
  if qual == nil: return ""
  let tn = (if qual.typeName.len > 0: qual.typeName else: qual.name)
  if tn.len == 0 or l.scope.classes.hasKey(tn): return ""
  let spelled = l.surface.nimSpellingOf(tn)
  if spelled.len == 0: return ""
  for m in l.surface.overloads(tn, l.surface.kindOfName(tn), member):
    if m.paramTypes.len > 0:
      let p0 = m.paramTypes[0]
      if p0.kind == nkBracketExpr and p0.len == 2 and p0[0].kind == nkIdent and
         p0[0].ident.s == "typedesc":
        return spelled
  ""

proc callToNim(l: Lowerer; n: NsNode): PNode =
  var callee = n.body
  if n.strVal == "fnptr":
    ## `f(a, b)` through a function pointer held in a local or a field; the
    ## parentheses keep `C.f(a)` from reading as a call of `f` with `C`.
    result = newTree(nkCall, n.info, newTree(nkPar, n.info, l.expr(callee)))
    for a in n.sons: result.add l.expr(a)
    return
  if callee != nil and callee.kind == nsnMember and callee.strVal == "event":
    ## Raising an event: each of its handlers is called.
    result = newTree(nkCall, n.info, l.id("Invoke", n.info),
                     newTree(nkDotExpr, n.info, l.memberReceiverChecked(callee),
                             l.id(callee.name, n.info)))
    for a in l.argsToNim(n): result.add a
    return
  if callee != nil and callee.kind == nsnMember and callee.body != nil and
     callee.body.kind == nsnBase:
    ## `base.M(args)` calls the base implementation, never the override.
    var args: seq[PNode] = @[]
    for a in l.argsToNim(n): args.add a
    if l.curClass != nil and l.curClass.typ != nil and l.scope.nativeBased(l.curClass.name) and
       not l.scope.isNative(l.curClass.name):
      ## In a class deriving a native one: a native base's C++ function, called
      ## without dispatch, or an N# base class's own body.
      let mi = l.scope.findMemberInfo(canonicalTypeName(l.curClass.typ.name), callee.name)
      if mi.name.len > 0 and l.scope.isNative(mi.owner):
        result = newTree(nkCall, n.info,
                         l.id("nsBaseCall_" & mi.owner & "_" & callee.name, n.info),
                         l.id("self", n.info))
      else:
        result = newTree(nkCall, n.info, l.id(callee.name, n.info),
                         newTree(nkCast, n.info, newTree(nkPtrTy, n.info, l.id(mi.owner, n.info)),
                                 l.id("self", n.info)))
      for a in args: result.add a
      return
    return l.baseCall(callee.name, args, n.info)
  if callee != nil and callee.kind == nsnMember and callee.body != nil and
     l.scope.classes.hasKey(callee.body.typeName):
    let m = l.scope.findMemberInfo(callee.body.typeName, callee.name)
    if m.name.len > 0 and m.isMethod and l.scope.isNative(m.owner):
      ## A native member: `M(receiver, typedesc args, args)`, the receiver being the
      ## C++ object (a handle dereferenced) or, for a static one, the type.
      result = newTree(nkCall, n.info, l.id(callee.name, n.info))
      if callee.body.typeKind == tkType:
        var ol = l
        ol.objTypes = true
        let q = l.qualifiedName(writtenName(callee.body), n.info)
        result.add (if q != nil: q
                    else: ol.typeToNim(nsnTypeName(callee.body.typeName, n.info), n.info))
      elif l.scope.onHandle(callee.body.typeName, callee.name):
        ## A member of the handle: the handle itself, unchecked (`this`'s own,
        ## through `SelfHandle`).
        result.add l.expr(callee.body)
      else:
        result.add l.recvOf(callee.body)
      for t in callee.typeArgs: result.add l.typeToNim(t, n.info)
      for a in l.argsToNim(n): result.add a
      return
  if callee != nil and callee.kind == nsnMember and callee.strVal == "extension":
    ## `x.M(args)` through an extension method: `M(x, args)`. C# calls it on a
    ## null `x` too, so the receiver is not checked.
    var bare = l
    bare.nilChecks = false
    let head =
      if callee.typeArgs.len > 0:
        let h = newTree(nkBracketExpr, n.info, l.id(callee.name, n.info))
        for t in callee.typeArgs: h.add l.typeToNim(t, n.info)
        h
      else: l.id(callee.name, n.info)
    result = newTree(nkCall, n.info, head, bare.expr(callee.body))
    for a in l.argsToNim(n): result.add a
    return
  ## `Class.Method(...)` / `Console.WriteLine(...)`: the qualifier is dropped,
  ## because it is a namespace or a static class. `sema.nim` decides this and
  ## records it as `tkType`.
  if callee != nil and callee.kind == nsnMember and callee.body != nil and
     callee.body.typeKind == tkType and l.isUserStatic(callee):
    ## `C.M(args)` on a class this compilation declares: `M(C, args)`, the
    ## class's typedesc first, with any written type arguments.
    let head =
      if callee.typeArgs.len > 0:
        let h = newTree(nkBracketExpr, n.info, l.memberIdent(callee.name, callee.body, n.info))
        for t in callee.typeArgs: h.add l.typeToNim(t, n.info)
        h
      else: l.memberIdent(callee.name, callee.body, n.info)
    result = newTree(nkCall, n.info, head, l.typeRef(callee.body))
    for a in l.argsToNim(n): result.add a
    return
  if callee != nil and callee.kind == nsnMember and callee.body != nil and
     callee.body.typeKind == tkType:
    let q = l.typedescQualifier(callee.body, callee.name)
    if q.len > 0:
      ## `int.Parse(s)`: the library declares it over the type (`typedesc[int32]`),
      ## so the type is its first argument, as for `int.MaxValue`.
      l.noteMemberImport(callee)
      var qt = l.id(q, n.info)
      if callee.body.typeArgs.len > 0:
        ## `Comparer<int>.Create(f)`: the generic type, instantiated.
        qt = newTree(nkBracketExpr, n.info, qt)
        for a in callee.body.typeArgs: qt.add l.typeToNim(a, n.info)
      ## The member's own type arguments (`Enumerable.Empty<int>()`), written.
      var head = l.id(callee.name, n.info)
      if callee.typeArgs.len > 0:
        head = newTree(nkBracketExpr, n.info, head)
        for t in callee.typeArgs: head.add l.typeToNim(t, n.info)
      result = newTree(nkCall, n.info, head, qt)
      for a in l.argsToNim(n): result.add a
      return
  if callee != nil and callee.kind == nsnMember and callee.body != nil and
     callee.body.typeKind == tkType and l.scope.qualifiedOnly.hasKey(writtenName(callee.body)):
    ## `Tools.Console.Print(s)`: a type of a namespace reached qualified, named like
    ## another in scope, stays qualified: `Print(Tools.Console, s)`.
    result = newTree(nkCall, n.info, l.id(callee.name, n.info), l.qualifiedOnlyRef(callee.body))
    for a in l.argsToNim(n): result.add a
    return
  if callee != nil and callee.kind == nsnMember and callee.body != nil and
     callee.body.typeKind == tkType:
    ## A static member: the qualifier is dropped, so the declaration it names has to
    ## be imported by name.
    l.noteMemberImport(callee)
    let ta = callee.typeArgs
    callee = nsnIdent(callee.name, callee.info)
    callee.typeArgs = ta
  ## `x.Method(...)` on a reference: C# tests the receiver before the call, so a
  ## method that never touches `self` still throws on a nil receiver. `this` is
  ## left alone, and the whole check follows the compilation's nil-check setting.
  result = newNodeI(nkCall, n.info)
  if callee.kind == nsnMember and callee.typeArgs.len > 0:
    ## `x.M<int>(a)`: Nim cannot put type arguments after a dot-call, so the call
    ## is written `M[int32](x, a)`.
    ## A method of a generic class takes the class's type parameters first, and Nim
    ## infers none of them once any is written: the receiver's type arguments are
    ## written too when they are known, and otherwise all are left to inference.
    let owner = callee.body.typeName
    let clsTps = (if l.scope.classes.hasKey(owner): l.scope.classes[owner].typeParams
                  else: @[])
    let recvArgs = (if callee.body.rtype != nil and callee.body.rtype.kind == nsnTypeName:
                      callee.body.rtype.sons else: @[])
    if clsTps.len > 0 and recvArgs.len != clsTps.len:
      result.add l.memberIdent(callee.name, callee.body, n.info)
    else:
      let head = newTree(nkBracketExpr, n.info, l.memberIdent(callee.name, callee.body, n.info))
      if clsTps.len > 0:
        for t in recvArgs: head.add l.typeToNim(t, n.info)
      for t in callee.typeArgs: head.add l.typeToNim(t, n.info)
      result.add head
    var recv = l.expr(callee.body)
    if l.nilChecks and l.nilableReceiver(callee.body):
      recv = l.checkNil(callee.body, recv, n.info)
    result.add recv
    for a in l.argsToNim(n): result.add a
    return
  if callee.kind == nsnIdent and callee.paramMod == "cells":
    ## A local function taking cells: this iteration's, after the arguments.
    result.add l.id(callee.name, n.info)
    for a in l.argsToNim(n): result.add a
    for c in callee.argParam.captures: result.add l.id(c, n.info)
    return
  if l.nilChecks and callee.kind == nsnMember and l.nilableReceiver(callee.body):
    let checked = l.checkNil(callee.body, l.expr(callee.body), n.info)
    result.add newTree(nkDotExpr, n.info, checked,
                       l.memberIdent(callee.name, callee.body, n.info))
  else:
    result.add l.expr(callee)
  for a in l.argsToNim(n): result.add a

proc cellFuncDelegate(l: Lowerer; n: NsNode): PNode =
  ## A local function taking cells, as a delegate: a closure made by a factory that
  ## takes this iteration's cells, as a lambda capturing them is.
  let f = n.argParam
  let fp = l.formalParams(f.typ, f.params, n.info)
  let call = newTree(nkCall, n.info, l.id(f.name, n.info))
  for p in f.params: call.add l.id(p.name, n.info)
  for c in f.captures: call.add l.id(c, n.info)
  let lam = newNodeI(nkLambda, n.info, 7)
  for i in 0 .. 6: lam[i] = empty(n.info)
  lam[3] = fp
  lam[6] = newTree(nkStmtList, n.info, call)
  let ffp = newTree(nkFormalParams, n.info, l.id("auto", n.info))
  let made = newNodeI(nkCall, n.info)
  for c in f.captures:
    ffp.add newTree(nkIdentDefs, n.info, l.id(c, n.info),
                    newTree(nkCall, n.info, l.id("typeof", n.info), l.id(c, n.info)),
                    empty(n.info))
  let factory = newNodeI(nkLambda, n.info, 7)
  for i in 0 .. 6: factory[i] = empty(n.info)
  factory[3] = ffp
  factory[6] = newTree(nkStmtList, n.info, lam)
  made.add newTree(nkPar, n.info, factory)
  for c in f.captures: made.add l.id(c, n.info)
  result = made

proc staticMethodGroup(l: Lowerer; n: NsNode): PNode =
  ## `IntFn f = Double;`: the method's parameters, forwarded with the class first.
  let m = l.scope.findMemberInfo(n.body.typeName, n.name)
  let fp = newNodeI(nkFormalParams, n.info)
  fp.add l.typeToNim(m.typ, n.info)
  let call = newTree(nkCall, n.info, l.memberIdent(n.name, n.body, n.info), l.typeRef(n.body))
  for p in m.params:
    fp.add newTree(nkIdentDefs, n.info, l.id(p.name, n.info), l.typeToNim(p.typ, n.info),
                   empty(n.info))
    call.add l.id(p.name, n.info)
  result = newNodeI(nkLambda, n.info, 7)
  for i in 0 .. 6: result[i] = empty(n.info)
  result[3] = fp
  result[6] = newTree(nkStmtList, n.info, call)

proc instanceMethodGroup(l: Lowerer; n: NsNode): PNode =
  ## `block: (let nsRecv = obj; proc (params): R = nsRecv.M(params))`
  let m = l.scope.findMemberInfo(n.body.typeName, n.name)
  let fp = newNodeI(nkFormalParams, n.info)
  fp.add l.typeToNim(m.typ, n.info)
  let call = newTree(nkCall, n.info, newTree(nkDotExpr, n.info, l.id("nsRecv", n.info),
                                             l.memberIdent(n.name, n.body, n.info)))
  for p in m.params:
    fp.add newTree(nkIdentDefs, n.info, l.id(p.name, n.info), l.typeToNim(p.typ, n.info),
                   empty(n.info))
    call.add l.id(p.name, n.info)
  let lam = newNodeI(nkLambda, n.info, 7)
  for i in 0 .. 6: lam[i] = empty(n.info)
  lam[3] = fp
  lam[6] = newTree(nkStmtList, n.info, call)
  var recv = l.expr(n.body)
  if l.nilChecks and l.nilableReceiver(n.body):
    recv = newTree(nkCall, n.info, l.id("nsCheckNil", n.info), recv)
  result = newTree(nkBlockExpr, n.info, empty(n.info), newTree(nkStmtList, n.info,
    newTree(nkLetSection, n.info, newTree(nkIdentDefs, n.info, l.id("nsRecv", n.info),
                                         empty(n.info), recv)), lam))

proc conversionProcName*(op: NsNode): string =
  ## `implicit operator double(Vec)` is the converter `nsImplicit_double`; an
  ## explicit one an ordinary proc, called by a cast.
  (if op.name == "implicit": "nsImplicit_"
   elif op.attrs.isChecked: "nsExplicitChecked_"
   else: "nsExplicit_") & mangleType(op.typ)

proc checkedOperatorName*(op: NsNode): string =
  ## `operator checked +` is an ordinary proc, which a `checked` context calls by
  ## name: Nim has one `+` per signature, and that one is the unchecked operator.
  let word = case op.name
             of "+": "Add"
             of "-": (if op.params.len == 1: "Neg" else: "Sub")
             of "*": "Mul"
             else: "Div"
  "nsChecked" & word

proc isCheckedOp(n: NsNode): bool =
  n.argParam != nil and n.argParam.kind == nsnOperatorDecl and
    n.argParam.attrs.isChecked and n.argParam.name notin ["implicit", "explicit"]


proc castToNim(l: Lowerer; n: NsNode): PNode =
  ## `(T)x` is a Nim conversion, and also how a ref object is downcast. A `T?`
  ## operand is unwrapped first, since the conversion applies to the value. A cast
  ## through a user-defined conversion calls the operator.
  if n.argParam != nil and n.argParam.kind == nsnOperatorDecl:
    return newTree(nkCall, n.info, l.id(conversionProcName(n.argParam), n.info),
                   l.expr(n.body))
  if l.isHandleValue(n.body) and n.typ != nil and n.typ.kind == nsnTypeName and
     l.scope.classes.hasKey(canonicalTypeName(n.typ.name)) and
     l.scope.handleRoot(canonicalTypeName(n.typ.name)).len > 0:
    ## `(Crate)e` on a handle: the handle of the other class, which the engine
    ## may check.
    return newTree(nkCall, n.info, l.id("nsAs", n.info), l.expr(n.body),
                   l.typeToNim(n.typ, n.info))
  if n.strVal == "unbox":
    ## `(T)o` on an `object`: the boxed value, or the reference downcast.
    return newTree(nkCall, n.info, l.id("nsUnbox", n.info), l.expr(n.body),
                   l.typeToNim(n.typ, n.info))
  if n.typ != nil and n.typ.kind == nsnNullableType and n.typ.typeKind == tkNullable:
    ## `(int?)x`: to a `T?`. From another `T?` the conversion is lifted (absent
    ## stays absent); from a value, the value converted and wrapped.
    if n.body != nil and n.body.typeKind == tkNullable:
      return newTree(nkCall, n.info, l.id("nsOptAs", n.info), l.expr(n.body),
                     l.typeToNim(n.typ.typ, n.info))
    if n.body != nil and n.body.kind == nsnNull:
      return l.noneCall(n.typ, n.info)
    return l.someCall(newTree(nkCall, n.info, l.typeToNim(n.typ.typ, n.info), l.expr(n.body)),
                      n.typ.typ, n.info)
  if n.typ != nil and n.typ.kind == nsnTypeName and n.typeKind == tkClass and
     n.body != nil and n.body.typeKind == tkClass and
     canonicalTypeName(n.body.typeName) != canonicalTypeName(n.typ.name) and
     l.scope.classes.hasKey(canonicalTypeName(n.typ.name)) and
     l.scope.classes[canonicalTypeName(n.typ.name)].classKind == ckClass and
     not l.scope.nativeBased(canonicalTypeName(n.typ.name)):
    ## `(Dog)animal`: the downcast tested once, failing with .NET's message, which
    ## names both types.
    return newTree(nkCall, n.info, l.id("nsDowncast", n.info), l.expr(n.body),
                   l.typeToNim(n.typ, n.info))
  if l.checked and n.typeKind == tkInt and n.typ != nil and n.typ.kind == nsnTypeName and
     n.typ.sons.len == 0 and isNumericName(canonicalTypeName(n.typ.name)) and
     n.body != nil and n.body.typeKind == tkInt and n.body.kind != nsnIntLit:
    ## `checked((byte)x)`: out of range throws, as C# has it (see `nsCkConv`).
    return newTree(nkCall, n.info, l.id("nsCkConv", n.info), l.typeToNim(n.typ, n.info),
                   l.expr(n.body))
  result = newNodeI(nkCall, n.info)
  result.add convCallee(l.typeToNim(n.typ, n.info))
  if n.body != nil and n.body.typeKind == tkNullable:
    result.add l.presentOf(n.body, n.info)
  else:
    result.add l.expr(n.body)

proc asToNim(l: Lowerer; n: NsNode): PNode =
  ## `x as T` yields nil instead of raising, and reads its operand once. The block
  ## scopes the temporary, so two of them in one body cannot collide.
  if n.strVal == "boxed":
    ## From an `object`: the value when it holds one of the type, else null.
    return newTree(nkCall, n.info, l.id("nsAsValue", n.info), l.expr(n.body),
                   l.typeToNim(n.typ, n.info))
  if n.strVal == "same": return l.expr(n.body)
  let defs = newNodeI(nkIdentDefs, n.info)
  defs.add l.id("nsAs", n.info)
  defs.add newNodeI(nkEmpty, n.info)
  defs.add l.expr(n.body)
  let cond = newNodeI(nkInfix, n.info)
  cond.add l.id("of", n.info)
  cond.add l.id("nsAs", n.info)
  cond.add l.objTypeToNim(n.typ, n.info)
  let conv = newNodeI(nkCall, n.info)
  conv.add convCallee(l.typeToNim(n.typ, n.info))
  conv.add l.id("nsAs", n.info)
  let inner = newNodeI(nkStmtList, n.info)
  inner.add newTree(nkLetSection, n.info, defs)
  inner.add newTree(nkIfExpr, n.info,
                    newTree(nkElifExpr, n.info, cond, conv),
                    newTree(nkElseExpr, n.info, newNodeI(nkNilLit, n.info)))
  result = newNodeI(nkBlockExpr, n.info)
  result.add empty(n.info)
  result.add inner

proc isHandleValue(l: Lowerer; n: NsNode): bool =
  ## A value of a handle class (`this` excepted, which is the object itself).
  if n == nil or n.kind in {nsnThis, nsnBase, nsnNull}: return false
  var tn = (if n.typeKind == tkClass: n.typeName else: "")
  if n.kind == nsnCast and n.typ != nil and n.typ.kind == nsnTypeName:
    tn = canonicalTypeName(n.typ.name)   ## `(Crate)e`: the cast's own type
  tn.len > 0 and l.scope.classes.hasKey(tn) and l.scope.handleRoot(tn).len > 0

proc recvOf(l: Lowerer; n: NsNode): PNode =
  ## A receiver: `this` in a native-derived class is the object (`self`), a
  ## handle is dereferenced, anything else is its value.
  if n != nil and n.kind == nsnThis and l.thisName == "self" and l.curClass != nil and
     l.scope.nativeBased(l.curClass.name):
    return l.id("self", n.info)
  result = l.expr(n)
  if l.isHandleValue(n):
    if n.kind == nsnIdent and l.isHoisted(n.name):
      ## A handle local whose object is kept (see `stmt`).
      return newTree(nkCall, n.info, l.id("nsDerefCached", n.info), result,
                     l.id("nsP_" & n.name, n.info))
    result = newTree(nkCall, n.info, l.id("nsDeref", n.info), result)

proc memberReceiver(l: Lowerer; n: NsNode): PNode =
  ## The receiver of a member access. A member of a *type* keeps its receiver, in
  ## the spelling the library declares it under, so `int.MaxValue` reaches Nim's
  ## own dot-call for `int32` by the same route as `int.high` does. A value
  ## receiver, and a class this module declares, are left alone.
  var r = n.body
  var name = ""
  var dotted = true
  while r != nil:
    if r.kind == nsnMember:
      if name.len == 0: name = r.name
      r = r.body
    elif r.kind == nsnIdent:
      if name.len == 0: name = r.name
      r = nil
    else:
      dotted = false
      r = nil
  if dotted and name.len > 0 and not l.scope.classes.hasKey(name):
    let spelled = l.surface.nimSpellingOf(name)
    if spelled.len > 0:
      if n.body != nil and n.body.typeArgs.len > 0:
        ## `Comparer<int>.Default`: the generic type, instantiated.
        result = newTree(nkBracketExpr, n.info, l.id(spelled, n.info))
        for a in n.body.typeArgs: result.add l.typeToNim(a, n.info)
        return
      return l.id(spelled, n.info)
  if n.body != nil and l.scope.classes.hasKey(n.body.typeName) and
     l.scope.onHandle(n.body.typeName, n.name):
    ## A member of the handle (`[OnHandle]`): the handle itself, unchecked.
    return l.expr(n.body)
  l.recvOf(n.body)

proc nilableReceiver(l: Lowerer; n: NsNode): bool =
  ## True for a receiver the nil check may test: a declared *class*. A struct is a
  ## value, so it can never be nil, and `this` is a parameter a method body cannot
  ## see as nil without the call-site check having fired first.
  if n == nil or n.kind in {nsnThis, nsnBase, nsnNew}: return false
  if n.typeKind != tkClass: return false
  let name = n.typeName
  if name.len > 0 and l.scope.classes.hasKey(name) and l.scope.nativeBased(name):
    return false   ## a handle checks itself; a native pointer is never null
  name.len > 0 and l.scope.classes.hasKey(name) and
    l.scope.classes[name].classKind == ckClass

proc pureRead(l: Lowerer; n: NsNode): bool =
  ## A receiver that reads the same twice as once: a variable, `this`, or a
  ## field of one -- not a property, whose getter runs each time.
  if n == nil: return false
  case n.kind
  of nsnIdent, nsnThis: true
  of nsnMember:
    if not l.pureRead(n.body): return false
    let owner = n.body.typeName
    if owner.len == 0 or not l.scope.classes.hasKey(owner): return false
    let m = l.scope.findMemberInfo(owner, n.name)
    m.name.len > 0 and not m.isMethod and not m.isProperty and not m.isEvent
  else: false

proc checkNil(l: Lowerer; recvNs: NsNode; recv: PNode; info: TLineInfo): PNode =
  ## `nsCheckNil(recv)`; for a receiver that is a variable or a field of one
  ## `nsCheckNilVar`, which rereads it instead of copying the reference.
  let simple = recv.kind in {nkIdent, nkSym} or
               (recv.kind == nkDotExpr and l.pureRead(recvNs))
  let name = (if simple: "nsCheckNilVar" else: "nsCheckNil")
  newTree(nkCall, info, l.id(name, info), recv)

proc memberReceiverChecked(l: Lowerer; n: NsNode): PNode =
  ## A field access on a class reference tests the receiver first, so dereferencing
  ## null raises `NullReferenceException` instead of faulting. C# tests at the
  ## access, and `-d:danger` / `--nilChecks:off` turn the whole check off.
  result = l.memberReceiver(n)
  if l.nilChecks and l.nilableReceiver(n.body):
    result = l.checkNil(n.body, result, n.info)

proc condTail(l: Lowerer; nd: NsNode; absent: PNode): PNode =
  ## The body of a `?.`: read the guarded value once, then either yield `absent` or
  ## evaluate the tail with the temporary as its receiver.
  let defs = newNodeI(nkIdentDefs, nd.info)
  defs.add l.id(NsCond, nd.info)
  defs.add newNodeI(nkEmpty, nd.info)
  defs.add l.expr(nd.body)
  var cond = newNodeI(nkInfix, nd.info)
  cond.add l.id("==", nd.info)
  cond.add l.id(NsCond, nd.info)
  cond.add newNodeI(nkNilLit, nd.info)
  ## The temporary stands for the guarded value; a handle's keeps its type, so it
  ## is still dereferenced as a receiver (a reference needs no second nil check).
  let tmp = nsnIdent(NsCond, nd.info)
  if l.isHandleValue(nd.body):
    tmp.typeKind = nd.body.typeKind
    tmp.typeName = nd.body.typeName
    tmp.rtype = nd.body.rtype
  if l.isHandleValue(nd.body):
    ## A handle is absent when the engine says it is no longer valid.
    cond = newTree(nkPrefix, nd.info, l.id("not", nd.info),
                   newTree(nkCall, nd.info, l.id("nsValid", nd.info), l.id(NsCond, nd.info)))
  var tailNim = absent
  if nd.sons.len > 0 and nd.sons[0] != nil:
    nd.sons[0] = replaceIdentical(nd.sons[0], nd.body, tmp)
    let tail = nd.sons[0]
    if tail.kind == nsnNullDot:
      ## `a?.B?.C ?? x`: the same absent value belongs to every link of the chain.
      tailNim = l.condTail(tail, absent)
    else:
      tailNim = l.expr(tail)
  let inner = newNodeI(nkStmtList, nd.info)
  inner.add newTree(nkLetSection, nd.info, defs)
  ## `cond` *is* the absent case, so the absent value goes in the branch.
  inner.add newTree(nkIfExpr, nd.info,
                    newTree(nkElifExpr, nd.info, cond, copyTree(absent)),
                    newTree(nkElseExpr, nd.info, tailNim))
  result = newNodeI(nkBlockExpr, nd.info)
  result.add empty(nd.info)
  result.add inner

proc condStmt(l: Lowerer; nd: NsNode): PNode =
  ## `a?.M(...)` as a statement: nothing happens when `a` is null, otherwise the
  ## tail runs, its result dropped.
  let info = nd.info
  var tailNim = newTree(nkDiscardStmt, info, empty(info))
  let tmp = nsnIdent(NsCond, info)
  if l.isHandleValue(nd.body):
    tmp.typeKind = nd.body.typeKind
    tmp.typeName = nd.body.typeName
    tmp.rtype = nd.body.rtype
  if nd.sons.len > 0 and nd.sons[0] != nil:
    nd.sons[0] = replaceIdentical(nd.sons[0], nd.body, tmp)
    let tail = nd.sons[0]
    tailNim = (if tail.kind == nsnNullDot: l.condStmt(tail)
               else: newTree(nkCall, info, l.id("nsStmt", info), l.expr(tail)))
  let inner = newNodeI(nkStmtList, info)
  inner.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(NsCond, info),
                                                empty(info), l.expr(nd.body)))
  let present =
    if l.isHandleValue(nd.body):
      newTree(nkCall, info, l.id("nsValid", info), l.id(NsCond, info))
    else:
      newTree(nkPrefix, info, l.id("not", info), newTree(nkInfix, info, l.id("==", info),
        l.id(NsCond, info), newNodeI(nkNilLit, info)))
  inner.add newTree(nkIfStmt, info, newTree(nkElifBranch, info, present, tailNim))
  result = newTree(nkBlockStmt, info, empty(info), inner)

proc nullDotToNim(l: Lowerer; n: NsNode): PNode =
  ## `a?.B` on its own yields null when the receiver is null: nil for a reference,
  ## the empty string for a `string` (N#'s null one), and for a value type the
  ## absent `T?`, the present value wrapped (`int? n = s?.Length`-like).
  if n.typeKind == tkNullable:
    result = l.condTail(n, l.noneFromName(n.typeName, n.info))
    ## The innermost present branch is the value: wrapped into the `T?`.
    var e = result
    while e != nil and e.kind == nkBlockExpr and e.len == 2 and e[1].kind == nkStmtList and
          e[1].len > 0 and e[1][^1].kind == nkIfExpr and e[1][^1].len == 2 and
          e[1][^1][1].kind == nkElseExpr:
      let branch = e[1][^1][1]
      if branch[0].kind == nkBlockExpr and branch[0].len == 2 and
         branch[0][1].kind == nkStmtList and branch[0][1].len > 0 and
         branch[0][1][^1].kind == nkIfExpr:
        e = branch[0]
      else:
        branch[0] = l.someNamed(branch[0], n.typeName, n.info)
        break
  elif n.typeKind == tkString:
    result = l.condTail(n, newStrNode(nkStrLit, ""))
  else:
    result = l.condTail(n, newNodeI(nkNilLit, n.info))

proc nullCoalesceToNim(l: Lowerer; n: NsNode): PNode =
  ## `a ?? b` is `b` when `a` is absent. With a `?.` on the left, `b` is that
  ## chain's absent value, so the two lower into one block.
  if n.sons.len == 0: return empty(n.info)
  let lhs = n.sons[0]
  let fallback = if n.sons.len > 1: l.expr(n.sons[1]) else: newNodeI(nkNilLit, n.info)
  if lhs != nil and lhs.kind == nsnNullDot:
    result = l.condTail(lhs, fallback)
  elif lhs != nil and lhs.typeKind == tkString:
    ## `s ?? b` for a string: `b` when `s` is null, which is the empty string.
    let t = NsCond
    let sl = newNodeI(nkStmtList, n.info)
    sl.add newTree(nkLetSection, n.info, newTree(nkIdentDefs, n.info, l.id(t, n.info),
                                                empty(n.info), l.expr(lhs)))
    sl.add newTree(nkIfExpr, n.info,
      newTree(nkElifExpr, n.info, newTree(nkInfix, n.info, l.id("==", n.info),
        newTree(nkCall, n.info, l.id("len", n.info), l.id(t, n.info)),
        newIntNode(nkIntLit, 0)), fallback),
      newTree(nkElseExpr, n.info, l.id(t, n.info)))
    result = newTree(nkBlockExpr, n.info, empty(n.info), sl)
  elif lhs != nil and lhs.typeKind == tkNullable:
    ## `a ?? b` on a `T?`: the library answers the test and the unwrap, so no member
    ## name is known here, and `b` stays lazy.
    result = newNodeI(nkBlockExpr, n.info)
    result.add empty(n.info)
    let inner = newNodeI(nkStmtList, n.info)
    let defs = newNodeI(nkIdentDefs, n.info)
    defs.add l.id(NsCond, n.info)
    defs.add newNodeI(nkEmpty, n.info)
    defs.add l.expr(lhs)
    inner.add newTree(nkLetSection, n.info, defs)
    let cond = newNodeI(nkCall, n.info)
    cond.add l.id("nsAbsent", n.info)
    cond.add l.id(NsCond, n.info)
    let present = newNodeI(nkCall, n.info)
    present.add l.id("nsPresent", n.info)
    present.add l.id(NsCond, n.info)
    inner.add newTree(nkIfExpr, n.info,
                      newTree(nkElifExpr, n.info, cond, fallback),
                      newTree(nkElseExpr, n.info, present))
    result.add inner
  else:
    ## `a ?? b` for a reference: `b` when it is nil.
    result = newNodeI(nkBlockExpr, n.info)
    result.add empty(n.info)
    let inner = newNodeI(nkStmtList, n.info)
    let defs = newNodeI(nkIdentDefs, n.info)
    defs.add l.id(NsCond, n.info)
    defs.add newNodeI(nkEmpty, n.info)
    defs.add l.expr(lhs)
    inner.add newTree(nkLetSection, n.info, defs)
    let cond = newNodeI(nkInfix, n.info)
    cond.add l.id("==", n.info)
    cond.add l.id(NsCond, n.info)
    cond.add newNodeI(nkNilLit, n.info)
    inner.add newTree(nkIfExpr, n.info,
                      newTree(nkElifExpr, n.info, cond, fallback),
                      newTree(nkElseExpr, n.info, l.id(NsCond, n.info)))
    result.add inner

proc interpolatedToNim(l: Lowerer; n: NsNode): PNode =
  ## `$"a{x,5:F2}b"` as `"a" & nsAlign(nsFmt(x, "F2"), 5) & "b"`. The intrinsics own
  ## what a format spec means; a hole with no spec is the value's `$`.
  result = nil
  for part in n.sons:
    var piece: PNode
    if part.kind == nsnStrLit:
      piece = newAtom(nkStrLit, part.strVal, part.info)
    else:
      piece = newNodeI(nkCall, part.info)
      piece.add l.id("nsFmt", part.info)
      piece.add l.expr(part.body)
      piece.add newAtom(nkStrLit, part.strVal, part.info)
      if part.sons.len > 0:
        let al = newNodeI(nkCall, part.info)
        al.add l.id("nsAlign", part.info)
        al.add piece
        al.add l.expr(part.sons[0])
        piece = al
    result = (if result == nil: piece
              else: newTree(nkInfix, part.info, l.id("&", part.info), result, piece))
  if result == nil: result = newAtom(nkStrLit, "", n.info)

proc ifaceTypeOp(l: Lowerer; n: NsNode): PNode
proc isPatternToNim(l: Lowerer; n: NsNode): PNode
proc switchExprToNim(l: Lowerer; n: NsNode): PNode
proc isIfaceValue(l: Lowerer; e: NsNode): bool
proc objOf(l: Lowerer; e: NsNode): PNode

proc structPointee(l: Lowerer; t: NsNode): bool =
  ## Whether `T*` points at a struct's C mirror (`nsC_<S>`) rather than at `T`.
  t != nil and t.kind == nsnTypeName and l.scope.isMarshalableStruct(canonicalTypeName(t.name))

proc isCViewField(l: Lowerer; n: NsNode): bool

proc isCView(l: Lowerer; n: NsNode): bool =
  ## `*p`, `p[i]` or `p->F` naming a whole struct held as its C mirror, which is
  ## read with `nsFromC`, written with `nsToC`, and copied in and out around a
  ## method or property. The shape is checked before the (costlier) struct.
  if n == nil: return false
  let shaped =
    case n.kind
    of nsnUnary: n.name == "deref"
    of nsnIndex:
      n.body != nil and n.body.rtype != nil and n.body.rtype.kind == nsnPointerType
    of nsnMember: l.isCViewField(n)
    else: false
  shaped and l.structPointee(n.rtype)

proc isCViewField(l: Lowerer; n: NsNode): bool =
  ## `p->F`: a field of a struct held as its C mirror.
  n.kind == nsnMember and n.body != nil and n.body.kind in {nsnUnary, nsnIndex, nsnMember} and
    l.isCView(n.body) and
    (let m = l.scope.findMemberInfo(canonicalTypeName(n.body.rtype.name), n.name);
     m.name.len > 0 and not m.isMethod and not m.isProperty and not m.isStatic)

proc cView(l: Lowerer; n: NsNode): PNode =
  ## The C mirror lvalue `isCView`/`isCViewField` names.
  case n.kind
  of nsnUnary: newTree(nkBracketExpr, n.info, l.expr(n.body))
  of nsnIndex:
    newTree(nkCall, n.info, l.id("nsPtrAt", n.info), l.expr(n.body), l.expr(n.sons[0]))
  else: newTree(nkDotExpr, n.info, l.cView(n.body), l.id(n.name, n.info))

proc throughCView(l: Lowerer; holder, whole: NsNode): PNode =
  ## A method or property on a struct held as its C mirror (`holder.body`): `whole`
  ## runs on a copy, `nsSelf`, which is written back after (`nsThroughC`).
  let recv = holder.body
  holder.body = NsNode(kind: nsnIdent, info: recv.info, name: "nsSelf",
                       typeKind: recv.typeKind, typeName: recv.typeName, rtype: recv.rtype)
  let inner = (if whole.kind == nsnAssign: l.assignCore(whole) else: l.expr(whole))
  holder.body = recv
  newTree(nkCall, whole.info, l.id("nsThroughC", whole.info),
          newTree(nkAddr, whole.info, l.cView(recv)), inner)

proc expr(l: Lowerer; n: NsNode): PNode =
  if n == nil: return newNodeI(nkEmpty, unknownLineInfo)
  if n.kind in {nsnUnary, nsnIndex, nsnMember, nsnCall}:
    if l.isCViewField(n):
      let f = l.cView(n)
      return (if l.isCView(n): newTree(nkCall, n.info, l.id("nsFromC", n.info), f) else: f)
    if l.isCView(n):
      return newTree(nkCall, n.info, l.id("nsFromC", n.info), l.cView(n))
    if n.kind == nsnMember and n.body != nil and l.isCView(n.body):
      return l.throughCView(n, n)
    if n.kind == nsnCall and n.body != nil and n.body.kind == nsnMember and
       n.body.body != nil and l.isCView(n.body.body):
      return l.throughCView(n.body, n)
    if n.kind == nsnCall:
      for a in n.sons:
        if a.kind == nsnRefArg and l.isCView(a.body):
          ## `M(ref *p)`: `M` updates a copy, stored back after.
          return l.throughCView(a, n)
  case n.kind
  of nsnEmpty: result = empty(n.info)
  of nsnIdent:
    result = l.id(n.name, n.info)
    if n.paramMod == "cells": return l.cellFuncDelegate(n)
    if n.paramMod == "deref":
      ## A `ref` local reads and writes the variable it refers to.
      return newTree(nkBracketExpr, n.info, result)
    if n.typeArgs.len > 0:
      ## `Max<string>` / `Box<int>.Made`: the explicit type arguments.
      result = newTree(nkBracketExpr, n.info, result)
      for a in n.typeArgs: result.add l.typeToNim(a, n.info)
  of nsnThis:
    result = l.id(if l.thisName.len > 0: l.thisName else: "this", n.info)
    if l.thisName == "self" and l.curClass != nil and l.scope.nativeBased(l.curClass.name):
      ## `this` as a value in a native-derived class: the engine may move the
      ## object, so it is never kept as a pointer but as its own handle.
      let root = l.scope.handleRoot(l.curClass.name)
      if root.len > 0 and l.scope.ownedFamily(l.curClass.name):
        ## Kept alive by the box N# made it in, if it did: lent otherwise.
        result = newTree(nkCall, n.info, l.id("nsSelfObj", n.info),
                         newTree(nkBracketExpr, n.info, l.id("NsH_" & root, n.info),
                                 l.id(l.curClass.name, n.info)),
                         l.id("self", n.info),
                         newTree(nkDotExpr, n.info,
                                 newTree(nkDotExpr, n.info, l.id("self", n.info),
                                         l.id("nsOwner", n.info)), l.id("box", n.info)))
      elif root.len > 0:
        result = newTree(nkCall, n.info, l.id("nsAs", n.info),
                         newTree(nkCall, n.info, l.id("nsSelfOf_" & root, n.info), result),
                         newTree(nkBracketExpr, n.info, l.id("NsH_" & root, n.info),
                                 l.id(l.curClass.name, n.info)))
  of nsnBase: result = l.baseConv(n.info)
  of nsnNull:
    if n.typeName.len > 0 and l.scope.classes.hasKey(n.typeName) and
       l.scope.handleRoot(n.typeName).len > 0:
      ## `null` for a handle class: the invalid handle.
      result = newTree(nkCall, n.info, l.id("nsNull", n.info),
                       l.typeToNim(nsnTypeName(n.typeName, n.info), n.info))
    elif n.typeName.len > 0 and l.scope.isValueInterface(n.typeName):
      ## The empty interface value; a generic one's with its type arguments.
      result = newTree(nkCall, n.info, l.id("default", n.info),
                       (if n.rtype != nil: l.typeToNim(n.rtype, n.info)
                        else: l.id(n.typeName, n.info)))
    elif n.typeKind == tkString:
      ## A null string is the empty one.
      result = newStrNode(nkStrLit, "")
      result.info = n.info
    else:
      result = newNodeI(nkNilLit, n.info)
  of nsnIntLit:
    ## The literal's C# type, chosen by `sema.nim`, picks the typed Nim literal; an
    ## `int` one stays untyped so it adapts to its context the way C#'s does.
    let kind = case n.typeName
      of "uint": nkUInt32Lit
      of "long": nkInt64Lit
      of "ulong": nkUInt64Lit
      else: nkIntLit
    result = newAtom(kind, n.intVal, n.info)
  of nsnFloatLit:
    result = newAtom((if n.strVal == "f": nkFloat32Lit else: nkFloatLit),
                     n.floatVal, n.info)
  of nsnInterpolated: result = l.interpolatedToNim(n)
  of nsnStrLit: result = newAtom(nkStrLit, n.strVal, n.info)
  of nsnCharLit: result = newAtom(nkCharLit, n.intVal, n.info)
  of nsnBoolLit: result = l.id(if n.intVal != 0: "true" else: "false", n.info)
  of nsnMember:
    if n.body != nil and n.body.kind == nsnBase and l.curBase.len > 0 and
       l.scope.classes.hasKey(l.curBase) and
       l.scope.findMemberInfo(l.curBase, n.name).isProperty:
      ## `base.P`: the base's getter, not the override's.
      result = l.baseCall(n.name, @[], n.info)
    elif n.body != nil and n.body.typeKind == tkType and n.typeKind == tkDelegate and
         l.scope.classes.hasKey(n.body.typeName) and
         l.scope.findMemberInfo(n.body.typeName, n.name).isMethod:
      ## `C.M` as a method group: a closure that calls `M(C, ...)`.
      result = l.staticMethodGroup(n)
    elif n.body != nil and n.typeKind == tkDelegate and n.body.typeKind == tkClass and
         l.scope.findMemberInfo(n.body.typeName, n.name).isMethod:
      ## `obj.M` as a method group: C# binds the receiver when the delegate is made,
      ## so it is read once into the closure's environment.
      result = l.instanceMethodGroup(n)
    elif n.body != nil and n.body.typeKind == tkType and
         l.scope.qualifiedOnly.hasKey(writtenName(n.body)) and
         not l.scope.qualifiedOnly.hasKey(writtenName(n.body) & "." & n.name):
      ## `Tools.Console.Calls`: a static of a type of a namespace reached qualified,
      ## named like another in scope, read through the qualified type.
      result = newTree(nkCall, n.info, l.id(n.name, n.info), l.qualifiedOnlyRef(n.body))
    else:
      l.noteMemberImport(n)
      if l.imports != nil and n.name in l.imports.userTypes and n.body != nil and
         not l.isUserReceiver(n.body) and n.body.typeKind != tkType:
        ## A library member named like a type of this compilation (`e.Message`
        ## beside a class `Message`): `x.Message` would convert to the type, so it is
        ## called through the module that declares it.
        let ovs = l.surface.overloads(n.body.typeName, n.body.typeKind, n.name)
        if ovs.len > 0 and ovs[0].path.len > 0:
          return newTree(nkCall, n.info, newTree(nkDotExpr, n.info,
            l.id(ovs[0].path.split('/')[^1], n.info), l.id(n.name, n.info)),
            l.memberReceiverChecked(n))
      result = newTree(nkDotExpr, n.info, l.memberReceiverChecked(n),
                       l.memberIdent(n.name, n.body, n.info))
      let owner = (if n.body != nil and n.body.kind == nsnThis and l.curClass != nil:
                     l.curClass.name
                   elif n.body != nil: n.body.typeName else: "")
      if l.isManagedNativeField(owner, n.name):
        ## A Nim-managed field of a native-derived class: its value is in the
        ## `NsField`.
        result = newTree(nkCall, n.info, l.id("nsVal", n.info), result)
  of nsnCall: result = l.callToNim(n)
  of nsnIndex:
    if n.body != nil and n.body.rtype != nil and n.body.rtype.kind == nsnPointerType:
      ## `p[i]`: the `i`th element from `p`, unchecked as C# has it.
      return newTree(nkCall, n.info, l.id("nsPtrAt", n.info), l.expr(n.body),
                     l.expr(n.sons[0]))
    if n.strVal.startsWith("count:"):
      ## `x[^k]` on a collection: `x[x.Count - k]`, `x` read once.
      let info = n.info
      let t = l.fresh("nsRecv")
      let count = newTree(nkDotExpr, info, l.id(t, info), l.id(n.strVal[6 .. ^1], info))
      let br = newTree(nkBracketExpr, info, l.id(t, info))
      for a in n.sons:
        if a.kind == nsnFromEnd:
          br.add newTree(nkInfix, info, l.id("-", info), count, l.expr(a.body))
        else: br.add l.expr(a)
      return newTree(nkBlockExpr, info, empty(info), newTree(nkStmtList, info,
        newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(t, info), empty(info),
                                            l.expr(n.body))), br))
    ## A native class's indexer takes the C++ object: a handle (or an N#
    ## reference) dereferenced, `this` as `self`.
    let native = n.body != nil and l.scope.classes.hasKey(n.body.typeName) and
                 l.scope.nativeBased(n.body.typeName)
    result = newTree(nkBracketExpr, n.info,
                     (if native: l.recvOf(n.body) else: l.expr(n.body)))
    for i in n.sons: result.add l.indexArgToNim(i)
  of nsnNew: result = l.newToNim(n)
  of nsnNewArray:
    if n.sons.len > 1:
      ## `new T[n, m]`: every element the default.
      result = newTree(nkCall, n.info, l.id("nsNewMd", n.info), l.typeToNim(n.typ, n.info))
      for s in n.sons: result.add l.expr(s)
      return
    result = newTree(nkCall, n.info, l.id("nsNewArray", n.info),
                     l.typeToNim(n.typ, n.info), l.expr(n.sons[0]))
  of nsnCollection:
    ## `[a, ..xs, b]` into an array: a sequence the elements and the spread
    ## collections' elements are added to, in order.
    let info = n.info
    if n.typ == nil:
      ## No target type: sema has reported it (NS9176); nothing to lower to.
      return empty(info)
    let t = l.fresh("nsColl")
    let et = n.typ.typ
    let sl = newNodeI(nkStmtList, info)
    sl.add newTree(nkVarSection, info, newTree(nkIdentDefs, info, l.id(t, info), empty(info),
      newTree(nkCall, info, newTree(nkBracketExpr, info, l.id("newSeq", info),
                                    l.typeToNim(et, info)))))
    for e in n.sons:
      if e.kind == nsnSpread:
        let x = l.fresh("nsElem")
        sl.add newTree(nkForStmt, info, l.id(x, info), l.expr(e.body),
          newTree(nkStmtList, info, newTree(nkCall, info, l.id("add", info), l.id(t, info),
                                            l.id(x, info))))
      else:
        var v = l.expr(e)
        if et.kind == nsnTypeName and e.kind != nsnNull:
          v = newTree(nkCall, e.info, convCallee(l.typeToNim(et, e.info)), v)
        sl.add newTree(nkCall, info, l.id("add", info), l.id(t, info), v)
    sl.add newTree(nkCall, info, l.id("nsArrayOf", info), l.id(t, info))
    result = newTree(nkBlockExpr, info, empty(info), sl)
  of nsnArrayLit:
    ## `new T[] { a, b }`: each element converted to `T`, as C# converts it, which
    ## for an interface is its converter and for a base class an upcast.
    if n.sons.len == 0 and n.typ != nil:
      ## `[]`: Nim cannot infer an empty literal's element type.
      return newTree(nkCall, n.info, l.id("nsNewArray", n.info),
                     l.typeToNim(n.typ, n.info), newIntNode(nkIntLit, 0))
    let br = newNodeI(nkBracket, n.info)
    for e in n.sons:
      if n.typ != nil and n.typ.kind == nsnTypeName and e.kind != nsnNull:
        br.add newTree(nkCall, e.info, convCallee(l.typeToNim(n.typ, e.info)), l.expr(e))
      else:
        ## A nullable element type: `some`/`none` as sema chose, as for an argument.
        br.add l.wrappedArg(e)
    result = newTree(nkPrefix, n.info, l.id("@", n.info), br)
    if n.intVal <= 1:
      ## A `T[]`: the library's array over those elements.
      result = l.arrayOf(n.typ, br, n.info)
    if n.intVal > 1:
      ## `{ {1, 2}, {3, 4} }`: the row-major elements and the lengths.
      let dims = newNodeI(nkBracket, n.info)
      for d in n.params: dims.add newIntNode(nkIntLit, d.intVal)
      result = newTree(nkCall, n.info, l.id("nsMdOf", n.info), result,
                       newTree(nkPrefix, n.info, l.id("@", n.info), dims))
  of nsnUnary:
    case n.name
    of "deref":
      ## `*p`: `p[]`.
      return newTree(nkBracketExpr, n.info, l.expr(n.body))
    of "addr":
      if n.strVal == "method":
        ## `&M` of an `[UnmanagedCallersOnly]` method: its C entry.
        let parts = n.typeName.split('.')
        return l.id(unmanagedEntryName(parts[0], parts[^1]), n.info)
      return newTree(nkAddr, n.info, l.expr(n.body))
    of "fixed":
      ## `fixed (T* p = arr)`: the first element; or the address written.
      if n.body.kind == nsnUnary and n.body.name == "addr": return l.expr(n.body)
      return newTree(nkCall, n.info, l.id("nsArrayAddr", n.info), l.expr(n.body))
    else: discard
    if isCheckedOp(n):
      result = newTree(nkCall, n.info, l.id(checkedOperatorName(n.argParam), n.info),
                       l.expr(n.body))
    elif l.checked and n.name == "-" and n.typeKind == tkInt and n.body != nil and
         n.body.typeKind == tkInt and n.body.kind != nsnIntLit:
      result = newTree(nkCall, n.info, l.id("nsCkNeg", n.info), l.expr(n.body))
    elif n.name == "-" and n.body != nil and n.body.kind == nsnIntLit and
         n.body.typeName == "" and n.body.strVal.len == 0:
      ## One negative literal: `-(2147483648)` would read the literal first, which
      ## where Nim's `int` is 32 bits (`--cpu:mipsel`, `i386`) is an `int64`.
      result = newAtom(nkIntLit, -n.body.intVal, n.info)
    else:
      result = newTree(nkPrefix, n.info, l.id(n.name, n.info), l.expr(n.body))
  of nsnIncDec:
    ## In an expression `x++` is the old value and `++x` the new one; the intrinsics
    ## carry both. As a statement it is Nim's own `inc`/`dec` (see `stmtInner`).
    let tmpl = (if n.strVal == "prefix": "nsPre" else: "nsPost") &
               (if n.name == "inc": "Inc" else: "Dec")
    var pre: seq[PNode] = @[]
    let target = l.stabilize(n.body, nil, pre)
    result = newTree(nkCall, n.info, l.id(tmpl, n.info), l.expr(target))
    if pre.len > 0:
      ## The intrinsics name their operand twice, to read it and to write it back.
      let sl = newNodeI(nkStmtList, n.info)
      for x in pre: sl.add x
      sl.add result
      result = newTree(nkBlockExpr, n.info, empty(n.info), sl)
  of nsnCast, nsnIs, nsnAs:
    if n.kind == nsnCast and (n.strVal == "reinterpret" or
       (n.typ != nil and n.typ.kind in {nsnPointerType, nsnFnPtrType}) or
       (n.typ != nil and n.typ.kind == nsnTypeName and n.body != nil and
        n.body.rtype != nil and n.body.rtype.kind in {nsnPointerType, nsnFnPtrType} and
        canonicalTypeName(n.typ.name) in ["nint", "nuint", "long", "ulong"])):
      ## `(int*)p`, `(IntPtr)p`: the same bits as the other type.
      return newTree(nkCast, n.info, l.typeToNim(n.typ, n.info), l.expr(n.body))
    result = l.ifaceTypeOp(n)
    if result != nil: discard
    elif n.kind == nsnIs and n.name == "nsIsType":
      result = newTree(nkCall, n.info, l.id("nsIsType", n.info), l.expr(n.body),
                       l.typeToNim(n.typ, n.info))
    elif n.kind == nsnIs:
      result = newTree(nkInfix, n.info, l.id(n.name, n.info), l.expr(n.body),
                       l.objTypeToNim(n.typ, n.info))
    elif n.kind == nsnAs: result = l.asToNim(n)
    else:
      result = l.castToNim(n)
  of nsnDefault:
    result = newNodeI(nkCall, n.info)
    result.add l.id("default", n.info)
    result.add l.typeToNim(n.typ, n.info)
  of nsnThrow:
    ## Nim's `raise` is `noreturn`, so it stands where a value is expected.
    result = l.throwToNim(n)
  of nsnCheckedExpr: result = l.checkedExprToNim(n)
  of nsnTypeOf:
    result = newTree(nkCall, n.info, l.id("nsTypeOf", n.info), l.typeToNim(n.typ, n.info))
  of nsnSizeOf:
    ## A struct's size is its C layout's, as C# gives a sequential struct's.
    let t = (if n.typ != nil and n.typ.kind == nsnTypeName and
                l.scope.isMarshalableStruct(canonicalTypeName(n.typ.name)):
               l.id(cMirrorName(n.typ.name), n.info)
             else: l.typeToNim(n.typ, n.info))
    result = newTree(nkCall, n.info, l.id("nsSizeOf", n.info), t)
  of nsnWith:
    ## `r with { A = 1 }`: a copy of `r` -- `nsClone` for a class record, which
    ## keeps the dynamic type -- with the initialiser applied to it.
    let info = n.info
    var copy = l.expr(n.body)
    let rt = (if n.body.rtype != nil: n.body.rtype
              else: nsnTypeName(n.body.typeName, info))
    let cn = (if rt.kind == nsnTypeName: canonicalTypeName(rt.name) else: "")
    if n.body.typeKind == tkClass and
       not (l.scope.classes.hasKey(cn) and l.scope.classes[cn].classKind == ckStruct):
      copy = newTree(nkCall, info, l.typeToNim(rt, info),
                     newTree(nkCall, info, l.id("nsClone", info), copy))
    let sl = newNodeI(nkStmtList, info)
    sl.add newTree(nkVarSection, info, newTree(nkIdentDefs, info, l.id(n.strVal, info),
                                              empty(info), copy))
    for st in n.inits: sl.add l.stmt(st)
    sl.add l.id(n.strVal, info)
    result = newTree(nkBlockExpr, info, empty(info), sl)
  of nsnAssign:
    ## `(x = e)` as a value: the assignment, then the variable read back, its
    ## receiver and indices evaluated once for both.
    var bare = l
    bare.nilChecks = false
    var pre: seq[PNode] = @[]
    let m = (if n.sons.len == 2 and n.strVal notin ["discard", "refAssign"]:
               l.withStableTarget(n, pre) else: n)
    let sl = newNodeI(nkStmtList, n.info)
    for x in pre: sl.add x
    sl.add l.assignCore(m)
    sl.add bare.expr(m.sons[0])
    result = newTree(nkBlockExpr, n.info, empty(n.info), sl)
  of nsnBinary:
    if n.name in ["==", "!="] and
       ((l.isHandleValue(n.sons[0]) and n.sons[1].kind == nsnNull) or
        (l.isHandleValue(n.sons[1]) and n.sons[0].kind == nsnNull)):
      ## `h == null` asks the engine whether the handle is still valid.
      let h = (if n.sons[0].kind == nsnNull: n.sons[1] else: n.sons[0])
      result = newTree(nkCall, n.info, l.id("nsValid", n.info), l.expr(h))
      if n.name == "==": result = newTree(nkPrefix, n.info, l.id("not", n.info), result)
    elif n.name in ["==", "!="] and (l.isIfaceValue(n.sons[0]) or l.isIfaceValue(n.sons[1])):
      ## An interface value is equal to another, or to null, by its object.
      let side = proc (e: NsNode): PNode =
        if e.kind == nsnNull: newNodeI(nkNilLit, e.info)
        else: newTree(nkCall, e.info, l.id("RootRef", e.info), l.objOf(e))
      result = newTree(nkInfix, n.info, l.id(n.name, n.info), side(n.sons[0]),
                       side(n.sons[1]))
    elif n.name in ["==", "!="] and
       ((n.sons[0] != nil and n.sons[0].typeKind == tkNullable and
         n.sons[1] != nil and n.sons[1].kind == nsnNull) or
        (n.sons[1] != nil and n.sons[1].typeKind == tkNullable and
         n.sons[0] != nil and n.sons[0].kind == nsnNull)):
      ## `x == null` on a `T?`: compare with the absent value of that type and let
      ## the library's `==` decide, so no member name is known here.
      let probe = if n.sons[0].typeKind == tkNullable: n.sons[0] else: n.sons[1]
      result = newNodeI(nkInfix, n.info)
      result.add l.id(n.name, n.info)
      result.add l.expr(probe)
      result.add l.noneFromName(probe.typeName, n.info)
    elif n.name in ["==", "!="] and n.sons.len == 2 and
         ((n.sons[1].kind == nsnNull and l.isTypeParamValue(n.sons[0])) or
          (n.sons[0].kind == nsnNull and l.isTypeParamValue(n.sons[1]))):
      ## `x == null` where `x`'s type is a type parameter, which Nim cannot compare
      ## with `nil` for every argument.
      let v = (if n.sons[0].kind == nsnNull: n.sons[1] else: n.sons[0])
      result = newTree(nkCall, n.info, l.id("nsIsNull", n.info), l.expr(v))
      if n.name == "!=": result = newTree(nkPrefix, n.info, l.id("not", n.info), result)
    elif n.name in ["+", "-"] and n.sons.len == 2 and n.sons[0].typeKind == tkDelegate and
         n.sons[1].typeKind == tkDelegate:
      ## `a + b` on delegates: one that calls `a`'s list, then `b`'s; `a - b`: `a`'s
      ## list without the last run equal to `b`'s (12.10.5, 12.11.6).
      result = newTree(nkCall, n.info,
                       l.id((if n.name == "+": "nsCombine" else: "nsRemove"), n.info),
                       l.ordered(n.sons[0], n.sons[1 .. 1]), l.expr(n.sons[1]))
    elif isCheckedOp(n):
      result = newTree(nkCall, n.info, l.id(checkedOperatorName(n.argParam), n.info),
                       l.ordered(n.sons[0], n.sons[1 .. 1]), l.expr(n.sons[1]))
    elif l.checked and n.name in ["+", "-", "*"] and n.sons.len == 2 and
         n.typeKind == tkInt and n.sons[0].typeKind == tkInt and
         n.sons[1].typeKind == tkInt and
         not (n.sons[0].kind == nsnIntLit and n.sons[1].kind == nsnIntLit):
      ## Checked integer arithmetic (see `checked`); a literal on the left takes the
      ## other operand's type, as for `nsDiv` below.
      result = newNodeI(nkCall, n.info)
      result.add l.id((case n.name
                       of "+": "nsCkAdd"
                       of "-": "nsCkSub"
                       else: "nsCkMul"), n.info)
      var left = l.ordered(n.sons[0], n.sons[1 .. 1])
      let right = l.expr(n.sons[1])
      if n.sons[0].kind == nsnIntLit and left.kind == nkIntLit:
        left = newTree(nkCall, n.info,
          newTree(nkCall, n.info, l.id("typeof", n.info), copyTree(right)), left)
      result.add left
      result.add right
    elif n.name in ["nsDiv", "nsMod", "nsFmod"] or isMaskedShift(n):
      ## Integer `/` and `%`, the floating-point `%`, and a shift whose count is not
      ## a constant in range go through library procs, which are called rather
      ## than used as an infix operator.
      ## They are generic over the operand type, which an untyped literal on the
      ## left would bind to Nim's `int` (`5 / z`): the literal takes the other
      ## operand's type, or for a shift, whose type is the left operand's, C#'s `int`.
      result = newNodeI(nkCall, n.info)
      result.add l.id(shiftProc(n.name), n.info)
      var left = l.ordered(n.sons[0], n.sons[1 .. 1])
      let right = l.expr(n.sons[1])
      if n.sons[0].kind == nsnIntLit and left.kind == nkIntLit and
         n.sons[1].kind != nsnIntLit:
        let to = (if n.name in ["shl", "shr", "ushr"]: l.id("int32", n.info)
                  else: newTree(nkCall, n.info, l.id("typeof", n.info), copyTree(right)))
        left = newTree(nkCall, n.info, to, left)
      result.add left
      result.add right
    else:
      result = newTree(nkInfix, n.info, l.id(n.name, n.info),
                       l.ordered(n.sons[0], n.sons[1 .. 1]), l.expr(n.sons[1]))
  of nsnNullDot: result = l.nullDotToNim(n)
  of nsnNullCoalesce: result = l.nullCoalesceToNim(n)
  of nsnTernary:
    result = newNodeI(nkIfExpr, n.info)
    result.add newTree(nkElifExpr, n.info, l.expr(n.sons[0]), l.expr(n.sons[1]))
    result.add newTree(nkElseExpr, n.info, l.expr(n.sons[2]))
  of nsnLambda: result = l.lambdaToNim(n)
  of nsnNamedArg: result = l.wrappedArg(n)
  of nsnTupleLit:
    result = newNodeI(nkTupleConstr, n.info)
    for k, e in n.sons:
      let v = (if e.kind == nsnNamedArg: e.body else: e)
      result.add newTree(nkExprColonExpr, e.info, l.id("Item" & $(k + 1), e.info),
                         l.expr(v))
  of nsnIsPattern: result = l.isPatternToNim(n)
  of nsnSwitchExpr: result = l.switchExprToNim(n)
  of nsnRefArg:
    result = l.expr(n.body)
    if n.body != nil and n.body.kind == nsnIndex and n.body.body != nil and
       n.body.body.typeKind == tkSequence:
      ## `ref a[i]`: the element lives in the array, not in a parameter, so it is
      ## reached through a pointer, which a `ref` return may hand back.
      result = newTree(nkCall, n.info, l.id("nsElemRef", n.info), result)
  of nsnOutDecl: result = l.id(n.name, n.info)   ## declared before the statement
  else: result = empty(n.info)
  if n.conv == "nsHandle":
    ## A handle as one of another class of its family (`Node n = ball;`).
    result = newTree(nkCall, n.info, l.id("nsAs", n.info), result,
                     l.typeToNim(n.convType, n.info))
  elif n.conv == "nsOptAs":
    ## A lifted numeric conversion between nullables: `int?` to `long?`.
    result = newTree(nkCall, n.info, l.id("nsOptAs", n.info), result,
                     l.typeToNim(n.convType, n.info))
  elif n.conv == "nsAsDelegate":
    ## A lambda as the delegate type its parameter has, every type argument bound.
    result = newTree(nkCall, n.info, l.typeToNim(n.convType, n.info), result)
  elif n.conv == "nsVariant":
    ## A variant conversion: the type arguments are references either way, so the
    ## value is reinterpreted as the target instantiation.
    result = newTree(nkCall, n.info, l.id("nsVariant", n.info), result,
                     l.typeToNim(n.convType, n.info))
  elif n.conv.len > 0 and n.convType != nil and n.conv.startsWith("nsTo"):
    ## A class into a library interface: the interface names its type arguments.
    result = newTree(nkCall, n.info, l.id(n.conv, n.info), result,
                     l.typeToNim(n.convType, n.info))
  elif n.conv.len > 0:
    ## The implicit numeric conversion `sema.nim` recorded: C# promotes and widens
    ## where Nim wants the conversion spelled.
    result = newTree(nkCall, n.info, l.id(nimTypeName(n.conv), n.info), result)

# --- statements -------------------------------------------------------------

proc stmtsToNode(l: Lowerer; stmts: seq[NsNode]; info: TLineInfo): PNode

proc localFuncToNim(l: Lowerer; n: NsNode): PNode

proc cursorUnsafe(l: Lowerer; n: NsNode; local: string): bool =
  ## Whether `n` might release what a local borrowed from an element points to,
  ## or change the local: it reassigns the local, writes an element or a field
  ## that is not a number, or runs code N# cannot see through -- any call but
  ## `Math`'s, a constructor, a closure, a property of a class it declares.
  if n == nil: return false
  case n.kind
  of nsnAssign:
    let t = (if n.sons.len > 0: n.sons[0] else: nil)
    if t != nil:
      if t.kind == nsnIdent and t.name == local: return true
      if t.kind == nsnIndex: return true
      if t.kind == nsnMember and t.typeKind notin {tkInt, tkFloat, tkBool, tkChar}:
        return true
  of nsnIncDec:
    if n.body != nil and n.body.kind == nsnIdent and n.body.name == local: return true
  of nsnCall:
    let c = n.body
    if not (c != nil and c.kind == nsnMember and c.body != nil and
            c.body.typeKind == tkType and unqualified(c.body.typeName) == "Math"):
      return true
  of nsnNew, nsnLambda, nsnLocalFunc, nsnForeach, nsnLocalDecl:
    if n.kind == nsnLocalDecl:
      if n.name == local: return true
    else: return true
  of nsnMember:
    if n.body != nil and l.scope.classes.hasKey(n.body.typeName):
      let m = l.scope.findMemberInfo(n.body.typeName, n.name)
      if m.isProperty or m.isMethod: return true
  else: discard
  if l.cursorUnsafe(n.body, local): return true
  for x in n.sons:
    if l.cursorUnsafe(x, local): return true
  false

proc cursorLocal(l: Lowerer; d: NsNode; rest: openArray[NsNode]): bool =
  ## `var b = a[i];` where nothing for the rest of the block can release `b`'s
  ## object or reassign `b`: Nim's `{.cursor.}`, a borrow that counts no
  ## reference (the element keeps it alive), as C#'s plain reference read does.
  if d.body == nil or d.body.kind != nsnIndex or d.paramMod.len > 0 or d.cell or
     d.declKind == dkConst or d.body.typeKind notin {tkClass, tkString}:
    return false
  for x in rest:
    if l.cursorUnsafe(x, d.name): return false
  true

proc stmtsToNode(l: Lowerer; stmts: seq[NsNode]; info: TLineInfo): PNode =
  ## A block's statements. C# lets a local function be called anywhere in its
  ## block, Nim only after its definition, so each is declared forward first; its
  ## captures are still resolved where it is defined.
  result = newNodeI(nkStmtList, info)
  ## One taking loop-body cells names their types, so it is declared after the
  ## last of them this block declares, which C# requires a call to follow.
  var later = initTable[int, seq[PNode]]()
  for s in stmts:
    if s != nil and s.kind == nsnLocalFunc:
      let fwd = l.localFuncToNim(s)
      fwd[6] = empty(s.info)
      var at = -1
      for i, d in stmts:
        if d != nil and d.kind == nsnLocalDecl and d.name in s.captures: at = i
      if at < 0: result.add fwd
      else: later.mgetOrPut(at, @[]).add fwd
  let kept = (if l.hoist != nil: l.hoist.names.len else: 0)
  defer:
    if l.hoist != nil: l.hoist.names.setLen(kept)
  for i, s in stmts:
    let st = l.stmt(s)
    if s != nil and s.kind == nsnLocalDecl and st.kind in {nkVarSection, nkLetSection} and
       st.len == 1 and st[0].kind == nkIdentDefs and st[0][0].kind == nkIdent and
       l.cursorLocal(s, stmts.toOpenArray(i + 1, stmts.len - 1)):
      st[0][0] = newTree(nkPragmaExpr, s.info, st[0][0],
                         newTree(nkPragma, s.info, l.id("cursor", s.info)))
    result.add st
    for fwd in later.getOrDefault(i): result.add fwd

proc addStmts(l: Lowerer; dest: PNode; stmts: seq[NsNode]; info: TLineInfo) =
  ## A run of statements added to `dest`, lowered as a block's are.
  for x in l.stmtsToNode(stmts, info): dest.add x

proc stmtSeq(l: Lowerer; blk: NsNode): PNode =
  ## Lowers a `nsnBlock` to an `nkStmtList`.
  if blk == nil: return newNodeI(nkStmtList, unknownLineInfo)
  result = l.stmtsToNode(blk.sons, blk.info)

proc throwToNim(l: Lowerer; n: NsNode): PNode =
  ## `throw new T(msg)`:
  ##   * external exception (system or a prelude exception) -> `nsNewException(T, args)`
  ##   * user-declared exception class -> raise the allocator result, which is
  ##     already a `ref T` because such a class is lowered as a value object.
  var e = l.expr(n.body)
  if n.body != nil and n.body.kind == nsnNew and n.body.typ != nil and
     n.body.typ.kind == nsnTypeName and
     not l.scope.classes.hasKey(n.body.typ.name):
    let ne = newNodeI(nkCall, n.info)
    ne.add l.id("nsNewException", n.info)
    let q = l.qualifiedName(n.body.typ.name, n.info, n.body.typ.sons.len)
    ne.add (if q != nil: q else: l.id(nimTypeName(n.body.typ.name), n.info))
    for a in n.body.sons: ne.add l.expr(a)
    if l.imports != nil: l.imports.note(namespaceModulePath("System"), "nsNewException")
    e = ne
  elif n.body != nil and n.body.kind != nsnNew:
    ## `throw e;` of an exception thrown before starts its stack trace again.
    e = newTree(nkCall, n.info, l.id("nsThrown", n.info), e)
  elif n.body == nil:
    ## `throw;` raises the caught exception itself, which makes Nim record the
    ## rethrow's own frames as well (a bare `raise` would not), so its stack trace
    ## goes on to the next catch, as .NET's does.
    e = newTree(nkCall, n.info, l.id("getCurrentException", n.info))
  result = newTree(nkRaiseStmt, n.info, e)

# --- patterns -----------------------------------------------------------------
#
# A pattern lowers to a boolean test of a temporary holding the subject, and its
# variables to Nim variables declared where C# scopes them -- before the statement
# for `x is T t` (C# puts them in the enclosing block), at the start of a switch
# section or a switch-expression arm otherwise -- which the test assigns when it
# succeeds.

proc fresh(l: Lowerer; base: string): string =
  inc l.counter[]
  base & $l.counter[]

proc patternBindings(pat: NsNode; into: var seq[NsNode]) =
  ## The pattern nodes that declare a variable: `T t`, `var x`, `{ ... } p`.
  if pat == nil: return
  case pat.kind
  of nsnPatType, nsnPatVar:
    if pat.name.len > 0 and pat.name != "_": into.add pat
  of nsnPatProp:
    if pat.name.len > 0: into.add pat
    for f in pat.sons: patternBindings(f.body, into)
  of nsnPatAnd, nsnPatOr, nsnPatList:
    for x in pat.sons: patternBindings(x, into)
  of nsnPatPositional:
    if pat.name.len > 0: into.add pat
    for x in pat.sons: patternBindings(x, into)
  of nsnPatNot, nsnPatSlice: patternBindings(pat.body, into)
  else: discard

proc bindingType(l: Lowerer; b: NsNode): PNode =
  ## The Nim type of a pattern variable: the pattern's type, or the subject's; an
  ## `out T x`'s is `T`.
  let t = (if b.kind in {nsnPatType, nsnPatProp, nsnOutDecl, nsnPatPositional} and
              b.typ != nil: b.typ
           else: b.rtype)
  if t != nil: l.typeToNim(t, b.info)
  else: newTree(nkCall, b.info, l.id("typeof", b.info), l.id("nsUntyped", b.info))

proc bindingDecls(l: Lowerer; bindings: seq[NsNode]; into: PNode) =
  for b in bindings:
    into.add newTree(nkVarSection, b.info, newTree(nkIdentDefs, b.info,
      l.id(b.name, b.info), l.bindingType(b), empty(b.info)))

proc isRefKindName(l: Lowerer; kind: NsTypeKind; name: string): bool =
  ## Whether a subject of this type can be null as a Nim `ref`.
  if kind in {tkException, tkDelegate}: return true
  if kind == tkClass:
    if l.scope.classes.hasKey(name):
      return l.scope.classes[name].classKind == ckClass
    return true
  false

proc assignTrue(l: Lowerer; name: string; v: PNode; info: TLineInfo): PNode =
  ## `(name = v; true)`: binds a pattern variable inside a test.
  newTree(nkStmtListExpr, info, newTree(nkAsgn, info, l.id(name, info), v),
          l.id("true", info))

proc andAll(l: Lowerer; parts: seq[PNode]; info: TLineInfo): PNode =
  if parts.len == 0: return l.id("true", info)
  result = parts[0]
  for i in 1 ..< parts.len:
    result = newTree(nkInfix, info, l.id("and", info), result, parts[i])

proc patTest(l: Lowerer; subj: PNode; pat: NsNode): PNode

proc typeTest(l: Lowerer; subj: PNode; pat: NsNode; target: NsNode;
              bindName: string): PNode =
  ## `subject is T` with an optional variable: an interface asks the object's class,
  ## a class is Nim's `of`, and a value type is decided by its static type.
  let info = pat.info
  let tname = canonicalTypeName(target.name)
  if pat.typeKind == tkNullable:
    ## A `T?` is a `T` exactly when it has a value (`a is int x`).
    if canonicalTypeName(pat.typeName) != tname: return l.id("false", info)
    result = newTree(nkCall, info, l.id("isSome", info), copyTree(subj))
    if bindName.len > 0:
      result = newTree(nkInfix, info, l.id("and", info), result, l.assignTrue(bindName,
        newTree(nkCall, info, l.id("get", info), copyTree(subj)), info))
    return
  let subjIface = l.scope.isValueInterface(pat.typeName)
  let obj = (if subjIface: newTree(nkDotExpr, info, subj, l.id("nsObj", info))
             else: subj)
  if l.scope.isValueInterface(tname):
    let a = l.fresh("nsAs")
    var test = newTree(nkInfix, info, l.id("!=", info),
                       newTree(nkDotExpr, info, l.id(a, info), l.id("nsObj", info)),
                       newNodeI(nkNilLit, info))
    if bindName.len > 0:
      test = newTree(nkInfix, info, l.id("and", info), test,
                     l.assignTrue(bindName, l.id(a, info), info))
    return newTree(nkBlockExpr, info, empty(info), newTree(nkStmtList, info,
      newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(a, info), empty(info),
        (if target.sons.len > 0:
           newTree(nkCall, info, l.id("nsAsByKey", info),
                   newTree(nkCall, info, l.id("RootRef", info), copyTree(obj)),
                   l.typeToNim(target, info))
         else:
           newTree(nkCall, info, l.id("nsAs" & tname, info),
                   newTree(nkCall, info, l.id("RootRef", info), copyTree(obj)))))), test))
  if not subjIface and canonicalTypeName(pat.typeName) in ["object", "Object", "RootRef"]:
    ## An `object` holds a reference or a box: the library asks which.
    let t = l.typeToNim(target, info)
    result = newTree(nkCall, info, l.id("nsIsType", info), copyTree(obj), t)
    if bindName.len > 0:
      result = newTree(nkInfix, info, l.id("and", info), result, l.assignTrue(bindName,
        newTree(nkCall, info, l.id("nsUnbox", info), copyTree(obj), copyTree(t)), info))
    return
  let targetIsStruct = l.boxedImpl(tname)
  if subjIface or l.isRefKindName(pat.typeKind, pat.typeName) or
     pat.typeKind == tkUnknown and not targetIsStruct and
     l.surface.kindOfName(tname) notin {tkInt, tkFloat, tkBool, tkChar, tkString}:
    ## A reference: the object's dynamic type decides; null is never a `T`.
    let ofT = (if targetIsStruct: l.id("nsBox_" & tname, info)
               else: l.objTypeToNim(target, info))
    result = newTree(nkInfix, info, l.id("of", info), copyTree(obj), ofT)
    if bindName.len > 0:
      let conv = (if targetIsStruct:
                    newTree(nkDotExpr, info, newTree(nkCall, info, copyTree(ofT),
                                                     copyTree(obj)), l.id("v", info))
                  else: newTree(nkCall, info, convCallee(l.typeToNim(target, info)),
                                copyTree(obj)))
      result = newTree(nkInfix, info, l.id("and", info), result,
                       l.assignTrue(bindName, conv, info))
    return
  ## A value: its static type is the answer.
  let same = canonicalTypeName(pat.typeName) == tname or
             nimTypeName(pat.typeName) == nimTypeName(tname)
  if not same: return l.id("false", info)
  result = (if bindName.len > 0: l.assignTrue(bindName, copyTree(subj), info)
            else: l.id("true", info))

proc patTest(l: Lowerer; subj: PNode; pat: NsNode): PNode =
  let info = pat.info
  case pat.kind
  of nsnPatDiscard: result = l.id("true", info)
  of nsnPatVar: result = l.assignTrue(pat.name, copyTree(subj), info)
  of nsnPatType: result = l.typeTest(subj, pat, pat.typ, pat.name)
  of nsnPatConst:
    if pat.body != nil and pat.body.kind == nsnNull:
      if l.scope.isValueInterface(pat.typeName):
        result = newTree(nkInfix, info, l.id("==", info),
                         newTree(nkDotExpr, info, copyTree(subj), l.id("nsObj", info)),
                         newNodeI(nkNilLit, info))
      elif pat.typeKind == tkNullable:
        result = newTree(nkCall, info, l.id("nsAbsent", info), copyTree(subj))
      elif l.isRefKindName(pat.typeKind, pat.typeName) or pat.typeKind == tkUnknown:
        result = newTree(nkCall, info, l.id("isNil", info), copyTree(subj))
      else:
        ## A value type is never null.
        result = l.id("false", info)
    else:
      result = newTree(nkInfix, info, l.id("==", info), copyTree(subj), l.expr(pat.body))
  of nsnPatRel:
    result = newTree(nkInfix, info, l.id(pat.name, info), copyTree(subj), l.expr(pat.body))
  of nsnPatAnd:
    result = newTree(nkInfix, info, l.id("and", info), l.patTest(subj, pat.sons[0]),
                     l.patTest(subj, pat.sons[1]))
  of nsnPatOr:
    result = newTree(nkInfix, info, l.id("or", info), l.patTest(subj, pat.sons[0]),
                     l.patTest(subj, pat.sons[1]))
  of nsnPatNot:
    result = newTree(nkPrefix, info, l.id("not", info), l.patTest(subj, pat.body))
  of nsnPatPositional:
    ## `T(p, q)`: of `T` (or not null), then the parts -- a tuple's elements, or the
    ## `out` values of `Deconstruct` into temporaries -- each against its pattern.
    var parts: seq[PNode] = @[]
    var owner = subj
    if pat.typ != nil:
      parts.add l.typeTest(subj, pat, pat.typ, "")
      if l.isRefKindName(pat.typeKind, pat.typeName) or pat.typeKind == tkUnknown:
        owner = newTree(nkCall, info, l.typeToNim(pat.typ, info), owner)
    elif l.isRefKindName(pat.typeKind, pat.typeName):
      parts.add newTree(nkPrefix, info, l.id("not", info),
                        newTree(nkCall, info, l.id("isNil", info), copyTree(subj)))
    let ptypes = pat.argParam
    let o = l.fresh("nsWhole")
    let body = newNodeI(nkStmtList, info)
    body.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(o, info),
                                                empty(info), copyTree(owner)))
    var tests: seq[PNode] = @[]
    var names: seq[string] = @[]
    for i, x in pat.sons:
      let v = l.fresh("nsPart")
      names.add v
      if pat.strVal == "tuple":
        body.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(v, info),
          empty(info), newTree(nkDotExpr, info, l.id(o, info), l.id("Item" & $(i + 1), info))))
      else:
        let et = (if ptypes != nil and i < ptypes.sons.len: ptypes.sons[i].typ else: nil)
        body.add newTree(nkVarSection, info, newTree(nkIdentDefs, info, l.id(v, info),
          l.typeToNim(et, info), empty(info)))
    if pat.strVal == "Deconstruct":
      let call = newTree(nkCall, info, newTree(nkDotExpr, info, l.id(o, info),
                                              l.id("Deconstruct", info)))
      for v in names: call.add l.id(v, info)
      body.add call
    for i, x in pat.sons: tests.add l.patTest(l.id(names[i], info), x)
    if pat.name.len > 0: tests.add l.assignTrue(pat.name, l.id(o, info), info)
    body.add l.andAll(tests, info)
    parts.add newTree(nkBlockExpr, info, empty(info), body)
    result = l.andAll(parts, info)
  of nsnPatList:
    ## `[p, .., q]`: the length -- exactly the element count, or at least the
    ## count beside the slice -- then each element against its pattern, those after
    ## the slice counted from the end, and the slice against its own.
    let native = pat.strVal == "native"
    let len = l.fresh("nsLen")
    var before, after = 0
    var sliceAt = -1
    for i, x in pat.sons:
      if x.kind == nsnPatSlice: sliceAt = i
      elif sliceAt < 0: inc before
      else: inc after
    var parts: seq[PNode] = @[]
    if not native:
      parts.add newTree(nkPrefix, info, l.id("not", info),
                        newTree(nkCall, info, l.id("isNil", info), copyTree(subj)))
    let measure = (if native: newTree(nkCall, info, l.id("len", info), copyTree(subj))
                   else: newTree(nkDotExpr, info, copyTree(subj), l.id(pat.strVal, info)))
    let lenOk = newTree(nkInfix, info, l.id(if sliceAt >= 0: ">=" else: "==", info),
                        l.id(len, info), newIntNode(nkIntLit, before + after))
    var inner: seq[PNode] = @[lenOk]
    var k = 0
    for i, x in pat.sons:
      if x.kind == nsnPatSlice:
        if x.body != nil:
          let sl = newTree(nkBracketExpr, info, copyTree(subj), newTree(nkInfix, info,
            l.id("..<", info), newIntNode(nkIntLit, before),
            newTree(nkInfix, info, l.id("-", info), l.id(len, info),
                    newIntNode(nkIntLit, after))))
          let v = l.fresh("nsSlice")
          inner.add newTree(nkBlockExpr, info, empty(info), newTree(nkStmtList, info,
            newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(v, info),
                                               empty(info), sl)),
            l.patTest(l.id(v, info), x.body)))
        continue
      let idx = (if sliceAt < 0 or i < sliceAt: newIntNode(nkIntLit, i)
                 else: newTree(nkInfix, info, l.id("-", info), l.id(len, info),
                               newIntNode(nkIntLit, pat.sons.len - i)))
      inc k
      let v = l.fresh("nsItem")
      inner.add newTree(nkBlockExpr, info, empty(info), newTree(nkStmtList, info,
        newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(v, info), empty(info),
          newTree(nkBracketExpr, info, copyTree(subj), idx))),
        l.patTest(l.id(v, info), x)))
    parts.add newTree(nkBlockExpr, info, empty(info), newTree(nkStmtList, info,
      newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(len, info), empty(info),
                                         newTree(nkCall, info, l.id("int", info), measure))),
      l.andAll(inner, info)))
    result = l.andAll(parts, info)
  of nsnPatProp:
    ## `T { P: pat } p`: not null, of `T`, and each member matching its pattern.
    var parts: seq[PNode] = @[]
    var owner = subj
    let subjIface = l.scope.isValueInterface(pat.typeName)
    if subjIface:
      owner = newTree(nkDotExpr, info, copyTree(subj), l.id("nsObj", info))
    if pat.typ != nil:
      parts.add l.typeTest(subj, pat, pat.typ, "")
      let tname = canonicalTypeName(pat.typ.name)
      if l.boxedImpl(tname) and (subjIface or l.isRefKindName(pat.typeKind, pat.typeName)):
        owner = newTree(nkDotExpr, info, newTree(nkCall, info,
                        l.id("nsBox_" & tname, info), owner), l.id("v", info))
      elif l.isRefKindName(pat.typeKind, pat.typeName) or subjIface or
           pat.typeKind == tkUnknown:
        owner = newTree(nkCall, info, l.typeToNim(pat.typ, info), owner)
    elif l.isRefKindName(pat.typeKind, pat.typeName):
      parts.add newTree(nkPrefix, info, l.id("not", info),
                        newTree(nkCall, info, l.id("isNil", info), copyTree(subj)))
    for f in pat.sons:
      let v = l.fresh("nsField")
      var access = copyTree(owner)
      for part in f.name.split('.'):
        access = newTree(nkDotExpr, info, access, l.id(part, info))
      parts.add newTree(nkBlockExpr, info, empty(info), newTree(nkStmtList, info,
        newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(v, info),
                                           empty(info), access)),
        l.patTest(l.id(v, info), f.body)))
    if pat.name.len > 0: parts.add l.assignTrue(pat.name, copyTree(owner), info)
    result = l.andAll(parts, info)
  else: result = l.id("true", info)

proc isPatternToNim(l: Lowerer; n: NsNode): PNode =
  ## `x is pattern`: the subject read once, then tested.
  let s = l.fresh("nsSubj")
  result = newTree(nkBlockExpr, n.info, empty(n.info), newTree(nkStmtList, n.info,
    newTree(nkLetSection, n.info, newTree(nkIdentDefs, n.info, l.id(s, n.info),
                                         empty(n.info), l.expr(n.body))),
    l.patTest(l.id(s, n.info), n.sons[0])))

proc exprBindings(n: NsNode; into: var seq[NsNode])

proc switchExprToNim(l: Lowerer; n: NsNode): PNode =
  ## `x switch { p1 when g1 => v1, ... }`: the subject read once, then a chain of
  ## arms, each in a block of its own so their variables do not meet. No match
  ## throws, as C#'s `SwitchExpressionException` does.
  let info = n.info
  let s = l.fresh("nsSubj")
  proc chain(l: Lowerer; i: int): PNode =
    if i >= n.sons.len:
      return newTree(nkRaiseStmt, info, newTree(nkCall, info,
        l.id("newException", info), l.id("SwitchExpressionException", info),
        newAtom(nkStrLit, "Non-exhaustive switch expression failed to match its input.",
                info)))
    let arm = n.sons[i]
    var test = l.patTest(l.id(s, info), arm.sons[0])
    if arm.sons[1] != nil:
      test = newTree(nkInfix, info, l.id("and", info), test, l.expr(arm.sons[1]))
    let body = newNodeI(nkStmtList, info)
    var binds: seq[NsNode] = @[]
    patternBindings(arm.sons[0], binds)
    exprBindings(arm.sons[1], binds)
    exprBindings(arm.sons[2], binds)
    l.bindingDecls(binds, body)
    body.add newTree(nkIfExpr, info,
      newTree(nkElifExpr, info, test, l.expr(arm.sons[2])),
      newTree(nkElseExpr, info, l.chain(i + 1)))
    result = newTree(nkBlockExpr, info, empty(info), body)
  result = newTree(nkBlockExpr, info, empty(info), newTree(nkStmtList, info,
    newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(s, info), empty(info),
                                       l.expr(n.body))),
    l.chain(0)))

proc labelSwitchBreaks(n: NsNode; label: string) =
  ## Every `break` that leaves this switch -- not one inside a nested loop or switch
  ## -- names the switch's block, since Nim's `break` would leave a loop.
  if n == nil: return
  case n.kind
  of nsnBreak:
    if n.name.len == 0: n.name = label
  of nsnWhile, nsnDoWhile, nsnFor, nsnForeach, nsnSwitch, nsnLambda, nsnLocalFunc:
    discard
  else:
    for x in n.sons: labelSwitchBreaks(x, label)
    if n.kind in {nsnBlock, nsnBlockStmt, nsnIfBranch, nsnElseBranch, nsnIf, nsnTry,
                  nsnCatch, nsnFinally, nsnChecked, nsnUnchecked, nsnUsingStmt, nsnLock}:
      labelSwitchBreaks(n.body, label)

proc isConstLabel(lab: NsNode): bool =
  ## A label Nim's `case` can take: a constant without a guard.
  lab.kind == nsnCaseLabel and lab.sons.len == 0 and lab.body != nil and
    lab.body.kind == nsnPatConst and lab.body.body != nil and
    lab.body.body.kind != nsnNull

proc switchToNim(l: Lowerer; n: NsNode): PNode =
  ## A switch is a labeled block, so `break` leaves it from anywhere in a section. A
  ## section without statements shares the next section's (`case 1: case 2: ...`).
  ## When every label is a constant it is Nim's `case`; otherwise a chain of tests
  ## over the subject, read once, each section in a block of its own for its
  ## pattern variables, with `default` last whatever its position.
  let info = n.info
  let label = l.fresh("nsSwitch")
  var sections: seq[tuple[labels: seq[NsNode], isDefault: bool, body: NsNode]] = @[]
  var pending: seq[NsNode] = @[]
  var pendingDefault = false
  for sec in n.sons:
    if sec.name == "default": pendingDefault = true
    else:
      for lab in sec.sons: pending.add lab
    if sec.body != nil and sec.body.sons.len > 0:
      labelSwitchBreaks(sec.body, label)
      sections.add (labels: pending, isDefault: pendingDefault, body: sec.body)
      pending = @[]
      pendingDefault = false
  var allConst = true
  for sec in sections:
    for lab in sec.labels:
      if not isConstLabel(lab): allConst = false
  let inner = newNodeI(nkStmtList, info)
  if allConst:
    let cs = newNodeI(nkCaseStmt, info)
    cs.add l.expr(n.body)
    var hasDefault = false
    for sec in sections:
      if sec.isDefault: continue
      let br = newNodeI(nkOfBranch, info)
      for lab in sec.labels: br.add l.expr(lab.body.body)
      br.add l.stmtSeq(sec.body)
      cs.add br
    for sec in sections:
      if sec.isDefault:
        cs.add newTree(nkElse, info, l.stmtSeq(sec.body))
        hasDefault = true
    if not hasDefault:
      ## C# does not require a `default`; Nim `case` needs an `else`.
      cs.add newTree(nkElse, info, newTree(nkStmtList, info,
                                          newTree(nkDiscardStmt, info, empty(info))))
    inner.add cs
  else:
    let s = l.fresh("nsSubj")
    inner.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(s, info),
                                                 empty(info), l.expr(n.body)))
    var defaultBody: NsNode = nil
    for sec in sections:
      if sec.isDefault:
        defaultBody = sec.body
        continue
      let blk = newNodeI(nkStmtList, info)
      var binds: seq[NsNode] = @[]
      var tests: seq[PNode] = @[]
      for lab in sec.labels:
        patternBindings(lab.body, binds)
        var t = l.patTest(l.id(s, info), lab.body)
        if lab.sons.len > 0:
          exprBindings(lab.sons[0], binds)
          t = newTree(nkInfix, info, l.id("and", info), t, l.expr(lab.sons[0]))
        tests.add t
      l.bindingDecls(binds, blk)
      var cond = tests[0]
      for i in 1 ..< tests.len:
        cond = newTree(nkInfix, info, l.id("or", info), cond, tests[i])
      let body = l.stmtSeq(sec.body)
      ## A section ends in a jump in C#; one that does not leave is made to.
      if body.len == 0 or body[^1].kind notin {nkReturnStmt, nkRaiseStmt, nkBreakStmt,
                                               nkContinueStmt}:
        body.add newTree(nkBreakStmt, info, l.id(label, info))
      blk.add newTree(nkIfStmt, info, newTree(nkElifBranch, info, cond, body))
      inner.add newTree(nkBlockStmt, info, empty(info), blk)
    if defaultBody != nil:
      inner.add l.stmtSeq(defaultBody)
  result = newTree(nkBlockStmt, info, l.id(label, info), inner)

proc labelForContinues(n: NsNode; label: string; found: var bool) =
  ## Marks the `continue`s of the enclosing loop -- not one in a nested loop -- so
  ## they lower to `break label`.
  if n == nil: return
  case n.kind
  of nsnContinue:
    if n.name.len == 0:
      n.name = label
      found = true
  of nsnWhile, nsnDoWhile, nsnFor, nsnForeach, nsnLambda, nsnLocalFunc: discard
  else:
    for x in n.sons: labelForContinues(x, label, found)
    if n.kind in {nsnBlock, nsnBlockStmt, nsnIfBranch, nsnElseBranch, nsnIf, nsnTry,
                  nsnCatch, nsnFinally, nsnChecked, nsnUnchecked, nsnSwitchSection,
                  nsnUsingStmt, nsnLock}:
      labelForContinues(n.body, label, found)

proc mutatesLocal(n: NsNode; name: string): bool =
  ## Whether a statement assigns a local, steps it, or passes it as `ref`/`out`.
  if n == nil or n.kind in {nsnLambda, nsnLocalFunc}: return false
  if n.kind == nsnIncDec and n.body != nil and n.body.kind == nsnIdent and
     n.body.name == name:
    return true
  if assignsLocal(n, name): return true
  if mutatesLocal(n.body, name): return true
  for x in n.sons:
    if mutatesLocal(x, name): return true
  false

proc counterOf(l: Lowerer; n: NsNode): string =
  ## A `for` loop's counter when it is never negative: an `int` local starting at
  ## a non-negative constant (or a counter of an enclosing such loop, plus one),
  ## stepped only by `++` in the header. "" otherwise.
  let header = n.body
  if header == nil or header.sons.len < 3: return ""
  let init = header.sons[0]
  var step = header.sons[2]
  if step != nil and step.kind == nsnExprStmt: step = step.body
  if init == nil or init.kind != nsnLocalDecl or init.body == nil: return ""
  if step == nil or step.kind != nsnIncDec or step.name != "inc" or step.body == nil or
     step.body.kind != nsnIdent or step.body.name != init.name:
    return ""
  if init.typ == nil or init.typ.kind != nsnTypeName or
     canonicalTypeName(init.typ.name) notin ["int", "Int32"]:
    return ""
  proc nonneg(l: Lowerer; e: NsNode): bool =
    if e == nil: return false
    case e.kind
    of nsnIntLit: e.intVal >= 0
    of nsnIdent: e.name in l.nonneg
    of nsnBinary: e.name == "+" and e.sons.len == 2 and l.nonneg(e.sons[0]) and
                  l.nonneg(e.sons[1])
    else: false
  if not l.nonneg(init.body): return ""
  let c = init.name
  if mutatesLocal(header.sons[1], c): return ""
  for x in n.sons:
    if mutatesLocal(x, c): return ""
  c

proc forToNim(l: Lowerer; n: NsNode): PNode =
  ## `for (init; cond; step) body` -> `block: (init; while cond: (body; step))`,
  ## since Nim has no C-style `for`.
  let header = n.body
  var l = l
  let counter = l.counterOf(n)
  var bound = ""   ## the array `counter < a.Length` keeps the counter inside
  if counter.len > 0:
    l.nonneg.add counter
    let cond = header.sons[1]
    if cond != nil and cond.kind == nsnBinary and cond.name == "<" and cond.sons.len == 2 and
       cond.sons[0].kind == nsnIdent and cond.sons[0].name == counter and
       cond.sons[1].kind == nsnMember and cond.sons[1].name == "Length" and
       cond.sons[1].body != nil and cond.sons[1].body.kind == nsnIdent and
       cond.sons[1].body.typeName.endsWith("[]"):
      let a = cond.sons[1].body.name
      var changed = false
      for x in n.sons: changed = changed or mutatesLocal(x, a)
      if not changed: bound = a
  let blk = newNodeI(nkBlockStmt, n.info)
  blk.add empty(n.info)
  let sl = newNodeI(nkStmtList, n.info)
  if header != nil and header.sons.len > 0 and header.sons[0] != nil:
    sl.add l.stmt(header.sons[0])
  let w = newNodeI(nkWhileStmt, n.info)
  if bound.len > 0:
    ## Marked for `elideBounds`, which drops the checks on `a[counter]` in the body
    ## once it has seen that neither is a closure's or a `var` parameter.
    w.add newTree(nkCall, n.info, l.id("nsForBound", n.info), l.id(counter, n.info),
                  l.id(bound, n.info), l.expr(header.sons[1]))
  elif header != nil and header.sons.len > 1 and header.sons[1] != nil:
    w.add l.expr(header.sons[1])
  else:
    w.add l.id("true", n.info)
  let wbody = newNodeI(nkStmtList, n.info)
  let hasStep = header != nil and header.sons.len > 2 and header.sons[2] != nil
  var label = ""
  if hasStep:
    ## C#'s `continue` runs the step; Nim's would skip it, so this loop's
    ## `continue`s leave a block around the body instead.
    label = l.fresh("nsForBody")
    var found = false
    for s in n.sons: labelForContinues(s, label, found)
    if not found: label = ""
  if label.len > 0:
    let body = newNodeI(nkStmtList, n.info)
    l.addStmts(body, n.sons, n.info)
    wbody.add newTree(nkBlockStmt, n.info, l.id(label, n.info), body)
  else:
    l.addStmts(wbody, n.sons, n.info)
  if hasStep:
    wbody.add l.stmt(header.sons[2])
  w.add wbody
  sl.add w
  blk.add sl
  result = blk

proc catchMatch(l: Lowerer; c: NsNode; exc: PNode): PNode =
  ## Whether the current exception is one a `catch` clause takes.
  if c.typ == nil or c.typ.kind in {nsnEmpty, nsnVoidType}: return l.id("true", c.info)
  newTree(nkInfix, c.info, l.id("of", c.info), exc, l.objTypeToNim(c.typ, c.info))

proc catchVar(l: Lowerer; c: NsNode; exc: PNode): PNode =
  ## `let e = (ref T)(exc)`: the clause's variable, when it names one.
  if c.typ == nil or c.typ.kind in {nsnEmpty, nsnVoidType}: return empty(c.info)
  newTree(nkLetSection, c.info, newTree(nkIdentDefs, c.info, l.id(c.name, c.info),
    empty(c.info), newTree(nkCall, c.info,
      newTree(nkPar, c.info, newTree(nkRefTy, c.info, l.objTypeToNim(c.typ, c.info))),
      exc)))

proc anyException(l: Lowerer; info: TLineInfo): PNode =
  ## `system.Exception`: every exception, Nim's defects included.
  newTree(nkDotExpr, info, l.id("system", info), l.id("Exception", info))

proc filteredTryToNim(l: Lowerer; n: NsNode): PNode =
  ## A `try` with a `catch ... when (filter)`. Nim's `except` has no filter, so one
  ## branch takes every exception and picks the first clause that matches and whose
  ## filter holds -- the filter sees the clause's variable -- then runs that clause's
  ## body, or re-raises when none applies. C# runs filters before unwinding, so a
  ## `finally` nested in the `try` runs earlier here than in C#.
  let info = n.info
  result = newNodeI(nkTryStmt, info)
  result.add l.stmtSeq(n.body)
  let exc = l.fresh("nsExc")
  let pick = l.fresh("nsPick")
  let br = newTree(nkExceptBranch, info, l.anyException(info))
  let body = newNodeI(nkStmtList, info)
  for r in l.cacheResets(info): body.add r
  body.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(exc, info),
    empty(info), newTree(nkCall, info, l.id("getCurrentException", info))))
  ## Named and its trace cut before a filter can read it (see `tryToNim`); the
  ## whole trace is kept, and put back when no clause takes the exception, so one
  ## re-raised past every filter keeps its outer frames.
  let saved = l.fresh("nsTrace")
  body.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(saved, info),
    empty(info), newTree(nkDotExpr, info, l.id(exc, info), l.id("trace", info))))
  body.add newTree(nkCall, info, l.id("nsAdoptException", info), l.id(exc, info))
  body.add newTree(nkVarSection, info, newTree(nkIdentDefs, info, l.id(pick, info),
    empty(info), newIntNode(nkIntLit, 0)))
  var k = 0
  let dispatch = newNodeI(nkIfStmt, info)
  var finallyNode: PNode = nil
  for c in n.sons:
    if c.kind == nsnFinally:
      finallyNode = newTree(nkFinally, c.info, l.afterThrow(l.stmtSeq(c.body)))
      continue
    if c.kind != nsnCatch: continue
    inc k
    let unpicked = newTree(nkInfix, c.info, l.id("==", c.info), l.id(pick, c.info),
                           newIntNode(nkIntLit, 0))
    let test = newTree(nkInfix, c.info, l.id("and", c.info), unpicked,
                       l.catchMatch(c, l.id(exc, c.info)))
    let setPick = newTree(nkAsgn, c.info, l.id(pick, c.info), newIntNode(nkIntLit, k))
    let then = newNodeI(nkStmtList, c.info)
    then.add l.catchVar(c, l.id(exc, c.info))
    if c.sons.len > 0:
      then.add newTree(nkIfStmt, c.info, newTree(nkElifBranch, c.info,
                                                l.expr(c.sons[0]), setPick))
    else: then.add setPick
    body.add newTree(nkIfStmt, c.info, newTree(nkElifBranch, c.info, test,
      newTree(nkBlockStmt, c.info, empty(c.info), then)))
    let run = newNodeI(nkStmtList, c.info)
    run.add l.catchVar(c, l.id(exc, c.info))
    run.add l.stmtSeq(c.body)
    dispatch.add newTree(nkElifBranch, c.info, newTree(nkInfix, c.info, l.id("==", c.info),
      l.id(pick, c.info), newIntNode(nkIntLit, k)), run)
  dispatch.add newTree(nkElse, info, newTree(nkStmtList, info,
    newTree(nkAsgn, info, newTree(nkDotExpr, info, l.id(exc, info), l.id("trace", info)),
            l.id(saved, info)),
    newTree(nkRaiseStmt, info, empty(info))))
  body.add dispatch
  br.add body
  result.add br
  if finallyNode != nil: result.add finallyNode

proc usingToNim(l: Lowerer; n: NsNode): PNode =
  ## `using (r) body` disposes `r` when the body is left, however it is left, and
  ## several resources in the reverse of their order; Nim's `defer` runs at the end
  ## of the enclosing scope, in the same reverse order. The statement form is a block
  ## of its own; `using var` defers in the block it is declared in. A null resource
  ## is not disposed.
  let info = n.info
  let sl = newNodeI(nkStmtList, info)
  for r in n.sons:
    var v: PNode
    if r.kind == nsnLocalDecl:
      sl.add l.stmt(r)
      v = l.id(r.name, r.info)
    else:
      let t = l.fresh("nsUsing")
      sl.add newTree(nkLetSection, r.info, newTree(nkIdentDefs, r.info, l.id(t, r.info),
                                                  empty(r.info), l.expr(r)))
      v = l.id(t, r.info)
    let disposal = newTree(nkStmtList, r.info,
      newTree(nkCall, r.info, l.id("nsDispose", r.info), v))
    ## `Dispose` may move engine objects: what is kept before it is dropped.
    for x in l.cacheResets(r.info): disposal.add x
    sl.add newTree(nkDefer, r.info, disposal)
  if n.body == nil: return sl
  sl.add l.stmtSeq(n.body)
  result = newTree(nkBlockStmt, info, empty(info), sl)

proc lockToNim(l: Lowerer; n: NsNode): PNode =
  ## `lock (x) body`: a program has one thread, so the lock is always free. The
  ## locked expression is still evaluated.
  let info = n.info
  let sl = newNodeI(nkStmtList, info)
  sl.add newTree(nkDiscardStmt, info, l.expr(n.body))
  l.addStmts(sl, n.sons, n.info)
  result = newTree(nkBlockStmt, info, empty(info), sl)

proc tryToNim(l: Lowerer; n: NsNode): PNode =
  for c in n.sons:
    if c.kind == nsnCatch and c.sons.len > 0: return l.filteredTryToNim(n)
  if l.inIterator and hasYield(n.body):
    for c in n.sons:
      if c.kind == nsnFinally:
        ## A `try` an iterator may be suspended in: its `finally` is a closure,
        ## registered while the body runs, so disposing the enumerator early runs
        ## it (`foreach` left by `break`), and run as usual otherwise.
        let info = n.info
        let fin = l.fresh("nsFin")
        let fp = newTree(nkFormalParams, info, empty(info))
        let finProc = newNodeI(nkLambda, info, 7)
        for i in 0 .. 6: finProc[i] = empty(info)
        finProc[3] = fp
        finProc[4] = newTree(nkPragma, info, l.id("closure", info))
        finProc[6] = l.afterThrow(l.stmtSeq(c.body))
        var plain = copyNsNode(n)
        plain.sons = @[]
        for x in n.sons:
          if x.kind != nsnFinally: plain.sons.add x
        let tryPart = (if plain.sons.len > 0: l.tryToNim(plain) else: l.stmtSeq(n.body))
        result = newTree(nkStmtList, info,
          newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(fin, info),
                                              empty(info), finProc)),
          newTree(nkCall, info, l.id("nsDisposePush", info), l.id("nsDisp", info),
                  l.id(fin, info)),
          newTree(nkTryStmt, info, tryPart, newTree(nkFinally, info, newTree(nkStmtList, info,
            newTree(nkCall, info, l.id("nsDisposePop", info), l.id("nsDisp", info)),
            newTree(nkCall, info, l.id(fin, info))))))
        return
  result = newNodeI(nkTryStmt, n.info)
  result.add l.stmtSeq(n.body)
  for c in n.sons:
    if c.kind == nsnCatch:
      let br = newNodeI(nkExceptBranch, c.info)
      if c.typ != nil and c.typ.kind notin {nsnEmpty, nsnVoidType}:
        ## `except T as e`
        let asNode = newNodeI(nkInfix, c.info)
        asNode.add l.id("as", c.info)
        asNode.add l.objTypeToNim(c.typ, c.info)
        asNode.add l.id(c.name, c.info)
        br.add asNode
      else:
        ## `catch { }` takes everything, the runtime's errors too (a bare `except`
        ## would leave out Nim's defects, `NullReferenceException` among them).
        br.add l.anyException(c.info)
      var handler = l.afterThrow(l.stmtSeq(c.body))
      if c.typ != nil and c.typ.kind notin {nsnEmpty, nsnVoidType} and c.name.len > 0:
        ## A defect Nim's runtime raised is given .NET's message once, here, where
        ## the program first sees it, so reading `Message` is reading a field.
        handler = newTree(nkStmtList, c.info,
          newTree(nkCall, c.info, l.id("nsAdoptException", c.info), l.id(c.name, c.info)), handler)
      br.add handler
      result.add br
    elif c.kind == nsnFinally:
      let f = newNodeI(nkFinally, c.info)
      f.add l.afterThrow(l.stmtSeq(c.body))
      result.add f

proc noneCall(l: Lowerer; t: NsNode; info: TLineInfo): PNode =
  ## `none(T)`: the absent value of a `T?`.
  result = newNodeI(nkCall, info)
  result.add l.id("none", info)
  result.add (if t.kind == nsnNullableType: l.typeToNim(t.typ, info)
              else: l.typeToNim(t, info))

proc someCall(l: Lowerer; v: PNode; inner: NsNode; info: TLineInfo): PNode =
  ## `some[int32](v)`: C# converts a value to `T?` implicitly, and the element type is
  ## stated because a literal's own type (Nim's `int`) is not it.
  result = newNodeI(nkCall, info)
  result.add newTree(nkBracketExpr, info, l.id("some", info),
                     l.typeToNim(inner, info))
  result.add v

proc someNamed(l: Lowerer; v: PNode; name: string; info: TLineInfo): PNode =
  ## `some[int32](v)` where the target's type is only known by name.
  result = newNodeI(nkCall, info)
  result.add newTree(nkBracketExpr, info, l.id("some", info),
                     l.id(nimTypeName(name), info))
  result.add v

proc noneFromName(l: Lowerer; name: string; info: TLineInfo): PNode =
  ## `none(T)` for a target whose type is only known by name (`x = null` on `int?`).
  result = newNodeI(nkCall, info)
  result.add l.id("none", info)
  result.add l.id(nimTypeName(name), info)

proc wrappedArg(l: Lowerer; a: NsNode): PNode =
  ## One call argument, with the implicit conversion `sema.nim` chose from the
  ## parameter's declared type applied: a value into a `T?` parameter becomes
  ## `some[T](value)` and `null` into one becomes `none(T)`, which is what C# does
  ## without writing anything.
  if a.kind == nsnNamedArg:
    ## `name: v` is Nim's `name = v`, the value converted as any argument is.
    return newTree(nkExprEqExpr, a.info, l.id(a.name, a.info), l.wrappedArg(a.body))
  result = l.expr(a)
  case a.argConv
  of acSome: result = l.someNamed(result, a.argConvType, a.info)
  of acNoneOption: result = l.noneFromName(a.argConvType, a.info)
  of acNone: discard

proc presentOf(l: Lowerer; v: NsNode; info: TLineInfo): PNode =
  ## `nsPresent(v)`, for a cast of a `T?` to its element type.
  result = newNodeI(nkCall, info)
  result.add l.id("nsPresent", info)
  result.add l.expr(v)

proc localDeclToNim(l: Lowerer; n: NsNode): PNode =
  if n.paramMod == "ref" and n.body != nil and n.body.kind == nsnRefArg:
    ## `ref T r = ref x;`: a pointer to `x`, which every use of `r` dereferences.
    var bare = l
    bare.nilChecks = false
    return newTree(nkVarSection, n.info, newTree(nkIdentDefs, n.info, l.id(n.name, n.info),
      empty(n.info), newTree(nkCall, n.info, l.id("addr", n.info), bare.expr(n.body.body))))
  let defs = newNodeI((if n.declKind == dkConst: nkConstDef else: nkIdentDefs), n.info)
  defs.add l.id(n.name, n.info)
  defs.add l.typeToNim(n.typ, n.info)
  var value = empty(n.info)
  let nullable = n.typ != nil and n.typ.typeKind == tkNullable
  if n.body != nil:
    if nullable and n.body.kind == nsnNull:
      ## `int? x = null;` is the absent value.
      value = l.noneCall(n.typ, n.info)
    else:
      value = l.expr(n.body)
      if nullable and n.body.typeKind != tkNullable:
        ## `int? x = 5;`, where C# converts the value to `T?` implicitly.
        value = l.someCall(value, n.typ.typ, n.info)
  elif nullable:
    ## `int? x;` starts absent.
    value = l.noneCall(n.typ, n.info)
  if n.cell:
    ## A loop-body variable a lambda captures: a cell per iteration.
    let t = defs[1]
    let init = (if value.kind != nkEmpty: value
                else: newTree(nkCall, n.info, l.id("default", n.info), copyTree(t)))
    let maker = (if t.kind != nkEmpty:
                   newTree(nkBracketExpr, n.info, l.id("nsCellOf", n.info), copyTree(t))
                 else: l.id("nsCellOf", n.info))
    defs[1] = empty(n.info)
    value = newTree(nkCall, n.info, maker, init)
  defs.add value
  let kind = case n.declKind
    of dkVar: nkVarSection
    of dkLet: nkLetSection
    of dkConst: nkConstSection
  result = newNodeI(kind, n.info)
  result.add defs

proc isRefValue(l: Lowerer; e: NsNode): bool =
  ## Whether `e`'s value is a reference, so a temporary holding it reaches the very
  ## object `e` does: a class instance, an array or collection, a delegate. A struct
  ## is copied by a temporary, so it is never one.
  case e.typeKind
  of tkSequence, tkDelegate, tkException: true
  of tkClass:
    let cn = canonicalTypeName(e.typeName)
    cn.len > 0 and not l.boxedImpl(cn) and
      not (l.scope.classes.hasKey(cn) and l.scope.classes[cn].classKind == ckStruct)
  else: false

proc isPropertyRead(l: Lowerer; e: NsNode): bool =
  ## `x.P` where `P` is a property of an N# class: reading it runs the getter.
  if e == nil or e.kind != nsnMember or e.body == nil: return false
  let owner = (if e.body.kind == nsnThis and l.curClass != nil: l.curClass.name
               else: canonicalTypeName(e.body.typeName))
  l.scope.classes.hasKey(owner) and l.scope.findMemberInfo(owner, e.name).isProperty

proc stabilize(l: Lowerer; target, later: NsNode; pre: var seq[PNode]): NsNode =
  ## The target of a compound assignment or an increment with every part C#
  ## evaluates once (ECMA-334 12.21.4) bound to a temporary first: a receiver that
  ## calls or steps something, or is a property's value, and an index that does or
  ## that `later` (the right side) may change. Lowering then reads and writes the
  ## target through the temporaries, so `arr[k++] += 1` steps `k` once and
  ## `Obj().P += 1` calls `Obj` once. A struct receiver is not copied: its own parts
  ## are stabilised instead, since writing through a copy would be lost. What needs
  ## nothing is returned as it is.
  if target == nil: return target
  let laterMutates = later != nil and mayMutate(later)
  proc bindTemp(l: Lowerer; e: NsNode; pre: var seq[PNode]): NsNode =
    let name = l.fresh("nsTgt")
    pre.add newTree(nkLetSection, e.info, newTree(nkIdentDefs, e.info,
      l.id(name, e.info), empty(e.info), l.expr(e)))
    result = nsn(nsnIdent, e.info)
    result.name = name
    result.typeKind = e.typeKind
    result.typeName = e.typeName
    result.rtype = e.rtype
  proc receiver(l: Lowerer; r: NsNode; pre: var seq[PNode]): NsNode =
    if r == nil or r.typeKind == tkType or r.kind in {nsnIdent, nsnThis, nsnBase}:
      return r
    if l.isRefValue(r) and (mayMutate(r) or l.isPropertyRead(r)):
      return l.bindTemp(r, pre)
    if r.kind in {nsnMember, nsnIndex}:
      ## A struct, or a field chain `a.b.c`: its own parts may still need binding.
      return l.stabilize(r, later, pre)
    r
  case target.kind
  of nsnMember:
    let r = l.receiver(target.body, pre)
    if r == target.body: return target
    result = copyNsNode(target)
    result.body = r
  of nsnIndex:
    let r = l.receiver(target.body, pre)
    var idx: seq[NsNode] = @[]
    var changed = r != target.body
    for x in target.sons:
      let v = (if x.kind == nsnRefArg: x.body else: x)
      if v.kind in {nsnIntLit, nsnCharLit, nsnStrLit, nsnFloatLit} or
         v.typeKind == tkType or not (mayMutate(v) or (laterMutates and isLocation(v))):
        idx.add x
      else:
        idx.add l.bindTemp(x, pre)
        changed = true
    if not changed: return target
    result = copyNsNode(target)
    result.body = r
    result.sons = idx
  else: result = target

proc assignCore(l: Lowerer; n: NsNode): PNode =
  ## The left side is lowered without the nil check, because `nsCheckNil(x).f` is
  ## not an lvalue; the check becomes a statement of its own instead, and only for a
  ## receiver that is a plain name, so no receiver is evaluated twice.
  var bare = l
  bare.nilChecks = false
  if n.strVal == "discard":
    return newTree(nkDiscardStmt, n.info, l.expr(n.sons[1]))
  if n.strVal == "refAssign":
    var bare = l
    bare.nilChecks = false
    return newTree(nkAsgn, n.info, l.id(n.sons[0].name, n.info),
                   newTree(nkCall, n.info, l.id("addr", n.info), bare.expr(n.sons[1].body)))
  let t0 = n.sons[0]
  if n.name.len == 0 and l.isCView(t0):
    ## `*p = v`: the struct stored as its C mirror.
    return newTree(nkAsgn, n.info, l.cView(t0),
                   newTree(nkCall, n.info, l.id("nsToC", n.info), l.expr(n.sons[1])))
  if t0.kind == nsnMember and t0.body != nil and l.isCView(t0.body) and
     not l.isCViewField(t0):
    ## `p->P = v`: a property's setter on a copy, stored back.
    return l.throughCView(t0, n)
  if n.name.len == 0 and t0.kind == nsnMember and t0.body != nil and
     l.scope.qualifiedOnly.hasKey(writtenName(t0.body)):
    for m in l.scope.qualifiedOnly[writtenName(t0.body)].members:
      if m.name == t0.name and m.isProperty:
        ## `Tools.Console.Calls = v`: its setter called by name, since Nim looks
        ## `Calls=` up for `Calls(Tools.Console) = v` among the bare `Console`s.
        return newTree(nkCall, n.info,
                       newTree(nkAccQuoted, n.info, l.id(t0.name & "=", n.info)),
                       l.qualifiedOnlyRef(t0.body), l.expr(n.sons[1]))
  let lhs = bare.expr(n.sons[0])
  var value: PNode
  if n.strVal == "eventAccessor":
    ## `e += h` / `e -= h` on an event with accessors: its `add` or `remove`.
    let t = n.sons[0]
    let call = newTree(nkCall, n.info, l.id((if n.name == "+": "nsAdd_" else: "nsRemove_") &
                                            t.name, n.info))
    if t.kind == nsnMember and t.body != nil: call.add l.expr(t.body)
    elif l.curClass != nil: call.add l.id((if l.thisName.len > 0: l.thisName
                                           else: l.curClass.name), n.info)
    call.add l.expr(n.sons[1])
    return call
  if n.strVal == "event":
    ## `e += h` / `e -= h`: a handler joins or leaves the event's list.
    return newTree(nkCall, n.info,
                   l.id(if n.name == "+": "nsSubscribe" else: "nsUnsubscribe", n.info),
                   lhs, l.expr(n.sons[1]))
  if n.strVal in ["combine", "remove"]:
    ## `d += h`: a delegate that calls `d`'s list, then `h`'s; `d -= h`: `d`'s
    ## list without the last run equal to `h`'s.
    let op = (if n.strVal == "combine": "nsCombine" else: "nsRemove")
    return newTree(nkAsgn, n.info, lhs, newTree(nkCall, n.info, l.id(op, n.info),
                                                copyTree(lhs), l.expr(n.sons[1])))
  if n.name == "??":
    ## `a ??= b`: the compound form of `a = a ?? b`.
    let co = nsn(nsnNullCoalesce, n.info)
    co.name = "??"
    co.sons = @[n.sons[0], n.sons[1]]
    value = bare.nullCoalesceToNim(co)
  elif n.name.len == 0:
    value = l.expr(n.sons[1])
  else:
    ## Compound assignment: `x += e` becomes `x = x + e`. With numeric operands
    ## `sema.nim` recorded the promoted type (`strVal`) and `x`'s own (`typeName`):
    ## `x` is promoted for the operator and the result cast back, as C# does.
    var operand = copyTree(lhs)
    if isLocation(n.sons[0]) and mayMutate(n.sons[1]):
      ## `x op= e` reads `x` before `e` runs (12.21.4): `g += Bump()` adds to the
      ## old `g` even when `Bump` assigns it.
      operand = newTree(nkCall, n.info, l.id("nsVal", n.info), operand)
    if n.strVal.len > 0:
      operand = newTree(nkCall, n.info, l.id(nimTypeName(n.strVal), n.info), operand)
    let rhs = l.expr(n.sons[1])
    if isCheckedOp(n):
      value = newTree(nkCall, n.info, l.id(checkedOperatorName(n.argParam), n.info),
                      operand, rhs)
    elif n.typeKind == tkInt and n.name in ["/", "mod"]:
      value = newTree(nkCall, n.info,
                      l.id((if n.name == "/": "nsDiv" else: "nsMod"), n.info),
                      operand, rhs)
    elif n.typeKind == tkFloat and n.name == "mod":
      value = newTree(nkCall, n.info, l.id("nsFmod", n.info), operand, rhs)
    elif isMaskedShift(n):
      value = newTree(nkCall, n.info, l.id(shiftProc(n.name), n.info), operand, rhs)
    else:
      value = newTree(nkInfix, n.info, l.id(n.name, n.info), operand, rhs)
    if n.strVal.len > 0 and n.typeName.len > 0:
      value = newTree(nkCall, n.info, l.id(nimTypeName(n.typeName), n.info), value)
  let nullableTarget = n.sons[0] != nil and n.sons[0].typeKind == tkNullable
  ## A compound operator's result is lifted already (`a += 2` is `a + 2`, a `T?`).
  let wrapTarget = nullableTarget and (n.name == "??" or
                                        (n.name.len == 0 and n.sons[1].typeKind != tkNullable))
  if wrapTarget:
    ## The result goes back into a `T?` target, so C#'s implicit conversion applies to
    ## `x = 5` and `x ??= 5` alike. `a ?? b` yields the unwrapped `T`, so `??=` always
    ## needs the wrap, while `x = otherNullable` already has one.
    if n.name.len == 0 and n.sons[1].kind == nsnNull:
      value = l.noneFromName(n.sons[0].typeName, n.info)
    else:
      value = l.someNamed(value, n.sons[0].typeName, n.info)
  result = newTree(nkAsgn, n.info, lhs, value)
  let target = n.sons[0]
  if l.nilChecks and target != nil and target.kind == nsnMember and
     target.body != nil and target.body.kind == nsnIdent and
     l.nilableReceiver(target.body):
    let check = l.checkNil(target.body, bare.expr(target.body), n.info)
    result = newTree(nkStmtList, n.info,
                     newTree(nkDiscardStmt, n.info, check), result)


proc withStableTarget(l: Lowerer; n: NsNode; pre: var seq[PNode]): NsNode =
  ## `n` (an assignment) with its target's once-evaluated parts bound in `pre`.
  let t = l.stabilize(n.sons[0], n.sons[1], pre)
  if t == n.sons[0]: return n
  result = copyNsNode(n)
  result.sons = @[t, n.sons[1]]

proc assignToNim(l: Lowerer; n: NsNode): PNode =
  ## A compound assignment evaluates its target's receiver and indices once; a
  ## plain one names its target once already.
  if n.name.len > 0 and n.sons.len == 2 and
     n.strVal notin ["discard", "refAssign", "eventAccessor", "event"]:
    var pre: seq[PNode] = @[]
    let m = l.withStableTarget(n, pre)
    if pre.len > 0:
      result = newNodeI(nkStmtList, n.info)
      for x in pre: result.add x
      result.add l.assignCore(m)
      return
  l.assignCore(n)

proc doWhileToNim(l: Lowerer; n: NsNode): PNode =
  ## C#'s `do { B } while (c)` runs B once and then reads c, and a `continue` in B
  ## must reach that read. A first-pass flag keeps one copy of the body and leaves
  ## `break` and `continue` to Nim's own loop.
  result = newNodeI(nkBlockStmt, n.info)
  result.add empty(n.info)
  let scope = newNodeI(nkStmtList, n.info)
  let defs = newNodeI(nkIdentDefs, n.info)
  defs.add l.id("nsFirst", n.info)
  defs.add newNodeI(nkEmpty, n.info)
  defs.add l.id("true", n.info)
  scope.add newTree(nkVarSection, n.info, defs)
  let cond = newNodeI(nkInfix, n.info)
  cond.add l.id("or", n.info)
  cond.add l.id("nsFirst", n.info)
  cond.add l.expr(n.body)
  let loop = newNodeI(nkWhileStmt, n.info)
  loop.add cond
  let body = newNodeI(nkStmtList, n.info)
  let assign = newNodeI(nkAsgn, n.info)
  assign.add l.id("nsFirst", n.info)
  assign.add l.id("false", n.info)
  body.add assign
  l.addStmts(body, n.sons, n.info)
  loop.add body
  scope.add loop
  result.add scope

proc checkPush(l: Lowerer; checked: bool; info: TLineInfo): PNode =
  ## `{.push overflowChecks: on|off, rangeChecks: on|off.}`: C#'s `checked` state
  ## covers arithmetic and integral conversions alike, and an unchecked narrowing
  ## conversion keeps the low bits (`(short)70000` is 4464) where Nim's checked
  ## one would raise.
  let state = if checked: "on" else: "off"
  result = newTree(nkPragma, info, l.id("push", info),
    newTree(nkExprColonExpr, info, l.id("overflowChecks", info), l.id(state, info)),
    newTree(nkExprColonExpr, info, l.id("rangeChecks", info), l.id(state, info)))

proc checkedToNim(l: Lowerer; n: NsNode): PNode =
  ## C# turns overflow checking on inside `checked` and off inside `unchecked`,
  ## which is Nim's `overflowChecks` switch.
  result = newNodeI(nkStmtList, n.info)
  result.add l.checkPush(n.kind == nsnChecked, n.info)
  var inner = l
  inner.checked = n.kind == nsnChecked
  inner.addStmts(result, n.sons, n.info)
  let pop = newNodeI(nkPragma, n.info)
  pop.add l.id("pop", n.info)
  result.add pop

proc checkedExprToNim(l: Lowerer; n: NsNode): PNode =
  ## `checked(e)`: the operand computed under the `overflowChecks` state it names.
  let info = n.info
  let t = l.fresh("nsChecked")
  let sl = newNodeI(nkStmtList, info)
  sl.add l.checkPush(n.name == "checked", info)
  var inner = l
  inner.checked = n.name == "checked"
  sl.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(t, info),
                                            empty(info), inner.expr(n.body)))
  sl.add newTree(nkPragma, info, l.id("pop", info))
  sl.add l.id(t, info)
  result = newTree(nkBlockExpr, info, empty(info), sl)

proc exprBindings(n: NsNode; into: var seq[NsNode]) =
  ## The variables an expression declares -- `out T x` and the variables of
  ## `x is pattern` -- but not those of a nested lambda, or of a switch
  ## expression's arms, which are scoped to the arm.
  if n == nil or n.kind in {nsnLambda, nsnLocalFunc}: return
  case n.kind
  of nsnOutDecl:
    into.add n
    return
  of nsnIsPattern:
    exprBindings(n.body, into)
    if n.sons.len > 0: patternBindings(n.sons[0], into)
    return
  of nsnSwitchExpr:
    exprBindings(n.body, into)
    return
  else: discard
  exprBindings(n.body, into)
  for x in n.sons: exprBindings(x, into)
  for x in n.initArgs: exprBindings(x, into)

proc collectOutDecls(n: NsNode; into: var seq[NsNode]) =
  exprBindings(n, into)

proc outDeclsOf(n: NsNode): seq[NsNode] =
  ## The `out T x` a statement declares: C# scopes them to the enclosing block, so
  ## they are declared before the statement. Only the statement's own expressions
  ## are looked at, never a nested statement's.
  result = @[]
  case n.kind
  of nsnExprStmt, nsnReturn, nsnThrow, nsnWhile, nsnDoWhile, nsnSwitch, nsnForeach,
     nsnLocalDecl:
    collectOutDecls(n.body, result)
  of nsnAssign:
    for x in n.sons: collectOutDecls(x, result)
  of nsnIf:
    for b in n.sons:
      if b.kind == nsnIfBranch: collectOutDecls(b.body, result)
  of nsnMultiDecl:
    for d in n.sons: collectOutDecls(d.body, result)
  else: discard

proc stmtInner(l: Lowerer; n: NsNode): PNode

# --- handle hoisting -------------------------------------------------------------
#
# Each member access through an engine handle resolves it (`nsDeref`: a validity
# test and a lookup). A handle local keeps the object it reaches in `nsP_x` and
# reuses it, until a statement that may create, destroy or move engine objects:
# such a statement resolves handles afresh, and clears every kept pointer after
# it. What may move: a native member unless its class is `Stable` (and the member
# not `[Moves]`), a constructor of such a class, an N# member that may reach one,
# a call N# cannot see the target of (virtual, interface, delegate), and storing a
# class N# owns whose binding is not `Stable` (its C++ destructor may run). A
# cleared pointer is resolved again at its next use, so branches and loops need no
# analysis of their own. `-d:nsNoHandleCache` turns it off.

proc exprMoves(l: Lowerer; n: NsNode): bool
proc memberMoves(l: Lowerer; cls, name: string): bool

proc bodyMoves(l: Lowerer; n: NsNode): bool =
  ## Whether anything in a body may move engine objects, its nested statements
  ## included; a lambda's body counts where it is called, not here.
  if n == nil: return false
  if n.kind in {nsnLambda, nsnLocalFunc}: return false
  if l.exprMoves(n): return true
  if l.bodyMoves(n.body): return true
  for x in n.sons:
    if l.bodyMoves(x): return true
  false

proc memberMoves(l: Lowerer; cls, name: string): bool =
  ## Whether an N# member (every declaration of the name, along its class chain)
  ## may move engine objects. Recursion counts as moving.
  let key = cls & "." & name
  if l.hoist.moves.hasKey(key): return l.hoist.moves[key]
  l.hoist.moves[key] = true
  var r = false
  for c in l.scope.chain(cls):
    let d = l.scope.classes[c].decl
    if d == nil: continue
    if l.scope.isNative(c):
      for m in d.sons:
        if m.name == name and l.scope.nativeMoves(c, name): r = true
      continue
    for m in d.sons:
      if m.name != name and not (name == "" and m.kind == nsnCtorDecl): continue
      case m.kind
      of nsnMethodDecl, nsnCtorDecl: r = r or l.bodyMoves(m.body)
      of nsnPropertyDecl:
        for acc in m.params: r = r or l.bodyMoves(acc)
      of nsnFieldDecl: r = r or l.bodyMoves(m.body)
      else: discard
    if r: break
  l.hoist.moves[key] = r
  r

proc ownedRelease(l: Lowerer; n: NsNode): bool =
  ## A value of a class N# owns whose binding is not `Stable`: storing over one may
  ## run its C++ destructor.
  n != nil and n.typeKind == tkClass and l.scope.classes.hasKey(n.typeName) and
    l.scope.ownedFamily(n.typeName) and not l.scope.nativeStable(n.typeName)

proc exprMoves(l: Lowerer; n: NsNode): bool =
  ## Whether evaluating an expression may move engine objects (lambdas aside).
  if n == nil: return false
  case n.kind
  of nsnLambda, nsnLocalFunc: return false
  of nsnCall:
    let c = n.body
    if c == nil: return true
    if c.kind == nsnMember and c.strVal == "extension":
      if l.scope.extensions.hasKey(c.name) and l.scope.extensions[c.name].len > 0:
        if l.memberMoves(l.scope.extensions[c.name][0].owner, c.name): return true
      else: return true
    elif c.kind == nsnMember and c.body != nil:
      let owner = (if c.body.kind == nsnThis: (if l.curClass != nil: l.curClass.name else: "")
                   else: c.body.typeName)
      if l.scope.classes.hasKey(owner):
        let mi = l.scope.findMemberInfo(owner, c.name)
        if mi.name.len == 0 or not mi.isMethod: return true      ## a delegate
        if l.scope.isNative(mi.owner):
          if l.scope.nativeMoves(mi.owner, c.name): return true
        elif l.scope.isDispatched(owner, c.name) or l.scope.isValueInterface(owner): return true
        elif l.memberMoves(mi.owner, c.name): return true
      elif c.body.typeKind == tkClass and l.scope.isValueInterface(c.body.typeName):
        return true
    else:
      return true                                                ## a local function or delegate
    for a in n.sons:
      if l.ownedRelease(a): return true
  of nsnNew:
    let t = (if n.typ != nil and n.typ.kind == nsnTypeName: unqualified(n.typ.name) else: "")
    if l.scope.classes.hasKey(t):
      if l.scope.nativeBased(t) and not l.scope.nativeStable(t): return true
      if l.memberMoves(t, ""): return true
  of nsnMember:
    if n.body != nil:
      let owner = (if n.body.kind == nsnThis: (if l.curClass != nil: l.curClass.name else: "")
                   else: n.body.typeName)
      if l.scope.classes.hasKey(owner):
        let mi = l.scope.findMemberInfo(owner, n.name)
        if mi.isProperty:
          if l.scope.isNative(mi.owner):
            if l.scope.nativeMoves(mi.owner, n.name): return true
          elif l.scope.isDispatched(owner, n.name) or l.memberMoves(mi.owner, n.name):
            return true
  of nsnIndex:
    if n.body != nil and l.scope.classes.hasKey(n.body.typeName) and
       l.scope.nativeBased(n.body.typeName) and
       not l.scope.nativeStable(n.body.typeName):
      return true
  of nsnAssign:
    if n.sons.len > 0 and l.ownedRelease(n.sons[0]): return true
  else: discard
  if l.exprMoves(n.body): return true
  for x in n.sons:
    if l.exprMoves(x): return true
  false

proc stmtMoves(l: Lowerer; n: NsNode): bool =
  ## Whether a statement's own expressions may move engine objects: its condition,
  ## initializer, subject or value -- not the statements nested in it, which are
  ## judged where they are lowered.
  if n == nil: return false
  case n.kind
  of nsnLocalDecl, nsnExprStmt, nsnReturn, nsnThrow, nsnSwitch:
    l.exprMoves(n.body)
  of nsnIf:
    var r = false
    for b in n.sons:
      if b != nil and b.kind == nsnIfBranch: r = r or l.exprMoves(b.body)
    r
  of nsnWhile, nsnDoWhile: l.exprMoves(n.body)
  of nsnFor: l.bodyMoves(n.body)
  of nsnForeach:
    ## The enumeration itself: a collection of the library's moves nothing.
    l.exprMoves(n.body) or (n.body != nil and n.body.typeKind == tkClass and
                            l.scope.classes.hasKey(n.body.typeName))
  of nsnUsingStmt:
    var r = false
    for x in n.sons: r = r or l.bodyMoves(x)
    r
  of nsnYield:
    ## Whatever runs between the iterator's steps may move anything.
    true
  of nsnBlock, nsnBlockStmt, nsnTry, nsnChecked, nsnUnchecked, nsnBreak, nsnContinue,
     nsnElseBranch:
    false
  else: l.exprMoves(n)

proc hoistedLocal(l: Lowerer; n: NsNode): string =
  ## The engine class a local's handle is of, when it is one N# may keep the object
  ## of: "" otherwise.
  if defined(nsNoHandleCache) or l.hoist == nil or n.paramMod.len > 0 or n.cell or
     n.declKind == dkConst:
    return ""
  let tn = (if n.typ != nil and n.typ.kind == nsnTypeName: canonicalTypeName(n.typ.name)
            elif n.body != nil: n.body.typeName else: "")
  if tn.len > 0 and l.scope.classes.hasKey(tn) and l.scope.engineOwned(tn): tn else: ""

proc cacheDecl(l: Lowerer; name, cls: string; info: TLineInfo): PNode =
  ## `var nsP_x: ptr C = nil`
  newTree(nkVarSection, info, newTree(nkIdentDefs, info, l.id("nsP_" & name, info),
    newTree(nkPtrTy, info, l.id(cls, info)), newNodeI(nkNilLit, info)))

proc cacheResets(l: Lowerer; info: TLineInfo): seq[PNode] =
  ## `nsP_x = nil` for every kept pointer in scope.
  result = @[]
  if l.hoist == nil: return
  for (name, _) in l.hoist.names:
    result.add newTree(nkAsgn, info, l.id("nsP_" & name, info), newNodeI(nkNilLit, info))

proc afterThrow(l: Lowerer; body: PNode): PNode =
  ## A `catch` or `finally` body: the statement that threw may have moved engine
  ## objects before its kept pointers were dropped, so they are dropped here.
  let resets = l.cacheResets(body.info)
  if resets.len == 0: return body
  result = newNodeI(nkStmtList, body.info)
  for r in resets: result.add r
  result.add body

proc isHoisted(l: Lowerer; name: string): bool =
  if l.hoist == nil or l.noCache: return false
  for (n, _) in l.hoist.names:
    if n == name: return true
  false

proc assignsLocal(n: NsNode; name: string): bool =
  ## Whether a statement assigns the local, or passes it as `ref`/`out`.
  if n == nil or n.kind in {nsnLambda, nsnLocalFunc}: return false
  if n.kind == nsnAssign and n.sons.len > 0 and n.sons[0].kind == nsnIdent and
     n.sons[0].name == name:
    return true
  if n.kind == nsnRefArg and n.body != nil and n.body.kind == nsnIdent and n.body.name == name:
    return true
  if assignsLocal(n.body, name): return true
  for x in n.sons:
    if assignsLocal(x, name): return true
  false

proc stmtCore(l: Lowerer; n: NsNode): PNode

proc stmt(l: Lowerer; n: NsNode): PNode =
  if n == nil: return empty(unknownLineInfo)
  if l.hoist != nil and l.hoist.names.len > 0 and not l.noCache and l.stmtMoves(n):
    ## It may move engine objects: handles resolve afresh in it, and nothing kept
    ## survives it.
    var fresh = l
    fresh.noCache = true
    result = newTree(nkStmtList, n.info, fresh.stmtCore(n))
    for r in l.cacheResets(n.info): result.add r
    return
  result = l.stmtCore(n)
  if l.hoist != nil and l.hoist.names.len > 0:
    var after: seq[PNode] = @[]
    for (name, _) in l.hoist.names:
      if assignsLocal(n, name):
        after.add newTree(nkAsgn, n.info, l.id("nsP_" & name, n.info), newNodeI(nkNilLit, n.info))
    if after.len > 0:
      result = newTree(nkStmtList, n.info, result)
      for a in after: result.add a
  if n.kind == nsnLocalDecl:
    let cls = l.hoistedLocal(n)
    if cls.len > 0:
      result = newTree(nkStmtList, n.info, result, l.cacheDecl(n.name, cls, n.info))
      l.hoist.names.add (n.name, cls)

proc stmtCore(l: Lowerer; n: NsNode): PNode =
  if n == nil: return empty(unknownLineInfo)
  let outs = outDeclsOf(n)
  if outs.len == 0: return l.stmtInner(n)
  result = newNodeI(nkStmtList, n.info)
  l.bindingDecls(outs, result)
  result.add l.stmtInner(n)
  if n.kind in {nsnWhile, nsnDoWhile, nsnFor, nsnForeach, nsnSwitch}:
    ## A loop's or a switch's variables are scoped to it, not to the block.
    result = newTree(nkBlockStmt, n.info, empty(n.info), result)

proc deconstructToNim(l: Lowerer; n: NsNode): PNode =
  ## `(a, b) = value`: the value read once, then each target bound or assigned from
  ## its element -- after the whole value is read, so `(a, b) = (b, a)` swaps.
  let info = n.info
  result = newNodeI(nkStmtList, info)
  let t = l.fresh("nsTup")
  result.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(t, info),
                                                empty(info), l.expr(n.body)))
  var values: seq[PNode] = @[]
  if n.strVal == "Deconstruct":
    ## A class's `Deconstruct(out a, out b)` fills temporaries first.
    let call = newTree(nkCall, info, newTree(nkDotExpr, info, l.id(t, info),
                                             l.id("Deconstruct", info)))
    let d = l.scope.findMemberInfo(n.body.typeName, "Deconstruct")
    for k in 0 ..< n.sons.len:
      let v = l.fresh("nsPart")
      let pt = (if k < d.params.len: d.params[k].typ else: nil)
      result.add newTree(nkVarSection, info, newTree(nkIdentDefs, info, l.id(v, info),
                                                    l.typeToNim(pt, info), empty(info)))
      call.add l.id(v, info)
      values.add l.id(v, info)
    result.add call
  else:
    for k in 0 ..< n.sons.len:
      values.add newTree(nkDotExpr, info, l.id(t, info), l.id("Item" & $(k + 1), info))
  for k, target in n.sons:
    case target.kind
    of nsnPatDiscard: discard
    of nsnLocalDecl:
      result.add newTree(nkVarSection, info, newTree(nkIdentDefs, info,
        l.id(target.name, info), l.typeToNim(target.typ, info), values[k]))
    else:
      var bare = l
      bare.nilChecks = false
      result.add newTree(nkAsgn, info, bare.expr(target), values[k])

proc memberBody(l: Lowerer; ret, body: NsNode; params: seq[NsNode] = @[]): PNode =
  ## A member's body. An iterator block becomes a closure iterator inside the
  ## `IEnumerable<T>` (or `IEnumerator<T>`) it returns, so each enumeration runs
  ## the body afresh, lazily, as C#'s does. A parameter the body assigns is a local
  ## copy (`var p = p`), inside the iterator for one.
  var inner = l
  inner.inIterator = body != nil and hasYield(body)
  result = prependAll(inner.stmtSeq(body), l.shadowParams(params, body,
                                                      (if body != nil: body.info else: unknownLineInfo)))
  if body == nil or not hasYield(body): return
  let el = iteratorElement(ret)
  if el == nil: return
  let info = body.info
  let maker = (if canonicalTypeName(ret.name) == "IEnumerable": "nsEnumerable"
               else: "nsEnumerator")
  result = newTree(nkStmtList, info, newTree(nkAsgn, info, l.id("result", info),
    newTree(nkCall, info, l.id(maker, info), l.typeToNim(el, info), result)))

proc localFuncToNim(l: Lowerer; n: NsNode): PNode =
  ## A local function is a nested proc, which captures what it names as a closure.
  var inner = l
  if inner.hoist != nil: inner.hoist = NsHoist(moves: l.hoist.moves)
  for t in n.typeParams: inner.procTypeParams.add t.name
  let fp = inner.formalParams(n.typ, n.params, n.info)
  if n.paramMod == "ref": fp[0] = newTree(nkVarTy, n.info, fp[0])
  for c in n.captures:
    ## A loop-body variable it captures, as the cell of the caller's iteration (see
    ## `markLoopCells`).
    fp.add newTree(nkIdentDefs, n.info, l.id(c, n.info),
                   newTree(nkCall, n.info, l.id("typeof", n.info), l.id(c, n.info)),
                   empty(n.info))
  inner.procTypeParams = @[]
  for t in n.typeParams: inner.procTypeParams.add t.name
  result = inner.mkProc(l.id(n.name, n.info), fp, inner.memberBody(n.typ, n.body, n.params),
                        n.info, withPragmas = true)
  let frame = l.nestedFrame("g__", (if n.name == NsResultLocal: "result" else: n.name), n.params)
  if frame.len > 0: l.framed(result, frame)

proc enumeratorLoop(l: Lowerer; n: NsNode): PNode =
  ## `foreach` over a class with a `GetEnumerator` method, as C# defines it:
  ## `var e = c.GetEnumerator(); while (e.MoveNext()) { var x = e.Current; ... }`.
  let info = n.info
  let e = l.fresh("nsEnum")
  let sl = newNodeI(nkStmtList, info)
  sl.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(e, info),
    empty(info), newTree(nkCall, info,
      newTree(nkDotExpr, info, l.expr(n.body), l.id("GetEnumerator", info)))))
  let body = newNodeI(nkStmtList, info)
  body.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(n.name, info),
    (if n.typ != nil: l.typeToNim(n.typ, info) else: empty(info)),
    newTree(nkDotExpr, info, l.id(e, info), l.id("Current", info))))
  l.addStmts(body, n.sons, n.info)
  sl.add newTree(nkWhileStmt, info, newTree(nkCall, info,
    newTree(nkDotExpr, info, l.id(e, info), l.id("MoveNext", info))), body)
  result = newTree(nkBlockStmt, info, empty(info), sl)

proc isPlainVariable(l: Lowerer; t: NsNode): bool =
  ## Whether Nim's `inc` can take `t`: an integer local, parameter, field or array
  ## element, rather than a property or indexer (a getter's result) or a float.
  if t == nil or t.typeKind in {tkFloat, tkUnknown, tkNullable}: return false
  case t.kind
  of nsnIdent: true
  of nsnIndex: t.body != nil and t.body.typeKind == tkSequence
  of nsnMember:
    if t.body == nil: return false
    let owner = (if t.body.kind == nsnThis and l.curClass != nil: l.curClass.name
                 else: t.body.typeName)
    if not l.scope.classes.hasKey(owner): return false
    let m = l.scope.findMemberInfo(owner, t.name)
    m.name.len > 0 and not m.isProperty and not m.isMethod
  else: false

proc stmtInner(l: Lowerer; n: NsNode): PNode =
  case n.kind
  of nsnLocalFunc: result = l.localFuncToNim(n)
  of nsnDeconstruct: result = l.deconstructToNim(n)
  of nsnMultiDecl:
    result = newNodeI(nkStmtList, n.info)
    for d in n.sons: result.add l.stmt(d)
  of nsnBlock: result = l.stmtSeq(n)
  of nsnBlockStmt:
    let blk = newNodeI(nkBlockStmt, n.info)
    blk.add empty(n.info)
    blk.add l.stmtsToNode(n.sons, n.info)
    result = blk
  of nsnLocalDecl: result = l.localDeclToNim(n)
  of nsnExprStmt:
    if n.body != nil and n.body.kind == nsnNullDot:
      return l.condStmt(n.body)
    if n.body != nil and n.body.kind == nsnIncDec:
      let target = n.body.body
      if l.isPlainVariable(target):
        return newTree(nkCommand, n.info, l.id(n.body.name, n.info), l.expr(target))
      ## A property, an indexer or a float: the stepped value is assigned, the
      ## target's receiver and indices evaluated once for the read and the write.
      var pre: seq[PNode] = @[]
      let stable = l.stabilize(target, nil, pre)
      let step = newTree(nkCall, n.info, l.id(if n.body.name == "inc": "nsInc" else: "nsDec",
                                              n.info), l.expr(stable))
      if pre.len == 0: return step
      result = newNodeI(nkStmtList, n.info)
      for x in pre: result.add x
      result.add step
      return
    result = l.expr(n.body)
    if n.body != nil and n.body.kind == nsnCall and n.body.body != nil and
       n.body.body.kind != nsnMember and n.body.body.typeKind == tkDelegate:
      ## Invoking a delegate as a statement drops its result, which Nim needs said.
      result = newTree(nkCall, n.info, l.id("nsStmt", n.info), result)
  of nsnAssign: result = l.assignToNim(n)
  of nsnIf:
    result = newNodeI(nkIfStmt, n.info)
    for b in n.sons:
      if b.kind == nsnIfBranch:
        let br = newNodeI(nkElifBranch, b.info)
        br.add l.expr(b.body)
        br.add l.stmtsToNode(b.sons, b.info)
        result.add br
      elif b.kind == nsnElseBranch:
        let e = newNodeI(nkElse, b.info)
        e.add l.stmtsToNode(b.sons, b.info)
        result.add e
  of nsnWhile:
    let w = newNodeI(nkWhileStmt, n.info)
    w.add l.expr(n.body)
    w.add l.stmtsToNode(n.sons, n.info)
    result = w
  of nsnDoWhile: result = l.doWhileToNim(n)
  of nsnChecked, nsnUnchecked: result = l.checkedToNim(n)
  of nsnFor: result = l.forToNim(n)
  of nsnForeach:
    if n.strVal == "GetEnumerator": return l.enumeratorLoop(n)
    result = newNodeI(nkForStmt, n.info)
    if n.cell:
      ## A loop variable a lambda captures: each iteration's in a cell of its own.
      let it = l.fresh("nsIt")
      result.add l.id(it, n.info)
      result.add l.expr(n.body)
      let maker = (if n.typ != nil and n.typ.kind != nsnEmpty and
                      not (n.typ.kind == nsnTypeName and n.typ.name == "var"):
                     newTree(nkBracketExpr, n.info, l.id("nsCellOf", n.info),
                             l.typeToNim(n.typ, n.info))
                   else: l.id("nsCellOf", n.info))
      let body = l.stmtsToNode(n.sons, n.info)
      body.sons.insert(newTree(nkVarSection, n.info, newTree(nkIdentDefs, n.info,
        l.id(n.name, n.info), empty(n.info),
        newTree(nkCall, n.info, maker, l.id(it, n.info)))), 0)
      result.add body
      return
    result.add l.id(n.name, n.info)
    result.add l.expr(n.body)
    ## A handle loop variable keeps its object for the iteration (see `stmt`).
    let ln = NsNode(kind: nsnLocalDecl, name: n.name, typ: n.typ, info: n.info)
    let cls = (if n.typ != nil: l.hoistedLocal(ln) else: "")
    if cls.len > 0:
      l.hoist.names.add (n.name, cls)
      let body = l.stmtsToNode(n.sons, n.info)
      l.hoist.names.setLen(l.hoist.names.len - 1)
      body.sons.insert(l.cacheDecl(n.name, cls, n.info), 0)
      result.add body
    else:
      result.add l.stmtsToNode(n.sons, n.info)
  of nsnYield:
    ## Inside the closure iterator `memberBody` builds: `yield return v` yields,
    ## and `yield break` ends the iteration.
    if n.name == "return":
      result = newTree(nkYieldStmt, n.info, l.expr(n.body))
    else:
      result = newTree(nkReturnStmt, n.info, empty(n.info))
  of nsnSwitch: result = l.switchToNim(n)
  of nsnTry: result = l.tryToNim(n)
  of nsnUsingStmt: result = l.usingToNim(n)
  of nsnLock: result = l.lockToNim(n)
  of nsnReturn:
    result = newNodeI(nkReturnStmt, n.info)
    ## `return 4` from an `int?` member: `some`, as sema chose.
    result.add (if n.body == nil: empty(n.info) else: l.wrappedArg(n.body))
  of nsnBreak:
    ## A `break` that leaves a switch names the switch's block.
    result = newNodeI(nkBreakStmt, n.info)
    result.add (if n.name.len > 0: l.id(n.name, n.info) else: empty(n.info))
  of nsnContinue:
    if n.name.len > 0:
      ## A `for` loop's `continue`, which must still run the step.
      result = newTree(nkBreakStmt, n.info, l.id(n.name, n.info))
    else:
      result = newNodeI(nkContinueStmt, n.info)
      result.add empty(n.info)
  of nsnThrow: result = l.throwToNim(n)
  else:
    ## A lambda's expression body into a `T?` result is `some`, as sema chose.
    result = (if n.argConv != acNone: l.wrappedArg(n) else: l.expr(n))

# --- declaration helpers ----------------------------------------------------

proc selfDefs(l: Lowerer; clsName: string; isException: bool; info: TLineInfo;
              mutable = false): PNode =
  ## `self: ClsName`, as a `ref` for exception classes because those are lowered
  ## as value objects. A struct member that assigns to `this` takes `var self`, since
  ## a struct is a value and the caller's copy is the one that changes.
  result = newNodeI(nkIdentDefs, info)
  result.add l.id("self", info)
  var t = (if isException: newTree(nkRefTy, info, l.clsType(clsName, info))
           else: l.clsType(clsName, info))
  if mutable and l.curClass != nil and l.curClass.classKind == ckStruct:
    t = newTree(nkVarTy, info, t)
  result.add t
  result.add empty(info)

proc isAutoProperty(m: NsNode): bool =
  ## True when either accessor is written `get;` / `set;`, which means the class
  ## needs a generated backing field.
  result = false
  for i in 0 ..< min(m.params.len, 2):
    if m.params[i] != nil and m.params[i].kind == nsnEmpty: return true

# --- enum and delegate declarations -----------------------------------------

proc qualifySiblings(n: NsNode; enumName: string; names: seq[string]) =
  ## In an enum member's value, a bare sibling (`All = Read | Write`) is `E.Read`.
  if n == nil: return
  if n.body != nil and n.body.kind == nsnIdent and n.body.name in names:
    n.body = nsnMember(nsnIdent(enumName, n.body.info), n.body.name, n.body.info)
  else: qualifySiblings(n.body, enumName, names)
  for i in 0 ..< n.sons.len:
    if n.sons[i] != nil and n.sons[i].kind == nsnIdent and n.sons[i].name in names:
      n.sons[i] = nsnMember(nsnIdent(enumName, n.sons[i].info), n.sons[i].name,
                            n.sons[i].info)
    else: qualifySiblings(n.sons[i], enumName, names)

proc lowerEnum(l: Lowerer; n: NsNode; into: var seq[PNode]) =
  ## `enum E : U { A, B = 4 }` is `type E = distinct U`, each member a template
  ## over `typedesc[E]` (so `E.A` reads as in C#) yielding its value, and procs
  ## for the operators and the printing (`nsEnumName`). A member
  ## without a value is the previous one plus one, the first zero, as in C#.
  let info = n.info
  let u = (if n.typ != nil: l.typeToNim(n.typ, info) else: l.id("int32", info))
  let td = newTree(nkTypeDef, info, l.exportedName(n.attrs, n.name, info), empty(info),
                   newTree(nkDistinctTy, info, u))
  into.add newTree(nkTypeSection, info, td)
  var names: seq[string] = @[]
  for f in n.sons: names.add f.name
  var prev = ""
  let table = newNodeI(nkBracket, info)
  for f in n.sons:
    var value: PNode
    if f.body != nil:
      let holder = nsn(nsnExprStmt, f.info)
      holder.body = f.body
      qualifySiblings(holder, n.name, names)
      value = newTree(nkCall, f.info, l.id(n.name, f.info),
        newTree(nkCall, f.info, copyTree(u), l.expr(holder.body)))
    elif prev.len == 0:
      value = newTree(nkCall, f.info, l.id(n.name, f.info), newIntNode(nkIntLit, 0))
    else:
      value = newTree(nkCall, f.info, l.id(n.name, f.info), newTree(nkInfix, f.info,
        l.id("+", f.info), newTree(nkCall, f.info, copyTree(u),
          newTree(nkDotExpr, f.info, l.id(n.name, f.info), l.id(prev, f.info))),
        newIntNode(nkIntLit, 1)))
    let fp = newTree(nkFormalParams, f.info, l.id(n.name, f.info),
      newTree(nkIdentDefs, f.info, l.id("t", f.info),
        newTree(nkBracketExpr, f.info, l.id("typedesc", f.info), l.id(n.name, f.info)),
        empty(f.info)))
    into.add newTree(nkTemplateDef, f.info, l.exportedName(n.attrs, f.name, f.info),
      empty(f.info), empty(f.info), fp, empty(f.info), empty(f.info),
      newTree(nkStmtList, f.info, value))
    table.add newTree(nkTupleConstr, f.info, newStrNode(nkStrLit, f.name),
      newTree(nkCall, f.info, l.id("int64", f.info), newTree(nkCall, f.info,
        copyTree(u), newTree(nkDotExpr, f.info, l.id(n.name, f.info),
                             l.id(f.name, f.info)))))
    prev = f.name
  ## The operators and the printing are ordinary procs, declared with the rest of
  ## the module's routines rather than by a template call: a module of an import
  ## cycle shares its leading declarations only, which a statement would end.
  let e = l.id(n.name, info)
  proc under(x: string): PNode = newTree(nkCall, info, copyTree(u), l.id(x, info))
  proc pair(t: PNode): PNode =
    newTree(nkIdentDefs, info, l.id("a", info), l.id("b", info), t, empty(info))
  proc single(t: PNode): PNode = newTree(nkIdentDefs, info, l.id("a", info), t, empty(info))
  proc op(name: string; ret: PNode; params: seq[PNode]; body: PNode): PNode =
    let fp = newTree(nkFormalParams, info, ret)
    for p in params: fp.add p
    ## Quoted, so the operator reads back when a namespace module is rendered.
    l.mkProc(newTree(nkPostfix, info, l.id("*", info),
                     newTree(nkAccQuoted, info, l.id(name, info))),
             fp, newTree(nkStmtList, info, body), info)
  for cmp in ["==", "<", "<="]:
    into.add op(cmp, l.id("bool", info), @[pair(copyTree(e))],
      newTree(nkInfix, info, l.id(cmp, info), under("a"), under("b")))
  for bit in ["or", "and", "xor"]:
    into.add op(bit, copyTree(e), @[pair(copyTree(e))],
      newTree(nkCall, info, copyTree(e),
        newTree(nkInfix, info, l.id(bit, info), under("a"), under("b"))))
  into.add op("not", copyTree(e), @[single(copyTree(e))],
    newTree(nkCall, info, copyTree(e), newTree(nkPrefix, info, l.id("not", info), under("a"))))
  into.add op("hash", l.id("Hash", info), @[single(copyTree(e))],
    newTree(nkCall, info, l.id("hash", info), under("a")))
  into.add op("$", l.id("string", info), @[single(copyTree(e))],
    newTree(nkCall, info, l.id("nsEnumName", info),
      newTree(nkCall, info, l.id("int64", info), under("a")), table,
      l.id(if n.hasAttribute("Flags"): "true" else: "false", info)))
  ## The members and whether they are flags, for `Enum`'s static members (the
  ## library's `GetValues`, `Parse`, ...) to read through the type.
  proc onType(name: string; ret, body: PNode): PNode =
    l.mkProc(l.exportId(name, info), newTree(nkFormalParams, info, ret,
      newTree(nkIdentDefs, info, l.id("t", info), newTree(nkBracketExpr, info,
        l.id("typedesc", info), copyTree(e)), empty(info))),
      newTree(nkStmtList, info, body), info)
  ## A constant array: reading it costs no allocation (string literals are shared).
  let tableTy = newTree(nkBracketExpr, info, l.id("array", info),
    newIntNode(nkIntLit, table.len),
    newTree(nkTupleConstr, info, l.id("string", info), l.id("int64", info)))
  let tableConst = newTree(nkConstSection, info, newTree(nkConstDef, info,
    l.id("nsTable", info), copyTree(tableTy),
    (if table.len > 0: copyTree(table)
     else: newTree(nkCall, info, l.id("default", info), copyTree(tableTy)))))
  into.add onType("nsEnumMembers", tableTy,
    newTree(nkStmtList, info, tableConst, l.id("nsTable", info)))
  into.add onType("nsEnumIsFlags", l.id("bool", info),
    l.id(if n.hasAttribute("Flags"): "true" else: "false", info))
  let ts = op("ToString", l.id("string", info), @[single(copyTree(e))],
    newTree(nkPrefix, info, l.id("$", info), l.id("a", info)))
  ## A call statement may drop it, as any method's result.
  ts[4] = newTree(nkPragma, info, l.id("discardable", info))
  into.add ts
  let local = (if n.outer.len > 0: n.outer & "+" & n.name else: n.name)
  let full = (if l.curNamespace.len > 0: l.curNamespace & "." & local else: local)
  into.add l.mkProc(l.exportId("nsTypeOf", info),
    newTree(nkFormalParams, info, l.id("Type", info), newTree(nkIdentDefs, info,
      l.id("t", info), newTree(nkBracketExpr, info, l.id("typedesc", info),
                               l.id(n.name, info)), empty(info))),
    newTree(nkStmtList, info, newTree(nkCall, info, l.id("nsTypeNamed", info),
                                      newAtom(nkStrLit, full, info))), info)

proc lowerDelegate(l: Lowerer; n: NsNode): PNode =
  ## `delegate R D(args)` becomes a `{.closure.}` proc type, so both plain
  ## methods and capturing lambdas fit, as C# delegates do.
  let pragma = newNodeI(nkPragma, n.info)
  pragma.add l.id("closure", n.info)
  let procTy = newTree(nkProcTy, n.info,
                       l.formalParams(n.typ, n.params, n.info), pragma)
  let td = newNodeI(nkTypeDef, n.info)
  td.add l.exportedName(n.attrs, n.name, n.info)
  var tps: seq[string] = @[]
  for t in n.typeParams: tps.add t.name
  td.add l.genericParams(tps, n.info)
  td.add procTy
  result = newNodeI(nkTypeSection, n.info)
  result.add td

# --- static members ---------------------------------------------------------

proc staticStorageName(cls, member: string): string =
  ## The module global behind a static field or a static auto-property. The class
  ## is part of the name, so two classes' `count` are two globals.
  "ns" & cls & "_" & member

proc typedescDefs(l: Lowerer; cls: string; info: TLineInfo): PNode =
  ## `nsT: typedesc[C]`, the receiver of a static member, so `C.x` is Nim's dot-call;
  ## named so no parameter of the method's own (`t`) is taken.
  result = newNodeI(nkIdentDefs, info)
  result.add l.id("nsT", info)
  result.add newTree(nkBracketExpr, info, l.id("typedesc", info), l.clsType(cls, info))
  result.add empty(info)

proc lazyStaticCtor(l: Lowerer; n: NsNode): bool =
  ## A class that is not generic with a static constructor: C# runs its static
  ## field initialisers and that constructor on first use (ECMA-334 15.12), so its
  ## statics are reached through `nsStaticCtor_C()`. A native class keeps the
  ## initialiser that runs at start.
  if n == nil or n.typeParams.len > 0 or l.scope.isNative(n.name) or
     l.scope.nativeBased(n.name): return false
  for m in n.sons:
    if m.kind == nsnCtorDecl and m.attrs.isStatic: return true
  false

proc staticStorageRef(l: Lowerer; storage: string; info: TLineInfo;
                      direct = false): PNode =
  ## The storage behind a static member: the global, or for a generic class the
  ## per-instantiation storage proc, `nsC_x[T]()`; behind a static constructor, a
  ## proc that runs it first, `nsStaticRef_nsC_x()`.
  if l.clsTypeParams.len == 0 and not direct and l.lazyStaticCtor(l.curClass):
    return newTree(nkCall, info, l.id("nsStaticRef_" & storage, info))
  if l.clsTypeParams.len == 0: return l.id(storage, info)
  let callee = newTree(nkBracketExpr, info, l.id(storage, info))
  for t in l.clsTypeParams: callee.add l.id(t, info)
  result = newTree(nkCall, info, callee)

proc staticAccessor(l: Lowerer; cls: string; m: NsNode; storage: string;
                    direct = false): PNode =
  ## `template x*(t: typedesc[C]): untyped = nsC_x`: `C.x` reads and writes the
  ## global, so `C.x = 1` and `C.x += 1` need nothing else.
  let fp = newNodeI(nkFormalParams, m.info)
  fp.add l.id("untyped", m.info)
  fp.add l.typedescDefs(cls, m.info)
  result = newNodeI(nkTemplateDef, m.info, 7)
  result[0] = l.exportedName(m.attrs, m.name, m.info)
  for i in 1 .. 5: result[i] = empty(m.info)
  result[2] = l.genericParams(l.clsTypeParams, m.info)
  result[3] = fp
  result[6] = newTree(nkStmtList, m.info, l.staticStorageRef(storage, m.info, direct))

proc genericStaticCtor(n: NsNode): NsNode =
  ## A generic class's static constructor, which each instantiation runs on its
  ## own, or nil.
  if n == nil or n.typeParams.len == 0: return nil
  for m in n.sons:
    if m.kind == nsnCtorDecl and m.attrs.isStatic: return m
  nil

proc staticCtorCall(l: Lowerer; info: TLineInfo): PNode =
  ## `nsStaticCtor_C[T]()`, which runs the instantiation's static constructor the
  ## first time anything of it is used; nil when the class has none to run.
  if l.lazyStaticCtor(l.curClass):
    return newTree(nkCall, info, l.id("nsStaticCtor_" & l.curClass.name, info))
  if genericStaticCtor(l.curClass) == nil: return nil
  let callee = newTree(nkBracketExpr, info, l.id("nsStaticCtor_" & l.curClass.name, info))
  for t in l.clsTypeParams: callee.add l.id(t, info)
  newTree(nkCall, info, callee)

proc emitStaticStorage(l: Lowerer; storage: string; typ: NsNode; init: NsNode;
                       info: TLineInfo; inits: var seq[PNode]; into: var seq[PNode]) =
  ## A static member's storage. C# gives every instantiation of a generic class its
  ## own statics, so there it is a `{.global.}` inside a generic proc, initialised on
  ## first use; otherwise a module global, initialised by the static initialiser.
  if l.clsTypeParams.len == 0:
    into.add newTree(nkVarSection, info, newTree(nkIdentDefs, info, l.id(storage, info),
                                                l.typeToNim(typ, info), empty(info)))
    if init != nil:
      inits.add newTree(nkAsgn, info, l.id(storage, info), l.expr(init))
    if l.lazyStaticCtor(l.curClass):
      ## `proc nsStaticRef_nsC_x(): var T = (nsStaticCtor_C(); nsC_x)`
      let fp = newNodeI(nkFormalParams, info)
      fp.add newTree(nkVarTy, info, l.typeToNim(typ, info))
      into.add l.mkProc(newTree(nkPostfix, info, l.id("*", info),
                                l.id("nsStaticRef_" & storage, info)), fp,
        newTree(nkStmtList, info,
                newTree(nkCall, info, l.id("nsStaticCtor_" & l.curClass.name, info)),
                l.id(storage, info)), info)
    return
  let body = newNodeI(nkStmtList, info)
  let sc = l.staticCtorCall(info)
  if sc != nil: body.add sc
  let gv = newTree(nkPragmaExpr, info, l.id("nsV", info),
                   newTree(nkPragma, info, l.id("global", info)))
  body.add newTree(nkVarSection, info, newTree(nkIdentDefs, info, gv,
                                              l.typeToNim(typ, info), empty(info)))
  if init != nil:
    let gr = newTree(nkPragmaExpr, info, l.id("nsReady", info),
                     newTree(nkPragma, info, l.id("global", info)))
    body.add newTree(nkVarSection, info, newTree(nkIdentDefs, info, gr, empty(info),
                                                l.id("false", info)))
    body.add newTree(nkIfStmt, info, newTree(nkElifBranch, info,
      newTree(nkPrefix, info, l.id("not", info), l.id("nsReady", info)),
      newTree(nkStmtList, info,
              newTree(nkAsgn, info, l.id("nsReady", info), l.id("true", info)),
              newTree(nkAsgn, info, l.id("nsV", info), l.expr(init)))))
  body.add l.id("nsV", info)
  let fp = newNodeI(nkFormalParams, info)
  fp.add newTree(nkVarTy, info, l.typeToNim(typ, info))
  var pl = l
  pl.procTypeParams = l.clsTypeParams
  into.add pl.mkProc(newTree(nkPostfix, info, l.id("*", info), l.id(storage, info)),
                     fp, body, info)

proc lowerStaticField(l: Lowerer; cls: NsNode; m: NsNode; inits: var seq[PNode];
                      into: var seq[PNode]) =
  ## A `static` field is module storage, a `const` one a Nim `const`; both are
  ## reached through an accessor template over the class's `typedesc`. A static
  ## field's initialiser runs in the class's static initialiser.
  let storage = staticStorageName(cls.name, m.name)
  if m.attrs.isConst:
    let defs = newNodeI(nkConstDef, m.info)
    defs.add l.id(storage, m.info)
    defs.add l.typeToNim(m.typ, m.info)
    defs.add l.expr(m.body)
    into.add newTree(nkConstSection, m.info, defs)
    var nl = l
    nl.clsTypeParams = @[]
    ## A constant is no static field: reading it initialises nothing.
    into.add nl.staticAccessor(cls.name, m, storage, direct = true)
    return
  l.emitStaticStorage(storage, m.typ, m.body, m.info, inits, into)
  into.add l.staticAccessor(cls.name, m, storage)

# --- properties -------------------------------------------------------------

proc lowerEventAccessors(l: Lowerer; cls, m: NsNode; isException: bool): seq[PNode] =
  ## `event D E { add { ... } remove { ... } }`: procs `nsAdd_E`/`nsRemove_E` over
  ## the receiver (a `typedesc` for a static event) and the handler, `value`.
  result = @[]
  let recvDefs =
    if m.attrs.isStatic: l.typedescDefs(cls.name, m.info)
    else: l.selfDefs(cls.name, isException, m.info)
  for i, prefix in ["nsAdd_", "nsRemove_"]:
    let fp = newNodeI(nkFormalParams, m.info)
    fp.add empty(m.info)
    fp.add copyTree(recvDefs)
    fp.add newTree(nkIdentDefs, m.info, l.id("value", m.info), l.typeToNim(m.typ, m.info),
                   empty(m.info))
    result.add l.mkProc(l.exportedName(m.attrs, prefix & m.name, m.info), fp,
                        l.stmtSeq(m.params[i]), m.info)

proc propName(l: Lowerer; m: NsNode; suffix: string; attrs = m.attrs): PNode =
  ## A property accessor's proc: `P`/`P=`, or for `T I.P` the name only the
  ## interface table uses, `nsI_P`.
  if m.explicitIface.len > 0: l.id("ns" & m.explicitIface & "_" & m.name & suffix, m.info)
  else: l.exportedName(attrs, m.name & suffix, m.info)

proc lowerProperty(l: Lowerer; cls: NsNode; m: NsNode; isException: bool): seq[PNode] =
  ## A C# property becomes a getter named `P` and a setter named `P=`. An
  ## accessor written `get;`/`set;` reads and writes a generated `PBacking` field.
  result = @[]
  if m.attrs.isEvent: return l.lowerEventAccessors(cls, m, isException)
  let getter = if m.params.len > 0: m.params[0] else: nil
  var setter = if m.params.len > 1: m.params[1] else: nil
  ## A static property is reached through its type, so its receiver is the
  ## `typedesc`, and an auto-property's storage is a module global.
  let isStatic = m.attrs.isStatic
  let backing =
    if isStatic: l.staticStorageRef(staticStorageName(cls.name, m.name & "Backing"), m.info)
    else: newTree(nkDotExpr, m.info, l.id("self", m.info),
                  l.id(m.name & "Backing", m.info))
  let recvDefs =
    if isStatic: l.typedescDefs(cls.name, m.info)
    else: l.selfDefs(cls.name, isException, m.info)
  if getter != nil:
    let gbody =
      if getter.kind == nsnEmpty: copyTree(backing)
      else: l.memberBody(m.typ, getter)
    let gp = newNodeI(nkFormalParams, m.info)
    gp.add l.typeToNim(m.typ, m.info)
    gp.add copyTree(recvDefs)
    result.add l.mkProc(propName(l, m, ""), gp, gbody, m.info)
  if setter == nil and getter != nil and getter.kind == nsnEmpty:
    ## `{ get; }`: its constructors assign it, through a setter only this module
    ## sees (sema rejects any other assignment).
    setter = nsn(nsnEmpty, m.info)
    setter.attrs = NsAttrs(access: aPrivate)
    setter.strVal = "access"
  if setter != nil:
    let sbody =
      if setter.kind == nsnEmpty:
        newTree(nkAsgn, m.info, copyTree(backing), l.id("value", m.info))
      else:
        l.stmtSeq(setter)
    let sp = newNodeI(nkFormalParams, m.info)
    sp.add empty(m.info)
    sp.add (if isStatic: copyTree(recvDefs)
            else: l.selfDefs(cls.name, isException, m.info, mutable = true))
    sp.add l.paramDef(nsnParam("value", m.typ, m.info))
    ## Exported whatever its access (`private set;`), which `sema.nim` checks
    ## (CS0272): Nim looks `P=` up where a generic routine assigning `P` is
    ## instantiated, and a static member is generic (its `typedesc`), so one in
    ## another module assigning a private setter would not find it.
    let sattrs = m.attrs
    var exported = sattrs
    exported.access = aPublic
    result.add l.mkProc(propName(l, m, "=", exported), sp, sbody, m.info)

# --- operators and indexers ---------------------------------------------------

proc nimOperatorName*(cs: string): string =
  ## The Nim proc a C# operator declaration becomes.
  case cs
  of "%": "mod"
  of "&": "and"
  of "|": "or"
  of "^": "xor"
  of "<<": "shl"
  of ">>": "shr"
  of "!", "~": "not"
  else: cs

proc lowerOperator(l: Lowerer; cls, m: NsNode): seq[PNode] =
  ## `operator +` is the Nim proc `+` over the declared operands; `++`/`--` are
  ## `inc`/`dec` over a `var` operand, assigning the operator's result; a
  ## conversion is a `converter` when implicit, a proc a cast calls when explicit.
  result = @[]
  let info = m.info
  let fp = l.formalParams(m.typ, m.params, info)
  let body = prependAll(l.stmtSeq(m.body), l.shadowParams(m.params, m.body, info))
  case m.name
  of "implicit", "explicit":
    result.add l.mkProc(l.exportId(conversionProcName(m), info), fp, body, info,
                        kind = (if m.name == "implicit": nkConverterDef else: nkProcDef))
  of "++", "--":
    let helper = "nsOp" & (if m.name == "++": "Inc_" else: "Dec_") & cls.name
    result.add l.mkProc(l.id(helper, info), fp, body, info)
    let ifp = newNodeI(nkFormalParams, info)
    ifp.add empty(info)
    let pt = (if m.params.len > 0: l.typeToNim(m.params[0].typ, info) else: empty(info))
    ifp.add newTree(nkIdentDefs, info, l.id("x", info), newTree(nkVarTy, info, pt),
                    empty(info))
    let assign = newTree(nkAsgn, info, l.id("x", info),
                         newTree(nkCall, info, l.id(helper, info), l.id("x", info)))
    result.add l.mkProc(l.exportId((if m.name == "++": "inc" else: "dec"), info), ifp,
                        newTree(nkStmtList, info, assign), info)
  elif m.attrs.isChecked:
    result.add l.mkProc(l.exportId(checkedOperatorName(m), info), fp, body, info)
  else:
    result.add l.mkProc(l.exportId(nimOperatorName(m.name), info), fp, body, info)

proc lowerIndexer(l: Lowerer; cls, m: NsNode; isException: bool): seq[PNode] =
  ## `this[...]` is Nim's `[]` and `[]=` over the receiver and the index parameters.
  result = @[]
  let info = m.info
  let getter = (if m.sons.len > 0: m.sons[0] else: nil)
  let setter = (if m.sons.len > 1: m.sons[1] else: nil)
  if getter != nil:
    let fp = newNodeI(nkFormalParams, info)
    fp.add l.typeToNim(m.typ, info)
    fp.add l.selfDefs(cls.name, isException, info)
    for p in m.params: fp.add l.paramDef(p)
    result.add l.mkProc(l.exportedName(m.attrs, "[]", info), fp, l.memberBody(m.typ, getter, m.params),
                        info)
  if setter != nil:
    let fp = newNodeI(nkFormalParams, info)
    fp.add empty(info)
    fp.add l.selfDefs(cls.name, isException, info, mutable = true)
    for p in m.params: fp.add l.paramDef(p)
    fp.add newTree(nkIdentDefs, info, l.id("value", info), l.typeToNim(m.typ, info),
                   empty(info))
    result.add l.mkProc(l.exportedName(m.attrs, "[]=", info), fp, l.stmtSeq(setter),
                        info)

# --- constructors -----------------------------------------------------------

proc lowerInit(l: Lowerer; cls, m: NsNode; isException: bool;
               baseName: string; fieldInits: seq[PNode]): PNode =
  ## `proc initC(self: C, params) = <field initialisers>; <base init>; <body>`.
  ## C# runs the initialisers before the base constructor, and not at all in a
  ## constructor that chains to `this(...)`, whose target runs them.
  let ip = newNodeI(nkFormalParams, m.info)
  ip.add empty(m.info)
  ip.add l.selfDefs(cls.name, isException, m.info, mutable = true)
  for p in m.params: ip.add l.paramDef(p, sink = true)
  let ibody = newNodeI(nkStmtList, m.info)
  let sc = l.staticCtorCall(m.info)
  if sc != nil: ibody.add sc
  if m.initKind != "this":
    for f in fieldInits: ibody.add copyTree(f)
  var initName = ""
  if m.initKind == "base": initName = "init" & baseName
  elif m.initKind == "this": initName = "init" & cls.name
  elif baseName.len > 0: initName = "init" & baseName
  ## `: base(msg)` on an exception base that N# itself does not define sets the
  ## message directly, because there is no `initCatchableError` to call.
  let externalExcBase = isException and baseName.len > 0 and
                        not l.scope.classes.hasKey(baseName) and
                        l.surface.isExceptionType(baseName)
  if externalExcBase:
    ## The library's constructor gives the arguments to `self`: the message, an
    ## inner exception, a parameter's name.
    let icall = newTree(nkCall, m.info, l.id("nsInitException", m.info), l.id("self", m.info))
    let q = l.qualifiedName(baseName, m.info)
    icall.add (if q != nil: q else: l.id(nimTypeName(baseName), m.info))
    for a in m.initArgs: icall.add l.expr(a)
    if l.imports != nil: l.imports.note(namespaceModulePath("System"), "nsInitException")
    ibody.add icall
  elif initName.len > 0:
    let icall = newNodeI(nkCall, m.info)
    icall.add l.id(initName, m.info)
    icall.add l.id("self", m.info)
    for a in m.initArgs: icall.add l.expr(a)
    ibody.add icall
  if m.body != nil:
    for v in l.shadowParams(m.params, m.body, m.info): ibody.add v
    l.addStmts(ibody, m.body.sons, m.info)
  result = l.mkProc(l.exportedName(m.attrs, "init" & cls.name, m.info), ip, ibody,
                    m.info, withPragmas = true)

proc dotnetName(l: Lowerer; cls: NsNode): string =
  ## A type's .NET full name: `Demo.Outer+Inner`.
  let local = (if cls.outer.len > 0: cls.outer & "+" & cls.name else: cls.name)
  (if l.curNamespace.len > 0: l.curNamespace & "." & local else: local)

proc defaultMessage(l: Lowerer; cls: NsNode; info: TLineInfo): PNode =
  ## `result.name = "Demo.E"; result.msg = nsDefaultMessage(result)`: an exception
  ## is named as .NET names its type, which `GetType()` reads, and has the message
  ## .NET's parameterless constructors make until its constructor passes one on.
  if l.imports != nil: l.imports.note(namespaceModulePath("System"), "nsDefaultMessage")
  result = newTree(nkStmtList, info,
    newTree(nkAsgn, info, newTree(nkDotExpr, info, l.id("result", info), l.id("name", info)),
            newAtom(nkStrLit, l.dotnetName(cls), info)),
    newTree(nkAsgn, info, newTree(nkDotExpr, info, l.id("result", info), l.id("msg", info)),
            newTree(nkCall, info, l.id("nsDefaultMessage", info), l.id("result", info))))

proc lowerAllocator(l: Lowerer; cls, m: NsNode; isException: bool): PNode =
  ## `proc newC(params): C = new(result); initC(result, params)`. A struct is a
  ## value, already zero-initialised, so it needs no `new`.
  let ap = newNodeI(nkFormalParams, m.info)
  ap.add (if isException: newTree(nkRefTy, m.info, l.clsType(cls.name, m.info))
          else: l.clsType(cls.name, m.info))
  for p in m.params: ap.add l.paramDef(p, sink = true)
  let abody = newNodeI(nkStmtList, m.info)
  if cls.classKind == ckClass:
    let newCall = newNodeI(nkCall, m.info)
    newCall.add l.id("new", m.info)
    newCall.add l.id("result", m.info)
    abody.add newCall
  if isException: abody.add l.defaultMessage(cls, m.info)
  let fwd = newNodeI(nkCall, m.info)
  fwd.add l.id("init" & cls.name, m.info)
  fwd.add l.id("result", m.info)
  for p in m.params: fwd.add l.id(p.name, m.info)
  abody.add fwd
  result = l.mkProc(l.exportedName(m.attrs, "new" & cls.name, m.info), ap, abody,
                    m.info, withPragmas = true)

# --- interfaces --------------------------------------------------------------
#
# An interface value is a fat pointer: the object, as a `RootRef`, and a static
# table of procs for that object's class. C# lets a class name a base class *and*
# interfaces, which Nim's single inheritance cannot express, so an interface is not a
# base type; it is this pair:
#
#   type
#     nsVT_IRepo[T] = object             # one proc per member, over a `RootRef`,
#       nsReady*: bool                   # and the tables of the interfaces it
#       f0*: proc (self: RootRef, item: T) {.nimcall.}   # extends
#     IRepo[T] = object
#       nsObj*: RootRef
#       nsVt*: ptr nsVT_IRepo[T]
#   proc Add*[T](self: IRepo[T], item: T) = (self.nsVt.f0)(nsCheckNil(self.nsObj), item)
#
# A class that implements `IRepo<int>` gets a lazily filled `nsVT_IRepo[int32]`
# whose entries call its own members, and a `converter` from the class, so a class
# value is accepted wherever the interface is. A plain (non-generic) class has a
# table of its own for every interface it implements, inherited ones included, and
# the conversion takes the object's own class's (`nsVtOf_I`, dispatched once), so
# an entry calls the implementation directly (`procCall`) when every class deriving
# it has tables of its own too; otherwise entries dispatch again.
# A non-generic interface also gets a dispatched `nsAs<I>(RootRef)`, overridden by
# each implementing class, which is how `is`, `as` and casts ask the *dynamic* type.
# An interface value converts to an interface it extends through the pointers its
# table keeps to the class's other tables. A struct is boxed into a `ref` first, as
# C# boxes it.

type
  NsSlot = tuple[m: NsNode, setter: bool, params: seq[string], args: seq[NsNode]]
    ## One table entry: a method or an accessor, and the substitution that turns the
    ## declaring interface's type parameters into the ones it is seen through.

proc ifaceTps(l: Lowerer; iface: string): seq[string] =
  if l.scope.classes.hasKey(iface): l.scope.classes[iface].typeParams else: @[]

proc ifaceBases(l: Lowerer; iface: string): seq[NsNode] =
  ## The interfaces `iface` extends, as types over its own type parameters.
  l.scope.directInterfaceTypes(iface)

proc vtSlots(l: Lowerer; iface: string; params: seq[string];
             args: seq[NsNode]): seq[NsSlot] =
  ## The entries of `iface<args>`'s table, in order: its own members, then the ones
  ## it inherits, one per method and one per property accessor.
  result = @[]
  var sources: seq[tuple[name: string, params: seq[string], args: seq[NsNode]]] =
    @[(name: iface, params: params, args: args)]
  for b in l.ifaceBases(iface):
    let bn = canonicalTypeName(b.name)
    var bargs: seq[NsNode] = @[]
    for a in b.sons: bargs.add substitute(a, params, args)
    sources.add (name: bn, params: l.ifaceTps(bn), args: bargs)
  for src in sources:
    if not l.scope.classes.hasKey(src.name): continue
    let d = l.scope.classes[src.name].decl
    if d == nil: continue
    for m in d.sons:
      if m.attrs.isStatic: continue
      if m.kind == nsnMethodDecl:
        result.add (m: m, setter: false, params: src.params, args: src.args)
      elif m.kind == nsnPropertyDecl:
        if m.params.len > 0 and m.params[0] != nil:
          result.add (m: m, setter: false, params: src.params, args: src.args)
        if m.params.len > 1 and m.params[1] != nil:
          result.add (m: m, setter: true, params: src.params, args: src.args)

proc subType(l: Lowerer; t: NsNode; slot: NsSlot; info: TLineInfo): PNode =
  l.typeToNim(substitute(t, slot.params, slot.args), info)

proc ifaceTypeNim(l: Lowerer; name: string; args: seq[NsNode]; info: TLineInfo): PNode =
  ## `I` or `I[A, B]`.
  result = l.id(name, info)
  if args.len > 0:
    result = newTree(nkBracketExpr, info, result)
    for a in args: result.add l.typeToNim(a, info)

proc vtTypeNim(l: Lowerer; name: string; args: seq[NsNode]; info: TLineInfo): PNode =
  l.ifaceTypeNim("nsVT_" & name, args, info)

proc tpNodes(tps: seq[string]; info: TLineInfo): seq[NsNode] =
  result = @[]
  for t in tps: result.add nsnTypeName(t, info)

proc slotProcTy(l: Lowerer; slot: NsSlot; info: TLineInfo): PNode =
  ## `proc (self: RootRef, params): R {.nimcall.}`
  let fp = newNodeI(nkFormalParams, info)
  let m = slot.m
  if slot.setter: fp.add empty(info)
  else: fp.add l.subType(m.typ, slot, info)
  fp.add l.identDefs("self", l.id("RootRef", info), info)
  if m.kind == nsnMethodDecl:
    for p in m.params: fp.add l.identDefs(p.name, l.subType(p.typ, slot, info), info)
  elif slot.setter:
    fp.add l.identDefs("value", l.subType(m.typ, slot, info), info)
  result = newTree(nkProcTy, info, fp,
                   newTree(nkPragma, info, l.id("nimcall", info)))

proc lowerInterface(l: var Lowerer; n: NsNode; into: var seq[PNode]) =
  let info = n.info
  let tps = l.ifaceTps(n.name)
  let tpArgs = tpNodes(tps, info)
  l.curClass = n
  l.clsTypeParams = tps
  l.procTypeParams = tps
  defer:
    l.clsTypeParams = @[]
    l.procTypeParams = @[]
  let slots = l.vtSlots(n.name, tps, tpArgs)
  let bases = l.ifaceBases(n.name)
  # the table type and the value type
  let vtRec = newNodeI(nkRecList, info)
  vtRec.add l.identDefs("nsReady", l.id("bool", info), info)
  vtRec[0][0] = l.exportId("nsReady", info)
  for k, slot in slots:
    let d = l.identDefs("f" & $k, l.slotProcTy(slot, info), info)
    d[0] = l.exportId("f" & $k, info)
    vtRec.add d
  for j, b in bases:
    let d = l.identDefs("up" & $j, newTree(nkPtrTy, info,
                        l.vtTypeNim(canonicalTypeName(b.name), b.sons, info)), info)
    d[0] = l.exportId("up" & $j, info)
    vtRec.add d
  let vtObj = newTree(nkObjectTy, info, empty(info), empty(info), vtRec)
  let valRec = newNodeI(nkRecList, info)
  let o = l.identDefs("nsObj", l.id("RootRef", info), info)
  o[0] = l.exportId("nsObj", info)
  valRec.add o
  let v = l.identDefs("nsVt", newTree(nkPtrTy, info, l.vtTypeNim(n.name, tpArgs, info)),
                      info)
  v[0] = l.exportId("nsVt", info)
  valRec.add v
  let valObj = newTree(nkObjectTy, info, empty(info), empty(info), valRec)
  let sec = newNodeI(nkTypeSection, info)
  sec.add newTree(nkTypeDef, info, l.exportId("nsVT_" & n.name, info),
                  l.genericParams(tps, info), vtObj)
  sec.add newTree(nkTypeDef, info, l.exportedName(n.attrs, n.name, info),
                  l.genericParams(tps, info), valObj)
  into.add sec
  let selfType = l.ifaceTypeNim(n.name, tpArgs, info)
  let selfDefs = l.identDefs("self", selfType, info)
  # one dispatching proc per slot: `(self.nsVt.fK)(nsCheckNil(self.nsObj), args)`
  for k, slot in slots:
    let m = slot.m
    let fp = newNodeI(nkFormalParams, info)
    if slot.setter: fp.add empty(info)
    else: fp.add l.subType(m.typ, slot, info)
    fp.add copyTree(selfDefs)
    let call = newNodeI(nkCall, info)
    call.add newTree(nkPar, info, newTree(nkDotExpr, info,
                     newTree(nkDotExpr, info, l.id("self", info), l.id("nsVt", info)),
                     l.id("f" & $k, info)))
    call.add newTree(nkCall, info, l.id("nsCheckNilVar", info),
                     newTree(nkDotExpr, info, l.id("self", info), l.id("nsObj", info)))
    if m.kind == nsnMethodDecl:
      for p in m.params:
        fp.add l.identDefs(p.name, l.subType(p.typ, slot, info), info)
        call.add l.id(p.name, info)
    elif slot.setter:
      fp.add l.identDefs("value", l.subType(m.typ, slot, info), info)
      call.add l.id("value", info)
    let name = (if slot.setter: m.name & "=" else: m.name)
    let disp = l.mkProc(l.exportId(name, info), fp, newTree(nkStmtList, info, call), info)
    ## A dispatcher is one indirect call: inlined, an interface call costs no more;
    ## the implementation it reaches records the frame, as in .NET.
    disp[4] = newTree(nkPragma, info, l.id("inline", info))
    ## C# lets a call statement drop a method's result.
    if fp[0].kind != nkEmpty: disp[4].add l.id("discardable", info)
    l.unframed(disp)
    into.add disp
  # default implementations (C# 8): `nsDefault_I_M(self: I, params)`, whose `this`
  # is the interface value, so the members it calls dispatch through the table
  for m in n.sons:
    if m.kind != nsnMethodDecl or m.body == nil or m.attrs.isStatic: continue
    var inner = l
    inner.thisName = "self"
    inner.nilChecks = false
    let fp = newNodeI(nkFormalParams, info)
    fp.add l.typeToNim(m.typ, m.info)
    fp.add copyTree(selfDefs)
    for p in m.params: fp.add l.paramDef(p)
    let pd = l.mkProc(l.exportId("nsDefault_" & n.name & "_" & m.name, m.info), fp,
                      inner.memberBody(m.typ, m.body, m.params), m.info, withPragmas = true)
    l.framed(pd, l.frameOwner(n) & "." & m.name & "(" & l.clrParams(m.params) & ")")
    into.add pd
  # printing
  for nm in ["$", "ToString"]:
    let fp = newNodeI(nkFormalParams, info)
    fp.add l.id("string", info)
    fp.add copyTree(selfDefs)
    into.add l.mkProc(l.exportId(nm, info), fp, newTree(nkStmtList, info,
      newTree(nkPrefix, info, l.id("$", info),
              newTree(nkDotExpr, info, l.id("self", info), l.id("nsObj", info)))), info)
  # the dynamic test, for a non-generic interface
  if tps.len == 0:
    let fp = newNodeI(nkFormalParams, info)
    fp.add l.id(n.name, info)
    fp.add l.identDefs("x", l.id("RootRef", info), info)
    let body = newTree(nkStmtList, info, newTree(nkCall, info, l.id("default", info),
                                                  l.id(n.name, info)))
    let md = l.mkProc(l.exportId("nsAs" & n.name, info), fp, body, info,
                      kind = nkMethodDef)
    md[4] = newTree(nkPragma, info, l.id("base", info))
    into.add md
  # an interface value converts to each interface it extends, through its table
  for j, b in bases:
    let bn = canonicalTypeName(b.name)
    if not l.scope.classes.hasKey(bn): continue
    let fp = newNodeI(nkFormalParams, info)
    fp.add l.ifaceTypeNim(bn, b.sons, info)
    fp.add l.identDefs("x", copyTree(selfType), info)
    let up = newTree(nkIfExpr, info,
      newTree(nkElifExpr, info, newTree(nkCall, info, l.id("isNil", info),
              newTree(nkDotExpr, info, l.id("x", info), l.id("nsVt", info))),
              newNodeI(nkNilLit, info)),
      newTree(nkElseExpr, info, newTree(nkDotExpr, info,
        newTree(nkDotExpr, info, l.id("x", info), l.id("nsVt", info)),
        l.id("up" & $j, info))))
    let make = newTree(nkObjConstr, info, l.ifaceTypeNim(bn, b.sons, info),
      newTree(nkExprColonExpr, info, l.id("nsObj", info),
              newTree(nkDotExpr, info, l.id("x", info), l.id("nsObj", info))),
      newTree(nkExprColonExpr, info, l.id("nsVt", info), up))
    into.add l.mkProc(l.exportId("nsTo_" & mangleType(b), info), fp,
                      newTree(nkStmtList, info, make), info, kind = nkConverterDef)

proc implementerFor(l: Lowerer; cls, m: NsNode; iface, instance: string): string =
  ## The proc a table entry calls: the class's member, or its explicit `I.M` --
  ## for a generic interface, the instantiation's own (`IBox<int>.Get`).
  for c in cls.sons:
    if c.name == m.name and c.explicitIface in [iface, instance]:
      return "ns" & c.explicitIface & "_" & m.name
  m.name

proc lowerImplementations(l: var Lowerer; n: NsNode; isException: bool;
                          into: var seq[PNode]) =
  ## For each interface the class names: a lazily filled table, a converter, and,
  ## for a non-generic interface, the `nsAs<I>` override. A struct is boxed:
  ## `nsBox_S` holds a copy, as C#'s box does.
  let info = n.info
  let nativeDerived = l.scope.nativeBased(n.name) and not l.scope.isNative(n.name)
  let isStruct = n.classKind == ckStruct or nativeDerived
  ## A plain class has a table of its own for each interface it implements, those
  ## it inherits included, and the conversion picks the object's own class's
  ## (`nsVtOf_I`, dispatched once): a call through the interface then reaches the
  ## implementation directly. A generic class (or one with a generic class between
  ## it and a base) keeps its base's tables, whose entries dispatch again.
  let plain = not isStruct and not isException and n.classKind == ckClass and
              l.clsTypeParams.len == 0
  var ifaces = l.scope.directInterfaceTypes(n.name)
  var inherited: seq[string] = @[]
  var mapper = initTable[string, string]()     ## the class that names the interface
  for it in ifaces: mapper[mangleType(it)] = n.name
  if plain:
    let ch = l.scope.chain(n.name)
    for k in 1 ..< ch.len:
      let a = ch[k]
      if l.scope.classes[a].typeParams.len > 0 or l.scope.nativeBased(a): break
      for it in l.scope.directInterfaceTypes(a):
        let key = mangleType(it)
        if not mapper.hasKey(key):
          mapper[key] = a
          inherited.add key
          ifaces.add it
  ## The library interfaces it names that are values (`IComparer<T>`): the library
  ## builds their tables from the class's members; `is`/`as` reach them through it.
  var libVals: seq[NsNode] = @[]
  if l.scope.classes.hasKey(n.name):
    for li in l.scope.classes[n.name].libInterfaces:
      if l.scope.isValueInterface(canonicalTypeName(li.name)): libVals.add li
  if ifaces.len == 0 and libVals.len == 0: return
  ## Every class deriving this one has tables of its own: an entry may call the
  ## implementation without dispatching again.
  var exact = plain
  if exact:
    for d, k in l.scope.classes:
      if d != n.name and n.name in l.scope.chain(d) and k.typeParams.len > 0:
        exact = false
  let boxName = "nsBox_" & n.name
  let boxType = l.ifaceTypeNim(boxName, tpNodes(l.clsTypeParams, info), info)
  let heldType = (if nativeDerived: l.typeToNim(nsnTypeName(n.name, info), info)
                  else: l.clsType(n.name, info))
  if isStruct:
    let rec = newNodeI(nkRecList, info)
    let vd = l.identDefs("v", copyTree(heldType), info)
    vd[0] = l.exportId("v", info)
    rec.add vd
    let obj = newTree(nkObjectTy, info, empty(info),
                      newTree(nkOfInherit, info, l.id("RootObj", info)), rec)
    into.add newTree(nkTypeSection, info, newTree(nkTypeDef, info,
      l.exportId(boxName, info), l.genericParams(l.clsTypeParams, info),
      newTree(nkRefTy, info, obj)))
    # a boxed struct prints as the struct does
    let fp = newNodeI(nkFormalParams, info)
    fp.add l.id("string", info)
    fp.add l.identDefs("self", copyTree(boxType), info)
    into.add l.mkProc(l.exportId("ToString", info), fp, newTree(nkStmtList, info,
      (if nativeDerived: newAtom(nkStrLit, n.name, info)
       else: newTree(nkPrefix, info, l.id("$", info),
                     newTree(nkDotExpr, info, l.id("self", info), l.id("v", info))))), info,
      kind = nkMethodDef)
  let recvType = (if isStruct: copyTree(boxType)
                  elif isException: newTree(nkRefTy, info, l.clsType(n.name, info))
                  else: l.clsType(n.name, info))
  proc getterCall(l: Lowerer; name: string; info: TLineInfo): PNode =
    var head = l.id(name, info)
    if l.clsTypeParams.len > 0:
      head = newTree(nkBracketExpr, info, head)
      for t in l.clsTypeParams: head.add l.id(t, info)
    newTree(nkCall, info, head)
  for it in ifaces:
    let iface = canonicalTypeName(it.name)
    if not l.scope.classes.hasKey(iface): continue
    let args = it.sons
    let tps = l.ifaceTps(iface)
    let getName = "nsVtGet_" & n.name & "_" & mangleType(it)
    # proc nsVtGet_C_I(): ptr nsVT_I = the table, filled on first use
    let fill = newTree(nkObjConstr, info, l.vtTypeNim(iface, args, info))
    fill.add newTree(nkExprColonExpr, info, l.id("nsReady", info), l.id("true", info))
    for k, slot in l.vtSlots(iface, tps, args):
      let m = slot.m
      let pt = l.slotProcTy(slot, info)
      let lam = newNodeI(nkLambda, info, 7)
      for i in 0 .. 6: lam[i] = empty(info)
      lam[3] = copyTree(pt[0])
      lam[4] = copyTree(pt[1])
      let me = (if nativeDerived:
                  newTree(nkCall, info, l.id("nsDeref", info),
                    newTree(nkDotExpr, info, newTree(nkCall, info, copyTree(boxType),
                                                     l.id("self", info)), l.id("v", info)))
                elif isStruct:
                  newTree(nkDotExpr, info, newTree(nkCall, info, copyTree(boxType),
                                                   l.id("self", info)), l.id("v", info))
                else:
                  ## The table is only ever paired with this class's objects, so
                  ## the object is reread as one without a conversion check.
                  newTree(nkCast, info, copyTree(recvType), l.id("self", info)))
      let target = l.implementerFor(n, m, iface, mangleType(it))
      ## The entry's object, read as the class whose member it calls: this one for
      ## a dispatched member (its own override), else the member's declaring class.
      let mapperCls = mapper.getOrDefault(mangleType(it), n.name)
      let mi = l.scope.findMemberInfo(mapperCls, m.name)
      let staticCls = (if l.scope.isDispatched(mapperCls, m.name) or mi.name.len == 0:
                         n.name else: mi.owner)
      var body: PNode
      var implemented = false
      for c in l.scope.chain(n.name):
        for cm in l.scope.classes[c].members:
          if cm.name == m.name and not cm.isStatic: implemented = true
      let usesDefault = m.kind == nsnMethodDecl and m.body != nil and not implemented and
                        target == m.name
      if usesDefault:
        ## Not implemented by the class: the interface's default, given the object
        ## as the interface value.
        let call = newTree(nkCall, info, l.id("nsDefault_" & iface & "_" & m.name, info),
          newTree(nkCall, info, l.id("nsTo_" & mangleType(it), info), me))
        for p in m.params: call.add l.id(p.name, info)
        body = call
      elif slot.setter:
        body = newTree(nkAsgn, info, newTree(nkDotExpr, info, me,
                                             l.memberIdent(m.name, nil, info)),
                       l.id("value", info))
      else:
        let call = newNodeI(nkCall, info)
        call.add l.memberIdent(target, nil, info)
        if staticCls != n.name:
          ## A member the class does not dispatch (one hidden by `new` included): the
          ## one of the class that names the interface.
          call.add newTree(nkCast, info, l.id(staticCls, info), l.id("self", info))
        else:
          call.add me
        if m.kind == nsnMethodDecl:
          for p in m.params: call.add l.id(p.name, info)
        ## This table is paired only with objects of exactly this class: the
        ## member is called as this class's, without dispatching again.
        body = (if exact: newTree(nkCommand, info, l.id("procCall", info), call) else: call)
      lam[6] = newTree(nkStmtList, info, body)
      fill.add newTree(nkExprColonExpr, info, l.id("f" & $k, info), lam)
    for j, b in l.ifaceBases(iface):
      ## The tables of the interfaces this one extends, for upcasts.
      var bt = nsnTypeName(b.name, info)
      for a in b.sons: bt.add substitute(a, tps, args)
      fill.add newTree(nkExprColonExpr, info, l.id("up" & $j, info),
                       l.getterCall("nsVtGet_" & n.name & "_" & mangleType(bt), info))
    let store = "nsStore"
    let getFp = newNodeI(nkFormalParams, info)
    getFp.add newTree(nkPtrTy, info, l.vtTypeNim(iface, args, info))
    let getBody = newTree(nkStmtList, info,
      newTree(nkVarSection, info, newTree(nkIdentDefs, info,
        newTree(nkPragmaExpr, info, l.id(store, info),
                newTree(nkPragma, info, l.id("global", info))),
        l.vtTypeNim(iface, args, info), empty(info))),
      newTree(nkIfStmt, info, newTree(nkElifBranch, info,
        newTree(nkPrefix, info, l.id("not", info),
                newTree(nkDotExpr, info, l.id(store, info), l.id("nsReady", info))),
        newTree(nkStmtList, info, newTree(nkAsgn, info, l.id(store, info), fill)))),
      newTree(nkCall, info, l.id("addr", info), l.id(store, info)))
    ## The table's thunks forward to the implementation, which records the frame:
    ## a lambda takes no `stackTrace` pragma, so they are made with it pushed off.
    into.add newTree(nkPragma, info, l.id("push", info), newTree(nkExprColonExpr, info,
                                                              l.id("stackTrace", info),
                                                              l.id("off", info)))
    into.add l.mkProc(l.exportId(getName, info), getFp, getBody, info)
    into.add newTree(nkPragma, info, l.id("pop", info))
    let getCall = l.getterCall(getName, info)
    let key = mangleType(it)
    if plain:
      ## `nsVtOf_I(x)`: the table of the object's own class, dispatched once.
      var base = mapper[key] == n.name
      for a in l.scope.chain(n.name)[1 .. ^1]:
        for t in l.scope.directInterfaceTypes(a):
          if mangleType(t) == key: base = false
      let vfp = newNodeI(nkFormalParams, info)
      vfp.add newTree(nkPtrTy, info, l.vtTypeNim(iface, args, info))
      vfp.add l.identDefs("x", l.clsType(n.name, info), info)
      let vm = l.mkProc(l.exportId("nsVtOf_" & key, info), vfp,
                        newTree(nkStmtList, info, copyTree(getCall)), info, kind = nkMethodDef)
      if base:
        if vm[4].kind == nkEmpty: vm[4] = newNodeI(nkPragma, info)
        vm[4].add l.id("base", info)
      into.add vm
    if key in inherited: continue
    # converter nsTo_<I>*(x: C): I
    let cfp = newNodeI(nkFormalParams, info)
    cfp.add l.ifaceTypeNim(iface, args, info)
    cfp.add l.identDefs("x", (if isException: newTree(nkRefTy, info, l.clsType(n.name, info))
                              else: copyTree(heldType)), info)
    let objExpr = (if isStruct: newTree(nkObjConstr, info, copyTree(boxType),
                                        newTree(nkExprColonExpr, info, l.id("v", info),
                                                l.id("x", info)))
                   else: l.id("x", info))
    let make = newTree(nkObjConstr, info, l.ifaceTypeNim(iface, args, info),
      newTree(nkExprColonExpr, info, l.id("nsObj", info), objExpr),
      newTree(nkExprColonExpr, info, l.id("nsVt", info),
              (if plain: newTree(nkCall, info, l.id("nsVtOf_" & key, info), l.id("x", info))
               else: copyTree(getCall))))
    var cbody: PNode
    if isStruct:
      cbody = newTree(nkStmtList, info, make)
    else:
      cbody = newTree(nkStmtList, info, newTree(nkIfExpr, info,
        newTree(nkElifExpr, info, newTree(nkCall, info, l.id("isNil", info), l.id("x", info)),
                newTree(nkCall, info, l.id("default", info),
                        l.ifaceTypeNim(iface, args, info))),
        newTree(nkElseExpr, info, make)))
    into.add l.mkProc(l.exportId("nsTo_" & mangleType(it), info), cfp, cbody, info,
                      kind = nkConverterDef)
    # method nsAs<I>*(x: C): I, for the dynamic test of a non-generic interface
    if args.len == 0 and tps.len == 0:
      let afp = newNodeI(nkFormalParams, info)
      afp.add l.id(iface, info)
      afp.add l.identDefs("x", copyTree(recvType), info)
      let abody =
        if isStruct:
          newTree(nkStmtList, info, newTree(nkObjConstr, info, l.id(iface, info),
            newTree(nkExprColonExpr, info, l.id("nsObj", info), l.id("x", info)),
            newTree(nkExprColonExpr, info, l.id("nsVt", info), copyTree(getCall))))
        else:
          newTree(nkStmtList, info, newTree(nkCall, info,
                  l.id("nsTo_" & mangleType(it), info), l.id("x", info)))
      into.add l.mkProc(l.exportId("nsAs" & iface, info), afp, abody, info,
                        kind = nkMethodDef)
  ## method nsVtByKey*(x: C; key: string): pointer -- the dynamic test of a generic
  ## interface: each instantiation's table by its type's name, else the base's.
  if isStruct or isException: return
  let kbody = newNodeI(nkStmtList, info)
  for it in ifaces:
    if it.sons.len == 0 or not l.scope.classes.hasKey(canonicalTypeName(it.name)): continue
    let key = newTree(nkCall, info, l.id("nsKeyOf", info), l.typeToNim(it, info))
    let table = newTree(nkCast, info, l.id("pointer", info),
                        l.getterCall("nsVtGet_" & n.name & "_" & mangleType(it), info))
    kbody.add newTree(nkIfStmt, info, newTree(nkElifBranch, info,
      newTree(nkInfix, info, l.id("==", info), l.id("key", info), key),
      newTree(nkStmtList, info, newTree(nkReturnStmt, info, table))))
  for li in libVals:
    ## `nsKeysOf<I>[C, args](key)`: the library's tables for `I` and what it extends.
    let head = newTree(nkBracketExpr, info, l.id("nsKeysOf" & canonicalTypeName(li.name), info),
                       copyTree(recvType))
    for a in li.sons: head.add l.typeToNim(a, info)
    let ask = newTree(nkCall, info, head, l.id("key", info))
    kbody.add newTree(nkIfStmt, info, newTree(nkElifBranch, info,
      newTree(nkInfix, info, l.id("!=", info), ask, newNodeI(nkNilLit, info)),
      newTree(nkStmtList, info, newTree(nkReturnStmt, info, copyTree(ask)))))
  if kbody.len == 0: return
  let base = (if n.typ != nil and l.scope.classes.hasKey(canonicalTypeName(n.typ.name)):
                l.typeToNim(n.typ, info)
              else: l.id("RootRef", info))
  kbody.add newTree(nkCall, info, l.id("procCall", info), newTree(nkCall, info,
    l.id("nsVtByKey", info), newTree(nkCall, info, base, l.id("x", info)), l.id("key", info)))
  let kfp = newNodeI(nkFormalParams, info)
  kfp.add l.id("pointer", info)
  kfp.add l.identDefs("x", copyTree(recvType), info)
  kfp.add l.identDefs("key", l.id("string", info), info)
  var kl = l
  kl.procTypeParams = l.clsTypeParams
  into.add kl.mkProc(l.exportId("nsVtByKey", info), kfp, kbody, info, kind = nkMethodDef)

proc isIfaceType(l: Lowerer; t: NsNode): bool =
  t != nil and t.kind == nsnTypeName and l.scope.isValueInterface(canonicalTypeName(t.name))

proc isIfaceValue(l: Lowerer; e: NsNode): bool =
  e != nil and e.typeKind == tkClass and l.scope.isValueInterface(e.typeName)

proc objOf(l: Lowerer; e: NsNode): PNode =
  ## The object behind a value: `x.nsObj` for an interface value, `x` otherwise.
  result = l.expr(e)
  if l.isIfaceValue(e):
    result = newTree(nkDotExpr, e.info, result, l.id("nsObj", e.info))

proc ifaceTypeOp(l: Lowerer; n: NsNode): PNode =
  ## `is`, `as` and casts that involve an interface, or `nil` when none does. The
  ## dynamic type answers: `nsAs<I>(obj)` is empty when it does not implement `I`.
  result = nil
  let info = n.info
  if l.isIfaceType(n.typ):
    let iface = canonicalTypeName(n.typ.name)
    let probe =
      if n.typ.sons.len > 0:
        ## A generic interface: the class answers by the instantiation's name.
        newTree(nkCall, info, l.id("nsAsByKey", info), l.id("nsSrc", info),
                l.typeToNim(n.typ, info))
      else: newTree(nkCall, info, l.id("nsAs" & iface, info), l.id("nsSrc", info))
    var value: PNode
    case n.kind
    of nsnIs:
      value = newTree(nkInfix, info, l.id("!=", info),
                      newTree(nkDotExpr, info, probe, l.id("nsObj", info)),
                      newNodeI(nkNilLit, info))
    of nsnAs: value = probe
    else:
      value = newTree(nkCall, info, l.id("nsIfaceCast", info), probe, l.id("nsSrc", info))
    let defs = l.identDefs("nsSrc", empty(info), info)
    defs[2] = newTree(nkCall, info, l.id("RootRef", info), l.objOf(n.body))
    result = newTree(nkBlockExpr, info, empty(info), newTree(nkStmtList, info,
      newTree(nkLetSection, info, defs), value))
  elif l.isIfaceValue(n.body):
    ## From an interface value to a class: the object is tested or converted.
    let obj = l.objOf(n.body)
    let target = canonicalTypeName(if n.typ != nil: n.typ.name else: "")
    let isStruct = l.boxedImpl(target)
    ## The class as Nim names it, with its type arguments: `Bag[int32]`.
    let cls = (if isStruct: l.id("nsBox_" & target, info) else: l.typeToNim(n.typ, info))
    case n.kind
    of nsnIs:
      result = newTree(nkInfix, info, l.id("of", info), obj, cls)
    of nsnCast:
      if isStruct:
        result = newTree(nkDotExpr, info, newTree(nkCall, info, cls, obj), l.id("v", info))
      else:
        result = newTree(nkCall, info, cls, obj)
    of nsnAs:
      if not isStruct:
        ## The object if it is one, else null, reading the operand once.
        let defs = l.identDefs("nsAs", empty(info), info)
        defs[2] = obj
        result = newTree(nkBlockExpr, info, empty(info), newTree(nkStmtList, info,
          newTree(nkLetSection, info, defs),
          newTree(nkIfExpr, info,
            newTree(nkElifExpr, info,
              newTree(nkInfix, info, l.id("of", info), l.id("nsAs", info), cls),
              newTree(nkCall, info, copyTree(cls), l.id("nsAs", info))),
            newTree(nkElseExpr, info, newNodeI(nkNilLit, info)))))
    else: discard

# --- classes ----------------------------------------------------------------

proc alwaysExported(l: Lowerer; name: string; info: TLineInfo): PNode =
  ## The implicit constructor pair is always exported, as in the previous
  ## emitter, regardless of the class's own accessibility.
  result = newTree(nkPostfix, info, l.id("*", info), l.nameNode(name, info))

proc recordState(l: Lowerer; n: NsNode): tuple[shown, compared: seq[string]] =
  ## A record's members as C# sees them: `ToString` shows its public instance
  ## fields and properties, base record first; equality compares its instance
  ## state -- fields and auto-properties, not computed properties.
  result = (@[], @[])
  var chain = l.scope.chain(n.name)
  chain.reverse()
  for c in chain:
    let decl = l.scope.classes[c].decl
    if decl == nil: continue
    for m in decl.sons:
      if m.attrs.isStatic or m.attrs.isConst or m.attrs.isEvent: continue
      case m.kind
      of nsnFieldDecl:
        if m.attrs.access == aPublic: result.shown.add m.name
        result.compared.add m.name
      of nsnPropertyDecl:
        if m.explicitIface.len > 0: continue
        if m.attrs.access == aPublic: result.shown.add m.name
        if m.params.len > 0 and m.params[0] != nil and m.params[0].kind == nsnEmpty:
          result.compared.add m.name
      else: discard

proc recordMembers(l: Lowerer; n: NsNode; isClass: bool; into: var seq[PNode]) =
  ## A record's value semantics: `==` over its state (a class record also equal to
  ## itself, and unequal to null), `Equals`, `hash`, and `nsClone`, which `with`
  ## copies through; a class record's is a `method`, so the copy keeps the
  ## dynamic type.
  let info = n.info
  let st = l.recordState(n)
  let t = l.clsType(n.name, info)
  let a = l.id("a", info)
  let b = l.id("b", info)
  proc pairDefs(): PNode =
    newTree(nkIdentDefs, info, l.id("a", info), l.id("b", info), copyTree(t), empty(info))
  var cond: PNode = l.id("true", info)
  for f in st.compared:
    let eq = newTree(nkInfix, info, l.id("==", info),
                     newTree(nkDotExpr, info, copyTree(a), l.memberIdent(f, nil, info)),
                     newTree(nkDotExpr, info, copyTree(b), l.memberIdent(f, nil, info)))
    cond = newTree(nkInfix, info, l.id("and", info), cond, eq)
  var body: PNode
  if isClass:
    let ident = newTree(nkInfix, info, l.id("==", info),
      newTree(nkCast, info, l.id("pointer", info), copyTree(a)),
      newTree(nkCast, info, l.id("pointer", info), copyTree(b)))
    let anyNil = newTree(nkInfix, info, l.id("or", info),
      newTree(nkCall, info, l.id("isNil", info), copyTree(a)),
      newTree(nkCall, info, l.id("isNil", info), copyTree(b)))
    body = newTree(nkIfExpr, info,
      newTree(nkElifExpr, info, ident, l.id("true", info)),
      newTree(nkElifExpr, info, anyNil, l.id("false", info)),
      newTree(nkElseExpr, info, cond))
  else: body = cond
  if n.attrs.isAnon:
    ## An anonymous type's `==` is the reference comparison; only `Equals`
    ## compares the members.
    into.add l.mkProc(l.alwaysExported("Equals", info),
      newTree(nkFormalParams, info, l.id("bool", info), pairDefs()),
      newTree(nkStmtList, info, body), info, withPragmas = true)
  else:
    into.add l.mkProc(l.alwaysExported("==", info),
      newTree(nkFormalParams, info, l.id("bool", info), pairDefs()),
      newTree(nkStmtList, info, body), info)
    into.add l.mkProc(l.alwaysExported("Equals", info),
      newTree(nkFormalParams, info, l.id("bool", info), pairDefs()),
      newTree(nkStmtList, info, newTree(nkInfix, info, l.id("==", info), copyTree(a),
                                        copyTree(b))), info, withPragmas = true)
  ## `hash`: the members' hashes mixed, so a record can key a dictionary.
  let hbody = newNodeI(nkStmtList, info)
  hbody.add newTree(nkVarSection, info, newTree(nkIdentDefs, info, l.id("h", info),
                                               l.id("Hash", info), newIntNode(nkIntLit, 0)))
  if isClass:
    hbody.add newTree(nkIfStmt, info, newTree(nkElifBranch, info,
      newTree(nkCall, info, l.id("isNil", info), l.id("self", info)),
      newTree(nkReturnStmt, info, newIntNode(nkIntLit, 0))))
  for f in st.compared:
    hbody.add newTree(nkAsgn, info, l.id("h", info), newTree(nkInfix, info, l.id("!&", info),
      l.id("h", info), newTree(nkCall, info, l.id("hash", info),
        newTree(nkDotExpr, info, l.id("self", info), l.memberIdent(f, nil, info)))))
  hbody.add newTree(nkPrefix, info, l.id("!$", info), l.id("h", info))
  into.add l.mkProc(l.alwaysExported("hash", info),
    newTree(nkFormalParams, info, l.id("Hash", info),
            newTree(nkIdentDefs, info, l.id("self", info), copyTree(t), empty(info))),
    hbody, info)
  if isClass:
    let base = l.scope.classes[n.name].base
    let isRoot = base.len == 0 or not l.scope.classes.hasKey(base) or
                 not l.scope.classes[base].decl.attrs.isRecord
    let cbody = newTree(nkStmtList, info,
      newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id("c", info), empty(info),
        newTree(nkCall, info, copyTree(t)))),
      newTree(nkAsgn, info, newTree(nkDerefExpr, info, l.id("c", info)),
              newTree(nkDerefExpr, info, l.id("self", info))),
      l.id("c", info))
    let md = l.mkProc(l.alwaysExported("nsClone", info),
      newTree(nkFormalParams, info, l.id("RootRef", info),
              newTree(nkIdentDefs, info, l.id("self", info), copyTree(t), empty(info))),
      cbody, info, kind = nkMethodDef)
    if isRoot: md[4] = newTree(nkPragma, info, l.id("base", info))
    into.add md

proc fieldText(l: Lowerer; n: NsNode; isClass: bool; selfDefs: PNode): PNode =
  ## `nsFieldText(self)`: the instance fields as `Name: value, ...`, a base class's
  ## first (through its own `nsFieldText`, so its private fields print too). An
  ## auto-property shows under its own name; events, statics and constants not.
  let info = n.info
  let body = newNodeI(nkStmtList, info)
  var start: PNode = newAtom(nkStrLit, "", info)
  ## The base as resolved (`Outer.A`, `M.Animal` and `N.G<int>` included), and
  ## written as the class's own `of` clause writes it.
  let base = l.scope.classes[n.name].base
  if isClass and n.typ != nil and base.len > 0 and l.scope.classes.hasKey(base):
    start = newTree(nkCall, info, l.id("nsFieldText", info),
      newTree(nkCall, info, l.objTypeToNim(n.typ, info), l.id("self", info)))
  body.add newTree(nkAsgn, info, l.id("result", info), start)
  for m in n.sons:
    if m.attrs.isStatic or m.attrs.isConst or m.attrs.isEvent: continue
    var value: PNode = nil
    if m.kind == nsnFieldDecl:
      value = newTree(nkDotExpr, info, l.id("self", info), l.memberIdent(m.name, nil, info))
    elif m.kind == nsnPropertyDecl and m.explicitIface.len == 0 and isAutoProperty(m):
      value = newTree(nkDotExpr, info, l.id("self", info), l.id(m.name & "Backing", info))
    if value != nil:
      body.add newTree(nkCall, info, l.id("nsFieldAdd", info), l.id("result", info),
                       newAtom(nkStrLit, m.name, info), value)
  let fp = newNodeI(nkFormalParams, info)
  fp.add l.id("string", info)
  fp.add copyTree(selfDefs)
  result = l.mkProc(l.alwaysExported("nsFieldText", info), fp, body, info)
  if n.typeParams.len > 0: result[2] = l.genericParams(l.clsTypeParams, info)

proc objectToString(l: Lowerer; n: NsNode; isClass: bool): seq[PNode] =
  ## `ToString()` of a class that does not override it, and inherits no override
  ## from this compilation, prints its fields as Nim prints an object -- not the
  ## type's name, as C#'s `object.ToString()` does (SPEC §7). A class gets a
  ## `method`, a struct a proc, and `$` for both reaches it. A record keeps C#'s
  ## `R { A = 1 }`.
  result = @[]
  var overridden = false
  for c in l.scope.chain(n.name):
    for m in l.scope.classes[c].members:
      ## `ToString()` itself, not an overload such as `ToString(string format)`.
      if m.name == "ToString" and m.isMethod and not m.isStatic and m.params.len == 0:
        overridden = true
  let info = n.info
  let local = (if n.outer.len > 0: n.outer & "+" & n.name else: n.name)
  let full = (if l.curNamespace.len > 0: l.curNamespace & "." & local else: local)
  let selfDefs = newNodeI(nkIdentDefs, info)
  selfDefs.add l.id("self", info)
  selfDefs.add l.clsType(n.name, info)
  selfDefs.add empty(info)
  ## The type's .NET name; of a generic one, `Demo.Box`1[System.Int32]`, from the
  ## arguments' names.
  var typeName = newAtom(nkStrLit, full, info)
  if n.typeParams.len > 0:
    typeName = newTree(nkCall, info, l.id("nsGenericName", info), newAtom(nkStrLit, full, info))
    for t in l.clsTypeParams:
      typeName.add newTree(nkCall, info, l.id("nsDisplay", info),
                           newTree(nkCall, info, l.id("nsTypeOf", info), l.id(t, info)))
  if n.attrs.isRecord:
    ## `R { A = 1, B = x }`: the type's own name and its public members. A record
    ## prints this unless it declares `ToString` itself.
    overridden = false
    for m in n.sons:
      if m.kind == nsnMethodDecl and m.name == "ToString" and not m.attrs.isStatic and
          m.params.len == 0:
        overridden = true
  if not overridden and n.attrs.isRecord:
    let shown = l.recordState(n).shown
    ## An anonymous type prints its members only: `{ A = 1 }`.
    let head = (if n.attrs.isAnon: "" else: n.name & " ")
    var text: PNode = newAtom(nkStrLit, head & (if shown.len > 0: "{ " else: "{"),
                              info)
    for i, f in shown:
      let label = (if i > 0: ", " else: "") & f & " = "
      text = newTree(nkInfix, info, l.id("&", info), text, newAtom(nkStrLit, label, info))
      text = newTree(nkInfix, info, l.id("&", info), text, newTree(nkPrefix, info,
        l.id("$", info), newTree(nkPar, info,
          newTree(nkDotExpr, info, l.id("self", info), l.id(f, info)))))
    text = newTree(nkInfix, info, l.id("&", info), text, newAtom(nkStrLit, " }", info))
    let fp = newNodeI(nkFormalParams, info)
    fp.add l.id("string", info)
    fp.add copyTree(selfDefs)
    result.add l.mkProc(l.alwaysExported("ToString", info), fp,
                        newTree(nkStmtList, info, text), info, withPragmas = true,
                        kind = (if isClass: nkMethodDef else: nkProcDef))
  ## A static class has no instances to print.
  let printsFields = not n.attrs.isRecord and not n.attrs.isStatic
  if printsFields:
    result.add l.fieldText(n, isClass, selfDefs)
  if not overridden and printsFields:
    ## Not C#'s type name: the fields, as Nim prints an object (see `nsObjectText`).
    let fp = newNodeI(nkFormalParams, info)
    fp.add l.id("string", info)
    fp.add copyTree(selfDefs)
    let text = newTree(nkCall, info, l.id("nsObjectText", info), l.id("self", info),
                       newTree(nkCall, info, l.id("nsFieldText", info), l.id("self", info)))
    result.add l.mkProc(l.alwaysExported("ToString", info), fp,
                        newTree(nkStmtList, info, text), info,
                        withPragmas = true, kind = (if isClass: nkMethodDef else: nkProcDef))
  ## `typeof(C)` and, for a class, the dynamic type `GetType()` reads.
  if n.typeParams.len > 0:
    ## Built from the arguments' types, which say their assemblies (`FullName`).
    let call = newTree(nkCall, info, l.id("nsGenericType", info), newAtom(nkStrLit, full, info),
                       newAtom(nkStrLit, "", info))
    for t in l.clsTypeParams:
      call.add newTree(nkCall, info, l.id("nsTypeOf", info), l.id(t, info))
    let pd = l.mkProc(l.alwaysExported("nsTypeOf", info),
      newTree(nkFormalParams, info, l.id("Type", info), newTree(nkIdentDefs, info,
        l.id("t", info), newTree(nkBracketExpr, info, l.id("typedesc", info),
                                 l.clsType(n.name, info)), empty(info))),
      newTree(nkStmtList, info, call), info)
    pd[2] = l.genericParams(l.clsTypeParams, info)
    result.add pd
    if isClass:
      ## `GetType()` of an instance: the constructed type, its arguments' too.
      result.add l.mkProc(l.alwaysExported("nsDynType", info),
        newTree(nkFormalParams, info, l.id("Type", info), copyTree(selfDefs)),
        newTree(nkStmtList, info, newTree(nkCall, info, l.id("nsTypeOf", info),
          newTree(nkCall, info, l.id("typeof", info), l.id("self", info)))), info,
        kind = nkMethodDef)
  else:
    result.add l.mkProc(l.alwaysExported("nsTypeOf", info),
      newTree(nkFormalParams, info, l.id("Type", info), newTree(nkIdentDefs, info,
        l.id("t", info), newTree(nkBracketExpr, info, l.id("typedesc", info),
                                 l.clsType(n.name, info)), empty(info))),
      newTree(nkStmtList, info, newTree(nkCall, info, l.id("nsTypeNamed", info),
                                        newAtom(nkStrLit, full, info))), info)
  if isClass:
    result.add l.mkProc(l.alwaysExported("nsTypeName", info),
      newTree(nkFormalParams, info, l.id("string", info), copyTree(selfDefs)),
      newTree(nkStmtList, info, copyTree(typeName)), info, kind = nkMethodDef)
  if not isClass:
    ## `$` for a struct: the class form is the intrinsics' generic one.
    let fp = newNodeI(nkFormalParams, info)
    fp.add l.id("string", info)
    fp.add copyTree(selfDefs)
    let call = newTree(nkCall, info, l.id("ToString", info), l.id("self", info))
    result.add l.mkProc(l.alwaysExported("$", info), fp, newTree(nkStmtList, info, call),
                        info)

proc exceptionTypeName(l: Lowerer; n: NsNode): seq[PNode] =
  ## `typeof(E)` of an exception class. The dynamic type `GetType()` reads is its
  ## `name`, which its allocator sets (see `defaultMessage`); its `ToString` and
  ## `Message` are the library's, from the exception root.
  let info = n.info
  let full = l.dotnetName(n)
  result = @[]
  result.add l.mkProc(l.alwaysExported("nsTypeOf", info),
    newTree(nkFormalParams, info, l.id("Type", info), newTree(nkIdentDefs, info,
      l.id("t", info), newTree(nkBracketExpr, info, l.id("typedesc", info),
        newTree(nkRefTy, info, l.clsType(n.name, info))), empty(info))),
    newTree(nkStmtList, info, newTree(nkCall, info, l.id("nsTypeNamed", info),
                                      newAtom(nkStrLit, full, info))), info)

# --- P/Invoke -------------------------------------------------------------------
#
# A `[DllImport]` method is two procs: the C function, `importc` over C's own types
# with the C calling convention -- loaded from its library at start-up, or linked in
# for `"__Internal"` -- and the C# method, which marshals its arguments as .NET does
# by default (`NsMarshal`) and calls it. A struct crosses as `nsC_<S>`, a C struct of
# its fields in order, which `nsToC`/`nsFromC` copy to and from: an N# struct is a
# Nim `object of RootObj`, whose type header C does not expect.

type NsDllImport = tuple[lib, entry: string; stdcall: bool]

proc dllImportOf(m: NsNode): NsDllImport =
  ## `[DllImport("lib", EntryPoint = "name", CallingConvention = ...)]`.
  result = (lib: "", entry: m.name, stdcall: false)
  let a = m.attributeNamed("DllImport")
  if a == nil: return
  for x in a.sons:
    if x.kind == nsnStrLit: result.lib = x.strVal
    elif x.kind == nsnNamedArg and x.body != nil:
      if x.name == "EntryPoint" and x.body.kind == nsnStrLit: result.entry = x.body.strVal
      elif x.name == "CallingConvention" and x.body.kind == nsnMember:
        result.stdcall = x.body.name in ["StdCall", "Winapi"]

proc marshalAsByte(attrs: seq[NsNode]; onReturn: bool): bool

proc cTypeOf(l: Lowerer; t: NsNode; byteBool: bool; info: TLineInfo): PNode =
  ## The C side of a marshalled type.
  case l.scope.marshalOf(t)
  of mkVoid: empty(info)
  of mkBool: l.id((if byteBool: "uint8" else: "int32"), info)
  of mkString: l.id("cstring", info)
  of mkStruct: l.id(cMirrorName(t.name), info)
  of mkArray: newTree(nkPtrTy, info, l.typeToNim(t.typ, info))
  of mkEnum: newTree(nkCall, info, l.id("nsEnumBase", info), l.typeToNim(t, info))
  of mkBlittable, mkUnsupported: l.typeToNim(t, info)

proc toC(l: Lowerer; t: NsNode; v: PNode; byteBool: bool; info: TLineInfo): PNode =
  ## An N# value as its C side.
  case l.scope.marshalOf(t)
  of mkBool:
    newTree(nkCall, info, l.id((if byteBool: "uint8" else: "int32"), info),
            newTree(nkCall, info, l.id("ord", info), v))
  of mkString: newTree(nkCall, info, l.id("cstring", info), v)
  of mkStruct: newTree(nkCall, info, l.id("nsToC", info), v)
  of mkArray: newTree(nkCall, info, l.id("nsArrayAddr", info), v)
  of mkEnum: newTree(nkCall, info, l.cTypeOf(t, false, info), v)
  else: v

proc fromC(l: Lowerer; t: NsNode; v: PNode; info: TLineInfo): PNode =
  ## A C value as its N# type.
  case l.scope.marshalOf(t)
  of mkBool: newTree(nkInfix, info, l.id("!=", info), v, newAtom(nkIntLit, 0, info))
  of mkString: newTree(nkPrefix, info, l.id("$", info), v)
  of mkStruct: newTree(nkCall, info, l.id("nsFromC", info), v)
  of mkEnum: newTree(nkCall, info, l.typeToNim(t, info), v)
  else: v

proc cStructMirror(l: Lowerer; n: NsNode; into: var seq[PNode]) =
  ## `nsC_<S>`, the C struct of a marshalable struct's fields, and the copies to
  ## and from it.
  let info = n.info
  let packed = block:
    var p = false
    let a = n.attributeNamed("StructLayout")
    if a != nil:
      for x in a.sons:
        if x.kind == nsnNamedArg and x.name == "Pack" and x.body != nil and
           x.body.kind == nsnIntLit and x.body.intVal == 1: p = true
    p
  let rec = newNodeI(nkRecList, info)
  let toBody = newNodeI(nkObjConstr, info)
  toBody.add l.id(cMirrorName(n.name), info)
  let fromBody = newNodeI(nkStmtList, info)
  for f in l.scope.structFields(n.name):
    let field = (if f.kind == nsnPropertyDecl: f.name & "Backing" else: f.name)
    let byteBool = marshalAsByte(f.attributes, false)
    rec.add l.identDefs(field, l.cTypeOf(f.typ, byteBool, f.info), f.info)
    rec[^1][0] = l.exportId(field, f.info)
    toBody.add newTree(nkExprColonExpr, info, l.id(field, info),
      l.toC(f.typ, newTree(nkDotExpr, info, l.id("s", info), l.id(field, info)), byteBool, info))
    fromBody.add newTree(nkAsgn, info,
      newTree(nkDotExpr, info, l.id("result", info), l.id(field, info)),
      l.fromC(f.typ, newTree(nkDotExpr, info, l.id("c", info), l.id(field, info)), info))
  let prag = newTree(nkPragma, info, l.id("bycopy", info))
  if packed: prag.add l.id("packed", info)
  into.add newTree(nkTypeSection, info, newTree(nkTypeDef, info,
    newTree(nkPragmaExpr, info, l.exportId(cMirrorName(n.name), info), prag),
    empty(info), newTree(nkObjectTy, info, empty(info), empty(info), rec)))
  let toFp = newTree(nkFormalParams, info, l.id(cMirrorName(n.name), info),
                     l.identDefs("s", l.id(n.name, info), info))
  let toProc = l.mkProc(l.exportId("nsToC", info), toFp,
                        newTree(nkStmtList, info, toBody), info)
  toProc[4] = newTree(nkPragma, info, l.id("inline", info))
  into.add toProc
  let fromFp = newTree(nkFormalParams, info, l.id(n.name, info),
                       l.identDefs("c", l.id(cMirrorName(n.name), info), info))
  let fromProc = l.mkProc(l.exportId("nsFromC", info), fromFp, fromBody, info)
  fromProc[4] = newTree(nkPragma, info, l.id("inline", info))
  into.add fromProc

proc marshalAsByte(attrs: seq[NsNode]; onReturn: bool): bool =
  ## `[MarshalAs(UnmanagedType.U1)]` (or `I1`): a `bool` as one byte, not a BOOL;
  ## `onReturn` reads `[return: MarshalAs(...)]`.
  for a in attrs:
    if (a.strVal == "return") == onReturn and
       a.name.split('.')[^1] in ["MarshalAs", "MarshalAsAttribute"]:
      for x in a.sons:
        if x.kind == nsnMember and x.name in ["U1", "I1"]: return true
  false

proc unmanagedEntry(l: Lowerer; cls, m: NsNode): PNode =
  ## `[UnmanagedCallersOnly] static R M(args)`: `nsUC_<C>_<M>`, the C function `&M`
  ## gives (exported under `EntryPoint` when one is named), which calls `M`. An
  ## exception cannot unwind through C's frames, so one leaving `M` ends the program
  ## as .NET's does.
  let info = m.info
  var entry = ""
  for x in m.attributeNamed("UnmanagedCallersOnly").sons:
    if x.kind == nsnNamedArg and x.name == "EntryPoint" and x.body != nil and
       x.body.kind == nsnStrLit: entry = x.body.strVal
  let params = l.formalParams(m.typ, m.params, info)
  let call = newTree(nkCall, info, l.id(m.name, info), l.id(cls.name, info))
  for p in m.params: call.add l.id(p.name, info)
  let isVoid = m.typ == nil or m.typ.kind in {nsnVoidType, nsnEmpty}
  let run = (if isVoid: call else: newTree(nkAsgn, info, l.id("result", info), call))
  let body = newTree(nkStmtList, info, newTree(nkTryStmt, info,
    newTree(nkStmtList, info, run),
    newTree(nkExceptBranch, info,
      newTree(nkInfix, info, l.id("as", info), l.id("Exception", info), l.id("nsE", info)),
      newTree(nkStmtList, info, newTree(nkCall, info, l.id("nsCallbackEscape", info),
                                        l.id("nsE", info))))))
  result = l.mkProc(l.exportId(unmanagedEntryName(cls.name, m.name), info), params, body, info)
  result[4] = newTree(nkPragma, info, l.id("cdecl", info))
  if entry.len > 0:
    result[4].add newTree(nkExprColonExpr, info, l.id("exportc", info), newStrNode(nkStrLit, entry))

proc pinvokeMethod(l: var Lowerer; cls, m: NsNode; into: var seq[PNode]) =
  ## `[DllImport] static extern R M(args)`: `nsPI_<C>_<M>`, the C function, and
  ## `M(C, args)`, which marshals. A function linked in (`"__Internal"`) is declared
  ## under a name of its own, which an assembler label binds to the C symbol, so no
  ## other declaration of it (a header's, another method's) conflicts; one of a
  ## library is looked up when first called and called through a pointer.
  let info = m.info
  let imp = dllImportOf(m)
  let rawName = "nsPI_" & cls.name & "_" & m.name
  let callConv = l.id((if imp.stdcall: "stdcall" else: "cdecl"), info)
  let rfp = newNodeI(nkFormalParams, info)
  rfp.add l.cTypeOf(m.typ, marshalAsByte(m.attributes, true), info)
  for p in m.params:
    var t = l.cTypeOf(p.typ, marshalAsByte(p.attributes, false), p.info)
    if p.paramMod in ["ref", "out"]: t = newTree(nkVarTy, p.info, t)
    rfp.add l.identDefs(p.name, t, p.info)
  if imp.lib.len == 0 or imp.lib == "__Internal":
    inc l.pinvokeLinked
    let raw = l.mkProc(l.id(rawName, info), rfp, empty(info), info)
    ## `N_CDECL(R, name)(params) __asm__("entry")`: the convention, then the label
    ## (GCC and Clang; MSVC has none).
    let decl = (if imp.stdcall: "N_STDCALL" else: "N_CDECL") & "($1, $2)$3 __asm__(NS_ASMNAME(\"" &
               imp.entry & "\"))"
    raw[4] = newTree(nkPragma, info,
      newTree(nkExprColonExpr, info, l.id("importc", info),
              newStrNode(nkStrLit, rawName & "_" & $l.pinvokeLinked)),
      callConv,
      newTree(nkExprColonExpr, info, l.id("codegenDecl", info), newStrNode(nkStrLit, decl)))
    into.add raw
  else:
    l.pinvokeLoaded = true
    ## `var f {.global.}: pointer; if f == nil: f = nsPInvokeEntry(lib, entry);
    ## cast[proc (...) {.cdecl.}](f)(args)`
    let fnTy = newTree(nkProcTy, info, copyTree(rfp), newTree(nkPragma, info, copyTree(callConv)))
    let body = newNodeI(nkStmtList, info)
    body.add newTree(nkVarSection, info, newTree(nkIdentDefs, info,
      newTree(nkPragmaExpr, info, l.id("nsEntry", info),
              newTree(nkPragma, info, l.id("global", info))),
      l.id("pointer", info), empty(info)))
    body.add newTree(nkIfStmt, info, newTree(nkElifBranch, info,
      newTree(nkInfix, info, l.id("==", info), l.id("nsEntry", info), newNodeI(nkNilLit, info)),
      newTree(nkAsgn, info, l.id("nsEntry", info),
              newTree(nkCall, info, l.id("nsPInvokeEntry", info),
                      newStrNode(nkStrLit, imp.lib), newStrNode(nkStrLit, imp.entry)))))
    let call = newTree(nkCall, info, newTree(nkCast, info, fnTy, l.id("nsEntry", info)))
    for p in m.params: call.add l.id(p.name, p.info)
    body.add call
    into.add l.mkProc(l.id(rawName, info), copyTree(rfp), body, info)
  ## The C# method: each argument as C takes it; a `ref`/`out` one that C sees
  ## differently (a BOOL, a C struct, an enum) through a copy, copied back after.
  let body = newNodeI(nkStmtList, info)
  let call = newTree(nkCall, info, l.id(rawName, info))
  var copyBack: seq[PNode] = @[]
  for p in m.params:
    let byteBool = marshalAsByte(p.attributes, false)
    let mk = l.scope.marshalOf(p.typ)
    if p.paramMod in ["ref", "out"] and mk in {mkBool, mkStruct, mkEnum}:
      let tmp = "nsPA_" & p.name
      let init = (if p.paramMod == "out": newTree(nkCall, info, l.id("default", info),
                                                  l.cTypeOf(p.typ, byteBool, info))
                  else: l.toC(p.typ, l.id(p.name, info), byteBool, info))
      body.add newTree(nkVarSection, info, newTree(nkIdentDefs, info, l.id(tmp, info),
                                                   empty(info), init))
      call.add l.id(tmp, info)
      copyBack.add newTree(nkAsgn, info, l.id(p.name, info),
                           l.fromC(p.typ, l.id(tmp, info), info))
    else:
      call.add l.toC(p.typ, l.id(p.name, info), byteBool, info)
  if l.scope.marshalOf(m.typ) == mkVoid:
    body.add call
    for c in copyBack: body.add c
  else:
    body.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id("nsPR", info),
                                                 empty(info), call))
    for c in copyBack: body.add c
    body.add newTree(nkAsgn, info, l.id("result", info), l.fromC(m.typ, l.id("nsPR", info), info))
  var params = l.formalParams(m.typ, m.params, info)
  let np = newNodeI(nkFormalParams, info)
  np.add params[0]
  np.add l.typedescDefs(cls.name, info)
  for i in 1 ..< params.len: np.add params[i]
  into.add l.mkProc(l.exportedName(m.attrs, m.name, info), np, body, info, withPragmas = true)

# --- native C++ types ----------------------------------------------------------
#
# A `[Native]` type is the C++ type it names: a Nim `importcpp` object, whose
# `extern` members are `importcpp` procs. A handle class (`Handle = ...`) also
# gets its handle type, `NsH_<Class>[T]`, which every variable of it, or of a
# class deriving it, holds. An N# class deriving a native one is a C++ struct
# deriving it: its methods are C++ member functions (`{.member.}`), and those
# overriding a native `virtual` are C++ overrides (`{.virtual.}`).

proc strLit(s: string; info: TLineInfo): PNode =
  result = newStrNode(nkStrLit, s)
  result.info = info

proc cppPragma(l: Lowerer; pattern, header: string; info: TLineInfo;
               extra: openArray[string] = []): PNode =
  ## `{.importcpp: "pattern", header: "h.hpp", extra.}`
  result = newNodeI(nkPragma, info)
  result.add newTree(nkExprColonExpr, info, l.id("importcpp", info), strLit(pattern, info))
  if header.len > 0:
    result.add newTree(nkExprColonExpr, info, l.id("header", info), strLit(header, info))
  for e in extra: result.add l.id(e, info)

proc nativeHeader(l: Lowerer; cls: string): string =
  ## The header a native type is declared in: its own, or its nearest native base's.
  for c in l.scope.chain(cls):
    if l.scope.classes[c].native.header.len > 0: return l.scope.classes[c].native.header
  ""

proc isHandleConstrained(l: Lowerer; m: NsNode; tp: string): bool =
  ## `where T : Component` with `Component` a handle class: `T` is a handle, and
  ## the C++ template takes the class it handles.
  for w in m.constraints:
    if w.name == tp:
      for c in w.sons:
        if c.kind == nsnTypeName and l.scope.classes.hasKey(c.name) and
           l.scope.handleRoot(c.name).len > 0:
          return true
  false

proc nativeParamType(l: Lowerer; t: NsNode; info: TLineInfo): PNode =
  ## A C# `string` reaches C++ as `const char*`.
  if t != nil and t.kind == nsnTypeName and canonicalTypeName(t.name) == "string":
    return l.id("cstring", info)
  if t != nil and t.kind == nsnTypeName and l.scope.classes.hasKey(canonicalTypeName(t.name)) and
     l.scope.ownedFamily(canonicalTypeName(t.name)):
    ## An N# reference reaches C++ as whatever the parameter is: `X*` or `X&`.
    return newTree(nkBracketExpr, info, l.id("NsPass", info),
                   l.id(l.scope.handleRoot(canonicalTypeName(t.name)), info))
  l.typeToNim(t, info)

proc returnAttr(m: NsNode; name: string): bool =
  ## `[return: name]` on a member.
  for a in m.attributes:
    if a.strVal == "return" and a.name.split('.')[^1] in [name, name & "Attribute"]:
      return true
  false

proc shiftTypeRefs(pattern: string): string =
  ## An `importcpp` pattern with each `'k` (`'*k`, `'**k`) naming the next argument,
  ## for a proc that gains a parameter in front.
  result = ""
  var i = 0
  while i < pattern.len:
    if pattern[i] == '\'' and i + 1 < pattern.len:
      var j = i + 1
      while j < pattern.len and pattern[j] == '*': inc j
      var k = j
      while k < pattern.len and pattern[k] in {'0'..'9'}: inc k
      if k > j:
        let n = parseInt(pattern[j ..< k])
        result.add pattern[i ..< j] & $(if n >= 1: n + 1 else: n)
        i = k
        continue
    result.add pattern[i]
    inc i

proc returnAttrNode(m: NsNode; name: string): NsNode =
  ## The `[return: name(...)]` attribute of a member, or nil.
  for a in m.attributes:
    if a.strVal == "return" and a.name.split('.')[^1] in [name, name & "Attribute"]:
      return a
  nil

proc stringReturn(l: Lowerer; m: NsNode; raw: PNode; pattern, header: string): PNode =
  ## An `extern` returning `string`: `nsRaw_M`, the C++ call, copies the C string it
  ## gives into the N# result within the same C++ expression (a temporary it points
  ## into is still alive), and `M` returns it. The characters are the result itself
  ## (`const char*`), or what `[return: CString("#.c_str()", Length = "#.size()")]`
  ## reaches from it.
  let info = m.info
  let fp = raw[3]
  var args: seq[PNode] = @[]
  for i in 1 ..< fp.len:
    for k in 0 ..< fp[i].len - 2: args.add l.id(fp[i][k].ident.s, info)
  let wrapper = newNodeI(nkProcDef, info, 7)
  wrapper[0] = raw[0]
  wrapper[1] = empty(info)
  wrapper[2] = copyTree(raw[2])
  wrapper[3] = copyTree(fp)
  wrapper[3][0] = l.id("string", info)
  wrapper[4] = newTree(nkPragma, info, l.id("discardable", info))
  wrapper[5] = empty(info)
  let rawName = "nsRaw_" & m.name
  raw[0] = l.id(rawName, info)
  fp[0] = empty(info)
  fp.sons.insert(l.identDefs("nsDest", newTree(nkPtrTy, info, l.id("string", info)), info), 1)
  let call = shiftTypeRefs(pattern)
  var wrapped = "nsSetStr(#, " & call & ")"
  let cs = (if m.kind == nsnMethodDecl: returnAttrNode(m, "CString") else: nil)
  if cs != nil:
    var reach, length = ""
    for x in cs.sons:
      if x.kind == nsnStrLit: reach = x.strVal
      elif x.kind == nsnNamedArg and x.name == "Length" and x.body != nil and
           x.body.kind == nsnStrLit:
        length = x.body.strVal
    wrapped = "nsSetStrVia(#, " & call & ", [&](auto&& nsv) { return " &
              reach.replace("#", "nsv") & "; }" &
              (if length.len > 0: ", [&](auto&& nsv) { return " & length.replace("#", "nsv") & "; }"
               else: "") & ")"
  ## The binding's own header is included by its types; this one is the helpers'.
  raw[4] = l.cppPragma(wrapped, "pure/nsharp/nsobj.hpp", info)
  let c = newTree(nkCall, info, l.id(rawName, info),
                  newTree(nkCall, info, l.id("addr", info), l.id("result", info)))
  for a in args: c.add a
  wrapper[6] = newTree(nkStmtList, info, c)
  result = newTree(nkStmtList, info, raw, wrapper)

proc cstringParams(l: Lowerer; m: NsNode; raw: PNode): PNode =
  ## An `extern` with `[CString("pattern")] string` parameters: `raw`, the C++ call,
  ## becomes `nsRawArgs_M`, taking each such argument's characters and length,
  ## and builds the C++ argument from them where it stands, in an immediately
  ## called lambda (`#` the characters, `#len` the length), so it lives exactly as
  ## long as the call. `raw`'s name then belongs to a wrapper passing them.
  var conv: seq[(string, string)] = @[]        ## parameter name, its pattern
  for p in m.params:
    if p == nil: continue
    let a = p.attributeNamed("CString")
    if a == nil: continue
    for x in a.sons:
      if x.kind == nsnStrLit: conv.add (p.name, x.strVal)
  if conv.len == 0: return raw
  let info = m.info
  let fp = raw[3]
  proc convOf(name: string): string =
    for (n, pat) in conv:
      if n == name: return pat
    ""
  ## Each argument slot of the C++ call, in order: (name, is a typedesc).
  var slots: seq[(string, bool)] = @[]
  for i in 1 ..< fp.len:
    let t = fp[i][^2]
    let td = t.kind == nkBracketExpr and t[0].kind == nkIdent and t[0].ident.s == "typedesc"
    for k in 0 ..< fp[i].len - 2: slots.add (fp[i][k].ident.s, td)
  proc argText(name: string): string =
    let pat = convOf(name)
    if pat.len == 0: return "#"
    "[&](const char* nsp, long long nsn) { return " &
      pat.replace("#len", "nsn").replace("#", "nsp") & "; }(#, #)"
  var pattern = ""
  for x in raw[4]:
    if x.kind == nkExprColonExpr and x[0].kind == nkIdent and x[0].ident.s == "importcpp":
      pattern = x[1].strVal
  ## The C++ call's parameters: the values in order (each such string followed by
  ## its length), then the `typedesc`s, which a `#` cannot stand for but `'k`
  ## still names -- renumbered to where they now are.
  var order: seq[string] = @[]                 ## new parameter list, by name
  var defs: seq[PNode] = @[]
  for (nm, td) in slots:
    if td: continue
    for i in 1 ..< fp.len:
      if fp[i][0].ident.s == nm:
        let d = copyTree(fp[i])
        if convOf(nm).len > 0:
          d[^2] = l.id("cstring", info)
          defs.add d
          defs.add l.identDefs("nsLen_" & nm, l.id("int64", info), info)
          order.add nm
          order.add "nsLen_" & nm
        else:
          defs.add d
          order.add nm
  for (nm, td) in slots:
    if not td: continue
    for i in 1 ..< fp.len:
      if fp[i][0].ident.s == nm: defs.add copyTree(fp[i])
    order.add nm
  proc newIndex(old: int): int =
    ## `'k` names the k-th parameter (1-based); where that one is now.
    if old < 1 or old > slots.len: return old
    order.find(slots[old - 1][0]) + 1
  var values: seq[string] = @[]
  for (nm, td) in slots:
    if not td: values.add nm
  var outp = ""
  var idx = 0
  var i = 0
  while i < pattern.len:
    let c = pattern[i]
    if c == '#' and idx < values.len:
      outp.add argText(values[idx])
      inc idx
    elif c == '@':
      var items: seq[string] = @[]
      while idx < values.len:
        items.add argText(values[idx])
        inc idx
      outp.add items.join(", ")
    elif c == '\'' and i + 1 < pattern.len and pattern[i + 1] in {'*', '0'..'9'}:
      var j = i + 1
      while j < pattern.len and pattern[j] == '*': inc j
      var k = j
      while k < pattern.len and pattern[k] in {'0'..'9'}: inc k
      if k > j:
        outp.add pattern[i ..< j] & $newIndex(parseInt(pattern[j ..< k]))
        i = k
        continue
      outp.add c
    else:
      outp.add c
    inc i
  let nfp = newTree(nkFormalParams, info, copyTree(fp[0]))
  for d in defs: nfp.add d
  let inner = newNodeI(nkProcDef, info, 7)
  inner[0] = l.id("nsRawArgs_" & m.name, info)
  inner[1] = empty(info)
  inner[2] = copyTree(raw[2])
  inner[3] = nfp
  inner[4] = copyTree(raw[4])
  for k in 0 ..< inner[4].len:
    let x = inner[4][k]
    if x.kind == nkExprColonExpr and x[0].kind == nkIdent and x[0].ident.s == "importcpp":
      x[1] = strLit(outp, info)
  for k in countdown(inner[4].len - 1, 0):
    if inner[4][k].kind == nkIdent and inner[4][k].ident.s == "discardable":
      inner[4].sons.delete(k)
  inner[5] = empty(info)
  inner[6] = empty(info)
  ## The wrapper, under `raw`'s name: the N# string's characters and length.
  let w = newNodeI(nkProcDef, info, 7)
  w[0] = raw[0]
  w[1] = empty(info)
  w[2] = copyTree(raw[2])
  w[3] = copyTree(fp)
  for k in 1 ..< w[3].len:
    if convOf(w[3][k][0].ident.s).len > 0: w[3][k][^2] = l.id("string", info)
  w[4] = (if fp[0].kind != nkEmpty: newTree(nkPragma, info, l.id("discardable", info))
          else: empty(info))
  w[5] = empty(info)
  let call = newTree(nkCall, info, l.id("nsRawArgs_" & m.name, info))
  for nm in order:
    if nm.startsWith("nsLen_"):
      let src = nm[6 .. ^1]
      call.add newTree(nkCall, info, l.id("int64", info),
                       newTree(nkDotExpr, info, l.id(src, info), l.id("len", info)))
    elif convOf(nm).len > 0:
      call.add newTree(nkCall, info, l.id("cstring", info), l.id(nm, info))
    else:
      call.add l.id(nm, info)
  w[6] = newTree(nkStmtList, info,
                 (if fp[0].kind != nkEmpty: newTree(nkReturnStmt, info, call) else: call))
  result = newTree(nkStmtList, info, inner, w)

proc ownedReturn(l: Lowerer; m: NsNode; raw: PNode; rt, pattern, header: string): PNode =
  ## An `extern` returning a class N# may own: `nsRaw_M`, the C++ call, and `M`, the
  ## N# reference to what it gives. By value (the default) the result is
  ## constructed in a fresh box (`new (box) T(call)`, which C++17 elides into);
  ## `[return: Borrowed]` lends a pointer or reference, which nothing keeps alive;
  ## `[return: Owned]` hands over one C++ made with `new`, which N# deletes.
  let info = m.info
  let root = l.scope.handleRoot(rt)
  let href = newTree(nkBracketExpr, info, l.id("NsH_" & root, info), l.id(rt, info))
  let cpp = (if l.scope.isNative(rt): l.scope.classes[rt].native.cpp else: rt)
  let byValue = not returnAttr(m, "Borrowed") and not returnAttr(m, "Owned")
  let fp = raw[3]
  var args: seq[PNode] = @[]
  for i in 1 ..< fp.len:
    for k in 0 ..< fp[i].len - 2: args.add l.id(fp[i][k].ident.s, info)
  let wrapper = newNodeI(nkProcDef, info, 7)
  wrapper[0] = raw[0]
  wrapper[1] = empty(info)
  wrapper[2] = copyTree(raw[2])
  wrapper[3] = copyTree(fp)
  wrapper[3][0] = copyTree(href)
  wrapper[4] = newTree(nkPragma, info, l.id("discardable", info))
  wrapper[5] = empty(info)
  raw[0] = l.id("nsRaw_" & m.name, info)
  let call = newTree(nkCall, info, l.id("nsRaw_" & m.name, info))
  let body = newNodeI(nkStmtList, info)
  if byValue:
    fp[0] = empty(info)
    fp.sons.insert(l.identDefs("nsDest", newTree(nkPtrTy, info, l.id(rt, info)), info), 1)
    raw[4] = l.cppPragma("new (#) " & cpp & "(" & shiftTypeRefs(pattern) & ")", header, info)
    body.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id("nsB", info),
      empty(info), newTree(nkCall, info, l.id("nsNewBox", info), l.id(rt, info))))
    call.add newTree(nkCall, info, l.id("nsAt", info), l.id("nsB", info))
    for a in args: call.add a
    body.add call
    body.add newTree(nkAsgn, info, l.id("result", info),
                     newTree(nkCall, info, l.id("nsMake", info), copyTree(href), l.id("nsB", info)))
  else:
    fp[0] = newTree(nkPtrTy, info, l.id(rt, info))
    raw[4] = l.cppPragma("nsAddr(" & pattern & ")", header, info)
    for a in args: call.add a
    body.add newTree(nkAsgn, info, l.id("result", info),
                     newTree(nkCall, info,
                             l.id((if returnAttr(m, "Owned"): "nsAdopt" else: "nsBorrow"), info),
                             copyTree(href), call))
  wrapper[6] = body
  result = newTree(nkStmtList, info, raw, wrapper)

proc nativeMethod(l: Lowerer; cls, m: NsNode; nat: NsNative; header: string;
                  patternOverride = ""): PNode =
  ## `extern R M<T>(args)` as `proc M[T](self: ptr C; t: typedesc[T]; args): R` over
  ## the C++ call; each type parameter is a `typedesc` argument, which the C++
  ## pattern names as `'k` (`'**k` for a handle: the `typedesc`, then the handle, are
  ## looked through to the class).
  let info = m.info
  let isStruct = cls.classKind == ckStruct
  let fp = newNodeI(nkFormalParams, info)
  fp.add l.typeToNim(m.typ, info)
  if m.attrs.isStatic:
    var ol = l
    ol.objTypes = true
    fp.add l.identDefs("t", newTree(nkBracketExpr, info, l.id("typedesc", info),
                                    ol.typeToNim(nsnTypeName(cls.name, info), info)), info)
  var targs: seq[string] = @[]
  var tps: seq[string] = @[]
  let handleSide = m.attributeNamed("OnHandle") != nil and not m.attrs.isStatic
  if handleSide:
    ## `[OnHandle]`: the receiver is a handle of any class of the family.
    tps.add "nsU"
    fp.add l.identDefs("self", newTree(nkBracketExpr, info,
                                       l.id("NsH_" & l.scope.handleRoot(cls.name), info),
                                       l.id("nsU", info)), info)
  elif not m.attrs.isStatic:
    fp.add l.identDefs("self", (if isStruct: l.id(cls.name, info)
                                else: newTree(nkPtrTy, info, l.id(cls.name, info))), info)
  for i, tp in m.typeParams:
    tps.add tp.name
    fp.add l.identDefs("ns_" & tp.name, newTree(nkBracketExpr, info, l.id("typedesc", info),
                                                l.id(tp.name, info)), info)
    targs.add "'" & (if l.isHandleConstrained(m, tp.name): "**" else: "") & $(i + 2)
  var forward = false
  for p in m.params:
    if p.paramMod == "params" and p.attributeNamed("Forward") != nil:
      ## `[Forward] params object[]`: the rest of the arguments, which `@` passes
      ## to the C++ call as they are.
      forward = true
      continue
    var t = l.nativeParamType(p.typ, p.info)
    if p.paramMod in ["ref", "out"]: t = newTree(nkVarTy, p.info, t)
    fp.add l.identDefs(p.name, t, p.info)
  var pattern = (if patternOverride.len > 0: patternOverride else: nativeOf(m).cpp)
  if pattern.len == 0:
    let targ = (if targs.len > 0: "<" & targs.join(", ") & ">" else: "")
    pattern =
      if m.attrs.isStatic: nat.cpp & "::" & m.name & targ & "(@)"
      elif isStruct or handleSide:
        "#." & (if targs.len > 0: "template " else: "") & m.name & targ & "(@)"
      else: "#->" & (if targs.len > 0: "template " else: "") & m.name & targ & "(@)"
  result = newNodeI(nkProcDef, info, 7)
  result[0] = l.nativeMemberId(m.name, info)
  result[1] = empty(info)
  result[2] = l.genericParams(tps, info)
  result[3] = fp
  ## C# lets a call statement drop a method's result.
  let isVoid = m.typ == nil or m.typ.kind in {nsnVoidType, nsnEmpty}
  var extra = (if isVoid: newSeq[string]() else: @["discardable"])
  if forward: extra.add "varargs"
  result[4] = l.cppPragma(pattern, header, info, extra)
  result[5] = empty(info)
  result[6] = empty(info)
  let rt = (if m.typ != nil and m.typ.kind == nsnTypeName: canonicalTypeName(m.typ.name)
            else: "")
  if forward and m.typ != nil and m.typ.kind == nsnTypeName:
    ## A `[Forward]` factory of a class N# may own (`T Create<T>(...) where T :
    ## Palette`), handed over or lent: a template passes the arguments on to the
    ## C++ call, whose pointer becomes the reference.
    var owned = false
    for w in m.constraints:
      if w.name == m.typ.name:
        for c in w.sons:
          if c.kind == nsnTypeName and l.scope.classes.hasKey(canonicalTypeName(c.name)) and
             l.scope.ownedFamily(canonicalTypeName(c.name)):
            owned = true
    if owned:
      let info = m.info
      let raw = result
      raw[0] = l.id("nsRaw_" & m.name, info)
      raw[3][0] = l.id("pointer", info)
      raw[4] = l.cppPragma("nsAddr(" & pattern & ")", header, info, ["varargs"])
      let tp = newNodeI(nkFormalParams, info)
      tp.add l.id("untyped", info)
      var names: seq[string] = @[]
      var typeArg = ""
      for i in 1 ..< raw[3].len:
        let d = raw[3][i]
        for k in 0 ..< d.len - 2:
          let nm = d[k].ident.s
          names.add nm
          if nm == "ns_" & m.typ.name: typeArg = nm
          tp.add l.identDefs(nm, (if d[^2].kind == nkBracketExpr and d[^2][0].kind == nkIdent and
                                     d[^2][0].ident.s == "typedesc": l.id("typedesc", info)
                                  else: copyTree(d[^2])), info)
      tp.add l.identDefs("nsArgs", newTree(nkBracketExpr, info, l.id("varargs", info),
                                           l.id("untyped", info)), info)
      let call = newTree(nkCall, info, l.id("nsRaw_" & m.name, info))
      for nm in names: call.add l.id(nm, info)
      call.add l.id("nsArgs", info)
      let how = (if returnAttr(m, "Owned"): "nsAdoptPtr" else: "nsBorrowPtr")
      let t = newNodeI(nkTemplateDef, info, 7)
      t[0] = l.nativeMemberId(m.name, info)
      for i in 1 .. 6: t[i] = empty(info)
      t[3] = tp
      t[6] = newTree(nkStmtList, info,
                     newTree(nkCall, info, l.id(how, info), l.id(typeArg, info), call))
      return newTree(nkStmtList, info, raw, t)
  if rt.len > 0 and l.scope.classes.hasKey(rt) and l.scope.ownedFamily(rt) and not forward:
    result = l.ownedReturn(m, result, rt, pattern, header)
  elif rt == "string" and not forward:
    result = l.stringReturn(m, result, pattern, header)
  if not forward:
    ## `[CString("Text::Str::From(#)")] string name`: the C++ call is the innermost
    ## proc, which builds those arguments from their characters.
    if result.kind == nkStmtList:
      result[0] = l.cstringParams(m, result[0])
      ## The result's wrapper passes those arguments on as the N# strings they are.
      for p in m.params:
        if p != nil and p.attributeNamed("CString") != nil:
          let wfp = result[1][3]
          for k in 1 ..< wfp.len:
            if wfp[k][0].kind == nkIdent and wfp[k][0].ident.s == p.name:
              wfp[k][^2] = l.id("string", m.info)
    else: result = l.cstringParams(m, result)

proc ownedNew(l: Lowerer; cls: NsNode; params: seq[PNode]; ctor, header: string;
              info: TLineInfo; into: PNode) =
  ## `new C(args)` for a class N# owns: `nsPlace_C(p, args)` runs the C++ constructor
  ## `ctor` in a fresh box (placement new), and `newC(args)` returns the reference
  ## holding it. An N# class deriving a native one also records the box, which
  ## `this` as a value keeps alive.
  let root = l.scope.handleRoot(cls.name)
  let place = newNodeI(nkProcDef, info, 7)
  place[0] = l.id("nsPlace_" & cls.name, info)
  for i in 1 .. 6: place[i] = empty(info)
  place[3] = newTree(nkFormalParams, info, empty(info),
                     l.identDefs("nsP", newTree(nkPtrTy, info, l.id(cls.name, info)), info))
  for p in params: place[3].add copyTree(p)
  place[4] = l.cppPragma("new (#) " & ctor, header, info)
  into.add place
  let href = newTree(nkBracketExpr, info, l.id("NsH_" & root, info), l.id(cls.name, info))
  let body = newNodeI(nkStmtList, info)
  body.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id("nsB", info), empty(info),
    newTree(nkCall, info, l.id("nsNewBox", info), l.id(cls.name, info))))
  let call = newTree(nkCall, info, l.id("nsPlace_" & cls.name, info),
                     newTree(nkCall, info, l.id("nsAt", info), l.id("nsB", info)))
  for p in params:
    for k in 0 ..< p.len - 2:
      call.add l.id((if p[k].kind == nkPostfix: p[k][1] else: p[k]).ident.s, info)
  body.add call
  if not l.scope.isNative(cls.name):
    body.add newTree(nkAsgn, info,
      newTree(nkDotExpr, info, newTree(nkDotExpr, info,
        newTree(nkCall, info, l.id("nsAt", info), l.id("nsB", info)), l.id("nsOwner", info)),
        l.id("box", info)),
      newTree(nkCast, info, l.id("pointer", info), l.id("nsB", info)))
  body.add newTree(nkAsgn, info, l.id("result", info),
                   newTree(nkCall, info, l.id("nsMake", info), href, l.id("nsB", info)))
  let pd = newNodeI(nkProcDef, info, 7)
  pd[0] = l.exportId("new" & cls.name, info)
  for i in 1 .. 6: pd[i] = empty(info)
  pd[3] = newTree(nkFormalParams, info, copyTree(href))
  for p in params: pd[3].add copyTree(p)
  pd[6] = body
  into.add pd

proc nativeProperty(l: Lowerer; cls, m: NsNode; nat: NsNative; header: string;
                    into: PNode) =
  ## `extern T P { get; set; }`: a getter `P` and a setter `P=` over the C++ the
  ## property's `[Native(Get = .., Set = ..)]` names -- a member function's name
  ## (`#->GetPosition()`, `#->SetPosition(value)`), or a pattern. A static one with
  ## neither is the C++ type's static member. `[OnHandle]` puts it on the handle.
  let info = m.info
  let pn = nativeOf(m)
  let isStatic = m.attrs.isStatic
  let handleSide = m.attributeNamed("OnHandle") != nil and not isStatic
  let isStruct = cls.classKind == ckStruct
  let access = (if handleSide or isStruct: "#." else: "#->")
  var ol = l
  ol.objTypes = true
  proc recvDefs(mutable: bool): PNode =
    if isStatic:
      l.identDefs("t", newTree(nkBracketExpr, info, l.id("typedesc", info),
                               ol.typeToNim(nsnTypeName(cls.name, info), info)), info)
    elif handleSide:
      l.identDefs("self", newTree(nkBracketExpr, info,
                                  l.id("NsH_" & l.scope.handleRoot(cls.name), info),
                                  l.id("nsU", info)), info)
    elif isStruct:
      l.identDefs("self", (if mutable: newTree(nkVarTy, info, l.id(cls.name, info))
                           else: l.id(cls.name, info)), info)
    else:
      l.identDefs("self", newTree(nkPtrTy, info, l.id(cls.name, info)), info)
  proc expand(given: string; setter: bool): string =
    ## A name is a member function (or, static, one of the type); a pattern is
    ## kept, with a static one's `typedesc` consumed first.
    if given.len == 0:
      if isStatic: return nat.cpp & "::" & m.name & (if setter: " = @" else: "@")
      return ""
    var isName = true
    for c in given:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}: isName = false
    if not isName: return (if isStatic: "#" & given else: given)
    if isStatic: return nat.cpp & "::" & given & (if setter: "(@)" else: "()@")
    access & given & (if setter: "(#)" else: "()")
  proc emit(name: PNode; fp: PNode; pattern: string) =
    let pd = newNodeI(nkProcDef, info, 7)
    pd[0] = name
    for i in 1 .. 6: pd[i] = empty(info)
    if handleSide: pd[2] = l.genericParams(@["nsU"], info)
    pd[3] = fp
    pd[4] = l.cppPragma(pattern, header, info)
    ## A getter returning a string or a class N# may own is split as a method
    ## returning one is, with the getter's own `[return: ...]` attributes.
    let acc = (if m.params.len > 0: m.params[0] else: nil)
    let gm = nsn(nsnMethodDecl, info)
    gm.name = m.name
    if acc != nil: gm.attributes = acc.attributes
    let rt = (if m.typ != nil and m.typ.kind == nsnTypeName: canonicalTypeName(m.typ.name)
              else: "")
    if fp[0].kind != nkEmpty and rt == "string":
      into.add l.stringReturn(gm, pd, pattern, header)
    elif fp[0].kind != nkEmpty and l.scope.classes.hasKey(rt) and l.scope.ownedFamily(rt):
      into.add l.ownedReturn(gm, pd, rt, pattern, header)
    else:
      into.add pd
  let getter = (if m.params.len > 0: m.params[0] else: nil)
  let setter = (if m.params.len > 1: m.params[1] else: nil)
  if getter != nil:
    let pattern = expand(pn.get, false)
    if pattern.len > 0:
      emit(l.nativeMemberId(m.name, info),
           newTree(nkFormalParams, info, l.typeToNim(m.typ, info), recvDefs(false)), pattern)
  if setter != nil:
    let pattern = expand(pn.set, true)
    if pattern.len > 0:
      emit(l.nativeMemberId(m.name & "=", info),
           newTree(nkFormalParams, info, empty(info), recvDefs(true),
                   l.identDefs("value", l.nativeParamType(m.typ, info), info)), pattern)

proc nativeIndexer(l: Lowerer; cls, m: NsNode; nat: NsNative; header: string;
                   into: PNode) =
  ## `extern T this[int i] { get; set; }`: Nim's `[]` and `[]=` over the C++ the
  ## indexer's `[Native(Get = .., Set = ..)]` names -- a member function's name,
  ## which takes the indices (and, setting, the value after them:
  ## `#->GetChild(i)`, `#->SetChild(i, value)`), or a pattern (`"(*#)[#]"`).
  let info = m.info
  let pn = nativeOf(m)
  let isStruct = cls.classKind == ckStruct
  let access = (if isStruct: "#." else: "#->")
  proc expand(given: string): string =
    var isName = given.len > 0
    for c in given:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}: isName = false
    (if isName: access & given & "(@)" else: given)
  proc recv(mutable: bool): PNode =
    if isStruct:
      l.identDefs("self", (if mutable: newTree(nkVarTy, info, l.id(cls.name, info))
                           else: l.id(cls.name, info)), info)
    else:
      l.identDefs("self", newTree(nkPtrTy, info, l.id(cls.name, info)), info)
  let getter = (if m.sons.len > 0: m.sons[0] else: nil)
  let setter = (if m.sons.len > 1: m.sons[1] else: nil)
  if getter != nil and pn.get.len > 0:
    let pattern = expand(pn.get)
    let fp = newTree(nkFormalParams, info, l.typeToNim(m.typ, info), recv(false))
    for p in m.params: fp.add l.identDefs(p.name, l.nativeParamType(p.typ, p.info), p.info)
    let pd = newNodeI(nkProcDef, info, 7)
    pd[0] = l.exportId("[]", info)
    for i in 1 .. 6: pd[i] = empty(info)
    pd[3] = fp
    pd[4] = l.cppPragma(pattern, header, info)
    ## A string, or a class N# may own, is returned as a method returns one.
    let gm = nsn(nsnMethodDecl, info)
    gm.name = "nsIndex_" & cls.name
    gm.attributes = getter.attributes
    let rt = (if m.typ != nil and m.typ.kind == nsnTypeName: canonicalTypeName(m.typ.name)
              else: "")
    if rt == "string": into.add l.stringReturn(gm, pd, pattern, header)
    elif l.scope.classes.hasKey(rt) and l.scope.ownedFamily(rt):
      into.add l.ownedReturn(gm, pd, rt, pattern, header)
    else: into.add pd
  if setter != nil and pn.set.len > 0:
    let fp = newTree(nkFormalParams, info, empty(info), recv(true))
    for p in m.params: fp.add l.identDefs(p.name, l.nativeParamType(p.typ, p.info), p.info)
    fp.add l.identDefs("value", l.nativeParamType(m.typ, info), info)
    let pd = newNodeI(nkProcDef, info, 7)
    pd[0] = l.exportId("[]=", info)
    for i in 1 .. 6: pd[i] = empty(info)
    pd[3] = fp
    pd[4] = l.cppPragma(expand(pn.set), header, info)
    into.add pd

proc lowerNativeType(l: var Lowerer; n: NsNode; into: var seq[PNode]) =
  let info = n.info
  let nat = l.scope.classes[n.name].native
  let header = l.nativeHeader(n.name)
  ## The helpers' header (`nsAddr`, boxes, `NsField`), which a member's pattern may
  ## use while its `header:` names the binding's.
  if not l.helpersIncluded:
    l.helpersIncluded = true
    into.add newTree(nkPragma, info, newTree(nkExprColonExpr, info, l.id("emit", info),
      strLit("/*TYPESECTION*/\n#include \"pure/nsharp/nsobj.hpp\"\n", info)))
  var ol = l
  ol.objTypes = true
  # the type: the C++ type, with the fields the binding names
  let recList = newNodeI(nkRecList, info)
  for m in n.sons:
    if m.kind == nsnFieldDecl and not m.attrs.isStatic:
      recList.add l.identDefs(m.name, l.typeToNim(m.typ, m.info), m.info)
      recList[^1][0] = l.exportId(m.name, m.info)
  let objTy = newNodeI(nkObjectTy, info)
  objTy.add empty(info)
  objTy.add (if n.typ != nil: newTree(nkOfInherit, info, ol.typeToNim(n.typ, info))
             else: empty(info))
  objTy.add recList
  let extra = (if n.classKind == ckClass and n.typ == nil and not n.attrs.isStatic:
                 @["inheritable"] else: @[])
  let sec = newNodeI(nkTypeSection, info)
  if nat.handle.len > 0:
    ## The handle: `NsH_<Class>[T]`, the template with `{0}` as the class. It comes
    ## first, since an instantiation of a type declared later in the section stays
    ## unresolved.
    sec.add newTree(nkTypeDef, info,
                    newTree(nkPragmaExpr, info, l.exportId("NsH_" & n.name, info),
                            l.cppPragma(nat.handle.replace("{0}", "'0"), header, info)),
                    l.genericParams(@["T"], info),
                    newTree(nkObjectTy, info, empty(info), empty(info), empty(info)))
  let ownedRoot = n.classKind == ckClass and not n.attrs.isStatic and
                  l.scope.ownedFamily(n.name) and l.scope.handleRoot(n.name) == n.name
  if ownedRoot:
    ## A family with no handle: `NsH_<Class>[T]` is an N# reference, a pointer to the
    ## object and the box keeping it alive when N# made it (nil when C++ lent it).
    let rec = newTree(nkRecList, info,
                      newTree(nkIdentDefs, info, l.exportId("p", info),
                              newTree(nkPtrTy, info, l.id("T", info)), empty(info)),
                      newTree(nkIdentDefs, info, l.exportId("keep", info),
                              newTree(nkRefTy, info, l.id("NsBoxBase", info)), empty(info)))
    sec.add newTree(nkTypeDef, info, l.exportId("NsH_" & n.name, info),
                    l.genericParams(@["T"], info),
                    newTree(nkObjectTy, info, empty(info), empty(info), rec))
  sec.add newTree(nkTypeDef, info,
                  newTree(nkPragmaExpr, info, l.exportId(n.name, info),
                          l.cppPragma(nat.cpp, header, info, extra)),
                  empty(info), objTy)
  into.add sec
  # the members: in a statement list, so the module's forward declarations, which
  # an `importcpp` proc has no body to follow, leave them alone
  let procs = newNodeI(nkStmtList, info)
  if ownedRoot:
    l.familyProcs.add newTree(nkCall, info, l.id("nsObjProcs", info), l.id("NsH_" & n.name, info),
                      l.id(n.name, info))
  if nat.handle.len > 0:
    ## Validity is the handle's `explicit operator bool` unless `Valid` says how to
    ## test it; the invalid handle is a default-constructed one unless `Null` names
    ## it; the object is the handle's `operator->` unless `Deref` says how to reach it.
    let valid = (if nat.valid.len > 0: nat.valid else: "static_cast<bool>(#)")
    let null = (if nat.null.len > 0: nat.null.replace("{0}", "'1")
                else: nat.handle.replace("{0}", "'1") & "()")
    let deref = (if nat.deref.len > 0: nat.deref else: "#.operator->()")
    l.familyProcs.add newTree(nkCall, info, l.id("nsHandleProcs", info), l.id("NsH_" & n.name, info),
                      l.id(n.name, info), strLit(header, info), strLit(valid, info),
                      strLit(null, info), strLit(deref, info))
  if nat.handle.len > 0 and nat.selfHandle.len > 0:
    ## `nsSelfOf_<Class>(self)`: an object's own handle, through `SelfHandle` -- a
    ## C++ pattern (`#->GetId()`), or a member name standing for `#->name`.
    let pattern = (if '#' in nat.selfHandle: nat.selfHandle else: "#->" & nat.selfHandle)
    let fp = newTree(nkFormalParams, info,
                     newTree(nkBracketExpr, info, l.id("NsH_" & n.name, info), l.id(n.name, info)),
                     l.identDefs("self", newTree(nkPtrTy, info, l.id(n.name, info)), info))
    let pd = newNodeI(nkProcDef, info, 7)
    pd[0] = l.exportId("nsSelfOf_" & n.name, info)
    for i in 1 .. 6: pd[i] = empty(info)
    pd[3] = fp
    pd[4] = l.cppPragma(pattern, header, info)
    procs.add pd
  var paramless = false
  for m in n.sons:
    case m.kind
    of nsnMethodDecl:
      procs.add l.nativeMethod(n, m, nat, header)
      if m.attrs.isVirtual and not m.attrs.isStatic and m.typeParams.len == 0:
        ## `nsBaseCall_C_M`: the C++ class's own `M`, called without dispatch,
        ## which `base.M()` in an override is.
        var bc: NsNode
        new(bc)
        bc[] = m[]
        bc.name = "nsBaseCall_" & n.name & "_" & m.name
        bc.attributes = @[]
        for a in m.attributes:
          if a.strVal == "return": bc.attributes.add a
        procs.add l.nativeMethod(n, bc, nat, header, "#->" & nat.cpp & "::" & m.name & "(@)")
    of nsnCtorDecl:
      if m.attrs.isStatic: continue
      if m.params.len == 0: paramless = true
      if n.classKind == ckClass and l.scope.engineOwned(n.name):
        ## The engine makes these: the constructor is only a derived class's
        ## `: base(...)`, which C++ calls by name.
        continue
      if n.classKind == ckClass:
        ## A class N# may own: `new C(...)` makes one in a box.
        var ps: seq[PNode] = @[]
        for p in m.params: ps.add l.identDefs(p.name, l.nativeParamType(p.typ, p.info), p.info)
        l.ownedNew(n, ps, nat.cpp & "(@)", header, m.info, procs)
        continue
      let fp = newNodeI(nkFormalParams, m.info)
      fp.add ol.typeToNim(nsnTypeName(n.name, m.info), m.info)
      for p in m.params: fp.add l.identDefs(p.name, l.nativeParamType(p.typ, p.info), p.info)
      let pd = newNodeI(nkProcDef, m.info, 7)
      pd[0] = l.exportId("new" & n.name, m.info)
      for i in 1 .. 6: pd[i] = empty(m.info)
      pd[3] = fp
      pd[4] = l.cppPragma(nat.cpp & "(@)", header, m.info, ["constructor"])
      procs.add pd
    of nsnPropertyDecl:
      l.nativeProperty(n, m, nat, header, procs)
    of nsnIndexerDecl:
      l.nativeIndexer(n, m, nat, header, procs)
    of nsnOperatorDecl:
      let fp = newNodeI(nkFormalParams, m.info)
      fp.add l.typeToNim(m.typ, m.info)
      for p in m.params: fp.add l.identDefs(p.name, l.typeToNim(p.typ, p.info), p.info)
      let pattern = (if m.params.len == 2: "(# " & m.name & " #)" else: "(" & m.name & "#)")
      let pd = newNodeI(nkProcDef, m.info, 7)
      pd[0] = l.exportId(nimOperatorName(m.name), m.info)
      for i in 1 .. 6: pd[i] = empty(m.info)
      pd[3] = fp
      pd[4] = l.cppPragma(pattern, header, m.info)
      procs.add pd
    else: discard
  if n.classKind == ckClass and not paramless and not n.attrs.isStatic and
     not n.attrs.isAbstract and l.scope.ownedFamily(n.name):
    ## No constructor declared: C#'s implicit parameterless one, C++'s default.
    l.ownedNew(n, @[], nat.cpp & "()", header, info, procs)
  if n.classKind == ckStruct and not paramless:
    ## `new V()` / `default(V)`: the C++ value-initialised one.
    let fp = newTree(nkFormalParams, info, ol.typeToNim(nsnTypeName(n.name, info), info))
    let pd = newNodeI(nkProcDef, info, 7)
    pd[0] = l.exportId("new" & n.name, info)
    for i in 1 .. 6: pd[i] = empty(info)
    pd[3] = fp
    pd[4] = l.cppPragma(nat.cpp & "()", header, info, ["constructor"])
    procs.add pd
  l.nativeProcs.add procs

proc cppParamSig(np: PNode): string =
  ## A member function's C++ parameter list for `{.member.}`/`{.virtual.}`:
  ## `('2 #2, '3 #3)`, the receiver being the first.
  result = "("
  var k = 2
  for i in 2 ..< np.len:
    for j in 0 ..< np[i].len - 2:
      if k > 2: result.add ", "
      result.add "'" & $k & " #" & $k
      inc k
  result.add ")"

proc guardEntry(l: Lowerer; call: PNode; where: string; hasResult: bool;
                info: TLineInfo): PNode =
  ## Where C++ enters N#: an exception must not leave, since C++ cannot see it
  ## (with goto exceptions it would stay pending through the engine's own code),
  ## so it goes to `nsOnUnhandled` (`nsEscaped`); if that returns, so does this,
  ## with the default result.
  let body = (if hasResult: newTree(nkAsgn, info, l.id("result", info), call) else: call)
  newTree(nkTryStmt, info, newTree(nkStmtList, info, body, newTree(nkDiscardStmt, info, empty(info))),
          newTree(nkExceptBranch, info, l.anyException(info),
                  newTree(nkCall, info, l.id("nsEscaped", info), strLit(where, info))))

proc cppEntry(l: Lowerer; cls, m: NsNode; np: PNode; quals = ""): PNode =
  ## `nsCpp_M`: the C++ member function `M` of an N# class deriving a native one
  ## (`{.member.}`, or `{.virtual.}` for the override of a native virtual), running
  ## the N# `M` behind the boundary `guardEntry` keeps.
  let info = m.info
  var sig = m.name & cppParamSig(np)
  ## A `const` one reaches the N# body through `const_cast`: N# keeps the body from
  ## changing the object (NS9916/NS9917), and its managed fields are read through
  ## `nsVal`, which takes them as variables.
  let recv = (if isConstQualified(quals): newTree(nkCall, info, l.id("nsUnconst", info),
                                                  l.id("self", info))
              else: l.id("self", info))
  let call = newTree(nkCall, info, l.id(m.name, info), recv)
  for i in 2 ..< np.len:
    for j in 0 ..< np[i].len - 2:
      call.add l.id(np[i][j].ident.s, info)
  if quals.len > 0: sig.add " " & quals
  if m.attrs.isOverride: sig.add " override"
  let fp = copyTree(np)
  for i in 2 ..< fp.len:
    if fp[i].len >= 3: fp[i][^1] = empty(info)       ## no default values here
  let pd = newNodeI(nkProcDef, info, 7)
  pd[0] = l.id("nsCpp_" & m.name, info)
  for i in 1 .. 6: pd[i] = empty(info)
  pd[3] = fp
  pd[4] = newTree(nkPragma, info, newTree(nkExprColonExpr, info,
    l.id((if m.attrs.isOverride: "virtual" else: "member"), info), strLit(sig, info)))
  pd[6] = newTree(nkStmtList, info,
                  l.guardEntry(call, cls.name & "." & m.name, fp[0].kind != nkEmpty, info))
  pd

proc exportWrapper(l: Lowerer; cls, m: NsNode): PNode =
  ## `[Export("name")]` on a static method: `proc name() {.exportc.}`, which C++
  ## calls, forwarding to the method.
  let a = m.attributeNamed("Export")
  if a == nil or not m.attrs.isStatic: return nil
  var name = m.name
  for x in a.sons:
    if x.kind == nsnStrLit: name = x.strVal
  let info = m.info
  let fp = l.formalParams(m.typ, m.params, info)
  let call = newTree(nkCall, info, l.id(m.name, info), l.id(cls.name, info))
  for p in m.params: call.add l.id(p.name, info)
  result = newNodeI(nkProcDef, info, 7)
  result[0] = l.id(name, info)
  for i in 1 .. 6: result[i] = empty(info)
  result[3] = fp
  result[4] = newTree(nkPragma, info,
                      newTree(nkExprColonExpr, info, l.id("exportc", info), strLit(name, info)),
                      l.id("cdecl", info))
  result[6] = newTree(nkStmtList, info, l.guardEntry(call, cls.name & "." & m.name,
                                                    m.typ != nil and m.typ.kind notin
                                                      {nsnVoidType, nsnEmpty}, info))

proc plainNativeField(l: Lowerer; t: NsNode): bool =
  ## A field type C++ may copy and move as bytes: a number, `bool`, `char`, an
  ## enum, a native struct, or a handle. Anything else is Nim-managed.
  if t == nil or t.kind != nsnTypeName or t.sons.len > 0: return false
  let n = canonicalTypeName(t.name)
  if n in ["int", "uint", "long", "ulong", "short", "ushort", "byte", "sbyte", "float",
           "double", "bool", "char", "nint", "nuint"]:
    return true
  if l.scope.enums.contains(n): return true
  if l.scope.classes.hasKey(n):
    if l.scope.engineOwned(n): return true
    if l.scope.isNative(n) and l.scope.classes[n].classKind == ckStruct: return true
  false

proc isManagedNativeField(l: Lowerer; cls, field: string): bool =
  ## A field of a class deriving a native one whose type Nim manages: it is held as
  ## an `NsField[T]`, and read and written through `nsVal`.
  if cls.len == 0 or not l.scope.classes.hasKey(cls) or not l.scope.nativeBased(cls) or
     l.scope.isNative(cls):
    return false
  let m = l.scope.findMemberInfo(cls, field)
  if m.name.len == 0 or m.isMethod or m.isProperty or m.isStatic or
     not l.scope.classes.hasKey(m.owner) or l.scope.isNative(m.owner):
    return false
  not l.plainNativeField(m.typ)

proc lowerNativeDerived(l: var Lowerer; n: NsNode; into: var seq[PNode]) =
  ## An N# class deriving a native one: a C++ struct deriving it. A field Nim
  ## manages is an `NsField[T]`, whose hooks the module registers when it starts,
  ## so C++'s own copies, moves and destruction of the struct keep Nim's counts.
  let info = n.info
  var ol = l
  ol.objTypes = true
  let recList = newNodeI(nkRecList, info)
  var registered: seq[string] = @[]
  var inits: seq[NsNode] = @[]
  for m in n.sons:
    if m.kind == nsnFieldDecl and not m.attrs.isStatic:
      var t = l.typeToNim(m.typ, m.info)
      if not l.plainNativeField(m.typ):
        let key = mangleType(m.typ)
        if key notin registered:
          registered.add key
          into.add newTree(nkCall, m.info, l.id("nsUseField", m.info), copyTree(t))
        t = newTree(nkBracketExpr, m.info, l.id("NsField", m.info), t)
      recList.add newTree(nkIdentDefs, m.info, l.exportId(m.name, m.info), t, empty(m.info))
      if m.body != nil: inits.add m
  let owned = l.scope.ownedFamily(n.name)
  if owned and n.typ != nil and l.scope.isNative(canonicalTypeName(n.typ.name)):
    ## (Once: the first N# class above the native one has it, and its own derive it.)
    ## The box N# made it in, if it did, which `this` as a value keeps alive.
    recList.add newTree(nkIdentDefs, info, l.id("nsOwner", info), l.id("NsOwner", info),
                        empty(info))
  let objTy = newTree(nkObjectTy, info, empty(info),
                      newTree(nkOfInherit, info, ol.typeToNim(n.typ, info)), recList)
  let pragma = newTree(nkPragma, info,
                       newTree(nkExprColonExpr, info, l.id("exportc", info),
                               strLit(n.name, info)))
  into.add newTree(nkTypeSection, info,
                   newTree(nkTypeDef, info,
                           newTree(nkPragmaExpr, info, l.exportId(n.name, info), pragma),
                           empty(info), objTy))
  var ctors: seq[NsNode] = @[]
  for m in n.sons:
    if m.kind == nsnCtorDecl and not m.attrs.isStatic: ctors.add m
  if ctors.len == 0 and inits.len > 0:
    ## No constructor of its own: the field initializers are a C++ default
    ## constructor, which is what the engine's `T obj;` runs.
    ctors.add nil
  var ctorIndex = 0
  for c in ctors:
    ## A constructor: a C++ one, which the engine runs when a `[Forward]` factory
    ## creates the object, and which starts with the field initializers. Its body
    ## sees `this` as `self`, as a member function's does.
    let cinfo = (if c != nil: c.info else: info)
    let body = newNodeI(nkStmtList, cinfo)
    if c != nil and c.body != nil:
      body.add newTree(nkLetSection, cinfo,
                       newTree(nkIdentDefs, cinfo, l.id("self", cinfo), empty(cinfo),
                               newTree(nkAddr, cinfo, l.id("result", cinfo))))
    for m in inits:
      var target = newTree(nkDotExpr, m.info, l.id("result", m.info), l.id(m.name, m.info))
      if not l.plainNativeField(m.typ):
        target = newTree(nkCall, m.info, l.id("nsVal", m.info), target)
      var value = l.expr(m.body)
      if m.typ != nil and m.body.kind in {nsnIntLit, nsnFloatLit}:
        value = newTree(nkCall, m.info, l.typeToNim(m.typ, m.info), value)
      body.add newTree(nkAsgn, m.info, target, value)
    let fp = newTree(nkFormalParams, cinfo, ol.typeToNim(nsnTypeName(n.name, cinfo), cinfo))
    if c != nil:
      for p in c.params: fp.add l.paramDef(p)
      if c.body != nil:
        ## C++ cannot see an exception that leaves it, and the object would be half
        ## made, so one stops the program, as an unhandled exception does.
        var inner = l
        inner.thisName = "self"
        ## The closing `discard` keeps the body's last call from being the value of
        ## the `try`, which ends the proc.
        let user = newTree(nkStmtList, c.info, inner.memberBody(nil, c.body, c.params),
                           newTree(nkDiscardStmt, c.info, empty(c.info)))
        body.add newTree(nkTryStmt, c.info, user,
                         newTree(nkExceptBranch, c.info, l.anyException(c.info),
                                 newTree(nkCall, c.info, l.id("nsEscaped", c.info),
                                         strLit(n.name & "." & n.name, c.info))))
    let pd = newNodeI(nkProcDef, cinfo, 7)
    pd[0] = l.id("nsInit_" & n.name, cinfo)
    for i in 1 .. 6: pd[i] = empty(cinfo)
    pd[3] = fp
    pd[4] = newTree(nkPragma, cinfo, l.id("constructor", cinfo))
    if c != nil and c.initKind == "base" and c.initArgs.len > 0:
      ## `: base(args)`: the C++ initializer list. A parameter passes as it is; any
      ## other argument is a function of the parameters (`nsBase_C_k_j`), which the
      ## list calls -- C++ runs it before the constructor's body, as C# does.
      var names: seq[string] = @[]
      var sig = n.name & "("
      for i, p in c.params:
        if i > 0: sig.add ", "
        sig.add "'" & $(i + 1) & " #" & $(i + 1)
        names.add p.name
      let baseName = canonicalTypeName(n.typ.name)
      let baseCpp = (if l.scope.isNative(baseName): l.scope.classes[baseName].native.cpp
                     else: baseName)
      var args: seq[string] = @[]
      for j, a in c.initArgs:
        let v = (if a.kind == nsnNamedArg: a.body else: a)
        let pt = (if a.argParam != nil: a.argParam.typ else: nil)
        let isStr = pt != nil and pt.kind == nsnTypeName and
                    canonicalTypeName(pt.name) == "string"
        let k = (if v.kind == nsnIdent: names.find(v.name) else: -1)
        if k >= 0 and not isStr:
          args.add "#" & $(k + 1)
          continue
        let helper = "nsBase_" & n.name & "_" & $ctorIndex & "_" & $j
        let hp = newNodeI(nkFormalParams, cinfo)
        hp.add (if pt != nil: l.nativeParamType(pt, cinfo) else: empty(cinfo))
        for p in c.params: hp.add l.paramDef(p)
        var value = l.expr(v)
        if isStr: value = newTree(nkCall, cinfo, l.id("cstring", cinfo), value)
        elif pt != nil and v.kind in {nsnIntLit, nsnFloatLit}:
          value = newTree(nkCall, cinfo, l.typeToNim(pt, cinfo), value)
        let h = newNodeI(nkProcDef, cinfo, 7)
        h[0] = l.id(helper, cinfo)
        for i in 1 .. 6: h[i] = empty(cinfo)
        h[3] = hp
        h[4] = newTree(nkPragma, cinfo,
                       newTree(nkExprColonExpr, cinfo, l.id("exportc", cinfo), strLit(helper, cinfo)),
                       l.id("cdecl", cinfo))
        h[6] = newTree(nkStmtList, cinfo, value)
        into.add h
        var call = helper & "("
        for i in 0 ..< c.params.len:
          if i > 0: call.add ", "
          call.add "#" & $(i + 1)
        args.add call & ")"
      pd[4] = newTree(nkPragma, cinfo, newTree(nkExprColonExpr, cinfo, l.id("constructor", cinfo),
        strLit(sig & ") : " & baseCpp & "(" & args.join(", ") & ")", cinfo)))
    inc ctorIndex
    pd[6] = body
    into.add pd
  if owned and not n.attrs.isAbstract:
    ## `new D(args)`: N# owns what it makes of a family with no handle.
    let made = newNodeI(nkStmtList, info)
    if ctors.len == 0:
      l.ownedNew(n, @[], n.name & "()", "", info, made)
    for c in ctors:
      var ps: seq[PNode] = @[]
      if c != nil:
        for p in c.params: ps.add l.paramDef(p)
      l.ownedNew(n, ps, n.name & "(@)", "", (if c != nil: c.info else: info), made)
    ## In a statement list, which the module's forward declarations leave alone:
    ## `nsPlace_D` is an `importcpp` proc, with no body to follow.
    into.add made
  var staticCtor: seq[PNode] = @[]
  var staticInits: seq[PNode] = @[]
  for m in n.sons:
    var inner = l
    case m.kind
    of nsnFieldDecl:
      if m.attrs.isStatic:
        var st = l
        st.thisName = ""
        st.lowerStaticField(n, m, staticInits, into)
    of nsnMethodDecl:
      let fp = l.formalParams(m.typ, m.params, m.info)
      let np = newNodeI(nkFormalParams, m.info)
      np.add fp[0]
      if m.attrs.isStatic:
        inner.thisName = ""
        np.add ol.typedescDefs(n.name, m.info)
      else:
        inner.thisName = "self"
        np.add l.identDefs("self", newTree(nkPtrTy, m.info, l.id(n.name, m.info)), m.info)
      for i in 1 ..< fp.len: np.add fp[i]
      let pd = inner.mkProc(l.exportId(m.name, m.info), np,
                            inner.memberBody(m.typ, m.body, m.params), m.info)
      if not m.attrs.isStatic:
        ## The N# body is a member function too (`nsM_M`, which C++ does not
        ## know), so it reaches the base's protected members.
        pd[4] = newTree(nkPragma, m.info, newTree(nkExprColonExpr, m.info, l.id("member", m.info),
                        strLit("nsM_" & m.name & cppParamSig(np), m.info)))
      into.add pd
      if not m.attrs.isStatic:
        ## The C++ member function, which the engine finds by name (a concept), or
        ## the override of a native `virtual`: it runs the N# one (which N# calls
        ## itself, so its exceptions reach an N# `catch`), and stops one escaping
        ## into C++. It has the qualifiers of the C++ function it overrides
        ## (`const`, `noexcept`), or `const` for a `readonly` method.
        let quals =
          if m.attrs.isOverride: l.scope.nativeQualifiers(n.name, m.name)
          elif m.attrs.isReadonly: "const"
          else: ""
        into.add l.cppEntry(n, m, np, quals)
      let w = l.exportWrapper(n, m)
      if w != nil: into.add w
    of nsnCtorDecl:
      if m.attrs.isStatic and m.body != nil:
        ## The static constructor: after the static fields' initializers, when the
        ## module starts.
        var st = l
        st.thisName = ""
        staticCtor.add st.stmtSeq(m.body)
    else: discard
  for st in staticCtor: staticInits.add st
  ## The interfaces it implements: its handle, boxed, is the interface value's
  ## object, and each table entry calls the member on what the handle reaches.
  l.lowerImplementations(n, false, into)
  if staticInits.len > 0:
    let fp = newNodeI(nkFormalParams, info)
    fp.add empty(info)
    let body = newNodeI(nkStmtList, info)
    for st in staticInits: body.add st
    l.staticInits.add l.mkProc(l.id("nsStaticInit" & n.name, info), fp, body, info)

proc lowerClass(l: var Lowerer; n: NsNode; into: var seq[PNode]) =
  let isClass = n.classKind == ckClass
  let mappedBase =
    if n.typ != nil and n.typ.kind == nsnTypeName: nimTypeName(n.typ.name)
    else: ""
  let isException = isClass and
    l.surface.isExceptionType(mappedBase, l.scope.baseChain(mappedBase))
  l.curClass = n
  l.curBase = mappedBase
  l.curBaseType = (if n.typ != nil and n.typ.kind == nsnTypeName: n.typ else: nil)
  l.curIsException = isException
  if l.scope.isNative(n.name):
    l.lowerNativeType(n, into)
    return
  if l.scope.nativeBased(n.name):
    l.lowerNativeDerived(n, into)
    return
  for m in n.sons:
    if m.kind == nsnFieldDecl and m.attrs.isEvent and m.typ != nil and
       not (m.typ.kind == nsnTypeName and m.typ.name == "seq"):
      ## An event holds its handlers: a list of the delegate type.
      let t = nsnTypeName("seq", m.typ.info)
      t.add m.typ
      m.typ = t
  l.clsTypeParams = @[]
  for t in n.typeParams: l.clsTypeParams.add t.name
  l.procTypeParams = l.clsTypeParams
  defer:
    l.clsTypeParams = @[]
    l.procTypeParams = @[]
  if not isException:
    let firstGen = into.len
    if n.attrs.isRecord: l.recordMembers(n, isClass, into)
    for p in l.objectToString(n, isClass): into.add p
    ## Of what C# generates for a type (a record's `ToString`, `Equals`,
    ## `GetHashCode`, the default `ToString`), the frames .NET names; the rest are
    ## helpers that record none.
    let owner = l.frameOwner(n)
    for pd in into[firstGen .. ^1]:
      if pd.kind notin {nkProcDef, nkMethodDef, nkFuncDef} or pd.len < 7 or
         pd[6].kind == nkEmpty or pd[4].kind == nkPragma and
         pd[4].sons.anyIt(it.kind == nkExprColonExpr and it[0].kind == nkIdent and
                          it[0].ident.s in ["nsFrame", "stackTrace"]):
        continue
      let own = n.name & (if n.typeParams.len > 0: "`" & $n.typeParams.len else: "")
      case procNameOf(pd)
      of "ToString":
        ## A record's own; a plain class's field print is N#'s, which .NET has not.
        if n.attrs.isRecord: l.framed(pd, owner & ".ToString()") else: l.unframed(pd)
      of "Equals": l.framed(pd, owner & ".Equals(" & own & " other)")
      of "hash": l.framed(pd, owner & ".GetHashCode()")
      else: l.unframed(pd)
  else:
    for p in l.exceptionTypeName(n): into.add p
  l.lowerImplementations(n, isException, into)

  # 1. the type: `C = ref object` for a class, a plain `object` for a struct and
  #    for an exception class (which is raised as `ref C`).
  let recList = newNodeI(nkRecList, n.info)
  for m in n.sons:
    if m.attrs.isStatic and m.kind in {nsnFieldDecl, nsnPropertyDecl}:
      continue   ## a module global, below
    if m.kind == nsnFieldDecl:
      let defs = newNodeI(nkIdentDefs, m.info)
      defs.add l.exportedName(m.attrs, m.name, m.info)
      defs.add l.typeToNim(m.typ, m.info)
      defs.add empty(m.info)
      recList.add defs
    elif m.kind == nsnPropertyDecl and isAutoProperty(m):
      let defs = newNodeI(nkIdentDefs, m.info)
      defs.add l.id(m.name & "Backing", m.info)
      defs.add l.typeToNim(m.typ, m.info)
      defs.add empty(m.info)
      recList.add defs
  let objTy = newNodeI(nkObjectTy, n.info)
  objTy.add empty(n.info)
  if n.typ != nil:
    objTy.add newTree(nkOfInherit, n.info, l.objTypeToNim(n.typ, n.info))
  else:
    # A base-less class is a `ref object`, a base-less struct a value `object`,
    # but both are a System.Object in C#, so both derive from the root.
    objTy.add newTree(nkOfInherit, n.info, l.id("RootObj", n.info))
  objTy.add recList
  let typeValue =
    if isClass and not isException: newTree(nkRefTy, n.info, objTy)
    else: objTy
  let td = newNodeI(nkTypeDef, n.info)
  td.add l.exportedName(n.attrs, n.name, n.info)
  td.add l.genericParams(l.clsTypeParams, n.info)
  td.add typeValue
  let sec = newNodeI(nkTypeSection, n.info)
  sec.add td
  into.add sec
  if not isClass and l.scope.isMarshalableStruct(n.name):
    ## A struct C can take: its C mirror, for P/Invoke from any module.
    l.cStructMirror(n, into)

  # 2. static storage and the initialisers: instance ones run in every
  #    constructor, static ones and the static constructor in `nsStaticInit<C>`.
  var fieldInits: seq[PNode] = @[]
  var staticInits: seq[PNode] = @[]
  block:
    var inner = l
    inner.thisName = "self"
    for m in n.sons:
      if m.kind == nsnFieldDecl and m.attrs.isStatic:
        var st = l
        st.thisName = ""
        st.lowerStaticField(n, m, staticInits, into)
      elif m.kind == nsnPropertyDecl and m.attrs.isStatic and isAutoProperty(m):
        var st = l
        st.thisName = ""
        st.emitStaticStorage(staticStorageName(n.name, m.name & "Backing"), m.typ,
                             m.body, m.info, staticInits, into)
      elif m.kind == nsnFieldDecl and m.body != nil:
        fieldInits.add newTree(nkAsgn, m.info,
                               newTree(nkDotExpr, m.info, l.id("self", m.info),
                                       l.id(m.name, m.info)),
                               inner.expr(m.body))
      elif m.kind == nsnPropertyDecl and m.body != nil and isAutoProperty(m):
        fieldInits.add newTree(nkAsgn, m.info,
                               newTree(nkDotExpr, m.info, l.id("self", m.info),
                                       l.id(m.name & "Backing", m.info)),
                               inner.expr(m.body))

  # 3. members, in source order (Nim resolves `self.Prop` dot-calls against
  #    declarations seen so far, so a property must precede its users)
  var hasCtor = false
  for m in n.sons:
    var inner = l
    inner.frameScope = l.frameOwner(n) & ".<" & memberFrameName(m) & ">"
    inner.frameCount = new int
    inner.frameLocals = new Table[string, int]
    let firstProc = into.len
    defer: l.nameFrames(n, m, into[firstProc .. ^1])
    if m.kind == nsnMethodDecl and m.attrs.isExtern and m.hasAttribute("DllImport"):
      l.pinvokeMethod(n, m, into)
      continue
    case m.kind
    of nsnMethodDecl:
      inner.thisName = if m.attrs.isStatic: "" else: "self"
      for t in m.typeParams: inner.procTypeParams.add t.name
      var params = l.formalParams(m.typ, m.params, m.info)
      if m.paramMod == "ref":
        ## `ref T M()`: a `var T` result, which a caller may assign or take.
        params[0] = newTree(nkVarTy, m.info, params[0])
      if m.name == "Main" and m.attrs.isStatic:
        # entry point: parameters are ignored, it is called as `Main()`
        params = newNodeI(nkFormalParams, m.info)
        params.add l.typeToNim(m.typ, m.info)
      elif m.attrs.isStatic and m.params.len > 0 and m.params[0].paramMod == "this":
        ## An extension method is a plain proc over its `this` parameter, so
        ## `M(x, args)` and Nim's own `x.M(args)` both reach it.
        discard
      else:
        ## An instance method takes `self`; a static one its class's `typedesc`,
        ## so it is called `M(C, args)` and never competes, through Nim's dot-call,
        ## with a member of its first argument's type.
        let np = newNodeI(nkFormalParams, m.info)
        np.add params[0]
        np.add (if m.attrs.isStatic: l.typedescDefs(n.name, m.info)
                else: l.selfDefs(n.name, isException, m.info,
                                 mutable = m.strVal == "mutating"))
        for i in 1 ..< params.len: np.add params[i]
        params = np
      ## `R I.M()` is reachable only through `I`, so it gets a name of its own that
      ## only the interface table uses.
      let nameNode =
        if m.explicitIface.len > 0: l.id("ns" & m.explicitIface & "_" & m.name, m.info)
        else: l.exportedName(m.attrs, m.name, m.info)
      ## C# lets a call statement drop a method's result.
      let pd = l.asMethod(n, m, inner.mkProc(nameNode, params,
                                             inner.memberBody(m.typ, m.body, m.params),
                                             m.info, withPragmas = true))
      let sc = l.staticCtorCall(m.info)
      if sc != nil and m.attrs.isStatic and pd[6].kind == nkStmtList:
        pd[6].sons.insert(sc, 0)
      into.add pd
      if m.name == "Main" and m.attrs.isStatic and m.params.len > 0 and
         pd[6].kind == nkStmtList:
        ## `Main(string[] args)` is called without arguments; `args` is the
        ## command line, read where the body starts.
        pd[6].sons.insert(newTree(nkLetSection, m.info, newTree(nkIdentDefs, m.info,
          l.id(m.params[0].name, m.info), empty(m.info),
          newTree(nkCall, m.info, l.id("nsCommandLine", m.info)))), 0)
      if m.name == "Main" and l.entryPoint == nil: l.entryPoint = pd
      let ew = l.exportWrapper(n, m)
      if ew != nil: into.add ew
      if m.attrs.isStatic and m.hasAttribute("UnmanagedCallersOnly"):
        into.add l.unmanagedEntry(n, m)
    of nsnPropertyDecl:
      inner.thisName = (if m.attrs.isStatic: "" else: "self")
      for p in inner.lowerProperty(n, m, isException): into.add l.asMethod(n, m, p)
    of nsnOperatorDecl:
      inner.thisName = ""
      for p in inner.lowerOperator(n, m): into.add p
    of nsnIndexerDecl:
      inner.thisName = "self"
      for p in inner.lowerIndexer(n, m, isException): into.add p
    of nsnCtorDecl:
      if m.attrs.isStatic and genericStaticCtor(n) != nil:
        ## Each instantiation runs it once, the first time it is used: a generic
        ## proc whose `{.global.}` flag belongs to the instantiation. The flag is
        ## set first, so the statics it touches do not call it again.
        inner.thisName = ""
        let info = m.info
        let body = newNodeI(nkStmtList, info)
        body.add newTree(nkVarSection, info, newTree(nkIdentDefs, info,
          newTree(nkPragmaExpr, info, l.id("nsRan", info),
                  newTree(nkPragma, info, l.id("global", info))),
          empty(info), l.id("false", info)))
        let run = newTree(nkStmtList, info,
                          newTree(nkAsgn, info, l.id("nsRan", info), l.id("true", info)))
        if m.body != nil:
          for st in m.body.sons: run.add inner.stmt(st)
        body.add newTree(nkIfStmt, info, newTree(nkElifBranch, info,
          newTree(nkPrefix, info, l.id("not", info), l.id("nsRan", info)), run))
        let fp = newNodeI(nkFormalParams, info)
        fp.add empty(info)
        var pl = inner
        pl.procTypeParams = l.clsTypeParams
        into.add pl.mkProc(newTree(nkPostfix, info, l.id("*", info),
                                   l.id("nsStaticCtor_" & n.name, info)), fp, body, info)
        continue
      if m.attrs.isStatic:
        ## The static constructor runs once, after the static initialisers.
        inner.thisName = ""
        if m.body != nil:
          for st in m.body.sons: staticInits.add inner.stmt(st)
        continue
      hasCtor = true
      inner.thisName = "self"
      into.add inner.lowerInit(n, m, isException, mappedBase, fieldInits)
      into.add inner.lowerAllocator(n, m, isException)
    of nsnFieldDecl: discard
    else: discard

  if l.lazyStaticCtor(n):
    ## Run on first use, once: the static field initialisers in order, then the
    ## static constructor's body. The flag is set first, so the statics they touch
    ## do not run it again.
    let info = n.info
    let fp = newNodeI(nkFormalParams, info)
    fp.add empty(info)
    let body = newNodeI(nkStmtList, info)
    body.add newTree(nkVarSection, info, newTree(nkIdentDefs, info,
      newTree(nkPragmaExpr, info, l.id("nsRan", info),
              newTree(nkPragma, info, l.id("global", info))),
      empty(info), l.id("false", info)))
    let run = newTree(nkStmtList, info,
                      newTree(nkAsgn, info, l.id("nsRan", info), l.id("true", info)))
    for st in staticInits: run.add st
    body.add newTree(nkIfStmt, info, newTree(nkElifBranch, info,
      newTree(nkPrefix, info, l.id("not", info), l.id("nsRan", info)), run))
    var nl = l
    nl.procTypeParams = @[]
    let sc = nl.mkProc(newTree(nkPostfix, info, l.id("*", info),
                               l.id("nsStaticCtor_" & n.name, info)), fp, body, info)
    l.framed(sc, l.frameOwner(n) & "..cctor()")
    into.add sc
  elif staticInits.len > 0:
    let fp = newNodeI(nkFormalParams, n.info)
    fp.add empty(n.info)
    let body = newNodeI(nkStmtList, n.info)
    for st in staticInits: body.add st
    var nl = l
    nl.procTypeParams = @[]
    let si = nl.mkProc(l.id("nsStaticInit" & n.name, n.info), fp, body, n.info)
    l.framed(si, l.frameOwner(n) & "..cctor()")
    l.staticInits.add si

  # `new T()` in generic code reaches a parameterless constructor through this.
  var paramless = not hasCtor
  for m in n.sons:
    if m.kind == nsnCtorDecl and not m.attrs.isStatic and m.params.len == 0:
      paramless = true
  if paramless and not (n.attrs.isAbstract):
    let info = n.info
    let fp = newNodeI(nkFormalParams, info)
    fp.add (if isException: newTree(nkRefTy, info, l.clsType(n.name, info))
            else: l.clsType(n.name, info))
    fp.add l.typedescDefs(n.name, info)
    var callee = l.id("new" & n.name, info)
    if l.clsTypeParams.len > 0:
      callee = newTree(nkBracketExpr, info, callee)
      for t in l.clsTypeParams: callee.add l.id(t, info)
    let cr = l.mkProc(l.alwaysExported("nsCreate", info), fp,
                      newTree(nkStmtList, info, newTree(nkCall, info, callee)), info)
    l.unframed(cr)
    into.add cr

  # 4. the implicit constructor pair when none was declared
  if not hasCtor:
    let info = n.info
    let baseParamless =
      mappedBase.len == 0 or not l.scope.classes.hasKey(mappedBase) or
      l.scope.classes[mappedBase].ctorArities.len == 0 or
      0 in l.scope.classes[mappedBase].ctorArities
    let ip = newNodeI(nkFormalParams, info)
    ip.add empty(info)
    ip.add l.selfDefs(n.name, isException, info, mutable = true)
    let ibody = newNodeI(nkStmtList, info)
    for f in fieldInits: ibody.add copyTree(f)
    if mappedBase.len > 0 and baseParamless and
       (l.scope.classes.hasKey(mappedBase) or
        not l.surface.isExceptionType(mappedBase, l.scope.baseChain(mappedBase))):
      let icall = newNodeI(nkCall, info)
      icall.add l.id("init" & mappedBase, info)
      icall.add l.id("self", info)
      ibody.add icall
    let ini = l.mkProc(l.alwaysExported("init" & n.name, info), ip, ibody, info,
                       withPragmas = true)
    l.framed(ini, l.frameOwner(n) & "..ctor()")
    into.add ini
    let ap = newNodeI(nkFormalParams, info)
    ap.add (if isException: newTree(nkRefTy, info, l.clsType(n.name, info))
            else: l.clsType(n.name, info))
    let abody = newNodeI(nkStmtList, info)
    if isClass:
      let nc = newNodeI(nkCall, info)
      nc.add l.id("new", info)
      nc.add l.id("result", info)
      abody.add nc
    if isException: abody.add l.defaultMessage(n, info)
    let fw = newNodeI(nkCall, info)
    fw.add l.id("init" & n.name, info)
    fw.add l.id("result", info)
    abody.add fw
    let alloc = l.mkProc(l.alwaysExported("new" & n.name, info), ap, abody, info,
                         withPragmas = true)
    l.unframed(alloc)
    into.add alloc

# --- module -----------------------------------------------------------------

proc lowerDecl(l: var Lowerer; d: NsNode; into: var seq[PNode]) =
  case d.kind
  of nsnUsing:
    ## Lowers `using A.B;` to `import "A/B"`, so the namespace is in scope only
    ## where the directive appears. Recorded as well, so a member reached in this
    ## module is not named again by a `from` when its namespace is already here.
    if d.name.len > 0 and d.name in l.ownNamespaces:
      ## A namespace this file declares is lowered into this module already.
      discard
    elif d.name.len > 0:
      l.usingPaths.incl namespaceModulePath(d.name)
      into.add newTree(nkImportStmt, d.info,
                       newAtom(nkStrLit, namespaceModulePath(d.name), d.info))
  of nsnNamespace:
    ## Namespaces are flattened; they carry no scope of their own yet.
    let saved = l.curNamespace
    l.curNamespace = d.name
    if d.body != nil:
      for x in d.body.sons: lowerDecl(l, x, into)
    l.curNamespace = saved
  of nsnClassDecl:
    if d.classKind == ckInterface: lowerInterface(l, d, into)
    else: lowerClass(l, d, into)
  of nsnEnumDecl: l.lowerEnum(d, into)
  of nsnDelegateDecl: into.add l.lowerDelegate(d)
  else: into.add l.stmt(d)

proc isImportStmt*(n: PNode): bool =
  ## An import, which both halves of a namespace module need: the declarations may
  ## name imported types and the implementations imported procs.
  n.kind in {nkImportStmt, nkImportExceptStmt, nkFromStmt}

proc makeMainCall(l: Lowerer; procDef: PNode): PNode =
  ## `when isMainModule: Main()`
  let info = procDef.info
  let call = newNodeI(nkCall, info)
  call.add l.id("Main", info)
  let body = newNodeI(nkStmtList, info)
  body.add call
  result = newTree(nkWhenStmt, info,
                   newTree(nkElifBranch, info, l.id("isMainModule", info), body))

# --- redundant nil checks -----------------------------------------------------
#
# Lowering checks a reference at each member access (`nsCheckNilVar(x).f`), as C#
# throws there. Within a routine, a local once checked stays non-nil until it is
# assigned, so the later checks are dropped. Conservatively: only the routine's own
# locals and parameters, never one a closure captures; a check inside a branch, a
# block, a loop or a `try` holds only there; a local passed bare to a call may be a
# `var`/`out` argument, so it is forgotten; a loop starts without the locals it
# assigns.

proc nsIdentName(n: PNode): string =
  if n == nil: return ""
  case n.kind
  of nkIdent: n.ident.s
  of nkPostfix: (if n.len > 1: nsIdentName(n[1]) else: "")
  of nkPragmaExpr: (if n.len > 0: nsIdentName(n[0]) else: "")
  else: ""

proc nsAssignedIn(n: PNode; into: var HashSet[string]) =
  ## Every local a statement may change: assigned, declared, passed bare to a call
  ## or taken the address of.
  if n == nil: return
  case n.kind
  of nkAsgn, nkFastAsgn:
    let nm = nsIdentName(n[0])
    if nm.len > 0: into.incl nm
  of nkIdentDefs, nkVarTuple:
    for k in 0 ..< n.len - 2: into.incl nsIdentName(n[k])
  of nkCall, nkCommand:
    if n.len > 0 and n[0].kind == nkIdent and n[0].ident.s == "nsCheckNilVar": return
    for k in 1 ..< n.len:
      if n[k].kind == nkIdent: into.incl n[k].ident.s
  of nkAddr, nkHiddenAddr:
    let nm = nsIdentName(n[0])
    if nm.len > 0: into.incl nm
  of nkForStmt:
    for k in 0 ..< n.len - 2: into.incl nsIdentName(n[k])
  else: discard
  if n.kind notin {nkProcDef, nkMethodDef, nkFuncDef, nkIteratorDef, nkConverterDef,
                   nkLambda, nkDo, nkTemplateDef, nkMacroDef}:
    for i in 0 ..< n.safeLen: nsAssignedIn(n[i], into)

proc nsCapturedIn(n: PNode; nested: bool; into: var HashSet[string]) =
  ## The names a nested routine mentions: a closure may change them at any call.
  if n == nil: return
  if n.kind == nkIdent and nested: into.incl n.ident.s
  let inner = nested or n.kind in {nkProcDef, nkMethodDef, nkFuncDef, nkIteratorDef,
                                   nkConverterDef, nkLambda, nkDo}
  for i in 0 ..< n.safeLen: nsCapturedIn(n[i], inner, into)

proc nsLocalsIn(n: PNode; into: var HashSet[string]) =
  ## The routine's own locals and parameters (not those of routines inside it).
  if n == nil: return
  case n.kind
  of nkIdentDefs, nkVarTuple:
    for k in 0 ..< n.len - 2: into.incl nsIdentName(n[k])
  of nkForStmt:
    for k in 0 ..< n.len - 2: into.incl nsIdentName(n[k])
  of nkProcDef, nkMethodDef, nkFuncDef, nkIteratorDef, nkConverterDef, nkLambda, nkDo,
     nkTemplateDef, nkMacroDef:
    return
  else: discard
  for i in 0 ..< n.safeLen: nsLocalsIn(n[i], into)

proc elideIn(n: PNode; facts: var HashSet[string]; tracked: HashSet[string]): PNode

proc elideRoutine(n: PNode) =
  ## A routine's body, with its own locals tracked from nothing known.
  if n.len <= 6 or n[6].kind == nkEmpty: return
  var tracked = initHashSet[string]()
  nsLocalsIn(n[3], tracked)
  nsLocalsIn(n[6], tracked)
  var captured = initHashSet[string]()
  nsCapturedIn(n[6], false, captured)
  for c in captured: tracked.excl c
  var facts = initHashSet[string]()
  n[6] = elideIn(n[6], facts, tracked)

proc elideIn(n: PNode; facts: var HashSet[string]; tracked: HashSet[string]): PNode =
  result = n
  if n == nil: return
  case n.kind
  of nkProcDef, nkMethodDef, nkFuncDef, nkIteratorDef, nkConverterDef, nkLambda, nkDo:
    elideRoutine(n)
  of nkTemplateDef, nkMacroDef: discard
  of nkCall, nkCommand:
    if n.len == 2 and n[0].kind == nkIdent and n[0].ident.s == "nsCheckNilVar" and
       n[1].kind == nkIdent and n[1].ident.s in tracked:
      let nm = n[1].ident.s
      if nm in facts: return n[1]
      facts.incl nm
      return n
    for i in 0 ..< n.len: n[i] = elideIn(n[i], facts, tracked)
    for k in 1 ..< n.len:
      if n[k].kind == nkIdent: facts.excl n[k].ident.s
  of nkAsgn, nkFastAsgn:
    n[1] = elideIn(n[1], facts, tracked)
    n[0] = elideIn(n[0], facts, tracked)
    let nm = nsIdentName(n[0])
    if nm.len > 0: facts.excl nm
  of nkIdentDefs, nkVarTuple:
    n[^1] = elideIn(n[^1], facts, tracked)
    for k in 0 ..< n.len - 2: facts.excl nsIdentName(n[k])
  of nkInfix:
    if n.len == 3 and n[0].kind == nkIdent and n[0].ident.s in ["and", "or"]:
      n[1] = elideIn(n[1], facts, tracked)
      var side = facts
      n[2] = elideIn(n[2], side, tracked)
    else:
      for i in 0 ..< n.len: n[i] = elideIn(n[i], facts, tracked)
  of nkIfStmt, nkIfExpr, nkCaseStmt, nkTryStmt, nkBlockStmt, nkBlockExpr, nkWhenStmt:
    ## The first condition (or the selector) always runs; anything inside holds
    ## only there.
    var changed = initHashSet[string]()
    nsAssignedIn(n, changed)
    var first = 0
    if n.kind in {nkIfStmt, nkIfExpr} and n.len > 0 and n[0].len == 2:
      n[0][0] = elideIn(n[0][0], facts, tracked)
      var inside = facts
      n[0][1] = elideIn(n[0][1], inside, tracked)
      first = 1
    elif n.kind == nkCaseStmt and n.len > 0:
      n[0] = elideIn(n[0], facts, tracked)
      first = 1
    for i in first ..< n.len:
      var inside = facts
      n[i] = elideIn(n[i], inside, tracked)
    for c in changed: facts.excl c
  of nkWhileStmt, nkForStmt:
    var changed = initHashSet[string]()
    nsAssignedIn(n, changed)
    for c in changed: facts.excl c
    var inside = facts
    for i in 0 ..< n.len: n[i] = elideIn(n[i], inside, tracked)
  else:
    for i in 0 ..< n.safeLen: n[i] = elideIn(n[i], facts, tracked)

# --- bounds checks in counted loops -------------------------------------------
#
# `for (int i = 0; i < a.Length; i++)` over an array the body never replaces, with a
# counter the body never changes, keeps `i` inside the array: `forToNim` marks the
# loop `while nsForBound(i, a, cond)`, and here `a[i]` in its body reads the element
# unchecked -- when `i` and `a` are the routine's own, no closure captures them, and
# `a` is not a `var` parameter, which something else could replace. The marker
# itself is dropped either way.

proc nsUncheckedIn(n: PNode; a, i: string; cache: IdentCache): PNode =
  result = n
  if n == nil: return
  case n.kind
  of nkProcDef, nkMethodDef, nkFuncDef, nkIteratorDef, nkConverterDef, nkLambda, nkDo,
     nkTemplateDef, nkMacroDef:
    return
  of nkBracketExpr:
    if n.len == 2 and n[0].kind == nkIdent and n[0].ident.s == a and
       n[1].kind == nkIdent and n[1].ident.s == i:
      return newTree(nkCall, n.info, newIdentNode(cache.getIdent("nsAtUnchecked"), n.info),
                     n[0], n[1])
  else: discard
  for k in 0 ..< n.safeLen: n[k] = nsUncheckedIn(n[k], a, i, cache)

proc boundsIn(n: PNode; owned: HashSet[string]; cache: IdentCache)

proc boundsRoutine(n: PNode; cache: IdentCache) =
  ## A routine: its own locals and parameters, less those a closure captures and
  ## its `var` parameters.
  if n.len <= 6 or n[6].kind == nkEmpty: return
  var owned = initHashSet[string]()
  nsLocalsIn(n[3], owned)
  nsLocalsIn(n[6], owned)
  var captured = initHashSet[string]()
  nsCapturedIn(n[6], false, captured)
  for c in captured: owned.excl c
  if n[3].kind == nkFormalParams:
    for k in 1 ..< n[3].len:
      let d = n[3][k]
      if d.kind == nkIdentDefs and d.len >= 2 and d[^2].kind == nkVarTy:
        for j in 0 ..< d.len - 2: owned.excl nsIdentName(d[j])
  boundsIn(n[6], owned, cache)

proc boundsIn(n: PNode; owned: HashSet[string]; cache: IdentCache) =
  if n == nil: return
  case n.kind
  of nkProcDef, nkMethodDef, nkFuncDef, nkIteratorDef, nkConverterDef, nkLambda, nkDo:
    boundsRoutine(n, cache)
    return
  of nkTemplateDef, nkMacroDef: return
  of nkWhileStmt:
    let c = n[0]
    if c.kind == nkCall and c.len == 4 and c[0].kind == nkIdent and
       c[0].ident.s == "nsForBound":
      let i = c[1].ident.s
      let a = c[2].ident.s
      n[0] = c[3]
      if i in owned and a in owned:
        n[1] = nsUncheckedIn(n[1], a, i, cache)
  else: discard
  for k in 0 ..< n.safeLen: boundsIn(n[k], owned, cache)

proc elideBounds(n: PNode; cache: IdentCache) =
  ## Every routine of the module.
  if n == nil: return
  case n.kind
  of nkProcDef, nkMethodDef, nkFuncDef, nkIteratorDef, nkConverterDef:
    boundsRoutine(n, cache)
  else:
    for i in 0 ..< n.safeLen: elideBounds(n[i], cache)

proc elideNilChecks(n: PNode) =
  ## Every routine of the module.
  if n == nil: return
  case n.kind
  of nkProcDef, nkMethodDef, nkFuncDef, nkIteratorDef, nkConverterDef:
    elideRoutine(n)
  else:
    for i in 0 ..< n.safeLen: elideNilChecks(n[i])

proc typeName(n: PNode): string =
  ## The name a type is written with: `Dog`, `Bag[T]`, `Ns.Dog`, `Dog*`.
  case n.kind
  of nkIdent: n.ident.s
  of nkSym: n.sym.name.s
  of nkAccQuoted: (if n.len > 0: typeName(n[0]) else: "")
  of nkPostfix: (if n.len > 1: typeName(n[1]) else: "")
  of nkPragmaExpr: (if n.len > 0: typeName(n[0]) else: "")
  of nkBracketExpr, nkPtrTy, nkRefTy, nkVarTy: (if n.len > 0: typeName(n[0]) else: "")
  of nkDotExpr: (if n.len > 0: typeName(n[^1]) else: "")
  else: ""

proc classDepths(types: PNode): Table[string, int] =
  ## How deep in its hierarchy each object type of the type section is: 0 for
  ## one without a base the section declares.
  var bases = initTable[string, string]()
  for td in types:
    if td.kind != nkTypeDef or td.len < 3: continue
    var nameNode = td[0]
    if nameNode.kind == nkPragmaExpr: nameNode = nameNode[0]
    if nameNode.kind == nkPostfix: nameNode = nameNode[1]
    var body = td[2]
    while body.kind in {nkRefTy, nkPtrTy} and body.len > 0: body = body[0]
    if body.kind == nkObjectTy and body.len > 1 and body[1].kind == nkOfInherit and
       body[1].len > 0:
      bases[typeName(nameNode)] = typeName(body[1][0])
  result = initTable[string, int]()
  for name in bases.keys:
    var d = 0
    var cur = name
    while bases.hasKey(cur) and d <= bases.len:
      cur = bases[cur]
      inc d
    result[name] = d

proc substTypes(n: PNode; names: seq[string]; args: seq[PNode]): PNode =
  ## `n` with each type parameter named in `names` replaced by its argument.
  if n.kind == nkIdent:
    let k = names.find(n.ident.s)
    return (if k >= 0 and k < args.len: copyTree(args[k]) else: copyTree(n))
  result = copyNode(n)
  for i in 0 ..< n.safeLen: result.add substTypes(n[i], names, args)

proc genericParamNames(gp: PNode): seq[string] =
  ## `[T, U]` of a type or routine: its parameters' names, in order.
  result = @[]
  if gp.kind != nkGenericParams: return
  for d in gp:
    if d.kind == nkIdentDefs:
      for i in 0 ..< d.len - 2: result.add typeName(d[i])
    else: result.add typeName(d)

proc genericBases(types: PNode): Table[string, PNode] =
  ## For each class of the section that is not generic itself, the nearest base up
  ## its chain that is an instance of a generic class (`Repo[int32]`).
  var direct = initTable[string, PNode]()
  var generic = initHashSet[string]()
  for td in types:
    if td.kind != nkTypeDef or td.len < 3: continue
    var nameNode = td[0]
    if nameNode.kind == nkPragmaExpr: nameNode = nameNode[0]
    if nameNode.kind == nkPostfix: nameNode = nameNode[1]
    if td[1].kind == nkGenericParams and td[1].len > 0: generic.incl typeName(nameNode)
    var body = td[2]
    while body.kind in {nkRefTy, nkPtrTy} and body.len > 0: body = body[0]
    if body.kind == nkObjectTy and body.len > 1 and body[1].kind == nkOfInherit and
       body[1].len > 0:
      direct[typeName(nameNode)] = body[1][0]
  result = initTable[string, PNode]()
  for name in direct.keys:
    if name in generic: continue
    var cur = name
    var hops = 0
    while direct.hasKey(cur) and hops <= direct.len:
      let b = direct[cur]
      if b.kind == nkBracketExpr:
        result[name] = b
        break
      cur = typeName(b)
      inc hops

proc hasPragma(r: PNode; name: string): bool =
  let pr = r[pragmasPos]
  if pr.kind != nkPragma: return false
  for x in pr:
    if x.kind == nkIdent and x.ident.s == name: return true
  false

proc instantiateBase(l: Lowerer; r: PNode; base: PNode;
                     names: seq[string] = @[]; args: seq[PNode] = @[]): PNode =
  ## Nim attaches an override to a generic base method only once that method is
  ## instantiated for the base's type arguments, which nothing has done when the
  ## override is declared: `static: discard compiles(M(Repo[int32](nil), ...))`
  ## does it first, so `Repo<int> r = new IntRepo(); r.M()` dispatches.
  var name = r[namePos]
  if name.kind == nkPostfix: name = name[1]
  let info = r.info
  let call = newTree(nkCall, info, copyTree(name),
                     newTree(nkCall, info, copyTree(base), newNodeI(nkNilLit, info)))
  let params = r[paramsPos]
  for i in 2 ..< params.len:
    let defs = params[i]
    if defs.kind != nkIdentDefs: return nil
    var t = substTypes(defs[^2], names, args)
    if t.kind == nkVarTy and t.len > 0: t = t[0]
    if t.kind == nkEmpty: return nil
    for _ in 0 ..< defs.len - 2:
      call.add newTree(nkCall, info, l.id("default", info),
                       copyTree(t))
  result = newTree(nkStaticStmt, info, newTree(nkStmtList, info,
    newTree(nkDiscardStmt, info, newTree(nkCall, info,
      l.id("compiles", info), call))))

proc receiverName(r: PNode): string =
  ## The type of a routine's first parameter, which a method dispatches on.
  let params = r[paramsPos]
  if params.kind == nkFormalParams and params.len > 1 and params[1].kind == nkIdentDefs:
    typeName(params[1][^2])
  else: ""

# --- per-iteration variables -----------------------------------------------
#
# C# gives each iteration of a loop its own copy of the variables declared in the
# loop's body, and of a `foreach` variable (ECMA-334 13.9.5), so a lambda created
# in one iteration keeps that iteration's variable. Nim lifts every captured local
# of a routine into one environment, which all iterations share. So a loop-body
# variable a lambda captures is kept in a heap cell (`var x = nsCellOf(v)`, used as
# `x[]`), and the lambda is made by a factory that takes the cells as parameters
# (`(proc (x: typeof(x)): auto = <lambda>)(x)`): each closure keeps its own
# iteration's cell, and a write after the lambda is made is still seen by it, as
# C#'s capture by reference has it.

type
  NsCellDecl = ref object
    node: NsNode        ## the nsnLocalDecl / nsnForeach / nsnParam declaring it
    inLoop: bool        ## declared in a loop body of its routine or lambda
    level: int          ## how many lambdas (or local functions) enclose it
  NsCellFrame = object
    node: NsNode
    isLambda: bool      ## a lambda, which gets a factory; a local function parameters
  NsCellWalk = object
    scopes: seq[Table[string, NsCellDecl]]
    loop: int
    frames: seq[NsCellFrame]
    mark: bool          ## the second pass: every use of a cell reads through it

proc cellResolve(w: NsCellWalk; name: string): NsCellDecl =
  for i in countdown(w.scopes.high, 0):
    if w.scopes[i].hasKey(name): return w.scopes[i][name]
  nil

proc cellDeclare(w: var NsCellWalk; name: string; node: NsNode; inLoop: bool) =
  if name.len == 0 or w.scopes.len == 0: return
  w.scopes[^1][name] = NsCellDecl(node: node, inLoop: inLoop, level: w.frames.len)

proc cellWalk(w: var NsCellWalk; n: NsNode)

proc cellWalkStmts(w: var NsCellWalk; list: seq[NsNode]) =
  ## A statement list is a scope: a declaration is seen by the statements after it,
  ## and a local function by the whole block.
  w.scopes.add initTable[string, NsCellDecl]()
  for x in list:
    if x != nil and x.kind == nsnLocalFunc: w.cellDeclare(x.name, x, false)
  for x in list: w.cellWalk(x)
  discard w.scopes.pop

proc cellWalkRoutine(w: var NsCellWalk; n: NsNode; frame: bool; isLambda: bool) =
  ## A routine, lambda or local function: its parameters, then its body, with the
  ## loop depth counted afresh.
  let savedLoop = w.loop
  w.loop = 0
  if frame: w.frames.add NsCellFrame(node: n, isLambda: isLambda)
  w.scopes.add initTable[string, NsCellDecl]()
  for p in n.params:
    if p != nil and p.kind == nsnParam: w.cellDeclare(p.name, p, false)
    else: w.cellWalk(p)
  w.cellWalk(n.body)
  for x in n.sons: w.cellWalk(x)
  discard w.scopes.pop
  if frame: discard w.frames.pop
  w.loop = savedLoop

proc cellWalk(w: var NsCellWalk; n: NsNode) =
  if n == nil: return
  case n.kind
  of nsnIdent:
    let d = w.cellResolve(n.name)
    if d == nil: return
    if w.mark:
      if d.node.cell and n.paramMod.len == 0: n.paramMod = "deref"
      elif d.node.kind == nsnLocalFunc and d.node.captures.len > 0 and n.paramMod.len == 0:
        ## A local function taking cells: a call passes them, a delegate binds them.
        n.paramMod = "cells"
        n.argParam = d.node
    elif d.inLoop and d.level < w.frames.len and d.node.kind in {nsnLocalDecl, nsnForeach}:
      ## Captured across a lambda or local function boundary from a loop body: each
      ## one in between takes the cell, a lambda from its factory and a local
      ## function as a parameter its callers pass.
      d.node.cell = true
      for k in d.level ..< w.frames.len:
        if n.name notin w.frames[k].node.captures: w.frames[k].node.captures.add n.name
    elif d.node.kind == nsnLocalFunc:
      ## Naming a local function that takes cells uses them here.
      for c in d.node.captures:
        w.cellWalk(nsnIdent(c, n.info))
  of nsnLocalDecl:
    w.cellWalk(n.body)
    ## A `ref` local is a pointer already; a constant is never captured as a variable.
    w.cellDeclare(n.name, n, w.loop > 0 and n.paramMod.len == 0 and n.declKind == dkVar)
  of nsnMultiDecl:
    for x in n.sons: w.cellWalk(x)
  of nsnOutDecl, nsnPatType, nsnPatVar:
    ## Declared by an expression; not made a cell (its lowering declares it).
    w.cellDeclare(n.name, n, false)
  of nsnBlock, nsnBlockStmt:
    w.cellWalkStmts(n.sons)
  of nsnFor:
    w.scopes.add initTable[string, NsCellDecl]()
    let h = n.body
    if h != nil and h.sons.len > 0: w.cellWalk(h.sons[0])   ## shared by the iterations
    inc w.loop
    if h != nil:
      for i in 1 ..< h.sons.len: w.cellWalk(h.sons[i])
    w.cellWalkStmts(n.sons)
    dec w.loop
    discard w.scopes.pop
  of nsnForeach:
    w.cellWalk(n.body)
    inc w.loop
    w.scopes.add initTable[string, NsCellDecl]()
    ## The enumerator form and a handle loop variable declare it their own way.
    w.cellDeclare(n.name, n, n.strVal != "GetEnumerator")
    w.cellWalkStmts(n.sons)
    discard w.scopes.pop
    dec w.loop
  of nsnWhile, nsnDoWhile:
    w.cellWalk(n.body)
    inc w.loop
    w.cellWalkStmts(n.sons)
    dec w.loop
  of nsnIfBranch:
    w.cellWalk(n.body)
    w.cellWalkStmts(n.sons)
  of nsnElseBranch:
    w.cellWalkStmts(n.sons)
  of nsnCatch:
    w.scopes.add initTable[string, NsCellDecl]()
    w.cellDeclare(n.name, n, false)
    w.cellWalk(n.body)
    for x in n.sons: w.cellWalk(x)
    discard w.scopes.pop
  of nsnUsingStmt:
    w.scopes.add initTable[string, NsCellDecl]()
    for x in n.sons: w.cellWalk(x)
    w.cellWalk(n.body)
    discard w.scopes.pop
  of nsnLambda:
    w.cellWalkRoutine(n, true, true)
  of nsnLocalFunc:
    w.cellDeclare(n.name, n, false)
    w.cellWalkRoutine(n, true, false)
  of nsnMethodDecl, nsnCtorDecl, nsnOperatorDecl, nsnIndexerDecl:
    w.cellWalkRoutine(n, false, false)
  else:
    w.cellWalk(n.body)
    for x in n.sons: w.cellWalk(x)
    for x in n.inits: w.cellWalk(x)
    for x in n.initArgs: w.cellWalk(x)
    for x in n.params: w.cellWalk(x)

proc markLoopCells(module: NsNode) =
  ## Finds the loop-body variables lambdas capture, then marks every use of them.
  ## The first pass runs twice: a local function may be named before the walk
  ## reaches the cells its body takes.
  for mark in [false, false, true]:
    var w = NsCellWalk(mark: mark)
    w.scopes.add initTable[string, NsCellDecl]()
    w.cellWalk(module)

proc renameMemberDecls(l: Lowerer; module: PNode) =
  ## The declarations of the members `memberIdent` renames: their routines (and
  ## setters, `X=`), and fields of that name, which the same accesses reach.
  proc renamed(l: Lowerer; n: PNode): PNode =
    ## `X` / `X=` / `X*` as its `nsM_` spelling, or nil when it is not renamed.
    case n.kind
    of nkIdent:
      let s = n.ident.s
      let base = (if s.endsWith("="): s[0 ..< ^1] else: s)
      if base in l.imports.memberRenames:
        return l.id("nsM_" & s, n.info)
    of nkPostfix:
      let r = l.renamed(n[1])
      if r != nil: return newTree(nkPostfix, n.info, n[0], r)
    of nkAccQuoted:
      if n.len == 1:
        let r = l.renamed(n[0])
        if r != nil: return newTree(nkAccQuoted, n.info, r)
    of nkPragmaExpr:
      let r = l.renamed(n[0])
      if r != nil: return newTree(nkPragmaExpr, n.info, r, n[1])
    else: discard
    nil
  proc ownReceiver(n: PNode): bool =
    ## `self` / `result` (or a conversion or cast of one): this class's object, so
    ## a member the lowering generated against it is one of its own.
    case n.kind
    of nkIdent: n.ident.s in ["self", "result"]
    of nkCall, nkCast, nkHiddenStdConv, nkConv:
      n.len > 0 and ownReceiver(n[^1])
    else: false
  proc walk(l: Lowerer; n: PNode) =
    case n.kind
    of nkProcDef, nkMethodDef, nkFuncDef, nkTemplateDef, nkIteratorDef, nkConverterDef:
      let r = l.renamed(n[namePos])
      if r != nil: n[namePos] = r
      for i in 1 ..< n.len: l.walk(n[i])
    of nkRecList:
      for i in 0 ..< n.len:
        if n[i].kind == nkIdentDefs:
          for k in 0 ..< n[i].len - 2:
            let r = l.renamed(n[i][k])
            if r != nil: n[i][k] = r
        else: l.walk(n[i])
    of nkDotExpr:
      if n.len == 2 and ownReceiver(n[0]):
        let r = l.renamed(n[1])
        if r != nil: n[1] = r
      for i in 0 ..< n.len: l.walk(n[i])
    else:
      for i in 0 ..< n.safeLen: l.walk(n[i])
  l.walk(module)

proc lowerModule*(module: NsNode; scope: NsModuleScope;
                  cache: IdentCache; config: ConfigRef): PNode =
  ## Lowers a whole `.ns` module to the Nim statements the rest of the compiler
  ## consumes.
  var l = Lowerer(scope: scope, surface: bclSurface(config), cache: cache,
                  counter: new int,
                  imports: NsFromImports(byModule: initTable[string, seq[string]]()),
                  usingPaths: initHashSet[string](),
                  hoist: NsHoist(moves: initTable[string, bool]()),
                  nilChecks: optNilCheck in config.options)
  var stmts: seq[PNode] = @[]
  proc noteOwn(n: NsNode; into: var HashSet[string]) =
    if n.kind == nsnNamespace:
      into.incl n.name
      if n.body != nil:
        for x in n.body.sons: noteOwn(x, into)
  for d in module.sons: noteOwn(d, l.ownNamespaces)
  markLoopCells(module)
  ## Types and members of one name (`Color Color`): see `memberRenames`.
  for cn, cls in l.scope.classes:
    l.imports.userTypes.incl cn
  for e in l.scope.enums: l.imports.userTypes.incl e
  for d in l.scope.delegates.keys: l.imports.userTypes.incl d
  for cn, cls in l.scope.classes:
    for m in cls.members:
      if (m.isMethod or m.isProperty or m.isEvent) and m.name in l.imports.userTypes:
        l.imports.memberRenames.incl m.name
  renameResultLocals(module)
  renameResultArgs(module)
  for d in module.sons:
    l.lowerDecl(d, stmts)
  if l.pinvokeLinked > 0:
    ## The assembler name of a C function, with the platform's prefix (`_` on
    ## macOS): `__asm__(NS_ASMNAME("strlen"))`.
    stmts.add newTree(nkPragma, module.info, newTree(nkExprColonExpr, module.info,
      l.id("emit", module.info), newStrNode(nkStrLit, "/*TYPESECTION*/\n" &
        "#ifndef NS_ASMNAME\n#define NS_ASMNAME3(p, n) #p n\n" &
        "#define NS_ASMNAME2(p, n) NS_ASMNAME3(p, n)\n" &
        "#define NS_ASMNAME(n) NS_ASMNAME2(__USER_LABEL_PREFIX__, n)\n#endif\n")))
  if l.pinvokeLoaded:
    stmts.add newTree(nkImportStmt, module.info, newStrNode(nkStrLit, "nsharp/pinvoke"))
  ## A namespace of the tree reached only qualified (`Tools.Widget.Make()`): its
  ## members are in scope, its types that would clash are not, and are named
  ## qualified (`Tools.Console`).
  ## Not imported when every name it was found by is a local or member of that name
  ## (`var Tools = ...; Tools.Length`).
  for ns in l.scope.qualifiedNs:
    let path = namespaceModulePath(ns)
    let head = ns.split('.')[0]
    if ns in l.ownNamespaces or l.usingPaths.contains(path) or
       (head in l.scope.qualifiedShadowed and head notin l.scope.qualifiedUsed): continue
    let clashing = l.scope.qualifiedExcept.getOrDefault(ns)
    let imp = newNodeI((if clashing.len > 0: nkImportExceptStmt else: nkImportStmt), module.info)
    imp.add newAtom(nkStrLit, path, module.info)
    for c in clashing: imp.add l.id(c, module.info)
    stmts.add imp
  result = newNodeI(nkStmtList, module.info)
  ## Every module sees the N# intrinsics, so `"a" + b` concatenates and any type
  ## can be printed without a `using`.
  result.add newTree(nkImportStmt, module.info,
                     newAtom(nkStrLit, NsIntrinsicsPath, module.info))
  ## A prelude declaration a member access reached is named by the module that
  ## declares it, since Nim resolves a proc where it is used. A namespace this
  ## module already imports needs no naming, and the order is sorted, so the output
  ## does not depend on the order the members were lowered in.
  var modules: seq[string] = @[]
  for m in l.imports.byModule.keys:
    if not l.usingPaths.contains(m): modules.add m
  modules.sort()
  for m in modules:
    let f = newNodeI(nkFromStmt, module.info)
    f.add newAtom(nkStrLit, m, module.info)
    var names = l.imports.byModule[m]
    if names.len > 0:
      for x in l.surface.unnamedMembersOf(m):
        if x notin names: names.add x
    names.sort()
    for n in names:
      ## An operator is quoted, so the module reads back when it is rendered.
      if n[0] in {'a'..'z', 'A'..'Z', '_'}: f.add l.id(n, module.info)
      else: f.add newTree(nkAccQuoted, module.info, l.id(n, module.info))
    ## Named only qualified (`Ns.T`): the module, and nothing in scope.
    if names.len == 0: f.add newNodeI(nkNilLit, module.info)
    result.add f
  ## C# arithmetic is unchecked unless it is written inside `checked`, so the module
  ## turns the check off and `checked { }` pushes it back on (§7.3).
  result.add l.checkPush(false, module.info)
  ## Declarations first, then every routine forward declared, then the rest in
  ## source order. C# members may name each other in any order, and Nim resolves a
  ## name against what precedes it, so this is what lets a member call one declared
  ## after it, and a derived class come before its base.
  var routines: seq[PNode] = @[]
  const declKinds = {nkTypeSection, nkVarSection, nkConstSection, nkTemplateDef,
                     nkImportStmt, nkImportExceptStmt, nkFromStmt}
  for s in stmts:
    if isImportStmt(s): result.add s
  ## One type section: Nim resolves a type that names a later one only within a
  ## section, and C# types name each other in any order.
  let types = newNodeI(nkTypeSection, module.info)
  for s in stmts:
    if s.kind == nkTypeSection:
      for t in s: types.add t
  if types.len > 0: result.add types
  for s in stmts:
    if s.kind in declKinds and s.kind != nkTypeSection and not isImportStmt(s):
      result.add s
  for f in l.familyProcs: result.add f
  for p in l.nativeProcs: result.add p
  for p in l.staticInits: routines.add p
  for s in stmts:
    if s.kind in {nkProcDef, nkMethodDef, nkConverterDef}: routines.add s
  ## Nim attaches a method to the base method declared before it, so the methods
  ## are declared base class first, whatever order the classes are written in.
  let depths = classDepths(types)
  proc depthOf(r: PNode): int = depths.getOrDefault(receiverName(r), 0)
  ## Only the methods move, among their own slots, so the rest keeps its order.
  var slots: seq[int] = @[]
  var methods: seq[PNode] = @[]
  for i, r in routines:
    if r.kind == nkMethodDef:
      slots.add i
      methods.add r
  methods.sort(proc (a, b: PNode): int = cmp(depthOf(a), depthOf(b)))
  for k, i in slots: routines[i] = methods[k]
  ## An override of a generic class's method (`IntRepo : Repo<int>`) links to the
  ## base method's instance, so that instance must exist when the override is
  ## declared, and both before any routine calls through the base is checked.
  ## Making an instance needs the bodies of every generic routine it may reach. So:
  ## the declarations; every generic routine's definition (which instantiates
  ## nothing); the instances (`instantiateBase`); such an override's declaration;
  ## then the rest of the definitions in source order.
  let genBases = genericBases(types)
  var late: seq[PNode] = @[]       ## overrides of a generic base's methods
  proc isGenericMethod(r: PNode): bool =
    r.kind == nkMethodDef and r[genericParamsPos].kind == nkGenericParams
  ## A generic class's override reaches its instance's dispatch only once Nim has
  ## made that instance, after the base method's: for every instance the program
  ## names (`Wrapper<string>`), each generic method of the class and of its
  ## generic bases is instantiated, base first.
  var instanceForces: seq[PNode] = @[]
  var typeDefs = initTable[string, PNode]()
  for td in types:
    if td.kind == nkTypeDef: typeDefs[typeName(td[0])] = td
  proc baseOfDef(td: PNode): PNode =
    var body = td[2]
    while body.kind in {nkRefTy, nkPtrTy} and body.len > 0: body = body[0]
    if body.kind == nkObjectTy and body.len > 1 and body[1].kind == nkOfInherit and
       body[1].len > 0: body[1][0] else: nil
  for inst in l.imports.instances:
    var chain: seq[PNode] = @[]
    var cur = inst
    var hops = 0
    while cur != nil and cur.kind == nkBracketExpr and typeDefs.hasKey(typeName(cur)) and
          hops < 32:
      chain.insert(cur, 0)
      let td = typeDefs[typeName(cur)]
      let b = baseOfDef(td)
      cur = (if b == nil: nil
             else: substTypes(b, genericParamNames(td[1]), cur.sons[1 .. ^1]))
      inc hops
    for c in chain:
      for r in routines:
        if r.isGenericMethod and receiverName(r) == typeName(c):
          let force = l.instantiateBase(r, c, genericParamNames(r[genericParamsPos]),
                                        c.sons[1 .. ^1])
          if force != nil: instanceForces.add force
  ## Identity, not structure: a routine defined early is skipped where it would be.
  var early = initHashSet[int]()
  for r in routines:
    if r.kind == nkMethodDef and not r.hasPragma("base") and
       not r.isGenericMethod and genBases.hasKey(receiverName(r)):
      late.add r
      continue
    if r[6].kind == nkEmpty:
      ## No body (a P/Invoke `importc` proc): its own declaration, once.
      result.add r
      early.incl cast[int](r)
      continue
    let fwd = copyTree(r)
    fwd[6] = newNodeI(nkEmpty, r.info)
    result.add fwd
  if late.len > 0 or instanceForces.len > 0:
    ## A type's `nsTypeOf` first: a generic class's name names its arguments', so
    ## an instance made here reaches theirs, which name nothing of the module.
    for r in routines:
      var name = r[namePos]
      if name.kind == nkPostfix: name = name[1]
      if name.kind == nkIdent and name.ident.s == "nsTypeOf" and cast[int](r) notin early:
        result.add r
        early.incl cast[int](r)
    for r in routines:
      if r[genericParamsPos].kind == nkGenericParams and cast[int](r) notin early:
        result.add r
        early.incl cast[int](r)
    for f in instanceForces: result.add f
    for r in late:
      let force = l.instantiateBase(r, genBases[receiverName(r)])
      if force != nil: result.add force
      let fwd = copyTree(r)
      fwd[6] = newNodeI(nkEmpty, r.info)
      result.add fwd
  ## Static initialisers run before any statement of the program, top-level ones
  ## included; their bodies may name anything, since everything is declared above.
  for p in l.staticInits:
    result.add newTree(nkCall, p.info, copyTree(p[0]))
  for s in stmts:
    if s.kind notin declKinds and cast[int](s) notin early:
      result.add s
  for p in l.staticInits: result.add p
  if l.entryPoint != nil:
    result.add makeMainCall(l, l.entryPoint)
  if l.nilChecks: elideNilChecks(result)
  elideBounds(result, l.cache)
  if l.imports.memberRenames.len > 0: l.renameMemberDecls(result)

