# N# frontend - semantic analysis, name resolution and type checking
#
# Resolves names (a bare member name becomes `this.Member`), enforces access
# control, attaches coarse type information to expressions (`NsNode.typeKind`),
# checks the conversions C# would refuse, and applies the base-constructor rule,
# so lowering can make type-directed decisions instead of guessing from names
# (integer `/`, `some(T)`/`none(T)` for a `T?` target).
#
# What a type is and what a member yields comes from two places: this module's own
# declarations, and the prelude's (`bcl.nim`'s surface, read out of the prelude's
# Nim sources). No member name is known here -- `.Length`, `.Count`, `.Message` and
# `.Value` are whatever the library declares them to be, and Nim resolves them at
# their call sites exactly as it resolves `int.high` to `high(int32)`.
#
# The information gathered is deliberately coarse (`ast.NsTypeKind`) and only as
# precise as lowering needs. It is still not a type system: no user conversions,
# no generics, and no inference beyond what an expression spells. Only the
# refusals the frontend can *see* are encoded -- a name it cannot resolve, an
# enum, a `T?` whose element is unclear all count as compatible, so an unspotted
# mistake stays Nim's to report rather than becoming a wrong N# error.

import std/[tables, sets, strutils]
import ../lineinfos, ../options
import ast, bcl, diagnostics, lambdas, numeric, symbols

type
  NsYieldHost = enum
    yhNone        ## a lambda, a constructor: C# has no iterator there
    yhMember      ## a method or a local function, which may be an iterator
    yhUnsupported ## an accessor or an operator: an iterator N# does not lower yet

type
  NsTypeInfo* = object
    kind*: NsTypeKind
    name*: string              ## the type's name, when it has one
    node*: NsNode              ## the type as written, generic arguments included
    isRef*: bool               ## a `ref` local: a reference to another variable

  NsCheckContext = object
    scope: NsModuleScope
    config: ConfigRef
    surface: NsBclSurface                       ## what the prelude declares
    clsName: string                            ## enclosing class, "" outside one
    members: seq[string]                       ## names reachable from it
    retType: NsNode                            ## enclosing member's return type
    isStaticCtx: bool                          ## inside a static member: no `this`
    typeParams: seq[string]                    ## the generic parameters in scope
    curMember: NsNode                          ## the member whose body is walked
    tmpCounter: int                            ## numbers the temporaries sema introduces
    inCtor: bool                               ## inside a constructor of `clsName`
    ctorIsStatic: bool                         ## ... and it is the static one
    yieldHost: NsYieldHost                     ## what a `yield` here would belong to
    types: TableRef[string, NsTypeInfo]        ## locals, params, loop variables
    undo: seq[seq[(string, NsTypeInfo, bool)]] ## one frame per open scope
    inChecked: bool                            ## inside `checked`: `operator checked` applies

const NsLocalFuncMark = "#local"
  ## The type name a local function is declared under, so a call can find it.

proc setType(n: NsNode; kind: NsTypeKind; name = "") =
  n.typeKind = kind
  n.typeName = name

# --- scopes -----------------------------------------------------------------

proc pushScope(ctx: var NsCheckContext) =
  ctx.undo.add @[]

proc popScope(ctx: var NsCheckContext) =
  ## Rolls back every declaration made in the innermost scope.
  let decls = ctx.undo.pop()
  for d in decls:
    if d[2]: ctx.types[d[0]] = d[1]
    else: ctx.types.del(d[0])

proc declare(ctx: var NsCheckContext; name: string; kind: NsTypeKind;
             typeName = ""; node: NsNode = nil) =
  if ctx.undo.len > 0:
    let had = ctx.types.hasKey(name)
    ctx.undo[^1].add (name, (if had: ctx.types[name]
                             else: NsTypeInfo(kind: tkUnknown)), had)
  ctx.types[name] = NsTypeInfo(kind: kind, name: typeName, node: node)

proc declTypeName(t: NsNode): string =
  ## The type name recorded for a local or parameter. Canonical, so a qualified
  ## `Company.Products.Widget` matches the class names in the module scope. For a
  ## `T?` it is the inner name, which is what `x.Value` needs.
  if t == nil: ""
  elif t.kind == nsnNullableType: declTypeName(t.typ)
  elif t.kind == nsnArrayType:
    ## `int[]`: the element's name with the brackets, so indexing can recover it.
    (if t.typ != nil: declTypeName(t.typ) & "[]" else: "")
  else: canonicalTypeName(t.name)

# --- type classification ----------------------------------------------------

proc isTypeName(ctx: NsCheckContext; name: string): bool =
  ## True when the name is a type or a namespace the frontend can place: C#'s own
  ## vocabulary, a type the library declares, a type, enum or delegate this
  ## compilation declares, or a namespace it imports. A qualifier -- the root of
  ## `Console.WriteLine` or `P.Gadget` -- is told from a value by this lookup, not
  ## by how the name is spelled.
  ctx.surface.isKnownTypeName(name) or ctx.scope.classes.hasKey(name) or
    ctx.scope.delegates.hasKey(name) or ctx.scope.enums.contains(name) or
    ctx.scope.namespaces.contains(name)

proc qualifierRoot(n: NsNode): string =
  ## The innermost name of a dotted receiver: the `System` of `System.Console`, the
  ## `P` of `P.Gadget`. "" when the receiver is not a plain dotted name, which is
  ## how an expression receiver stays a value.
  if n == nil: return ""
  case n.kind
  of nsnIdent: n.name
  of nsnMember: qualifierRoot(n.body)
  else: ""

const
  NsValueKinds* = {tkInt, tkFloat, tkBool, tkChar, tkString, tkSequence}
    ## Kinds that are values rather than references, which is what separates a cast
    ## that boxes from one that does not.

proc isObjectTarget(t: NsNode): bool =
  ## True for `object` and `RootRef`, the targets a cast boxes into.
  if t == nil or t.kind != nsnTypeName: return false
  unqualified(t.name) in ["object", "Object", "RootRef"]

proc classifyName(ctx: NsCheckContext; name: string): NsTypeKind =
  ## Kind of a type written by name. "List is a sequence" and "SystemException is an
  ## exception" are both answered by the library that declares them; the rest by
  ## C#'s own vocabulary and by this compilation's declarations. It is a lookup
  ## either way, not a guess.
  let canon = canonicalTypeName(name)
  if canon in ctx.typeParams:
    ## A type parameter stands for any type: nothing is known until instantiation,
    ## which Nim checks.
    return tkUnknown
  result = ctx.surface.kindOfName(canon)
  if result != tkUnknown: return
  if ctx.scope.delegates.hasKey(canon): return tkDelegate
  if ctx.scope.classes.hasKey(canon):
    return (if ctx.surface.isExceptionType(canon, ctx.scope.baseChain(canon)):
              tkException
            else: tkClass)
  result = tkUnknown

proc classifyType(ctx: NsCheckContext; t: NsNode): NsTypeKind =
  ## Kind of a written type. `T[]` is a sequence and `T?` is a nullable value type;
  ## a name goes through `classifyName`; anything unrecognised stays unknown so
  ## lowering stays conservative. The node records its own kind, which is how
  ## `desugar.nim` knows whether the type needs `Option`.
  if t == nil: return tkUnknown
  case t.kind
  of nsnArrayType:
    t.setType(tkSequence, declTypeName(t))
    result = tkSequence
  of nsnTupleType:
    for e in t.sons: discard ctx.classifyType(e.typ)
    t.setType(tkTuple)
    result = tkTuple
  of nsnNullableType:
    let inner = ctx.classifyType(t.typ)
    ## Only a value type needs `Option`: a reference is nullable already, so `Node?`
    ## is just `Node`, as C# reads it.
    result = if inner in {tkInt, tkFloat, tkBool, tkChar}: tkNullable else: inner
    t.setType(result, declTypeName(t.typ))
  of nsnTypeName:
    result = ctx.classifyName(t.name)
    if result == tkUnknown and t.sons.len > 0 or result == tkUnknown and
       ctx.surface.types.hasKey(nimTypeName(t.name) & "0"):
      ## `Func<int, int>`: the library declares C#'s per-arity names with a suffix.
      let k = ctx.surface.kindOfName(nimTypeName(t.name) & $t.sons.len)
      if k != tkUnknown: result = k
    t.setType(result, canonicalTypeName(t.name))
  else: result = tkUnknown

proc memberKind(ctx: NsCheckContext; clsName, member: string): NsTypeKind =
  ## Kind of `this.member` / `Class.member`. For a method this is its return
  ## type, which is what the surrounding call produces.
  let info = ctx.scope.findMemberInfo(clsName, member)
  if info.name.len == 0: return tkUnknown
  ctx.classifyType(info.typ)

proc memberTypeOf(ctx: NsCheckContext; recv: NsNode; clsName, member: string): NsNode =
  ## A member's declared type -- a method's result -- as seen through the receiver:
  ## the class's type parameters replaced by the receiver's type arguments.
  let info = ctx.scope.findMemberInfo(clsName, member)
  if info.name.len == 0: return nil
  result = info.typ
  if recv != nil and recv.rtype != nil and recv.rtype.kind == nsnTypeName and
     ctx.scope.classes.hasKey(info.owner):
    result = substitute(result, ctx.scope.classes[info.owner].typeParams,
                        recv.rtype.sons)

proc memberTypeName(ctx: NsCheckContext; clsName, member: string): string =
  ## A member's declared type name, which a nullable field needs so that lowering can
  ## name the element type when building `some(T)` or `none(T)`.
  let info = ctx.scope.findMemberInfo(clsName, member)
  if info.name.len == 0: return ""
  declTypeName(info.typ)

proc memberKindOfSurface(ctx: NsCheckContext; rk: NsTypeKind; recv, name: string;
                         tname: var string): NsTypeKind =
  ## The kind a library member yields, from its declaration in the prelude. A
  ## declared result is looked up like any other type name; a result that is one of
  ## the declaration's own type parameters is the receiver's own type --
  ## `int.MaxValue` is an `int` -- or, for a `T?`, its element, which is what
  ## `a.Value` is. A member the library does not declare is `tkUnknown`, and stays
  ## Nim's to resolve.
  let m = ctx.surface.member(recv, rk, name)
  if m.name.len == 0: return tkUnknown
  if not ctx.surface.resultAgrees(recv, rk, name): return tkUnknown
  if not m.retIsParam:
    tname = m.ret
    return ctx.surface.kindOfSpelling(m.ret)
  if rk == tkNullable: return ctx.classifyName(recv)
  if m.isStatic: return rk
  tkUnknown

# --- numeric conversions ----------------------------------------------------
#
# C# promotes the operands of an arithmetic operator to a common type and converts a
# value implicitly where a wider numeric type is expected; Nim does neither for
# `int` to `float`, nor for `char`. The conversion an operand or a value needs is
# recorded on it (`conv`), and only when both types are known exactly, so an
# expression the frontend cannot type is left to Nim as before.

proc csOperatorOf*(nimOp: string): string =
  ## The C# operator a lowered operator name came from.
  case nimOp
  of "mod", "nsMod": "%"
  of "nsDiv": "/"
  of "and": "&"
  of "or": "|"
  of "xor": "^"
  of "shl": "<<"
  of "shr": ">>"
  of "not": "!"
  else: nimOp

proc numName(n: NsNode): string =
  ## The C# numeric type of an expression, or "" when it is not known exactly.
  if n == nil: return ""
  case n.kind
  of nsnIntLit: return (if n.typeName.len > 0: n.typeName else: "int")
  of nsnCharLit: return "char"
  of nsnFloatLit: return (if n.typeName.len > 0: n.typeName else: "double")
  else: discard
  case n.typeKind
  of tkInt, tkFloat: numericOfSpelling(n.typeName)
  of tkChar: "char"
  else: ""

proc isConstantLit(n: NsNode): bool =
  ## A literal, or a negated one: C# lets an in-range constant narrow implicitly.
  n != nil and (n.kind == nsnIntLit or
                (n.kind == nsnUnary and n.name == "-" and n.body != nil and
                 n.body.kind == nsnIntLit))

proc constValue(n: NsNode): BiggestInt =
  if n.kind == nsnIntLit: n.intVal else: -n.body.intVal

proc kindOfNumeric(s: string): NsTypeKind =
  if isFloating(s): tkFloat elif s == "char": tkChar else: tkInt

proc needConv(n: NsNode; to: string) =
  ## Records that `n` is converted to `to` where it is used.
  if n == nil or to.len == 0: return
  if isConstantLit(n) and n.typeName.len == 0 and fitsLiteral(constValue(n), to):
    ## An untyped Nim literal takes the type its context asks for.
    return
  if numName(n) != to: n.conv = to

proc variantArgs(ctx: NsCheckContext; name: string): seq[string] =
  ## The variance of each type parameter of a generic interface or delegate, ""
  ## for an invariant one; `Func`'s and `Action`'s are .NET's.
  let n = unqualified(name)
  if ctx.scope.classes.hasKey(n) and ctx.scope.classes[n].decl != nil:
    for t in ctx.scope.classes[n].decl.typeParams: result.add t.strVal
  elif ctx.scope.delegates.hasKey(n):
    for t in ctx.scope.delegates[n].typeParams: result.add t.strVal

proc isRefConvertible(ctx: NsCheckContext; src, dst: NsNode): bool =
  ## A reference conversion from class `src` to class `dst`, or to `object`: the
  ## two share Nim's representation, which is what a variant conversion needs.
  if src == nil or dst == nil or src.kind != nsnTypeName or dst.kind != nsnTypeName:
    return false
  let s = unqualified(src.name)
  let d = unqualified(dst.name)
  if not ctx.scope.classes.hasKey(s) or ctx.scope.classes[s].classKind != ckClass:
    return false
  if d in ["object", "Object"]: return true
  ctx.scope.classes.hasKey(d) and ctx.scope.classes[d].classKind == ckClass and
    d in ctx.scope.baseChain(s)

type NsVariantConv = enum vcNone, vcOk, vcUnsupported

proc isRefTypeArg(ctx: NsCheckContext; t: NsNode): bool =
  ## A type argument C# variance would accept but N# holds by value or as an
  ## interface's fat pointer: an interface, `string`, an array.
  if t == nil: return false
  if t.kind == nsnArrayType: return true
  t.kind == nsnTypeName and (ctx.scope.isInterface(unqualified(t.name)) or
    unqualified(t.name) in ["string", "String"])

proc variantConversion(ctx: NsCheckContext; src, dst: NsNode): NsVariantConv =
  ## `IProducer<Cat>` to `IProducer<Animal>` when `T` is `out`, and the reverse
  ## for `in` (C# 4 variance), over reference type arguments only, as in C#.
  if src == nil or dst == nil or src.kind != nsnTypeName or dst.kind != nsnTypeName:
    return vcNone
  if unqualified(src.name) != unqualified(dst.name) or src.sons.len != dst.sons.len or
     src.sons.len == 0:
    return vcNone
  var variance = ctx.variantArgs(src.name)
  let n = unqualified(src.name)
  if n == "Func":
    variance = @[]
    for i in 0 ..< src.sons.len: variance.add(if i == src.sons.len - 1: "out" else: "in")
  elif n == "Action":
    variance = @[]
    for i in 0 ..< src.sons.len: variance.add "in"
  if variance.len != src.sons.len: return vcNone
  var differs = false
  var unsupported = false
  for i in 0 ..< src.sons.len:
    let a = src.sons[i]
    let b = dst.sons[i]
    if mangleType(a) == mangleType(b): continue
    differs = true
    let (f, t) = (if variance[i] == "in": (b, a) else: (a, b))
    if variance[i] notin ["in", "out"]: return vcNone
    if not ctx.isRefConvertible(f, t):
      if ctx.isRefTypeArg(f) or ctx.isRefTypeArg(t): unsupported = true
      else: return vcNone
  if not differs: vcNone
  elif unsupported: vcUnsupported
  else: vcOk

proc namesSequence(ctx: NsCheckContext; cls: string; enumerator: bool): bool =
  ## Whether class `cls`, or a base of it, names `IEnumerable<T>` (or, with
  ## `enumerator`, `IEnumerator<T>`).
  for c in ctx.scope.chain(cls):
    let d = ctx.scope.classes[c].decl
    if d != nil and (if enumerator: d.attrs.isEnumerator else: d.attrs.isEnumerable):
      return true
  false

proc coerce(ctx: NsCheckContext; value: NsNode; targetName: string; info: TLineInfo;
            targetType: NsNode = nil) =
  ## The implicit numeric conversion C# applies where a value of one numeric type is
  ## used as another: recorded when C# allows it, CS0266 when only a cast would.
  ## A variant interface or delegate conversion is recorded too.
  if value != nil and value.typeKind == tkClass and value.conv.len == 0:
    ## A class implementing `IEnumerable<T>`/`IEnumerator<T>` where one is expected:
    ## the library's view over its `GetEnumerator` (or `MoveNext`/`Current`).
    let t = canonicalTypeName(targetName).split('<')[0]
    let cn = canonicalTypeName(value.typeName)
    if t == "IEnumerable" and ctx.namesSequence(cn, false):
      value.conv = "nsToIEnumerable"
      return
    if t == "IEnumerator" and ctx.namesSequence(cn, true):
      value.conv = "nsToIEnumerator"
      return
  if value != nil and targetType != nil and value.conv.len == 0:
    case ctx.variantConversion(value.rtype, targetType)
    of vcOk:
      value.conv = "nsVariant"
      value.convType = targetType
      return
    of vcUnsupported:
      nsError(ctx.config, info, ndUnsupported,
              "a variant conversion over an interface, string or array type argument")
      return
    of vcNone: discard
  let target = (if targetName.len == 0 and targetType != nil and
                   isObjectTarget(targetType): "object" else: targetName)
  if value != nil and canonicalTypeName(target).split('<')[0] == "IEnumerable" and
     (value.typeKind == tkSequence or
      ctx.surface.member(value.typeName, value.typeKind, "nsToIEnumerable").name.len > 0):
    ## An array or a collection used as an `IEnumerable<T>`: the view the library
    ## declares for it.
    value.conv = "nsToIEnumerable"
    return
  if value != nil and canonicalTypeName(target) in ["object", "Object"] and
     value.kind != nsnNull and value.conv.len == 0 and
     not ctx.scope.isInterface(value.typeName):
    ## A value used as an `object` is boxed; a reference passes through the same
    ## library call unchanged.
    value.conv = "nsBox"
    return
  let dst = numericOfSpelling(target)
  if value == nil or dst.len == 0: return
  let src = numName(value)
  if src.len == 0 or src == dst: return
  if isConstantLit(value) and src != "char" and not isFloating(src) and
     fitsLiteral(constValue(value), dst):
    ## `byte b = 5;`, `double d = 1;`: an in-range constant, which Nim's untyped
    ## literal already adapts to.
    return
  if implicitlyConvertible(src, dst):
    value.conv = dst
  else:
    nsError(ctx.config, info, ndCannotConvertExplicit, src, dst)

