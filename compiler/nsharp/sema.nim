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
import ast, bcl, diagnostics, numeric, symbols

type
  NsTypeInfo* = object
    kind*: NsTypeKind
    name*: string              ## the type's name, when it has one
    node*: NsNode              ## the type as written, generic arguments included

  NsCheckContext = object
    scope: NsModuleScope
    config: ConfigRef
    surface: NsBclSurface                       ## what the prelude declares
    clsName: string                            ## enclosing class, "" outside one
    members: seq[string]                       ## names reachable from it
    retType: NsNode                            ## enclosing member's return type
    isStaticCtx: bool                          ## inside a static member: no `this`
    typeParams: seq[string]                    ## the generic parameters in scope
    inCtor: bool                               ## inside a constructor of `clsName`
    ctorIsStatic: bool                         ## ... and it is the static one
    types: TableRef[string, NsTypeInfo]        ## locals, params, loop variables
    undo: seq[seq[(string, NsTypeInfo, bool)]] ## one frame per open scope

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
    t.setType(tkSequence)
    result = tkSequence
  of nsnNullableType:
    let inner = ctx.classifyType(t.typ)
    ## Only a value type needs `Option`: a reference is nullable already, so `Node?`
    ## is just `Node`, as C# reads it.
    result = if inner in {tkInt, tkFloat, tkBool, tkChar}: tkNullable else: inner
    t.setType(result, declTypeName(t.typ))
  of nsnTypeName:
    result = ctx.classifyName(t.name)
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

proc coerce(ctx: NsCheckContext; value: NsNode; target: string; info: TLineInfo) =
  ## The implicit numeric conversion C# applies where a value of one numeric type is
  ## used as another: recorded when C# allows it, CS0266 when only a cast would.
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
  of tkSequence: result = t.kind != tkSequence
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

proc resolveOverload(ctx: NsCheckContext; cands: seq[seq[NsNode]];
                     args: seq[NsNode]): tuple[ok: bool, idx, score: int] =
  ## Picks the overload every argument fits, preferring the one that needs the fewest
  ## conversions, so an exact match beats the `T?` one C# would also have reached.
  result = (ok: false, idx: -1, score: high(int))
  for i in 0 ..< cands.len:
    if cands[i].len != args.len: continue
    var fits = true
    var score = 0
    for j in 0 ..< args.len:
      let pt = if cands[i][j] != nil: cands[i][j].typ else: nil
      if ctx.incompatible(args[j], ctx.targetOfType(pt)):
        fits = false
        break
      if ctx.argConv(args[j], pt) != acNone: inc score
    if fits and score < result.score:
      result = (ok: true, idx: i, score: score)

proc markNull(ctx: NsCheckContext; value: NsNode; target: string) =
  ## `null` for an interface is the empty interface value, which lowering spells
  ## `default(I)`, so the target is recorded on the literal.
  if value != nil and value.kind == nsnNull and ctx.scope.isInterface(target):
    value.setType(tkClass, target)

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
    nsError(ctx.config, info, ndCannotConvert, valueSpelling(value), t.spelling)

proc isTypeParamRef(ctx: NsCheckContext; t: NsNode): bool =
  ## A parameter typed by a type parameter: a bare name no declaration answers for.
  t != nil and t.kind == nsnTypeName and t.sons.len == 0 and '.' notin t.name and
    not ctx.isTypeName(t.name)

