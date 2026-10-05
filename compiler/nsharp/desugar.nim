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
    usingPaths: HashSet[string]
      ## The modules this module's own `using` directives import, so a member whose
      ## namespace is already imported is not named twice.
    cache: IdentCache
    thisName: string        ## "self" in instance members, "" in static ones
    entryPoint: PNode       ## the emitted `Main` proc, if there was one
    nilChecks: bool         ## whether the compilation has the nil check on

proc note(l: NsFromImports; module, name: string) =
  ## Records one declaration to import by name, once.
  if module.len == 0 or name.len == 0: return
  if not l.byModule.hasKey(module): l.byModule[module] = @[]
  if name notin l.byModule[module]: l.byModule[module].add name

proc id(l: Lowerer; s: string; info: TLineInfo): PNode =
  newAtom(l.cache.getIdentExact(s), info)

proc empty(info: TLineInfo): PNode {.inline.} = newNodeI(nkEmpty, info)

proc emptyList(info: TLineInfo): PNode {.inline.} = newNodeI(nkStmtList, info)

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
    result = l.id(nimTypeName(t.name), info)
    if t.sons.len > 0:
      let be = newNodeI(nkBracketExpr, info)
      be.add result
      for a in t.sons: be.add l.typeToNim(a, info)
      result = be
  else:
    result = empty(info)

proc formalParams(l: Lowerer; ret: NsNode; params: seq[NsNode];
                  info: TLineInfo): PNode =
  result = newNodeI(nkFormalParams, info)
  result.add l.typeToNim(ret, info)
  for p in params:
    let defs = newNodeI(nkIdentDefs, p.info)
    defs.add l.id(p.name, p.info)
    defs.add l.typeToNim(p.typ, p.info)
    defs.add empty(p.info)
    result.add defs

# --- expressions ------------------------------------------------------------

proc annotateLambda(l: Lowerer; lam, declared: NsNode) =
  ## Fills a lambda's parameter and return types from the declared delegate type,
  ## so `IntFn f = x => ...;` gives `x` a type. This is the only place the
  ## "declared local of delegate type" information is used.
  if lam == nil or lam.kind != nsnLambda: return
  if declared == nil or declared.kind != nsnTypeName: return
  if not l.scope.delegates.hasKey(declared.name): return
  let d = l.scope.delegates[declared.name]
  lam.typ = d.typ
  for i in 0 ..< lam.params.len:
    if lam.params[i].typ == nil and i < d.params.len:
      lam.params[i].typ = d.params[i].typ

proc expr(l: Lowerer; n: NsNode): PNode
proc stmtSeq(l: Lowerer; blk: NsNode): PNode
proc nilableReceiver(l: Lowerer; n: NsNode): bool
proc noneFromName(l: Lowerer; name: string; info: TLineInfo): PNode
proc someNamed(l: Lowerer; v: PNode; name: string; info: TLineInfo): PNode
proc presentOf(l: Lowerer; v: NsNode; info: TLineInfo): PNode
proc wrappedArg(l: Lowerer; a: NsNode): PNode

proc lambdaToNim(l: Lowerer; n: NsNode): PNode =
  let fp = newNodeI(nkFormalParams, n.info)
  fp.add l.typeToNim(n.typ, n.info)
  for p in n.params:
    let defs = newNodeI(nkIdentDefs, p.info)
    defs.add l.id(p.name, p.info)
    defs.add l.typeToNim(p.typ, p.info)
    defs.add empty(p.info)
    fp.add defs
  result = newNodeI(nkLambda, n.info, 7)
  for i in 0 .. 6: result[i] = empty(n.info)
  result[3] = fp
  result[6] = if n.body != nil: l.stmtSeq(n.body) else: emptyList(n.info)

proc newToNim(l: Lowerer; n: NsNode): PNode =
  ## `new T(args)` becomes `newT(args)`, carrying generic arguments over.
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
  for a in n.sons: result.add l.wrappedArg(a)

proc callToNim(l: Lowerer; n: NsNode): PNode =
  var callee = n.body
  ## `Class.Method(...)` / `Console.WriteLine(...)`: the qualifier is dropped,
  ## because it is a namespace or a static class. `sema.nim` decides this and
  ## records it as `tkType`.
  if callee != nil and callee.kind == nsnMember and callee.body != nil and
     callee.body.typeKind == tkType:
    ## A static member: the qualifier is dropped, so the declaration it names has to
    ## be imported by name.
    l.noteMemberImport(callee)
    callee = nsnIdent(callee.name, callee.info)
  ## `x.Method(...)` on a reference: C# tests the receiver before the call, so a
  ## method that never touches `self` still throws on a nil receiver. `this` is
  ## left alone, and the whole check follows the compilation's nil-check setting.
  result = newNodeI(nkCall, n.info)
  if l.nilChecks and callee.kind == nsnMember and l.nilableReceiver(callee.body):
    let checked = newNodeI(nkCall, n.info)
    checked.add l.id("nsCheckNil", n.info)
    checked.add l.expr(callee.body)
    result.add newTree(nkDotExpr, n.info, checked, l.id(callee.name, n.info))
  else:
    result.add l.expr(callee)
  for a in n.sons: result.add l.wrappedArg(a)

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
  if n == nil or n.kind == nsnThis: return false
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

