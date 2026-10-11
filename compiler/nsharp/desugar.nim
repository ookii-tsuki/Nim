# N# frontend - lowering to Nim
#
# The C#-to-Nim translation: NsNode in, ordinary Nim PNodes out. The name mapping
# itself lives in bcl.nim.
#
# A value-returning method, local function or generated `init`/`new` proc is
# `{.discardable.}` (see procPragmas), since C# lets a call statement drop a result.

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
    ownNamespaces: HashSet[string]
      ## the namespaces this module declares itself, which a `using` need not import
    clsTypeParams: seq[string]
      ## the type parameters of the class being lowered: its own name is `C[T]`
    procTypeParams: seq[string]
      ## the generic parameters a routine emitted now takes (class's, then method's)
    objTypes: bool
      ## a native class names its C++ struct, not its handle: a base type, `self`

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
    let pr = (if def[4].kind == nkPragma: copyTree(def[4]) else: newNodeI(nkPragma, def.info))
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
    if not l.objTypes and l.scope.classes.hasKey(name):
      let root = l.scope.handleRoot(name)
      if root.len > 0:
        ## A handle class is held through its handle: `NsH_Node[Ball]`.
        return newTree(nkBracketExpr, info, l.id("NsH_" & root, info), l.id(name, info))
    result = l.id(name, info)
    if t.sons.len > 0:
      let be = newNodeI(nkBracketExpr, info)
      be.add result
      for a in t.sons: be.add l.typeToNim(a, info)
      result = be
  else:
    result = empty(info)

proc expr(l: Lowerer; n: NsNode): PNode
proc fresh(l: Lowerer; base: string): string
proc throwToNim(l: Lowerer; n: NsNode): PNode
proc checkedExprToNim(l: Lowerer; n: NsNode): PNode
proc assignToNim(l: Lowerer; n: NsNode): PNode

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
  result.add (if p.body != nil: l.expr(p.body) else: empty(p.info))

proc exportedName(l: Lowerer; attrs: NsAttrs; name: string; info: TLineInfo): PNode =
  ## A C# member is exported to Nim unless it is private.
  if attrs.isExported:
    result = newTree(nkPostfix, info, l.id("*", info), l.id(name, info))
  else:
    result = l.id(name, info)


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
        arg = newTree(nkCall, a.info, l.typeToNim(pt, a.info), arg)
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
  info.isMethod and info.isStatic and not info.isExtension and m.name != "Main"

proc typeRef(l: Lowerer; t: NsNode): PNode =
  ## A type used as a value (a static member's receiver): `C`, or `C[int32]` when it
  ## carries type arguments.
  result = l.id(nimTypeName(t.typeName), t.info)
  if t.typeArgs.len > 0:
    result = newTree(nkBracketExpr, t.info, result)
    for a in t.typeArgs: result.add l.typeToNim(a, t.info)

proc checkNil(l: Lowerer; recvNs: NsNode; recv: PNode; info: TLineInfo): PNode
proc recvOf(l: Lowerer; n: NsNode): PNode
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

proc callToNim(l: Lowerer; n: NsNode): PNode =
  var callee = n.body
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
        result.add ol.typeToNim(nsnTypeName(callee.body.typeName, n.info), n.info)
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
      recv = l.checkNil(callee.body, recv, n.info)
    result.add recv
    for a in l.argsToNim(n): result.add a
    return
  if l.nilChecks and callee.kind == nsnMember and l.nilableReceiver(callee.body):
    let checked = l.checkNil(callee.body, l.expr(callee.body), n.info)
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
    if spelled.len > 0: return l.id(spelled, n.info)
  if n.body != nil and l.scope.classes.hasKey(n.body.typeName) and
     l.scope.onHandle(n.body.typeName, n.name):
    ## A member of the handle (`[OnHandle]`): the handle itself, unchecked.
    return l.expr(n.body)
  l.recvOf(n.body)

proc nilableReceiver(l: Lowerer; n: NsNode): bool =
  ## True for a receiver the nil check may test: a declared *class*. A struct is a
  ## value, so it can never be nil, and `this` is a parameter a method body cannot
  ## see as nil without the call-site check having fired first.
  if n == nil or n.kind in {nsnThis, nsnBase}: return false
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