# --- type checking ----------------------------------------------------------
#
# C# converts implicitly in a handful of places and refuses everywhere else. What
# follows encodes only the refusals, and only the ones the frontend can see: a name
# it cannot resolve, an enum, a type declared in a module the scope does not cover,
# or a `T?` whose element is unclear all count as *compatible*. Being conservative
# in that direction is the point -- a wrong N# error would stop a program Nim would
# have accepted, while a missed one only leaves Nim's own message in place.

const
  NsNullIntolerantKinds* = {tkInt, tkFloat, tkBool, tkChar}
    ## The kinds C# refuses `null` for. A `string` and a sequence are references, so
    ## `null` is accepted for them even where Nim cannot represent it.

  NsValueTargetKinds* = {tkInt, tkFloat, tkBool, tkChar}
    ## The kinds a `T?` wraps in `Option[T]`; for anything else the `?` is only an
    ## annotation, because the type is nullable already.

proc defaultSpelling(k: NsTypeKind): string =
  ## How C# names a kind that has no name of its own, as a literal does not.
  case k
  of tkInt: "int"
  of tkFloat: "double"
  of tkBool: "bool"
  of tkChar: "char"
  of tkString: "string"
  of tkSequence: "T[]"
  of tkClass, tkException: "object"
  of tkDelegate: "delegate"
  else: "?"

proc typeSpelling(target: NsNode): string =
  ## How C# names a declared type in a diagnostic, preferring what the source wrote.
  result = "?"
  if target == nil: return
  case target.kind
  of nsnNullableType: result = typeSpelling(target.typ) & "?"
  of nsnArrayType: result = typeSpelling(target.typ) & "[]"
  of nsnTypeName:
    if target.sons.len > 0:
      result = unqualified(target.name) & "<"
      for i in 0 ..< target.sons.len:
        if i > 0: result.add ", "
        result.add typeSpelling(target.sons[i])
      result.add ">"
    else: result = canonicalTypeName(target.name)
  else: discard

proc valueSpelling(arg: NsNode): string =
  ## How C# names what an expression *is*.
  result = "?"
  if arg == nil: return
  if arg.kind == nsnNull:
    result = "<null>"
    return
  if arg.typeName.len > 0: result = arg.typeName
  else: result = defaultSpelling(arg.typeKind)

proc qualifiedName(clsName, member: string): string =
  ## `Box.Show`, the type-qualified name Roslyn uses when it names the candidate an
  ## argument list fell short of. A constructor is `Box.Box`, as C# writes it.
  if clsName.len == 0: member
  else: unqualified(clsName) & "." & member

proc signature(displayName: string; params: seq[NsNode]): string =
  ## `Show(int, string)`, the tail of a C# arity message.
  result = displayName & "("
  for i in 0 ..< params.len:
    if i > 0: result.add ", "
    result.add typeSpelling(if params[i] != nil: params[i].typ else: nil)
  result.add ")"

type
  NsTarget = object
    ## What a value has to be to be acceptable here: the kind it must have, the class
    ## name a chain is walked with, whether `null` is allowed, and -- when it is a `T?`
    ## on a value type -- the element type the `some`/`none` wrap is spelled with.
    kind: NsTypeKind
    name: string
    spelling: string
    isNullOk: bool
    isOptionValue: bool
    elemName: string

proc targetOfType(ctx: NsCheckContext; target: NsNode): NsTarget =
  ## The target of a declared type: a parameter, local, field or `return`.
  result = NsTarget(kind: tkUnknown, isNullOk: true, spelling: typeSpelling(target))
  if target == nil or isObjectTarget(target): return
  if target.kind == nsnNullableType:
    let inner = ctx.classifyType(target.typ)
    result.kind = inner
    result.name = declTypeName(target.typ)
    if inner in NsValueTargetKinds:
      ## C# converts a value to `T?` implicitly, so the element kind is what an
      ## argument has to match, and `null` is that type's absent value.
      result.isOptionValue = true
      result.elemName = declTypeName(target.typ)
    else:
      result.isNullOk = inner notin NsNullIntolerantKinds
    return
  result.kind = ctx.classifyType(target)
  result.name = declTypeName(target)
  result.isNullOk = result.kind notin NsNullIntolerantKinds

proc targetOfExpr(ctx: NsCheckContext; e: NsNode): NsTarget =
  ## The target of an expression, which is all an assignment has to work with: the
  ## kind `sema` already attached to the left side. A `T?` left side takes the value
  ## its element type takes, because C# converts into it implicitly.
  result = NsTarget(kind: tkUnknown, isNullOk: true, spelling: valueSpelling(e))
  if e == nil: return
  if e.typeKind == tkNullable:
    result.kind = ctx.classifyName(e.typeName)
    result.name = e.typeName
    result.spelling = e.typeName & "?"
    result.isOptionValue = true
    result.elemName = e.typeName
    return
  result.kind = e.typeKind
  result.name = e.typeName
  result.isNullOk = e.typeKind notin NsNullIntolerantKinds

proc incompatible(ctx: NsCheckContext; arg: NsNode; t: NsTarget): bool =
  ## True only when C# would reject the value outright.
  result = false
  if arg == nil: return
  if arg.kind == nsnNull:
    result = not t.isNullOk
    return
  let ak = arg.typeKind
  if ak == tkUnknown or t.kind == tkUnknown: return
  let src = (if arg.typeName.len > 0: canonicalTypeName(arg.typeName) else: numName(arg))
  if src.len > 0 and t.name.len > 0 and
     ctx.scope.conversionOp(src, canonicalTypeName(t.name), true) != nil:
    ## A user-defined implicit conversion (`implicit operator double(Vec v)`).
    return
  case ak
  of tkClass:
    if t.kind == tkException: return          ## an exception class is one of these
    if t.kind != tkClass:
      result = true
      return
    let a = arg.typeName
    let b = t.name
    if a.len == 0 or b.len == 0: return
    if not ctx.scope.classes.hasKey(a) or not ctx.scope.classes.hasKey(b):
      return                                  ## declared elsewhere: stay quiet
    result = not ctx.scope.implements(a, b)
  of tkException:
    result = t.kind != tkException and t.kind != tkClass
  of tkDelegate: result = t.kind != tkDelegate
  of tkSequence:
    ## An array or a collection is an `IEnumerable<T>` too.
    result = t.kind != tkSequence and
             not canonicalTypeName(t.name).startsWith("IEnumerable")
  of tkString: result = t.kind != tkString
  of tkBool: result = t.kind != tkBool
  of tkInt, tkFloat, tkChar: result = t.kind notin {tkInt, tkFloat, tkChar}
  else: discard

proc argConv(ctx: NsCheckContext; arg, target: NsNode): NsArgConv =
  ## The conversion C# inserts for this argument: a value into a `T?` parameter is
  ## `some`, and `null` into one is `none`. Anything else is used as written.
  result = acNone
  if arg == nil or target == nil: return
  if target.kind == nsnNullableType and
     ctx.classifyType(target.typ) in NsValueTargetKinds:
    if arg.kind == nsnNull: result = acNoneOption
    elif arg.typeKind != tkNullable: result = acSome   ## a `T?` is already one

type
  NsArgMap = object
    ## How a call's arguments fill one candidate's parameters.
    fits: bool              ## every argument found a parameter, every required one is filled
    slot: seq[int]          ## the parameter each argument fills
    element: seq[bool]      ## the argument is one element of a `params` array
    missing: int            ## the first required parameter left unfilled, or -1

proc argValue*(a: NsNode): NsNode =
  ## The value an argument passes: `v` in `name: v`, `x` in `ref x`.
  if a != nil and a.kind in {nsnNamedArg, nsnRefArg}: a.body else: a

proc mapArgs(params, args: seq[NsNode]): NsArgMap =
  ## C#'s argument list rules: positional arguments in order, named ones by name,
  ## the last parameter `params T[]` taking the rest as elements (or one array), and
  ## every parameter left out needing a default value.
  result = NsArgMap(fits: true, slot: newSeq[int](args.len),
                    element: newSeq[bool](args.len), missing: -1)
  var filled = newSeq[bool](params.len)
  var pos = 0
  for j, a in args:
    if a.kind == nsnNamedArg:
      var k = -1
      for i, p in params:
        if p != nil and p.name == a.name: k = i
      if k < 0 or filled[k]:
        result.fits = false
        return
      filled[k] = true
      result.slot[j] = k
    elif pos < params.len and params[pos] != nil and params[pos].paramMod == "params":
      result.slot[j] = pos
      filled[pos] = true
      ## One array argument is the array itself; anything else is an element.
      let v = argValue(a)
      result.element[j] = not (j == args.len - 1 and j == pos and
                               v.typeKind == tkSequence)
    elif pos < params.len:
      result.slot[j] = pos
      filled[pos] = true
      inc pos
    else:
      result.fits = false
      return
  for k, p in params:
    if not filled[k] and p != nil and p.body == nil and p.paramMod != "params":
      result.fits = false
      result.missing = k
      return

proc slotType(params: seq[NsNode]; m: NsArgMap; j: int): NsNode =
  ## The type argument `j` must convert to: its parameter's, or the element type of a
  ## `params` array.
  let p = params[m.slot[j]]
  if p == nil: return nil
  if m.element[j] and p.typ != nil and p.typ.kind == nsnArrayType: p.typ.typ
  else: p.typ

proc resolveOverload(ctx: NsCheckContext; cands: seq[seq[NsNode]];
                     args: seq[NsNode]): tuple[ok: bool, idx, score: int, map: NsArgMap] =
  ## Picks the overload every argument fits, preferring the one that needs the fewest
  ## conversions, so an exact match beats the `T?` one C# would also have reached,
  ## and one that needs no `params` expansion or default beats one that does.
  result = (ok: false, idx: -1, score: high(int), map: NsArgMap())
  for i in 0 ..< cands.len:
    let m = mapArgs(cands[i], args)
    if not m.fits: continue
    var fits = true
    var score = 0
    for j in 0 ..< args.len:
      let pt = slotType(cands[i], m, j)
      let v = argValue(args[j])
      if v.kind == nsnOutDecl: continue
      if ctx.incompatible(v, ctx.targetOfType(pt)):
        fits = false
        break
      if ctx.argConv(v, pt) != acNone: inc score
      if m.element[j]: inc score
    if cands[i].len > args.len: inc score
    if fits and score < result.score:
      result = (ok: true, idx: i, score: score, map: m)

proc markNull(ctx: NsCheckContext; value: NsNode; target: string) =
  ## `null` for an interface is the empty interface value, which lowering spells
  ## `default(I)`, so the target is recorded on the literal.
  if value != nil and value.kind == nsnNull and ctx.scope.isInterface(target):
    value.setType(tkClass, target)
  elif value != nil and value.kind == nsnNull and canonicalTypeName(target) == "string":
    ## A Nim string cannot be nil: a null string is the empty one (SPEC 7.3).
    value.setType(tkString, "string")

proc checkConvertible(ctx: NsCheckContext; value: NsNode; t: NsTarget;
                      info: TLineInfo) =
  ## The one rule the initialiser, the assignment and `return` share: CS0029 for a
  ## value of an unrelated type, CS0037 for `null` into a value type.
  if value == nil: return
  if value.kind == nsnNull:
    if not t.isNullOk:
      nsError(ctx.config, info, ndCannotConvertNull, t.spelling)
    ctx.markNull(value, t.name)
    return
  if ctx.incompatible(value, t):
    let src = (if value.typeName.len > 0: canonicalTypeName(value.typeName)
               else: numName(value))
    if src.len > 0 and t.name.len > 0 and
       ctx.scope.conversionOp(src, canonicalTypeName(t.name), false) != nil:
      ## Only an explicit conversion exists: C# says so (CS0266).
      nsError(ctx.config, info, ndCannotConvertExplicit, valueSpelling(value), t.spelling)
    else:
      nsError(ctx.config, info, ndCannotConvert, valueSpelling(value), t.spelling)

proc isTypeParamRef(ctx: NsCheckContext; t: NsNode): bool =
  ## A parameter typed by a type parameter: a bare name no declaration answers for.
  t != nil and t.kind == nsnTypeName and t.sons.len == 0 and '.' notin t.name and
    not ctx.isTypeName(t.name)

proc checkCallArgs(ctx: var NsCheckContext; cands: seq[seq[NsNode]];
                   args: seq[NsNode]; displayName, recvName: string;
                   isCtor: bool; info: TLineInfo) =
  ## CS1501 / CS1729 when no overload takes this many arguments, CS7036 when one
  ## takes more, CS1503 when one takes exactly this many but an argument cannot be
  ## converted. A call the scope cannot resolve -- a library method, a name from a
  ## module it does not cover -- has no candidates and is left to Nim. The chosen
  ## overload's parameter is recorded on each argument, which `out var` declarations
  ## and lambda arguments take their types from.
  if cands.len == 0: return
  for a in args:
    if a.kind == nsnRefArg and a.name == "out" and a.body != nil and
       a.body.kind == nsnIdent and a.body.name == "_" and not ctx.types.hasKey("_"):
      ## `out _` discards: a temporary of the parameter's type takes the value.
      inc ctx.tmpCounter
      a.kind = nsnOutDecl
      a.name = "nsDiscard" & $ctx.tmpCounter
      a.body = nil
      a.typ = nil
  let (ok, idx, _, map) = ctx.resolveOverload(cands, args)
  if ok:
    for j in 0 ..< args.len:
      let a = args[j]
      let pt = slotType(cands[idx], map, j)
      a.argParam = cands[idx][map.slot[j]]
      a.argElement = map.element[j]
      let v = argValue(a)
      if v.kind == nsnOutDecl:
        ## `out var x` takes the parameter's type -- for a type parameter, the type
        ## an argument for another parameter of that type gives it.
        if v.typ == nil and pt != nil: v.typ = pt
        if v.typ != nil and ctx.isTypeParamRef(v.typ):
          for k in 0 ..< args.len:
            let o = argValue(args[k])
            if k == j or o == nil or o.kind in {nsnOutDecl, nsnLambda}: continue
            let ot = slotType(cands[idx], map, k)
            if ot != nil and ot.kind == nsnTypeName and ot.name == v.typ.name:
              let vt = valueType(o)
              if vt != nil:
                v.typ = (if vt.kind == nsnTypeName and vt.name == "int" and
                            o.kind == nsnIntLit: nsnTypeName("int", vt.info) else: vt)
                break
        ctx.declare(v.name, ctx.classifyType(v.typ), declTypeName(v.typ), v.typ)
        continue
      if a.kind == nsnRefArg: continue
      let conv = ctx.argConv(v, pt)
      if conv != acNone:
        ## Lowering applies it, so the argument reaches `some`/`none` spelled with
        ## the element type rather than with the literal's own type.
        v.argConv = conv
        v.argConvType =
          declTypeName(if pt.kind == nsnNullableType: pt.typ else: pt)
      elif pt != nil:
        ctx.coerce(v, declTypeName(pt), v.info, pt)
        ctx.markNull(v, declTypeName(pt))
        if ctx.isTypeParamRef(pt) and v.kind in {nsnIntLit, nsnFloatLit} and
           v.typeName.len == 0:
          ## A literal for a type parameter fixes the type argument, and C# types
          ## `3` as `int` where Nim would infer its own `int`.
          v.conv = (if v.kind == nsnIntLit: "int" else: "double")
    return
  ## No overload fits. One that takes the arguments' shape but not a value's type is
  ## CS1503, naming the first argument that does not convert.
  for i in 0 ..< cands.len:
    let m = mapArgs(cands[i], args)
    if not m.fits: continue
    for j in 0 ..< args.len:
      let pt = slotType(cands[i], m, j)
      let v = argValue(args[j])
      if v.kind != nsnOutDecl and ctx.incompatible(v, ctx.targetOfType(pt)):
        nsError(ctx.config, v.info, ndArgumentCannotConvert,
                $(j + 1), valueSpelling(v), typeSpelling(pt))
        return
    return
  ## No overload takes these arguments. Roslyn names the one short candidate and
  ## its first missing parameter when there is exactly one -- a constructor with a
  ## single declaration, or a method with no overloads -- and falls back to the arity
  ## message as soon as there is a choice.
  let where = if args.len > 0: args[0].info else: info
  let single = (if cands.len == 1: mapArgs(cands[0], args) else: NsArgMap(missing: -1))
  if cands.len == 1 and single.missing >= 0:
    let p = cands[0][single.missing]
    nsError(ctx.config, where, ndMissingArgument,
            (if p != nil: p.name else: "?"),
            signature(qualifiedName(recvName, displayName), cands[0]))
  elif isCtor:
    nsError(ctx.config, where, ndCtorNoOverload, recvName, $args.len)
  else:
    nsError(ctx.config, where, ndArgumentNoOverload, displayName, $args.len)