proc expr(l: Lowerer; n: NsNode): PNode =
  if n == nil: return newNodeI(nkEmpty, unknownLineInfo)
  case n.kind
  of nsnEmpty: result = empty(n.info)
  of nsnIdent: result = l.id(n.name, n.info)
  of nsnThis:
    result = l.id(if l.thisName.len > 0: l.thisName else: "this", n.info)
  of nsnNull: result = newNodeI(nkNilLit, n.info)
  of nsnIntLit: result = newAtom(nkIntLit, n.intVal, n.info)
  of nsnFloatLit: result = newAtom(nkFloatLit, n.floatVal, n.info)
  of nsnStrLit: result = newAtom(nkStrLit, n.strVal, n.info)
  of nsnCharLit: result = newAtom(nkCharLit, n.intVal, n.info)
  of nsnBoolLit: result = l.id(if n.intVal != 0: "true" else: "false", n.info)
  of nsnMember:
    l.noteMemberImport(n)
    result = newTree(nkDotExpr, n.info, l.memberReceiverChecked(n),
                     l.id(n.name, n.info))
  of nsnCall: result = l.callToNim(n)
  of nsnIndex:
    result = newTree(nkBracketExpr, n.info, l.expr(n.body), l.expr(n.sons[0]))
  of nsnNew: result = l.newToNim(n)
  of nsnNewArray:
    let typ = newTree(nkBracketExpr, n.info, l.id("newSeq", n.info),
                      l.typeToNim(n.typ, n.info))
    result = newNodeI(nkCall, n.info)
    result.add typ
    result.add l.expr(n.sons[0])
  of nsnArrayLit:
    let br = newNodeI(nkBracket, n.info)
    for e in n.sons: br.add l.expr(e)
    result = newTree(nkPrefix, n.info, l.id("@", n.info), br)
  of nsnUnary:
    result = newTree(nkPrefix, n.info, l.id(n.name, n.info), l.expr(n.body))
  of nsnIncDec:
    result = newTree(nkCommand, n.info, l.id(n.name, n.info), l.expr(n.body))
  of nsnCast:
    ## `(T)x` is a Nim conversion, and also how a ref object is downcast. A `T?`
    ## operand is unwrapped first, since the conversion applies to the value.
    result = newNodeI(nkCall, n.info)
    result.add l.typeToNim(n.typ, n.info)
    if n.body != nil and n.body.typeKind == tkNullable:
      result.add l.presentOf(n.body, n.info)
    else:
      result.add l.expr(n.body)
  of nsnIs:
    result = newTree(nkInfix, n.info, l.id(n.name, n.info), l.expr(n.body),
                     l.typeToNim(n.typ, n.info))
  of nsnAs: result = l.asToNim(n)
  of nsnDefault:
    result = newNodeI(nkCall, n.info)
    result.add l.id("default", n.info)
    result.add l.typeToNim(n.typ, n.info)
  of nsnBinary:
    if n.name in ["==", "!="] and
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
  else: result = empty(n.info)

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

proc switchSectionBody(l: Lowerer; blk: NsNode): PNode =
  ## A section body with a trailing `break` dropped: in C# `break` exits the
  ## switch, but Nim `case` never falls through, so keeping it would break out of
  ## an enclosing loop instead.
  var stmts = if blk == nil: newSeq[NsNode]() else: blk.sons
  if stmts.len > 0 and stmts[^1].kind == nsnBreak:
    stmts = stmts[0 ..< stmts.len - 1]
  result = newNodeI(nkStmtList, if blk == nil: unknownLineInfo else: blk.info)
  for s in stmts: result.add l.stmt(s)

