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
import ast, bcl, diagnostics, flow, lambdas, numeric, symbols

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
    iterVar*: bool             ## a `foreach` variable, which is read-only
    isConst*: bool             ## a `const` local

  NsCheckContext = object
    scope: NsModuleScope
    config: ConfigRef
    surface: NsBclSurface                       ## what the prelude declares
    clsName: string                            ## enclosing class, "" outside one
    members: seq[string]                       ## names reachable from it
    retType: NsNode                            ## enclosing member's return type
    isStaticCtx: bool                          ## inside a static member: no `this`
    typeParams: seq[string]                    ## the generic parameters in scope
    usingNamespaces: HashSet[string]           ## the namespaces the file imports or is in
    inUnsafe: bool                             ## in an unsafe context (pointers allowed)
    unsafeReported: ref HashSet[string]        ## CS0214 sites, reported once each
    curMember: NsNode                          ## the member whose body is walked
    tmpCounter: int                            ## numbers the temporaries sema introduces
    inCtor: bool                               ## inside a constructor of `clsName`
    constBody: string                          ## `Class.Member` of a const member function being walked
    ctorIsStatic: bool                         ## ... and it is the static one
    yieldHost: NsYieldHost                     ## what a `yield` here would belong to
    types: TableRef[string, NsTypeInfo]        ## locals, params, loop variables
    undo: seq[seq[(string, NsTypeInfo, bool)]] ## one frame per open scope
    inChecked: bool                            ## inside `checked`: `operator checked` applies
    lambdaDepth: int                           ## inside a lambda: `return` is the lambda's
    receiver: NsNode                           ## the receiver of the member being walked
    inIterator: bool                           ## the body walked yields: `return` ends it
    assigning: bool                            ## walking a plain assignment's target

const NsLocalFuncMark = "#local"
  ## The type name a local function is declared under, so a call can find it.

proc setType(n: NsNode; kind: NsTypeKind; name = "") =
  n.typeKind = kind
  n.typeName = name

proc kindSpelling(n: NsNode): string =
  ## A value's type as C# spells it in a diagnostic.
  if n.typeName.len > 0: return n.typeName
  case n.typeKind
  of tkInt: "int"
  of tkFloat: "double"
  of tkBool: "bool"
  of tkChar: "char"
  of tkString: "string"
  else: "?"

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
  elif t.kind == nsnPointerType:
    (if t.typ == nil or t.typ.kind == nsnVoidType: "void" else: declTypeName(t.typ)) & "*"
  elif t.kind == nsnFnPtrType: "delegate*"
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

proc dottedName(n: NsNode): string =
  ## A receiver as written, `A.B.C`, when it is a chain of names; "" otherwise.
  if n == nil: return ""
  case n.kind
  of nsnIdent: n.name
  of nsnMember:
    let head = dottedName(n.body)
    if head.len == 0: "" else: head & "." & n.name
  else: ""

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
  of nsnPointerType, nsnFnPtrType:
    ## A pointer or function pointer: what it points at is classified, it itself
    ## stays unknown, so lowering takes Nim's own operations on it.
    if t.kind == nsnPointerType and t.typ != nil:
      discard ctx.classifyType(t.typ)
    for x in t.sons: discard ctx.classifyType(x)
    t.setType(tkUnknown, declTypeName(t))
    result = tkUnknown
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
    ## A struct is a value type too: `Pt?` is a `Nullable<Pt>`.
    let struct = inner == tkClass and t.typ != nil and t.typ.kind == nsnTypeName and
      ctx.scope.classes.hasKey(canonicalTypeName(t.typ.name)) and
      ctx.scope.classes[canonicalTypeName(t.typ.name)].classKind == ckStruct
    result = if inner in {tkInt, tkFloat, tkBool, tkChar} or struct: tkNullable else: inner
    t.setType(result, declTypeName(t.typ))
  of nsnTypeName:
    ## The type arguments too (`Func<int?>`), which lowering spells as their kinds say.
    for a in t.sons: discard ctx.classifyType(a)
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
    ## The C# name of a declared number (`float` is Nim's, a `double`).
    tname = (if m.ret == "float": "double"
             elif numericOfSpelling(m.ret).len > 0 and not isNumericName(m.ret):
               numericOfSpelling(m.ret)
             else: m.ret)
    return ctx.surface.kindOfSpelling(m.ret)
  if rk == tkNullable: return ctx.classifyName(recv)
  if m.isStatic:
    ## `long.MaxValue` is a `long`, named so that what holds it can tell.
    let num = numericOfSpelling(canonicalTypeName(recv))
    if num.len > 0: tname = num
    return rk
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
  of "ushr": ">>>"
  of "nsFmod": "%"
  of "not": "!"
  else: nimOp

proc constantFitsUnsigned(e: NsNode; own, other: string): bool =
  ## A constant the other operand's unsigned type can hold (ECMA-334 10.2.11): an
  ## `int` one into any of them, a `long` one into `ulong` only.
  e != nil and e.kind == nsnIntLit and
    ((own == "int" and other in ["uint", "ulong", "nuint"]) or
     (own == "long" and other == "ulong")) and fitsLiteral(e.intVal, other)

proc numName(n: NsNode): string =
  ## The C# numeric type of an expression, or "" when it is not known exactly.
  if n == nil: return ""
  case n.kind
  of nsnIntLit: return (if n.typeName.len > 0: n.typeName else: "int")
  of nsnCharLit: return "char"
  of nsnFloatLit: return (if n.typeName.len > 0: n.typeName else: "double")
  of nsnUnary:
    ## A negated integer literal is a constant of the literal's type, `long` when
    ## the negation leaves `int`'s range.
    if n.name == "-" and n.body != nil and n.body.kind == nsnIntLit and
       n.body.typeName.len == 0:
      return (if -n.body.intVal >= low(int32): "int" else: "long")
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