proc checkCondition(ctx: NsCheckContext; cond: NsNode) =
  ## C# requires a `bool` condition, and says CS0029 when it does not get one. A `T?`
  ## is not a `bool` either, but its spelling keeps the `?` C# prints.
  if cond == nil: return
  if cond.typeKind in {tkInt, tkFloat, tkChar, tkString, tkSequence,
                       tkClass, tkException, tkDelegate, tkNullable}:
    let what = (if cond.typeKind == tkNullable: cond.typeName & "?"
                else: valueSpelling(cond))
    nsError(ctx.config, cond.info, ndCannotConvert, what, "bool")

proc checkThrow(ctx: NsCheckContext; n: NsNode) =
  ## What C# lets you throw must derive from `Exception`. Roslyn reports the mismatch
  ## as the implicit conversion to `System.Exception` -- CS0029, not the CS0155 the
  ## message suggests -- which is why the target is spelled out here.
  let e = n.body
  if e == nil or e.kind == nsnNull: return
  if e.typeKind == tkUnknown or e.typeKind == tkException: return
  nsError(ctx.config, e.info, ndCannotConvert, valueSpelling(e), "System.Exception")

proc checkCatch(ctx: NsCheckContext; c: NsNode) =
  ## CS0155: only something deriving from `Exception` can be caught. A name the scope
  ## cannot classify is left to Nim.
  if c.typ == nil: return
  let k = ctx.classifyType(c.typ)
  if k != tkUnknown and k != tkException:
    nsError(ctx.config, c.info, ndNotAnException)

proc checkDisposable(ctx: NsCheckContext; r: NsNode) =
  ## CS1674: what `using` disposes must convert to `System.IDisposable`. Only a type
  ## this compilation declares is judged; a library type is left to Nim.
  let t = (if r.kind == nsnLocalDecl:
             (if r.typ != nil: declTypeName(r.typ) elif r.body != nil: r.body.typeName
              else: "")
           else: r.typeName)
  if t.len == 0 or not ctx.scope.classes.hasKey(t): return
  var seen: seq[string] = ctx.scope.chain(t)
  for i in ctx.scope.interfaceClosure(t): seen.add i
  for c in seen:
    if not ctx.scope.classes.hasKey(c): continue
    for li in ctx.scope.classes[c].libInterfaces:
      if canonicalTypeName(li.name) == "IDisposable": return
  nsError(ctx.config, r.info, ndNotDisposable, t)

proc warnNullableRefs(ctx: NsCheckContext; n: NsNode) =
  ## `MyObj?` on a reference type is only an annotation: C# accepts it and does
  ## nothing with it. C# does warn CS8632 -- but only while the nullable-annotations
  ## context is off, which is the default. N# has no such context, so it is always
  ## off, and the warning always applies. A struct is exempt: C# really does make
  ## that `Nullable<T>`, which N# does not support yet.
  if n == nil: return
  if n.kind == nsnNullableType and n.typ != nil:
    let inner = ctx.classifyType(n.typ)
    let name = declTypeName(n.typ)
    let isStruct = inner == tkClass and ctx.scope.classes.hasKey(name) and
                   ctx.scope.classes[name].classKind == ckStruct
    if inner in {tkClass, tkException, tkString, tkSequence, tkDelegate} and
       not isStruct:
      nsWarn(ctx.config, n.info, ndNullableAnnotation)
  warnNullableRefs(ctx, n.typ)
  for p in n.params: warnNullableRefs(ctx, p)
  for a in n.initArgs: warnNullableRefs(ctx, a)
  if n.body != nil: warnNullableRefs(ctx, n.body)
  for i in 0 ..< n.sons.len: warnNullableRefs(ctx, n.sons[i])

# --- expressions ------------------------------------------------------------

proc inaccessible(ctx: NsCheckContext; n: NsNode) =
  nsError(ctx.config, n.info, ndNotAccessible, n.name)

proc checkMemberAccess(ctx: NsCheckContext; n: NsNode) =
  ## `this.member`, or the `this.member` a bare name was rewritten into.
  if n.body != nil and n.body.kind == nsnThis and ctx.clsName.len > 0:
    if not ctx.scope.accessibleFrom(ctx.clsName, n.name):
      ctx.inaccessible(n)

proc noteMutation(ctx: NsCheckContext; target: NsNode) =
  ## A struct member that assigns to `this` mutates the value it is called on, so it
  ## takes `self` by `var` (`sema` marks it, lowering reads the mark).
  if ctx.curMember == nil or ctx.clsName.len == 0 or
     not ctx.scope.classes.hasKey(ctx.clsName) or
     ctx.scope.classes[ctx.clsName].classKind != ckStruct: return
  var t = target
  while t != nil and t.kind in {nsnMember, nsnIndex}: t = t.body
  if t != nil and t.kind == nsnThis: ctx.curMember.strVal = "mutating"

proc walkExpr(ctx: var NsCheckContext; n: NsNode): NsTypeKind

proc initStatements(tmp: string; inits: seq[NsNode]; info: TLineInfo;
                    recvPath: seq[string] = @[]): seq[NsNode] =
  ## The statements an object or collection initialiser stands for, over the new
  ## object `tmp`: `A = v` assigns, `A = { ... }` initialises the member in place,
  ## `[k] = v` assigns through the indexer, and anything else is an `Add`.
  result = @[]
  proc recv(): NsNode =
    result = nsnIdent(tmp, info)
    for m in recvPath: result = nsnMember(result, m, info)
  for it in inits:
    case it.kind
    of nsnInitMember:
      if it.body != nil and it.body.kind == nsnInitList:
        for st in initStatements(tmp, it.body.sons, it.info, recvPath & @[it.name]):
          result.add st
      else:
        let a = nsn(nsnAssign, it.info)
        a.sons = @[nsnMember(recv(), it.name, it.info), it.body]
        result.add a
    of nsnInitIndex:
      let ix = nsn(nsnIndex, it.info)
      ix.body = recv()
      ix.sons = it.sons
      let a = nsn(nsnAssign, it.info)
      a.sons = @[ix, it.body]
      result.add a
    of nsnInitAdd:
      let call = nsn(nsnCall, it.info)
      call.body = nsnMember(recv(), "Add", it.info)
      call.sons = it.sons
      let st = nsn(nsnExprStmt, it.info)
      st.body = call
      result.add st
    else: discard

proc targetTyped(ctx: NsCheckContext; value, target: NsNode) =
  ## `new()`, `default` and `{ ... }` take their type from what they convert to.
  if value == nil or target == nil: return
  case value.kind
  of nsnNew, nsnDefault:
    if value.typ == nil and target.kind != nsnVoidType:
      value.typ = (if target.kind == nsnNullableType and value.kind == nsnNew: target.typ
                   else: target)
  of nsnArrayLit:
    ## A callee's own type parameter is no type here: the elements decide.
    if value.typ == nil and target.kind == nsnArrayType and
       not (ctx.isTypeParamRef(target.typ) and target.typ.name notin ctx.typeParams):
      value.typ = target.typ
  of nsnCollection:
    if value.typ != nil or target.kind == nsnVoidType: return
    var hasSpread = false
    for e in value.sons:
      if e.kind == nsnSpread: hasSpread = true
    var t = target
    if t.kind == nsnTypeName and t.sons.len == 1 and
       canonicalTypeName(t.name) in ["IEnumerable", "IReadOnlyList", "IReadOnlyCollection",
                                     "ICollection", "IList"]:
      ## An interface target is an array of its element type.
      t = nsnArrayType(t.sons[0], t.info)
    if t.kind == nsnArrayType:
      if hasSpread: value.typ = t
      else:
        ## `[a, b]` into an array is `new T[] { a, b }`.
        value.kind = nsnArrayLit
        value.typ = t.typ
    elif t.kind == nsnTypeName:
      ## Into a collection type: `new C { a, b }` -- with spreads, `new C(array)`,
      ## through the constructor that takes a collection.
      let elems = value.sons
      value.kind = nsnNew
      value.typ = t
      value.sons = @[]
      if hasSpread:
        if t.sons.len != 1: return
        let arr = nsn(nsnCollection, value.info)
        arr.sons = elems
        arr.typ = nsnArrayType(t.sons[0], value.info)
        value.add arr
      else:
        for e in elems:
          let add = nsn(nsnInitAdd, e.info)
          add.add e
          value.inits.add add
  else: discard
proc walkStmt(ctx: var NsCheckContext; n: NsNode)

proc walkInScope(ctx: var NsCheckContext; stmts: seq[NsNode]) =
  ## Statements in the scope already open: its local functions first, since C#
  ## lets a body call one before its declaration, or recursively.
  for s in stmts:
    if s != nil and s.kind == nsnLocalFunc:
      ctx.declare(s.name, tkDelegate, NsLocalFuncMark, s)
  for s in stmts: ctx.walkStmt(s)
proc walkBody(ctx: var NsCheckContext; blk: NsNode)

proc staticReceiver(ctx: NsCheckContext; owner: string; info: TLineInfo): NsNode =
  ## `C`, or `C<T>` when `owner` is the generic class being checked.
  result = nsnIdent(owner, info)
  result.setType(tkType, owner)
  if owner == ctx.clsName and ctx.scope.classes.hasKey(owner):
    for t in ctx.scope.classes[owner].typeParams:
      result.typeArgs.add nsnTypeName(t, info)

proc checkTypeTest(ctx: NsCheckContext; n: NsNode) =
  ## `is`, `as` and casts need nothing checked here: a generic interface's type
  ## test asks the object's class by the instantiation's name (`nsVtByKey`).
  discard

proc checkLibraryInterfaceValue(ctx: NsCheckContext; t: NsNode) =
  ## A library interface (`IComparable<T>`) is a contract N# checks by name; it has
  ## no table, so it cannot be the type of a value.
  if t != nil and t.kind == nsnTypeName and
     canonicalTypeName(t.name) in ctx.scope.libIfaces and
     not ctx.scope.classes.hasKey(canonicalTypeName(t.name)):
    nsError(ctx.config, t.info, ndUnsupported,
            "a value of the library interface '" & unqualified(t.name) & "'")

proc staticImport(ctx: NsCheckContext; name: string): string =
  ## The type a `using static` makes `name` a static member of, or "".
  for t in ctx.scope.staticUsings:
    if ctx.scope.classes.hasKey(t):
      let m = ctx.scope.findMemberInfo(t, name)
      if m.name.len > 0 and (m.isStatic or m.isConst): return t
    else:
      let m = ctx.surface.member(t, ctx.surface.kindOfName(t), name)
      if m.name.len > 0 and m.isStatic: return t
  ""

proc chainInScope(ctx: NsCheckContext; cls: string): bool =
  ## Whether every class `cls` derives from is this compilation's: a library base
  ## (`Exception`, `Attribute`) lends members N# cannot list, so a name it does
  ## not resolve may still be one of them.
  if not ctx.scope.classes.hasKey(cls): return false
  let ch = ctx.scope.chain(cls)
  let last = ctx.scope.classes[ch[^1]].base
  last.len == 0 or last in ["object", "Object"]

proc libraryHas(ctx: NsCheckContext; recv: string; kind: NsTypeKind; name: string): bool =
  ## Whether the prelude gives a value of this type a member `name`: its own, or one
  ## declared for any value (`ToString`, `GetType`), or an extension in scope.
  if ctx.surface.member(recv, kind, name).name.len > 0: return true
  for m in ctx.surface.members.getOrDefault(NsParamKey):
    if m.name == name: return true
  ctx.scope.extensions.hasKey(name)

proc checkMemberUse(ctx: NsCheckContext; n: NsNode) =
  ## `recv.name` on a value: the member must exist (CS1061), be an instance member
  ## (CS0176), and be accessible from here (CS0122). Only where the receiver's
  ## type, and everything it inherits, is known.
  let recv = n.body
  if recv == nil or recv.kind == nsnThis or recv.kind == nsnBase: return
  let rk = recv.typeKind
  let cn = canonicalTypeName(recv.typeName)
  if rk == tkClass and ctx.scope.classes.hasKey(cn):
    if not ctx.chainInScope(cn) and ctx.scope.classes[cn].classKind != ckInterface:
      return
    let m = ctx.scope.findMemberInfo(cn, n.name)
    if m.name.len == 0:
      if not ctx.libraryHas("object", tkClass, n.name):
        nsError(ctx.config, n.info, ndNoMember, cn, n.name)
      return
    if m.isStatic or m.isConst:
      nsError(ctx.config, n.info, ndStaticViaInstance, m.owner & "." & n.name)
      return
    var ok = true
    ## An interface's members are public whatever they are written with; an
    ## explicit implementation (`R I.M()`) is not a member of the class at all, so
    ## the access that counts is that of an ordinary member of the name.
    let ownerIsIface = ctx.scope.classes.hasKey(m.owner) and
                       ctx.scope.classes[m.owner].classKind == ckInterface
    var access = (if ownerIsIface: aPublic else: m.access)
    block ordinary:
      for c in ctx.scope.chain(cn):
        let d = ctx.scope.classes[c].decl
        if d == nil: continue
        for x in d.sons:
          if x.name == n.name and x.explicitIface.len == 0:
            access = (if d.classKind == ckInterface: aPublic else: x.attrs.access)
            break ordinary
    case access
    of aPrivate:
      ## A nested type sees its enclosing types' private members.
      ok = false
      var c = ctx.clsName
      var hops = 0
      while c.len > 0 and hops < 32:
        if c == m.owner: ok = true
        c = (if ctx.scope.classes.hasKey(c): ctx.scope.classes[c].enclosing else: "")
        inc hops
    of aProtected:
      ok = ctx.clsName.len > 0 and m.owner in ctx.scope.chain(ctx.clsName)
    else: discard
    if not ok:
      nsError(ctx.config, n.info, ndNotAccessible, m.owner & "." & n.name)
  elif rk == tkString and cn in ["string", "String", ""]:
    if not ctx.libraryHas("string", tkString, n.name):
      nsError(ctx.config, n.info, ndNoMember, "string", n.name)

proc unknownName(ctx: NsCheckContext; n: NsNode) =
  ## A bare name nothing in scope declares (CS0103); an instance member named in a
  ## static member, which needs an object (CS0120). Only reported where every
  ## place the name could come from is known.
  if n.name.len == 0 or n.name[0] in {'$', '#'} or n.name == "_": return
  if ctx.clsName.len == 0 or not ctx.chainInScope(ctx.clsName): return
  if n.name in ctx.typeParams or ctx.isTypeName(n.name): return
  if ctx.surface.namespaces.contains(n.name): return
  ## What every class inherits from `object` (`ReferenceEquals`, `Equals`).
  if ctx.surface.member("object", tkClass, n.name).name.len > 0: return
  if n.name in ctx.members:
    let m = ctx.scope.findMemberInfo(ctx.clsName, n.name)
    if not m.isStatic and ctx.isStaticCtx:
      nsError(ctx.config, n.info, ndObjectRefRequired, m.owner & "." & n.name)
    return
  nsError(ctx.config, n.info, ndNameNotFound, n.name)