proc switchToNim(l: Lowerer; n: NsNode): PNode =
  result = newNodeI(nkCaseStmt, n.info)
  result.add l.expr(n.body)
  var hasDefault = false
  for sec in n.sons:
    if sec.name == "default":
      let e = newNodeI(nkElse, sec.info)
      e.add l.switchSectionBody(sec.body)
      result.add e
      hasDefault = true
    else:
      let br = newNodeI(nkOfBranch, sec.info)
      for lab in sec.sons: br.add l.expr(lab)
      br.add l.switchSectionBody(sec.body)
      result.add br
  if not hasDefault:
    ## C# does not require a `default`; Nim `case` needs an `else`.
    let e = newNodeI(nkElse, n.info)
    let sl = newNodeI(nkStmtList, n.info)
    sl.add newTree(nkDiscardStmt, n.info, empty(n.info))
    e.add sl
    result.add e

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
  for s in n.sons: wbody.add l.stmt(s)
  if header != nil and header.sons.len > 2 and header.sons[2] != nil:
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
  l.annotateLambda(n.body, n.typ)
  let defs = newNodeI(nkIdentDefs, n.info)
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
    ## Compound assignment: `x += e` becomes `x = x + e`.
    value = newTree(nkInfix, n.info, l.id(n.name, n.info),
                    copyTree(lhs), l.expr(n.sons[1]))
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

proc stmt(l: Lowerer; n: NsNode): PNode =
  if n == nil: return empty(unknownLineInfo)
  case n.kind
  of nsnBlock: result = l.stmtSeq(n)
  of nsnBlockStmt:
    let blk = newNodeI(nkBlockStmt, n.info)
    blk.add empty(n.info)
    blk.add l.stmtsToNode(n.sons, n.info)
    result = blk
  of nsnLocalDecl: result = l.localDeclToNim(n)
  of nsnExprStmt: result = l.expr(n.body)
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
    result = newNodeI(nkBreakStmt, n.info)
    result.add empty(n.info)
  of nsnContinue:
    result = newNodeI(nkContinueStmt, n.info)
    result.add empty(n.info)
  of nsnThrow: result = l.throwToNim(n)
  else: result = l.expr(n)

# --- declaration helpers ----------------------------------------------------

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
            withPragmas = false): PNode =
  result = newNodeI(nkProcDef, info, 7)
  result[0] = nameNode
  result[1] = empty(info)
  result[2] = empty(info)
  result[3] = params
  result[4] = if withPragmas: l.procPragmas(params, info) else: empty(info)
  result[5] = empty(info)
  result[6] = body

proc paramDef(l: Lowerer; p: NsNode): PNode =
  result = newNodeI(nkIdentDefs, p.info)
  result.add l.id(p.name, p.info)
  result.add l.typeToNim(p.typ, p.info)
  result.add empty(p.info)

proc selfDefs(l: Lowerer; clsName: string; isException: bool; info: TLineInfo): PNode =
  ## `self: ClsName`, as a `ref` for exception classes because those are lowered
  ## as value objects.
  result = newNodeI(nkIdentDefs, info)
  result.add l.id("self", info)
  result.add (if isException: newTree(nkRefTy, info, l.id(clsName, info))
              else: l.id(clsName, info))
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
  td.add empty(n.info)
  td.add procTy
  result = newNodeI(nkTypeSection, n.info)
  result.add td

# --- properties -------------------------------------------------------------

proc lowerProperty(l: Lowerer; cls: NsNode; m: NsNode; isException: bool): seq[PNode] =
  ## A C# property becomes a getter named `P` and a setter named `P=`. An
  ## accessor written `get;`/`set;` reads and writes a generated `PBacking` field.
  result = @[]
  if m.attrs.isStatic: return   # static properties are not supported
  let getter = if m.params.len > 0: m.params[0] else: nil
  let setter = if m.params.len > 1: m.params[1] else: nil
  if getter != nil:
    let gbody =
      if getter.kind == nsnEmpty:
        newTree(nkDotExpr, m.info, l.id("self", m.info),
                l.id(m.name & "Backing", m.info))
      else:
        l.stmtSeq(getter)
    let gp = newNodeI(nkFormalParams, m.info)
    gp.add l.typeToNim(m.typ, m.info)
    gp.add l.selfDefs(cls.name, isException, m.info)
    result.add l.mkProc(l.exportedName(m.attrs, m.name, m.info), gp, gbody, m.info)
  if setter != nil:
    let sbody =
      if setter.kind == nsnEmpty:
        newTree(nkAsgn, m.info,
                newTree(nkDotExpr, m.info, l.id("self", m.info),
                        l.id(m.name & "Backing", m.info)),
                l.id("value", m.info))
      else:
        l.stmtSeq(setter)
    let sp = newNodeI(nkFormalParams, m.info)
    sp.add empty(m.info)
    sp.add l.selfDefs(cls.name, isException, m.info)
    sp.add l.paramDef(nsnParam("value", m.typ, m.info))
    result.add l.mkProc(l.exportedName(m.attrs, m.name & "=", m.info), sp, sbody, m.info)