proc isZeroLiteral(n: NsNode): bool =
  ## The literal `0`, which converts to every enum type.
  n != nil and n.kind == nsnIntLit and n.intVal == 0 and n.typeName.len == 0

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
  result = @[]
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
  t.kind == nsnTypeName and (ctx.scope.isValueInterface(unqualified(t.name)) or
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

proc convertsToLibIface(ctx: NsCheckContext; value: NsNode; iface: string): bool

proc userConversionFrom(ctx: NsCheckContext; src, dst: string): string =
  ## The operand type of the user-defined implicit conversion C# uses from `src`
  ## to `dst`: one from `src` itself, or after a standard numeric widening (ECMA-334
  ## 10.5.4), so `Meters m = 3;` reaches an `implicit operator Meters(double)`.
  if src.len == 0 or dst.len == 0: return ""
  if ctx.scope.conversionOp(src, dst, true) != nil: return src
  if isNumericName(src):
    for w in ["short", "int", "long", "float", "double"]:
      if implicitlyConvertible(src, w) and ctx.scope.conversionOp(w, dst, true) != nil:
        return w
  ""

proc coerce(ctx: NsCheckContext; value: NsNode; targetName: string; info: TLineInfo;
            targetType: NsNode = nil) =
  ## The implicit numeric conversion C# applies where a value of one numeric type is
  ## used as another: recorded when C# allows it, CS0266 when only a cast would.
  ## A variant interface or delegate conversion is recorded too.
  if value != nil and value.conv.len == 0 and isZeroLiteral(value) and
     ctx.scope.enums.contains(canonicalTypeName(targetName)):
    ## `Perm p = 0;`: the literal `0` is of any enum type (10.2.4).
    value.conv = canonicalTypeName(targetName)
    return
  if value != nil and value.conv.len == 0 and value.typeName.len == 0 and
     (isConstantLit(value) or value.kind == nsnFloatLit) and
     ctx.scope.classes.hasKey(canonicalTypeName(targetName)):
    ## A literal for a user type with an implicit conversion from a number takes
    ## the operator's operand type first (`V2 c = 5;`), since Nim types it `int`
    ## and does not chain a converter after a widening.
    let s = ctx.userConversionFrom(numName(value), canonicalTypeName(targetName))
    if s.len > 0:
      value.conv = s
      return
  if value != nil and value.typeKind == tkClass and value.conv.len == 0 and
     value.kind != nsnNull:
    ## A handle as one of another class of its family: `Node n = ball;`.
    let tn = (if targetType != nil and targetType.kind == nsnTypeName:
                canonicalTypeName(targetType.name) else: canonicalTypeName(targetName))
    let vn = canonicalTypeName(value.typeName)
    if tn.len > 0 and vn.len > 0 and tn != vn and ctx.scope.classes.hasKey(tn) and
       ctx.scope.classes.hasKey(vn):
      let root = ctx.scope.handleRoot(tn)
      if root.len > 0 and root == ctx.scope.handleRoot(vn):
        value.conv = "nsHandle"
        value.convType = nsnTypeName(tn, info)
        return
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
  let tIface = canonicalTypeName(target).split('<')[0]
  if value != nil and value.kind != nsnNull and tIface in ctx.scope.libValueIfaces and
     not ctx.scope.classes.hasKey(tIface) and
     canonicalTypeName(value.typeName).split('<')[0] != tIface:
    ## A collection, an array, or another interface value used as a library
    ## interface (`IList<T>`): the library's conversion for it, `nsTo<I>`.
    let conv = "nsTo" & tIface
    if ctx.scope.classes.hasKey(canonicalTypeName(value.typeName)) and
       not ctx.scope.isValueInterface(canonicalTypeName(value.typeName)):
      ## A class of this compilation: the library builds its table from the class's
      ## members, and the interface's type arguments come from the target.
      value.conv = conv
      value.convType = targetType
      return
    if ctx.convertsToLibIface(value, tIface):
      value.conv = conv
      return
  if value != nil and canonicalTypeName(target).split('<')[0] == "IEnumerable" and
     (value.typeKind == tkSequence or
      ctx.surface.member(value.typeName, value.typeKind, "nsToIEnumerable").name.len > 0):
    ## An array or a collection used as an `IEnumerable<T>`: the view the library
    ## declares for it.
    value.conv = "nsToIEnumerable"
    return
  if value != nil and canonicalTypeName(target) in ["object", "Object"] and
     value.kind != nsnNull and value.conv.len == 0 and
     ctx.scope.isValueInterface(canonicalTypeName(value.typeName).split('<')[0]):
    ## An interface value as an `object` is the instance it holds.
    value.conv = "nsIfaceObject"
    return
  if value != nil and canonicalTypeName(target) in ["object", "Object"] and
     value.kind != nsnNull and value.conv.len == 0 and
     not ctx.scope.isValueInterface(value.typeName):
    ## A value used as an `object` is boxed; a reference passes through the same
    ## library call unchanged. A string literal is one instance however often it is
    ## written (6.4.5.6), so its box is shared.
    value.conv = (if value.kind == nsnStrLit: "nsBoxLit" else: "nsBox")
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
  elif value.kind == nsnFloatLit and src == "double" and dst in ["float", "decimal"]:
    ## `float f = 1.5;`: the literal is a `double` (CS0664).
    nsError(ctx.config, info, ndFloatLiteral, dst, (if dst == "float": "F" else: "M"))
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
    typ: NsNode          ## the declared type, when the target is one

proc convertsToLibIface(ctx: NsCheckContext; value: NsNode; iface: string): bool =
  ## Whether a value converts to a library interface: a class of this compilation
  ## does (the library builds its table), anything else when the library declares
  ## `nsTo<I>` for its type -- an array's being `NsArray`.
  if value == nil: return false
  let vn = canonicalTypeName(value.typeName).split('<')[0]
  if ctx.scope.classes.hasKey(vn) and not ctx.scope.isValueInterface(vn): return true
  let head =
    if value.typeName.endsWith("[]") or
       (value.rtype != nil and value.rtype.kind == nsnArrayType): "NsArray"
    else: ctx.surface.nimSpellingOf(vn)
  if head.len == 0: return false
  let conv = "nsTo" & iface
  for key, ms in ctx.surface.members:
    for m in ms:
      if m.name == conv and m.paramTypes.len >= 1 and
         headSpelling(m.paramTypes[0]) == head:
        return true
  false

proc targetOfType(ctx: NsCheckContext; target: NsNode): NsTarget =
  ## The target of a declared type: a parameter, local, field or `return`.
  result = NsTarget(kind: tkUnknown, isNullOk: true, spelling: typeSpelling(target),
                    typ: target)
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
  let cn = canonicalTypeName(result.name)
  if result.kind == tkClass and ctx.scope.classes.hasKey(cn) and
     ctx.scope.classes[cn].classKind == ckStruct:
    ## A struct is a value: `null` is not one (CS0037).
    result.isNullOk = false

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

proc spelledTypeArgs(name: string): seq[string] =
  ## The type arguments of a spelled type, at the top level: `int` for `int[]`,
  ## `int` and `List<string>` for `Dictionary<int, List<string>>`.
  result = @[]
  if name.endsWith("[]"): return @[name[0 ..< name.len - 2]]
  let open = name.find('<')
  if open < 0 or not name.endsWith(">"): return
  var depth = 0
  var cur = ""
  for c in name[open + 1 ..< name.len - 1]:
    case c
    of '<': inc depth; cur.add c
    of '>': dec depth; cur.add c
    of ',':
      if depth == 0:
        result.add cur.strip
        cur = ""
      else: cur.add c
    else: cur.add c
  if cur.strip.len > 0: result.add cur.strip

proc isValueTypeName(ctx: NsCheckContext; name: string): bool =
  ## A type no variance applies to: a built-in value type or an enum.
  canonicalTypeName(name) in ["int", "uint", "long", "ulong", "short", "ushort",
    "byte", "sbyte", "float", "double", "decimal", "bool", "char", "nint", "nuint"] or
    ctx.scope.enums.contains(canonicalTypeName(name))

type
  NsLibConv = enum
    ## How a value converts where a library interface is involved.
    lcUndecided   ## no library interface on either side: the other rules decide
    lcFits        ## an implicit conversion
    lcCast        ## only an explicit one: an interface and a class that is not
                  ## sealed, or two interfaces (CS0266)
    lcNone        ## none at all: an array is sealed (CS0029)
    lcVariance    ## a variant conversion (`List<string>` to `IReadOnlyList<object>`),
                  ## valid C# that the library's tables do not do yet

proc libIfaceConversion(ctx: NsCheckContext; arg: NsNode; t: NsTarget): NsLibConv =
  ## A library interface (`IList<T>`, `IEnumerable<T>`) as the value's type or the
  ## target. The library declares each implicit conversion as an `nsTo<I>`, an
  ## interface into the ones it extends included; any other between an interface
  ## and a collection takes a cast, as C# says.
  result = lcUndecided
  if arg == nil or arg.kind == nsnNull or t.name.len == 0: return
  let src = canonicalTypeName(arg.typeName)
  let si = src.split('<')[0]
  let ti = canonicalTypeName(t.name).split('<')[0]
  if si.len == 0 or ti.len == 0: return
  let srcIface = si in ctx.scope.libValueIfaces or si == "IEnumerable"
  let tgtIface = ti in ctx.scope.libValueIfaces
  if not srcIface and not tgtIface: return
  if si == ti: return lcUndecided                 ## the same type: other rules
  if ti == "IEnumerable" or t.kind == tkUnknown: return lcUndecided
  if tgtIface:
    ## The element types must agree; only a reference type may vary (into the
    ## covariant `IReadOnlyList<T>` and friends), so a value type that differs is
    ## certain.
    ## The spellings with their type arguments: what the value's type was
    ## resolved to or constructed as, and what the target declares.
    let srcFull =
      if arg.rtype != nil: typeSpelling(arg.rtype)
      elif arg.kind == nsnNew and arg.typ != nil: typeSpelling(arg.typ)
      else: src
    let sa = spelledTypeArgs(srcFull)
    let ta = spelledTypeArgs(if t.typ != nil: typeSpelling(t.typ) else: t.spelling)
    var argsDiffer, argsVary = false
    if sa.len == ta.len:
      for k in 0 ..< sa.len:
        if canonicalTypeName(sa[k]) != canonicalTypeName(ta[k]):
          if ctx.isValueTypeName(sa[k]) or ctx.isValueTypeName(ta[k]): argsDiffer = true
          else: argsVary = true
    if not argsDiffer and ctx.convertsToLibIface(arg, ti):
      return (if argsVary: lcVariance else: lcFits)
    if ctx.scope.classes.hasKey(si) and not ctx.scope.isValueInterface(si):
      return lcUndecided                          ## a user class: its own rules
    if arg.typeKind notin {tkSequence, tkClass}: return lcUndecided
    return (if src.endsWith("[]"): lcNone else: lcCast)
  ## An interface into something else: a library collection or an array.
  result = (if t.name.endsWith("[]") or ctx.surface.nimSpellingOf(ti).len > 0: lcCast
            else: lcUndecided)

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
     ctx.userConversionFrom(src, canonicalTypeName(t.name)) != "":
    ## A user-defined implicit conversion (`implicit operator double(Vec v)`).
    return
  case ctx.libIfaceConversion(arg, t)
  of lcFits: return
  of lcCast, lcNone, lcVariance:
    result = true
    return
  of lcUndecided: discard
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
    let ti = canonicalTypeName(t.name).split('<')[0]
    result = t.kind != tkSequence and
             not canonicalTypeName(t.name).startsWith("IEnumerable") and
             not (ti in ctx.scope.libValueIfaces and ctx.convertsToLibIface(arg, ti))
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

proc nullableValue(ctx: NsCheckContext; v, target: NsNode) =
  ## A value where a `T?` is wanted (a `return`, a lambda's result): `some`/`none`
  ## with the element type, as for an argument.
  let conv = ctx.argConv(v, target)
  if conv != acNone and v.argConv == acNone:
    v.argConv = conv
    v.argConvType = declTypeName(target.typ)

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
      ## Named in its own position (C# 7.2), it lets positional arguments follow.
      if k == pos: inc pos
    elif pos < params.len and filled[pos] and
         (params[pos] == nil or params[pos].paramMod != "params"):
      result.fits = false
      return
    elif pos < params.len and params[pos] != nil and params[pos].paramMod == "params":
      result.slot[j] = pos
      filled[pos] = true
      ## One array argument is the array itself (the normal form, 12.6.4.2): an
      ## array, `new[] { .. }` before its element type is known, or `null`;
      ## anything else is an element. An array whose elements are arrays only
      ## stands for itself when it is one, so `null` and `new[]` are elements then.
      let v = argValue(a)
      let pt = params[pos].typ
      let nested = pt != nil and pt.kind == nsnArrayType and pt.typ != nil and
                   pt.typ.kind == nsnArrayType
      let whole = v.typeKind == tkSequence or
                  (not nested and v.kind in {nsnNull, nsnArrayLit, nsnNewArray})
      result.element[j] = not (j == args.len - 1 and j == pos and whole)
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

type
  NsTyDesc = object
    ## A type as overload resolution compares it: its C# name, and whether it is
    ## the `T?` of a value type. `known` is false where sema has no exact type.
    name: string
    nullable: bool
    known: bool

proc descOfType(ctx: NsCheckContext; t: NsNode): NsTyDesc =
  if t == nil: return
  if t.kind == nsnNullableType:
    if ctx.classifyType(t.typ) in NsValueTargetKinds + {tkClass}:
      let n = declTypeName(t.typ)
      let struct = n in ["int", "uint", "long", "ulong", "short", "ushort", "byte",
                         "sbyte", "float", "double", "bool", "char", "nint", "nuint"] or
                   ctx.scope.enums.contains(n) or
                   (ctx.scope.classes.hasKey(n) and ctx.scope.classes[n].classKind == ckStruct)
      return NsTyDesc(name: n, nullable: struct, known: true)
  let n = declTypeName(t)
  NsTyDesc(name: n, known: n.len > 0)

proc descOfArg(v: NsNode): NsTyDesc =
  if v == nil: return
  if v.kind == nsnNull: return NsTyDesc(name: "<null>", known: true)
  let num = numName(v)
  if num.len > 0: return NsTyDesc(name: num, known: true)
  case v.typeKind
  of tkString: NsTyDesc(name: "string", known: true)
  of tkBool: NsTyDesc(name: "bool", known: true)
  of tkChar: NsTyDesc(name: "char", known: true)
  of tkNullable:
    NsTyDesc(name: canonicalTypeName(v.typeName), nullable: true, known: v.typeName.len > 0)
  of tkClass, tkSequence:
    NsTyDesc(name: canonicalTypeName(v.typeName), known: v.typeName.len > 0)
  else: NsTyDesc()

proc same(a, b: NsTyDesc): bool = a.known and b.known and a.name == b.name and
                                  a.nullable == b.nullable

proc implicitTo(ctx: NsCheckContext; a, b: NsTyDesc): bool =
  ## Whether C# converts a value of type `a` to `b` implicitly (ECMA-334 10.2):
  ## identity, numeric widening (lifted for `T?`), boxing to `object`, a base class
  ## or interface, a user-defined implicit conversion.
  if not (a.known and b.known): return false
  if same(a, b): return true
  if b.name == "object" and not b.nullable: return true
  if isNumericName(a.name) and isNumericName(b.name):
    if a.nullable and not b.nullable: return false
    return implicitlyConvertible(a.name, b.name)
  if b.nullable and not a.nullable and a.name == b.name: return true
  if a.nullable or b.nullable: return false
  if ctx.scope.classes.hasKey(a.name) and ctx.scope.implements(a.name, b.name): return true
  ctx.scope.conversionOp(a.name, b.name, true) != nil

proc betterTarget(ctx: NsCheckContext; t1, t2: NsTyDesc): bool =
  ## C#'s better conversion target (12.6.4.7): `t1` converts to `t2` and not back,
  ## or `t1` is the signed one of a signed/unsigned pair.
  if ctx.implicitTo(t1, t2) and not ctx.implicitTo(t2, t1): return true
  if t1.nullable != t2.nullable: return false
  case t1.name
  of "sbyte": t2.name in ["byte", "ushort", "uint", "ulong"]
  of "short": t2.name in ["ushort", "uint", "ulong"]
  of "int": t2.name in ["uint", "ulong"]
  of "long": t2.name == "ulong"
  else: false

proc betterConversion(ctx: NsCheckContext; arg: NsNode; t1, t2: NsTyDesc): bool =
  ## Whether converting `arg` to `t1` is better than to `t2` (12.6.4.5): an exact
  ## match beats one that is not, otherwise the better conversion target.
  if same(t1, t2) or not (t1.known and t2.known): return false
  let s = descOfArg(arg)
  if same(s, t1): return true
  if same(s, t2): return false
  ctx.betterTarget(t1, t2)

proc numericApplicable(v: NsNode; pt: NsTyDesc): bool =
  ## A numeric argument fits a numeric parameter only by an implicit conversion,
  ## or as a constant in the parameter's range (10.2.11).
  let s = descOfArg(v)
  if not (s.known and pt.known and isNumericName(s.name) and isNumericName(pt.name)):
    return true
  if s.nullable and not pt.nullable: return false
  if implicitlyConvertible(s.name, pt.name): return true
  isConstantLit(v) and v.typeName.len == 0 and fitsLiteral(constValue(v), pt.name)

proc resolveOverload(ctx: NsCheckContext; cands: seq[seq[NsNode]];
                     args: seq[NsNode]): tuple[ok: bool, idx, score: int, map: NsArgMap] =
  ## Picks the overload C# does (12.6.4): of those every argument converts to, the
  ## one better than every other -- each argument's conversion at least as good and
  ## one better, an exact match beating any other conversion and a more specific
  ## target a less specific one; a tie goes to the one that needs no `params`
  ## expansion, then to the one that leaves no default to fill. With no single best
  ## one, the one needing the fewest conversions is taken and Nim has the last word.
  result = (ok: false, idx: -1, score: high(int), map: NsArgMap())
  var fitting: seq[tuple[idx, score: int, map: NsArgMap]] = @[]
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
      if cands.len > 1 and not numericApplicable(v, ctx.descOfType(pt)):
        fits = false
        break
      if ctx.argConv(v, pt) != acNone: inc score
      if m.element[j]: inc score
    if cands[i].len > args.len: inc score
    if fits:
      fitting.add (idx: i, score: score, map: m)
      if score < result.score:
        result = (ok: true, idx: i, score: score, map: m)
  if fitting.len < 2: return
  proc expanded(m: NsArgMap): bool =
    for e in m.element:
      if e: return true
    false
  proc better(a, b: tuple[idx, score: int, map: NsArgMap]): bool =
    var anyBetter = false
    for j in 0 ..< args.len:
      let v = argValue(args[j])
      if v.kind in {nsnOutDecl, nsnLambda} or args[j].kind == nsnRefArg: continue
      let ta = ctx.descOfType(slotType(cands[a.idx], a.map, j))
      let tb = ctx.descOfType(slotType(cands[b.idx], b.map, j))
      if ctx.betterConversion(v, tb, ta): return false
      if ctx.betterConversion(v, ta, tb): anyBetter = true
    if anyBetter: return true
    let ea = expanded(a.map)
    let eb = expanded(b.map)
    if ea != eb: return eb
    let da = cands[a.idx].len > args.len
    let db = cands[b.idx].len > args.len
    if da != db: return db
    false
  for a in fitting:
    var best = true
    for b in fitting:
      if a.idx != b.idx and not better(a, b):
        best = false
        break
    if best:
      return (ok: true, idx: a.idx, score: a.score, map: a.map)

proc markNull(ctx: NsCheckContext; value: NsNode; target: string;
              targetType: NsNode = nil) =
  ## `null` for an interface is the empty interface value, which lowering spells
  ## `default(I)`, so the target is recorded on the literal; for a handle class it
  ## is the invalid handle.
  let tn = canonicalTypeName(target)
  if value != nil and value.kind == nsnNull and ctx.scope.classes.hasKey(tn) and
     ctx.scope.handleRoot(tn).len > 0:
    value.setType(tkClass, tn)
  elif value != nil and value.kind == nsnNull and ctx.scope.isValueInterface(target):
    value.setType(tkClass, target)
    ## A generic interface's empty value names its type arguments too.
    if targetType != nil and targetType.kind == nsnTypeName: value.rtype = targetType
  elif value != nil and value.kind == nsnNull and canonicalTypeName(target) == "string":
    ## A Nim string cannot be nil: a null string is the empty one (SPEC 7.3).
    value.setType(tkString, "string")

proc liftConversion(value, target: NsNode) =
  ## `long? l = i;` for an `int? i`: the lifted numeric conversion (10.6.1).
  if value == nil or target == nil or value.typeKind != tkNullable or
     target.kind != nsnNullableType or value.conv.len > 0: return
  let src = value.typeName
  let dst = declTypeName(target.typ)
  if src != dst and isNumericName(src) and isNumericName(dst) and
     implicitlyConvertible(src, dst):
    value.conv = "nsOptAs"
    value.convType = target.typ

proc checkConvertible(ctx: NsCheckContext; value: NsNode; t: NsTarget;
                      info: TLineInfo) =
  ## The one rule the initialiser, the assignment and `return` share: CS0029 for a
  ## value of an unrelated type, CS0037 for `null` into a value type.
  if value == nil: return
  liftConversion(value, t.typ)
  if value.kind == nsnNull:
    if not t.isNullOk:
      nsError(ctx.config, info, ndCannotConvertNull, t.spelling)
    ctx.markNull(value, t.name, t.typ)
    return
  if value.kind == nsnLambda and t.kind in {tkInt, tkFloat, tkBool, tkChar, tkString,
                                            tkSequence, tkClass}:
    ## A lambda only converts to a delegate (CS1660).
    nsError(ctx.config, info, ndLambdaToValue, t.spelling)
    return
  if value.typeKind == tkDelegate and t.kind notin {tkDelegate, tkUnknown} and
     value.kind in {nsnIdent, nsnMember} and value.typeName.len == 0:
    ## A method named without a call is a method group, not a value (CS0428).
    nsError(ctx.config, info, ndMethodGroupConv, value.name, t.spelling)
    return
  let tcn = canonicalTypeName(t.name)
  if ctx.scope.enums.contains(tcn) and value.typeKind in {tkInt, tkFloat} and
     not (value.kind == nsnIntLit and value.intVal == 0):
    ## An integer is no enum without a cast; `0` alone converts (CS0266).
    nsError(ctx.config, info, ndCannotConvertExplicit, valueSpelling(value), t.spelling)
    return
  if ctx.scope.enums.contains(canonicalTypeName(value.typeName)) and
     t.kind in {tkInt, tkFloat} and not ctx.scope.enums.contains(tcn):
    nsError(ctx.config, info, ndCannotConvertExplicit, value.typeName, t.spelling)
    return
  if ctx.incompatible(value, t):
    let src = (if value.typeName.len > 0: canonicalTypeName(value.typeName)
               else: numName(value))
    let lib = ctx.libIfaceConversion(value, t)
    if lib == lcVariance:
      nsError(ctx.config, info, ndUnsupported,
              "a variant conversion of a library interface ('" & valueSpelling(value) &
              "' to '" & t.spelling & "')")
    elif lib == lcCast:
      ## An interface and a class that is not sealed, or two interfaces: a cast
      ## would do (CS0266).
      nsError(ctx.config, info, ndCannotConvertExplicit, valueSpelling(value), t.spelling)
    elif src.len > 0 and t.name.len > 0 and
       ctx.scope.conversionOp(src, canonicalTypeName(t.name), false) != nil:
      ## Only an explicit conversion exists: C# says so (CS0266).
      nsError(ctx.config, info, ndCannotConvertExplicit, valueSpelling(value), t.spelling)
    else:
      nsError(ctx.config, info, ndCannotConvert, valueSpelling(value), t.spelling)

proc checkCast(ctx: NsCheckContext; n: NsNode; target: NsTypeKind) =
  ## `(T)x` with no conversion at all between the two (CS0030): a string and a
  ## number, a bool and anything else, or two classes neither derives from.
  let v = n.body
  if v == nil or v.kind == nsnNull: return
  let src = v.typeKind
  const known = {tkInt, tkFloat, tkBool, tkChar, tkString, tkClass}
  if src notin known or target notin known: return
  let sn = canonicalTypeName(v.typeName)
  let tn = canonicalTypeName(declTypeName(n.typ))
  if ctx.scope.enums.contains(sn) or ctx.scope.enums.contains(tn): return
  var ok = true
  if src == tkBool or target == tkBool: ok = src == target
  elif src == tkString or target == tkString: ok = src == target
  elif src == tkClass and target == tkClass:
    if ctx.scope.classes.hasKey(sn) and ctx.scope.classes.hasKey(tn) and
       ctx.scope.classes[sn].classKind != ckInterface and
       ctx.scope.classes[tn].classKind != ckInterface and
       ctx.scope.classes[sn].classKind != ckStruct and
       ctx.scope.classes[tn].classKind != ckStruct:
      ok = sn in ctx.scope.chain(tn) or tn in ctx.scope.chain(sn)
  elif (src == tkClass) != (target == tkClass):
    let cn = (if src == tkClass: sn else: tn)
    ok = not (ctx.scope.classes.hasKey(cn) and ctx.scope.classes[cn].operators.len == 0 and
              ctx.scope.classes[cn].classKind == ckClass)
  if not ok:
    nsError(ctx.config, n.info, ndCannotCast, kindSpelling(v), typeSpelling(n.typ))

proc isTypeParamRef(ctx: NsCheckContext; t: NsNode): bool =
  ## A parameter typed by a type parameter: a bare name no declaration answers for.
  t != nil and t.kind == nsnTypeName and t.sons.len == 0 and '.' notin t.name and
    not ctx.isTypeName(t.name)

proc walkExpr(ctx: var NsCheckContext; n: NsNode): NsTypeKind

proc checkCallArgs(ctx: var NsCheckContext; cands: seq[seq[NsNode]];
                   args: seq[NsNode]; displayName, recvName: string;
                   isCtor: bool; info: TLineInfo; call: NsNode = nil) =
  ## CS1501 / CS1729 when no overload takes this many arguments, CS7036 when one
  ## takes more, CS1503 when one takes exactly this many but an argument cannot be
  ## converted. A call the scope cannot resolve -- a library method, a name from a
  ## module it does not cover -- has no candidates and is left to Nim. The chosen
  ## overload's parameter is recorded on each argument, which `out var` declarations
  ## and lambda arguments take their types from.
  if cands.len == 0: return
  for a in args:
    if a.kind == nsnRefArg and a.body != nil and a.body.kind == nsnMember and
       a.body.body != nil and
       ctx.scope.isNativeObjectField(a.body.body.typeName,
         ctx.scope.findMemberInfo(a.body.body.typeName, a.body.name).typ):
      ## Lowering reaches such a field through a property (CS0206 in C#'s terms).
      nsError(ctx.config, a.info, ndUnsupported,
              "'" & a.name & "' of '" & a.body.name & "', a native object field")
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
  if ok and call != nil:
    ## A default the declaration leaves out (`noDefault`) is passed by name.
    var filled = newSeq[bool](cands[idx].len)
    for j in 0 ..< args.len: filled[map.slot[j]] = true
    for k, p in cands[idx]:
      if p != nil and p.noDefault and not filled[k] and p.body != nil:
        let a = nsn(nsnNamedArg, call.info)
        a.name = p.name
        a.body = copyNsTree(p.body)
        discard ctx.walkExpr(a.body)
        ctx.coerce(a.body, declTypeName(p.typ), a.info, p.typ)
        call.sons.add a
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
      let pm = a.argParam.paramMod
      if pm in ["ref", "out"] and a.kind != nsnRefArg and
         not (a.kind == nsnNamedArg and a.body != nil and a.body.kind == nsnRefArg):
        ## The callee writes the argument, which the call must say (CS1620).
        nsError(ctx.config, a.info, ndRefArgMissing, $(j + 1), pm)
      if a.kind == nsnRefArg: continue
      liftConversion(v, pt)
      let conv = ctx.argConv(v, pt)
      if conv != acNone:
        ## Lowering applies it, so the argument reaches `some`/`none` spelled with
        ## the element type rather than with the literal's own type.
        v.argConv = conv
        v.argConvType =
          declTypeName(if pt.kind == nsnNullableType: pt.typ else: pt)
      elif pt != nil:
        ctx.coerce(v, declTypeName(pt), v.info, pt)
        ctx.markNull(v, declTypeName(pt), pt)
        if cands.len > 1 and pt.kind != nsnNullableType and v.conv.len == 0 and
           isNumericName(declTypeName(pt)) and
           ((isConstantLit(v) and v.typeName.len == 0) or
            (numName(v).len > 0 and numName(v) != declTypeName(pt))):
          ## A number is converted to what the overload C# chose takes, so Nim does
          ## not find `U(uint)` and `U(int)` equally good for `U(1)`, or `F(int)`
          ## and `F(long)` for a `short`.
          v.conv = declTypeName(pt)
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
  for a in args:
    if a.kind == nsnNamedArg:
      var known = false
      for c in cands:
        for p in c:
          if p != nil and p.name == a.name: known = true
      if not known:
        ## No overload has a parameter of that name (CS1739).
        nsError(ctx.config, a.info, ndNoNamedParam, displayName, a.name)
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

proc isForwardParam(p: NsNode): bool =
  p != nil and p.paramMod == "params" and p.attributeNamed("Forward") != nil

proc forwardTarget(ctx: NsCheckContext; owner: string; callee: NsNode): string =
  ## The class a `[Forward]` factory's arguments construct: its type argument for the
  ## method's result type when that is a type parameter, else for its first one.
  ## "" when the call names none, or names a type parameter of its own.
  let mi = ctx.scope.findMemberInfo(owner, callee.name)
  if mi.typeParams.len == 0 or callee.typeArgs.len != mi.typeParams.len: return ""
  var k = 0
  if mi.typ != nil and mi.typ.kind == nsnTypeName:
    let i = mi.typeParams.find(mi.typ.name)
    if i >= 0: k = i
  let t = callee.typeArgs[k]
  if t == nil or t.kind != nsnTypeName: return ""
  let cn = unqualified(t.name)
  if ctx.scope.classes.hasKey(cn): cn else: ""

proc checkExplicitTypeArgs(ctx: NsCheckContext; owner: string; callee: NsNode;
                           args: seq[NsNode]) =
  ## `M<int>("s")`: the written type arguments fix the parameter types, so an
  ## argument that does not convert to them is CS1503.
  var subs: seq[seq[NsNode]] = @[]
  for c in ctx.scope.chain(owner):
    for m in ctx.scope.classes[c].members:
      if m.name != callee.name or not m.isMethod or
         m.typeParams.len != callee.typeArgs.len: continue
      var ps: seq[NsNode] = @[]
      for p in m.params:
        if p == nil:
          ps.add p
          continue
        var q: NsNode
        new(q)
        q[] = p[]
        q.typ = substitute(p.typ, m.typeParams, callee.typeArgs)
        ps.add q
      subs.add ps
  if subs.len == 0: return
  let r = ctx.resolveOverload(subs, args)
  if r.ok:
    ## `null` for a parameter the type arguments make a `string` is the empty
    ## string N# spells a null one with (SPEC 7.3).
    for j in 0 ..< args.len:
      let pt = slotType(subs[r.idx], r.map, j)
      if pt != nil: ctx.markNull(argValue(args[j]), declTypeName(pt), pt)
    return
  for c in subs:
    let m = mapArgs(c, args)
    if not m.fits: continue
    for j in 0 ..< args.len:
      let pt = slotType(c, m, j)
      let v = argValue(args[j])
      if v.kind notin {nsnOutDecl, nsnLambda} and ctx.incompatible(v, ctx.targetOfType(pt)):
        nsError(ctx.config, v.info, ndArgumentCannotConvert,
                $(j + 1), valueSpelling(v), typeSpelling(pt))
        return

proc exactLibraryResult(ctx: NsCheckContext; callee: NsNode; args: seq[NsNode]): NsNode =
  ## The result type of the static library overload whose parameters are exactly
  ## the arguments' types (`Math.Abs(2.5f)` is `Abs(float)`'s, a `float`), as C#'s
  ## overload resolution picks it; nil when none is, or a type is not known. Nim
  ## makes the call either way: this is what the frontend knows of its result.
  let recv = callee.body
  if recv == nil or recv.typeKind != tkType: return nil
  let recvName = unqualified(recv.typeName)
  if ctx.scope.classes.hasKey(recvName): return nil
  var argTypes: seq[string] = @[]
  for a in args:
    if a == nil or a.kind in {nsnNamedArg, nsnRefArg, nsnOutDecl, nsnLambda}: return nil
    let vt = valueType(a)
    if vt != nil and vt.kind == nsnTypeName: argTypes.add canonicalTypeName(vt.name)
    else:
      ## A value without a type name (`-2.5`): C#'s type for its kind.
      case a.typeKind
      of tkInt: argTypes.add "int"
      of tkFloat: argTypes.add "double"
      of tkBool: argTypes.add "bool"
      of tkChar: argTypes.add "char"
      of tkString: argTypes.add "string"
      else: return nil
  for m in ctx.surface.overloads(recvName, ctx.surface.kindOfName(recvName), callee.name):
    let (ps, variadic) = libParams(m, recv, true, callee)
    if variadic or ps.len != args.len: continue
    var bound = initTable[string, NsNode]()
    var exact = true
    for j, pt in ps:
      if pt == nil or pt.kind != nsnTypeName:
        exact = false
        break
      if pt.name.startsWith("$"):
        if bound.hasKey(pt.name):
          if canonicalTypeName(bound[pt.name].name) != argTypes[j]: exact = false
        else: bound[pt.name] = nsnTypeName(argTypes[j], pt.info)
      elif canonicalTypeName(pt.name) != argTypes[j]: exact = false
      if not exact: break
    if not exact: continue
    var nb: seq[NsNode] = @[]
    for k, g in m.genParams:
      nb.add (if bound.hasKey("$" & g): bound["$" & g]
              elif callee.typeArgs.len == m.genParams.len: callee.typeArgs[k]
              else: nsnTypeName("$" & g, callee.info))
    let rt = nimToCs(m.retType, m.genParams, nb, callee)
    if rt == nil or (rt.kind == nsnTypeName and rt.name.startsWith("$")): return nil
    return rt
  nil

proc checkLibraryCall(ctx: NsCheckContext; callee: NsNode; args: seq[NsNode]) =
  ## A call of a library member no overload of which takes these arguments:
  ## CS1503 when one takes this many, CS1501 when none does. Generic parameters
  ## the receiver leaves open are bound by the arguments; anything N# cannot type
  ## is taken to fit, so only a sure mismatch is reported.
  let recv = callee.body
  let staticCall = recv.typeKind == tkType
  var recvName = ""
  var recvKind = tkUnknown
  if staticCall:
    recvName = unqualified(recv.typeName)
    if ctx.scope.classes.hasKey(recvName): return
    recvKind = ctx.surface.kindOfName(recvName)
  else:
    recvName = recv.typeName
    recvKind = recv.typeKind
    if recvKind notin {tkSequence, tkString, tkInt, tkFloat, tkChar, tkBool, tkClass}: return
    if recvKind == tkClass and ctx.scope.classes.hasKey(canonicalTypeName(recvName)): return
  if ctx.scope.extensions.hasKey(callee.name): return
  ## `null` where every overload of this arity takes a `string` is the empty string
  ## N# spells a null one with (SPEC 7.3): `string.IsNullOrEmpty(null)`.
  for j, a in args:
    if a == nil or a.kind != nsnNull: continue
    var strings = 0
    var others = 0
    for m in ctx.surface.overloads(recvName, recvKind, callee.name):
      if m.isStatic != staticCall and not staticCall: continue
      let (ps, variadic) = libParams(m, recv, staticCall, callee)
      if variadic or ps.len != args.len: continue
      if ps[j] != nil and canonicalTypeName(declTypeName(ps[j])) == "string": inc strings
      else: inc others
    if strings > 0 and others == 0: ctx.markNull(a, "string")
  for a in args:
    if a == nil or a.kind in {nsnNamedArg, nsnRefArg, nsnOutDecl, nsnLambda} or
       a.typeKind in {tkUnknown, tkDelegate}:
      return
  let ovs = ctx.surface.overloads(recvName, recvKind, callee.name)
  if ovs.len == 0: return
  var bad: tuple[found: bool, idx: int, pt: NsNode] = (found: false, idx: 0, pt: nil)
  for m in ovs:
    if m.isStatic != staticCall and not staticCall: continue
    let (ps, variadic) = libParams(m, recv, staticCall, callee)
    let fixed = (if variadic: ps.len - 1 else: ps.len)
    if args.len < fixed: return          # defaults N# cannot see: assume it fits
    if not variadic and args.len > ps.len: continue
    var bound = initTable[string, NsNode]()
    var fits = true
    for j, a in args:
      var pt = (if j < fixed: ps[j] else: ps[^1])
      if pt == nil: continue
      if pt.kind == nsnTypeName and pt.name.startsWith("$"):
        if bound.hasKey(pt.name): pt = bound[pt.name]
        else:
          let vt = valueType(a)
          if vt != nil: bound[pt.name] = vt
          continue
      if pt == nil or (pt.kind == nsnArrayType and pt.typ == nil): continue
      if ctx.incompatible(a, ctx.targetOfType(pt)):
        fits = false
        if not bad.found: bad = (true, j, pt)
        break
    if fits:
      ## A value into a library interface parameter (`list.Sort(new ByLength())`)
      ## is converted as into a user method's; open type arguments come from the
      ## other arguments.
      proc bindDollar(t: NsNode; bound: Table[string, NsNode]): NsNode =
        if t == nil: return nil
        if t.kind == nsnTypeName and t.name.startsWith("$"):
          return (if bound.hasKey(t.name): bound[t.name] else: nil)
        result = copyNsTree(t)
        result.sons = @[]
        for x in t.sons:
          let b = bindDollar(x, bound)
          if b == nil: return nil
          result.sons.add b
      proc bindFrom(pt, vt: NsNode; bound: var Table[string, NsNode]) =
        if pt == nil or vt == nil: return
        if pt.kind == nsnTypeName and pt.name.startsWith("$"):
          if not bound.hasKey(pt.name): bound[pt.name] = vt
        elif pt.kind == nsnArrayType and vt.kind == nsnArrayType:
          bindFrom(pt.typ, vt.typ, bound)
        elif pt.kind == nsnTypeName and vt.kind == nsnTypeName and
             pt.sons.len == vt.sons.len:
          for i in 0 ..< pt.sons.len: bindFrom(pt.sons[i], vt.sons[i], bound)
      for j, a in args:
        bindFrom((if j < fixed: ps[j] else: ps[^1]), valueType(a), bound)
      for j, a in args:
        let pt = (if j < fixed: ps[j] else: ps[^1])
        if pt == nil or pt.kind != nsnTypeName: continue
        if canonicalTypeName(pt.name) == "object":
          ## A value into an `object` parameter (`List<object>.Add(1)`) is boxed.
          ctx.coerce(a, "object", a.info, pt)
          continue
        if canonicalTypeName(pt.name) notin ctx.scope.libValueIfaces: continue
        let full = bindDollar(pt, bound)
        if full != nil: ctx.coerce(a, declTypeName(full), a.info, full)
      return
  if bad.found:
    let a = args[bad.idx]
    nsError(ctx.config, a.info, ndArgumentCannotConvert, $(bad.idx + 1), valueSpelling(a),
            typeSpelling(bad.pt))
  else:
    nsError(ctx.config, callee.info, ndArgumentNoOverload, callee.name, $args.len)

proc libraryOutTypes(ctx: NsCheckContext; callee: NsNode; args: seq[NsNode]) =
  ## `T.M(..., out var x)` of a library member: `x` takes the type of the parameter it
  ## fills, in the overload the other arguments fit. Only an overload of this arity
  ## that types the parameter (its generic parameters bound) is taken.
  let recv = callee.body
  if recv == nil: return
  var wanted = false
  for a in args:
    if a != nil and a.kind == nsnOutDecl and a.typ == nil: wanted = true
  if not wanted: return
  let staticCall = recv.typeKind == tkType
  let recvName = (if staticCall: unqualified(recv.typeName) else: recv.typeName)
  let recvKind = (if staticCall: ctx.surface.kindOfName(recvName) else: recv.typeKind)
  for m in ctx.surface.overloads(recvName, recvKind, callee.name):
    if m.isStatic != staticCall and not staticCall: continue
    let (ps, variadic) = libParams(m, recv, staticCall, callee)
    if variadic or ps.len != args.len: continue
    var fits = true
    for j, a in args:
      let pt = ps[j]
      if a.kind == nsnOutDecl:
        if a.typ == nil and (pt == nil or pt.kind != nsnTypeName or pt.name.startsWith("$")):
          fits = false
      elif pt != nil and not (pt.kind == nsnTypeName and pt.name.startsWith("$")) and
           a.typeKind notin {tkUnknown, tkDelegate} and a.kind notin {nsnNamedArg, nsnRefArg} and
           ctx.incompatible(a, ctx.targetOfType(pt)):
        fits = false
      if not fits: break
    if not fits: continue
    for j, a in args:
      if a.kind == nsnOutDecl and a.typ == nil: a.typ = ps[j]
    return

proc libraryCtorConvert(ctx: NsCheckContext; n: NsNode) =
  ## `new HashSet<int>(new Mod10())`: an argument for a library interface parameter
  ## of one of the type's constructors (`new<Type>` in the library) is converted as a
  ## method's is, the constructor's generic parameters being the type's arguments.
  let tn = ctx.surface.nimSpellingOf(unqualified(n.typ.name))
  if tn.len == 0 or n.sons.len == 0: return
  let ctor = "new" & tn
  for key, ms in ctx.surface.members:
    for m in ms:
      if m.name != ctor or m.paramTypes.len != n.sons.len: continue
      var nb = newSeq[NsNode](m.genParams.len)
      if n.typ.sons.len == m.genParams.len:
        for i in 0 ..< nb.len: nb[i] = n.typ.sons[i]
      var ps: seq[NsNode] = @[]
      var fits = true
      for j, a in n.sons:
        let pt = nimToCs(m.paramTypes[j], m.genParams, nb, n)
        ps.add pt
        if pt == nil or a == nil or a.kind in {nsnNamedArg, nsnRefArg, nsnLambda} or
           a.typeKind in {tkUnknown, tkDelegate}:
          continue
        if pt.kind == nsnTypeName and canonicalTypeName(pt.name) in ctx.scope.libValueIfaces:
          if not ctx.convertsToLibIface(a, canonicalTypeName(pt.name)):
            fits = false
            break
          continue
        if ctx.incompatible(a, ctx.targetOfType(pt)):
          fits = false
          break
      if not fits: continue
      var converts = false
      for j, a in n.sons:
        let pt = ps[j]
        if pt != nil and pt.kind == nsnTypeName and
           canonicalTypeName(pt.name) in ctx.scope.libValueIfaces:
          ctx.coerce(a, declTypeName(pt), a.info, pt)
          converts = converts or a.conv.len > 0
      if converts: return

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

proc checkTypeArgs(ctx: NsCheckContext; t: NsNode)
proc firstUnknownType(ctx: NsCheckContext; t: NsNode): NsNode
proc checkAssignable(ctx: NsCheckContext; target: NsNode)

proc checkOperands(ctx: NsCheckContext; n: NsNode; lk, rk: NsTypeKind) =
  ## A built-in operator applied to operands it does not take (CS0019): only
  ## judged when both operands' kinds are known and neither declares the operator.
  const known = {tkInt, tkFloat, tkBool, tkChar, tkString, tkClass}
  if lk notin known or rk notin known: return
  for side in [n.sons[0], n.sons[1]]:
    let cn = canonicalTypeName(side.typeName)
    if side.typeKind == tkClass and (not ctx.scope.classes.hasKey(cn) or
       ctx.scope.classes[cn].operators.len > 0 or ctx.scope.classes[cn].decl == nil or
       ctx.scope.classes[cn].decl.attrs.isRecord):
      ## A library class, or one with operators or conversions of its own: Nim
      ## knows better.
      return
  proc num(k: NsTypeKind): bool = k in {tkInt, tkFloat, tkChar}
  proc integral(k: NsTypeKind): bool = k in {tkInt, tkChar}
  let ok =
    case n.name
    of "+": lk == tkString or rk == tkString or (num(lk) and num(rk)) or
            (lk == tkDelegate and rk == tkDelegate)
    of "-": (num(lk) and num(rk)) or (lk == tkDelegate and rk == tkDelegate)
    of "*", "/", "nsDiv", "mod", "nsMod", "nsFmod": num(lk) and num(rk)
    of "<", ">", "<=", ">=": num(lk) and num(rk)
    of "==", "!=":
      (num(lk) and num(rk)) or (lk == rk and lk in {tkBool, tkString, tkClass})
    of "and", "or", "xor":
      (lk == tkBool and rk == tkBool) or
        (n.strVal != "logical" and integral(lk) and integral(rk))
    of "shl", "shr", "ushr": integral(lk) and integral(rk)
    else: true
  if not ok:
    let shown = (if n.strVal == "logical": (if n.name == "and": "&&" else: "||")
                 else: csOperatorOf(n.name))
    nsError(ctx.config, n.info, ndOperatorTypes, shown,
            kindSpelling(n.sons[0]), kindSpelling(n.sons[1]))

# --- control flow -----------------------------------------------------------
#
# Reachability as C# defines it, over the statements alone: whether control can
# reach the end of a body, which a value-returning member must not (CS0161) and a
# switch section must not (CS0163). Only a literal `true` counts as constant.

proc isTrueLit(n: NsNode): bool = n != nil and n.kind == nsnBoolLit and n.intVal == 1

proc hasYieldStmt(n: NsNode): bool =
  ## Whether a body yields: an iterator block, whose end is always fine.
  if n == nil or n.kind in {nsnLambda, nsnLocalFunc}: return false
  if n.kind == nsnYield: return true
  if hasYieldStmt(n.body): return true
  for x in n.sons:
    if hasYieldStmt(x): return true
  false

proc breaksOut(n: NsNode): bool =
  ## Whether a `break` in `n` leaves the loop or switch `n` is the body of: one
  ## not inside a nested loop, switch, lambda or local function.
  if n == nil: return false
  case n.kind
  of nsnBreak: true
  of nsnWhile, nsnDoWhile, nsnFor, nsnForeach, nsnSwitch, nsnLambda, nsnLocalFunc: false
  else:
    if n.kind in {nsnIf, nsnIfBranch, nsnBlock, nsnBlockStmt, nsnElseBranch, nsnTry,
                  nsnCatch, nsnFinally, nsnChecked, nsnUnchecked, nsnUsingStmt, nsnLock}:
      if breaksOut(n.body): return true
      for x in n.sons:
        if breaksOut(x): return true
    false

proc anyBreaksOut(stmts: seq[NsNode]): bool =
  for x in stmts:
    if breaksOut(x): return true
  false

proc endReachable(stmts: seq[NsNode]): bool

proc stmtEndReachable(n: NsNode): bool =
  if n == nil: return true
  case n.kind
  of nsnReturn, nsnThrow, nsnBreak, nsnContinue: false
  of nsnYield: n.name != "break"
  of nsnBlock, nsnBlockStmt, nsnChecked, nsnUnchecked, nsnLock: endReachable(n.sons)
  of nsnElseBranch: stmtEndReachable(n.body)
  of nsnUsingStmt: n.body == nil or stmtEndReachable(n.body)
  of nsnIf:
    var hasElse = false
    for b in n.sons:
      if b.kind == nsnIfBranch:
        if isTrueLit(b.body): return endReachable(b.sons)
        if endReachable(b.sons): return true
      else:
        hasElse = true
        if stmtEndReachable(b): return true
    not hasElse
  of nsnWhile, nsnDoWhile:
    not isTrueLit(n.body) or anyBreaksOut(n.sons)
  of nsnFor:
    let cond = (if n.body != nil and n.body.sons.len > 1: n.body.sons[1] else: nil)
    (cond != nil and cond.kind != nsnEmpty and not isTrueLit(cond)) or
      anyBreaksOut(n.sons)
  of nsnSwitch:
    var hasDefault = false
    for sec in n.sons:
      if sec.name == "default": hasDefault = true
      if sec.body != nil and breaksOut(sec.body): return true
    not hasDefault
  of nsnTry:
    ## The protected block is the node's body; its sons are the clauses.
    var fin: NsNode = nil
    var any = stmtEndReachable(n.body)
    for x in n.sons:
      if x.kind == nsnFinally: fin = x
      elif x.kind == nsnCatch: any = any or stmtEndReachable(x.body)
    if fin != nil and not stmtEndReachable(fin.body): return false
    any
  else: true

proc endReachable(stmts: seq[NsNode]): bool =
  for s in stmts:
    if not stmtEndReachable(s): return false
  true

proc checkJumps(ctx: NsCheckContext; stmts: seq[NsNode]; inLoop, inSwitch: bool) =
  ## `break` outside a loop or switch, `continue` outside a loop (CS0139).
  for s in stmts:
    if s == nil: continue
    case s.kind
    of nsnBreak:
      if not inLoop and not inSwitch: nsError(ctx.config, s.info, ndNoEnclosingLoop)
    of nsnContinue:
      if not inLoop: nsError(ctx.config, s.info, ndNoEnclosingLoop)
    of nsnWhile, nsnDoWhile, nsnFor, nsnForeach:
      ctx.checkJumps(s.sons, true, inSwitch)
    of nsnSwitch:
      for sec in s.sons:
        if sec.body != nil: ctx.checkJumps(sec.body.sons, inLoop, true)
    of nsnLocalFunc:
      if s.body != nil: ctx.checkJumps(s.body.sons, false, false)
    of nsnIf:
      for b in s.sons:
        if b.kind == nsnIfBranch: ctx.checkJumps(b.sons, inLoop, inSwitch)
        elif b.kind == nsnElseBranch and b.body != nil:
          ctx.checkJumps(b.body.sons, inLoop, inSwitch)
        else: ctx.checkJumps(b.sons, inLoop, inSwitch)
    of nsnTry:
      for x in s.sons:
        if x.kind in {nsnCatch, nsnFinally}:
          if x.body != nil: ctx.checkJumps(x.body.sons, inLoop, inSwitch)
        else: ctx.checkJumps(x.sons, inLoop, inSwitch)
    of nsnBlock, nsnBlockStmt, nsnChecked, nsnUnchecked, nsnLock:
      ctx.checkJumps(s.sons, inLoop, inSwitch)
    of nsnUsingStmt:
      if s.body != nil: ctx.checkJumps(s.body.sons, inLoop, inSwitch)
    else: discard

proc checkBodyFlow(ctx: NsCheckContext; body: NsNode; ret: NsNode; what: string;
                   info: TLineInfo) =
  ## A member body: its jumps, and for a value-returning one that is not an
  ## iterator, that its end cannot be reached (CS0161).
  if body == nil or body.kind != nsnBlock: return
  ctx.checkJumps(body.sons, false, false)
  proc lambdas(n: NsNode; into: var seq[NsNode]) =
    if n == nil: return
    if n.kind == nsnLambda: into.add n
    lambdas(n.body, into)
    for x in n.sons: lambdas(x, into)
    for x in n.params: lambdas(x, into)
    for x in n.initArgs: lambdas(x, into)
  var ls: seq[NsNode] = @[]
  lambdas(body, ls)
  for l in ls:
    ## A lambda's body is its own: a loop outside it is no loop for its `break`.
    if l.body != nil and l.body.strVal != "expr": ctx.checkJumps(l.body.sons, false, false)
  if ret != nil and ret.kind != nsnVoidType and not hasYieldStmt(body) and
     endReachable(body.sons):
    nsError(ctx.config, info, ndNotAllPathsReturn, what)


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
     canonicalTypeName(t.name) notin ctx.scope.libValueIfaces and
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
  ## A `{.nsHidden.}` helper is no member of N# source's (`x.nsBox()` is CS1061).
  if ctx.surface.member(recv, kind, name, visibleOnly = true).name.len > 0: return true
  var cur = ctx.surface.nimSpellingOf(recv)
  var hops = 0
  while cur.len > 0 and ctx.surface.types.hasKey(cur) and hops < 16:
    ## A field of the library's object type reads as a C# property.
    if name in ctx.surface.types[cur].fields and
       name notin ctx.surface.types[cur].hiddenFields: return true
    cur = ctx.surface.types[cur].base
    inc hops
  for m in ctx.surface.members.getOrDefault(NsParamKey):
    if m.name == name and not m.hidden: return true
  ctx.scope.extensions.hasKey(name)

proc fillCallerArgs(ctx: NsCheckContext; n: NsNode; recv, name: string) =
  ## A library parameter marked `{.nsCallerArgument: "argument".}` that the call
  ## leaves out receives the named argument's text as written, as C#'s
  ## `[CallerArgumentExpression]` does: `ThrowIfNull(s)` passes `"s"`.
  var keys = @[recv, ctx.surface.nimSpellingOf(recv)]
  for key in keys:
    for m in ctx.surface.members.getOrDefault(key):
      if m.name != name or m.callerArgs.len == 0: continue
      ## A member over a receiver (a `typedesc` or a value) counts it as the first
      ## parameter; one filed by `{.nsStatic.}` has none.
      let offset = (if m.qualifier.len > 0: 0 else: 1)
      var positional = 0
      for a in n.sons:
        if a.kind != nsnNamedArg: inc positional
      for c in m.callerArgs:
        let at = c.param - offset
        let src = c.source - offset
        if at < 0 or src < 0 or c.param >= m.paramNames.len or
           c.source >= m.paramNames.len:
          continue
        ## Passed already, by position or by name: nothing to fill.
        var given = positional > at
        var text = ""
        for i, a in n.sons:
          if a.kind == nsnNamedArg:
            if a.name == m.paramNames[c.param]: given = true
            elif a.name == m.paramNames[c.source] and a.body != nil: text = a.body.srcText
          elif i == src: text = a.srcText
        if given or text.len == 0: continue
        let lit = nsnStrLit(text, n.info)
        lit.setType(tkString, "string")
        if positional == n.sons.len and at == n.sons.len:
          n.sons.add lit
        else:
          ## After named arguments, by name too.
          let named = nsn(nsnNamedArg, n.info)
          named.name = m.paramNames[c.param]
          named.body = lit
          n.sons.add named
        return

proc libraryBaseHas(ctx: NsCheckContext; name: string): bool =
  ## Whether the enclosing class inherits a visible member `name` from a library
  ## type it derives from: `Message`, `HResult` in a class deriving from `Exception`.
  if ctx.clsName.len == 0: return false
  for b in ctx.scope.baseChain(ctx.clsName):
    if ctx.scope.classes.hasKey(b): continue
    let k = ctx.surface.kindOfName(b)
    if ctx.libraryHas(b, k, name): return true
    if k == tkException and ctx.libraryHas("Exception", tkException, name): return true
  false

proc checkConstCall(ctx: NsCheckContext; n: NsNode) =
  ## In a const member function, `this` reaches only const members (NS9917).
  if ctx.constBody.len == 0 or n.body == nil or n.body.kind != nsnThis: return
  let mi = ctx.scope.findMemberInfo(ctx.clsName, n.name)
  if mi.name.len == 0 or not mi.isMethod or mi.isStatic: return
  if not ctx.scope.constMember(ctx.clsName, n.name):
    nsError(ctx.config, n.info, ndConstCall, mi.owner & "." & n.name, ctx.constBody)

proc checkOnHandleThis(ctx: NsCheckContext; n: NsNode) =
  ## `this.M()` on an `[OnHandle]` member needs the object's own handle, which only
  ## `SelfHandle` gives (NS9903).
  if n.body == nil or n.body.kind != nsnThis or not ctx.scope.classes.hasKey(ctx.clsName) or
     not ctx.scope.onHandle(ctx.clsName, n.name):
    return
  let root = ctx.scope.handleRoot(ctx.clsName)
  if root.len > 0 and ctx.scope.classes[root].native.selfHandle.len == 0:
    nsError(ctx.config, n.info, ndNativeNoSelfHandle, ctx.clsName, root)

proc warnEarlyNative(ctx: NsCheckContext; n: NsNode) =
  ## `this.M()` on a native member in a constructor of a class deriving a native
  ## one: C++ has constructed the base, but the engine may set the object up only
  ## once it is constructed (NS9910).
  if not ctx.inCtor or ctx.ctorIsStatic or n.body == nil or
     n.body.kind notin {nsnThis, nsnBase} or not ctx.scope.classes.hasKey(ctx.clsName) or
     not ctx.scope.nativeBased(ctx.clsName) or ctx.scope.isNative(ctx.clsName):
    return
  let m = ctx.scope.findMemberInfo(ctx.clsName, n.name)
  if m.name.len > 0 and ctx.scope.isNative(m.owner):
    nsWarn(ctx.config, n.info, ndNativeCtorEarly, m.owner & "." & n.name, ctx.clsName)

proc accessAllowed(ctx: NsCheckContext; owner: string; access: NsAccess): bool

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
      ## A class deriving from an exception: what it does not declare, the
      ## library's exception root must (`Message`), as a visible member.
      if ctx.surface.isExceptionType(cn, ctx.scope.baseChain(cn)) and
         ctx.scope.findMemberInfo(cn, n.name).name.len == 0 and
         not ctx.libraryHas("Exception", tkException, n.name) and
         not ctx.libraryHas("object", tkClass, n.name):
        var found = false
        for b in ctx.scope.baseChain(cn):
          if ctx.libraryHas(b, tkException, n.name): found = true
        if not found: nsError(ctx.config, n.info, ndNoMember, cn, n.name)
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
    ok = ctx.accessAllowed(m.owner, access)
    if not ok:
      nsError(ctx.config, n.info, ndNotAccessible, m.owner & "." & n.name)
      return
    if m.isProperty and not ctx.assigning:
      ## A property with no getter cannot be read (CS0154).
      for c in ctx.scope.chain(cn):
        let d = ctx.scope.classes[c].decl
        if d == nil: continue
        for x in d.sons:
          if x.kind == nsnPropertyDecl and x.name == n.name and x.explicitIface.len == 0:
            if not x.attrs.isEvent and (x.params.len == 0 or x.params[0] == nil):
              nsError(ctx.config, n.info, ndNoGetter, c & "." & n.name)
            return
  elif rk in {tkInt, tkFloat, tkBool, tkChar}:
    let spelled = (if recv.typeName.len > 0: recv.typeName else: kindSpelling(recv))
    if not ctx.libraryHas(spelled, rk, n.name) and not ctx.libraryHas("object", tkClass, n.name):
      nsError(ctx.config, n.info, ndNoMember, spelled, n.name)
  elif rk == tkException:
    ## A library exception (`ArgumentException`), or a class deriving from one:
    ## its own members, or those of the library types it derives from.
    if ctx.scope.classes.hasKey(cn) and ctx.scope.findMemberInfo(cn, n.name).name.len > 0:
      discard
    else:
      var found = ctx.libraryHas(cn, rk, n.name) or
                  ctx.libraryHas("Exception", tkException, n.name) or
                  ctx.libraryHas("object", tkClass, n.name)
      if not found and ctx.scope.classes.hasKey(cn):
        for b in ctx.scope.baseChain(cn):
          if ctx.libraryHas(b, rk, n.name): found = true
      if not found: nsError(ctx.config, n.info, ndNoMember, cn, n.name)
  elif recv.rtype != nil and recv.rtype.kind == nsnArrayType:
    ## An array is the library's `NsArray` (`NsMdArray` with more than one
    ## dimension): `Length`, `Clone`, and LINQ's extensions where `System.Linq`
    ## is imported.
    let ext = ctx.surface.extensionModule("NsArray", tkClass, n.name)
    if (not ctx.libraryHas("NsArray", tkClass, n.name) and
        not ctx.libraryHas("NsMdArray", tkClass, n.name) and
        not ctx.libraryHas("object", tkClass, n.name)) or
       (ext.len > 0 and ext.replace('/', '.') notin ctx.scope.usings):
      nsError(ctx.config, n.info, ndNoMember, typeSpelling(recv.rtype), n.name)
  elif rk == tkString and cn in ["string", "String", ""]:
    if not ctx.libraryHas("string", tkString, n.name):
      nsError(ctx.config, n.info, ndNoMember, "string", n.name)
  elif rk in {tkClass, tkSequence} and not ctx.scope.classes.hasKey(cn) and
       (recv.rtype == nil or recv.rtype.kind != nsnArrayType) and
       ctx.surface.types.hasKey(ctx.surface.nimSpellingOf(cn)):
    ## A library class the prelude declares: what it does not declare, no
    ## receiver of it has (CS1061). An extension method (LINQ's) is its member only
    ## where its namespace is imported.
    let ext = ctx.surface.extensionModule(cn, rk, n.name)
    if (not ctx.libraryHas(cn, rk, n.name) and not ctx.libraryHas("object", tkClass, n.name)) or
       (ext.len > 0 and ext.replace('/', '.') notin ctx.scope.usings):
      nsError(ctx.config, n.info, ndNoMember,
              (if recv.rtype != nil: typeSpelling(recv.rtype) else: cn), n.name)

proc accessAllowed(ctx: NsCheckContext; owner: string; access: NsAccess): bool =
  ## Whether the class being checked may use a member of `owner` with `access`: a
  ## private one in `owner` or a type nested in it, a protected one in a class
  ## deriving it.
  case access
  of aPrivate:
    var c = ctx.clsName
    var hops = 0
    while c.len > 0 and hops < 32:
      if c == owner: return true
      c = (if ctx.scope.classes.hasKey(c): ctx.scope.classes[c].enclosing else: "")
      inc hops
    false
  of aProtected:
    ## A nested type sees what its enclosing types see.
    var c = ctx.clsName
    var hops = 0
    while c.len > 0 and hops < 32:
      if owner in ctx.scope.chain(c): return true
      c = (if ctx.scope.classes.hasKey(c): ctx.scope.classes[c].enclosing else: "")
      inc hops
    false
  else: true

proc qualifiedOnlyMember(ctx: NsCheckContext; recv: NsNode; name: string;
                         info: TLineInfo): NsMemberSymbol =
  ## `name` of a type reached qualified that the scope leaves out (`Tools.Console`):
  ## only a static class may be one (its every use is a static member's), and the
  ## member must exist (CS0117) and be accessible (CS0122).
  let written = dottedName(recv)
  let c = ctx.scope.qualifiedOnly[written]
  if c.classKind != ckClass or not c.isStatic:
    nsError(ctx.config, recv.info, ndUnsupported,
            "'" & written & "', named like a type in scope and reached with no 'using'," &
            " unless it is a static class,")
    return
  var found = 0
  for m in c.members:
    if m.name == name:
      if not ctx.accessAllowed(m.owner, m.access):
        nsError(ctx.config, info, ndNotAccessible, written & "." & name)
        return
      if found == 0: result = m
      inc found
  if found > 1:
    ## Overloads: which one a call reaches is Nim's to resolve, so it is untyped.
    result.typ = nil
  if found > 0: return
  if ctx.scope.qualifiedOnly.hasKey(written & "." & name):
    ## A nested type (`Tools.Console.Inner`): its members are its own.
    return NsMemberSymbol(name: name)
  nsError(ctx.config, info, ndNoStaticMember, written, name)

proc checkQualifiedOnlyUpdate(ctx: NsCheckContext; target: NsNode) =
  ## `Tools.Console.Calls += 1` or `++`: a property of such a type is read and
  ## written through its accessors, which lowering does not pair up yet.
  if target == nil or target.kind != nsnMember or target.body == nil: return
  let written = dottedName(target.body)
  if not ctx.scope.qualifiedOnly.hasKey(written): return
  for m in ctx.scope.qualifiedOnly[written].members:
    if m.name == target.name and m.isProperty:
      nsError(ctx.config, target.info, ndUnsupported,
              "updating '" & written & "." & target.name & "' in place")

proc checkStaticMember(ctx: NsCheckContext; cls, name: string; info: TLineInfo) =
  ## `C.name` on a class of this compilation that declares no such member (CS0117).
  let c = canonicalTypeName(cls)
  if not ctx.scope.classes.hasKey(c):
    ## A built-in type (`int.Foo`): what the library does not declare on it, it
    ## does not have. Lowering would otherwise drop the qualifier and reach any
    ## `Foo` in scope.
    let k = ctx.surface.kindOfName(c)
    if k in {tkInt, tkFloat, tkBool, tkChar, tkString} and
       not ctx.libraryHas(c, k, name) and not ctx.libraryHas("object", tkClass, name):
      nsError(ctx.config, info, ndNoStaticMember, cls, name)
      return
    ## A library type or static qualifier (`Stopwatch`, `Console`, `Math`): its
    ## visible members only, so a helper (`Stopwatch.newStopwatch`) is not one (an
    ## enum's values are members too); a nested type is a type.
    let nim = ctx.surface.nimSpellingOf(c)
    let libType = nim.len > 0 and ctx.surface.types.hasKey(nim)
    if (libType or ctx.surface.members.hasKey(c)) and
       not ctx.isTypeName(name) and not ctx.isTypeName(c & "." & name):
      var found = ctx.libraryHas(c, k, name) or ctx.libraryHas("object", tkClass, name)
      for m in ctx.surface.members.getOrDefault(c):
        if m.name == name and not m.hidden: found = true
      if not found: nsError(ctx.config, info, ndNoStaticMember, cls, name)
    return
  if not ctx.chainInScope(c): return
  if ctx.scope.enums.contains(c) or ctx.scope.classes.hasKey(name): return
  if ctx.scope.findMemberInfo(c, name).name.len > 0: return
  if ctx.libraryHas("object", tkClass, name): return
  nsError(ctx.config, info, ndNoStaticMember, c, name)

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
  proc declaredLater(x: NsNode; name: string): bool =
    if x == nil: return false
    if x.kind == nsnLocalDecl and x.name == name: return true
    if x.kind in {nsnLambda, nsnLocalFunc}: return false
    if declaredLater(x.body, name): return true
    for y in x.sons:
      if declaredLater(y, name): return true
    false
  if ctx.curMember != nil and declaredLater(ctx.curMember.body, n.name):
    ## The local exists, further down (CS0841).
    nsError(ctx.config, n.info, ndUsedBeforeDecl, n.name)
    return
  nsError(ctx.config, n.info, ndNameNotFound, n.name)

proc walkIdent(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  ## A bare name. Inside an instance member body, a name that is a class member
  ## is rewritten in place into `this.name` and then resolved as a member, which
  ## is the behaviour the parse-time rewrite used to have.
  if n.name == "$subject":
    ## The stand-in for a pattern's subject keeps the type it was given.
    return n.typeKind
  if ctx.types.hasKey(n.name) or n.name in ctx.members:
    for q in ctx.scope.qualifiedNs:
      if q.split('.')[0] == n.name: ctx.scope.qualifiedShadowed.incl n.name
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
      n.body.strVal = "implicit"   ## written as a bare name
      return ctx.walkExpr(n)
  if ctx.clsName.len > 0 and not ctx.isStaticCtx and n.name notin ctx.members and
     not ctx.types.hasKey(n.name) and ctx.libraryBaseHas(n.name):
    ## A member the class inherits from a library type (`HResult = 42` in an
    ## exception's constructor) is `this.name` too.
    n.kind = nsnMember
    n.body = nsn(nsnThis, n.info)
    n.body.strVal = "implicit"
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
  elif n.name in ctx.scope.qualifiedTypes:
    ## A type of a namespace reached only qualified, named bare (CS0103).
    n.setType(tkUnknown)
    nsError(ctx.config, n.info, ndNameNotFound, n.name)
    result = tkUnknown
  elif ctx.isTypeName(n.name):
    ## A type or a namespace used as a receiver (`Console.WriteLine`), or a static
    ## call qualifier. Which of those it is needs no further resolution here: the
    ## member access that follows asks the library.
    for q in ctx.scope.qualifiedNs:
      if q.split('.')[0] == n.name: ctx.scope.qualifiedUsed.incl n.name
    n.setType(tkType, canonicalTypeName(n.name))
    result = tkType
  else:
    n.setType(tkUnknown)
    ctx.unknownName(n)
    result = tkUnknown

proc typeLiteralReceiver(r: NsNode) =
  ## `42.ToString("x")`: an integer literal as a receiver is C#'s `int`, where
  ## Nim's untyped literal would fit every integer overload of the member.
  if r == nil or r.conv.len > 0: return
  var lit = r
  while lit != nil and lit.kind == nsnUnary and lit.name in ["-", "+"]:
    lit = lit.body
  if lit != nil and lit.kind == nsnIntLit and lit.typeName in ["", "int"]:
    r.conv = "int"

proc walkMember(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  ## Member access. The receiver's resolved type decides what the member means, and
  ## the declaration that owns it -- this module's, or the prelude's -- decides what
  ## it yields. No member name is special-cased.
  ctx.receiver = n.body
  var rk = ctx.walkExpr(n.body)
  typeLiteralReceiver(n.body)
  ## C#'s "Color Color" rule (§12.8.7.2): a field, property, local or parameter
  ## named as its own type stands for the type when what follows is one of the
  ## type's static members -- an enum's members, a class's statics and consts.
  let bare = n.body != nil and
    (n.body.kind == nsnIdent or
     (n.body.kind == nsnMember and n.body.body != nil and
      n.body.body.kind == nsnThis and n.body.body.strVal == "implicit"))
  if bare and rk != tkType and ctx.isTypeName(n.body.name):
    let tn = canonicalTypeName(n.body.name)
    let declared =
      if n.body.kind == nsnMember: canonicalTypeName(ctx.memberTypeName(ctx.clsName, n.body.name))
      elif ctx.types.hasKey(n.body.name): canonicalTypeName(ctx.types[n.body.name].name)
      else: canonicalTypeName(n.body.typeName)
    var isStaticUse = false
    if declared == tn:
      if ctx.scope.enums.contains(tn):
        isStaticUse = n.name in ctx.scope.enumMembers.getOrDefault(tn)
      elif ctx.scope.classes.hasKey(tn):
        let m = ctx.scope.findMemberInfo(tn, n.name)
        isStaticUse = m.name.len > 0 and (m.isStatic or m.isConst)
    if isStaticUse:
      n.body = nsnIdent(n.body.name, n.body.info)
      n.body.setType(tkType, tn)
      rk = tkType
  if rk == tkType and n.body != nil and n.body.kind == nsnMember and
     n.body.typeName.len > 0 and n.body.body != nil and
     (ctx.scope.classes.hasKey(n.body.typeName) or ctx.scope.enums.contains(n.body.typeName)) and
     qualifierRoot(n.body).len > 0 and
     not ctx.scope.classes.hasKey(qualifierRoot(n.body)) and
     not ctx.scope.enums.contains(qualifierRoot(n.body)) and
     not ctx.types.hasKey(qualifierRoot(n.body)) and
     qualifierRoot(n.body) notin ctx.members and
     not ctx.scope.qualifiedOnly.hasKey(dottedName(n.body)):
    ## `Demo.Thing.Max`, `Demo.Color.Green`: the namespace says where the type is
    ## and nothing more, so the member is a member of the type by its own name --
    ## unless another type of that name is in scope (`Tools.Widget` beside
    ## `Demo.Widget`).
    let plain = nsnIdent(n.body.typeName, n.body.info)
    plain.setType(tkType, n.body.typeName)
    plain.typeArgs = n.body.typeArgs
    plain.rtype = n.body.rtype
    n.body = plain
  if rk == tkType and n.body != nil and n.body.kind == nsnMember and
     n.body.body != nil and n.body.typeKind == tkType and
     not ctx.scope.classes.hasKey(n.body.name) and
     ctx.surface.isLibraryNamespace(qualifierRoot(n.body)) and
     qualifierRoot(n.body) notin ctx.members and
     not ctx.types.hasKey(qualifierRoot(n.body)) and
     ctx.surface.isKnownTypeName(n.body.name) and
     not ctx.surface.isLibraryNamespace(n.body.name):
    ## `System.StringComparer.OrdinalIgnoreCase`: the namespace says where the type
    ## is, so the member is a member of the type by its own name.
    let plain = nsnIdent(n.body.name, n.body.info)
    plain.setType(tkType, n.body.typeName)
    plain.typeArgs = n.body.typeArgs
    plain.rtype = n.body.rtype
    n.body = plain
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
  if rk in {tkInt, tkFloat, tkBool, tkChar}: ctx.checkMemberUse(n)
  case rk
  of tkClass:
    ctx.checkMemberAccess(n)
    ctx.checkMemberUse(n)
    ctx.warnEarlyNative(n)
    ctx.checkOnHandleThis(n)
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
      ## A result of a generic library type (`d.Keys`), bound by the receiver.
      if n.rtype == nil: n.rtype = libGenericResult(ctx.surface, n.body, n.name, 0)
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
    if rk in {tkString, tkSequence, tkException}: ctx.checkMemberUse(n)
    kind = ctx.memberKindOfSurface(rk, n.body.typeName, n.name, tname)
    if n.rtype == nil: n.rtype = libGenericResult(ctx.surface, n.body, n.name, 0)
  of tkType:
    ## A namespace's member is a type (`System.Console`); a declared type's member
    ## is one of its statics, which the library answers for (`string.Empty`,
    ## `int.MaxValue`, `Array.IndexOf`).
    if n.body != nil and ctx.scope.enums.contains(n.body.typeName):
      ## `Color.Green`: a value of the enum, not a type.
      n.setType(tkUnknown, n.body.typeName)
      n.rtype = nsnTypeName(n.body.typeName, n.info)
      return tkUnknown
    if n.body != nil and ctx.scope.qualifiedOnly.hasKey(dottedName(n.body)):
      ## `Tools.Console.Calls`: a static of a type reached qualified that is named
      ## like another in scope, which the scope leaves out: its own symbol answers.
      if ctx.scope.qualifiedOnly.hasKey(dottedName(n.body) & "." & n.name):
        ## A nested type (`Tools.Console.Inner`), a qualifier in turn: the outer
        ## type need not be static.
        n.setType(tkType, n.name)
        return tkType
      let m = ctx.qualifiedOnlyMember(n.body, n.name, n.info)
      if m.name.len > 0:
        if m.isMethod:
          nsError(ctx.config, n.info, ndUnsupported,
                  "a method group of '" & dottedName(n.body) & "'")
        elif m.typ != nil:
          n.setType(ctx.classifyType(m.typ), declTypeName(m.typ))
          n.rtype = m.typ
          return n.typeKind
      return tkUnknown
    if n.body != nil:
      let recv = n.body.typeName
      ctx.checkStaticMember(recv, n.name, n.info)
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
    ## A member the library declares a result for is a value of it (`DayOfWeek.Monday`
    ## is a `DayOfWeek`), whatever its kind; anything else names a type or namespace.
    if kind == tkUnknown and tname.len == 0: kind = tkType
    if kind == tkType and tname.len == 0 and
       (ctx.scope.classes.hasKey(n.name) or ctx.scope.enums.contains(n.name)):
      ## `Demo.Gadget`: the qualified name of a type this compilation declares.
      tname = n.name
    elif kind == tkType and tname.len == 0 and n.body != nil and
         ctx.surface.isLibraryNamespace(qualifierRoot(n.body)) and
         ctx.surface.isKnownTypeName(n.name) and
         not ctx.surface.isLibraryNamespace(n.name):
      ## `System.StringComparer`: the qualified name of a library type.
      tname = n.name
  else: discard
  n.setType(kind, tname)
  result = kind

proc isDeferred(v: NsNode): bool =
  ## An argument typed by the parameter it is passed for: a lambda, or a `new()`,
  ## `default` or array initialiser without a type of its own.
  v != nil and (v.kind == nsnLambda or
                v.kind in {nsnNew, nsnDefault, nsnArrayLit, nsnCollection} and v.typ == nil)

proc applySigDeep(ctx: NsCheckContext; lam: NsNode; sig: NsSig) =
  ## `applySig`, and a lambda the lambda returns (`x => y => x + y`) takes the
  ## signature of the delegate the outer one's result is.
  applySig(lam, sig)
  if lam == nil or lam.kind != nsnLambda or not sig.known or sig.ret == nil: return
  let inner = delegateSig(ctx.scope, ctx.surface, sig.ret)
  if not inner.known or lam.body == nil: return
  for st in lam.body.sons:
    if st == nil: continue
    if st.kind == nsnLambda: ctx.applySigDeep(st, inner)
    elif st.kind == nsnReturn and st.body != nil and st.body.kind == nsnLambda:
      ctx.applySigDeep(st.body, inner)

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

proc chooseLibraryOverload(ctx: NsCheckContext; n: NsNode; kind: var NsTypeKind;
                           tn: var string) =
  ## A library call whose overloads differ by their source's element type (LINQ's
  ## `Sum`): the result of the one the receiver selects, as C# picks it. The callee
  ## records it, for the semantic projection.
  let callee = n.body
  if callee == nil or callee.body == nil: return
  let recvName = (if callee.body.rtype != nil and callee.body.rtype.kind == nsnArrayType: "[]"
                  else: callee.body.typeName)
  if ctx.surface.resultAgrees(recvName, callee.body.typeKind, callee.name): return
  let (rt, isParam) = libInstanceResult(ctx.surface, callee.body, callee.name, n.sons.len,
                                       n.sons)
  if rt == nil: return
  let k = ctx.classifyType(rt)
  if k == tkUnknown: return
  kind = k
  tn = declTypeName(rt)
  n.rtype = rt
  if not isParam: callee.rtype = rt

proc hasPointerType(t: NsNode): bool =
  ## Whether a written type is or contains a pointer (`int*[]`, `List<int*>`).
  if t == nil: return false
  if t.kind in {nsnPointerType, nsnFnPtrType}: return true
  if t.typ != nil and t.typ != t and hasPointerType(t.typ): return true
  for x in t.sons:
    if hasPointerType(x): return true
  if t.kind == nsnParam: return hasPointerType(t.typ)
  false

proc requireUnsafe(ctx: NsCheckContext; info: TLineInfo) =
  ## Pointers outside an unsafe context (an `unsafe` type, member or block): CS0214,
  ## once per site, as a declaration and its uses may be walked more than once.
  if ctx.inUnsafe: return
  let key = $info.fileIndex.int32 & ":" & $info.line & ":" & $info.col
  if ctx.unsafeReported != nil:
    if key in ctx.unsafeReported[]: return
    ctx.unsafeReported[].incl key
  nsError(ctx.config, info, ndUnsafeNeeded)

proc requireUnsafe(ctx: NsCheckContext; t: NsNode; info: TLineInfo) =
  if hasPointerType(t): ctx.requireUnsafe(info)

proc isPointerType(t: NsNode): bool =
  t != nil and t.kind in {nsnPointerType, nsnFnPtrType}

proc declaredTypeOf(ctx: NsCheckContext; n: NsNode; methods = true): NsNode =
  ## The type a local, field or method (its result) named by `n` is declared
  ## with, read before `n` is walked; nil when it is not such a name.
  var m = NsMemberSymbol()
  case n.kind
  of nsnIdent:
    if ctx.types.hasKey(n.name): return ctx.types[n.name].node
    m = ctx.scope.findMemberInfo(ctx.clsName, n.name)
  of nsnMember:
    if n.body != nil and n.body.kind == nsnIdent and not ctx.types.hasKey(n.body.name) and
       ctx.scope.classes.hasKey(canonicalTypeName(n.body.name)):
      m = ctx.scope.findMemberInfo(canonicalTypeName(n.body.name), n.name)
  else: discard
  if m.name.len > 0 and not m.isProperty and (methods or not m.isMethod): m.typ else: nil

proc isPointerValue(ctx: NsCheckContext; n: NsNode): bool =
  ## Whether `n` is a pointer, judged before it is walked: what `(long)n` casts
  ## must be known first, since a pointer's cast reinterprets it.
  case n.kind
  of nsnIdent, nsnMember: isPointerType(ctx.declaredTypeOf(n))
  of nsnIndex:
    ## `ps[i]` of an array or a pointer of pointers.
    let t = (if n.body != nil: ctx.declaredTypeOf(n.body) else: nil)
    t != nil and t.kind in {nsnArrayType, nsnPointerType} and isPointerType(t.typ)
  of nsnCall:
    ## `M(..)` of a method returning a pointer.
    n.body != nil and n.body.kind in {nsnIdent, nsnMember} and
      isPointerType(ctx.declaredTypeOf(n.body))
  of nsnUnary: n.name in ["addr", "fixed"]
  of nsnCast: n.typ != nil and isPointerType(n.typ)
  of nsnBinary:
    n.name in ["+", "-"] and n.sons.len == 2 and
      (if n.name == "+": ctx.isPointerValue(n.sons[0]) xor ctx.isPointerValue(n.sons[1])
       else: ctx.isPointerValue(n.sons[0]) and not ctx.isPointerValue(n.sons[1]))
  else: false

proc walkPointerOp(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  ## `*p`, `&x`, `&M` and `fixed (T* p = e)`'s initialiser (unsafe code).
  ctx.requireUnsafe(n.info)
  result = tkUnknown
  n.setType(tkUnknown)
  case n.name
  of "deref":
    discard ctx.walkExpr(n.body)
    let pt = n.body.rtype
    if pt != nil and pt.kind == nsnPointerType and pt.typ != nil and pt.typ.kind != nsnVoidType:
      result = ctx.classifyType(pt.typ)
      n.setType(result, declTypeName(pt.typ))
      n.rtype = pt.typ
  of "addr":
    let b = n.body
    var owner = ""
    var name = ""
    if b.kind == nsnIdent and not ctx.types.hasKey(b.name) and b.name in ctx.members:
      owner = ctx.clsName
      name = b.name
    elif b.kind == nsnMember and b.body != nil and b.body.kind == nsnIdent and
         ctx.scope.classes.hasKey(canonicalTypeName(b.body.name)):
      owner = canonicalTypeName(b.body.name)
      name = b.name
    elif b.kind == nsnMember and b.body != nil and b.body.kind == nsnMember:
      ## `&Demo.Inner.Helpers.Twice`: the type named with its namespace.
      let dn = dottedName(b.body)
      let dot = dn.rfind('.')
      if dot > 0 and not ctx.types.hasKey(dn.split('.')[0]) and
         dn.split('.')[0] notin ctx.members and ctx.scope.classes.hasKey(dn[dot + 1 .. ^1]):
        owner = dn[dot + 1 .. ^1]
        name = b.name
    let m = (if owner.len > 0: ctx.scope.findMemberInfo(owner, name) else: NsMemberSymbol())
    if m.name.len > 0 and m.isMethod:
      ## `&M`: a function pointer to a static method C may call, which C# marks
      ## `[UnmanagedCallersOnly]`; lowering takes its C entry (`nsUC_<C>_<M>`).
      n.strVal = "method"
      n.typeName = m.owner & "." & m.name
      var callable = false
      if ctx.scope.classes.hasKey(m.owner) and ctx.scope.classes[m.owner].decl != nil:
        for d in ctx.scope.classes[m.owner].decl.sons:
          if d.kind == nsnMethodDecl and d.name == m.name and d.attrs.isStatic and
             d.hasAttribute("UnmanagedCallersOnly"):
            callable = true
      if not callable:
        nsError(ctx.config, n.info, ndUnsupported,
                "'&" & m.owner & "." & m.name & "' of a method without [UnmanagedCallersOnly]")
      return
    discard ctx.walkExpr(b)
    let pointee = (if b.rtype != nil: b.rtype else: nsnTypeName(b.typeName, b.info))
    let pn = canonicalTypeName(pointee.name)
    if pointee.kind == nsnTypeName and ctx.scope.classes.hasKey(pn) and
       ctx.scope.classes[pn].classKind == ckStruct and ctx.scope.classes[pn].native.cpp.len == 0:
      ## An N# struct is laid out with Nim's type header, which a C reader of the
      ## pointer would not expect; P/Invoke takes it by `ref`/`out` instead.
      nsError(ctx.config, n.info, ndUnsupported,
              "the address of a struct (pass it 'ref' or 'out' to C)")
    n.rtype = nsnPointerType(pointee, n.info)
    n.typeName = declTypeName(n.rtype)
  else:
    ## `fixed (T* p = arr)`: the first element of an array, or an address taken.
    discard ctx.walkExpr(n.body)
    let b = n.body
    if b.kind == nsnUnary and b.name == "addr":
      n.rtype = b.rtype
    elif b.rtype != nil and b.rtype.kind == nsnArrayType and b.rtype.typ != nil and
         ctx.scope.marshalOf(b.rtype.typ) in {mkBlittable, mkEnum}:
      n.rtype = nsnPointerType(b.rtype.typ, n.info)
    else:
      nsError(ctx.config, n.info, ndUnsupported,
              "'fixed' over this (an array of numbers, or an address, is supported)")
    if n.rtype != nil: n.typeName = declTypeName(n.rtype)

proc fnPtrTypeOf(ctx: NsCheckContext; n: NsNode): NsNode =
  ## The `delegate*` type of a local or field `n` names, before it is walked.
  if n == nil or n.kind notin {nsnIdent, nsnMember}: return nil
  let t = ctx.declaredTypeOf(n, methods = false)
  if t != nil and t.kind == nsnFnPtrType: t else: nil

proc walkCall(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  var kind = tkUnknown
  var cands: seq[seq[NsNode]] = @[]
  var owner = ""
  var tn = ""
  let callee = n.body
  let ft = ctx.fnPtrTypeOf(callee)
  if ft != nil:
    ## `f(a, b)` through a function pointer: its last type argument is the result.
    discard ctx.walkExpr(callee)
    for a in n.sons: discard ctx.walkExpr(a)
    n.strVal = "fnptr"
    if ft.sons.len > 0 and ft.sons[^1].kind != nsnVoidType:
      result = ctx.classifyType(ft.sons[^1])
      n.setType(result, declTypeName(ft.sons[^1]))
      n.rtype = ft.sons[^1]
    return
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
  elif callee != nil and callee.kind == nsnIdent and ctx.clsName.len > 0 and
       not ctx.isStaticCtx and not ctx.types.hasKey(callee.name) and
       callee.name notin ctx.members and ctx.libraryBaseHas(callee.name):
    ## A method the class inherits from a library type: `this.M(args)`.
    callee.kind = nsnMember
    callee.body = nsn(nsnThis, callee.info)
  if callee != nil and callee.kind == nsnMember:
    ctx.receiver = callee.body
    let rk = ctx.walkExpr(callee.body)
    typeLiteralReceiver(callee.body)
    if rk == tkType:
      ## `Class.Method(...)` or `Namespace.Method(...)`: lowering drops the
      ## qualifier, and the result type is the method's if the class is known.
      owner = unqualified(callee.body.name)
      ## `System.Console` beside a binding's own `Console`: the library's.
      ## ... or a type of a namespace reached qualified, named like the library's
      ## (`Tools.Console`), which the scope leaves out: its own symbol answers.
      let written = dottedName(callee.body)
      let qualifiedOnly = ctx.scope.qualifiedOnly.hasKey(written)
      if qualifiedOnly:
        let m = ctx.qualifiedOnlyMember(callee.body, callee.name, callee.info)
        if m.name.len > 0 and m.typ != nil:
          kind = ctx.classifyType(m.typ)
          tn = declTypeName(m.typ)
          n.rtype = m.typ
      let foreign = ctx.scope.foreignQualified(written) or qualifiedOnly
      if not foreign:
        ctx.checkStaticMember(owner, callee.name, callee.info)
        kind = ctx.memberKind(owner, callee.name)
        if not ctx.scope.classes.hasKey(owner):
          ctx.fillCallerArgs(n, owner, callee.name)
      if kind == tkUnknown:
        ## A static member of a library type: `String.Concat`, `Array.IndexOf`.
        kind = ctx.memberKindOfSurface(ctx.surface.kindOfName(owner), owner,
                                       callee.name, tn)
      if foreign: owner = ""
    elif rk == tkUnknown and ctx.scope.enums.contains(callee.body.typeName):
      ## A member of an enum value: what the library declares for any value
      ## (`ToString`, `GetType`).
      for m in ctx.surface.members.getOrDefault(NsParamKey):
        if m.name == callee.name and m.ret.len > 0 and not m.retIsParam:
          kind = ctx.surface.kindOfSpelling(m.ret)
          tn = m.ret
          n.rtype = nsnTypeName(m.ret, n.info)
          break
    elif rk in {tkString, tkSequence, tkInt, tkFloat, tkBool, tkChar, tkException}:
      ctx.checkMemberUse(callee)
      ## The result the prelude declares (`s.IndexOf(c)` is an `int`), so a member
      ## of it, or arithmetic on it, is typed too.
      kind = ctx.memberKindOfSurface(rk, callee.body.typeName, callee.name, tn)
      ctx.chooseLibraryOverload(n, kind, tn)
      if n.rtype == nil and kind != tkUnknown:
        n.rtype = libGenericResult(ctx.surface, callee.body, callee.name, n.sons.len)
    elif rk == tkClass:
      ctx.checkMemberUse(callee)
      ctx.warnEarlyNative(callee)
      ctx.checkOnHandleThis(callee)
      ctx.checkConstCall(callee)
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
        if not ctx.scope.classes.hasKey(canonicalTypeName(owner)):
          ctx.chooseLibraryOverload(n, kind, tn)
      if n.rtype == nil:
        ## A result of a generic library type (`xs.Where(f)`), bound by the receiver.
        n.rtype = libGenericResult(ctx.surface, callee.body, callee.name, n.sons.len)
    if kind == tkUnknown and callee.name == "GetType" and n.sons.len == 0 and
       rk notin {tkType, tkUnknown}:
      ## `x.GetType()` on a value of a library type (an exception the library
      ## aliases) is a `Type`, as it is of any value.
      kind = tkClass
      tn = "Type"
      n.rtype = nsnTypeName("Type", n.info)
    if callee.typeArgs.len > 0 and ctx.scope.classes.hasKey(owner):
      ## `M<Transform>()`: the written type arguments give the result its type.
      let mi = ctx.scope.findMemberInfo(owner, callee.name)
      if mi.isMethod and mi.typ != nil and mi.typeParams.len == callee.typeArgs.len:
        let st = substitute(mi.typ, mi.typeParams, callee.typeArgs)
        let k = ctx.classifyType(st)
        if k != tkUnknown:
          n.rtype = st
          kind = k
          tn = declTypeName(st)
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
       ctx.types[callee.name].kind in {tkInt, tkFloat, tkBool, tkChar, tkString} and
       ctx.types[callee.name].name != NsLocalFuncMark:
    ## A variable that is not a delegate is called (CS0149).
    nsError(ctx.config, callee.info, ndNotCallable)
    discard ctx.walkExpr(callee)
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
  if callee != nil and callee.kind == nsnMember and cands.len == 0 and callee.body != nil:
    ctx.checkLibraryCall(callee, n.sons)
    let owner = unqualified(callee.body.typeName)
    let first = ctx.surface.member(owner, ctx.surface.kindOfName(owner), callee.name)
    if callee.body.typeKind == tkType and
       (kind == tkUnknown or
        not ctx.surface.resultAgrees(owner, ctx.surface.kindOfName(owner), callee.name) or
        first.retIsParam or first.retIsInstance):
      ## Overloads that differ in their result, or one whose result is a type
      ## parameter: the one the arguments select.
      let rt = ctx.exactLibraryResult(callee, n.sons)
      if rt != nil:
        callee.rtype = rt
        let k = ctx.classifyType(rt)
        if k != tkUnknown:
          kind = k
          tn = declTypeName(rt)
          n.rtype = rt
  n.setType(kind, tn)
  if callee != nil and callee.typeArgs.len > 0 and owner.len > 0 and
     ctx.scope.classes.hasKey(owner):
    ctx.checkExplicitTypeArgs(owner, callee, n.sons)
  if callee != nil and cands.len == 1 and cands[0].len > 0 and isForwardParam(cands[0][^1]):
    ## A `[Forward]` factory: the arguments past its own parameters reach the C++
    ## call as they are, so they are checked against the constructors of the class
    ## it creates, and are given their parameters' types.
    let own = cands[0].len - 1
    let target = ctx.forwardTarget(owner, callee)
    ctx.checkCallArgs(@[cands[0][0 ..< own]], n.sons[0 ..< min(own, n.sons.len)],
                      callee.name, owner, false, n.info)
    if target.len > 0:
      ctx.checkCallArgs(ctx.scope.ctorOverloads(target),
                        (if n.sons.len > own: n.sons[own .. ^1] else: @[]),
                        target, target, true, n.info)
    for j in own ..< n.sons.len:
      n.sons[j].argForward = true
      n.sons[j].argNative = target.len > 0 and ctx.scope.isNative(target)
  elif callee != nil and (callee.kind == nsnMember or cands.len > 0):
    ctx.checkCallArgs(cands, n.sons, callee.name, owner, false, n.info, n)
  let sigs = callLambdaSigs(ctx.scope, ctx.surface, n)
  for j, a in n.sons:
    if isLambdaArg(a):
      let v = (if a.kind == nsnNamedArg: a.body else: a)
      if v.kind == nsnLambda: applySigDeep(ctx, v, sigs[j])
      elif a.argParam != nil:
        var pt = a.argParam.typ
        if a.argElement and pt != nil and pt.kind == nsnArrayType: pt = pt.typ
        ctx.targetTyped(v, pt)
        discard ctx.walkExpr(a)
        ## The conversion to the parameter, as for any other argument.
        if pt != nil: ctx.coerce(v, declTypeName(pt), v.info, pt)
        continue
      discard ctx.walkExpr(a)
  ## What the walked lambdas yield binds the type arguments the others left open
  ## (`T(() => 42)`): their results, and anything else still untyped, take them.
  ## Repeated while it binds more: a lambda whose parameters a type argument now
  ## gives is walked again with them (`Compose(2, a => a + 1, b => b * 1.5)`).
  for round in 0 ..< 4:
    var open = false
    for j, a in n.sons:
      let v = (if a.kind == nsnNamedArg: a.body else: a)
      if isLambdaArg(a) and sigs[j].known and v.kind == nsnLambda:
        if v.typ == nil: open = true
        for p in v.params:
          if p.typ == nil: open = true
    if not open: break
    let again = callLambdaSigs(ctx.scope, ctx.surface, n)
    var changed = false
    for j, a in n.sons:
      let v = (if a.kind == nsnNamedArg: a.body else: a)
      if not isLambdaArg(a) or v.kind != nsnLambda: continue
      var before = (if v.typ == nil: 1 else: 0)
      for p in v.params:
        if p.typ == nil: inc before
      applySigDeep(ctx, v, again[j])
      var after = (if v.typ == nil: 1 else: 0)
      for p in v.params:
        if p.typ == nil: inc after
      if after < before:
        changed = true
        discard ctx.walkExpr(v)
    if not changed: break
  if callee != nil and callee.kind == nsnMember and callee.typeArgs.len > 0 and
     cands.len == 0:
    ## A library method's written type arguments (`xs.Select<int, object>(f)`) have
    ## typed its lambdas, which then tell Nim the rest; written in Nim they would
    ## name a type class (`NsEnumerable[int32]`) where only a type can stand.
    var lambdas = 0
    var typed = true
    for a in n.sons:
      let v = (if a.kind == nsnNamedArg: a.body else: a)
      if v.kind == nsnLambda:
        inc lambdas
        if v.typ == nil: typed = false
        for p in v.params:
          if p.typ == nil: typed = false
    if lambdas > 0 and typed: callee.typeArgs = @[]
  if callee != nil and callee.kind == nsnMember:
    ## Each lambda as its delegate, for Nim, which cannot infer through two uses of
    ## one generic delegate (`Compose(a, f, g)`), once the arguments bind them all.
    let dts = inferredDelegateTypes(ctx.scope, ctx.surface, n)
    for j, a in n.sons:
      if j >= dts.len or dts[j] == nil: continue
      let v = (if a.kind == nsnNamedArg: a.body else: a)
      if v.kind == nsnLambda and v.conv.len == 0:
        v.conv = "nsAsDelegate"
        v.convType = dts[j]
  if callee != nil and callee.kind == nsnMember and cands.len == 0 and
     callee.body != nil and callee.body.typeKind != tkType and
     not ctx.scope.classes.hasKey(canonicalTypeName(callee.body.typeName)):
    ## The overload the typed lambdas select (`people.Sum(p => p.Age)` is the
    ## `int` one's).
    var tn2 = ""
    var k2 = kind
    ctx.chooseLibraryOverload(n, k2, tn2)
    let recvName = (if callee.body.rtype != nil and callee.body.rtype.kind == nsnArrayType: "[]"
                    else: callee.body.typeName)
    if not ctx.surface.resultAgrees(recvName, callee.body.typeKind, callee.name):
      ## A lambda whose result the overloads tell apart says it, so Nim, which
      ## would fit an `auto` one to several, takes the one C# does.
      for a in n.sons:
        let v = argValue(a)
        if v != nil and v.kind == nsnLambda and v.typ == nil:
          let lr = lambdaResult(v)
          if lr != nil and lr.kind == nsnTypeName and isNumericName(canonicalTypeName(lr.name)):
            v.typ = copyNsTree(lr)
    if n.rtype != nil and k2 != kind:
      kind = k2
      n.setType(kind, tn2)
  if callee != nil and callee.kind == nsnMember and cands.len == 0 and
     callee.body != nil and callee.body.typeKind != tkType and n.rtype == nil:
    ## A library result that only the lambdas bind (`xs.Select(x => "n" + x)` is an
    ## `IEnumerable<string>`), now that they are typed.
    let rt = libGenericResult(ctx.surface, callee.body, callee.name, n.sons.len, n.sons)
    if rt != nil:
      n.rtype = rt
      let k = ctx.classifyType(rt)
      if k != tkUnknown:
        kind = k
        n.setType(kind, declTypeName(rt))
  if callee != nil and callee.kind == nsnMember and cands.len == 0:
    ctx.libraryOutTypes(callee, n.sons)
  if kind == tkUnknown and callee != nil and callee.kind == nsnIdent and
     ctx.types.hasKey(callee.name) and ctx.types[callee.name].kind == tkDelegate and
     ctx.types[callee.name].node != nil and
     ctx.types[callee.name].node.kind in {nsnTypeName, nsnNullableType}:
    ## `f()` of a delegate variable: its delegate's result (`Func<int?>` is an
    ## `int?`), which a conversion of the value needs.
    let sig = delegateSig(ctx.scope, ctx.surface, ctx.types[callee.name].node)
    if sig.known and sig.ret != nil and sig.ret.kind != nsnVoidType:
      kind = ctx.classifyType(sig.ret)
      n.rtype = sig.ret
      n.setType(kind, declTypeName(sig.ret))
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

proc nestedTypeHides(ctx: NsCheckContext; name: string): bool =
  ## A type nested in the class or one of its bases (hoisted out, its `outer`
  ## names them), which C#'s lookup finds before an inherited member.
  if not ctx.scope.classes.hasKey(name): return false
  let d = ctx.scope.classes[name].decl
  if d == nil or d.outer.len == 0: return false
  d.outer.split('+')[^1] in ctx.scope.lookupChain(ctx.clsName)

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
    if pat.name.len == 0 and pat.typ != nil and pat.typ.kind == nsnTypeName and
       pat.typ.sons.len == 0 and '.' notin pat.typ.name and ctx.clsName.len > 0 and
       ctx.scope.findMemberInfo(ctx.clsName, pat.typ.name).isConst and
       not ctx.nestedTypeHides(pat.typ.name):
      ## `case Max:` naming a constant of the class, which C#'s lookup finds before
      ## a type of that name elsewhere (the parser only knows a type exists).
      pat.kind = nsnPatConst
      pat.body = nsnIdent(pat.typ.name, pat.typ.info)
      pat.typ = nil
      ctx.walkPattern(pat, subject)
      return
    ctx.checkTypeTest(pat)
    let k = ctx.classifyType(pat.typ)
    if pat.name.len > 0:
      ctx.declare(pat.name, k, declTypeName(pat.typ), pat.typ)
  of nsnPatConst, nsnPatRel:
    discard ctx.walkExpr(pat.body)
    if pat.body != nil and pat.body.kind == nsnIdent and ctx.types.hasKey(pat.body.name) and
       ctx.types[pat.body.name].name != NsLocalFuncMark:
      ## A variable is no constant to match against (CS9135).
      nsError(ctx.config, pat.body.info, ndConstantExpected, kindSpelling(pat.body))
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

proc checkCtorAccess(ctx: NsCheckContext; cn: string; n: NsNode) =
  ## `new C()` outside `C` (and the types nested in it) when every constructor
  ## `C` declares is private (CS0122).
  let d = ctx.scope.classes[cn].decl
  if d == nil or d.primary.len > 0 or d.attrs.isRecord: return
  var c = ctx.clsName
  while c.len > 0:
    if c == cn: return
    c = (if ctx.scope.classes.hasKey(c): ctx.scope.classes[c].enclosing else: "")
  var first: NsNode = nil
  for m in d.sons:
    if m.kind == nsnCtorDecl and not m.attrs.isStatic:
      if m.attrs.access != aPrivate or m.attrs.isPrimary: return
      if first == nil or m.params.len == n.sons.len: first = m
  if first != nil:
    nsError(ctx.config, n.info, ndNotAccessible, signature(cn & "." & cn, first.params))

proc walkExprIn(ctx: var NsCheckContext; n: NsNode): NsTypeKind

proc walkExpr(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  ## Any value of a pointer type needs an unsafe context (CS0214).
  result = ctx.walkExprIn(n)
  if n == nil or ctx.inUnsafe: return
  if n.kind in {nsnIdent, nsnMember, nsnIndex, nsnCall} and hasPointerType(n.rtype):
    ctx.requireUnsafe(n.info)
  elif n.kind == nsnDefault and hasPointerType(n.typ):
    ctx.requireUnsafe(n.info)
  if n.kind in {nsnCall, nsnNew}:
    ## An argument converted to a pointer parameter (`Take(null)`).
    for a in n.sons:
      if a != nil and a.argParam != nil and hasPointerType(a.argParam.typ):
        ctx.requireUnsafe(a.info)

proc walkExprIn(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
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
    if n.kind == nsnRefArg and n.name in ["ref", "out"] and n.body != nil and
       n.body.kind in {nsnIntLit, nsnStrLit, nsnFloatLit, nsnBoolLit, nsnCharLit, nsnNull,
                       nsnBinary, nsnNew}:
      ## Only a variable can be passed by reference (CS1510).
      nsError(ctx.config, n.body.info, ndRefNotVariable)
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
    elif n != ctx.receiver and ctx.clsName.len > 0 and ctx.scope.classes.hasKey(ctx.clsName) and
         ctx.scope.nativeBased(ctx.clsName) and not ctx.scope.isNative(ctx.clsName):
      ## `this` as a value in a class deriving a native one: the engine may move the
      ## object, so it is passed as its own handle, which `SelfHandle` reaches.
      let root = ctx.scope.handleRoot(ctx.clsName)
      if root.len == 0:
        var base = ctx.clsName
        for c in ctx.scope.chain(ctx.clsName):
          if ctx.scope.isNative(c):
            base = c
            break
        nsError(ctx.config, n.info, ndNativeThisNoHandle, ctx.clsName, base)
      elif ctx.scope.classes[root].native.handle.len > 0 and
           ctx.scope.classes[root].native.selfHandle.len == 0:
        nsError(ctx.config, n.info, ndNativeNoSelfHandle, ctx.clsName, root)
      elif ctx.inCtor and not ctx.ctorIsStatic:
        nsWarn(ctx.config, n.info, ndNativeCtorEarly, "this", ctx.clsName)
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
    ctx.checkTypeArgs(n.typ)
    if n.typ != nil and ctx.clsName.len > 0:
      let u = ctx.firstUnknownType(n.typ)
      if u != nil: nsError(ctx.config, u.info, ndNamespaceNotFound, u.name)
      elif n.typ.kind == nsnTypeName and '.' notin n.typ.name and
           not ctx.scope.classes.hasKey(n.typ.name) and
           not ctx.scope.delegates.hasKey(n.typ.name):
        ## A library type is only in scope through its namespace (`new List<int>()`
        ## needs `using System.Collections.Generic;`), CS0246 otherwise.
        let nim = nimTypeName(n.typ.name)
        let key = (if ctx.surface.types.hasKey(nim & $n.typ.sons.len): nim & $n.typ.sons.len
                   else: nim)
        if ctx.surface.types.hasKey(key):
          let ns = ctx.surface.types[key].path.replace('/', '.')
          if ns.len > 0 and ns notin ctx.usingNamespaces:
            var shown = n.typ.name
            if n.typ.sons.len > 0: shown.add "<" & repeat(",", n.typ.sons.len - 1) & ">"
            nsError(ctx.config, n.typ.info, ndNamespaceNotFound, shown)
    if n.typ == nil:
      ## `new()` whose target gave it no type.
      nsError(ctx.config, n.info, ndUnsupported, "a target-typed 'new()' without a target")
      return tkUnknown
    for a in n.sons: discard ctx.walkExpr(a)
    n.rtype = n.typ
    let k = ctx.classifyType(n.typ)
    n.setType(k, (if n.typ != nil: canonicalTypeName(n.typ.name) else: ""))
    if n.typ != nil and n.typ.kind == nsnTypeName:
      ## `new C(...)`: the constructors of a class the scope knows are checked the
      ## same way a method call's parameter lists are. A BCL type has none here.
      let cn = unqualified(n.typ.name)
      if ctx.scope.classes.hasKey(cn):
        ctx.warnObsolete(ctx.scope.classes[cn].obsolete, cn, n.info)
        if ctx.scope.classes[cn].isStatic:
          nsError(ctx.config, n.info, ndStaticClassInstance, cn)
        elif ctx.scope.classes[cn].classKind == ckClass and ctx.scope.engineOwned(cn):
          ## A class of a handle family is the engine's to create and to destroy:
          ## its own factory (`Spawn<T>()`) makes one. One of a family with no
          ## handle is N#'s, like any other object.
          nsError(ctx.config, n.info, ndNativeNew, cn)
        elif ctx.scope.classes[cn].isAbstract or
           ctx.scope.classes[cn].classKind == ckInterface:
          nsError(ctx.config, n.info, ndAbstractInstance, cn)
        ctx.checkCallArgs(ctx.scope.ctorOverloads(cn), n.sons, cn, cn, true, n.info, n)
        ctx.checkCtorAccess(cn, n)
      elif ctx.scope.isValueInterface(cn):
        ## A library interface (`IList<T>`) is no more constructible than a user's.
        nsError(ctx.config, n.info, ndAbstractInstance, cn)
      else:
        ctx.libraryCtorConvert(n)
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
      ## Declared with its type arguments, so `Add` on a `List<object>` boxes.
      ctx.declare(n.strVal, k, (if n.typ != nil: declTypeName(n.typ) else: ""), n.typ)
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
        ctx.checkConvertible(a, ctx.targetOfType(n.typ), a.info)
        ctx.coerce(a, declTypeName(n.typ), a.info, n.typ)
    if n.kind == nsnNewArray:
      for a in n.sons:
        if a.typeKind in {tkString, tkBool}:
          ## An array's length is a number (CS0029).
          nsError(ctx.config, a.info, ndCannotConvert, kindSpelling(a), "int")
    if n.kind == nsnArrayLit and n.typ == nil:
      ## `new[] { 1.5, 2.5 }`: the element type is the elements' best common type
      ## (ECMA-334 12.6.3.15), the candidate every element converts to implicitly:
      ## `{ long.MaxValue, 1 }` is a `long[]`, `{ dog, animal }` an `Animal[]`,
      ## `{ n, 1 }` for an `int? n` an `int?[]`; with none, CS0826.
      var cands: seq[NsNode] = @[]
      var hasNull = false
      var unknown = false
      for a in n.sons:
        if a.kind == nsnNull:
          hasNull = true
          continue
        let vt = valueType(a)
        if vt == nil:
          unknown = true
          continue
        var seen = false
        for c in cands:
          if mangleType(c) == mangleType(vt): seen = true
        if not seen: cands.add vt
      proc numOf(t: NsNode): string =
        if t != nil and t.kind == nsnTypeName: numericOfSpelling(canonicalTypeName(t.name))
        else: ""
      let scope = ctx.scope
      proc holdsNull(c: NsNode): bool =
        ## A reference type, or a nullable value type.
        c.kind in {nsnNullableType, nsnArrayType} or
          (c.kind == nsnTypeName and numOf(c).len == 0 and
           canonicalTypeName(c.name) notin ["bool", "char"] and
           not (scope.classes.hasKey(canonicalTypeName(c.name)) and
                scope.classes[canonicalTypeName(c.name)].decl != nil and
                scope.classes[canonicalTypeName(c.name)].decl.classKind == ckStruct) and
           not scope.enums.contains(canonicalTypeName(c.name)))
      proc converts(o, c: NsNode): bool =
        ## Whether a value of type `o` converts implicitly to `c`.
        if mangleType(o) == mangleType(c): return true
        if c.kind == nsnNullableType:
          return (o.kind == nsnNullableType and converts(o.typ, c.typ)) or
                 (o.kind != nsnNullableType and converts(o, c.typ))
        if o.kind == nsnNullableType: return false
        let on = numOf(o)
        let cn = numOf(c)
        if on.len > 0 or cn.len > 0:
          return on.len > 0 and cn.len > 0 and implicitlyConvertible(on, cn)
        if o.kind == nsnTypeName and c.kind == nsnTypeName:
          let cName = canonicalTypeName(c.name)
          if cName == "object": return true
          return scope.implements(canonicalTypeName(o.name), cName)
        false
      for c in cands:
        var best = not (hasNull and not holdsNull(c))
        for o in cands:
          if best and not converts(o, c): best = false
        if best:
          n.typ = c
          break
      if n.typ == nil and not unknown:
        nsError(ctx.config, n.info, ndNoBestArrayType)
      if n.typ != nil and (cands.len > 1 or hasNull):
        for a in n.sons:
          let conv = ctx.argConv(a, n.typ)
          if conv != acNone:
            ## Into a `T?`: `some`/`none` with the element type, as an argument.
            a.argConv = conv
            a.argConvType = declTypeName(n.typ.typ)
          else:
            ctx.markNull(a, declTypeName(n.typ), n.typ)
            ctx.coerce(a, declTypeName(n.typ), a.info, n.typ)
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
    if n.body != nil and n.body.rtype != nil and n.body.rtype.kind == nsnPointerType and
       n.body.rtype.typ != nil and n.body.rtype.typ.kind != nsnVoidType:
      ## `p[i]`: the `i`th `T` from where `p` points.
      for x in n.sons: discard ctx.walkExpr(x)
      let t = n.body.rtype.typ
      result = ctx.classifyType(t)
      n.setType(result, declTypeName(t))
      n.rtype = t
      return
    if n.body != nil and n.body.typeKind in {tkInt, tkFloat, tkBool, tkChar}:
      ## Only arrays, strings and types with an indexer take `[]` (CS0021).
      nsError(ctx.config, n.info, ndNotIndexable, kindSpelling(n.body))
    elif n.body != nil and (n.body.typeKind == tkString or
         (n.body.rtype != nil and n.body.rtype.kind == nsnArrayType and
          n.body.rtype.intVal < 2)):
      for a in n.sons:
        if a != nil and a.kind notin {nsnRange, nsnFromEnd}:
          discard ctx.walkExpr(a)
          if a.typeKind in {tkString, tkBool}:
            nsError(ctx.config, a.info, ndCannotConvert, kindSpelling(a), "int")
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
    if n.body != nil and n.body.typeKind in {tkClass, tkSequence} and n.sons.len == 1 and
       n.sons[0] != nil and n.sons[0].kind notin {nsnRange, nsnFromEnd} and
       not ctx.scope.classes.hasKey(canonicalTypeName(n.body.typeName)) and
       (n.body.rtype == nil or n.body.rtype.kind != nsnArrayType):
      ## A library collection's indexer takes its key type (CS1503).
      let probe = nsnMember(n.body, "[]", n.info)
      ctx.checkLibraryCall(probe, n.sons)
  of nsnUnary:
    if n.name in ["deref", "addr", "fixed"]: return ctx.walkPointerOp(n)
    result = ctx.walkExpr(n.body)
    if n.name == "-" and n.body != nil and n.body.kind == nsnIntLit and
       n.body.strVal.len == 0 and n.body.intVal == 2147483648'i64:
      ## `-2147483648` is the `int` `int.MinValue`: C# reads the literal 2147483648
      ## under a minus as an `int` (§12.9.3), though alone it is a `uint`.
      n.body.setType(tkInt, "")
    elif n.name == "-" and n.body != nil and n.body.kind == nsnIntLit and
         n.body.typeName == "uint" and n.body.strVal.len == 0:
      ## A negated `uint` is a `long` (§12.9.3): `-2147483649` is a `long` literal.
      n.body.setType(tkInt, "long")
    block unaryCheck:
      ## `!` takes a bool, `-`/`+` a number, `~` an integer (CS0023).
      let k = result
      if k notin {tkInt, tkFloat, tkBool, tkChar, tkString}: break unaryCheck
      let ok = case n.name
               of "not": (if n.strVal == "!": k == tkBool else: k in {tkInt, tkChar})
               of "-", "+": k in {tkInt, tkFloat, tkChar}
               else: true
      if not ok:
        nsError(ctx.config, n.info, ndUnaryOperand,
                (if n.name == "not": (if n.strVal == "!": "!" else: "~") else: n.name),
                kindSpelling(n.body))
        n.setType(tkUnknown)
        return tkUnknown
    n.setType(result, n.body.typeName)
    n.rtype = n.body.rtype
    if ctx.inChecked and result == tkClass:
      ## `-x` in a `checked` context calls `operator checked -` if the type has one.
      let cop = ctx.scope.userOperator(n.body.typeName, n.name, 1, checked = true)
      if cop != nil: n.argParam = cop
  of nsnIncDec:
    result = ctx.walkExpr(n.body)
    ctx.checkAssignable(n.body)
    ctx.checkQualifiedOnlyUpdate(n.body)
    ctx.noteMutation(n.body)
    n.setType(result, n.body.typeName)
    n.rtype = n.body.rtype
  of nsnCast:
    if n.typ != nil and n.typ.kind in {nsnPointerType, nsnFnPtrType}:
      ## `(int*)p`, `(void*)x`: a reinterpretation, not a conversion.
      ctx.requireUnsafe(n.info)
      discard ctx.walkExpr(n.body)
      result = ctx.classifyType(n.typ)
      n.setType(result, declTypeName(n.typ))
      n.rtype = n.typ
      return
    if n.typ != nil and n.typ.kind == nsnTypeName and n.body != nil and
       canonicalTypeName(n.typ.name) in ["nint", "nuint", "long", "ulong"] and
       ctx.isPointerValue(n.body):
      ## `(IntPtr)p`: a pointer's address as a number.
      discard ctx.walkExpr(n.body)
      n.strVal = "reinterpret"
      result = ctx.classifyType(n.typ)
      n.setType(result, declTypeName(n.typ))
      n.rtype = n.typ
      return
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
         not ctx.scope.isValueInterface(declTypeName(n.typ)):
      n.strVal = "unbox"
    else:
      ctx.checkCast(n, target)
    ## A numeric cast's result has the exact type written, which promotion and
    ## overload resolution read (`F((short)1)`).
    if target in {tkInt, tkFloat, tkChar} and isNumericName(declTypeName(n.typ)):
      n.setType(target, declTypeName(n.typ))
    elif isObjectTarget(n.typ):
      ## `(object)v` is an `object`, which a cast of it unboxes: `(int)(object)5`.
      n.setType(target, "object")
    elif target in {tkClass, tkException} and n.typ != nil and n.typ.kind == nsnTypeName:
      ## `((MyEx)e).Message`: the result is of the named class, as `as` makes it.
      n.setType(target, declTypeName(n.typ))
      n.rtype = n.typ
    else:
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
    if target in {tkString, tkSequence, tkNullable}:
      ## `o as string`, `o as int[]`, `o as int?`: references and `T?` take `as`;
      ## from an `object` the box is asked, from one of the type it is the value.
      if canonicalTypeName(n.body.typeName) in ["object", "Object"]: n.strVal = "boxed"
      elif n.body.typeKind == target: n.strVal = "same"
    elif target in NsValueKinds:
      ## C# rejects `as` on a value type, which is what a cast is for.
      nsError(ctx.config, n.info, ndUnsupported, "'as' with a value type")
    ## The result is of the named type, which a `var` declared from it takes.
    n.setType(target, declTypeName(n.typ))
    n.rtype = n.typ
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
    let (lk0, rk0) = (lk, rk)
    if n.name in ["+", "-"]:
      ## `p + n`, `n + p`, `p - n`: the pointer, moved.
      let lp = isPointerType(n.sons[0].rtype)
      let rp = isPointerType(n.sons[1].rtype)
      if lp != rp and (lp or n.name == "+"):
        n.rtype = (if lp: n.sons[0].rtype else: n.sons[1].rtype)
        n.setType(tkUnknown, declTypeName(n.rtype))
        return tkUnknown
    if n.name in ["==", "!="]:
      ## `s == null` for a string compares with the empty string.
      if lk == tkString: ctx.markNull(n.sons[1], "string")
      if rk == tkString: ctx.markNull(n.sons[0], "string")
    result = tkUnknown
    let ln = numName(n.sons[0])
    let rn = numName(n.sons[1])
    var numResult = ""
    if ln.len > 0 and rn.len > 0:
      if n.name in ["shl", "shr", "ushr"]:
        ## The count is an `int`; the result is the promoted left operand.
        numResult = unaryPromoted(ln)
        if isConstantLit(n.sons[0]) and n.sons[0].typeName.len == 0:
          ## `shl` gives a literal no context to take its type from.
          n.sons[0].conv = numResult
        else:
          needConv(n.sons[0], numResult)
      elif n.name in ["==", "!=", "<", ">", "<=", ">="] and ln == "char" and rn == "char":
        discard
      else:
        ## An integer constant beside a `uint` or `ulong` takes that type when it
        ## fits (ECMA-334 10.2.11), so overload resolution picks the unsigned
        ## operator: `u - 6` is a `uint` and wraps, it is not a `long`.
        let ln1 = (if constantFitsUnsigned(n.sons[0], ln, rn): rn else: ln)
        let rn1 = (if constantFitsUnsigned(n.sons[1], rn, ln): ln else: rn)
        let p = promoted(ln1, rn1)
        if p.len > 0:
          needConv(n.sons[0], p)
          needConv(n.sons[1], p)
          if n.name notin ["==", "!=", "<", ">", "<=", ">="]:
            numResult = p
            ## The operands now have the promoted type, which is what the integer
            ## division rule below asks about.
            lk = kindOfNumeric(p)
            rk = lk
    ## A lifted operator's other operand converts to the nullable's element type
    ## (`a + 1`, `3 == a`), so the library's lifted operator sees one `T`.
    var liftedInner = ""
    if lk == tkNullable and rk != tkNullable: liftedInner = n.sons[0].typeName
    elif rk == tkNullable and lk != tkNullable: liftedInner = n.sons[1].typeName
    elif lk == tkNullable: liftedInner = n.sons[0].typeName
    if liftedInner.len > 0 and (lk == tkNullable) != (rk == tkNullable):
      let other = (if lk == tkNullable: n.sons[1] else: n.sons[0])
      let on = numName(other)
      ## A bare literal too, which Nim would type `int` and so bind `T` to that.
      if on.len > 0 and isNumericName(liftedInner) and
         (on != liftedInner or (isConstantLit(other) and other.typeName.len == 0)) and
         (implicitlyConvertible(on, liftedInner) or
          (isConstantLit(other) and fitsLiteral(constValue(other), liftedInner))):
        other.conv = liftedInner
    ## An enum operand: the literal `0` beside it is of the enum (10.2.4), and
    ## `&`, `|`, `^` of two values of it are of it too (`(p & Perm.W) == 0`).
    let leftEnum = canonicalTypeName(n.sons[0].typeName)
    let rightEnum = canonicalTypeName(n.sons[1].typeName)
    let le = ctx.scope.enums.contains(leftEnum)
    let re = ctx.scope.enums.contains(rightEnum)
    if le or re:
      if le and isZeroLiteral(n.sons[1]): n.sons[1].conv = leftEnum
      if re and isZeroLiteral(n.sons[0]): n.sons[0].conv = rightEnum
      if n.name in ["and", "or", "xor"] and n.strVal != "logical":
        let e = (if le: leftEnum else: rightEnum)
        n.setType(tkUnknown, e)
        return tkUnknown
    if n.name in ["+", "-"] and lk == tkDelegate and rk == tkDelegate:
      ## Delegate combination and removal: a delegate of the left operand's type.
      n.setType(tkDelegate, n.sons[0].typeName)
      n.rtype = n.sons[0].rtype
      return tkDelegate
    case n.name
    of "==", "!=", "<", ">", "<=", ">=":
      result = tkBool
    of "and", "or", "xor":
      ## Bitwise on integers, logical otherwise; three-valued on a `bool?`.
      result = (if lk == tkNullable or rk == tkNullable: tkNullable
                elif lk == tkInt and rk == tkInt: tkInt else: tkBool)
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
      elif lk in {tkInt, tkFloat, tkChar} and rk in {tkInt, tkFloat, tkChar}:
        ## The floating-point remainder (12.10.4): truncated, with the dividend's
        ## sign, which is C's `fmod` and not Nim's integer `mod`.
        n.name = "nsFmod"
        result = tkFloat
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
    elif result == tkNullable:
      ## The lifted result has the element type, which `== null` spells `none(T)`.
      n.setType(result, liftedInner)
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
    let lhs = n.sons[0]
    let rhs = n.sons[1]
    if n.rtype == nil and lhs != nil and rhs != nil and lhs.typeKind == tkClass and
       lhs.typeName.len > 0 and not ctx.scope.classes.hasKey(lhs.typeName):
      ## An operator the library declares on its own struct (`DateTime - DateTime`
      ## is a `TimeSpan`): the overload whose right operand is the right side's type.
      ## Exactly first, then an integer widened to a floating-point parameter.
      ## A literal has a kind and no name: `0.5` is a `double`, `2` an `int`.
      let want = canonicalTypeName(if rhs.typeName.len > 0: rhs.typeName
                                   elif rhs.typeKind == tkFloat: "double"
                                   elif rhs.typeKind == tkInt: "int"
                                   else: "")
      var spellings = @[want, ctx.surface.nimSpellingOf(want)]
      if "float64" in spellings: spellings.add "float"
      block found:
        for widen in [false, true]:
          for o in ctx.surface.overloads(lhs.typeName, tkClass, n.name):
            if o.paramTypes.len != 2 or o.ret.len == 0: continue
            let p = headSpelling(o.paramTypes[1])
            if (want.len > 0 and p in spellings) or
               (widen and rhs.typeKind == tkInt and p in ["float", "float64"]):
              result = ctx.surface.kindOfName(o.ret)
              n.setType(result, o.ret)
              break found
    if n.typeKind != tkClass or n.rtype == nil:
      ctx.checkOperands(n, lk0, rk0)
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
    if result in {tkInt, tkFloat, tkBool, tkChar} and n.intVal == 0 and
       n.sons.len > 0 and n.sons[0] != nil:
      ## Without `??` a value-typed result is a `T?` (12.8.8): absent when the
      ## receiver is null.
      let tail = n.sons[0]
      let inner = (if numName(tail).len > 0: numName(tail)
                   elif result == tkBool: "bool" elif result == tkChar: "char"
                   else: tail.typeName)
      n.setType(tkNullable, inner)
      return tkNullable
    n.setType(result, (if result == tkString: "string" else: ""))
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
    ## A built-in value type's size is a constant (C# 12.8.19), which converts as a
    ## literal does (`nuint n = sizeof(int)`); a pointer's, or (unsafe code) a C-laid
    ## struct's, is known when the program is built. `char` is left to lowering:
    ## N#'s is one byte where C#'s is two.
    let k = ctx.classifyType(n.typ)
    let tn = (if n.typ != nil and n.typ.kind == nsnTypeName: canonicalTypeName(n.typ.name) else: "")
    let size = case tn
               of "sbyte", "byte", "bool": 1
               of "short", "ushort": 2
               of "int", "uint", "float": 4
               of "long", "ulong", "double": 8
               else: 0
    if size > 0:
      n.kind = nsnIntLit
      n.intVal = size
      n.setType(tkInt, "")
      return tkInt
    if hasPointerType(n.typ):
      ctx.requireUnsafe(n.info)
    elif tn notin ["char", "decimal"] and not ctx.scope.enums.contains(tn) and
         not ctx.inUnsafe:
      ## Only a built-in type has a predefined size (CS0233).
      nsError(ctx.config, n.info, ndSizeofUnsafe, declTypeName(n.typ))
    if k notin {tkInt, tkFloat, tkBool, tkChar} and
       not (n.typ != nil and n.typ.kind in {nsnPointerType, nsnFnPtrType}) and
       not ctx.scope.isMarshalableStruct(tn):
      nsError(ctx.config, n.info, ndUnsupported,
              "'sizeof' of a type other than a built-in value type, a pointer or a struct of them")
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
    ctx.checkCondition(n.sons[0])
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
    inc ctx.lambdaDepth
    let savedLamRet = ctx.retType
    ## A lambda's `return` is the lambda's: its delegate's result, when known.
    ctx.retType = (if n.typ != nil and not ctx.isTypeParamRef(n.typ): n.typ else: nil)
    let savedHost = ctx.yieldHost
    ctx.yieldHost = yhNone
    for p in n.params:
      if p.typ != nil: ctx.declare(p.name, ctx.classifyType(p.typ), declTypeName(p.typ),
                                   p.typ)
      else: ctx.declare(p.name, tkUnknown)
    if n.body != nil and n.body.strVal == "expr" and n.body.sons.len == 1:
      ## `() => e`: the expression is the lambda's result.
      let e = n.body.sons[0]
      if ctx.retType != nil and ctx.retType.kind != nsnVoidType:
        ctx.targetTyped(e, ctx.retType)
      discard ctx.walkExpr(e)
      if ctx.retType != nil and ctx.retType.kind != nsnVoidType:
        ## `() => "s"` for a `Func<int>` (CS0029).
        ctx.checkConvertible(e, ctx.targetOfType(ctx.retType), e.info)
        ## ... and the result converts as a `return`'s does (`() => 42` for a
        ## `Func<object>` boxes it).
        if ctx.retType.kind != nsnNullableType:
          ctx.coerce(e, declTypeName(ctx.retType), e.info, ctx.retType)
        else:
          ctx.nullableValue(e, ctx.retType)
    elif n.body != nil:
      ctx.walkInScope(n.body.sons)
    ctx.yieldHost = savedHost
    dec ctx.lambdaDepth
    ctx.retType = savedLamRet
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

const NsFrontendTypes = ["Func", "Action", "Predicate", "Comparison", "Converter",
                         "Index", "Range", "Nullable", "Tuple", "ValueTuple",
                         "IEnumerable", "IEnumerator", "dynamic", "var"]
  ## Types the frontend gives meaning itself rather than finding in the library:
  ## the delegate shapes, `Index`/`Range`, tuples.

proc typeKnown(ctx: NsCheckContext; t: NsNode): bool =
  ## Whether every name in a written type is one N# can place. Only a plain,
  ## unqualified name is ever judged unknown; anything else is left to Nim.
  if t == nil: return true
  case t.kind
  of nsnTypeName:
    if '.' notin t.name and not ctx.isTypeName(t.name) and t.name notin ctx.typeParams and
       t.name notin NsFrontendTypes:
      return false
    for a in t.sons:
      if not ctx.typeKnown(a): return false
    true
  of nsnArrayType, nsnNullableType: ctx.typeKnown(t.typ)
  of nsnTupleType:
    for e in t.sons:
      if not ctx.typeKnown(e.typ): return false
    true
  else: true

proc firstUnknownType(ctx: NsCheckContext; t: NsNode): NsNode =
  if t == nil: return nil
  case t.kind
  of nsnTypeName:
    if '.' notin t.name and canonicalTypeName(t.name) in ctx.scope.qualifiedTypes:
      ## Reachable only qualified (`Tools.Widget`), with no `using` (CS0246).
      return t
    if not ctx.typeKnown(nsnTypeName(t.name, t.info)): return t
    for a in t.sons:
      let u = ctx.firstUnknownType(a)
      if u != nil: return u
  of nsnArrayType, nsnNullableType: return ctx.firstUnknownType(t.typ)
  of nsnTupleType:
    for e in t.sons:
      let u = ctx.firstUnknownType(e.typ)
      if u != nil: return u
  else: discard
  nil

proc checkTernaryTypes(ctx: NsCheckContext; n: NsNode) =
  ## `var x = c ? 1 : "s";`: with no target type, one branch must convert to the
  ## other's type (CS0173).
  let a = n.sons[1]
  let b = n.sons[2]
  const known = {tkInt, tkFloat, tkBool, tkChar, tkString}
  if a.typeKind notin known or b.typeKind notin known or a.kind == nsnNull or
     b.kind == nsnNull: return
  let num = {tkInt, tkFloat, tkChar}
  if a.typeKind == b.typeKind or (a.typeKind in num and b.typeKind in num): return
  nsError(ctx.config, n.info, ndTernaryTypes, kindSpelling(a), kindSpelling(b))

proc checkValue(ctx: NsCheckContext; v: NsNode) =
  ## A type named where a value is expected (CS0119).
  if v != nil and v.kind == nsnIdent and v.typeKind == tkType and
     not ctx.types.hasKey(v.name):
    nsError(ctx.config, v.info, ndTypeAsValue, v.name)

proc checkTypeArgs(ctx: NsCheckContext; t: NsNode) =
  ## A generic type of this compilation written with the wrong number of type
  ## arguments (CS0305, CS0308), or one breaking a `class`/`struct` constraint
  ## (CS0452, CS0453).
  if t == nil: return
  case t.kind
  of nsnArrayType, nsnNullableType: ctx.checkTypeArgs(t.typ)
  of nsnTypeName:
    for a in t.sons: ctx.checkTypeArgs(a)
    let cn = canonicalTypeName(t.name)
    if not ctx.scope.classes.hasKey(cn): return
    let tps = ctx.scope.classes[cn].typeParams
    if tps.len == 0 and t.sons.len > 0:
      nsError(ctx.config, t.info, ndNotGenericType, cn)
    elif tps.len != t.sons.len and t.sons.len > 0:
      nsError(ctx.config, t.info, ndTypeArgCount, cn & "<" & tps.join(", ") & ">", $tps.len)
    elif ctx.scope.classes[cn].decl != nil:
      for w in ctx.scope.classes[cn].decl.constraints:
        let i = tps.find(w.name)
        if i < 0 or i >= t.sons.len: continue
        let arg = t.sons[i]
        let k = ctx.classifyType(arg)
        let an = canonicalTypeName(declTypeName(arg))
        let isValue = k in {tkInt, tkFloat, tkBool, tkChar} or
          (ctx.scope.classes.hasKey(an) and ctx.scope.classes[an].classKind == ckStruct)
        for c in w.sons:
          if c.kind == nsnIdent and c.name == "class" and isValue:
            nsError(ctx.config, arg.info, ndRefTypeConstraint, typeSpelling(arg), w.name,
                    cn & "<" & tps.join(", ") & ">")
          elif c.kind == nsnIdent and c.name == "struct" and not isValue and
               k in {tkString, tkClass, tkSequence}:
            nsError(ctx.config, arg.info, ndValueTypeConstraint, typeSpelling(arg), w.name,
                    cn & "<" & tps.join(", ") & ">")
  else: discard

proc checkMethodGroup(ctx: NsCheckContext; v, target: NsNode) =
  ## A method group assigned to a delegate must match its parameters (CS0123).
  let sig = delegateSig(ctx.scope, ctx.surface, target)
  if not sig.known or v.typeKind != tkDelegate: return
  let owner = (if v.kind == nsnMember and v.body != nil: canonicalTypeName(v.body.typeName)
               else: ctx.clsName)
  if not ctx.scope.classes.hasKey(owner): return
  let cands = ctx.scope.memberOverloads(owner, v.name)
  if cands.len == 0: return
  for ps in cands:
    if ps.len != sig.params.len: continue
    var ok = true
    for i, p in ps:
      if p == nil or sig.params[i] == nil: continue
      if typeSpelling(p.typ) != typeSpelling(sig.params[i]): ok = false
    if ok: return
  nsError(ctx.config, v.info, ndMethodGroupMismatch, v.name, typeSpelling(target))

proc notConstant(ctx: NsCheckContext; n: NsNode): bool =
  ## True only when `n` certainly is no compile-time constant: it reads a local
  ## or parameter that is not `const`, calls a method, or creates an object.
  if n == nil: return false
  case n.kind
  of nsnIdent:
    result = ctx.types.hasKey(n.name) and not ctx.types[n.name].isConst and
             ctx.types[n.name].name != NsLocalFuncMark
  of nsnCall:
    result = not (n.body != nil and n.body.kind == nsnIdent and n.body.name == "nameof")
  of nsnNew:
    result = true
  of nsnBinary, nsnUnary, nsnTernary, nsnCast:
    result = ctx.notConstant(n.body)
    for x in n.sons:
      if ctx.notConstant(x): result = true
  else: result = false

proc checkLocalDecl(ctx: NsCheckContext; n: NsNode) =
  ## A local's declaration: its type exists (CS0246), its name is not taken in
  ## this scope (CS0128) or an enclosing one (CS0136), and `var` has a value
  ## that has a type (CS0818, CS0815).
  let u = ctx.firstUnknownType(n.typ)
  if u != nil and ctx.clsName.len > 0:
    nsError(ctx.config, u.info, ndNamespaceNotFound, u.name)
  if ctx.types.hasKey(n.name) and ctx.types[n.name].name != NsLocalFuncMark and
     ctx.undo.len > 0:
    var here = false
    for d in ctx.undo[^1]:
      if d[0] == n.name: here = true
    nsError(ctx.config, n.info, (if here: ndDuplicateLocal else: ndLocalShadows), n.name)
  if n.typ != nil and n.typ.kind == nsnTypeName and
     ctx.scope.classes.hasKey(canonicalTypeName(n.typ.name)) and
     ctx.scope.classes[canonicalTypeName(n.typ.name)].isStatic:
    ## A static class has no instances to hold (CS0723).
    nsError(ctx.config, n.typ.info, ndStaticVariable, canonicalTypeName(n.typ.name))
  if n.typ == nil:
    if n.body == nil:
      nsError(ctx.config, n.info, ndVarNeedsInit)
    elif n.body.kind == nsnNull:
      nsError(ctx.config, n.info, ndVarBadInit, "<null>")

proc inferredNumeric(n: NsNode): string =
  ## The C# type of `var x = <n>` when `n` is a number whose type is known: an
  ## unsuffixed literal is the first of `int`, `uint`, `long` that holds it
  ## (§6.4.5.4), and `-5` or `1 + 2` of literals alone are `int`. "" when it is not
  ## known exactly, which leaves the lowering to infer it.
  if n == nil: return ""
  case n.kind
  of nsnIntLit:
    if n.typeName.len > 0: return n.typeName
    if n.intVal >= 0 and n.intVal <= 2147483647: return "int"
    if n.intVal > 0 and n.intVal <= 4294967295'i64: return "uint"
    return "long"
  of nsnUnary:
    if n.name in ["-", "+", "~"] and n.body != nil and n.body.kind == nsnIntLit and
       n.body.typeName.len == 0:
      if n.body.intVal <= 2147483648'i64: return "int"
      return "long"
  of nsnBinary:
    if n.name in ["+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>"] and n.sons.len == 2 and
       inferredNumeric(n.sons[0]) == "int" and inferredNumeric(n.sons[1]) == "int" and
       n.sons[0].kind in {nsnIntLit, nsnUnary, nsnBinary} and
       n.sons[1].kind in {nsnIntLit, nsnUnary, nsnBinary}:
      return "int"
  else: discard
  numName(n)

proc walkDecl(ctx: var NsCheckContext; n: NsNode) =
  ## Resolves a declaration's initialiser, then introduces the local (or the
  ## parameter) in the current scope so later statements see its type. A declared
  ## type makes the initialiser a conversion C# may refuse.
  if n.paramMod == "ref" and n.kind == nsnLocalDecl:
    ctx.walkRefDecl(n)
    return
  ctx.requireUnsafe(n.typ, n.info)
  ctx.checkLibraryInterfaceValue(n.typ)
  if n.kind == nsnLocalDecl:
    ctx.checkLocalDecl(n)
  var kind = ctx.classifyType(n.typ)
  ctx.targetTyped(n.body, n.typ)
  if n.body != nil and n.body.kind == nsnLambda and n.typ != nil:
    ## `Func<int, int> f = x => ...;`: the declared delegate types the lambda.
    let sig = delegateSig(ctx.scope, ctx.surface, n.typ)
    if sig.known and n.body.strVal != "anyParams" and n.body.params.len != sig.params.len:
      ## The lambda takes another number of parameters than its delegate (CS1593).
      nsError(ctx.config, n.body.info, ndLambdaArity, typeSpelling(n.typ), $n.body.params.len)
    applySigDeep(ctx, n.body, sig)
  if n.kind == nsnLocalDecl: ctx.checkTypeArgs(n.typ)
  if n.body != nil:
    let initKind = ctx.walkExpr(n.body)
    if n.kind == nsnLocalDecl and n.typ != nil and n.body.kind in {nsnIdent, nsnMember}:
      ctx.checkMethodGroup(n.body, n.typ)
    if n.typ == nil:
      kind = initKind
      if n.body.kind == nsnTernary and n.body.sons.len == 3:
        ctx.checkTernaryTypes(n.body)
      if n.kind == nsnLocalDecl and n.declKind != dkConst:
        ## `var x = 5;` is an `int`, not the Nim integer the literal would make: the
        ## variable is declared as if the type had been written.
        let inferred = inferredNumeric(n.body)
        if inferred.len > 0 and n.body.typeKind in {tkInt, tkFloat, tkChar}:
          n.typ = nsnTypeName(inferred, n.info)
        elif n.body.typeKind == tkString and n.body.kind != nsnNull:
          n.typ = nsnTypeName("string", n.info)
        elif n.body.typeKind == tkBool:
          n.typ = nsnTypeName("bool", n.info)
    elif n.typ.kind == nsnTupleType and n.body.kind == nsnTupleLit and
         n.typ.sons.len == n.body.sons.len:
      ## `(int, string) t = (1, 2);`: each element converts on its own.
      for i, e in n.body.sons:
        let v = (if e.kind == nsnNamedArg: e.body else: e)
        ctx.checkConvertible(v, ctx.targetOfType(n.typ.sons[i].typ), v.info)
    else:
      ctx.checkConvertible(n.body, ctx.targetOfType(n.typ), n.body.info)
      ctx.coerce(n.body, declTypeName(n.typ), n.body.info, n.typ)
  if n.kind == nsnLocalDecl: ctx.checkValue(n.body)
  if n.kind == nsnLocalDecl and n.typ == nil and n.body != nil and n.body.rtype != nil and
     n.body.rtype.kind == nsnVoidType:
    nsError(ctx.config, n.info, ndVarBadInit, "void")
  ## An inferred local (`var x = ...`) takes its type name from its initialiser,
  ## exactly as a `foreach` variable takes it from the collection it walks.
  if n.kind == nsnLocalDecl and n.declKind == dkConst and ctx.notConstant(n.body):
    nsError(ctx.config, n.body.info, ndNotConstant, n.name)
  ctx.declare(n.name, kind,
              (if n.typ != nil: declTypeName(n.typ) else: canonicalTypeName(n.body.typeName)),
              (if n.typ != nil: n.typ elif n.body != nil: n.body.rtype else: nil))
  if n.kind == nsnLocalDecl and n.declKind == dkConst: ctx.types[n.name].isConst = true

proc enumeratedElement(ctx: NsCheckContext; n: NsNode): NsNode =
  ## The element type `foreach` sees in a collection: an `IEnumerable<T>`'s `T`, or
  ## for a class with a `GetEnumerator` method -- C#'s pattern, which needs no
  ## interface -- what its enumerator's `Current` is. The latter marks the loop,
  ## because it lowers to the enumerator's `MoveNext`/`Current` rather than `items`.
  let coll = n.body
  result = iteratorElement(coll.rtype)
  if result != nil: return
  if coll.rtype != nil and coll.rtype.kind == nsnTypeName and
     not ctx.scope.classes.hasKey(canonicalTypeName(coll.rtype.name)):
    ## A library collection: what the library's `items` for it yields, its type
    ## parameters bound by the collection's (`d.Keys` yields the dictionary's `K`).
    let e = libIterElement(ctx.surface, coll)
    if e != nil: return e
    if coll.rtype.sons.len == 1 and
       ctx.surface.member(coll.typeName, coll.typeKind, "items").name.len > 0:
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
  if n.body != nil and n.body.typeKind in {tkInt, tkFloat, tkBool, tkChar}:
    ## Nothing to enumerate (CS1579).
    nsError(ctx.config, n.body.info, ndNotEnumerable, kindSpelling(n.body))
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
  elif n.typ == nil and n.body.rtype != nil and n.body.rtype.kind == nsnArrayType and
       n.body.rtype.typ != nil:
    ## Over an array a library member returned (`s.Split(',')`).
    elemType = n.body.rtype.typ
    elemKind = ctx.classifyType(elemType)
    elemName = declTypeName(elemType)
  elif n.typ == nil and n.body.rtype != nil and n.body.rtype.kind == nsnTypeName and
       n.body.rtype.sons.len == 1 and n.body.rtype.sons[0] != nil and
       not ctx.scope.classes.hasKey(n.body.rtype.name) and
       ctx.surface.types.hasKey(ctx.surface.nimSpellingOf(n.body.rtype.name)):
    ## Over what a library member returned, a collection of one element type
    ## (`s.Split(',')`, `e.InnerExceptions`): `x` has that type.
    elemType = n.body.rtype.sons[0]
    elemKind = ctx.classifyType(elemType)
    elemName = declTypeName(elemType)
  ctx.pushScope()
  ctx.declare(n.name, elemKind, elemName, elemType)
  if n.name.len > 0: ctx.types[n.name].iterVar = true
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

proc caseKey(p: NsNode): string =
  ## A constant case label's value as text, or "" for any other pattern.
  var c = p
  if c != nil and c.kind == nsnPatConst: c = c.body
  if c == nil: return ""
  case c.kind
  of nsnIntLit, nsnCharLit, nsnBoolLit: $c.intVal
  of nsnStrLit: "\"" & c.strVal & "\""
  of nsnMember:
    if c.body != nil and c.body.kind == nsnIdent: c.body.name & "." & c.name else: ""
  else: ""

proc walkSwitch(ctx: var NsCheckContext; n: NsNode) =
  ## A section's pattern variables are in scope in that section only. A section's
  ## end must be unreachable (CS0163; the last one CS8070), and two sections may
  ## not have one constant label (CS0152).
  discard ctx.walkExpr(n.body)
  var seen: seq[string] = @[]
  for i, sec in n.sons:
    if sec.body != nil and endReachable(sec.body.sons):
      let label = (if sec.name == "default": "default:" else: "case:")
      nsError(ctx.config, sec.info,
              (if i == n.sons.len - 1: ndFallOut else: ndFallThrough), label)
    for lab in sec.sons:
      if lab.kind == nsnCaseLabel and lab.sons.len == 0:
        let k = caseKey(lab.body)
        if k.len > 0:
          if k in seen: nsError(ctx.config, lab.info, ndDuplicateCase, k)
          seen.add k
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

proc returnsRef(ctx: NsCheckContext; call: NsNode): bool =
  ## Whether a call's method returns by `ref`, which makes the call assignable.
  let c = call.body
  if c == nil: return true
  if c.kind == nsnIdent and ctx.types.hasKey(c.name) and ctx.types[c.name].node != nil:
    return ctx.types[c.name].node.paramMod == "ref"
  for _, cls in ctx.scope.classes:
    if cls.decl == nil: continue
    for m in cls.decl.sons:
      if m.kind == nsnMethodDecl and m.name == c.name and m.paramMod == "ref": return true
  false

proc checkAssignable(ctx: NsCheckContext; target: NsNode) =
  ## What is not a variable cannot be assigned (CS0131); a string's characters
  ## are read-only (CS0200).
  if target != nil and target.kind == nsnIdent and ctx.types.hasKey(target.name) and
     ctx.types[target.name].iterVar:
    ## A `foreach` variable is read-only (CS1656).
    nsError(ctx.config, target.info, ndIterVarAssign, target.name, "foreach iteration variable")
    return
  if target != nil:
    case target.kind
    of nsnIndex:
      if target.body != nil and target.body.typeKind == tkString:
        nsError(ctx.config, target.info, ndReadOnlyProperty, "string.this[int]")
        return
    of nsnCall:
      if not ctx.returnsRef(target):
        nsError(ctx.config, target.info, ndNotAssignable)
        return
    of nsnIntLit, nsnStrLit, nsnFloatLit, nsnBoolLit, nsnCharLit, nsnBinary, nsnNull:
      nsError(ctx.config, target.info, ndNotAssignable)
      return
    else: discard
  if target != nil and target.kind == nsnMember and target.body != nil and
     target.body.kind == nsnMember and target.body.body != nil:
    ## `t.Position.x = v` with `Position` a property of a struct type: the getter
    ## gives a copy, so the assignment would be lost (CS1612).
    let inner = target.body
    let io = (if inner.body.kind == nsnThis: ctx.clsName else: inner.body.typeName)
    if io.len > 0 and ctx.scope.classes.hasKey(io):
      let pm = ctx.scope.findMemberInfo(io, inner.name)
      if pm.name.len > 0 and pm.isProperty and pm.typ != nil and pm.typ.kind == nsnTypeName:
        let pt = canonicalTypeName(pm.typ.name)
        if ctx.scope.classes.hasKey(pt) and ctx.scope.classes[pt].classKind == ckStruct:
          nsError(ctx.config, inner.info, ndPropertyValueNotVariable, pm.owner & "." & pm.name)
          return
  if ctx.constBody.len > 0 and target != nil and target.kind == nsnMember and
     target.body != nil and target.body.kind == nsnThis:
    let fm = ctx.scope.findMemberInfo(ctx.clsName, target.name)
    if fm.name.len > 0 and not fm.isStatic and not fm.isMethod:
      nsError(ctx.config, target.info, ndConstFieldWrite, fm.owner & "." & fm.name, ctx.constBody)
      return
  ctx.noteMutation(target)
  if target != nil and target.kind == nsnIndex and target.body != nil and
     target.body.typeKind == tkClass and ctx.scope.classes.hasKey(target.body.typeName):
    ## `r[i] = v` through an indexer whose setter is not accessible here (CS0272):
    ## reported when every indexer taking that many indices has one, since which
    ## overload the arguments pick is Nim's to resolve.
    var anyOk = false
    var blocked = ""
    for c in ctx.scope.chain(target.body.typeName):
      for ix in ctx.scope.classes[c].members:
        if ix.name != NsIndexerName or ix.params.len != target.sons.len: continue
        if ix.setAccess == ix.access or ctx.accessAllowed(ix.owner, ix.setAccess):
          anyOk = true
        elif blocked.len == 0: blocked = ix.owner & ".this[]"
    if blocked.len > 0 and not anyOk:
      nsError(ctx.config, target.info, ndSetterInaccessible, blocked)
    return
  ## A `const` is never assigned (CS0131); a `readonly` field only by its own class's
  ## constructors -- the static one, for a static field (CS0191 / CS0198).
  if target == nil or target.kind != nsnMember or target.body == nil: return
  var m: NsMemberSymbol
  let written = dottedName(target.body)
  if ctx.scope.qualifiedOnly.hasKey(written):
    ## `Tools.Console.Calls = v`: the member of that type, not of a bare `Console`.
    for x in ctx.scope.qualifiedOnly[written].members:
      if x.name == target.name: m = x
  else:
    var owner = ""
    if target.body.kind == nsnThis: owner = ctx.clsName
    elif target.body.typeKind == tkType: owner = target.body.typeName
    elif target.body.typeKind == tkClass: owner = target.body.typeName
    if owner.len == 0 or not ctx.scope.classes.hasKey(owner): return
    m = ctx.scope.findMemberInfo(owner, target.name)
  if m.name.len == 0: return
  let inOwnCtor = ctx.inCtor and m.owner == ctx.clsName and not ctx.ctorIsStatic
  let inInitializer = target.body.kind == nsnIdent and target.body.name.startsWith("nsInit")
  if m.isProperty and m.noSetter and not (m.autoGetOnly and inOwnCtor):
    nsError(ctx.config, target.info, ndReadOnlyProperty, m.owner & "." & m.name)
    return
  if m.isProperty and m.initOnly and not (inOwnCtor or inInitializer):
    nsError(ctx.config, target.info, ndInitOnly, m.owner & "." & m.name)
    return
  if m.isProperty and not m.noSetter and m.setAccess != m.access and
     not ctx.accessAllowed(m.owner, m.setAccess):
    nsError(ctx.config, target.info, ndSetterInaccessible, m.owner & "." & m.name)
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
  of nsnBlockStmt:
    ## `unsafe { }` makes its text an unsafe context.
    let saved = ctx.inUnsafe
    if n.strVal == "unsafe": ctx.inUnsafe = true
    ctx.walkInScope(n.sons)
    ctx.inUnsafe = saved
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
    let savedUnsafe = ctx.inUnsafe
    if n.attrs.isUnsafe: ctx.inUnsafe = true
    ctx.requireUnsafe(n.typ, n.info)
    defer: ctx.inUnsafe = savedUnsafe
    let savedRet = ctx.retType
    let savedTps = ctx.typeParams
    for t in n.typeParams: ctx.typeParams.add t.name
    ctx.retType = n.typ
    ctx.checkBodyFlow(n.body, n.typ, n.name, n.info)
    let savedHost = ctx.yieldHost
    let savedIter = ctx.inIterator
    let savedLambda = ctx.lambdaDepth
    ctx.inIterator = hasYieldStmt(n.body)
    ctx.lambdaDepth = 0
    ctx.yieldHost = yhMember
    ctx.pushScope()
    for p in n.params: ctx.walkDecl(p)
    if n.body != nil:
      ctx.walkInScope(n.body.sons)
    checkDefiniteAssignment(ctx.config, n.params, n.body)
    ctx.popScope()
    ctx.yieldHost = savedHost
    ctx.inIterator = savedIter
    ctx.lambdaDepth = savedLambda
    ctx.retType = savedRet
    ctx.typeParams = savedTps
  of nsnExprStmt:
    discard ctx.walkExpr(n.body)
    ## Only a call, an assignment, `++`/`--`, `await` or `new` is a statement
    ## (CS0201); a value computed and dropped is a mistake.
    if n.body != nil and n.body.kind notin {nsnCall, nsnAssign, nsnIncDec, nsnNew,
        nsnNullDot, nsnThrow, nsnEmpty, nsnLambda, nsnRefArg} and n.body.info.line > 0:
      nsError(ctx.config, n.body.info, ndNotAStatement)
  of nsnAssign:
    if n.name.len == 0 and n.sons.len == 2 and n.sons[0].kind == nsnIdent and
       n.sons[0].name == "_" and not ctx.types.hasKey("_") and "_" notin ctx.members:
      ## `_ = e;` evaluates `e` and discards it.
      n.strVal = "discard"
      discard ctx.walkExpr(n.sons[1])
      return
    ctx.assigning = n.name.len == 0
    discard ctx.walkExpr(n.sons[0])
    ctx.assigning = false
    if n.sons.len == 2 and n.sons[1].kind == nsnRefArg and n.sons[0].paramMod == "deref":
      ## `r = ref y;` points the `ref` local at another variable.
      n.strVal = "refAssign"
      discard ctx.walkExpr(n.sons[1])
      return
    if n.sons.len > 1: ctx.targetTyped(n.sons[1], n.sons[0].rtype)
    if n.sons.len > 1 and n.sons[1] != nil and n.sons[1].kind == nsnLambda:
      ## `f = x => ...;`: the target's delegate type types the lambda.
      applySigDeep(ctx, n.sons[1], delegateSig(ctx.scope, ctx.surface, n.sons[0].rtype))
    for i in 1 ..< n.sons.len: discard ctx.walkExpr(n.sons[i])
    ctx.checkAssignable(n.sons[0])
    if n.name.len > 0: ctx.checkQualifiedOnlyUpdate(n.sons[0])
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
        ## A literal into a user type names the type, which may convert from it.
        let target = (if numName(n.sons[0]).len == 0 and
                         (n.sons[0].typeKind == tkClass or
                          ctx.scope.enums.contains(canonicalTypeName(n.sons[0].typeName))) and
                         (isConstantLit(n.sons[1]) or n.sons[1].kind == nsnFloatLit):
                        canonicalTypeName(n.sons[0].typeName)
                      else: numName(n.sons[0]))
        ctx.coerce(n.sons[1], target, n.info, n.sons[0].rtype)
    elif n.sons.len == 2 and n.name in ["+", "-", "*", "/", "mod", "and", "or", "xor",
                                        "shl", "shr", "ushr"]:
      ## `x op= y` is `x = (T)(x op y)`: the operands are promoted as for `x op y`,
      ## and the result is cast back to `x`'s type, which C# does implicitly here.
      let ln = numName(n.sons[0])
      let rn = numName(n.sons[1])
      if ln.len > 0 and n.name == "+" and n.sons[1].typeKind == tkString:
        ## `n += "s"` concatenates to a string, which does not narrow back.
        nsError(ctx.config, n.sons[1].info, ndCannotConvert, "string", ln)
      if ln.len > 0 and rn.len > 0 and n.sons[0].typeKind != tkNullable:
        let p = (if n.name in ["shl", "shr", "ushr"]: unaryPromoted(ln)
                 else: promoted(ln, rn))
        if p.len > 0:
          if n.name notin ["shl", "shr", "ushr"]: needConv(n.sons[1], p)
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
    if n.kind == nsnReturn and ctx.lambdaDepth == 0 and not ctx.inIterator and
       (n.body == nil or n.body.kind != nsnRefArg):
      let isVoid = ctx.retType == nil or ctx.retType.kind == nsnVoidType
      let what = (if ctx.curMember != nil: ctx.clsName & "." & ctx.curMember.name else: "")
      if n.body != nil and isVoid:
        nsError(ctx.config, n.info, ndReturnInVoid, what)
      elif n.body == nil and not isVoid:
        nsError(ctx.config, n.info, ndReturnNeedsValue, typeSpelling(ctx.retType))
    if n.body != nil:
      if n.kind == nsnReturn: ctx.targetTyped(n.body, ctx.retType)
      if n.kind == nsnReturn and n.body.kind == nsnLambda and ctx.retType != nil:
        ## `return x => ...` takes the declared delegate's signature.
        ctx.applySigDeep(n.body, delegateSig(ctx.scope, ctx.surface, ctx.retType))
      discard ctx.walkExpr(n.body)
      if n.kind == nsnReturn:
        ## The declared return type is the conversion C# applies to `return`.
        if ctx.retType != nil:
          ctx.checkConvertible(n.body, ctx.targetOfType(ctx.retType), n.body.info)
          if ctx.retType.kind != nsnNullableType:
            ctx.coerce(n.body, declTypeName(ctx.retType), n.body.info, ctx.retType)
          else:
            ctx.nullableValue(n.body, ctx.retType)
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

proc walkMemberDeclIn(ctx: var NsCheckContext; m: NsNode)

proc walkMemberDecl(ctx: var NsCheckContext; m: NsNode) =
  ## An `unsafe` member is an unsafe context; a pointer in a signature needs one.
  let saved = ctx.inUnsafe
  if m.attrs.isUnsafe: ctx.inUnsafe = true
  if m.kind in {nsnFieldDecl, nsnPropertyDecl, nsnMethodDecl, nsnIndexerDecl,
                nsnOperatorDecl, nsnCtorDecl}:
    ctx.requireUnsafe(m.typ, m.info)
    if m.kind != nsnPropertyDecl:
      for p in m.params:
        if p != nil and p.kind == nsnParam: ctx.requireUnsafe(p.typ, p.info)
  ctx.walkMemberDeclIn(m)
  ctx.inUnsafe = saved

proc walkMemberDeclIn(ctx: var NsCheckContext; m: NsNode) =
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
    ctx.checkBodyFlow(m.body, m.typ, ctx.clsName & ".operator " & m.name, m.info)
    ctx.isStaticCtx = true
    ctx.pushScope()
    for p in m.params: ctx.walkDecl(p)
    if m.body != nil:
      ctx.walkInScope(m.body.sons)
    checkDefiniteAssignment(ctx.config, m.params, m.body)
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
    ctx.checkBodyFlow(m.body, m.typ, ctx.clsName & "." & m.name, m.info)
    let savedIter = ctx.inIterator
    ctx.inIterator = hasYieldStmt(m.body)
    let savedConst = ctx.constBody
    ## A member function C++ sees as `const` (the override of a const one, or
    ## `readonly`) cannot change its object.
    ctx.constBody =
      if not m.attrs.isStatic and ctx.scope.classes.hasKey(ctx.clsName) and
         ctx.scope.nativeBased(ctx.clsName) and not ctx.scope.isNative(ctx.clsName) and
         ctx.scope.constMember(ctx.clsName, m.name): ctx.clsName & "." & m.name
      else: ""
    ctx.pushScope()
    for p in m.params: ctx.walkDecl(p)
    if m.body != nil:
      ctx.walkInScope(m.body.sons)
    checkDefiniteAssignment(ctx.config, m.params, m.body)
    ctx.constBody = savedConst
    ctx.inIterator = savedIter
    ctx.popScope()
    ctx.members = saved
    ctx.retType = savedRet
    ctx.isStaticCtx = savedStatic
    ctx.typeParams = savedTps
  of nsnCtorDecl:
    let savedRet = ctx.retType
    ctx.retType = nil
    ctx.inIterator = false
    ctx.checkBodyFlow(m.body, nil, ctx.clsName, m.info)
    ctx.inCtor = true
    ctx.ctorIsStatic = m.attrs.isStatic
    ctx.isStaticCtx = m.attrs.isStatic
    ctx.pushScope()
    for p in m.params: ctx.walkDecl(p)
    for a in m.initArgs: discard ctx.walkExpr(a)
    if m.initKind == "base" and m.initArgs.len > 0 and not m.attrs.isStatic:
      let cls = ctx.scope.classes.getOrDefault(ctx.clsName)
      if cls.decl != nil and cls.decl.typ != nil and ctx.scope.nativeBased(ctx.clsName) and
         not ctx.scope.isNative(ctx.clsName):
        ## `: base(args)` in a class deriving a native one: the base's constructors
        ## take them, in the C++ constructor's initializer list.
        let b = canonicalTypeName(cls.decl.typ.name)
        ctx.checkCallArgs(ctx.scope.ctorOverloads(b), m.initArgs, b, b, true, m.info)
        for a in m.initArgs:
          let v = (if a.kind == nsnNamedArg: a.body else: a)
          let pt = (if a.argParam != nil and a.argParam.typ != nil and
                       a.argParam.typ.kind == nsnTypeName: canonicalTypeName(a.argParam.typ.name)
                    else: "")
          if pt == "string" and v.kind notin {nsnStrLit, nsnIdent}:
            nsError(ctx.config, v.info, ndUnsupported,
                    "a computed string argument to a native base constructor")
    if m.body != nil:
      ctx.walkInScope(m.body.sons)
    checkDefiniteAssignment(ctx.config, m.params, m.body)
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
      ctx.retType = (if i == 1 or m.attrs.isEvent: nil else: m.typ)
      ctx.checkBodyFlow(acc, ctx.retType, ctx.clsName & "." & m.name & ".get", acc.info)
      ctx.inIterator = i == 0 and hasYieldStmt(acc)
      if i == 1 or m.attrs.isEvent:
        ctx.declare("value", ctx.classifyType(m.typ), declTypeName(m.typ), m.typ)
      ctx.walkInScope(acc.sons)
      checkDefiniteAssignment(ctx.config, @[], acc)
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
        applySigDeep(ctx, m.body, delegateSig(ctx.scope, ctx.surface, m.typ))
      discard ctx.walkExpr(m.body)
      ctx.checkConvertible(m.body, ctx.targetOfType(m.typ), m.body.info)
      ctx.coerce(m.body, declTypeName(m.typ), m.body.info, m.typ)
      ctx.isStaticCtx = false
    elif m.attrs.isConst:
      nsError(ctx.config, m.info, ndConstNeedsValue)
  else: discard

proc checkDuplicates(ctx: NsCheckContext; cls: NsNode) =
  ## A name a type declares twice: a field, property or event (CS0102), or a
  ## method or constructor with the same parameter types (CS0111).
  var names: seq[string] = @[]
  var sigs: seq[string] = @[]
  var members: seq[NsNode] = @[]
  for m in cls.sons:
    if m.kind == nsnMultiDecl: members.add m.sons else: members.add m
  for m in members:
    if m.explicitIface.len > 0 or m.name.len == 0: continue
    case m.kind
    of nsnMethodDecl, nsnCtorDecl:
      var sig = (if m.kind == nsnCtorDecl: (if m.attrs.isStatic: ".cctor" else: ".ctor")
                 else: m.name) & "("
      for p in m.params: sig.add typeSpelling(p.typ) & ","
      if sig in sigs:
        nsError(ctx.config, m.info, ndDuplicateMethod, cls.name, m.name)
      sigs.add sig
      if m.kind == nsnMethodDecl and m.name in names:
        nsError(ctx.config, m.info, ndDuplicateMember, cls.name, m.name)
    of nsnFieldDecl, nsnPropertyDecl:
      if m.name in names:
        nsError(ctx.config, m.info, ndDuplicateMember, cls.name, m.name)
      for s in sigs:
        if s.startsWith(m.name & "("):
          nsError(ctx.config, m.info, ndDuplicateMember, cls.name, m.name)
      names.add m.name
    else: discard

proc checkNative(ctx: NsCheckContext; cls: NsNode) =
  ## What a `[Native]` binding and a class deriving a native one may contain. A rule
  ## of the native model has its own code (NS99xx); what N# may support later is
  ## NS9999. Nothing is dropped.
  let native = ctx.scope.isNative(cls.name)
  let based = not native and ctx.scope.nativeBased(cls.name)
  proc unsupported(m: NsNode; what: string) =
    nsError(ctx.config, m.info, ndUnsupported, what)
  proc named(m: NsNode): string =
    (if m.kind == nsnCtorDecl: cls.name & "." & cls.name else: cls.name & "." & m.name)
  let layout = cls.attributeNamed("StructLayout")
  if layout != nil:
    ## A layout N# does not give the struct's C mirror is NS9999, not ignored.
    for x in layout.sons:
      if x.kind == nsnMember and x.name in ["Explicit", "Auto"]:
        unsupported(cls, "'LayoutKind." & x.name & "'")
      elif x.kind == nsnNamedArg and x.name == "Pack" and x.body != nil and
           not (x.body.kind == nsnIntLit and x.body.intVal in [0, 1, 8]):
        unsupported(cls, "'Pack' other than 1 or 8")
      elif x.kind == nsnNamedArg and x.name in ["Size", "CharSet"]:
        unsupported(cls, "'" & x.name & "' on a StructLayout")
  for m in cls.sons:
    let a = m.attributeNamed("Export")
    if a != nil and (m.kind != nsnMethodDecl or not m.attrs.isStatic or
                     m.typeParams.len > 0):
      nsError(ctx.config, m.info, ndExportMisplaced, named(m))
    if m.hasAttribute("DllImport"):
      ## P/Invoke: a C function, whatever class declares it.
      if m.kind != nsnMethodDecl or not m.attrs.isStatic or not m.attrs.isExtern:
        nsError(ctx.config, m.info, ndDllImportNotStaticExtern)
      elif m.typeParams.len > 0 or cls.typeParams.len > 0:
        nsError(ctx.config, m.info, ndDllImportGeneric)
      else:
        ## What N# would otherwise ignore, getting the bytes wrong.
        for x in m.attributeNamed("DllImport").sons:
          if x.kind == nsnNamedArg and x.body != nil and x.body.kind == nsnMember and
             ((x.name == "CharSet" and x.body.name in ["Unicode", "Auto"]) or
              (x.name == "CallingConvention" and x.body.name in ["ThisCall", "FastCall"])):
            unsupported(m, "'" & x.name & " = " & x.body.name & "' on a P/Invoke")
          elif x.kind == nsnNamedArg and x.name in ["SetLastError", "PreserveSig",
                                                    "BestFitMapping", "ThrowOnUnmappableChar"]:
            unsupported(m, "'" & x.name & "' on a P/Invoke")
        var attrs = m.attributes
        for p in m.params: attrs.add p.attributes
        for a in attrs:
          if a.name.split('.')[^1] in ["MarshalAs", "MarshalAsAttribute"]:
            for x in a.sons:
              if x.kind == nsnMember and x.name notin ["U1", "I1", "Bool", "LPStr", "LPUTF8Str"]:
                unsupported(m, "'MarshalAs(UnmanagedType." & x.name & ")'")
        if ctx.scope.marshalOf(m.typ) == mkUnsupported or
           ctx.scope.marshalOf(m.typ) == mkArray:
          unsupported(m, "a P/Invoke result of type '" & declTypeName(m.typ) & "'")
        for p in m.params:
          let mk = ctx.scope.marshalOf(p.typ)
          if mk == mkUnsupported or (mk in {mkString, mkArray} and p.paramMod != "") or
             p.paramMod in ["params", "in", "this"]:
            unsupported(p, "a P/Invoke parameter '" & p.name & "' of type '" &
                           declTypeName(p.typ) & "'" &
                           (if p.paramMod.len > 0: " passed '" & p.paramMod & "'" else: ""))
    elif m.attrs.isExtern and not native:
      nsError(ctx.config, m.info, ndExternOutsideNative, named(m))
    var borrowed, owned = false
    for a in m.attributes:
      if a.strVal == "return":
        let short = a.name.split('.')[^1]
        if short in ["Borrowed", "BorrowedAttribute"]: borrowed = true
        if short in ["Owned", "OwnedAttribute"]: owned = true
    if m.attributes.len > 0:
      for a in m.attributes:
        if a.strVal == "return" and a.name.split('.')[^1] in ["CString", "CStringAttribute"]:
          let rt = (if m.typ != nil and m.typ.kind == nsnTypeName: canonicalTypeName(m.typ.name)
                    else: "")
          var reach = false
          for x in a.sons:
            if x.kind == nsnStrLit: reach = true
          if m.kind != nsnMethodDecl or not m.attrs.isExtern or rt != "string" or not reach:
            nsError(ctx.config, a.info, ndCStringMisplaced, named(m))
    if m.kind in {nsnMethodDecl, nsnCtorDecl, nsnOperatorDecl, nsnPropertyDecl}:
      for p in m.params:
        if p == nil or p.kind != nsnParam: continue
        let a = p.attributeNamed("CString")
        if a == nil: continue
        var reach = false
        for x in a.sons:
          if x.kind == nsnStrLit: reach = true
        let pt = (if p.typ != nil and p.typ.kind == nsnTypeName: canonicalTypeName(p.typ.name)
                  else: "")
        if m.kind != nsnMethodDecl or not m.attrs.isExtern or pt != "string" or
           p.paramMod.len > 0 or not reach:
          nsError(ctx.config, a.info, ndCStringMisplaced, named(m))
    ## The class a method returns: its own type, or the class a type parameter it
    ## returns is constrained to (`T Create<T>() where T : Palette`).
    var rt = (if m.typ != nil and m.typ.kind == nsnTypeName: canonicalTypeName(m.typ.name)
              else: "")
    if m.typ != nil and m.typ.kind == nsnTypeName:
      for w in m.constraints:
        if w.name == m.typ.name:
          for c in w.sons:
            if c.kind == nsnTypeName and ctx.scope.classes.hasKey(canonicalTypeName(c.name)):
              rt = canonicalTypeName(c.name)
    let ownedRt = rt.len > 0 and ctx.scope.classes.hasKey(rt) and ctx.scope.ownedFamily(rt)
    if borrowed or owned:
      if m.kind != nsnMethodDecl or not m.attrs.isExtern or (borrowed and owned) or not ownedRt:
        nsError(ctx.config, m.info, ndReturnOwnership, named(m))
    if m.kind == nsnMethodDecl and m.attrs.isExtern and m.params.len > 0 and
       m.params[^1] != nil and m.params[^1].attributeNamed("Forward") != nil and ownedRt:
      if not borrowed and not owned:
        unsupported(m, "a [Forward] factory returning a native class with no handle by value" &
                       " (say [return: Owned] or [return: Borrowed])")
    if m.attributeNamed("OnHandle") != nil:
      var ok = m.kind in {nsnMethodDecl, nsnPropertyDecl} and m.attrs.isExtern and
               not m.attrs.isStatic and native and cls.classKind == ckClass and
               ctx.scope.engineOwned(cls.name)
      for o in cls.sons:
        if o != m and o.kind == m.kind and o.name == m.name and
           o.attributeNamed("OnHandle") == nil:
          ok = false
      if not ok: nsError(ctx.config, m.info, ndOnHandleMisplaced, named(m))
    if m.kind in {nsnMethodDecl, nsnCtorDecl, nsnOperatorDecl}:
      for i, p in m.params:
        if p == nil or p.attributeNamed("Forward") == nil: continue
        if m.kind != nsnMethodDecl or not m.attrs.isExtern or m.typeParams.len == 0 or
           i != m.params.len - 1 or p.paramMod != "params" or p.typ == nil or
           p.typ.kind != nsnArrayType or p.typ.typ == nil or
           canonicalTypeName(declTypeName(p.typ.typ)) != "object":
          nsError(ctx.config, p.info, ndForwardMisplaced, named(m))
  if native:
    if cls.typ != nil and not ctx.scope.isNative(canonicalTypeName(cls.typ.name)):
      nsError(ctx.config, cls.info, ndNativeBaseNotNative, cls.name,
              canonicalTypeName(cls.typ.name))
    for m in cls.sons:
      case m.kind
      of nsnFieldDecl:
        ## A `const` is the binding's own, checked against C++'s (`static_assert`).
        if (m.attrs.isStatic or m.body != nil) and not m.attrs.isConst:
          nsError(ctx.config, m.info, ndNativeFieldStatic, named(m))
        elif cls.classKind == ckStruct and m.typ != nil and m.typ.kind == nsnTypeName and
             m.typ.sons.len == 0 and ctx.scope.classes.hasKey(canonicalTypeName(m.typ.name)) and
             ctx.scope.classes[canonicalTypeName(m.typ.name)].classKind == ckClass and
             ctx.scope.isNative(canonicalTypeName(m.typ.name)) and
             ctx.scope.ownedFamily(canonicalTypeName(m.typ.name)):
          ## A struct is copied, so an object in it would be lent from a copy.
          nsError(ctx.config, m.info, ndUnsupported,
                  "'" & named(m) & "': a field of a native class in a [Native] struct")
      of nsnMethodDecl, nsnCtorDecl, nsnOperatorDecl:
        if not m.attrs.isExtern or m.body != nil:
          nsError(ctx.config, m.info, ndNativeMemberNotExtern, named(m))
      of nsnIndexerDecl:
        ## `extern T this[...]`: each accessor is the C++ it names, never guessed.
        let pn = nativeOf(m)
        let getter = (if m.sons.len > 0: m.sons[0] else: nil)
        let setter = (if m.sons.len > 1: m.sons[1] else: nil)
        if not m.attrs.isExtern or (getter != nil and getter.kind != nsnEmpty) or
           (setter != nil and setter.kind != nsnEmpty):
          nsError(ctx.config, m.info, ndNativeMemberNotExtern, cls.name & ".this[]")
        else:
          if getter != nil and pn.get.len == 0:
            nsError(ctx.config, m.info, ndNativeAccessorUnnamed, cls.name & ".this[]", "getter")
          if setter != nil and pn.set.len == 0:
            nsError(ctx.config, m.info, ndNativeAccessorUnnamed, cls.name & ".this[]", "setter")
      of nsnPropertyDecl:
        ## Each accessor is the C++ its `[Native(Get = .., Set = ..)]` names; a
        ## static one with neither is the type's static member.
        let pn = nativeOf(m)
        let getter = (if m.params.len > 0: m.params[0] else: nil)
        let setter = (if m.params.len > 1: m.params[1] else: nil)
        if not m.attrs.isExtern or (getter != nil and getter.kind != nsnEmpty) or
           (setter != nil and setter.kind != nsnEmpty):
          nsError(ctx.config, m.info, ndNativeMemberNotExtern, named(m))
        elif not m.attrs.isStatic or pn.get.len > 0 or pn.set.len > 0:
          if getter != nil and pn.get.len == 0:
            nsError(ctx.config, m.info, ndNativeAccessorUnnamed, named(m), "getter")
          if setter != nil and pn.set.len == 0:
            nsError(ctx.config, m.info, ndNativeAccessorUnnamed, named(m), "setter")
        let pt = (if m.typ != nil and m.typ.kind == nsnTypeName: canonicalTypeName(m.typ.name)
                  else: "")
        if getter != nil:
          ## The getter's own `[return: ...]`: as on a method returning the type.
          for a in getter.attributes:
            let short = a.name.split('.')[^1]
            if a.strVal != "return": continue
            if short in ["CString", "CStringAttribute"] and pt != "string":
              nsError(ctx.config, a.info, ndCStringMisplaced, named(m))
            if short in ["Borrowed", "BorrowedAttribute", "Owned", "OwnedAttribute"] and
               not (ctx.scope.classes.hasKey(pt) and ctx.scope.ownedFamily(pt)):
              nsError(ctx.config, a.info, ndReturnOwnership, named(m))
      else:
        unsupported(m, "this member in a '[Native]' type")
  elif based:
    if cls.classKind != ckClass:
      unsupported(cls, "a struct deriving a native type")
    if cls.typeParams.len > 0:
      unsupported(cls, "a generic class deriving a native one")
    for m in cls.sons:
      case m.kind
      of nsnFieldDecl:
        discard   ## any type: a Nim-managed one is held as an `NsField` (desugar)
      of nsnMethodDecl:
        if m.typeParams.len > 0 and not m.attrs.isStatic:
          unsupported(m, "a generic method in a class deriving a native one")
      of nsnCtorDecl:
        ## A C++ constructor, which the engine runs when it creates the object
        ## through a `[Forward]` factory.
        if m.initKind == "this":
          unsupported(m, "': this(...)' on a constructor of a class deriving a native one")
      else:
        unsupported(m, "this member in a class deriving a native one")

proc checkSupported(ctx: NsCheckContext; cls: NsNode) =
  ## Features the frontend can parse but does not lower are rejected loudly
  ## rather than dropped silently; ignoring `interface` or `override` produced
  ## programs that looked like they worked.
  ctx.checkDuplicates(cls)
  ctx.checkNative(cls)
  for m in cls.sons:
    if m.kind in {nsnMethodDecl, nsnCtorDecl, nsnOperatorDecl, nsnIndexerDecl}:
      ## Two parameters of one name (CS0100).
      var seen: seq[string] = @[]
      for p in m.params:
        if p == nil or p.name.len == 0: continue
        if p.name in seen: nsError(ctx.config, p.info, ndDuplicateParam, p.name)
        seen.add p.name
    if m.kind == nsnCtorDecl and m.attrs.isStatic and m.params.len > 0:
      nsError(ctx.config, m.info, ndStaticCtorParams,
              signature(cls.name & "." & cls.name, m.params))
  if ctx.scope.classes.hasKey(cls.name):
    ## A class derives from one class (CS1721); a struct or an interface from none
    ## (CS0527): the rest of a base list are interfaces.
    var classBases: seq[string] = @[]
    for w in ctx.scope.classes[cls.name].written:
      let b = canonicalTypeName(w)
      if b != cls.name and ctx.scope.classes.hasKey(b) and
         ctx.scope.classes[b].classKind == ckClass:
        classBases.add b
    if cls.classKind == ckClass and classBases.len >= 2:
      nsError(ctx.config, cls.info, ndMultipleBases, cls.name, classBases[0], classBases[1])
    elif cls.classKind in {ckStruct, ckInterface} and classBases.len > 0:
      nsError(ctx.config, cls.info, ndNotInterface, classBases[0])
  for m in cls.sons:
    if m.kind == nsnOperatorDecl and m.name in ["true", "false"]:
      nsError(ctx.config, m.info, ndUnsupported, "'operator " & m.name & "'")

proc signatureOf(cls: string; m: NsNode): string =
  ## `Shape.Area()`, as C# names a member in a diagnostic.
  result = cls & "." & m.name
  if m.kind == nsnMethodDecl: result = signature(result, m.params)

proc sameParams(a, b: seq[NsNode]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i] == nil or b[i] == nil: return true
    if a[i].paramMod != b[i].paramMod or typeSpelling(a[i].typ) != typeSpelling(b[i].typ):
      return false
  true

proc baseHasParams(ctx: NsCheckContext; cls: string; m: NsNode): bool =
  ## Whether a base class declares a method `m.name` taking `m`'s parameters. A
  ## generic base, or a chain that leaves this compilation, is taken on trust.
  let ch = ctx.scope.chain(cls)
  if ch.len == 0 or ctx.scope.classes[ch[^1]].base.len > 0: return true
  for i in 1 ..< ch.len:
    let c = ctx.scope.classes[ch[i]]
    if c.typeParams.len > 0: return true
    for bm in c.members:
      if bm.name == m.name and bm.isMethod and sameParams(bm.params, m.params): return true
  false

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
      elif m.kind == nsnMethodDecl and not ctx.baseHasParams(cls.name, m):
        ## A slot of that name, but none taking these parameters (CS0115).
        nsError(ctx.config, m.info, ndNoOverrideSlot, signatureOf(cls.name, m))
    if a.isAbstract and not cls.attrs.isAbstract:
      nsError(ctx.config, m.info, ndAbstractInConcrete, signatureOf(cls.name, m),
              cls.name)
    if m.kind == nsnMethodDecl:
      if a.isAbstract and m.body != nil:
        nsError(ctx.config, m.info, ndAbstractHasBody, signatureOf(cls.name, m))
      elif not a.isAbstract and not a.isExtern and m.body == nil:
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
      var impl = NsMemberSymbol()
      for c in ctx.scope.chain(cls.name):
        for m in ctx.scope.classes[c].members:
          ## A static abstract member is implemented by a static one.
          if m.name == im.name and m.isStatic == im.isStatic:
            found = true
            if m.isMethod and sameParams(m.params, im.params): impl = m
        if found: break
      if impl.name.len > 0 and im.isMethod and impl.typ != nil and im.typ != nil and
         ctx.scope.classes[i].typeParams.len == 0 and
         typeSpelling(impl.typ) != typeSpelling(im.typ):
        ## An implicit implementation returns the interface's type (CS0738),
        ## unless an explicit one stands in for it.
        var explicit = false
        for m in cls.sons:
          if m.name == im.name and m.explicitIface.len > 0: explicit = true
        if not explicit:
          nsError(ctx.config, cls.info, ndIfaceReturn, cls.name,
                  signature(i & "." & im.name, im.params),
                  signature(impl.owner & "." & impl.name, impl.params), typeSpelling(im.typ))
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
  let savedUnsafe = ctx.inUnsafe
  if cls.attrs.isUnsafe: ctx.inUnsafe = true
  for m in cls.sons: ctx.walkMemberDecl(m)
  ctx.inUnsafe = savedUnsafe
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
  of nsnEnumDecl:
    ## Two members of one name (CS0102).
    var seen: seq[string] = @[]
    for f in d.sons:
      if f.name in seen: nsError(ctx.config, f.info, ndDuplicateMember, d.name, f.name)
      seen.add f.name
  of nsnDelegateDecl:
    ## `delegate void D(int* p);` needs an unsafe context of its own.
    if not d.attrs.isUnsafe:
      ctx.requireUnsafe(d.typ, d.info)
      for p in d.params: ctx.requireUnsafe(p.typ, p.info)
  of nsnUsing: discard
  else: ctx.walkStmt(d)

proc checkDuplicateTypes(list: seq[NsNode]; config: ConfigRef; ns: string) =
  ## Two types of one name and arity in one namespace block, neither `partial`
  ## (CS0101).
  var seen: seq[string] = @[]
  for d in list:
    if d.kind == nsnNamespace and d.body != nil:
      checkDuplicateTypes(d.body.sons, config, d.name)
    elif d.kind in {nsnClassDecl, nsnEnumDecl, nsnDelegateDecl} and d.name.len > 0 and
         not d.attrs.isPartial:
      let key = d.name & "`" & $d.typeParams.len
      if key in seen:
        nsError(config, d.info, ndDuplicateType, ns, d.name)
      seen.add key

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

proc markOverlappingDefaults(scope: NsModuleScope) =
  ## Nim cannot tell `Q(int a, int b = 0)` from `Q(int a)` for `Q(1)`, where C#
  ## takes the one without defaults (12.6.4.3). Where an overload's defaults let it
  ## take an argument count another overload of the same name takes, its defaulted
  ## parameters are declared without them and each call passes them (`noDefault`).
  proc arity(ps: seq[NsNode]): tuple[req, total: int, open: bool] =
    result = (req: 0, total: 0, open: false)
    for p in ps:
      if p == nil: continue
      if p.paramMod == "params": result.open = true
      elif p.body == nil: inc result.req
      inc result.total
  proc mark(group: seq[seq[NsNode]]) =
    for a in group:
      let ra = arity(a)
      if ra.req == ra.total or ra.open: continue
      for b in group:
        if b == a: continue
        let rb = arity(b)
        let hi = (if rb.open: high(int) else: rb.total)
        if max(ra.req, rb.req) <= min(ra.total - 1, hi):
          for p in a:
            if p != nil and p.body != nil: p.noDefault = true
          break
  for cls in scope.classes.values:
    var byName = initTable[string, seq[seq[NsNode]]]()
    for m in cls.members:
      if m.isMethod: byName.mgetOrPut(m.name, @[]).add m.params
    for g in byName.values:
      if g.len > 1: mark(g)
    if cls.ctorParams.len > 1: mark(cls.ctorParams)

proc checkModule*(module: NsNode; scope: NsModuleScope; config: ConfigRef) =
  ## Resolves names, enforces access control, checks the conversions and applies the
  ## base-constructor rule. Diagnostics go through `config`.
  var ctx = NsCheckContext(scope: scope, config: config,
                           surface: bclSurface(config),
                           types: newTable[string, NsTypeInfo](),
                           unsafeReported: new(HashSet[string]))
  var fileTypes = initTable[string, FileIndex]()
  collectFileTypes(module.sons, config, fileTypes)
  if fileTypes.len > 0:
    for d in module.sons: checkFileTypeUses(d, config, fileTypes)
  checkDuplicateTypes(module.sons, config, "<global namespace>")
  markOverlappingDefaults(scope)
  ## The namespaces whose library types are in scope: each `using`, and each
  ## namespace the file declares with every enclosing one (`A.B` sees `A`'s).
  proc noteNamespaces(ns: seq[NsNode]; into: var HashSet[string]; outer: string) =
    for d in ns:
      if d == nil: continue
      if d.kind == nsnUsing and d.alias.len == 0: into.incl d.name
      elif d.kind == nsnNamespace:
        let full = (if outer.len > 0: outer & "." & d.name else: d.name)
        var parts = full.split('.')
        for k in 1 .. parts.len: into.incl parts[0 ..< k].join(".")
        if d.body != nil: noteNamespaces(d.body.sons, into, full)
  noteNamespaces(module.sons, ctx.usingNamespaces, "")
  for d in module.sons: ctx.walkTop(d)
  ## The anonymous types the walk synthesized, checked as the declarations they
  ## now are; checking one cannot synthesize another.
  for d in ctx.scope.anonDecls:
    ctx.walkTop(d)
    module.add d
  ## After the walk, so every declaration is looked at exactly once: a `MyObj?` on a
  ## reference type is only an annotation, and C# warns about it.
  warnNullableRefs(ctx, module)