proc expr(l: Lowerer; n: NsNode): PNode =
  if n == nil: return newNodeI(nkEmpty, unknownLineInfo)
  case n.kind
  of nsnEmpty: result = empty(n.info)
  of nsnIdent:
    result = l.id(n.name, n.info)
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
    elif n.typeName.len > 0 and l.scope.isInterface(n.typeName):
      ## The empty interface value.
      result = newTree(nkCall, n.info, l.id("default", n.info), l.id(n.typeName, n.info))
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
    else:
      l.noteMemberImport(n)
      result = newTree(nkDotExpr, n.info, l.memberReceiverChecked(n),
                       l.id(n.name, n.info))
      let owner = (if n.body != nil and n.body.kind == nsnThis and l.curClass != nil:
                     l.curClass.name
                   elif n.body != nil: n.body.typeName else: "")
      if l.isManagedNativeField(owner, n.name):
        ## A Nim-managed field of a native-derived class: its value is in the
        ## `NsField`.
        result = newTree(nkCall, n.info, l.id("nsVal", n.info), result)
  of nsnCall: result = l.callToNim(n)
  of nsnIndex:
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
    result = newTree(nkBracketExpr, n.info, l.expr(n.body))
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
          v = newTree(nkCall, e.info, l.typeToNim(et, e.info), v)
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
        br.add newTree(nkCall, e.info, l.typeToNim(n.typ, e.info), l.expr(e))
      else:
        br.add l.expr(e)
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
    if isCheckedOp(n):
      result = newTree(nkCall, n.info, l.id(checkedOperatorName(n.argParam), n.info),
                       l.expr(n.body))
    else:
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
    elif n.kind == nsnIs and n.name == "nsIsType":
      result = newTree(nkCall, n.info, l.id("nsIsType", n.info), l.expr(n.body),
                       l.typeToNim(n.typ, n.info))
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
  of nsnThrow:
    ## Nim's `raise` is `noreturn`, so it stands where a value is expected.
    result = l.throwToNim(n)
  of nsnCheckedExpr: result = l.checkedExprToNim(n)
  of nsnTypeOf:
    result = newTree(nkCall, n.info, l.id("nsTypeOf", n.info), l.typeToNim(n.typ, n.info))
  of nsnSizeOf:
    result = newTree(nkCall, n.info, l.id("nsSizeOf", n.info), l.typeToNim(n.typ, n.info))
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
    ## `(x = e)` as a value: the assignment, then the variable read back.
    var bare = l
    bare.nilChecks = false
    result = newTree(nkBlockExpr, n.info, empty(n.info), newTree(nkStmtList, n.info,
      l.assignToNim(n), bare.expr(n.sons[0])))
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
    elif isCheckedOp(n):
      result = newTree(nkCall, n.info, l.id(checkedOperatorName(n.argParam), n.info),
                       l.ordered(n.sons[0], n.sons[1 .. 1]), l.expr(n.sons[1]))
    elif n.name in ["nsDiv", "nsMod"]:
      ## Integer `/` and `%` go through library procs, which are called rather
      ## than used as an infix operator.
      result = newNodeI(nkCall, n.info)
      result.add l.id(n.name, n.info)
      result.add l.ordered(n.sons[0], n.sons[1 .. 1])
      result.add l.expr(n.sons[1])
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
  elif n.conv == "nsVariant":
    ## A variant conversion: the type arguments are references either way, so the
    ## value is reinterpreted as the target instantiation.
    result = newTree(nkCall, n.info, l.id("nsVariant", n.info), result,
                     l.typeToNim(n.convType, n.info))
  elif n.conv.len > 0:
    ## The implicit numeric conversion `sema.nim` recorded: C# promotes and widens
    ## where Nim wants the conversion spelled.
    result = newTree(nkCall, n.info, l.id(nimTypeName(n.conv), n.info), result)

# --- statements -------------------------------------------------------------

proc stmtsToNode(l: Lowerer; stmts: seq[NsNode]; info: TLineInfo): PNode

proc localFuncToNim(l: Lowerer; n: NsNode): PNode

