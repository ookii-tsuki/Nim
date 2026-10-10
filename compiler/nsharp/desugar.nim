# N# frontend - lowering to Nim
#
# The C#-to-Nim translation: NsNode in, ordinary Nim PNodes out. The name mapping
# itself lives in bcl.nim.
#
# Methods get no `discardable` pragma while generated `init`/`new` procs do (see
# procPragmas). C# would allow discarding a method's result, so this asymmetry is
# a fidelity bug, not a design choice.

import std/[strutils, tables, algorithm, sets]
import ../ast, ../idents, ../lineinfos, ../options
import ast, bcl, symbols

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
    entryPoint: PNode       ## the emitted `Main` proc, if there was one
    staticInits: seq[PNode]
      ## One `nsStaticInit<C>` proc per class with static initialisers or a static
      ## constructor. They are emitted after every declaration and called before
      ## `Main`, so they may name any member of the module.
    nilChecks: bool         ## whether the compilation has the nil check on
    curClass: NsNode        ## the class whose members are being lowered
    curBase: string         ## its base class, for `base.M()`
    curIsException: bool    ## whether it is lowered as a value object raised by `ref`
    curNamespace: string    ## the enclosing namespace, for `object.ToString()`
    clsTypeParams: seq[string]
      ## the type parameters of the class being lowered: its own name is `C[T]`
    procTypeParams: seq[string]
      ## the generic parameters a routine emitted now takes (class's, then method's)

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


proc exportId(l: Lowerer; name: string; info: TLineInfo): PNode =
  newTree(nkPostfix, info, l.id("*", info), l.id(name, info))


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
    l.imports.note(m.path, m.name)
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
    let pr = newNodeI(nkPragma, def.info)
    pr.add l.id("base", def.info)
    result[4] = pr
  if m.attrs.isAbstract:
    let raiseCall = newNodeI(nkCall, def.info)
    raiseCall.add l.id("newException", def.info)
    raiseCall.add l.id("Defect", def.info)
    raiseCall.add newAtom(nkStrLit, "abstract member called: " & m.name, def.info)
    result[6] = newTree(nkStmtList, def.info, newTree(nkRaiseStmt, def.info, raiseCall))

proc baseConv(l: Lowerer; info: TLineInfo): PNode =
  ## `this` seen as its base class: `Base(self)`, or `(ref Base)(self)` for an
  ## exception class, whose `self` is a `ref`.
  let target =
    if l.curIsException: newTree(nkRefTy, info, l.id(nimTypeName(l.curBase), info))
    else: l.id(nimTypeName(l.curBase), info)
  result = newTree(nkCall, info, (if l.curIsException: newTree(nkPar, info, target)
                                  else: target), l.id("self", info))

proc baseCall(l: Lowerer; name: string; args: seq[PNode]; info: TLineInfo): PNode =
  ## `base.M(args)`: `procCall M(Base(self), args)`, which calls the base's own
  ## implementation instead of dispatching again.
  let call = newNodeI(nkCall, info)
  call.add l.id(name, info)
  call.add l.baseConv(info)
  for a in args: call.add a
  result = newTree(nkCommand, info, l.id("procCall", info), call)

# (interfaces: see below)
# --- types ------------------------------------------------------------------

proc typeToNim(l: Lowerer; t: NsNode; info: TLineInfo): PNode =
  ## C# type reference to Nim type expression. `nsnEmpty`/`nsnVoidType` become
  ## `nkEmpty`, which is how "no type" is spelled in a Nim parameter list.
  if t == nil: return empty(info)
  case t.kind
  of nsnEmpty, nsnVoidType:
    result = empty(info)
  of nsnArrayType:
    result = newTree(nkBracketExpr, info, l.id("seq", info),
                     l.typeToNim(t.typ, info))
  of nsnNullableType:
    ## A value type needs `Option`; a reference is nullable already, so `Node?` is
    ## just `Node`, which is how C# reads it.
    if t.typeKind == tkNullable:
      result = newTree(nkBracketExpr, info, l.id("Option", info),
                       l.typeToNim(t.typ, info))
    else:
      result = l.typeToNim(t.typ, info)
  of nsnTypeName:
    var name = nimTypeName(t.name)
    ## `Func<T, R>`: a name C# overloads by arity is declared once per arity by the
    ## library, with the arity as a suffix (`Func2`), and that declaration is used.
    let arity = name & $t.sons.len
    if not l.scope.classes.hasKey(name) and l.surface.types.hasKey(arity):
      name = arity
    result = l.id(name, info)
    if t.sons.len > 0:
      let be = newNodeI(nkBracketExpr, info)
      be.add result
      for a in t.sons: be.add l.typeToNim(a, info)
      result = be
  else:
    result = empty(info)

proc expr(l: Lowerer; n: NsNode): PNode

proc paramDef(l: Lowerer; p: NsNode): PNode =
  ## One parameter: `ref`/`out` are Nim `var` parameters (`in` is a read-only
  ## reference, which a Nim parameter already is), `params T[]` is `varargs[T]`,
  ## and a default value is Nim's.
  result = newNodeI(nkIdentDefs, p.info)
  result.add l.id(p.name, p.info)
  var t = l.typeToNim(p.typ, p.info)
  case p.paramMod
  of "ref", "out": t = newTree(nkVarTy, p.info, t)
  of "params":
    if p.typ != nil and p.typ.kind == nsnArrayType:
      t = newTree(nkBracketExpr, p.info, l.id("varargs", p.info),
                  l.typeToNim(p.typ.typ, p.info))
  else: discard
  result.add t
  result.add (if p.body != nil: l.expr(p.body) else: empty(p.info))

proc exportedName(l: Lowerer; attrs: NsAttrs; name: string; info: TLineInfo): PNode =
  ## A C# member is exported to Nim unless it is private.
  if attrs.isExported:
    result = newTree(nkPostfix, info, l.id("*", info), l.id(name, info))
  else:
    result = l.id(name, info)


proc procPragmas(l: Lowerer; params: PNode; info: TLineInfo): PNode =
  ## `discardable` for value-returning *generated* procs (`init`/`new`). Methods
  ## and property accessors pass `withPragmas = false`, reproducing the previous
  ## emitter; see the module note.
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
proc presentOf(l: Lowerer; v: NsNode; info: TLineInfo): PNode
proc wrappedArg(l: Lowerer; a: NsNode): PNode