# --- constructors -----------------------------------------------------------

proc lowerInit(l: Lowerer; cls, m: NsNode; isException: bool;
               baseName: string): PNode =
  ## `proc initC(self: C, params) = <base init>; <body>`
  let ip = newNodeI(nkFormalParams, m.info)
  ip.add empty(m.info)
  ip.add l.selfDefs(cls.name, isException, m.info)
  for p in m.params: ip.add l.paramDef(p)
  let ibody = newNodeI(nkStmtList, m.info)
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
  ap.add (if isException: newTree(nkRefTy, m.info, l.id(cls.name, m.info))
          else: l.id(cls.name, m.info))
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

# --- classes ----------------------------------------------------------------

proc alwaysExported(l: Lowerer; name: string; info: TLineInfo): PNode =
  ## The implicit constructor pair is always exported, as in the previous
  ## emitter, regardless of the class's own accessibility.
  result = newTree(nkPostfix, info, l.id("*", info), l.id(name, info))

proc lowerClass(l: var Lowerer; n: NsNode; into: var seq[PNode]) =
  let isClass = n.classKind == ckClass
  let mappedBase =
    if n.typ != nil and n.typ.kind == nsnTypeName: nimTypeName(n.typ.name)
    else: ""
  let isException = isClass and
    l.surface.isExceptionType(mappedBase, l.scope.baseChain(mappedBase))

  # 1. the type: `C = ref object` for a class, a plain `object` for a struct and
  #    for an exception class (which is raised as `ref C`).
  let recList = newNodeI(nkRecList, n.info)
  for m in n.sons:
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
  td.add empty(n.info)
  td.add typeValue
  let sec = newNodeI(nkTypeSection, n.info)
  sec.add td
  into.add sec

  # 2. members, in source order (Nim resolves `self.Prop` dot-calls against
  #    declarations seen so far, so a property must precede its users)
  var hasCtor = false
  for m in n.sons:
    var inner = l
    case m.kind
    of nsnMethodDecl:
      inner.thisName = if m.attrs.isStatic: "" else: "self"
      var params = l.formalParams(m.typ, m.params, m.info)
      if m.name == "Main" and m.attrs.isStatic:
        # entry point: parameters are ignored, it is called as `Main()`
        params = newNodeI(nkFormalParams, m.info)
        params.add l.typeToNim(m.typ, m.info)
      elif not m.attrs.isStatic:
        let np = newNodeI(nkFormalParams, m.info)
        np.add params[0]
        np.add l.selfDefs(n.name, isException, m.info)
        for i in 1 ..< params.len: np.add params[i]
        params = np
      let pd = inner.mkProc(l.exportedName(m.attrs, m.name, m.info), params,
                            inner.stmtSeq(m.body), m.info)
      into.add pd
      if m.name == "Main" and l.entryPoint == nil: l.entryPoint = pd
    of nsnPropertyDecl:
      inner.thisName = "self"
      for p in inner.lowerProperty(n, m, isException): into.add p
    of nsnCtorDecl:
      hasCtor = true
      inner.thisName = "self"
      into.add inner.lowerInit(n, m, isException, mappedBase)
      into.add inner.lowerAllocator(n, m, isException)
    of nsnFieldDecl: discard
    else: discard

  # 3. the implicit constructor pair when none was declared
  if not hasCtor:
    let info = n.info
    let baseParamless =
      mappedBase.len == 0 or not l.scope.classes.hasKey(mappedBase) or
      l.scope.classes[mappedBase].ctorArities.len == 0 or
      0 in l.scope.classes[mappedBase].ctorArities
    let ip = newNodeI(nkFormalParams, info)
    ip.add empty(info)
    ip.add l.selfDefs(n.name, isException, info)
    let ibody = newNodeI(nkStmtList, info)
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
    ap.add (if isException: newTree(nkRefTy, info, l.id(n.name, info))
            else: l.id(n.name, info))
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
    if d.body != nil:
      for x in d.body.sons: lowerDecl(l, x, into)
  of nsnClassDecl:
    if d.classKind == ckInterface: return   # interfaces are not supported yet
    lowerClass(l, d, into)
  of nsnEnumDecl: into.add l.lowerEnum(d)
  of nsnDelegateDecl: into.add l.lowerDelegate(d)
  else: into.add l.stmt(d)

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
  for s in stmts: result.add s
  if l.entryPoint != nil:
    result.add makeMainCall(l, l.entryPoint)

proc isImportStmt*(n: PNode): bool =
  ## An import, which both halves of a namespace module need: the declarations may
  ## name imported types and the implementations imported procs.
  n.kind in {nkImportStmt, nkImportExceptStmt, nkFromStmt}

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