proc stmtsToNode(l: Lowerer; stmts: seq[NsNode]; info: TLineInfo): PNode =
  ## A block's statements. C# lets a local function be called anywhere in its
  ## block, Nim only after its definition, so each is declared forward first; its
  ## captures are still resolved where it is defined.
  result = newNodeI(nkStmtList, info)
  for s in stmts:
    if s != nil and s.kind == nsnLocalFunc:
      let fwd = l.localFuncToNim(s)
      fwd[6] = empty(s.info)
      result.add fwd
  for s in stmts: result.add l.stmt(s)

proc stmtSeq(l: Lowerer; blk: NsNode): PNode =
  ## Lowers a `nsnBlock` to an `nkStmtList`.
  if blk == nil: return newNodeI(nkStmtList, unknownLineInfo)
  result = l.stmtsToNode(blk.sons, blk.info)

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

proc catchMatch(l: Lowerer; c: NsNode; exc: PNode): PNode =
  ## Whether the current exception is one a `catch` clause takes.
  if c.typ == nil or c.typ.kind in {nsnEmpty, nsnVoidType}: return l.id("true", c.info)
  newTree(nkInfix, c.info, l.id("of", c.info), exc, l.typeToNim(c.typ, c.info))

proc catchVar(l: Lowerer; c: NsNode; exc: PNode): PNode =
  ## `let e = (ref T)(exc)`: the clause's variable, when it names one.
  if c.typ == nil or c.typ.kind in {nsnEmpty, nsnVoidType}: return empty(c.info)
  newTree(nkLetSection, c.info, newTree(nkIdentDefs, c.info, l.id(c.name, c.info),
    empty(c.info), newTree(nkCall, c.info,
      newTree(nkPar, c.info, newTree(nkRefTy, c.info, l.typeToNim(c.typ, c.info))),
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
  body.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(exc, info),
    empty(info), newTree(nkCall, info, l.id("getCurrentException", info))))
  body.add newTree(nkVarSection, info, newTree(nkIdentDefs, info, l.id(pick, info),
    empty(info), newIntNode(nkIntLit, 0)))
  var k = 0
  let dispatch = newNodeI(nkIfStmt, info)
  var finallyNode: PNode = nil
  for c in n.sons:
    if c.kind == nsnFinally:
      finallyNode = newTree(nkFinally, c.info, l.stmtSeq(c.body))
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
  dispatch.add newTree(nkElse, info, newTree(nkRaiseStmt, info, empty(info)))
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
    sl.add newTree(nkDefer, r.info, newTree(nkStmtList, r.info,
      newTree(nkCall, r.info, l.id("nsDispose", r.info), v)))
  if n.body == nil: return sl
  sl.add l.stmtSeq(n.body)
  result = newTree(nkBlockStmt, info, empty(info), sl)

proc lockToNim(l: Lowerer; n: NsNode): PNode =
  ## `lock (x) body`: a program has one thread, so the lock is always free. The
  ## locked expression is still evaluated.
  let info = n.info
  let sl = newNodeI(nkStmtList, info)
  sl.add newTree(nkDiscardStmt, info, l.expr(n.body))
  for s in n.sons: sl.add l.stmt(s)
  result = newTree(nkBlockStmt, info, empty(info), sl)

proc tryToNim(l: Lowerer; n: NsNode): PNode =
  for c in n.sons:
    if c.kind == nsnCatch and c.sons.len > 0: return l.filteredTryToNim(n)
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
      else:
        ## `catch { }` takes everything, the runtime's errors too (a bare `except`
        ## would leave out Nim's defects, `NullReferenceException` among them).
        br.add l.anyException(c.info)
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
  if n.strVal == "discard":
    return newTree(nkDiscardStmt, n.info, l.expr(n.sons[1]))
  if n.strVal == "refAssign":
    var bare = l
    bare.nilChecks = false
    return newTree(nkAsgn, n.info, l.id(n.sons[0].name, n.info),
                   newTree(nkCall, n.info, l.id("addr", n.info), bare.expr(n.sons[1].body)))
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
    let check = l.checkNil(target.body, bare.expr(target.body), n.info)
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

proc checkedExprToNim(l: Lowerer; n: NsNode): PNode =
  ## `checked(e)`: the operand computed under the `overflowChecks` state it names.
  let info = n.info
  let t = l.fresh("nsChecked")
  let sl = newNodeI(nkStmtList, info)
  sl.add newTree(nkPragma, info, l.id("push", info), newTree(nkExprColonExpr, info,
    l.id("overflowChecks", info), l.id(if n.name == "checked": "on" else: "off", info)))
  sl.add newTree(nkLetSection, info, newTree(nkIdentDefs, info, l.id(t, info),
                                            empty(info), l.expr(n.body)))
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

proc hasYield(n: NsNode): bool =
  ## Whether a body is an iterator block: it holds a `yield` of its own, not one of
  ## a nested local function.
  if n == nil or n.kind in {nsnLambda, nsnLocalFunc}: return false
  if n.kind == nsnYield: return true
  if hasYield(n.body): return true
  for x in n.sons:
    if hasYield(x): return true
  false

proc memberBody(l: Lowerer; ret, body: NsNode): PNode =
  ## A member's body. An iterator block becomes a closure iterator inside the
  ## `IEnumerable<T>` (or `IEnumerator<T>`) it returns, so each enumeration runs
  ## the body afresh, lazily, as C#'s does.
  result = l.stmtSeq(body)
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
  for t in n.typeParams: inner.procTypeParams.add t.name
  let fp = inner.formalParams(n.typ, n.params, n.info)
  if n.paramMod == "ref": fp[0] = newTree(nkVarTy, n.info, fp[0])
  inner.procTypeParams = @[]
  for t in n.typeParams: inner.procTypeParams.add t.name
  result = inner.mkProc(l.id(n.name, n.info), fp, inner.memberBody(n.typ, n.body),
                        n.info, withPragmas = true)

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
  for s in n.sons: body.add l.stmt(s)
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
      ## A property, an indexer or a float: the stepped value is assigned.
      return newTree(nkCall, n.info, l.id(if n.body.name == "inc": "nsInc" else: "nsDec",
                                          n.info), l.expr(target))
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
    result.add l.id(n.name, n.info)
    result.add l.expr(n.body)
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
  ## over `typedesc[E]` (so `E.A` reads as in C#) yielding its value, and
  ## `nsEnum(E, U, flags, names)` for the operators and the printing. A member
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
  into.add newTree(nkCall, info, l.id("nsEnum", info), l.id(n.name, info), copyTree(u),
                   l.id(if n.hasAttribute("Flags"): "true" else: "false", info), table)
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
    into.add nl.staticAccessor(cls.name, m, storage)
    return
  l.emitStaticStorage(storage, m.typ, m.body, m.info, inits, into)
  into.add l.staticAccessor(cls.name, m, storage)

# --- properties -------------------------------------------------------------

proc lowerEventAccessors(l: Lowerer; cls, m: NsNode; isException: bool): seq[PNode] =
  ## `event D E { add { ... } remove { ... } }`: procs `nsAdd_E`/`nsRemove_E` over
  ## the receiver (a `typedesc` for a static event) and the handler, `value`.
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
    ## `private set;` keeps the setter in its module, as it does a private member.
    let sattrs = (if setter.strVal == "access": setter.attrs else: m.attrs)
    result.add l.mkProc(propName(l, m, "=", sattrs), sp, sbody, m.info)

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
    result.add l.mkProc(l.exportedName(m.attrs, "[]", info), fp, l.memberBody(m.typ, getter),
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
  for p in m.params: ap.add l.paramDef(p, sink = true)
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
    ## A dispatcher is one indirect call: inlined, an interface call costs no more.
    disp[4] = newTree(nkPragma, info, l.id("inline", info))
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
    into.add l.mkProc(l.exportId("nsDefault_" & n.name & "_" & m.name, m.info), fp,
                      inner.memberBody(m.typ, m.body), m.info, withPragmas = true)
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
                else:
                  ## The table is only ever paired with this class's objects, so
                  ## the object is reread as one without a conversion check.
                  newTree(nkCast, info, copyTree(recvType), l.id("self", info)))
      let target = l.implementerFor(n, m, iface, mangleType(it))
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
                     newTree(nkDotExpr, info, copyTree(a), l.id(f, info)),
                     newTree(nkDotExpr, info, copyTree(b), l.id(f, info)))
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
      newTree(nkStmtList, info, body), info)
  else:
    into.add l.mkProc(l.alwaysExported("==", info),
      newTree(nkFormalParams, info, l.id("bool", info), pairDefs()),
      newTree(nkStmtList, info, body), info)
    into.add l.mkProc(l.alwaysExported("Equals", info),
      newTree(nkFormalParams, info, l.id("bool", info), pairDefs()),
      newTree(nkStmtList, info, newTree(nkInfix, info, l.id("==", info), copyTree(a),
                                        copyTree(b))), info)
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
        newTree(nkDotExpr, info, l.id("self", info), l.id(f, info)))))
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
  let local = (if n.outer.len > 0: n.outer & "+" & n.name else: n.name)
  let full = (if l.curNamespace.len > 0: l.curNamespace & "." & local else: local)
  let selfDefs = newNodeI(nkIdentDefs, info)
  selfDefs.add l.id("self", info)
  selfDefs.add l.clsType(n.name, info)
  selfDefs.add empty(info)
  if n.attrs.isRecord:
    ## `R { A = 1, B = x }`: the type's own name and its public members. A record
    ## prints this unless it declares `ToString` itself.
    overridden = false
    for m in n.sons:
      if m.kind == nsnMethodDecl and m.name == "ToString" and not m.attrs.isStatic:
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
                        newTree(nkStmtList, info, text), info,
                        kind = (if isClass: nkMethodDef else: nkProcDef))
  elif not overridden:
    let fp = newNodeI(nkFormalParams, info)
    fp.add l.id("string", info)
    fp.add copyTree(selfDefs)
    result.add l.mkProc(l.alwaysExported("ToString", info), fp,
                        newTree(nkStmtList, info, newAtom(nkStrLit, full, info)), info,
                        kind = (if isClass: nkMethodDef else: nkProcDef))
  ## `typeof(C)` and, for a class, the dynamic type `GetType()` reads.
  if n.typeParams.len > 0:
    ## `typeof(Box<int>)`: ``Demo.Box`1[System.Int32]``, from the arguments' names.
    let call = newTree(nkCall, info, l.id("nsGenericName", info), newAtom(nkStrLit, full, info))
    for t in l.clsTypeParams:
      call.add newTree(nkCall, info, l.id("FullName", info),
                       newTree(nkCall, info, l.id("nsTypeOf", info), l.id(t, info)))
    let pd = l.mkProc(l.alwaysExported("nsTypeOf", info),
      newTree(nkFormalParams, info, l.id("Type", info), newTree(nkIdentDefs, info,
        l.id("t", info), newTree(nkBracketExpr, info, l.id("typedesc", info),
                                 l.clsType(n.name, info)), empty(info))),
      newTree(nkStmtList, info, newTree(nkCall, info, l.id("nsTypeNamed", info), call)), info)
    pd[2] = l.genericParams(l.clsTypeParams, info)
    result.add pd
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
      newTree(nkStmtList, info, newAtom(nkStrLit, full, info)), info, kind = nkMethodDef)
  if not isClass:
    ## `$` for a struct: the class form is the intrinsics' generic one.
    let fp = newNodeI(nkFormalParams, info)
    fp.add l.id("string", info)
    fp.add copyTree(selfDefs)
    let call = newTree(nkCall, info, l.id("ToString", info), l.id("self", info))
    result.add l.mkProc(l.alwaysExported("$", info), fp, newTree(nkStmtList, info, call),
                        info)

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