proc lambdaToNim(l: Lowerer; n: NsNode): PNode =
  ## A lambda as a Nim closure. `sema.nim` wrote the types of the delegate it
  ## converts to; one it could not place keeps `auto`, which Nim infers when the
  ## lambda is passed where a concrete proc type is expected.
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
  result[6] = if n.body != nil: l.stmtSeq(n.body) else: emptyList(n.info)

proc argsToNim(l: Lowerer; call: NsNode): seq[PNode] =
  ## A call's arguments, each with the conversion `sema.nim` chose.
  result = @[]
  for a in call.sons: result.add l.wrappedArg(a)

proc newToNim(l: Lowerer; n: NsNode): PNode =
  ## `new T(args)` becomes `newT(args)`, carrying generic arguments over.
  if n.typ != nil and n.typ.kind == nsnTypeName and n.typ.name in l.procTypeParams:
    ## `new T()` on a type parameter (`where T : new()`): every class declares
    ## `nsCreate` over its typedesc, and the intrinsics do for value types.
    return newTree(nkCall, n.info, l.id("nsCreate", n.info), l.id(n.typ.name, n.info))
  var callee =
    if n.typ != nil and n.typ.kind == nsnTypeName:
      l.id("new" & nimTypeName(n.typ.name), n.info)
    else:
      l.id("new", n.info)
  if n.typ != nil and n.typ.kind == nsnTypeName and n.typ.sons.len > 0:
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
  info.isMethod and info.isStatic and m.name != "Main"

proc typeRef(l: Lowerer; t: NsNode): PNode =
  ## A type used as a value (a static member's receiver): `C`, or `C[int32]` when it
  ## carries type arguments.
  result = l.id(nimTypeName(t.typeName), t.info)
  if t.typeArgs.len > 0:
    result = newTree(nkBracketExpr, t.info, result)
    for a in t.typeArgs: result.add l.typeToNim(a, t.info)

proc callToNim(l: Lowerer; n: NsNode): PNode =
  var callee = n.body
  if callee != nil and callee.kind == nsnMember and callee.body != nil and
     callee.body.kind == nsnBase:
    ## `base.M(args)` calls the base implementation, never the override.
    var args: seq[PNode] = @[]
    for a in l.argsToNim(n): args.add a
    return l.baseCall(callee.name, args, n.info)
  ## `Class.Method(...)` / `Console.WriteLine(...)`: the qualifier is dropped,
  ## because it is a namespace or a static class. `sema.nim` decides this and
  ## records it as `tkType`.
  if callee != nil and callee.kind == nsnMember and callee.body != nil and
     callee.body.typeKind == tkType and l.isUserStatic(callee):
    ## `C.M(args)` on a class this compilation declares: `M(C, args)`, the
    ## class's typedesc first, with any written type arguments.
    let head =
      if callee.typeArgs.len > 0:
        let h = newTree(nkBracketExpr, n.info, l.id(callee.name, n.info))
        for t in callee.typeArgs: h.add l.typeToNim(t, n.info)
        h
      else: l.id(callee.name, n.info)
    result = newTree(nkCall, n.info, head, l.typeRef(callee.body))
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
      result.add l.id(callee.name, n.info)
    else:
      let head = newTree(nkBracketExpr, n.info, l.id(callee.name, n.info))
      if clsTps.len > 0:
        for t in recvArgs: head.add l.typeToNim(t, n.info)
      for t in callee.typeArgs: head.add l.typeToNim(t, n.info)
      result.add head
    var recv = l.expr(callee.body)
    if l.nilChecks and l.nilableReceiver(callee.body):
      recv = newTree(nkCall, n.info, l.id("nsCheckNil", n.info), recv)
    result.add recv
    for a in l.argsToNim(n): result.add a
    return
  if l.nilChecks and callee.kind == nsnMember and l.nilableReceiver(callee.body):
    let checked = newNodeI(nkCall, n.info)
    checked.add l.id("nsCheckNil", n.info)
    checked.add l.expr(callee.body)
    result.add newTree(nkDotExpr, n.info, checked, l.id(callee.name, n.info))
  else:
    result.add l.expr(callee)
  for a in l.argsToNim(n): result.add a

proc staticMethodGroup(l: Lowerer; n: NsNode): PNode =
  ## `IntFn f = Double;`: the method's parameters, forwarded with the class first.
  let m = l.scope.findMemberInfo(n.body.typeName, n.name)
  let fp = newNodeI(nkFormalParams, n.info)
  fp.add l.typeToNim(m.typ, n.info)
  let call = newTree(nkCall, n.info, l.id(n.name, n.info), l.typeRef(n.body))
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
                                             l.id(n.name, n.info)))
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
  (if op.name == "implicit": "nsImplicit_" else: "nsExplicit_") & mangleType(op.typ)


proc castToNim(l: Lowerer; n: NsNode): PNode =
  ## `(T)x` is a Nim conversion, and also how a ref object is downcast. A `T?`
  ## operand is unwrapped first, since the conversion applies to the value. A cast
  ## through a user-defined conversion calls the operator.
  if n.argParam != nil and n.argParam.kind == nsnOperatorDecl:
    return newTree(nkCall, n.info, l.id(conversionProcName(n.argParam), n.info),
                   l.expr(n.body))
  result = newNodeI(nkCall, n.info)
  result.add l.typeToNim(n.typ, n.info)
  if n.body != nil and n.body.typeKind == tkNullable:
    result.add l.presentOf(n.body, n.info)
  else:
    result.add l.expr(n.body)

proc asToNim(l: Lowerer; n: NsNode): PNode =
  ## `x as T` yields nil instead of raising, and reads its operand once. The block
  ## scopes the temporary, so two of them in one body cannot collide.
  let defs = newNodeI(nkIdentDefs, n.info)
  defs.add l.id("nsAs", n.info)
  defs.add newNodeI(nkEmpty, n.info)
  defs.add l.expr(n.body)
  let cond = newNodeI(nkInfix, n.info)
  cond.add l.id("of", n.info)
  cond.add l.id("nsAs", n.info)
  cond.add l.typeToNim(n.typ, n.info)
  let conv = newNodeI(nkCall, n.info)
  conv.add l.typeToNim(n.typ, n.info)
  conv.add l.id("nsAs", n.info)
  let inner = newNodeI(nkStmtList, n.info)
  inner.add newTree(nkLetSection, n.info, defs)
  inner.add newTree(nkIfExpr, n.info,
                    newTree(nkElifExpr, n.info, cond, conv),
                    newTree(nkElseExpr, n.info, newNodeI(nkNilLit, n.info)))
  result = newNodeI(nkBlockExpr, n.info)
  result.add empty(n.info)
  result.add inner

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
    if spelled.len > 0: return l.id(spelled, n.info)
  l.expr(n.body)

