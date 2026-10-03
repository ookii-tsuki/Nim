# N# frontend - semantic analysis and name resolution
#
# Resolves names (a bare member name becomes `this.Member`), enforces access
# control, attaches coarse type information to expressions (`NsNode.typeKind`)
# and applies the base-constructor rule, so lowering can make type-directed
# decisions instead of guessing from names (`.Length`/`.Count`/`.Message`
# renames, integer `/`).
#
# The information gathered is deliberately coarse (`ast.NsTypeKind`) and only as
# precise as lowering needs. This is not a type system: no conversions, no
# overload resolution, no generics.

import std/tables
import ../msgs, ../options
import ast, bcl, symbols

type
  NsTypeInfo* = object
    kind*: NsTypeKind
    name*: string              ## the type's name, when it has one

  NsCheckContext = object
    scope: NsModuleScope
    config: ConfigRef
    clsName: string                            ## enclosing class, "" outside one
    members: seq[string]                       ## names reachable from it
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
             typeName = "") =
  if ctx.undo.len > 0:
    let had = ctx.types.hasKey(name)
    ctx.undo[^1].add (name, (if had: ctx.types[name]
                             else: NsTypeInfo(kind: tkUnknown)), had)
  ctx.types[name] = NsTypeInfo(kind: kind, name: typeName)

# --- type classification ----------------------------------------------------

proc isExceptionDerived(ctx: NsCheckContext; name: string): bool =
  ## A user class is an exception type when anything in its base chain is an
  ## exception base, directly or transitively.
  result = false
  if not ctx.scope.classes.hasKey(name): return false
  for c in ctx.scope.chain(name):
    let b = ctx.scope.classes[c].base
    if b.len > 0 and isExceptionBase(b): return true

proc classifyName(ctx: NsCheckContext; name: string): NsTypeKind =
  ## Kind of a type written by name, purely from `bcl.nim`'s tables plus the
  ## module scope. This is where "List is a sequence" and "Exception is an
  ## exception" come from; it is a lookup, not a guess.
  for s in NsIntTypeNames:
    if s == name: return tkInt
  for s in NsFloatTypeNames:
    if s == name: return tkFloat
  for s in NsSequenceTypeNames:
    if s == name: return tkSequence
  case name
  of "bool": tkBool
  of "char": tkChar
  of "string": tkString
  else:
    if isExceptionBase(name): tkException
    elif ctx.scope.delegates.hasKey(name): tkDelegate
    elif ctx.scope.classes.hasKey(name):
      if ctx.isExceptionDerived(name): tkException else: tkClass
    else: tkUnknown

proc classifyType(ctx: NsCheckContext; t: NsNode): NsTypeKind =
  ## Kind of a written type. `T[]` is a sequence; a name goes through
  ## `classifyName`; anything unrecognised stays unknown so lowering stays
  ## conservative.
  if t == nil: return tkUnknown
  case t.kind
  of nsnArrayType: tkSequence
  of nsnTypeName: ctx.classifyName(t.name)
  else: tkUnknown

proc memberKind(ctx: NsCheckContext; clsName, member: string): NsTypeKind =
  ## Kind of `this.member` / `Class.member`. For a method this is its return
  ## type, which is what the surrounding call produces.
  let info = ctx.scope.findMemberInfo(clsName, member)
  if info.name.len == 0: return tkUnknown
  ctx.classifyType(info.typ)

# --- expressions ------------------------------------------------------------

proc inaccessible(ctx: NsCheckContext; n: NsNode) =
  localError(ctx.config, n.info,
             "'" & n.name & "' is inaccessible due to its protection level")

proc checkMemberAccess(ctx: NsCheckContext; n: NsNode) =
  ## `this.member`, or the `this.member` a bare name was rewritten into.
  if n.body != nil and n.body.kind == nsnThis and ctx.clsName.len > 0:
    if not ctx.scope.accessibleFrom(ctx.clsName, n.name):
      ctx.inaccessible(n)

proc walkExpr(ctx: var NsCheckContext; n: NsNode): NsTypeKind
proc walkStmt(ctx: var NsCheckContext; n: NsNode)
proc walkBody(ctx: var NsCheckContext; blk: NsNode)