proc nativeMethod(l: Lowerer; cls, m: NsNode; nat: NsNative; header: string): PNode =
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
  var pattern = nativeOf(m).cpp
  if pattern.len == 0:
    let targ = (if targs.len > 0: "<" & targs.join(", ") & ">" else: "")
    pattern =
      if m.attrs.isStatic: nat.cpp & "::" & m.name & targ & "(@)"
      elif isStruct or handleSide:
        "#." & (if targs.len > 0: "template " else: "") & m.name & targ & "(@)"
      else: "#->" & (if targs.len > 0: "template " else: "") & m.name & targ & "(@)"
  result = newNodeI(nkProcDef, info, 7)
  result[0] = l.exportId(m.name, info)
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
  if rt.len > 0 and l.scope.classes.hasKey(rt) and l.scope.ownedFamily(rt) and not forward:
    result = l.ownedReturn(m, result, rt, pattern, header)
  elif rt == "string" and not forward:
    result = l.stringReturn(m, result, pattern, header)

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
    if '#' in given: return (if isStatic: "#" & given else: given)
    if isStatic: return nat.cpp & "::" & given & (if setter: "(@)" else: "()@")
    access & given & (if setter: "(#)" else: "()")
  proc emit(name: PNode; fp: PNode; pattern: string) =
    let pd = newNodeI(nkProcDef, info, 7)
    pd[0] = name
    for i in 1 .. 6: pd[i] = empty(info)
    if handleSide: pd[2] = l.genericParams(@["nsU"], info)
    pd[3] = fp
    pd[4] = l.cppPragma(pattern, header, info)
    if fp[0].kind == nkIdent and fp[0].ident.s == "string":
      ## A `const char*` getter (its `Get` pattern may say `#->Title().c_str()`).
      into.add l.stringReturn(m, pd, pattern, header)
    else:
      into.add pd
  let getter = (if m.params.len > 0: m.params[0] else: nil)
  let setter = (if m.params.len > 1: m.params[1] else: nil)
  if getter != nil:
    let pattern = expand(pn.get, false)
    if pattern.len > 0:
      emit(l.exportId(m.name, info),
           newTree(nkFormalParams, info, l.typeToNim(m.typ, info), recvDefs(false)), pattern)
  if setter != nil:
    let pattern = expand(pn.set, true)
    if pattern.len > 0:
      emit(l.exportId(m.name & "=", info),
           newTree(nkFormalParams, info, empty(info), recvDefs(true),
                   l.identDefs("value", l.nativeParamType(m.typ, info), info)), pattern)