proc nilableReceiver(l: Lowerer; n: NsNode): bool =
  ## True for a receiver the nil check may test: a declared *class*. A struct is a
  ## value, so it can never be nil, and `this` is a parameter a method body cannot
  ## see as nil without the call-site check having fired first.
  if n == nil or n.kind in {nsnThis, nsnBase}: return false
  if n.typeKind != tkClass: return false
  let name = n.typeName
  name.len > 0 and l.scope.classes.hasKey(name) and
    l.scope.classes[name].classKind == ckClass

proc memberReceiverChecked(l: Lowerer; n: NsNode): PNode =
  ## A field access on a class reference tests the receiver first, so dereferencing
  ## null raises `NullReferenceException` instead of faulting. C# tests at the
  ## access, and `-d:danger` / `--nilChecks:off` turn the whole check off.
  result = l.memberReceiver(n)
  if l.nilChecks and l.nilableReceiver(n.body):
    let checked = newNodeI(nkCall, n.info)
    checked.add l.id("nsCheckNil", n.info)
    checked.add result
    result = checked

proc condTail(l: Lowerer; nd: NsNode; absent: PNode): PNode =
  ## The body of a `?.`: read the guarded value once, then either yield `absent` or
  ## evaluate the tail with the temporary as its receiver.
  let defs = newNodeI(nkIdentDefs, nd.info)
  defs.add l.id(NsCond, nd.info)
  defs.add newNodeI(nkEmpty, nd.info)
  defs.add l.expr(nd.body)
  let cond = newNodeI(nkInfix, nd.info)
  cond.add l.id("==", nd.info)
  cond.add l.id(NsCond, nd.info)
  cond.add newNodeI(nkNilLit, nd.info)
  var tailNim = absent
  if nd.sons.len > 0 and nd.sons[0] != nil:
    nd.sons[0] = replaceIdentical(nd.sons[0], nd.body, nsnIdent(NsCond, nd.info))
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

proc nullDotToNim(l: Lowerer; n: NsNode): PNode =
  ## `a?.B` on its own yields nil when the receiver is nil; a value-typed one is
  ## rejected by `sema.nim` unless a `??` supplies the absent value.
  result = l.condTail(n, newNodeI(nkNilLit, n.info))

proc nullCoalesceToNim(l: Lowerer; n: NsNode): PNode =
  ## `a ?? b` is `b` when `a` is absent. With a `?.` on the left, `b` is that
  ## chain's absent value, so the two lower into one block.
  if n.sons.len == 0: return empty(n.info)
  let lhs = n.sons[0]
  let fallback = if n.sons.len > 1: l.expr(n.sons[1]) else: newNodeI(nkNilLit, n.info)
  if lhs != nil and lhs.kind == nsnNullDot:
    result = l.condTail(lhs, fallback)
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

proc expr(l: Lowerer; n: NsNode): PNode =
  if n == nil: return newNodeI(nkEmpty, unknownLineInfo)
  case n.kind
  of nsnEmpty: result = empty(n.info)
  of nsnIdent:
    result = l.id(n.name, n.info)
    if n.typeArgs.len > 0:
      ## `Max<string>` / `Box<int>.Made`: the explicit type arguments.
      result = newTree(nkBracketExpr, n.info, result)
      for a in n.typeArgs: result.add l.typeToNim(a, n.info)
  of nsnThis:
    result = l.id(if l.thisName.len > 0: l.thisName else: "this", n.info)
  of nsnBase: result = l.baseConv(n.info)
  of nsnNull:
    if n.typeName.len > 0 and l.scope.isInterface(n.typeName):
      ## The empty interface value.
      result = newTree(nkCall, n.info, l.id("default", n.info), l.id(n.typeName, n.info))
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
         l.scope.classes.hasKey(n.body.typeName):
      ## `C.M` as a method group: a closure that calls `M(C, ...)`.
      result = l.staticMethodGroup(n)
    elif n.body != nil and n.typeKind == tkDelegate and n.body.typeKind == tkClass and
         l.scope.findMemberInfo(n.body.typeName, n.name).isMethod:
      ## `obj.M` as a method group: C# binds the receiver when the delegate is made,
      ## so it is read once into the closure's environment.
      result = l.instanceMethodGroup(n)
    else:
      l.noteMemberImport(n)
      result = newTree(nkDotExpr, n.info, l.memberReceiverChecked(n),
                       l.id(n.name, n.info))
  of nsnCall: result = l.callToNim(n)
  of nsnIndex:
    result = newTree(nkBracketExpr, n.info, l.expr(n.body))
    for i in n.sons: result.add l.expr(i)
  of nsnNew: result = l.newToNim(n)
  of nsnNewArray:
    let typ = newTree(nkBracketExpr, n.info, l.id("newSeq", n.info),
                      l.typeToNim(n.typ, n.info))
    result = newNodeI(nkCall, n.info)
    result.add typ
    result.add l.expr(n.sons[0])
  of nsnArrayLit:
    ## `new T[] { a, b }`: each element converted to `T`, as C# converts it, which
    ## for an interface is its converter and for a base class an upcast.
    let br = newNodeI(nkBracket, n.info)
    for e in n.sons:
      if n.typ != nil and n.typ.kind == nsnTypeName and e.kind != nsnNull:
        br.add newTree(nkCall, e.info, l.typeToNim(n.typ, e.info), l.expr(e))
      else:
        br.add l.expr(e)
    result = newTree(nkPrefix, n.info, l.id("@", n.info), br)
  of nsnUnary:
    result = newTree(nkPrefix, n.info, l.id(n.name, n.info), l.expr(n.body))
  of nsnIncDec:
    ## In an expression `x++` is the old value and `++x` the new one; the intrinsics
    ## carry both. As a statement it is Nim's own `inc`/`dec` (see `stmtInner`).
    let tmpl = (if n.strVal == "prefix": "nsPre" else: "nsPost") &
               (if n.name == "inc": "Inc" else: "Dec")
    result = newTree(nkCall, n.info, l.id(tmpl, n.info), l.expr(n.body))
  of nsnCast, nsnIs, nsnAs:
    result = l.ifaceTypeOp(n)
    if result != nil: discard
    elif n.kind == nsnIs:
      result = newTree(nkInfix, n.info, l.id(n.name, n.info), l.expr(n.body),
                       l.typeToNim(n.typ, n.info))
    elif n.kind == nsnAs: result = l.asToNim(n)
    else:
      result = l.castToNim(n)
  of nsnDefault:
    result = newNodeI(nkCall, n.info)
    result.add l.id("default", n.info)
    result.add l.typeToNim(n.typ, n.info)
  of nsnBinary:
    if n.name in ["==", "!="] and (l.isIfaceValue(n.sons[0]) or l.isIfaceValue(n.sons[1])):
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
    elif n.name in ["nsDiv", "nsMod"]:
      ## Integer `/` and `%` go through library procs, which are called rather
      ## than used as an infix operator.
      result = newNodeI(nkCall, n.info)
      result.add l.id(n.name, n.info)
      result.add l.expr(n.sons[0])
      result.add l.expr(n.sons[1])
    else:
      result = newTree(nkInfix, n.info, l.id(n.name, n.info),
                       l.expr(n.sons[0]), l.expr(n.sons[1]))
  of nsnNullDot: result = l.nullDotToNim(n)
  of nsnNullCoalesce: result = l.nullCoalesceToNim(n)
  of nsnTernary:
    result = newNodeI(nkIfExpr, n.info)
    result.add newTree(nkElifExpr, n.info, l.expr(n.sons[0]), l.expr(n.sons[1]))
    result.add newTree(nkElseExpr, n.info, l.expr(n.sons[2]))
  of nsnLambda: result = l.lambdaToNim(n)
  of nsnNamedArg: result = l.wrappedArg(n)
  of nsnIsPattern: result = l.isPatternToNim(n)
  of nsnSwitchExpr: result = l.switchExprToNim(n)
  of nsnRefArg: result = l.expr(n.body)
  of nsnOutDecl: result = l.id(n.name, n.info)   ## declared before the statement
  else: result = empty(n.info)
  if n.conv.len > 0:
    ## The implicit numeric conversion `sema.nim` recorded: C# promotes and widens
    ## where Nim wants the conversion spelled.
    result = newTree(nkCall, n.info, l.id(nimTypeName(n.conv), n.info), result)