proc walkIdent(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  ## A bare name. Inside an instance member body, a name that is a class member
  ## is rewritten in place into `this.name` and then resolved as a member, which
  ## is the behaviour the parse-time rewrite used to have. `value` is exempt: it
  ## is the implicit setter parameter.
  if ctx.clsName.len > 0 and n.name != "value" and n.name in ctx.members:
    n.kind = nsnMember
    n.body = nsn(nsnThis, n.info)
    return ctx.walkExpr(n)
  if ctx.types.hasKey(n.name):
    let info = ctx.types[n.name]
    n.setType(info.kind, info.name)
    result = info.kind
  elif ctx.scope.delegates.hasKey(n.name):
    n.setType(tkDelegate, n.name)
    result = tkDelegate
  elif n.name.len > 0 and n.name[0] in {'A'..'Z'}:
    ## A type or namespace used as a receiver (`Console.WriteLine`), or a static
    ## call qualifier. Distinguishing these from a value needs real resolution;
    ## the capitalisation convention is a stand-in for it.
    n.setType(tkType, n.name)
    result = tkType
  else:
    n.setType(tkUnknown)
    result = tkUnknown

proc walkMember(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  ## Member access. The receiver's kind decides what the member means: `.Length`
  ## is `len` only on a sequence or string, `.Message` is `msg` only on an
  ## exception.
  let rk = ctx.walkExpr(n.body)
  var kind = tkUnknown
  var tname = ""
  case rk
  of tkSequence:
    if n.name in ["Length", "Count"]: kind = tkInt
  of tkString:
    if n.name == "Length": kind = tkInt
  of tkException:
    if n.name == "Message": kind = tkString
  of tkClass:
    ctx.checkMemberAccess(n)
    kind = ctx.memberKind(n.body.typeName, n.name)
    if n.body.typeName.len == 0: tname = ""
  else: discard
  n.setType(kind, tname)
  result = kind

proc walkCall(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  var kind = tkUnknown
  let callee = n.body
  if callee != nil and callee.kind == nsnMember:
    let rk = ctx.walkExpr(callee.body)
    if rk == tkType:
      ## `Class.Method(...)` or `Namespace.Method(...)`: lowering drops the
      ## qualifier, and the result type is the method's if the class is known.
      kind = ctx.memberKind(callee.body.name, callee.name)
    elif rk == tkClass:
      kind = ctx.memberKind(callee.body.typeName, callee.name)
    callee.setType(kind)
  elif callee != nil:
    discard ctx.walkExpr(callee)
  for a in n.sons: discard ctx.walkExpr(a)
  n.setType(kind)
  result = kind

proc walkExpr(ctx: var NsCheckContext; n: NsNode): NsTypeKind =
  if n == nil: return tkUnknown
  case n.kind
  of nsnIntLit: n.setType(tkInt); result = tkInt
  of nsnFloatLit: n.setType(tkFloat); result = tkFloat
  of nsnStrLit: n.setType(tkString); result = tkString
  of nsnCharLit: n.setType(tkChar); result = tkChar
  of nsnBoolLit: n.setType(tkBool); result = tkBool
  of nsnNull: n.setType(tkUnknown); result = tkUnknown
  of nsnThis:
    n.setType(tkClass, ctx.clsName)
    result = tkClass
  of nsnIdent: result = ctx.walkIdent(n)
  of nsnMember: result = ctx.walkMember(n)
  of nsnCall: result = ctx.walkCall(n)
  of nsnNew:
    for a in n.sons: discard ctx.walkExpr(a)
    let k = ctx.classifyType(n.typ)
    n.setType(k, (if n.typ != nil: n.typ.name else: ""))
    result = k
  of nsnNewArray, nsnArrayLit:
    for a in n.sons: discard ctx.walkExpr(a)
    n.setType(tkSequence)
    result = tkSequence
  of nsnIndex:
    discard ctx.walkExpr(n.body)
    for a in n.sons: discard ctx.walkExpr(a)
    n.setType(tkUnknown)
    result = tkUnknown
  of nsnUnary:
    result = ctx.walkExpr(n.body)
    n.setType(result)
  of nsnIncDec:
    discard ctx.walkExpr(n.body)
    n.setType(tkInt)
    result = tkInt
  of nsnBinary:
    let lk = ctx.walkExpr(n.sons[0])
    let rk = ctx.walkExpr(n.sons[1])
    result = tkUnknown
    case n.name
    of "==", "!=", "<", ">", "<=", ">=":
      result = tkBool
    of "and", "or", "xor":
      ## Bitwise on integers, logical otherwise.
      result = (if lk == tkInt and rk == tkInt: tkInt else: tkBool)
    of "/":
      if lk == tkInt and rk == tkInt:
        ## C# integer division is truncating; Nim's `/` is floating point.
        n.name = "div"
        result = tkInt
      elif lk == tkFloat or rk == tkFloat:
        result = tkFloat
    else:
      if lk == tkFloat or rk == tkFloat: result = tkFloat
      elif lk == tkInt: result = tkInt
    n.setType(result)
  of nsnTernary:
    discard ctx.walkExpr(n.sons[0])
    discard ctx.walkExpr(n.sons[1])
    result = ctx.walkExpr(n.sons[2])
    n.setType(result)
  of nsnLambda:
    ## Parameters start untyped (they are filled in from the declared delegate
    ## type during lowering) but the body must still be walked, otherwise names
    ## inside it are never resolved.
    ctx.pushScope()
    for p in n.params:
      if p.typ != nil: ctx.declare(p.name, ctx.classifyType(p.typ), p.typ.name)
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
  ## parameter) in the current scope so later statements see its type.
  var kind = ctx.classifyType(n.typ)
  if n.body != nil:
    let initKind = ctx.walkExpr(n.body)
    if n.typ == nil: kind = initKind
  ctx.declare(n.name, kind, (if n.typ != nil: n.typ.name else: n.typeName))

proc walkForeach(ctx: var NsCheckContext; n: NsNode) =
  let elemKind = ctx.classifyType(n.typ)
  discard ctx.walkExpr(n.body)
  ctx.pushScope()
  ctx.declare(n.name, elemKind,
              (if n.typ != nil: n.typ.name else: n.body.typeName))
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
      ctx.pushScope()
      if c.typ != nil:
        ctx.declare(c.name, ctx.classifyType(c.typ), c.typ.name)
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

proc walkStmt(ctx: var NsCheckContext; n: NsNode) =
  if n == nil: return
  case n.kind
  of nsnBlock: walkBody(ctx, n)
  of nsnLocalDecl: ctx.walkDecl(n)
  of nsnExprStmt: discard ctx.walkExpr(n.body)
  of nsnAssign:
    for s in n.sons: discard ctx.walkExpr(s)
  of nsnIf:
    for b in n.sons:
      if b.kind == nsnIfBranch:
        discard ctx.walkExpr(b.body)
        walkStmts(ctx, b.sons)
      elif b.kind == nsnElseBranch:
        walkStmts(ctx, b.sons)
  of nsnWhile:
    discard ctx.walkExpr(n.body)
    walkStmts(ctx, n.sons)
  of nsnFor: walkFor(ctx, n)
  of nsnForeach: walkForeach(ctx, n)
  of nsnSwitch: walkSwitch(ctx, n)
  of nsnTry: walkTry(ctx, n)
  of nsnReturn, nsnThrow:
    if n.body != nil: discard ctx.walkExpr(n.body)
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
        localError(ctx.config, m.info,
          "'" & cls.name & "' must call a base constructor: '" & baseName &
          "' has no accessible parameterless constructor")
  if not anyCtor:
    localError(ctx.config, cls.info,
      "'" & cls.name & "' must define a constructor: '" & baseName &
      "' has no accessible parameterless constructor")

proc walkMemberDecl(ctx: var NsCheckContext; m: NsNode) =
  case m.kind
  of nsnMethodDecl:
    ## Instance methods see the class's members as bare names; static ones do
    ## not, matching the parse-time rewrite this pass replaces.
    let saved = ctx.members
    if m.attrs.isStatic: ctx.members = @[]
    ctx.pushScope()
    for p in m.params: ctx.walkDecl(p)
    if m.body != nil:
      for s in m.body.sons: ctx.walkStmt(s)
    ctx.popScope()
    ctx.members = saved
  of nsnCtorDecl:
    ctx.pushScope()
    for p in m.params: ctx.walkDecl(p)
    for a in m.initArgs: discard ctx.walkExpr(a)
    if m.body != nil:
      for s in m.body.sons: ctx.walkStmt(s)
    ctx.popScope()
  of nsnPropertyDecl:
    for i in 0 ..< m.params.len:
      let acc = m.params[i]
      if acc == nil or acc.kind == nsnEmpty: continue
      ctx.pushScope()
      ## The setter's implicit parameter is `value`.
      if i == 1: ctx.declare("value", ctx.classifyType(m.typ), m.typ.name)
      for s in acc.sons: ctx.walkStmt(s)
      ctx.popScope()
  of nsnFieldDecl:
    ## Field initialisers are parsed but not lowered yet; they are still resolved
    ## so a problem in one is reported instead of silently hidden.
    if m.body != nil: discard ctx.walkExpr(m.body)
  else: discard

proc checkSupported(ctx: NsCheckContext; cls: NsNode) =
  ## Features the frontend can parse but does not lower are rejected loudly
  ## rather than dropped silently; ignoring `interface` or `override` produced
  ## programs that looked like they worked.
  if cls.classKind == ckInterface:
    localError(ctx.config, cls.info, "N# does not support 'interface' yet")
  for m in cls.sons:
    case m.kind
    of nsnPropertyDecl:
      if m.attrs.isStatic:
        localError(ctx.config, m.info, "N# does not support static properties yet")
    of nsnFieldDecl:
      if m.body != nil:
        localError(ctx.config, m.info, "N# does not support field initialisers yet")
    else: discard

proc walkClass(ctx: var NsCheckContext; cls: NsNode) =
  ctx.checkSupported(cls)
  let savedCls = ctx.clsName
  let savedMembers = ctx.members
  ctx.clsName = cls.name
  ctx.members = ctx.scope.memberNames(cls.name)
  for m in cls.sons: ctx.walkMemberDecl(m)
  ctx.clsName = savedCls
  ctx.members = savedMembers
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
  ## Resolves names, enforces access control and applies the base-constructor
  ## rule. Diagnostics go through `config`.
  var ctx = NsCheckContext(scope: scope, config: config,
                           types: newTable[string, NsTypeInfo]())
  for d in module.sons: ctx.walkTop(d)