proc lowerNativeType(l: var Lowerer; n: NsNode; into: var seq[PNode]) =
  let info = n.info
  let nat = l.scope.classes[n.name].native
  let header = l.nativeHeader(n.name)
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
    procs.add newTree(nkCall, info, l.id("nsObjProcs", info), l.id("NsH_" & n.name, info),
                      l.id(n.name, info))
  if nat.handle.len > 0:
    ## Validity is the handle's `explicit operator bool` unless `Valid` says how to
    ## test it; the invalid handle is a default-constructed one unless `Null` names
    ## it; the object is the handle's `operator->` unless `Deref` says how to reach it.
    let valid = (if nat.valid.len > 0: nat.valid else: "static_cast<bool>(#)")
    let null = (if nat.null.len > 0: nat.null.replace("{0}", "'1")
                else: nat.handle.replace("{0}", "'1") & "()")
    let deref = (if nat.deref.len > 0: nat.deref else: "#.operator->()")
    procs.add newTree(nkCall, info, l.id("nsHandleProcs", info), l.id("NsH_" & n.name, info),
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
    of nsnCtorDecl:
      if m.attrs.isStatic: continue
      if m.params.len == 0: paramless = true
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
  into.add procs

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
  result[6] = newTree(nkStmtList, info, call)

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
  if owned:
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
        let user = newTree(nkStmtList, c.info, inner.memberBody(nil, c.body),
                           newTree(nkDiscardStmt, c.info, empty(c.info)))
        body.add newTree(nkTryStmt, c.info, user,
                         newTree(nkExceptBranch, c.info, l.anyException(c.info),
                                 newTree(nkCall, c.info, l.id("nsEscaped", c.info),
                                         strLit(n.name, c.info))))
    let pd = newNodeI(nkProcDef, cinfo, 7)
    pd[0] = l.id("nsInit_" & n.name, cinfo)
    for i in 1 .. 6: pd[i] = empty(cinfo)
    pd[3] = fp
    pd[4] = newTree(nkPragma, cinfo, l.id("constructor", cinfo))
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
                            inner.memberBody(m.typ, m.body), m.info)
      if not m.attrs.isStatic:
        ## A member function, which the engine finds by name (a concept), or the
        ## override of a native `virtual`.
        pd[4] = newTree(nkPragma, m.info,
                        l.id((if m.attrs.isOverride: "virtual" else: "member"), m.info))
      into.add pd
      let w = l.exportWrapper(n, m)
      if w != nil: into.add w
    else: discard
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
    if n.attrs.isRecord: l.recordMembers(n, isClass, into)
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
                                             inner.memberBody(m.typ, m.body),
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
  proc noteOwn(n: NsNode; into: var HashSet[string]) =
    if n.kind == nsnNamespace:
      into.incl n.name
      if n.body != nil:
        for x in n.body.sons: noteOwn(x, into)
  for d in module.sons: noteOwn(d, l.ownNamespaces)
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