# --- statements -------------------------------------------------------------

proc stmt(l: Lowerer; n: NsNode): PNode
proc stmtsToNode(l: Lowerer; stmts: seq[NsNode]; info: TLineInfo): PNode

proc stmtSeq(l: Lowerer; blk: NsNode): PNode =
  ## Lowers a `nsnBlock` to an `nkStmtList`.
  result = newNodeI(nkStmtList, if blk == nil: unknownLineInfo else: blk.info)
  if blk != nil:
    for s in blk.sons: result.add l.stmt(s)

proc stmtsToNode(l: Lowerer; stmts: seq[NsNode]; info: TLineInfo): PNode =
  result = newNodeI(nkStmtList, info)
  for s in stmts: result.add l.stmt(s)

proc throwToNim(l: Lowerer; n: NsNode): PNode =
  ## `throw new T(msg)`:
  ##   * external exception (system or a prelude exception) -> `newException(T, msg)`
  ##   * user-declared exception class -> raise the allocator result, which is
  ##     already a `ref T` because such a class is lowered as a value object.
  var e = l.expr(n.body)
  if n.body != nil and n.body.kind == nsnNew and n.body.typ != nil and
     n.body.typ.kind == nsnTypeName and
     not l.scope.classes.hasKey(n.body.typ.name):
    let msg =
      if n.body.sons.len > 0: l.expr(n.body.sons[0])
      else: newAtom(nkStrLit, "", n.info)
    let ne = newNodeI(nkCall, n.info)
    ne.add l.id("newException", n.info)
    ne.add l.id(nimTypeName(n.body.typ.name), n.info)
    ne.add msg
    e = ne
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
  of nsnPatAnd, nsnPatOr:
    for x in pat.sons: patternBindings(x, into)
  of nsnPatNot: patternBindings(pat.body, into)
  else: discard

proc bindingType(l: Lowerer; b: NsNode): PNode =
  ## The Nim type of a pattern variable: the pattern's type, or the subject's; an
  ## `out T x`'s is `T`.
  let t = (if b.kind in {nsnPatType, nsnPatProp, nsnOutDecl} and b.typ != nil: b.typ
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
  let subjIface = l.scope.isInterface(pat.typeName)
  let obj = (if subjIface: newTree(nkDotExpr, info, subj, l.id("nsObj", info))
             else: subj)
  if l.scope.isInterface(tname):
    let a = l.fresh("nsAs")
    var test = newTree(nkInfix, info, l.id("!=", info),
                       newTree(nkDotExpr, info, l.id(a, info), l.id("nsObj", info)),
                       newNodeI(nkNilLit, info))
    if bindName.len > 0:
      test = newTree(nkInfix, info, l.id("and", info), test,
                     l.assignTrue(bindName, l.id(a, info), info))
    return newTree(nkBlockExpr, info, empty(info), newTree(nkStmtList, info,
      newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(a, info), empty(info),
        newTree(nkCall, info, l.id("nsAs" & tname, info),
                newTree(nkCall, info, l.id("RootRef", info), copyTree(obj))))), test))
  let targetIsStruct = l.scope.classes.hasKey(tname) and
                       l.scope.classes[tname].classKind == ckStruct
  if subjIface or l.isRefKindName(pat.typeKind, pat.typeName) or
     pat.typeKind == tkUnknown and not targetIsStruct and
     l.surface.kindOfName(tname) notin {tkInt, tkFloat, tkBool, tkChar, tkString}:
    ## A reference: the object's dynamic type decides; null is never a `T`.
    let ofT = (if targetIsStruct: l.id("nsBox_" & tname, info)
               else: l.typeToNim(target, info))
    result = newTree(nkInfix, info, l.id("of", info), copyTree(obj), ofT)
    if bindName.len > 0:
      let conv = (if targetIsStruct:
                    newTree(nkDotExpr, info, newTree(nkCall, info, copyTree(ofT),
                                                     copyTree(obj)), l.id("v", info))
                  else: newTree(nkCall, info, l.typeToNim(target, info), copyTree(obj)))
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
      if l.scope.isInterface(pat.typeName):
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
  of nsnPatProp:
    ## `T { P: pat } p`: not null, of `T`, and each member matching its pattern.
    var parts: seq[PNode] = @[]
    var owner = subj
    let subjIface = l.scope.isInterface(pat.typeName)
    if subjIface:
      owner = newTree(nkDotExpr, info, copyTree(subj), l.id("nsObj", info))
    if pat.typ != nil:
      parts.add l.typeTest(subj, pat, pat.typ, "")
      let tname = canonicalTypeName(pat.typ.name)
      if l.scope.classes.hasKey(tname) and l.scope.classes[tname].classKind == ckStruct and
         (subjIface or l.isRefKindName(pat.typeKind, pat.typeName)):
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
                  nsnCatch, nsnFinally, nsnChecked, nsnUnchecked}:
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
                  nsnCatch, nsnFinally, nsnChecked, nsnUnchecked, nsnSwitchSection}:
      labelForContinues(n.body, label, found)