proc walkIdent(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  ## A bare name. Inside an instance member body, a name that is a class member
  ## is rewritten in place into `this.name` and then resolved as a member, which
  ## is the behaviour the parse-time rewrite used to have.
  if n.name == "$subject":
    ## The stand-in for a pattern's subject keeps the type it was given.
    return n.typeKind
  if n.name notin ctx.members and not ctx.types.hasKey(n.name) and
     ctx.scope.staticUsings.len > 0:
    let owner = ctx.staticImport(n.name)
    if owner.len > 0:
      ## `using static T;` makes `T.name` reachable as `name`.
      n.kind = nsnMember
      n.strVal = "usingStatic"
      n.body = ctx.staticReceiver(owner, n.info)
      return ctx.walkExpr(n)
  if ctx.clsName.len > 0 and n.name notin ctx.members and
     not ctx.types.hasKey(n.name):
    let m = ctx.scope.enclosingStatic(ctx.clsName, n.name)
    if m.name.len > 0:
      ## A nested type names its enclosing type's statics bare.
      n.kind = nsnMember
      n.body = ctx.staticReceiver(m.owner, n.info)
      return ctx.walkExpr(n)
  if ctx.clsName.len > 0 and n.name in ctx.members and
     not ctx.types.hasKey(n.name):
    let m = ctx.scope.findMemberInfo(ctx.clsName, n.name)
    if m.isStatic:
      ## A static member is reached through its class, in any member -- `C<T>` in
      ## a generic class, whose statics belong to the instantiation.
      n.kind = nsnMember
      n.body = ctx.staticReceiver(m.owner, n.info)
      return ctx.walkExpr(n)
    if not ctx.isStaticCtx:
      n.kind = nsnMember
      n.body = nsn(nsnThis, n.info)
      return ctx.walkExpr(n)
  if ctx.types.hasKey(n.name):
    let info = ctx.types[n.name]
    n.setType(info.kind, info.name)
    n.rtype = info.node
    if info.isRef: n.paramMod = "deref"
    result = info.kind
  elif ctx.scope.delegates.hasKey(n.name):
    n.setType(tkDelegate, n.name)
    result = tkDelegate
  elif ctx.isTypeName(n.name):
    ## A type or a namespace used as a receiver (`Console.WriteLine`), or a static
    ## call qualifier. Which of those it is needs no further resolution here: the
    ## member access that follows asks the library.
    n.setType(tkType, canonicalTypeName(n.name))
    result = tkType
  else:
    n.setType(tkUnknown)
    ctx.unknownName(n)
    result = tkUnknown

proc walkMember(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  ## Member access. The receiver's resolved type decides what the member means, and
  ## the declaration that owns it -- this module's, or the prelude's -- decides what
  ## it yields. No member name is special-cased.
  var rk = ctx.walkExpr(n.body)
  if rk == tkUnknown and n.body != nil:
    ## The receiver is a qualifier rather than a value: a type or an imported
    ## namespace at the root of a dotted name (`int.MaxValue`, `Console`, `P.Gadget`,
    ## `System.Console`). The lookup is what tells the two apart.
    let root = qualifierRoot(n.body)
    if root.len > 0 and ctx.isTypeName(root):
      rk = tkType
      if n.body.kind == nsnIdent:
        n.body.setType(tkType, canonicalTypeName(n.body.name))
  var kind = tkUnknown
  var tname = ""
  case rk
  of tkClass:
    ctx.checkMemberAccess(n)
    ctx.checkMemberUse(n)
    kind = ctx.memberKind(n.body.typeName, n.name)
    if ctx.scope.findMemberInfo(n.body.typeName, n.name).isMethod:
      ## A method named without a call is a method group: a delegate value.
      kind = tkDelegate
    if kind != tkUnknown:
      if kind in {tkNullable, tkClass, tkException, tkInt, tkFloat, tkChar}:
        ## The member's declared type name, which lowering needs for a `T?`, the
        ## assignment check to walk a class chain, and promotion to know the width.
        tname = ctx.memberTypeName(n.body.typeName, n.name)
    else:
      ## Not a member this module declares: the prelude may declare one
      ## (`Equals`, `ToString`, `q.Count`), or nothing does.
      kind = ctx.memberKindOfSurface(rk, n.body.typeName, n.name, tname)
    if kind != tkDelegate or
       not ctx.scope.findMemberInfo(n.body.typeName, n.name).isMethod:
      ## A member of a generic class, seen through a receiver whose type arguments
      ## are known, has the substituted type. A delegate-typed field or property
      ## has its delegate type too, which types a lambda assigned to it.
      let mt = ctx.memberTypeOf(n.body, n.body.typeName, n.name)
      if mt != nil:
        n.rtype = mt
        let k = ctx.classifyType(mt)
        if k != tkUnknown:
          kind = k
          tname = declTypeName(mt)
  of tkTuple:
    ## `t.min` names `Item1`: a tuple element's name is an alias of its position.
    let tt = n.body.rtype
    if tt != nil and tt.kind == nsnTupleType:
      for k, e in tt.sons:
        if e.name == n.name or "Item" & $(k + 1) == n.name:
          n.name = "Item" & $(k + 1)
          if e.typ != nil:
            kind = ctx.classifyType(e.typ)
            tname = declTypeName(e.typ)
            n.rtype = e.typ
          break
  of tkSequence, tkString, tkException, tkNullable:
    if rk == tkString: ctx.checkMemberUse(n)
    kind = ctx.memberKindOfSurface(rk, n.body.typeName, n.name, tname)
  of tkType:
    ## A namespace's member is a type (`System.Console`); a declared type's member
    ## is one of its statics, which the library answers for (`string.Empty`,
    ## `int.MaxValue`, `Array.IndexOf`).
    if n.body != nil and ctx.scope.enums.contains(n.body.typeName):
      ## `Color.Green`: a value of the enum, not a type.
      n.setType(tkUnknown, n.body.typeName)
      n.rtype = nsnTypeName(n.body.typeName, n.info)
      return tkUnknown
    if n.body != nil:
      let recv = n.body.typeName
      if ctx.scope.classes.hasKey(recv) and
         ctx.scope.findMemberInfo(recv, n.name).name.len > 0:
        ## A static member of a class this compilation declares.
        kind = ctx.memberKind(recv, n.name)
        let mi = ctx.scope.findMemberInfo(recv, n.name)
        if mi.isMethod: kind = tkDelegate
        else: n.rtype = mi.typ
        if kind in {tkNullable, tkClass, tkException, tkInt, tkFloat, tkChar}:
          tname = ctx.memberTypeName(recv, n.name)
      else:
        kind = ctx.memberKindOfSurface(ctx.surface.kindOfName(recv), recv, n.name,
                                       tname)
    if kind == tkUnknown: kind = tkType
    if kind == tkType and tname.len == 0 and ctx.scope.classes.hasKey(n.name):
      ## `Demo.Gadget`: the qualified name of a type this compilation declares.
      tname = n.name
  else: discard
  n.setType(kind, tname)
  result = kind

proc isDeferred(v: NsNode): bool =
  ## An argument typed by the parameter it is passed for: a lambda, or a `new()`,
  ## `default` or array initialiser without a type of its own.
  v != nil and (v.kind == nsnLambda or
                v.kind in {nsnNew, nsnDefault, nsnArrayLit, nsnCollection} and v.typ == nil)

proc isLambdaArg(a: NsNode): bool =
  a != nil and (isDeferred(a) or
                (a.kind == nsnNamedArg and isDeferred(a.body)))

proc warnObsolete(ctx: NsCheckContext; attr: NsNode; what: string; info: TLineInfo) =
  ## A use of an `[Obsolete]` declaration: CS0618 with the message, CS0612 without
  ## one, and the error CS0619 when the attribute says `true`.
  if attr == nil: return
  let msg = (if attr.sons.len > 0 and attr.sons[0].kind == nsnStrLit: attr.sons[0].strVal
             else: "")
  let isError = attr.sons.len > 1 and attr.sons[1].kind == nsnBoolLit and
                attr.sons[1].intVal == 1
  if isError: nsError(ctx.config, info, ndObsoleteError, what, msg)
  elif msg.len > 0: nsWarn(ctx.config, info, ndObsolete, what, msg)
  else: nsWarn(ctx.config, info, ndObsoleteNoMessage, what)

proc isExtensionCall(ctx: NsCheckContext; callee: NsNode; owner: string): bool =
  ## Whether `recv.M` names an extension method: one is in scope, and the
  ## receiver's own type -- a class this compilation declares, or a library type
  ## -- has no member `M`, which C# would prefer.
  if not ctx.scope.extensions.hasKey(callee.name): return false
  if owner.len > 0 and ctx.scope.classes.hasKey(owner):
    return ctx.scope.findMemberInfo(owner, callee.name).name.len == 0
  let recv = callee.body
  ctx.surface.member(recv.typeName, recv.typeKind, callee.name).name.len == 0

proc walkCall(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  var kind = tkUnknown
  var cands: seq[seq[NsNode]] = @[]
  var owner = ""
  var tn = ""
  let callee = n.body
  if callee != nil and callee.kind == nsnIdent and not ctx.types.hasKey(callee.name) and
     callee.name notin ctx.members and ctx.scope.staticUsings.len > 0 and
     ctx.scope.enclosingStatic(ctx.clsName, callee.name).name.len == 0:
    let owner = ctx.staticImport(callee.name)
    if owner.len > 0:
      ## `using static T;` makes `T.M(...)` callable as `M(...)`.
      callee.kind = nsnMember
      callee.strVal = "usingStatic"
      callee.body = ctx.staticReceiver(owner, callee.info)
  if callee != nil and callee.kind == nsnIdent and ctx.clsName.len > 0 and
     not ctx.types.hasKey(callee.name) and callee.name notin ctx.members:
    let m = ctx.scope.enclosingStatic(ctx.clsName, callee.name)
    if m.name.len > 0 and m.isMethod:
      ## A nested type calls its enclosing type's static methods bare.
      callee.kind = nsnMember
      callee.body = ctx.staticReceiver(m.owner, callee.info)
  if callee != nil and callee.kind == nsnIdent and ctx.clsName.len > 0 and
     not ctx.types.hasKey(callee.name) and callee.name in ctx.members:
    ## `M(args)` naming a member of the enclosing class is `C.M(args)` for a static
    ## one and `this.M(args)` for an instance one, which is resolved as such below.
    let m = ctx.scope.findMemberInfo(ctx.clsName, callee.name)
    if m.isStatic:
      callee.kind = nsnMember
      callee.body = ctx.staticReceiver(m.owner, callee.info)
    elif not ctx.isStaticCtx:
      callee.kind = nsnMember
      callee.body = nsn(nsnThis, callee.info)
  if callee != nil and callee.kind == nsnMember:
    let rk = ctx.walkExpr(callee.body)
    if rk == tkType:
      ## `Class.Method(...)` or `Namespace.Method(...)`: lowering drops the
      ## qualifier, and the result type is the method's if the class is known.
      owner = unqualified(callee.body.name)
      kind = ctx.memberKind(owner, callee.name)
      if kind == tkUnknown:
        ## A static member of a library type: `String.Concat`, `Array.IndexOf`.
        kind = ctx.memberKindOfSurface(ctx.surface.kindOfName(owner), owner,
                                       callee.name, tn)
    elif rk == tkUnknown and ctx.scope.enums.contains(callee.body.typeName):
      ## A member of an enum value: what the library declares for any value
      ## (`ToString`, `GetType`).
      for m in ctx.surface.members.getOrDefault(NsParamKey):
        if m.name == callee.name and m.ret.len > 0 and not m.retIsParam:
          kind = ctx.surface.kindOfSpelling(m.ret)
          tn = m.ret
          n.rtype = nsnTypeName(m.ret, n.info)
          break
    elif rk == tkString:
      ctx.checkMemberUse(callee)
    elif rk == tkClass:
      ctx.checkMemberUse(callee)
      owner = callee.body.typeName
      kind = ctx.memberKind(owner, callee.name)
      let mt = ctx.memberTypeOf(callee.body, owner, callee.name)
      if mt != nil:
        n.rtype = mt
        let k = ctx.classifyType(mt)
        if k != tkUnknown:
          kind = k
          tn = declTypeName(mt)
      if kind == tkUnknown:
        ## Likewise, a member of a class the prelude declares (`Queue.Dequeue`).
        kind = ctx.memberKindOfSurface(rk, owner, callee.name, tn)
    ## The declared parameter lists, so the arguments can be matched against them.
    ## A receiver the scope does not know (`Console`, a name from a module it does
    ## not cover) has none, and the call is left to Nim.
    cands = ctx.scope.memberOverloads(owner, callee.name)
    if ctx.scope.classes.hasKey(owner):
      let mi = ctx.scope.findMemberInfo(owner, callee.name)
      if mi.isEvent and mi.isProperty:
        ## An event with accessors has no handlers to call, even inside (CS0079).
        nsError(ctx.config, callee.info, ndEventAccessorUse, mi.owner & "." & mi.name)
      elif mi.isEvent:
        ## Raising an event calls each handler; only its own type may (CS0070).
        callee.strVal = "event"
        if mi.owner != ctx.clsName:
          nsError(ctx.config, callee.info, ndEventOutside, mi.owner & "." & mi.name,
                  mi.owner)
      if mi.obsolete != nil:
        ctx.warnObsolete(mi.obsolete, signature(mi.owner & "." & callee.name, mi.params),
                         callee.info)
    if rk != tkType and ctx.isExtensionCall(callee, owner):
      ## `x.M(args)` where `x`'s type has no `M`: an extension method, which is
      ## `M(x, args)`. Its parameters after the `this` one take the arguments.
      let ext = ctx.scope.extensions[callee.name][0]
      callee.strVal = "extension"
      owner = ext.owner
      cands = @[]
      for c in ctx.scope.memberOverloads(owner, callee.name):
        if c.len > 0: cands.add c[1 .. ^1]
      kind = ctx.classifyType(ext.typ)
      tn = (if kind != tkUnknown: declTypeName(ext.typ) else: "")
      n.rtype = (if ext.typeParams.len == 0: ext.typ else: nil)
      if ext.typeParams.len > 0: kind = tkUnknown
    ## A member the module declares carries its declared result type name, which
    ## the surrounding `var x = ...` needs to name `x` (`List<int> Items()` makes
    ## `x` a `List`); the surface path has already recorded its own.
    if kind != tkUnknown and tn.len == 0:
      tn = ctx.memberTypeName(owner, callee.name)
    if n.rtype == nil and owner.len > 0:
      ## The declared result type, which a tuple's element names need.
      let info = ctx.scope.findMemberInfo(owner, callee.name)
      if info.name.len > 0 and info.isMethod: n.rtype = info.typ
    callee.setType(kind)
  elif callee != nil and callee.kind == nsnIdent and ctx.types.hasKey(callee.name) and
       ctx.types[callee.name].name == NsLocalFuncMark:
    ## A local function: its declaration answers like a method's.
    let decl = ctx.types[callee.name].node
    kind = ctx.classifyType(decl.typ)
    tn = declTypeName(decl.typ)
    cands = @[decl.params]
    callee.setType(tkDelegate)
  elif callee != nil:
    discard ctx.walkExpr(callee)
  ## Lambdas last: their parameter types come from the overload the other
  ## arguments select.
  for a in n.sons:
    if not isLambdaArg(a): discard ctx.walkExpr(a)
  n.setType(kind, tn)
  if callee != nil and (callee.kind == nsnMember or cands.len > 0):
    ctx.checkCallArgs(cands, n.sons, callee.name, owner, false, n.info)
  let sigs = callLambdaSigs(ctx.scope, ctx.surface, n)
  for j, a in n.sons:
    if isLambdaArg(a):
      let v = (if a.kind == nsnNamedArg: a.body else: a)
      if v.kind == nsnLambda: applySig(v, sigs[j])
      elif a.argParam != nil:
        var pt = a.argParam.typ
        if a.argElement and pt != nil and pt.kind == nsnArrayType: pt = pt.typ
        ctx.targetTyped(v, pt)
        discard ctx.walkExpr(a)
        ## The conversion to the parameter, as for any other argument.
        if pt != nil: ctx.coerce(v, declTypeName(pt), v.info, pt)
        continue
      discard ctx.walkExpr(a)
  for a in n.sons:
    let v = argValue(a)
    if v != nil and v.kind == nsnOutDecl and not ctx.types.hasKey(v.name):
      ## A call the frontend cannot resolve still declares an `out int x`; an
      ## `out var x` there has no type to declare.
      if v.typ != nil:
        ctx.declare(v.name, ctx.classifyType(v.typ), declTypeName(v.typ), v.typ)
      else:
        nsError(ctx.config, v.info, ndUnsupported,
                "'out var' for a method whose parameters N# cannot see")
  result = kind

proc markCoalesced(n: NsNode) =
  ## `a?.B?.C ?? x` supplies `x` for the absent case of *every* link, so none of them
  ## is a bare value-typed `?.` for the diag in `walkExpr`.
  if n == nil: return
  if n.kind == nsnNullDot: n.intVal = 1
  for s in n.sons: markCoalesced(s)
  markCoalesced(n.body)

proc subjectOf(kind: NsTypeKind; name: string; rtype: NsNode; info: TLineInfo): NsNode =
  ## A stand-in for a pattern's subject, carrying its type, for the sub-patterns.
  result = nsnIdent("$subject", info)
  result.setType(kind, name)
  result.rtype = rtype

proc walkPattern(ctx: var NsCheckContext; pat, subject: NsNode) =
  ## A pattern against a subject of known (or unknown) type. A designation declares
  ## a local of the pattern's type; a `var` one takes the subject's. The subject's
  ## type is recorded on the pattern, which lowering needs for its test.
  if pat == nil: return
  pat.setType(subject.typeKind, subject.typeName)
  pat.rtype = (if subject.rtype != nil: subject.rtype
               elif subject.typeName.len > 0: nsnTypeName(subject.typeName, pat.info)
               else: nil)
  case pat.kind
  of nsnPatType:
    ctx.checkTypeTest(pat)
    let k = ctx.classifyType(pat.typ)
    if pat.name.len > 0:
      ctx.declare(pat.name, k, declTypeName(pat.typ), pat.typ)
  of nsnPatConst, nsnPatRel:
    discard ctx.walkExpr(pat.body)
  of nsnPatAnd, nsnPatOr:
    for x in pat.sons: ctx.walkPattern(x, subject)
  of nsnPatNot:
    ctx.walkPattern(pat.body, subject)
  of nsnPatVar:
    ctx.declare(pat.name, subject.typeKind, subject.typeName, pat.rtype)
  of nsnPatPositional:
    ## `T(p, q)` / `(p, q)`: the subject (seen as `T`) taken apart -- a tuple by its
    ## elements, anything else by its `Deconstruct` -- each part matched.
    var owner = subject
    if pat.typ != nil:
      ctx.checkTypeTest(pat)
      let k = ctx.classifyType(pat.typ)
      owner = subjectOf(k, declTypeName(pat.typ), pat.typ, pat.info)
    var parts: seq[NsNode] = @[]
    let ot = owner.rtype
    if ot != nil and ot.kind == nsnTupleType and ot.sons.len == pat.sons.len:
      pat.strVal = "tuple"
      for e in ot.sons: parts.add e.typ
    elif ctx.scope.classes.hasKey(owner.typeName):
      for o in ctx.scope.memberOverloads(owner.typeName, "Deconstruct"):
        if o.len == pat.sons.len:
          pat.strVal = "Deconstruct"
          for p in o: parts.add p.typ
          break
    if pat.strVal.len == 0:
      nsError(ctx.config, pat.info, ndUnsupported,
              "a positional pattern on a type without a matching Deconstruct")
      return
    pat.rtype = owner.rtype
    if pat.name.len > 0:
      ctx.declare(pat.name, owner.typeKind, owner.typeName, owner.rtype)
    for i, x in pat.sons:
      let et = parts[i]
      ctx.walkPattern(x, subjectOf(ctx.classifyType(et), declTypeName(et), et, x.info))
    pat.argParam = nsn(nsnTupleType, pat.info)
    for et in parts: pat.argParam.add nsnParam("", et, pat.info)
  of nsnPatList:
    ## `[p, .., q]`: each element pattern against an element of the subject; the
    ## slice's against a slice, which only an array or a string has.
    let st = subject.rtype
    var et: NsNode = nil
    if subject.typeKind == tkString:
      et = nsnTypeName("char", pat.info)
      pat.strVal = "native"
    elif st != nil and st.kind == nsnArrayType:
      et = st.typ
      pat.strVal = "native"
    else:
      if subject.typeKind == tkClass or subject.typeKind == tkSequence:
        let tn = subject.typeName
        for c in ["Count", "Length"]:
          if (ctx.scope.classes.hasKey(tn) and ctx.scope.findMemberInfo(tn, c).name.len > 0) or
             ctx.surface.member(tn, subject.typeKind, c).name.len > 0:
            pat.strVal = c
            break
        et = libResultType(ctx.surface, subject, "[]", 1)
        if et == nil and ctx.scope.classes.hasKey(tn) and
           ctx.scope.findMemberInfo(tn, NsIndexerName).name.len > 0:
          et = ctx.memberTypeOf(subject, tn, NsIndexerName)
    if pat.strVal.len == 0:
      nsError(ctx.config, pat.info, ndUnsupported,
              "a list pattern on a type without a length and an indexer")
      return
    var slices = 0
    for x in pat.sons:
      if x.kind == nsnPatSlice:
        inc slices
        if x.body != nil:
          if pat.strVal != "native":
            nsError(ctx.config, x.info, ndUnsupported,
                    "a slice pattern of a type other than an array or a string")
          else: ctx.walkPattern(x.body, subject)
      else:
        ctx.walkPattern(x, subjectOf(ctx.classifyType(et), declTypeName(et), et, x.info))
    if slices > 1: nsError(ctx.config, pat.info, ndUnsupported, "two slices in a list pattern")
  of nsnPatProp:
    ## `T { P: pat }`: each member is matched as a subject of its own type.
    var owner = subject
    if pat.typ != nil:
      let k = ctx.classifyType(pat.typ)
      owner = subjectOf(k, declTypeName(pat.typ), pat.typ, pat.info)
    if pat.name.len > 0:
      ctx.declare(pat.name, owner.typeKind, owner.typeName, owner.rtype)
    for f in pat.sons:
      let probe = nsnMember(owner, f.name, f.info)
      let k = ctx.walkExpr(probe)
      ctx.walkPattern(f.body, subjectOf(k, probe.typeName, probe.rtype, f.info))
  else: discard

proc walkExpr(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  if n == nil: return tkUnknown
  case n.kind
  of nsnIntLit:
    ## C# types an unsuffixed literal as the first of int, uint, long, ulong that
    ## holds it, and a suffix narrows that list.
    let v = n.intVal
    let name =
      case n.strVal
      of "u": (if v >= 0 and v <= 0xFFFF_FFFF: "uint" else: "ulong")
      of "l": (if v >= 0: "long" else: "ulong")
      of "ul": "ulong"
      else:
        if v >= low(int32) and v <= high(int32): ""
        elif v >= 0 and v <= 0xFFFF_FFFF: "uint"
        elif v >= 0: "long"
        else: "ulong"
    n.setType(tkInt, name)
    result = tkInt
  of nsnFloatLit:
    n.setType(tkFloat, (if n.strVal == "f": "float" else: ""))
    result = tkFloat
  of nsnIsPattern:
    ## `x is pattern`: its variables are declared in the enclosing scope, as C#
    ## scopes them to the statement's block.
    discard ctx.walkExpr(n.body)
    if n.sons.len > 0: ctx.walkPattern(n.sons[0], n.body)
    n.setType(tkBool)
    result = tkBool
  of nsnSwitchExpr:
    discard ctx.walkExpr(n.body)
    result = tkUnknown
    var name = ""
    var rt: NsNode = nil
    for arm in n.sons:
      ctx.pushScope()
      ctx.walkPattern(arm.sons[0], n.body)
      if arm.sons[1] != nil:
        discard ctx.walkExpr(arm.sons[1])
        ctx.checkCondition(arm.sons[1])
      let k = ctx.walkExpr(arm.sons[2])
      if result == tkUnknown and k != tkUnknown and arm.sons[2].kind != nsnNull:
        result = k
        name = arm.sons[2].typeName
        rt = arm.sons[2].rtype
      ctx.popScope()
    n.setType(result, name)
    n.rtype = rt
  of nsnNamedArg, nsnRefArg:
    result = ctx.walkExpr(n.body)
    n.setType(result, (if n.body != nil: n.body.typeName else: ""))
    if n.body != nil: n.rtype = n.body.rtype
  of nsnOutDecl:
    ## Declared by the call once its overload is known (`out var` takes the type).
    result = (if n.typ != nil: ctx.classifyType(n.typ) else: tkUnknown)
    n.setType(result)
  of nsnInterpolated:
    for part in n.sons:
      if part.kind == nsnInterpHole:
        discard ctx.walkExpr(part.body)
        for a in part.sons: discard ctx.walkExpr(a)
    n.setType(tkString)
    result = tkString
  of nsnStrLit: n.setType(tkString); result = tkString
  of nsnCharLit: n.setType(tkChar); result = tkChar
  of nsnBoolLit: n.setType(tkBool); result = tkBool
  of nsnNull: n.setType(tkUnknown); result = tkUnknown
  of nsnThis:
    if ctx.isStaticCtx and n.info.line > 0:
      ## `this` names the object a static member does not have (CS0026).
      nsError(ctx.config, n.info, ndThisInStatic)
    n.setType(tkClass, ctx.clsName)
    result = tkClass
  of nsnBase:
    ## `base` is `this`, seen as the base class.
    let b = (if ctx.scope.classes.hasKey(ctx.clsName): ctx.scope.classes[ctx.clsName].base
             else: "")
    n.setType((if ctx.scope.classes.hasKey(b): tkClass else: tkUnknown), b)
    result = n.typeKind
  of nsnIdent: result = ctx.walkIdent(n)
  of nsnMember: result = ctx.walkMember(n)
  of nsnCall: result = ctx.walkCall(n)
  of nsnNew:
    if n.typ == nil:
      ## `new()` whose target gave it no type.
      nsError(ctx.config, n.info, ndUnsupported, "a target-typed 'new()' without a target")
      return tkUnknown
    for a in n.sons: discard ctx.walkExpr(a)
    n.rtype = n.typ
    let k = ctx.classifyType(n.typ)
    n.setType(k, (if n.typ != nil: n.typ.name else: ""))
    if n.typ != nil and n.typ.kind == nsnTypeName:
      ## `new C(...)`: the constructors of a class the scope knows are checked the
      ## same way a method call's parameter lists are. A BCL type has none here.
      let cn = unqualified(n.typ.name)
      if ctx.scope.classes.hasKey(cn):
        ctx.warnObsolete(ctx.scope.classes[cn].obsolete, cn, n.info)
        if ctx.scope.classes[cn].isStatic:
          nsError(ctx.config, n.info, ndStaticClassInstance, cn)
        elif ctx.scope.classes[cn].isAbstract or
           ctx.scope.classes[cn].classKind == ckInterface:
          nsError(ctx.config, n.info, ndAbstractInstance, cn)
        ctx.checkCallArgs(ctx.scope.ctorOverloads(cn), n.sons, cn, cn, true, n.info)
    if n.typ != nil and n.typ.kind == nsnTypeName and n.strVal.len == 0 and
       ctx.scope.classes.hasKey(unqualified(n.typ.name)):
      ## A `required` member must be set by the object initialiser (CS9035).
      var setNames: seq[string] = @[]
      for it in n.inits:
        if it.kind == nsnInitMember: setNames.add it.name
      let cn = unqualified(n.typ.name)
      for c in ctx.scope.chain(cn):
        for m in ctx.scope.classes[c].members:
          if m.isRequired and m.name notin setNames:
            nsError(ctx.config, n.info, ndRequiredMember, c & "." & m.name)
    if n.inits.len > 0 and n.strVal.len == 0:
      ## `new T(...) { A = 1, [k] = v, x }`: the initialiser becomes ordinary
      ## statements over a temporary, checked like any other.
      inc ctx.tmpCounter
      n.strVal = "nsInit" & $ctx.tmpCounter
      let stmts = initStatements(n.strVal, n.inits, n.info)
      ctx.pushScope()
      ctx.declare(n.strVal, k, (if n.typ != nil: canonicalTypeName(n.typ.name) else: ""),
                  n.typ)
      for st in stmts: ctx.walkStmt(st)
      ctx.popScope()
      n.inits = stmts
    result = k
  of nsnNewArray, nsnArrayLit:
    for a in n.sons:
      if n.typ != nil and n.kind == nsnArrayLit: ctx.targetTyped(a, n.typ)
      discard ctx.walkExpr(a)
      if n.typ != nil and n.kind == nsnArrayLit:
        ## Each element converts to the element type: `object[] { 1, "a" }` boxes.
        ctx.coerce(a, declTypeName(n.typ), a.info, n.typ)
    if n.kind == nsnArrayLit and n.typ == nil:
      ## `new[] { 1.5, 2.5 }`: the element type is the elements'.
      for a in n.sons:
        let vt = valueType(a)
        if vt != nil:
          n.typ = vt
          break
    let at = (if n.typ != nil: nsnArrayType(n.typ, n.info) else: nil)
    n.rtype = at
    n.setType(tkSequence, (if at != nil: declTypeName(at) else: ""))
    result = tkSequence
  of nsnAnonNew:
    ## `new { Name = x, Age = 3 }`: a sealed record-like class per shape (names
    ## and types, in order), synthesized here because only now are the values'
    ## types known. The expression becomes a `new` of it.
    var params: seq[NsNode] = @[]
    var key = ""
    var ok = true
    for e in n.sons:
      discard ctx.walkExpr(e.body)
      if e.body.kind == nsnIntLit and e.body.typeName.len == 0: e.body.conv = "int"
      var t = valueType(e.body)
      if t == nil and e.body.kind == nsnCast: t = e.body.typ
      if e.body.kind == nsnNull or e.body.kind == nsnLambda:
        nsError(ctx.config, e.info, ndAnonBadValue,
                (if e.body.kind == nsnNull: "<null>" else: "lambda expression"))
        ok = false
      elif t == nil:
        nsError(ctx.config, e.info, ndUnsupported,
                "an anonymous type member whose type is not known")
        ok = false
      for q in params:
        if q.name == e.name and e.name.len > 0:
          nsError(ctx.config, e.info, ndAnonDuplicate)
          ok = false
      params.add nsnParam(e.name, t, e.info)
      key.add e.name & ":" & mangleType(t) & ";"
    if not ok:
      n.setType(tkUnknown)
      return tkUnknown
    var cn = ctx.scope.anonTypes.getOrDefault(key)
    if cn.len == 0:
      cn = "nsAnon" & $ctx.scope.anonTypes.len
      ctx.scope.anonTypes[key] = cn
      let cls = nsn(nsnClassDecl, n.info)
      cls.name = cn
      cls.classKind = ckClass
      cls.attrs = NsAttrs(access: aInternal, isSealed: true, isRecord: true, isAnon: true)
      for q in params: cls.params.add nsnParam(q.name, copyNsTree(q.typ), q.info)
      synthesizeRecord(cls)
      collect(cls, ctx.scope)
      ctx.scope.anonDecls.add cls
    var values: seq[NsNode] = @[]
    for e in n.sons: values.add e.body
    n.kind = nsnNew
    n.sons = values
    n.typ = nsnTypeName(cn, n.info)
    n.rtype = n.typ
    n.setType(tkClass, cn)
    result = tkClass
  of nsnTupleLit:
    ## `(1, "one")`: a tuple whose element types are its values'; a C# int
    ## literal is an `int`, which Nim's would not be.
    let tt = nsn(nsnTupleType, n.info)
    for e in n.sons:
      let v = (if e.kind == nsnNamedArg: e.body else: e)
      discard ctx.walkExpr(e)
      if v.kind == nsnIntLit and v.typeName.len == 0: v.conv = "int"
      tt.add nsnParam((if e.kind == nsnNamedArg: e.name else: ""), valueType(v), e.info)
    n.rtype = tt
    n.setType(tkTuple)
    result = tkTuple
  of nsnIndex:
    discard ctx.walkExpr(n.body)
    var hasRange, hasHat = false
    for a in n.sons:
      if a == nil: continue
      if a.kind == nsnRange:
        hasRange = true
        for x in a.sons:
          if x != nil:
            if x.kind == nsnFromEnd: discard ctx.walkExpr(x.body) else: discard ctx.walkExpr(x)
      elif a.kind == nsnFromEnd:
        hasHat = true
        discard ctx.walkExpr(a.body)
      else: discard ctx.walkExpr(a)
    if hasRange or hasHat:
      let rk = n.body.typeKind
      let native = rk == tkString or (rk == tkSequence and n.body.typeName.endsWith("[]"))
      if native:
        ## An array or a string: Nim's `^k` and slices mean what C#'s do.
        n.strVal = "native"
        if hasRange:
          n.setType(rk, n.body.typeName)
          n.rtype = n.body.rtype
          return rk
      elif hasRange:
        nsError(ctx.config, n.info, ndUnsupported,
                "a range of a type other than an array or a string")
        return tkUnknown
      else:
        ## C#'s implicit index support: `x[^k]` is `x[x.Count - k]` for a type
        ## with an indexer and a `Count` (or `Length`).
        let tn = n.body.typeName
        var countName = ""
        for c in ["Count", "Length"]:
          if (ctx.scope.classes.hasKey(tn) and ctx.scope.findMemberInfo(tn, c).name.len > 0) or
             ctx.surface.member(tn, rk, c).name.len > 0:
            countName = c
            break
        if countName.len == 0:
          nsError(ctx.config, n.info, ndUnsupported, "'^' on a type without Count or Length")
          return tkUnknown
        n.strVal = "count:" & countName
        let mt = libResultType(ctx.surface, n.body, "[]", n.sons.len)
        if mt != nil:
          result = ctx.classifyType(mt)
          n.setType(result, declTypeName(mt))
          n.rtype = mt
          return result
        if ctx.scope.classes.hasKey(tn) and
           ctx.scope.findMemberInfo(tn, NsIndexerName).name.len > 0:
          let it = ctx.memberTypeOf(n.body, tn, NsIndexerName)
          result = ctx.classifyType(it)
          n.setType(result, declTypeName(it))
          n.rtype = it
          return result
        n.setType(tkUnknown)
        return tkUnknown
    result = tkUnknown
    let rn = (if n.body != nil: n.body.typeName else: "")
    if n.body != nil and n.body.typeKind == tkSequence and rn.endsWith("[]"):
      ## An array element has the array's element type.
      let elem = rn[0 ..< rn.len - 2]
      result = (if elem.endsWith("[]"): tkSequence else: ctx.classifyName(elem))
      n.setType(result, elem)
    elif n.body != nil and n.body.typeKind == tkString:
      result = tkChar
      n.setType(tkChar, "char")
    elif n.body != nil and libResultType(ctx.surface, n.body, "[]", n.sons.len) != nil:
      ## A library collection's element (`dict[k]`): the receiver's type argument.
      let mt = libResultType(ctx.surface, n.body, "[]", n.sons.len)
      result = ctx.classifyType(mt)
      n.setType(result, declTypeName(mt))
      n.rtype = mt
    elif n.body != nil and n.body.typeKind == tkClass and
         ctx.scope.findMemberInfo(rn, NsIndexerName).name.len > 0:
      ## A user indexer: its declared element type, seen through the receiver.
      let mt = ctx.memberTypeOf(n.body, rn, NsIndexerName)
      result = ctx.classifyType(mt)
      n.setType(result, declTypeName(mt))
      n.rtype = mt
    else:
      n.setType(tkUnknown)
  of nsnUnary:
    result = ctx.walkExpr(n.body)
    n.setType(result, n.body.typeName)
    n.rtype = n.body.rtype
    if ctx.inChecked and result == tkClass:
      ## `-x` in a `checked` context calls `operator checked -` if the type has one.
      let cop = ctx.scope.userOperator(n.body.typeName, n.name, 1, checked = true)
      if cop != nil: n.argParam = cop
  of nsnIncDec:
    result = ctx.walkExpr(n.body)
    ctx.noteMutation(n.body)
    n.setType(result, n.body.typeName)
    n.rtype = n.body.rtype
  of nsnCast:
    ctx.checkTypeTest(n)
    block userConversion:
      ## `(T)x` through a user-defined conversion, implicit or explicit: lowering
      ## calls the operator by name.
      discard ctx.walkExpr(n.body)
      let src = (if n.body.typeName.len > 0: canonicalTypeName(n.body.typeName)
                 else: numName(n.body))
      if src.len > 0 and n.typ != nil and n.typ.kind == nsnTypeName:
        var op: NsNode = nil
        if ctx.inChecked:
          ## `explicit operator checked int` is the one a `checked` cast calls.
          op = ctx.scope.conversionOp(src, canonicalTypeName(n.typ.name), false,
                                      checked = true)
        if op == nil:
          op = ctx.scope.conversionOp(src, canonicalTypeName(n.typ.name), false)
        if op != nil:
          n.argParam = op
          let k = ctx.classifyType(n.typ)
          n.setType(k, canonicalTypeName(n.typ.name))
          n.rtype = n.typ
          return k
    ## `(T)x` converts, which covers numbers, enums and ref objects; `(object)v`
    ## boxes a value and `(T)o` unboxes one.
    let target = ctx.classifyType(n.typ)
    discard ctx.walkExpr(n.body)
    if isObjectTarget(n.typ):
      ctx.coerce(n.body, "object", n.info)
    elif canonicalTypeName(n.body.typeName) in ["object", "Object"] and
         not ctx.scope.isInterface(declTypeName(n.typ)):
      n.strVal = "unbox"
    n.setType(target)
    result = target
  of nsnIs:
    ctx.checkTypeTest(n)
    discard ctx.walkExpr(n.body)
    ## A value type is tested statically and a class dynamically; an `object`
    ## asks the library, since it may hold a box.
    n.name = if canonicalTypeName(n.body.typeName) in ["object", "Object"]: "nsIsType"
             elif ctx.classifyType(n.typ) in NsValueKinds: "is" else: "of"
    n.setType(tkBool)
    result = tkBool
  of nsnAs:
    ctx.checkTypeTest(n)
    discard ctx.walkExpr(n.body)
    let target = ctx.classifyType(n.typ)
    if target in NsValueKinds:
      ## C# rejects `as` on a value type, which is what a cast is for.
      nsError(ctx.config, n.info, ndUnsupported, "'as' with a value type")
    n.setType(target)
    result = target
  of nsnDefault:
    if n.typ == nil:
      nsError(ctx.config, n.info, ndUnsupported, "a 'default' literal without a target")
      return tkUnknown
    result = ctx.classifyType(n.typ)
    n.setType(result, declTypeName(n.typ))
    n.rtype = n.typ
  of nsnBinary:
    var lk = ctx.walkExpr(n.sons[0])
    var rk = ctx.walkExpr(n.sons[1])
    if n.name in ["==", "!="]:
      ## `s == null` for a string compares with the empty string.
      if lk == tkString: ctx.markNull(n.sons[1], "string")
      if rk == tkString: ctx.markNull(n.sons[0], "string")
    result = tkUnknown
    let ln = numName(n.sons[0])
    let rn = numName(n.sons[1])
    var numResult = ""
    if ln.len > 0 and rn.len > 0:
      if n.name in ["shl", "shr"]:
        ## The count is an `int`; the result is the promoted left operand.
        numResult = unaryPromoted(ln)
        needConv(n.sons[0], numResult)
      elif n.name in ["==", "!=", "<", ">", "<=", ">="] and ln == "char" and rn == "char":
        discard
      else:
        let p = promoted(ln, rn)
        if p.len > 0:
          needConv(n.sons[0], p)
          needConv(n.sons[1], p)
          if n.name notin ["==", "!=", "<", ">", "<=", ">="]:
            numResult = p
            ## The operands now have the promoted type, which is what the integer
            ## division rule below asks about.
            lk = kindOfNumeric(p)
            rk = lk
    case n.name
    of "==", "!=", "<", ">", "<=", ">=":
      result = tkBool
    of "and", "or", "xor":
      ## Bitwise on integers, logical otherwise.
      result = (if lk == tkInt and rk == tkInt: tkInt else: tkBool)
    of "/":
      if lk == tkInt and rk == tkInt:
        ## C# integer division truncates and throws on a zero divisor; the
        ## intrinsics carry `nsDiv`, because Nim's `/` is floating point and its
        ## zero check rides on `overflowChecks`, which N# turns off.
        n.name = "nsDiv"
        result = tkInt
      elif lk == tkNullable or rk == tkNullable:
        ## The library lifts the operator and reuses the same division check, so the
        ## operator keeps its name and the result is absent when an operand is.
        result = tkNullable
      elif lk == tkFloat or rk == tkFloat:
        result = tkFloat
    of "mod":
      if lk == tkInt and rk == tkInt:
        ## Same reasoning as `/`.
        n.name = "nsMod"
        result = tkInt
      elif lk == tkNullable or rk == tkNullable:
        result = tkNullable
    of "+":
      ## C# concatenates when either operand is a string.
      if lk == tkString or rk == tkString: result = tkString
      elif lk == tkNullable or rk == tkNullable: result = tkNullable
      elif lk == tkFloat or rk == tkFloat: result = tkFloat
      elif lk == tkInt: result = tkInt
    else:
      if lk == tkNullable or rk == tkNullable: result = tkNullable
      elif lk == tkFloat or rk == tkFloat: result = tkFloat
      elif lk == tkInt: result = tkInt
    if numResult.len > 0 and result in {tkInt, tkFloat}:
      n.setType(kindOfNumeric(numResult), numResult)
    else:
      n.setType(result)
    for side in [n.sons[0], n.sons[1]]:
      if side != nil and side.typeKind == tkClass:
        let op = ctx.scope.userOperator(side.typeName, csOperatorOf(n.name), 2)
        if op != nil:
          ## `a + b` on a type that declares `operator +`.
          result = ctx.classifyType(op.typ)
          n.setType(result, declTypeName(op.typ))
          n.rtype = op.typ
          if ctx.inChecked:
            ## ... and in a `checked` context, its `operator checked +` if it has one.
            let cop = ctx.scope.userOperator(side.typeName, csOperatorOf(n.name), 2,
                                             checked = true)
            if cop != nil: n.argParam = cop
          break
  of nsnNullDot:
    ## `a?.B`: the guarded value goes back where the marker stood, so the tail is
    ## checked like any other expression. C# makes a value-typed result `T?`, which
    ## N# has no type for, so `??` must supply the absent value.
    discard ctx.walkExpr(n.body)
    if n.sons.len > 0 and n.sons[0] != nil:
      n.sons[0] = replaceMarked(n.sons[0], n.name, n.body)
      result = ctx.walkExpr(n.sons[0])
    else:
      result = tkUnknown
    if result in {tkInt, tkFloat, tkBool, tkChar} and n.intVal == 0:
      nsError(ctx.config, n.info, ndUnsupported,
              "a null-conditional value without '??'")
    n.setType(result)
  of nsnAssign:
    ## `(x = e)` as a value: the assignment, then `x`'s type.
    ctx.walkStmt(n)
    n.setType(n.sons[0].typeKind, n.sons[0].typeName)
    n.rtype = n.sons[0].rtype
    result = n.sons[0].typeKind
  of nsnThrow:
    ## A throw expression has no type of its own: it takes the other operand's.
    discard ctx.walkExpr(n.body)
    ctx.checkThrow(n)
    n.setType(tkUnknown)
    result = tkUnknown
  of nsnWith:
    ## `r with { ... }`: the initialiser applies to a copy, checked as
    ## assignments to a temporary of `r`'s type.
    result = ctx.walkExpr(n.body)
    n.setType(result, n.body.typeName)
    n.rtype = n.body.rtype
    let cn = canonicalTypeName(n.body.typeName)
    if ctx.scope.classes.hasKey(cn) and ctx.scope.classes[cn].classKind == ckClass and
       ctx.scope.classes[cn].decl != nil and not ctx.scope.classes[cn].decl.attrs.isRecord:
      nsError(ctx.config, n.info, ndWithNotRecord, cn)
    if n.strVal.len == 0:
      inc ctx.tmpCounter
      n.strVal = "nsInit" & $ctx.tmpCounter
      let stmts = initStatements(n.strVal, n.inits, n.info)
      ctx.pushScope()
      ctx.declare(n.strVal, result, n.body.typeName, n.body.rtype)
      for st in stmts: ctx.walkStmt(st)
      ctx.popScope()
      n.inits = stmts
  of nsnCollection:
    ## A collection expression into an array with spreads (the other targets were
    ## rewritten by `targetTyped`); without a target it has no type (CS9176).
    if n.typ == nil:
      nsError(ctx.config, n.info, ndNoCollectionTarget)
      return tkUnknown
    let et = n.typ.typ
    for e in n.sons:
      if e.kind == nsnSpread: discard ctx.walkExpr(e.body)
      else:
        ctx.targetTyped(e, et)
        discard ctx.walkExpr(e)
        ctx.checkConvertible(e, ctx.targetOfType(et), e.info)
        ctx.coerce(e, declTypeName(et), e.info, et)
    n.rtype = n.typ
    n.setType(tkSequence, declTypeName(n.typ))
    result = tkSequence
  of nsnFromEnd, nsnRange:
    ## `^k` and `a..b` are `System.Index` / `System.Range` values outside an
    ## element access, which the library does not declare.
    nsError(ctx.config, n.info, ndUnsupported, "an index or range value outside '[...]'")
    result = tkUnknown
  of nsnTypeOf:
    ## A `Type` names the type, a constructed one with its arguments' names.
    discard ctx.classifyType(n.typ)
    if n.typ == nil or n.typ.kind notin {nsnTypeName, nsnArrayType}:
      nsError(ctx.config, n.info, ndUnsupported, "'typeof' of a tuple or nullable type")
    n.setType(tkClass, "Type")
    n.rtype = nsnTypeName("Type", n.info)
    result = tkClass
  of nsnSizeOf:
    ## Only the built-in value types have a size outside an unsafe context.
    let k = ctx.classifyType(n.typ)
    if k notin {tkInt, tkFloat, tkBool, tkChar}:
      nsError(ctx.config, n.info, ndUnsupported, "'sizeof' of a type other than a built-in value type")
    n.setType(tkInt, "int")
    result = tkInt
  of nsnCheckedExpr:
    let savedChecked = ctx.inChecked
    ctx.inChecked = n.name == "checked"
    result = ctx.walkExpr(n.body)
    ctx.inChecked = savedChecked
    n.setType(result, n.body.typeName)
    n.rtype = n.body.rtype
    n.conv = n.body.conv
  of nsnNullCoalesce:
    ## `a ?? b`. With a `?.` on the left, `b` is the absent value for *every* link of
    ## that chain, which is how a value-typed `a?.V ?? b` works without `Nullable<T>`.
    let lhs = if n.sons.len > 0: n.sons[0] else: nil
    if lhs != nil and lhs.kind == nsnNullDot:
      markCoalesced(lhs)
      result = ctx.walkExpr(lhs)
    else:
      let lk = ctx.walkExpr(lhs)
      if lk in {tkInt, tkFloat, tkBool, tkChar}:
        nsError(ctx.config, n.info, ndUnsupported,
                "'??' with a value that cannot be absent")
      result = lk
    if n.sons.len > 1: discard ctx.walkExpr(n.sons[1])
    n.setType(result)
  of nsnTernary:
    discard ctx.walkExpr(n.sons[0])
    let a = ctx.walkExpr(n.sons[1])
    result = ctx.walkExpr(n.sons[2])
    let an = numName(n.sons[1])
    let bn = numName(n.sons[2])
    if an.len > 0 and bn.len > 0 and an != bn:
      ## `c ? 1 : 2.5` is a `double`: the branches meet at the wider type.
      let p = (if implicitlyConvertible(an, bn): bn
               elif implicitlyConvertible(bn, an): an
               else: "")
      if p.len > 0:
        needConv(n.sons[1], p)
        needConv(n.sons[2], p)
        n.setType(kindOfNumeric(p), p)
        return kindOfNumeric(p)
    if result == tkUnknown: result = a
    n.setType(result, (if n.sons[2].typeName.len > 0: n.sons[2].typeName
                       else: n.sons[1].typeName))
  of nsnLambda:
    ## Parameters start untyped (they are filled in from the declared delegate
    ## type during lowering) but the body must still be walked, otherwise names
    ## inside it are never resolved.
    ctx.pushScope()
    let savedHost = ctx.yieldHost
    ctx.yieldHost = yhNone
    for p in n.params:
      if p.typ != nil: ctx.declare(p.name, ctx.classifyType(p.typ), declTypeName(p.typ),
                                   p.typ)
      else: ctx.declare(p.name, tkUnknown)
    if n.body != nil:
      ctx.walkInScope(n.body.sons)
    ctx.yieldHost = savedHost
    ctx.popScope()
    n.setType(tkDelegate)
    result = tkDelegate
  else:
    ## Unknown shapes are walked conservatively rather than skipped silently.
    if n.body != nil: discard ctx.walkExpr(n.body)
    for a in n.sons: discard ctx.walkExpr(a)
    n.setType(tkUnknown)
    result = tkUnknown

# --- statements -------------------------------------------------------------

proc walkStmts(ctx: var NsCheckContext; stmts: seq[NsNode]) =
  ## A sequence of statements in its own name scope. A local function may be called
  ## before its declaration, so the block's local functions are declared first.
  ctx.pushScope()
  for s in stmts:
    if s != nil and s.kind == nsnLocalFunc:
      ctx.declare(s.name, tkDelegate, NsLocalFuncMark, s)
  for s in stmts: ctx.walkStmt(s)
  ctx.popScope()

proc walkDecl(ctx: var NsCheckContext; n: NsNode)

proc walkRefDecl(ctx: var NsCheckContext; n: NsNode) =
  ## `ref T r = ref x;`: `r` names the variable `x`, which must be given by `ref`.
  if n.body == nil or n.body.kind != nsnRefArg:
    nsError(ctx.config, n.info, ndUnsupported, "a 'ref' local without a 'ref' initialiser")
    return
  let k = ctx.walkExpr(n.body)
  let t = (if n.typ != nil: n.typ else: n.body.rtype)
  ctx.declare(n.name, (if n.typ != nil: ctx.classifyType(n.typ) else: k),
              (if n.typ != nil: declTypeName(n.typ) else: n.body.typeName), t)
  ctx.types[n.name].isRef = true

proc walkDecl(ctx: var NsCheckContext; n: NsNode) =
  ## Resolves a declaration's initialiser, then introduces the local (or the
  ## parameter) in the current scope so later statements see its type. A declared
  ## type makes the initialiser a conversion C# may refuse.
  if n.paramMod == "ref" and n.kind == nsnLocalDecl:
    ctx.walkRefDecl(n)
    return
  ctx.checkLibraryInterfaceValue(n.typ)
  var kind = ctx.classifyType(n.typ)
  ctx.targetTyped(n.body, n.typ)
  if n.body != nil and n.body.kind == nsnLambda and n.typ != nil:
    ## `Func<int, int> f = x => ...;`: the declared delegate types the lambda.
    applySig(n.body, delegateSig(ctx.scope, ctx.surface, n.typ))
  if n.body != nil:
    let initKind = ctx.walkExpr(n.body)
    if n.typ == nil: kind = initKind
    else:
      ctx.checkConvertible(n.body, ctx.targetOfType(n.typ), n.body.info)
      ctx.coerce(n.body, declTypeName(n.typ), n.body.info, n.typ)
  ## An inferred local (`var x = ...`) takes its type name from its initialiser,
  ## exactly as a `foreach` variable takes it from the collection it walks.
  ctx.declare(n.name, kind, (if n.typ != nil: declTypeName(n.typ) else: n.body.typeName),
              (if n.typ != nil: n.typ elif n.body != nil: n.body.rtype else: nil))

proc enumeratedElement(ctx: NsCheckContext; n: NsNode): NsNode =
  ## The element type `foreach` sees in a collection: an `IEnumerable<T>`'s `T`, or
  ## for a class with a `GetEnumerator` method -- C#'s pattern, which needs no
  ## interface -- what its enumerator's `Current` is. The latter marks the loop,
  ## because it lowers to the enumerator's `MoveNext`/`Current` rather than `items`.
  let coll = n.body
  result = iteratorElement(coll.rtype)
  if result != nil: return
  if coll.rtype != nil and coll.rtype.kind == nsnTypeName and
     coll.rtype.sons.len == 1 and
     not ctx.scope.classes.hasKey(canonicalTypeName(coll.rtype.name)) and
     ctx.surface.member(coll.typeName, coll.typeKind, "items").name.len > 0:
    ## A library collection of one element type (`List<T>`, `Queue<T>`), which the
    ## library walks with `items`, yields that type.
    return coll.rtype.sons[0]
  if coll.typeKind != tkClass or not ctx.scope.classes.hasKey(coll.typeName): return
  let ge = ctx.scope.findMemberInfo(coll.typeName, "GetEnumerator")
  if ge.name.len == 0 or not ge.isMethod: return
  n.strVal = "GetEnumerator"
  var et = iteratorElement(ge.typ)
  if et == nil and ge.typ != nil and ctx.scope.classes.hasKey(declTypeName(ge.typ)):
    let cur = ctx.scope.findMemberInfo(declTypeName(ge.typ), "Current")
    if cur.name.len > 0: et = cur.typ
  if et != nil and ctx.scope.classes.hasKey(ge.owner) and coll.rtype != nil and
     coll.rtype.kind == nsnTypeName:
    et = substitute(et, ctx.scope.classes[ge.owner].typeParams, coll.rtype.sons)
  result = et

proc walkForeach(ctx: var NsCheckContext; n: NsNode) =
  var elemKind = ctx.classifyType(n.typ)
  discard ctx.walkExpr(n.body)
  var elemName = (if n.typ != nil: declTypeName(n.typ) else: n.body.typeName)
  var elemType = n.typ
  let et = ctx.enumeratedElement(n)
  if n.typ == nil and et != nil:
    elemType = et
    elemKind = ctx.classifyType(et)
    elemName = declTypeName(et)
  elif n.typ == nil and n.body.typeKind == tkSequence and elemName.endsWith("[]"):
    ## `foreach (var x in xs)` over an array: `x` has the element type.
    elemName = elemName[0 ..< elemName.len - 2]
    elemKind = (if elemName.endsWith("[]"): tkSequence else: ctx.classifyName(elemName))
  ctx.pushScope()
  ctx.declare(n.name, elemKind, elemName, elemType)
  ctx.walkInScope(n.sons)
  ctx.popScope()

proc walkFor(ctx: var NsCheckContext; n: NsNode) =
  ctx.pushScope()
  let header = n.body
  if header != nil:
    for h in header.sons:
      if h == nil: continue
      if h.kind in {nsnLocalDecl, nsnAssign}: ctx.walkStmt(h)
      else: discard ctx.walkExpr(h)
  ctx.walkInScope(n.sons)
  ctx.popScope()

proc walkTry(ctx: var NsCheckContext; n: NsNode) =
  walkBody(ctx, n.body)
  for c in n.sons:
    if c.kind == nsnCatch:
      ctx.checkCatch(c)
      ctx.pushScope()
      if c.typ != nil:
        ctx.declare(c.name, ctx.classifyType(c.typ), declTypeName(c.typ), c.typ)
      for f in c.sons:
        ## `when (filter)`: a condition over the caught exception.
        discard ctx.walkExpr(f)
        ctx.checkCondition(f)
      if c.body != nil:
        ctx.walkInScope(c.body.sons)
      ctx.popScope()
    elif c.kind == nsnFinally:
      walkBody(ctx, c.body)

proc walkSwitch(ctx: var NsCheckContext; n: NsNode) =
  ## A section's pattern variables are in scope in that section only.
  discard ctx.walkExpr(n.body)
  for sec in n.sons:
    ctx.pushScope()
    for lab in sec.sons:
      if lab.kind == nsnCaseLabel:
        ctx.walkPattern(lab.body, n.body)
        for g in lab.sons:
          discard ctx.walkExpr(g)
          ctx.checkCondition(g)
      else:
        discard ctx.walkExpr(lab)
    if sec.body != nil:
      ctx.walkInScope(sec.body.sons)
    ctx.popScope()

proc eventOf(ctx: NsCheckContext; target: NsNode): NsMemberSymbol =
  ## The event a member access names, or a zeroed symbol.
  result = NsMemberSymbol()
  if target == nil or target.kind != nsnMember or target.body == nil: return
  let owner = (if target.body.kind == nsnThis: ctx.clsName else: target.body.typeName)
  if not ctx.scope.classes.hasKey(owner): return
  let m = ctx.scope.findMemberInfo(owner, target.name)
  if m.isEvent: result = m

proc checkAssignable(ctx: NsCheckContext; target: NsNode) =
  ctx.noteMutation(target)
  ## A `const` is never assigned (CS0131); a `readonly` field only by its own class's
  ## constructors -- the static one, for a static field (CS0191 / CS0198).
  if target == nil or target.kind != nsnMember or target.body == nil: return
  var owner = ""
  if target.body.kind == nsnThis: owner = ctx.clsName
  elif target.body.typeKind == tkType: owner = target.body.typeName
  elif target.body.typeKind == tkClass: owner = target.body.typeName
  if owner.len == 0 or not ctx.scope.classes.hasKey(owner): return
  let m = ctx.scope.findMemberInfo(owner, target.name)
  if m.name.len == 0: return
  let inOwnCtor = ctx.inCtor and m.owner == ctx.clsName and not ctx.ctorIsStatic
  let inInitializer = target.body.kind == nsnIdent and target.body.name.startsWith("nsInit")
  if m.isProperty and m.noSetter and not (m.autoGetOnly and inOwnCtor):
    nsError(ctx.config, target.info, ndReadOnlyProperty, m.owner & "." & m.name)
    return
  if m.isProperty and m.initOnly and not (inOwnCtor or inInitializer):
    nsError(ctx.config, target.info, ndInitOnly, m.owner & "." & m.name)
    return
  if m.isConst:
    nsError(ctx.config, target.info, ndNotAssignable)
  elif m.isReadonly:
    let ok = ctx.inCtor and m.owner == ctx.clsName and ctx.ctorIsStatic == m.isStatic
    if not ok:
      nsError(ctx.config, target.info,
              (if m.isStatic: ndStaticReadonlyAssigned else: ndReadonlyAssigned))

proc walkStmt(ctx: var NsCheckContext; n: NsNode) =
  if n == nil: return
  case n.kind
  of nsnBlock: walkBody(ctx, n)
  of nsnLocalDecl: ctx.walkDecl(n)
  of nsnMultiDecl:
    for d in n.sons: ctx.walkDecl(d)
  of nsnDeconstruct:
    ## `(a, b) = value`: each target takes the matching element -- of a tuple, or
    ## the matching `out` parameter of the value's `Deconstruct` method.
    discard ctx.walkExpr(n.body)
    var elems: seq[NsNode] = @[]
    let vt = n.body.rtype
    if vt != nil and vt.kind == nsnTupleType:
      for e in vt.sons: elems.add e.typ
    elif n.body.typeKind == tkClass:
      let d = ctx.scope.findMemberInfo(n.body.typeName, "Deconstruct")
      if d.name.len > 0 and d.isMethod:
        n.strVal = "Deconstruct"
        for p in d.params: elems.add p.typ
    for k, t in n.sons:
      let et = (if k < elems.len: elems[k] else: nil)
      case t.kind
      of nsnLocalDecl:
        if t.typ == nil: t.typ = et
        if t.typ == nil:
          nsError(ctx.config, t.info, ndUnsupported,
                  "deconstructing a value whose element types N# cannot see")
          continue
        ctx.declare(t.name, ctx.classifyType(t.typ), declTypeName(t.typ), t.typ)
      of nsnPatDiscard: discard
      else:
        discard ctx.walkExpr(t)
        ctx.checkAssignable(t)
  of nsnLocalFunc:
    ## A local function's body, like a method's, sees the enclosing locals.
    let savedRet = ctx.retType
    let savedTps = ctx.typeParams
    for t in n.typeParams: ctx.typeParams.add t.name
    ctx.retType = n.typ
    let savedHost = ctx.yieldHost
    ctx.yieldHost = yhMember
    ctx.pushScope()
    for p in n.params: ctx.walkDecl(p)
    if n.body != nil:
      ctx.walkInScope(n.body.sons)
    ctx.popScope()
    ctx.yieldHost = savedHost
    ctx.retType = savedRet
    ctx.typeParams = savedTps
  of nsnExprStmt: discard ctx.walkExpr(n.body)
  of nsnAssign:
    if n.name.len == 0 and n.sons.len == 2 and n.sons[0].kind == nsnIdent and
       n.sons[0].name == "_" and not ctx.types.hasKey("_") and "_" notin ctx.members:
      ## `_ = e;` evaluates `e` and discards it.
      n.strVal = "discard"
      discard ctx.walkExpr(n.sons[1])
      return
    discard ctx.walkExpr(n.sons[0])
    if n.sons.len == 2 and n.sons[1].kind == nsnRefArg and n.sons[0].paramMod == "deref":
      ## `r = ref y;` points the `ref` local at another variable.
      n.strVal = "refAssign"
      discard ctx.walkExpr(n.sons[1])
      return
    if n.sons.len > 1: ctx.targetTyped(n.sons[1], n.sons[0].rtype)
    if n.sons.len > 1 and n.sons[1] != nil and n.sons[1].kind == nsnLambda:
      ## `f = x => ...;`: the target's delegate type types the lambda.
      applySig(n.sons[1], delegateSig(ctx.scope, ctx.surface, n.sons[0].rtype))
    for i in 1 ..< n.sons.len: discard ctx.walkExpr(n.sons[i])
    ctx.checkAssignable(n.sons[0])
    let ev = ctx.eventOf(n.sons[0])
    if ev.name.len > 0:
      ## `e += h` / `e -= h` on an event add and remove a handler; anything else
      ## is allowed only inside the declaring type (CS0070).
      if n.name in ["+", "-"]:
        n.strVal = (if ev.isProperty: "eventAccessor" else: "event")
      elif ev.isProperty:
        nsError(ctx.config, n.info, ndEventAccessorUse, ev.owner & "." & ev.name)
      elif ev.owner != ctx.clsName:
        nsError(ctx.config, n.info, ndEventOutside, ev.owner & "." & ev.name, ev.owner)
    elif ctx.inChecked and n.name in ["+", "-", "*", "/"] and
         n.sons[0].typeKind == tkClass:
      ## `x += y` in a `checked` context: `operator checked +`, if the type has one.
      let cop = ctx.scope.userOperator(n.sons[0].typeName, n.name, 2, checked = true)
      if cop != nil: n.argParam = cop
    elif n.name in ["+", "-"] and n.sons[0].typeKind == tkDelegate:
      ## `d += h` combines delegates' invocation lists; `d -= h` takes `h`'s out.
      n.strVal = (if n.name == "+": "combine" else: "remove")
    ## A plain `x = y` is a conversion C# may refuse; a compound one (`x += y`) is
    ## not, because C# lets the operator's own result narrow back.
    if n.name.len == 0 and n.sons.len == 2:
      ctx.checkConvertible(n.sons[1], targetOfExpr(ctx, n.sons[0]), n.info)
      if n.sons[0].typeKind != tkNullable:
        ctx.coerce(n.sons[1], numName(n.sons[0]), n.info, n.sons[0].rtype)
    elif n.sons.len == 2 and n.name in ["+", "-", "*", "/", "mod", "and", "or", "xor",
                                        "shl", "shr"]:
      ## `x op= y` is `x = (T)(x op y)`: the operands are promoted as for `x op y`,
      ## and the result is cast back to `x`'s type, which C# does implicitly here.
      let ln = numName(n.sons[0])
      let rn = numName(n.sons[1])
      if ln.len > 0 and rn.len > 0 and n.sons[0].typeKind != tkNullable:
        let p = (if n.name in ["shl", "shr"]: unaryPromoted(ln) else: promoted(ln, rn))
        if p.len > 0:
          if n.name notin ["shl", "shr"]: needConv(n.sons[1], p)
          n.strVal = (if p != ln: p else: "")
          n.typeName = ln
          n.typeKind = kindOfNumeric(p)
  of nsnIf:
    for b in n.sons:
      if b.kind == nsnIfBranch:
        discard ctx.walkExpr(b.body)
        ctx.checkCondition(b.body)
        walkStmts(ctx, b.sons)
      elif b.kind == nsnElseBranch:
        walkStmts(ctx, b.sons)
  of nsnWhile:
    discard ctx.walkExpr(n.body)
    ctx.checkCondition(n.body)
    walkStmts(ctx, n.sons)
  of nsnDoWhile:
    discard ctx.walkExpr(n.body)
    ctx.checkCondition(n.body)
    walkStmts(ctx, n.sons)
  of nsnChecked, nsnUnchecked:
    let savedChecked = ctx.inChecked
    ctx.inChecked = n.kind == nsnChecked
    walkStmts(ctx, n.sons)
    ctx.inChecked = savedChecked
  of nsnUsingStmt:
    ## The statement form scopes its resources to its body; `using var` declares
    ## them in the enclosing block.
    if n.body != nil: ctx.pushScope()
    for r in n.sons:
      if r.kind == nsnLocalDecl: ctx.walkDecl(r)
      else: discard ctx.walkExpr(r)
      ctx.checkDisposable(r)
    if n.body != nil:
      walkBody(ctx, n.body)
      ctx.popScope()
  of nsnLock:
    discard ctx.walkExpr(n.body)
    walkStmts(ctx, n.sons)
  of nsnYield:
    case ctx.yieldHost
    of yhUnsupported:
      nsError(ctx.config, n.info, ndUnsupported, "an iterator in an operator")
    of yhNone:
      nsError(ctx.config, n.info, ndYieldHere)
    of yhMember:
      if iteratorElement(ctx.retType) == nil:
        nsError(ctx.config, n.info, ndNotIteratorType,
                (if ctx.retType == nil: "void" else: declTypeName(ctx.retType)))
    if n.body != nil:
      let et = iteratorElement(ctx.retType)
      ctx.targetTyped(n.body, et)
      discard ctx.walkExpr(n.body)
      if et != nil:
        ctx.checkConvertible(n.body, ctx.targetOfType(et), n.body.info)
        ctx.coerce(n.body, declTypeName(et), n.body.info, et)
  of nsnFor: walkFor(ctx, n)
  of nsnForeach: walkForeach(ctx, n)
  of nsnSwitch: walkSwitch(ctx, n)
  of nsnTry: walkTry(ctx, n)
  of nsnReturn, nsnThrow:
    if n.kind == nsnReturn and n.body != nil and n.body.kind == nsnRefArg:
      ## `return ref xs[i]` for an array parameter: N#'s array is a value, so a
      ## parameter's elements belong to the callee's copy.
      var root = n.body.body
      while root != nil and root.kind == nsnIndex: root = root.body
      if root != nil and root.kind == nsnIdent and ctx.curMember != nil:
        for prm in ctx.curMember.params:
          if prm.name == root.name and prm.typ != nil and prm.typ.kind == nsnArrayType:
            nsError(ctx.config, n.body.info, ndUnsupported,
                    "a reference into an array parameter")
    if n.body != nil:
      if n.kind == nsnReturn: ctx.targetTyped(n.body, ctx.retType)
      discard ctx.walkExpr(n.body)
      if n.kind == nsnReturn:
        ## The declared return type is the conversion C# applies to `return`.
        if ctx.retType != nil:
          ctx.checkConvertible(n.body, ctx.targetOfType(ctx.retType), n.body.info)
          if ctx.retType.kind != nsnNullableType:
            ctx.coerce(n.body, declTypeName(ctx.retType), n.body.info, ctx.retType)
      else:
        ctx.checkThrow(n)
  else:
    ctx.walkInScope(n.sons)
    if n.body != nil: discard ctx.walkExpr(n.body)

proc walkBody(ctx: var NsCheckContext; blk: NsNode) =
  if blk != nil: walkStmts(ctx, blk.sons)

# --- classes and the module driver ------------------------------------------

proc checkBaseCtors(ctx: NsCheckContext; cls: NsNode) =
  ## C# requires every derived constructor to name a base constructor when the
  ## base has no accessible parameterless one (CS7036).
  if cls.typ == nil or cls.typ.kind != nsnTypeName: return
  let baseName = cls.typ.name
  if not ctx.scope.classes.hasKey(baseName): return
  let arities = ctx.scope.classes[baseName].ctorArities
  if arities.len == 0 or 0 in arities: return
  var anyCtor = false
  for m in cls.sons:
    if m.kind == nsnCtorDecl:
      anyCtor = true
      if m.initKind.len == 0:
        nsError(ctx.config, m.info, ndBaseConstructorRequired,
                cls.name, baseName)
  if not anyCtor:
    nsError(ctx.config, cls.info, ndConstructorRequired, cls.name, baseName)

proc declarePrimary(ctx: var NsCheckContext; m: NsNode) =
  ## An instance initialiser sees the class's primary constructor parameters.
  if m.attrs.isStatic or not ctx.scope.classes.hasKey(ctx.clsName): return
  let decl = ctx.scope.classes[ctx.clsName].decl
  if decl == nil: return
  for p in decl.primary:
    ctx.declare(p.name, ctx.classifyType(p.typ), declTypeName(p.typ), p.typ)

proc checkCheckedOperator(ctx: NsCheckContext; m: NsNode) =
  ## `operator checked op` (C# 11) exists for the operators that can overflow and
  ## for explicit conversions (CS9023, CS9024), and only beside the unchecked
  ## version, which every other context calls (CS9025).
  if m.name == "implicit":
    nsError(ctx.config, m.info, ndCheckedImplicit)
    return
  if m.name in ["++", "--"]:
    nsError(ctx.config, m.info, ndUnsupported, "a checked '" & m.name & "' operator")
    return
  if m.name != "explicit" and
     not (m.name in ["+", "-", "*", "/"] and m.params.len in 1 .. 2) or
     (m.name in ["*", "/"] and m.params.len == 1):
    nsError(ctx.config, m.info, ndCheckedNotAllowed, m.name)
    return
  var found = false
  for o in ctx.scope.classes[ctx.clsName].operators:
    if o.name == m.name and not o.attrs.isChecked and o.params.len == m.params.len:
      if m.name == "explicit":
        if o.typ != nil and m.typ != nil and declTypeName(o.typ) == declTypeName(m.typ):
          found = true
      else: found = true
  if not found:
    let shown = (if m.name == "explicit": "explicit operator " & declTypeName(m.typ)
                 else: "operator " & m.name)
    nsError(ctx.config, m.info, ndCheckedNeedsUnchecked, shown)

proc walkMemberDecl(ctx: var NsCheckContext; m: NsNode) =
  ctx.curMember = m
  if m.kind == nsnMethodDecl and m.strVal == "finalizer":
    ## C# runs a finalizer when the collector reclaims the object -- for a short
    ## program, typically never. N# has no collector to run it, so it never does;
    ## the body is still checked. Only a class has one (CS0575), without
    ## parameters (CS1026 is the parse).
    let cls = ctx.scope.classes.getOrDefault(ctx.clsName)
    if cls.classKind != ckClass:
      nsError(ctx.config, m.info, ndFinalizerInStruct)
    elif m.params.len > 0:
      nsError(ctx.config, m.info, ndCloseParenExpected)
    else:
      nsWarn(ctx.config, m.info, ndFinalizerNeverRuns, ctx.clsName)
  ctx.yieldHost = (case m.kind
                   of nsnMethodDecl, nsnPropertyDecl, nsnIndexerDecl: yhMember
                   of nsnOperatorDecl: yhUnsupported
                   else: yhNone)
  case m.kind
  of nsnOperatorDecl:
    if m.attrs.isChecked: ctx.checkCheckedOperator(m)
    let savedRet = ctx.retType
    ctx.retType = m.typ
    ctx.isStaticCtx = true
    ctx.pushScope()
    for p in m.params: ctx.walkDecl(p)
    if m.body != nil:
      ctx.walkInScope(m.body.sons)
    ctx.popScope()
    ctx.isStaticCtx = false
    ctx.retType = savedRet
  of nsnIndexerDecl:
    let savedRet = ctx.retType
    for i in 0 ..< m.sons.len:
      let acc = m.sons[i]
      if acc == nil or acc.kind == nsnEmpty: continue
      ctx.retType = (if i == 0: m.typ else: nil)
      ctx.pushScope()
      for p in m.params: ctx.walkDecl(p)
      if i == 1: ctx.declare("value", ctx.classifyType(m.typ), declTypeName(m.typ), m.typ)
      ctx.walkInScope(acc.sons)
      ctx.popScope()
    ctx.retType = savedRet
  of nsnMethodDecl:
    ## Instance methods see the class's members as bare names; static ones do
    ## not, matching the parse-time rewrite this pass replaces.
    let saved = ctx.members
    let savedRet = ctx.retType
    let savedStatic = ctx.isStaticCtx
    let savedTps = ctx.typeParams
    for t in m.typeParams: ctx.typeParams.add t.name
    ctx.isStaticCtx = m.attrs.isStatic
    ctx.retType = m.typ
    ctx.pushScope()
    for p in m.params: ctx.walkDecl(p)
    if m.body != nil:
      ctx.walkInScope(m.body.sons)
    ctx.popScope()
    ctx.members = saved
    ctx.retType = savedRet
    ctx.isStaticCtx = savedStatic
    ctx.typeParams = savedTps
  of nsnCtorDecl:
    let savedRet = ctx.retType
    ctx.retType = nil
    ctx.inCtor = true
    ctx.ctorIsStatic = m.attrs.isStatic
    ctx.isStaticCtx = m.attrs.isStatic
    ctx.pushScope()
    for p in m.params: ctx.walkDecl(p)
    for a in m.initArgs: discard ctx.walkExpr(a)
    if m.body != nil:
      ctx.walkInScope(m.body.sons)
    ctx.popScope()
    ctx.inCtor = false
    ctx.ctorIsStatic = false
    ctx.isStaticCtx = false
    ctx.retType = savedRet
  of nsnPropertyDecl:
    let savedRet = ctx.retType
    ctx.retType = m.typ
    ctx.isStaticCtx = m.attrs.isStatic
    if m.body != nil:
      ## `{ get; set; } = value;`, converted like a field initialiser.
      ctx.pushScope()
      ctx.declarePrimary(m)
      discard ctx.walkExpr(m.body)
      ctx.popScope()
      ctx.checkConvertible(m.body, ctx.targetOfType(m.typ), m.body.info)
      ctx.coerce(m.body, declTypeName(m.typ), m.body.info, m.typ)
    for i in 0 ..< m.params.len:
      let acc = m.params[i]
      if acc == nil or acc.kind == nsnEmpty: continue
      ctx.pushScope()
      ## The setter's implicit parameter is `value`; an event's `add` and
      ## `remove` both take the handler as `value` and give nothing back.
      if m.attrs.isEvent: ctx.retType = nil
      if i == 1 or m.attrs.isEvent:
        ctx.declare("value", ctx.classifyType(m.typ), declTypeName(m.typ), m.typ)
      ctx.walkInScope(acc.sons)
      ctx.popScope()
    ctx.retType = savedRet
    ctx.isStaticCtx = false
  of nsnFieldDecl:
    ## A field initialiser is a conversion to the field's type, like a local's.
    if m.body != nil:
      ctx.pushScope()
      ctx.declarePrimary(m)
      defer: ctx.popScope()
      ctx.isStaticCtx = m.attrs.isStatic
      ctx.targetTyped(m.body, m.typ)
      if m.body.kind == nsnLambda:
        applySig(m.body, delegateSig(ctx.scope, ctx.surface, m.typ))
      discard ctx.walkExpr(m.body)
      ctx.checkConvertible(m.body, ctx.targetOfType(m.typ), m.body.info)
      ctx.coerce(m.body, declTypeName(m.typ), m.body.info, m.typ)
      ctx.isStaticCtx = false
    elif m.attrs.isConst:
      nsError(ctx.config, m.info, ndConstNeedsValue)
  else: discard

proc checkSupported(ctx: NsCheckContext; cls: NsNode) =
  ## Features the frontend can parse but does not lower are rejected loudly
  ## rather than dropped silently; ignoring `interface` or `override` produced
  ## programs that looked like they worked.
  for m in cls.sons:
    if m.kind == nsnOperatorDecl and m.name in ["true", "false"]:
      nsError(ctx.config, m.info, ndUnsupported, "'operator " & m.name & "'")

proc signatureOf(cls: string; m: NsNode): string =
  ## `Shape.Area()`, as C# names a member in a diagnostic.
  result = cls & "." & m.name
  if m.kind == nsnMethodDecl: result = signature(result, m.params)

proc checkInheritance(ctx: NsCheckContext; cls: NsNode) =
  ## The rules `virtual`/`override`/`abstract`/`sealed` carry: a sealed base cannot
  ## be derived from (CS0509), an `override` needs a slot (CS0115) that is not sealed
  ## (CS0239), an abstract member needs an abstract class (CS0513) and no body
  ## (CS0500), a non-abstract one a body (CS0501), and a concrete class must fill
  ## every abstract slot it inherits (CS0534).
  if cls.primary.len > 0:
    for m in cls.sons:
      if m.kind == nsnCtorDecl and not m.attrs.isPrimary and not m.attrs.isStatic and
         m.initKind != "this":
        nsError(ctx.config, m.info, ndPrimaryNotChained)
  for m in cls.sons:
    if m.kind == nsnPropertyDecl and m.attrs.isEvent and
       (m.params.len < 2 or m.params[0] == nil or m.params[1] == nil or
        m.params[0].name != "add" or m.params[1].name != "remove"):
      ## An event with accessors declares both, and nothing else (CS0065).
      nsError(ctx.config, m.info, ndEventAccessors, cls.name & "." & m.name)
    if cls.attrs.isStatic and m.kind in {nsnFieldDecl, nsnMethodDecl, nsnPropertyDecl,
                                         nsnIndexerDecl} and
       not m.attrs.isStatic and not m.attrs.isConst:
      nsError(ctx.config, m.info, ndStaticClassMember,
              (if m.kind == nsnIndexerDecl: "this" else: m.name))
    if m.kind == nsnMethodDecl and m.params.len > 0 and m.params[0].paramMod == "this" and
       (not cls.attrs.isStatic or cls.typeParams.len > 0 or not m.attrs.isStatic):
      nsError(ctx.config, m.info, ndExtensionNotStatic)
  if cls.classKind == ckInterface: return
  if cls.typ != nil and cls.typ.kind == nsnTypeName:
    let b = canonicalTypeName(cls.typ.name)
    if ctx.scope.classes.hasKey(b) and ctx.scope.classes[b].isSealed:
      nsError(ctx.config, cls.info, ndSealedBase, cls.name, b)
  for m in cls.sons:
    if m.kind notin {nsnMethodDecl, nsnPropertyDecl}: continue
    let a = m.attrs
    if a.isOverride:
      let slot = ctx.scope.baseSlot(cls.name, m.name)
      let ch = ctx.scope.chain(cls.name)
      let outside = ctx.scope.classes[ch[^1]].base
      if slot.name.len == 0 and outside.len > 0:
        ## The chain leaves this compilation (an exception base, a library class):
        ## the slot may be there, and Nim checks the override.
        discard
      elif slot.name.len == 0 and ctx.surface.member("object", tkClass, m.name).isVirtual:
        ## `ToString`, `Equals`, `GetHashCode`: the slots `object` declares.
        discard
      elif slot.name.len == 0:
        ## A base member of that name that is not virtual is CS0506; none is CS0115.
        var hidden = ""
        for i in 1 ..< ch.len:
          for bm in ctx.scope.classes[ch[i]].members:
            if bm.name == m.name and hidden.len == 0: hidden = ch[i] & "." & m.name
        if hidden.len > 0:
          nsError(ctx.config, m.info, ndOverrideNotVirtual, signatureOf(cls.name, m),
                  hidden)
        else:
          nsError(ctx.config, m.info, ndNoOverrideSlot, signatureOf(cls.name, m))
      elif slot.isSealed:
        nsError(ctx.config, m.info, ndOverrideSealed, signatureOf(cls.name, m),
                slot.owner & "." & m.name)
    if a.isAbstract and not cls.attrs.isAbstract:
      nsError(ctx.config, m.info, ndAbstractInConcrete, signatureOf(cls.name, m),
              cls.name)
    if m.kind == nsnMethodDecl:
      if a.isAbstract and m.body != nil:
        nsError(ctx.config, m.info, ndAbstractHasBody, signatureOf(cls.name, m))
      elif not a.isAbstract and m.body == nil:
        nsError(ctx.config, m.info, ndMissingBody, signatureOf(cls.name, m))
    if a.isSealed and not a.isOverride:
      nsError(ctx.config, m.info, ndSealedNotOverride, signatureOf(cls.name, m))
  if not cls.attrs.isAbstract:
    ## Every abstract slot along the chain must be filled by the nearest override.
    let ch = ctx.scope.chain(cls.name)
    var filled: seq[string] = @[]
    for c in ch:
      for m in ctx.scope.classes[c].members:
        if m.isAbstract and m.name notin filled:
          nsError(ctx.config, cls.info, ndAbstractNotImplemented, cls.name,
                  c & "." & m.name)
          filled.add m.name
        elif not m.isAbstract and (m.isOverride or m.isVirtual):
          filled.add m.name

proc checkInterfaces(ctx: NsCheckContext; cls: NsNode) =
  ## A class or struct must implement every member of every interface it names
  ## (CS0535), implicitly by an instance member of that name or explicitly as `I.M`.
  ## A method the interface gives a body (C# 8) needs no implementation.
  if cls.classKind == ckInterface:
    for m in cls.sons:
      if m.kind == nsnMethodDecl and m.body != nil and ctx.scope.classes[cls.name].typeParams.len > 0:
        nsError(ctx.config, m.info, ndUnsupported, "a default method in a generic interface")
      elif m.attrs.isStatic and not m.attrs.isAbstract and not m.attrs.isVirtual:
        ## `static abstract` / `static virtual` (C# 11) are contracts on the type,
        ## checked by name; a plain static member of an interface is not lowered.
        nsError(ctx.config, m.info, ndUnsupported, "a static interface member with a body")
    return
  for i in ctx.scope.interfaceClosure(cls.name):
    if not ctx.scope.classes.hasKey(i): continue
    for im in ctx.scope.classes[i].members:
      if im.hasBody: continue
      var found = false
      for c in ctx.scope.chain(cls.name):
        for m in ctx.scope.classes[c].members:
          ## A static abstract member is implemented by a static one.
          if m.name == im.name and m.isStatic == im.isStatic: found = true
        if found: break
      if not found:
        for m in cls.sons:
          ## `IBox<int>.Get` is filed as `IBox_int`, one instantiation of `IBox`.
          if m.name == im.name and (m.explicitIface == i or
                                    m.explicitIface.startsWith(i & "_")):
            found = true
      if not found:
        let what = (if im.isMethod: signature(i & "." & im.name, im.params)
                    else: i & "." & im.name)
        nsError(ctx.config, cls.info, ndInterfaceNotImplemented, cls.name, what)

proc walkClass(ctx: var NsCheckContext; cls: NsNode) =
  ctx.checkSupported(cls)
  ctx.checkInheritance(cls)
  ctx.checkInterfaces(cls)
  let savedCls = ctx.clsName
  let savedMembers = ctx.members
  let savedTps = ctx.typeParams
  for t in cls.typeParams: ctx.typeParams.add t.name
  ctx.clsName = cls.name
  ctx.members = ctx.scope.memberNames(cls.name)
  for m in cls.sons: ctx.walkMemberDecl(m)
  ctx.clsName = savedCls
  ctx.members = savedMembers
  ctx.typeParams = savedTps
  ctx.checkBaseCtors(cls)

proc checkAttributes(ctx: NsCheckContext; n: NsNode) =
  ## Each `[A]` names an attribute class, `AAttribute` or `A` (CS0246), which must
  ## derive from `Attribute` (CS0616). Its arguments have no effect N# can observe
  ## without reflection, so they are not evaluated.
  if n == nil: return
  for a in n.attributes:
    let short = a.name.split('.')[^1]
    var found = ""
    for c in [short & "Attribute", short]:
      if ctx.scope.classes.hasKey(c) or ctx.surface.types.hasKey(c):
        found = c
        break
    if found.len == 0:
      nsError(ctx.config, a.info, ndNamespaceNotFound, short)
    elif ctx.scope.classes.hasKey(found) and "Attribute" notin ctx.scope.baseChain(found):
      nsError(ctx.config, a.info, ndNotAttributeClass, found)
    elif ctx.scope.classes.hasKey(found):
      ## `[Tag<int>]` (C# 11): the arguments must match the class's parameters.
      let tps = ctx.scope.classes[found].typeParams
      if tps.len == 0 and a.typeArgs.len > 0:
        nsError(ctx.config, a.info, ndNotGenericType, found)
      elif tps.len != a.typeArgs.len:
        nsError(ctx.config, a.info, ndTypeArgCount,
                found & "<" & tps.join(", ") & ">", $tps.len)
  for p in n.params: ctx.checkAttributes(p)
  if n.kind in {nsnClassDecl, nsnEnumDecl}:
    for m in n.sons: ctx.checkAttributes(m)

proc checkVariance(ctx: NsCheckContext; d: NsNode) =
  ## `in`/`out` stand only on an interface's or a delegate's type parameters
  ## (CS1960), and an `out T` may not be taken nor an `in T` given back (CS1961).
  ## Only `T` itself is checked in a position, not `T` inside another type.
  proc variant(tps: seq[NsNode]; name: string): string =
    for t in tps:
      if t.name == name: return t.strVal
    ""
  proc misplaced(ctx: NsCheckContext; tps: seq[NsNode]; t: NsNode; asInput: bool;
                 member: string) =
    if t == nil or t.kind != nsnTypeName or t.sons.len > 0: return
    let v = variant(tps, t.name)
    if (asInput and v == "out") or (not asInput and v == "in"):
      nsError(ctx.config, t.info, ndInvalidVariance, t.name,
              (if asInput: "contravariantly" else: "covariantly"), member,
              (if v == "out": "covariant" else: "contravariant"))
  proc noVariance(ctx: NsCheckContext; tps: seq[NsNode]) =
    for t in tps:
      if t.strVal.len > 0: nsError(ctx.config, t.info, ndVarianceNotAllowed)
  case d.kind
  of nsnDelegateDecl:
    for p in d.params:
      if p.paramMod.len == 0: ctx.misplaced(d.typeParams, p.typ, true, d.name)
    ctx.misplaced(d.typeParams, d.typ, false, d.name)
  of nsnClassDecl:
    if d.classKind != ckInterface: ctx.noVariance(d.typeParams)
    for m in d.sons:
      ctx.noVariance(m.typeParams)
      if d.classKind != ckInterface: continue
      case m.kind
      of nsnMethodDecl:
        for p in m.params:
          if p.paramMod.len == 0: ctx.misplaced(d.typeParams, p.typ, true, m.name)
        ctx.misplaced(d.typeParams, m.typ, false, m.name)
      of nsnPropertyDecl:
        let getter = m.params.len > 0 and m.params[0] != nil
        let setter = m.params.len > 1 and m.params[1] != nil
        if getter or m.params.len == 0: ctx.misplaced(d.typeParams, m.typ, false, m.name)
        if setter: ctx.misplaced(d.typeParams, m.typ, true, m.name)
      else: discard
  else: discard

proc walkTop(ctx: var NsCheckContext; d: NsNode) =
  ctx.checkAttributes(d)
  ctx.checkVariance(d)
  case d.kind
  of nsnClassDecl: ctx.walkClass(d)
  of nsnNamespace:
    if d.body != nil:
      for x in d.body.sons: ctx.walkTop(x)
  of nsnEnumDecl, nsnDelegateDecl, nsnUsing: discard
  else: ctx.walkStmt(d)

proc collectFileTypes(list: seq[NsNode]; config: ConfigRef;
                      owners: var Table[string, FileIndex]) =
  ## The `file` types of a compilation and the file each belongs to. A namespace's
  ## files are checked as one module, so two of them declaring a file type of one
  ## name would be a single type; that is reported rather than merged.
  for d in list:
    if d.kind == nsnNamespace and d.body != nil:
      collectFileTypes(d.body.sons, config, owners)
    elif d.kind in {nsnClassDecl, nsnEnumDecl, nsnDelegateDecl} and d.attrs.isFile:
      if owners.hasKey(d.name) and owners[d.name] != d.info.fileIndex:
        nsError(config, d.info, ndUnsupported,
                "two file-local types named '" & d.name & "' in one namespace")
      owners[d.name] = d.info.fileIndex

proc checkFileTypeUses(n: NsNode; config: ConfigRef;
                       owners: Table[string, FileIndex]) =
  ## A `file` type is unknown outside the file that declares it (CS0246).
  if n == nil: return
  if n.kind in {nsnIdent, nsnTypeName} and owners.hasKey(n.name) and
     owners[n.name] != n.info.fileIndex:
    nsError(config, n.info, ndNamespaceNotFound, n.name)
  checkFileTypeUses(n.typ, config, owners)
  checkFileTypeUses(n.body, config, owners)
  for s in [n.params, n.sons, n.initArgs, n.bases, n.constraints, n.typeArgs,
            n.inits, n.primary]:
    for c in s: checkFileTypeUses(c, config, owners)

proc checkModule*(module: NsNode; scope: NsModuleScope; config: ConfigRef) =
  ## Resolves names, enforces access control, checks the conversions and applies the
  ## base-constructor rule. Diagnostics go through `config`.
  var ctx = NsCheckContext(scope: scope, config: config,
                           surface: bclSurface(config),
                           types: newTable[string, NsTypeInfo]())
  var fileTypes = initTable[string, FileIndex]()
  collectFileTypes(module.sons, config, fileTypes)
  if fileTypes.len > 0:
    for d in module.sons: checkFileTypeUses(d, config, fileTypes)
  for d in module.sons: ctx.walkTop(d)
  ## The anonymous types the walk synthesized, checked as the declarations they
  ## now are; checking one cannot synthesize another.
  for d in ctx.scope.anonDecls:
    ctx.walkTop(d)
    module.add d
  ## After the walk, so every declaration is looked at exactly once: a `MyObj?` on a
  ## reference type is only an annotation, and C# warns about it.
  warnNullableRefs(ctx, module)