proc checkCallArgs(ctx: NsCheckContext; cands: seq[seq[NsNode]];
                   args: seq[NsNode]; displayName, recvName: string;
                   isCtor: bool; info: TLineInfo) =
  ## CS1501 / CS1729 when no overload takes this many arguments, CS7036 when one
  ## takes more, CS1503 when one takes exactly this many but an argument cannot be
  ## converted. A call the scope cannot resolve -- a library method, a name from a
  ## module it does not cover -- has no candidates and is left to Nim.
  if cands.len == 0: return
  let (ok, idx, _) = ctx.resolveOverload(cands, args)
  if ok:
    for j in 0 ..< args.len:
      let pt = if cands[idx][j] != nil: cands[idx][j].typ else: nil
      let conv = ctx.argConv(args[j], pt)
      if conv != acNone:
        ## Lowering applies it, so the argument reaches `some`/`none` spelled with
        ## the element type rather than with the literal's own type.
        args[j].argConv = conv
        args[j].argConvType =
          declTypeName(if pt.kind == nsnNullableType: pt.typ else: pt)
      elif pt != nil:
        ctx.coerce(args[j], declTypeName(pt), args[j].info)
        ctx.markNull(args[j], declTypeName(pt))
        if ctx.isTypeParamRef(pt) and args[j].kind in {nsnIntLit, nsnFloatLit} and
           args[j].typeName.len == 0:
          ## A literal for a type parameter fixes the type argument, and C# types
          ## `3` as `int` where Nim would infer its own `int`.
          args[j].conv = (if args[j].kind == nsnIntLit: "int" else: "double")
    return
  var exact = -1
  for i in 0 ..< cands.len:
    if cands[i].len == args.len: exact = i
  if exact >= 0:
    for j in 0 ..< args.len:
      let pt = if cands[exact][j] != nil: cands[exact][j].typ else: nil
      if ctx.incompatible(args[j], ctx.targetOfType(pt)):
        nsError(ctx.config, args[j].info, ndArgumentCannotConvert,
                $(j + 1), valueSpelling(args[j]), typeSpelling(pt))
        return
    return
  ## No overload takes this many arguments. Roslyn names the one short candidate and
  ## its first missing parameter when there is exactly one -- a constructor with a
  ## single declaration, or a method with no overloads -- and falls back to the arity
  ## message as soon as there is a choice.
  let where = if args.len > 0: args[0].info else: info
  if cands.len == 1 and cands[0].len > args.len:
    let p = cands[0][args.len]
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

proc walkExpr(ctx: var NsCheckContext; n: NsNode): NsTypeKind
proc walkStmt(ctx: var NsCheckContext; n: NsNode)
proc walkBody(ctx: var NsCheckContext; blk: NsNode)

proc staticReceiver(ctx: NsCheckContext; owner: string; info: TLineInfo): NsNode =
  ## `C`, or `C<T>` when `owner` is the generic class being checked.
  result = nsnIdent(owner, info)
  result.setType(tkType, owner)
  if owner == ctx.clsName and ctx.scope.classes.hasKey(owner):
    for t in ctx.scope.classes[owner].typeParams:
      result.typeArgs.add nsnTypeName(t, info)

proc checkTypeTest(ctx: NsCheckContext; n: NsNode) =
  ## `is`, `as` and casts to a generic interface would need the dynamic type to name
  ## its type arguments, which the interface tables do not record yet.
  let t = n.typ
  if t != nil and t.kind == nsnTypeName and t.sons.len > 0 and
     ctx.scope.isInterface(canonicalTypeName(t.name)):
    nsError(ctx.config, n.info, ndUnsupported,
            "a type test or cast to a generic interface")

proc checkLibraryInterfaceValue(ctx: NsCheckContext; t: NsNode) =
  ## A library interface (`IComparable<T>`) is a contract N# checks by name; it has
  ## no table, so it cannot be the type of a value.
  if t != nil and t.kind == nsnTypeName and
     canonicalTypeName(t.name) in ctx.scope.libIfaces and
     not ctx.scope.classes.hasKey(canonicalTypeName(t.name)):
    nsError(ctx.config, t.info, ndUnsupported,
            "a value of the library interface '" & unqualified(t.name) & "'")