proc forToNim(l: Lowerer; n: NsNode): PNode =
  ## `for (init; cond; step) body` -> `block: (init; while cond: (body; step))`,
  ## since Nim has no C-style `for`.
  let header = n.body
  let blk = newNodeI(nkBlockStmt, n.info)
  blk.add empty(n.info)
  let sl = newNodeI(nkStmtList, n.info)
  if header != nil and header.sons.len > 0 and header.sons[0] != nil:
    sl.add l.stmt(header.sons[0])
  let w = newNodeI(nkWhileStmt, n.info)
  if header != nil and header.sons.len > 1 and header.sons[1] != nil:
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
    for s in n.sons: body.add l.stmt(s)
    wbody.add newTree(nkBlockStmt, n.info, l.id(label, n.info), body)
  else:
    for s in n.sons: wbody.add l.stmt(s)
  if hasStep:
    wbody.add l.stmt(header.sons[2])
  w.add wbody
  sl.add w
  blk.add sl
  result = blk

proc tryToNim(l: Lowerer; n: NsNode): PNode =
  result = newNodeI(nkTryStmt, n.info)
  result.add l.stmtSeq(n.body)
  for c in n.sons:
    if c.kind == nsnCatch:
      let br = newNodeI(nkExceptBranch, c.info)
      if c.typ != nil and c.typ.kind notin {nsnEmpty, nsnVoidType}:
        ## `except T as e`
        let asNode = newNodeI(nkInfix, c.info)
        asNode.add l.id("as", c.info)
        asNode.add l.typeToNim(c.typ, c.info)
        asNode.add l.id(c.name, c.info)
        br.add asNode
      br.add l.stmtSeq(c.body)
      result.add br
    elif c.kind == nsnFinally:
      let f = newNodeI(nkFinally, c.info)
      f.add l.stmtSeq(c.body)
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
  defs.add value
  let kind = case n.declKind
    of dkVar: nkVarSection
    of dkLet: nkLetSection
    of dkConst: nkConstSection
  result = newNodeI(kind, n.info)
  result.add defs

proc assignToNim(l: Lowerer; n: NsNode): PNode =
  ## The left side is lowered without the nil check, because `nsCheckNil(x).f` is
  ## not an lvalue; the check becomes a statement of its own instead, and only for a
  ## receiver that is a plain name, so no receiver is evaluated twice.
  var bare = l
  bare.nilChecks = false
  let lhs = bare.expr(n.sons[0])
  var value: PNode
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
    if n.strVal.len > 0:
      operand = newTree(nkCall, n.info, l.id(nimTypeName(n.strVal), n.info), operand)
    let rhs = l.expr(n.sons[1])
    if n.typeKind == tkInt and n.name in ["/", "mod"]:
      value = newTree(nkCall, n.info,
                      l.id((if n.name == "/": "nsDiv" else: "nsMod"), n.info),
                      operand, rhs)
    else:
      value = newTree(nkInfix, n.info, l.id(n.name, n.info), operand, rhs)
    if n.strVal.len > 0 and n.typeName.len > 0:
      value = newTree(nkCall, n.info, l.id(nimTypeName(n.typeName), n.info), value)
  let nullableTarget = n.sons[0] != nil and n.sons[0].typeKind == tkNullable
  let wrapTarget = nullableTarget and (n.name == "??" or
                                        n.sons[1].typeKind != tkNullable)
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
    let check = newNodeI(nkCall, n.info)
    check.add l.id("nsCheckNil", n.info)
    check.add bare.expr(target.body)
    result = newTree(nkStmtList, n.info,
                     newTree(nkDiscardStmt, n.info, check), result)

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
  for s in n.sons: body.add l.stmt(s)
  loop.add body
  scope.add loop
  result.add scope

proc checkedToNim(l: Lowerer; n: NsNode): PNode =
  ## C# turns overflow checking on inside `checked` and off inside `unchecked`,
  ## which is Nim's `overflowChecks` switch.
  result = newNodeI(nkStmtList, n.info)
  let push = newNodeI(nkPragma, n.info)
  push.add l.id("push", n.info)
  push.add newTree(nkExprColonExpr, n.info, l.id("overflowChecks", n.info),
                   l.id(if n.kind == nsnChecked: "on" else: "off", n.info))
  result.add push
  for s in n.sons: result.add l.stmt(s)
  let pop = newNodeI(nkPragma, n.info)
  pop.add l.id("pop", n.info)
  result.add pop

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

proc stmt(l: Lowerer; n: NsNode): PNode =
  if n == nil: return empty(unknownLineInfo)
  let outs = outDeclsOf(n)
  if outs.len == 0: return l.stmtInner(n)
  result = newNodeI(nkStmtList, n.info)
  l.bindingDecls(outs, result)
  result.add l.stmtInner(n)
  if n.kind in {nsnWhile, nsnDoWhile, nsnFor, nsnForeach, nsnSwitch}:
    ## A loop's or a switch's variables are scoped to it, not to the block.
    result = newTree(nkBlockStmt, n.info, empty(n.info), result)

proc localFuncToNim(l: Lowerer; n: NsNode): PNode =
  ## A local function is a nested proc, which captures what it names as a closure.
  var inner = l
  for t in n.typeParams: inner.procTypeParams.add t.name
  let fp = inner.formalParams(n.typ, n.params, n.info)
  inner.procTypeParams = @[]
  for t in n.typeParams: inner.procTypeParams.add t.name
  result = inner.mkProc(l.id(n.name, n.info), fp, inner.stmtSeq(n.body), n.info)

proc stmtInner(l: Lowerer; n: NsNode): PNode =
  case n.kind
  of nsnLocalFunc: result = l.localFuncToNim(n)
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
    if n.body != nil and n.body.kind == nsnIncDec:
      return newTree(nkCommand, n.info, l.id(n.body.name, n.info), l.expr(n.body.body))
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
    result = newNodeI(nkForStmt, n.info)
    result.add l.id(n.name, n.info)
    result.add l.expr(n.body)
    result.add l.stmtsToNode(n.sons, n.info)
  of nsnSwitch: result = l.switchToNim(n)
  of nsnTry: result = l.tryToNim(n)
  of nsnReturn:
    result = newNodeI(nkReturnStmt, n.info)
    result.add (if n.body == nil: empty(n.info) else: l.expr(n.body))
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
  else: result = l.expr(n)

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

proc lowerEnum(l: Lowerer; n: NsNode): PNode =
  let enumTy = newNodeI(nkEnumTy, n.info)
  enumTy.add empty(n.info)
  for f in n.sons:
    var field: PNode = l.id(f.name, f.info)
    if f.body != nil:
      let fd = newNodeI(nkEnumFieldDef, f.info)
      fd.add field
      fd.add l.expr(f.body)
      field = fd
    enumTy.add field
  let td = newNodeI(nkTypeDef, n.info)
  td.add l.exportedName(n.attrs, n.name, n.info)
  td.add empty(n.info)
  td.add enumTy
  result = newNodeI(nkTypeSection, n.info)
  result.add td

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
  ## `t: typedesc[C]`, the receiver of a static member, so `C.x` is Nim's dot-call.
  result = newNodeI(nkIdentDefs, info)
  result.add l.id("t", info)
  result.add newTree(nkBracketExpr, info, l.id("typedesc", info), l.clsType(cls, info))
  result.add empty(info)

proc staticStorageRef(l: Lowerer; storage: string; info: TLineInfo): PNode =
  ## The storage behind a static member: the global, or for a generic class the
  ## per-instantiation storage proc, `nsC_x[T]()`.
  if l.clsTypeParams.len == 0: return l.id(storage, info)
  let callee = newTree(nkBracketExpr, info, l.id(storage, info))
  for t in l.clsTypeParams: callee.add l.id(t, info)
  result = newTree(nkCall, info, callee)

proc staticAccessor(l: Lowerer; cls: string; m: NsNode; storage: string): PNode =
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
  result[6] = newTree(nkStmtList, m.info, l.staticStorageRef(storage, m.info))

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
    return
  let body = newNodeI(nkStmtList, info)
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
    into.add nl.staticAccessor(cls.name, m, storage)
    return
  l.emitStaticStorage(storage, m.typ, m.body, m.info, inits, into)
  into.add l.staticAccessor(cls.name, m, storage)

# --- properties -------------------------------------------------------------

proc lowerProperty(l: Lowerer; cls: NsNode; m: NsNode; isException: bool): seq[PNode] =
  ## A C# property becomes a getter named `P` and a setter named `P=`. An
  ## accessor written `get;`/`set;` reads and writes a generated `PBacking` field.
  result = @[]
  let getter = if m.params.len > 0: m.params[0] else: nil
  let setter = if m.params.len > 1: m.params[1] else: nil
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
      else: l.stmtSeq(getter)
    let gp = newNodeI(nkFormalParams, m.info)
    gp.add l.typeToNim(m.typ, m.info)
    gp.add copyTree(recvDefs)
    result.add l.mkProc(l.exportedName(m.attrs, m.name, m.info), gp, gbody, m.info)
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
    result.add l.mkProc(l.exportedName(m.attrs, m.name & "=", m.info), sp, sbody, m.info)

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
  let body = l.stmtSeq(m.body)
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
    result.add l.mkProc(l.exportedName(m.attrs, "[]", info), fp, l.stmtSeq(getter), info)
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
  for p in m.params: ip.add l.paramDef(p)
  let ibody = newNodeI(nkStmtList, m.info)
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
    if m.initArgs.len > 0:
      ibody.add newTree(nkAsgn, m.info,
                        newTree(nkDotExpr, m.info, l.id("self", m.info),
                                l.id("msg", m.info)),
                        l.expr(m.initArgs[0]))
  elif initName.len > 0:
    let icall = newNodeI(nkCall, m.info)
    icall.add l.id(initName, m.info)
    icall.add l.id("self", m.info)
    for a in m.initArgs: icall.add l.expr(a)
    ibody.add icall
  if m.body != nil:
    for s in m.body.sons: ibody.add l.stmt(s)
  result = l.mkProc(l.exportedName(m.attrs, "init" & cls.name, m.info), ip, ibody,
                    m.info, withPragmas = true)

proc lowerAllocator(l: Lowerer; cls, m: NsNode; isException: bool): PNode =
  ## `proc newC(params): C = new(result); initC(result, params)`. A struct is a
  ## value, already zero-initialised, so it needs no `new`.
  let ap = newNodeI(nkFormalParams, m.info)
  ap.add (if isException: newTree(nkRefTy, m.info, l.clsType(cls.name, m.info))
          else: l.clsType(cls.name, m.info))
  for p in m.params: ap.add l.paramDef(p)
  let abody = newNodeI(nkStmtList, m.info)
  if cls.classKind == ckClass:
    let newCall = newNodeI(nkCall, m.info)
    newCall.add l.id("new", m.info)
    newCall.add l.id("result", m.info)
    abody.add newCall
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
# whose entries call its own members -- which dispatch further when virtual -- and a
# `converter` from the class, so a class value is accepted wherever the interface is.
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
    call.add newTree(nkCall, info, l.id("nsCheckNil", info),
                     newTree(nkDotExpr, info, l.id("self", info), l.id("nsObj", info)))
    if m.kind == nsnMethodDecl:
      for p in m.params:
        fp.add l.identDefs(p.name, l.subType(p.typ, slot, info), info)
        call.add l.id(p.name, info)
    elif slot.setter:
      fp.add l.identDefs("value", l.subType(m.typ, slot, info), info)
      call.add l.id("value", info)
    let name = (if slot.setter: m.name & "=" else: m.name)
    into.add l.mkProc(l.exportId(name, info), fp, newTree(nkStmtList, info, call), info)
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