proc walkIdent(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  ## A bare name. Inside an instance member body, a name that is a class member
  ## is rewritten in place into `this.name` and then resolved as a member, which
  ## is the behaviour the parse-time rewrite used to have. `value` is exempt: it
  ## is the implicit setter parameter.
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
    if kind != tkDelegate:
      ## A member of a generic class, seen through a receiver whose type arguments
      ## are known, has the substituted type.
      let mt = ctx.memberTypeOf(n.body, n.body.typeName, n.name)
      if mt != nil:
        n.rtype = mt
        let k = ctx.classifyType(mt)
        if k != tkUnknown:
          kind = k
          tname = declTypeName(mt)
  of tkSequence, tkString, tkException, tkNullable:
    kind = ctx.memberKindOfSurface(rk, n.body.typeName, n.name, tname)
  of tkType:
    ## A namespace's member is a type (`System.Console`); a declared type's member
    ## is one of its statics, which the library answers for (`string.Empty`,
    ## `int.MaxValue`, `Array.IndexOf`).
    if n.body != nil:
      let recv = n.body.typeName
      if ctx.scope.classes.hasKey(recv) and
         ctx.scope.findMemberInfo(recv, n.name).name.len > 0:
        ## A static member of a class this compilation declares.
        kind = ctx.memberKind(recv, n.name)
        if ctx.scope.findMemberInfo(recv, n.name).isMethod: kind = tkDelegate
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

proc walkCall(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  var kind = tkUnknown
  var cands: seq[seq[NsNode]] = @[]
  var owner = ""
  var tn = ""
  let callee = n.body
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
    elif rk == tkClass:
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
    ## A member the module declares carries its declared result type name, which
    ## the surrounding `var x = ...` needs to name `x` (`List<int> Items()` makes
    ## `x` a `List`); the surface path has already recorded its own.
    if kind != tkUnknown and tn.len == 0:
      tn = ctx.memberTypeName(owner, callee.name)
    callee.setType(kind)
  elif callee != nil:
    discard ctx.walkExpr(callee)
  for a in n.sons: discard ctx.walkExpr(a)
  n.setType(kind, tn)
  if callee != nil and callee.kind == nsnMember:
    ctx.checkCallArgs(cands, n.sons, callee.name, owner, false, n.info)
  result = kind

proc markCoalesced(n: NsNode) =
  ## `a?.B?.C ?? x` supplies `x` for the absent case of *every* link, so none of them
  ## is a bare value-typed `?.` for the diag in `walkExpr`.
  if n == nil: return
  if n.kind == nsnNullDot: n.intVal = 1
  for s in n.sons: markCoalesced(s)
  markCoalesced(n.body)

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
    for a in n.sons: discard ctx.walkExpr(a)
    n.rtype = n.typ
    let k = ctx.classifyType(n.typ)
    n.setType(k, (if n.typ != nil: n.typ.name else: ""))
    if n.typ != nil and n.typ.kind == nsnTypeName:
      ## `new C(...)`: the constructors of a class the scope knows are checked the
      ## same way a method call's parameter lists are. A BCL type has none here.
      let cn = unqualified(n.typ.name)
      if ctx.scope.classes.hasKey(cn):
        if ctx.scope.classes[cn].isAbstract or
           ctx.scope.classes[cn].classKind == ckInterface:
          nsError(ctx.config, n.info, ndAbstractInstance, cn)
        ctx.checkCallArgs(ctx.scope.ctorOverloads(cn), n.sons, cn, cn, true, n.info)
    result = k
  of nsnNewArray, nsnArrayLit:
    for a in n.sons: discard ctx.walkExpr(a)
    n.setType(tkSequence)
    result = tkSequence
  of nsnIndex:
    discard ctx.walkExpr(n.body)
    for a in n.sons: discard ctx.walkExpr(a)
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
    else:
      n.setType(tkUnknown)
  of nsnUnary:
    result = ctx.walkExpr(n.body)
    n.setType(result)
  of nsnIncDec:
    discard ctx.walkExpr(n.body)
    n.setType(tkInt)
    result = tkInt
  of nsnCast:
    ctx.checkTypeTest(n)
    ## `(T)x` converts, which covers numbers, enums and ref objects. Boxing a value
    ## into `object` is the one case N# cannot express.
    let target = ctx.classifyType(n.typ)
    let operand = ctx.walkExpr(n.body)
    if isObjectTarget(n.typ) and operand in NsValueKinds:
      nsError(ctx.config, n.info, ndUnsupported, "a cast of a value to 'object'")
    n.setType(target)
    result = target
  of nsnIs:
    ctx.checkTypeTest(n)
    discard ctx.walkExpr(n.body)
    ## A value type is tested statically and a class dynamically.
    n.name = if ctx.classifyType(n.typ) in NsValueKinds: "is" else: "of"
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
    result = ctx.classifyType(n.typ)
    n.setType(result)
  of nsnBinary:
    var lk = ctx.walkExpr(n.sons[0])
    var rk = ctx.walkExpr(n.sons[1])
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
    for p in n.params:
      if p.typ != nil: ctx.declare(p.name, ctx.classifyType(p.typ), declTypeName(p.typ),
                                   p.typ)
      else: ctx.declare(p.name, tkUnknown)
    if n.body != nil:
      for s in n.body.sons: ctx.walkStmt(s)
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
  ## A sequence of statements in its own name scope.
  ctx.pushScope()
  for s in stmts: ctx.walkStmt(s)
  ctx.popScope()

proc walkDecl(ctx: var NsCheckContext; n: NsNode) =
  ## Resolves a declaration's initialiser, then introduces the local (or the
  ## parameter) in the current scope so later statements see its type. A declared
  ## type makes the initialiser a conversion C# may refuse.
  ctx.checkLibraryInterfaceValue(n.typ)
  var kind = ctx.classifyType(n.typ)
  if n.body != nil:
    let initKind = ctx.walkExpr(n.body)
    if n.typ == nil: kind = initKind
    else:
      ctx.checkConvertible(n.body, ctx.targetOfType(n.typ), n.body.info)
      ctx.coerce(n.body, declTypeName(n.typ), n.body.info)
  ## An inferred local (`var x = ...`) takes its type name from its initialiser,
  ## exactly as a `foreach` variable takes it from the collection it walks.
  ctx.declare(n.name, kind, (if n.typ != nil: declTypeName(n.typ) else: n.body.typeName),
              (if n.typ != nil: n.typ elif n.body != nil: n.body.rtype else: nil))

proc walkForeach(ctx: var NsCheckContext; n: NsNode) =
  var elemKind = ctx.classifyType(n.typ)
  discard ctx.walkExpr(n.body)
  var elemName = (if n.typ != nil: declTypeName(n.typ) else: n.body.typeName)
  if n.typ == nil and n.body.typeKind == tkSequence and elemName.endsWith("[]"):
    ## `foreach (var x in xs)` over an array: `x` has the element type.
    elemName = elemName[0 ..< elemName.len - 2]
    elemKind = (if elemName.endsWith("[]"): tkSequence else: ctx.classifyName(elemName))
  ctx.pushScope()
  ctx.declare(n.name, elemKind, elemName)
  for s in n.sons: ctx.walkStmt(s)
  ctx.popScope()

proc walkFor(ctx: var NsCheckContext; n: NsNode) =
  ctx.pushScope()
  let header = n.body
  if header != nil:
    for h in header.sons:
      if h == nil: continue
      if h.kind in {nsnLocalDecl, nsnAssign}: ctx.walkStmt(h)
      else: discard ctx.walkExpr(h)
  for s in n.sons: ctx.walkStmt(s)
  ctx.popScope()

proc walkTry(ctx: var NsCheckContext; n: NsNode) =
  walkBody(ctx, n.body)
  for c in n.sons:
    if c.kind == nsnCatch:
      ctx.checkCatch(c)
      ctx.pushScope()
      if c.typ != nil:
        ctx.declare(c.name, ctx.classifyType(c.typ), declTypeName(c.typ), c.typ)
      if c.body != nil:
        for s in c.body.sons: ctx.walkStmt(s)
      ctx.popScope()
    elif c.kind == nsnFinally:
      walkBody(ctx, c.body)

proc walkSwitch(ctx: var NsCheckContext; n: NsNode) =
  discard ctx.walkExpr(n.body)
  for sec in n.sons:
    for lab in sec.sons: discard ctx.walkExpr(lab)
    walkBody(ctx, sec.body)

proc checkAssignable(ctx: NsCheckContext; target: NsNode) =
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
  of nsnExprStmt: discard ctx.walkExpr(n.body)
  of nsnAssign:
    for s in n.sons: discard ctx.walkExpr(s)
    ctx.checkAssignable(n.sons[0])
    ## A plain `x = y` is a conversion C# may refuse; a compound one (`x += y`) is
    ## not, because C# lets the operator's own result narrow back.
    if n.name.len == 0 and n.sons.len == 2:
      ctx.checkConvertible(n.sons[1], targetOfExpr(ctx, n.sons[0]), n.info)
      if n.sons[0].typeKind != tkNullable:
        ctx.coerce(n.sons[1], numName(n.sons[0]), n.info)
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
    walkStmts(ctx, n.sons)
  of nsnFor: walkFor(ctx, n)
  of nsnForeach: walkForeach(ctx, n)
  of nsnSwitch: walkSwitch(ctx, n)
  of nsnTry: walkTry(ctx, n)
  of nsnReturn, nsnThrow:
    if n.body != nil:
      discard ctx.walkExpr(n.body)
      if n.kind == nsnReturn:
        ## The declared return type is the conversion C# applies to `return`.
        if ctx.retType != nil:
          ctx.checkConvertible(n.body, ctx.targetOfType(ctx.retType), n.body.info)
          if ctx.retType.kind != nsnNullableType:
            ctx.coerce(n.body, declTypeName(ctx.retType), n.body.info)
      else:
        ctx.checkThrow(n)
  else:
    for s in n.sons: ctx.walkStmt(s)
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

proc walkMemberDecl(ctx: var NsCheckContext; m: NsNode) =
  case m.kind
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
      for s in m.body.sons: ctx.walkStmt(s)
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
      for s in m.body.sons: ctx.walkStmt(s)
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
      discard ctx.walkExpr(m.body)
      ctx.checkConvertible(m.body, ctx.targetOfType(m.typ), m.body.info)
      ctx.coerce(m.body, declTypeName(m.typ), m.body.info)
    for i in 0 ..< m.params.len:
      let acc = m.params[i]
      if acc == nil or acc.kind == nsnEmpty: continue
      ctx.pushScope()
      ## The setter's implicit parameter is `value`.
      if i == 1: ctx.declare("value", ctx.classifyType(m.typ), declTypeName(m.typ))
      for s in acc.sons: ctx.walkStmt(s)
      ctx.popScope()
    ctx.retType = savedRet
    ctx.isStaticCtx = false
  of nsnFieldDecl:
    ## A field initialiser is a conversion to the field's type, like a local's.
    if m.body != nil:
      ctx.isStaticCtx = m.attrs.isStatic
      discard ctx.walkExpr(m.body)
      ctx.checkConvertible(m.body, ctx.targetOfType(m.typ), m.body.info)
      ctx.coerce(m.body, declTypeName(m.typ), m.body.info)
      ctx.isStaticCtx = false
    elif m.attrs.isConst:
      nsError(ctx.config, m.info, ndConstNeedsValue)
  else: discard

proc checkSupported(ctx: NsCheckContext; cls: NsNode) =
  ## Features the frontend can parse but does not lower are rejected loudly
  ## rather than dropped silently; ignoring `interface` or `override` produced
  ## programs that looked like they worked.
  if cls.typeParams.len > 0:
    for m in cls.sons:
      if m.kind == nsnCtorDecl and m.attrs.isStatic:
        ## Each instantiation would need its own run, on first use.
        nsError(ctx.config, m.info, ndUnsupported,
                "a static constructor in a generic class")

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
  ## An interface's own members have no body (a default implementation is C# 8,
  ## which N# does not lower yet).
  if cls.classKind == ckInterface:
    for m in cls.sons:
      if m.kind == nsnMethodDecl and m.body != nil:
        nsError(ctx.config, m.info, ndUnsupported, "a default interface method")
      elif m.attrs.isStatic:
        nsError(ctx.config, m.info, ndUnsupported, "a static interface member")
    return
  for i in ctx.scope.interfaceClosure(cls.name):
    if not ctx.scope.classes.hasKey(i): continue
    for im in ctx.scope.classes[i].members:
      var found = false
      for c in ctx.scope.chain(cls.name):
        for m in ctx.scope.classes[c].members:
          if m.name == im.name and not m.isStatic: found = true
        if found: break
      if not found:
        for m in cls.sons:
          if m.name == im.name and m.explicitIface == i: found = true
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

proc walkTop(ctx: var NsCheckContext; d: NsNode) =
  case d.kind
  of nsnClassDecl: ctx.walkClass(d)
  of nsnNamespace:
    if d.body != nil:
      for x in d.body.sons: ctx.walkTop(x)
  of nsnEnumDecl, nsnDelegateDecl, nsnUsing: discard
  else: ctx.walkStmt(d)

proc checkModule*(module: NsNode; scope: NsModuleScope; config: ConfigRef) =
  ## Resolves names, enforces access control, checks the conversions and applies the
  ## base-constructor rule. Diagnostics go through `config`.
  var ctx = NsCheckContext(scope: scope, config: config,
                           surface: bclSurface(config),
                           types: newTable[string, NsTypeInfo]())
  for d in module.sons: ctx.walkTop(d)
  ## After the walk, so every declaration is looked at exactly once: a `MyObj?` on a
  ## reference type is only an annotation, and C# warns about it.
  warnNullableRefs(ctx, module)