proc implementerFor(l: Lowerer; cls, m: NsNode; iface: string): string =
  ## The proc a table entry calls: the class's member, or its explicit `I.M`.
  for c in cls.sons:
    if c.name == m.name and c.explicitIface == iface: return "ns" & iface & "_" & m.name
  m.name

proc lowerImplementations(l: var Lowerer; n: NsNode; isException: bool;
                          into: var seq[PNode]) =
  ## For each interface the class names: a lazily filled table, a converter, and,
  ## for a non-generic interface, the `nsAs<I>` override. A struct is boxed:
  ## `nsBox_S` holds a copy, as C#'s box does.
  let info = n.info
  let ifaces = l.scope.directInterfaceTypes(n.name)
  if ifaces.len == 0: return
  let isStruct = n.classKind == ckStruct
  let boxName = "nsBox_" & n.name
  let boxType = l.ifaceTypeNim(boxName, tpNodes(l.clsTypeParams, info), info)
  if isStruct:
    let rec = newNodeI(nkRecList, info)
    let vd = l.identDefs("v", l.clsType(n.name, info), info)
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
      newTree(nkPrefix, info, l.id("$", info),
              newTree(nkDotExpr, info, l.id("self", info), l.id("v", info)))), info,
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
      let me = (if isStruct:
                  newTree(nkDotExpr, info, newTree(nkCall, info, copyTree(boxType),
                                                   l.id("self", info)), l.id("v", info))
                else: newTree(nkCall, info, (if isException: newTree(nkPar, info,
                                                copyTree(recvType)) else: copyTree(recvType)),
                              l.id("self", info)))
      let target = l.implementerFor(n, m, iface)
      var body: PNode
      if slot.setter:
        body = newTree(nkAsgn, info, newTree(nkDotExpr, info, me, l.id(m.name, info)),
                       l.id("value", info))
      else:
        let call = newNodeI(nkCall, info)
        call.add l.id(target, info)
        call.add me
        if m.kind == nsnMethodDecl:
          for p in m.params: call.add l.id(p.name, info)
        body = call
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
    into.add l.mkProc(l.exportId(getName, info), getFp, getBody, info)
    let getCall = l.getterCall(getName, info)
    # converter nsTo_<I>*(x: C): I
    let cfp = newNodeI(nkFormalParams, info)
    cfp.add l.ifaceTypeNim(iface, args, info)
    cfp.add l.identDefs("x", (if isException: newTree(nkRefTy, info, l.clsType(n.name, info))
                              else: l.clsType(n.name, info)), info)
    let objExpr = (if isStruct: newTree(nkObjConstr, info, copyTree(boxType),
                                        newTree(nkExprColonExpr, info, l.id("v", info),
                                                l.id("x", info)))
                   else: l.id("x", info))
    let make = newTree(nkObjConstr, info, l.ifaceTypeNim(iface, args, info),
      newTree(nkExprColonExpr, info, l.id("nsObj", info), objExpr),
      newTree(nkExprColonExpr, info, l.id("nsVt", info), copyTree(getCall)))
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

proc isIfaceType(l: Lowerer; t: NsNode): bool =
  t != nil and t.kind == nsnTypeName and l.scope.isInterface(canonicalTypeName(t.name))

proc isIfaceValue(l: Lowerer; e: NsNode): bool =
  e != nil and e.typeKind == tkClass and l.scope.isInterface(e.typeName)

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
    let probe = newTree(nkCall, info, l.id("nsAs" & iface, info), l.id("nsSrc", info))
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
    let isStruct = l.scope.classes.hasKey(target) and
                   l.scope.classes[target].classKind == ckStruct
    case n.kind
    of nsnIs:
      result = newTree(nkInfix, info, l.id("of", info), obj,
                       l.id((if isStruct: "nsBox_" & target else: nimTypeName(target)),
                            info))
    of nsnCast:
      if isStruct:
        result = newTree(nkDotExpr, info, newTree(nkCall, info,
                         l.id("nsBox_" & target, info), obj), l.id("v", info))
      else:
        result = newTree(nkCall, info, l.typeToNim(n.typ, info), obj)
    else: discard

# --- classes ----------------------------------------------------------------

proc alwaysExported(l: Lowerer; name: string; info: TLineInfo): PNode =
  ## The implicit constructor pair is always exported, as in the previous
  ## emitter, regardless of the class's own accessibility.
  result = newTree(nkPostfix, info, l.id("*", info), l.id(name, info))

proc objectToString(l: Lowerer; n: NsNode; isClass: bool): seq[PNode] =
  ## C#'s `object.ToString()` names the dynamic type, namespace included. A class
  ## that does not override it, and inherits no override from this compilation, gets
  ## a `method` that says so; a struct gets a proc, and `$` for both reaches it.
  result = @[]
  var overridden = false
  for c in l.scope.chain(n.name):
    for m in l.scope.classes[c].members:
      if m.name == "ToString" and m.isMethod and not m.isStatic: overridden = true
  let info = n.info
  let full = (if l.curNamespace.len > 0: l.curNamespace & "." & n.name else: n.name)
  let selfDefs = newNodeI(nkIdentDefs, info)
  selfDefs.add l.id("self", info)
  selfDefs.add l.clsType(n.name, info)
  selfDefs.add empty(info)
  if not overridden:
    let fp = newNodeI(nkFormalParams, info)
    fp.add l.id("string", info)
    fp.add copyTree(selfDefs)
    result.add l.mkProc(l.alwaysExported("ToString", info), fp,
                        newTree(nkStmtList, info, newAtom(nkStrLit, full, info)), info,
                        kind = (if isClass: nkMethodDef else: nkProcDef))
  if not isClass:
    ## `$` for a struct: the class form is the intrinsics' generic one.
    let fp = newNodeI(nkFormalParams, info)
    fp.add l.id("string", info)
    fp.add copyTree(selfDefs)
    let call = newTree(nkCall, info, l.id("ToString", info), l.id("self", info))
    result.add l.mkProc(l.alwaysExported("$", info), fp, newTree(nkStmtList, info, call),
                        info)

proc lowerClass(l: var Lowerer; n: NsNode; into: var seq[PNode]) =
  let isClass = n.classKind == ckClass
  let mappedBase =
    if n.typ != nil and n.typ.kind == nsnTypeName: nimTypeName(n.typ.name)
    else: ""
  let isException = isClass and
    l.surface.isExceptionType(mappedBase, l.scope.baseChain(mappedBase))
  l.curClass = n
  l.curBase = mappedBase
  l.curIsException = isException
  l.clsTypeParams = @[]
  for t in n.typeParams: l.clsTypeParams.add t.name
  l.procTypeParams = l.clsTypeParams
  defer:
    l.clsTypeParams = @[]
    l.procTypeParams = @[]
  if not isException:
    for p in l.objectToString(n, isClass): into.add p
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
    objTy.add newTree(nkOfInherit, n.info, l.typeToNim(n.typ, n.info))
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
    case m.kind
    of nsnMethodDecl:
      inner.thisName = if m.attrs.isStatic: "" else: "self"
      for t in m.typeParams: inner.procTypeParams.add t.name
      var params = l.formalParams(m.typ, m.params, m.info)
      if m.name == "Main" and m.attrs.isStatic:
        # entry point: parameters are ignored, it is called as `Main()`
        params = newNodeI(nkFormalParams, m.info)
        params.add l.typeToNim(m.typ, m.info)
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
      let pd = l.asMethod(n, m, inner.mkProc(nameNode, params, inner.stmtSeq(m.body),
                                             m.info))
      into.add pd
      if m.name == "Main" and l.entryPoint == nil: l.entryPoint = pd
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

  if staticInits.len > 0:
    let fp = newNodeI(nkFormalParams, n.info)
    fp.add empty(n.info)
    let body = newNodeI(nkStmtList, n.info)
    for st in staticInits: body.add st
    var nl = l
    nl.procTypeParams = @[]
    l.staticInits.add nl.mkProc(l.id("nsStaticInit" & n.name, n.info), fp, body, n.info)

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
    into.add l.mkProc(l.alwaysExported("nsCreate", info), fp,
                      newTree(nkStmtList, info, newTree(nkCall, info, callee)), info)

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
    into.add l.mkProc(l.alwaysExported("init" & n.name, info), ip, ibody, info,
                      withPragmas = true)
    let ap = newNodeI(nkFormalParams, info)
    ap.add (if isException: newTree(nkRefTy, info, l.clsType(n.name, info))
            else: l.clsType(n.name, info))
    let abody = newNodeI(nkStmtList, info)
    if isClass:
      let nc = newNodeI(nkCall, info)
      nc.add l.id("new", info)
      nc.add l.id("result", info)
      abody.add nc
    let fw = newNodeI(nkCall, info)
    fw.add l.id("init" & n.name, info)
    fw.add l.id("result", info)
    abody.add fw
    into.add l.mkProc(l.alwaysExported("new" & n.name, info), ap, abody, info,
                      withPragmas = true)

# --- module -----------------------------------------------------------------

proc lowerDecl(l: var Lowerer; d: NsNode; into: var seq[PNode]) =
  case d.kind
  of nsnUsing:
    ## Lowers `using A.B;` to `import "A/B"`, so the namespace is in scope only
    ## where the directive appears. Recorded as well, so a member reached in this
    ## module is not named again by a `from` when its namespace is already here.
    if d.name.len > 0:
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
  of nsnEnumDecl: into.add l.lowerEnum(d)
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

proc lowerModule*(module: NsNode; scope: NsModuleScope;
                  cache: IdentCache; config: ConfigRef): PNode =
  ## Lowers a whole `.ns` module to the Nim statements the rest of the compiler
  ## consumes.
  var l = Lowerer(scope: scope, surface: bclSurface(config), cache: cache,
                  counter: new int,
                  imports: NsFromImports(byModule: initTable[string, seq[string]]()),
                  usingPaths: initHashSet[string](),
                  nilChecks: optNilCheck in config.options)
  var stmts: seq[PNode] = @[]
  for d in module.sons:
    l.lowerDecl(d, stmts)
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
    names.sort()
    for n in names: f.add l.id(n, module.info)
    result.add f
  ## C# arithmetic is unchecked unless it is written inside `checked`, so the module
  ## turns the check off and `checked { }` pushes it back on (§7.3).
  let push = newNodeI(nkPragma, module.info)
  push.add l.id("push", module.info)
  push.add newTree(nkExprColonExpr, module.info,
                   l.id("overflowChecks", module.info), l.id("off", module.info))
  result.add push
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
  for p in l.staticInits: routines.add p
  for s in stmts:
    if s.kind in {nkProcDef, nkMethodDef, nkConverterDef}: routines.add s
  for r in routines:
    let fwd = copyTree(r)
    fwd[6] = newNodeI(nkEmpty, r.info)
    result.add fwd
  ## Static initialisers run before any statement of the program, top-level ones
  ## included; their bodies may name anything, since everything is declared above.
  for p in l.staticInits:
    result.add newTree(nkCall, p.info, copyTree(p[0]))
  for s in stmts:
    if s.kind notin declKinds:
      result.add s
  for p in l.staticInits: result.add p
  if l.entryPoint != nil:
    result.add makeMainCall(l, l.entryPoint)

proc splitModuleOutput*(stmts: PNode): tuple[decls, impls: PNode] =
  ## Splits a lowered module into type declarations and implementations, which
  ## `nsgen` emits as `<N>_decl` and `<N>_impl`.
  var decls = newNodeI(nkStmtList, stmts.info)
  var impls = newNodeI(nkStmtList, stmts.info)
  for i in 0 ..< stmts.len:
    let s = stmts[i]
    if s.kind == nkTypeSection:
      decls.add s
    elif isImportStmt(s):
      decls.add s
      impls.add s
    else:
      impls.add s
  result = (decls: decls, impls: impls)
