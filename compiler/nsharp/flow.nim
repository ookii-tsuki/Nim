# N# frontend - definite assignment
#
# C# requires a local to be definitely assigned before it is read (CS0165) and an
# `out` parameter to be assigned before the method returns (CS0177). This pass
# follows C#'s rules over one member body: the state is the set of tracked
# variables that are definitely assigned at a point, and control flow merges
# states by intersection. Only what C# itself tracks is tracked here -- locals
# declared without a value, and `out` parameters -- so a variable N# does not
# understand is never reported.

import std/sets
import ../options, ../lineinfos
import ast, diagnostics

type
  DaState = object
    unreachable: bool        ## no path reaches here: every variable counts as assigned
    assigned: HashSet[string]

  DaCtx = object
    config: ConfigRef
    tracked: HashSet[string]     ## the locals and `out` parameters followed
    outs: seq[NsNode]            ## the `out` parameters, checked where control leaves
    reported: HashSet[string]    ## each name is reported once
    breaks: seq[seq[DaState]]    ## per enclosing loop or switch: states at its `break`s

proc reachable(s: DaState): bool = not s.unreachable

proc isAssigned(s: DaState; name: string): bool =
  s.unreachable or name in s.assigned

proc merge(a, b: DaState): DaState =
  ## The state where two paths meet: what both assigned.
  if a.unreachable: return b
  if b.unreachable: return a
  result.assigned = a.assigned * b.assigned

proc dead(): DaState = DaState(unreachable: true)

proc assign(c: DaCtx; s: var DaState; name: string) =
  if name in c.tracked: s.assigned.incl name

proc read(c: var DaCtx; s: DaState; n: NsNode) =
  if n.name in c.tracked and not s.isAssigned(n.name) and n.name notin c.reported:
    c.reported.incl n.name
    nsError(c.config, n.info, ndUnassignedLocal, n.name)

proc expr(c: var DaCtx; n: NsNode; s: var DaState)

proc exprs(c: var DaCtx; ns: seq[NsNode]; s: var DaState) =
  for x in ns: c.expr(x, s)

proc expr(c: var DaCtx; n: NsNode; s: var DaState) =
  ## Evaluates `n` in order: reads are checked against `s`, assignments added.
  if n == nil: return
  case n.kind
  of nsnIdent:
    c.read(s, n)
  of nsnAssign:
    let target = (if n.sons.len > 0: n.sons[0] else: nil)
    if target != nil and target.kind == nsnIdent:
      if n.name.len > 0: c.read(s, target)   # `x += e` reads `x`
      for i in 1 ..< n.sons.len: c.expr(n.sons[i], s)
      c.assign(s, target.name)
    else:
      c.exprs(n.sons, s)
  of nsnRefArg:
    if n.name == "out" and n.body != nil and n.body.kind == nsnIdent:
      c.assign(s, n.body.name)
    else:
      c.expr(n.body, s)
  of nsnNamedArg:
    c.expr(n.body, s)
  of nsnLambda, nsnLocalFunc:
    ## A lambda reads what it captures when it is created; what it assigns is
    ## not known to have happened.
    var inner = s
    if n.body != nil:
      for x in n.body.sons:
        var t = inner
        c.expr(x, t)
  of nsnTernary:
    if n.sons.len == 3:
      c.expr(n.sons[0], s)
      var a = s
      var b = s
      c.expr(n.sons[1], a)
      c.expr(n.sons[2], b)
      s = merge(a, b)
    else: c.exprs(n.sons, s)
  of nsnBinary:
    c.expr(n.sons[0], s)
    if n.name in ["and", "or", "??"] or n.kind == nsnNullCoalesce:
      ## The right operand may not run: what it assigns does not count.
      var r = s
      c.expr(n.sons[1], r)
    else:
      c.expr(n.sons[1], s)
  of nsnNullCoalesce:
    if n.sons.len == 2:
      c.expr(n.sons[0], s)
      var r = s
      c.expr(n.sons[1], r)
  else:
    c.expr(n.body, s)
    c.exprs(n.sons, s)
    c.exprs(n.initArgs, s)
    c.exprs(n.inits, s)

proc stmt(c: var DaCtx; n: NsNode; s: var DaState)

proc stmts(c: var DaCtx; ns: seq[NsNode]; s: var DaState) =
  for x in ns: c.stmt(x, s)

proc leave(c: var DaCtx; s: DaState; info: TLineInfo) =
  ## Control leaves the method: every `out` parameter must be assigned (CS0177).
  if s.unreachable: return
  for p in c.outs:
    if p.name notin s.assigned and ("out:" & p.name) notin c.reported:
      c.reported.incl("out:" & p.name)
      nsError(c.config, info, ndOutUnassigned, p.name)

proc isTrue(n: NsNode): bool = n != nil and n.kind == nsnBoolLit and n.intVal == 1

proc loop(c: var DaCtx; body: seq[NsNode]; s: var DaState; forever: bool) =
  ## A loop body starts from the state before it, and its assignments do not
  ## count after it; a loop that never ends by its condition leaves only by
  ## `break`.
  c.breaks.add @[]
  var inner = s
  c.stmts(body, inner)
  let bs = c.breaks.pop()
  if forever:
    var after = dead()
    for b in bs: after = merge(after, b)
    s = after

proc stmt(c: var DaCtx; n: NsNode; s: var DaState) =
  if n == nil: return
  case n.kind
  of nsnLocalDecl:
    if n.body != nil:
      c.expr(n.body, s)
    elif n.paramMod != "ref":
      c.tracked.incl n.name
      s.assigned.excl n.name
  of nsnMultiDecl:
    c.stmts(n.sons, s)
  of nsnExprStmt:
    c.expr(n.body, s)
  of nsnAssign:
    c.expr(n, s)
  of nsnBlock, nsnBlockStmt, nsnChecked, nsnUnchecked:
    c.stmts(n.sons, s)
  of nsnLock:
    c.expr(n.body, s)
    c.stmts(n.sons, s)
  of nsnUsingStmt:
    c.stmts(n.sons, s)
    if n.body != nil: c.stmt(n.body, s)
  of nsnIf:
    var rest = s
    var after = dead()
    var hasElse = false
    for b in n.sons:
      if b.kind == nsnIfBranch:
        c.expr(b.body, rest)
        var branch = rest
        c.stmts(b.sons, branch)
        after = merge(after, branch)
        if isTrue(b.body):
          rest = dead()
          hasElse = true
          break
      else:
        hasElse = true
        var branch = rest
        if b.kind == nsnElseBranch: c.stmt(b.body, branch) else: c.stmts(b.sons, branch)
        after = merge(after, branch)
    s = (if hasElse: after else: merge(after, rest))
  of nsnWhile:
    c.expr(n.body, s)
    c.loop(n.sons, s, isTrue(n.body))
  of nsnDoWhile:
    ## The body runs once before the condition is tested.
    c.breaks.add @[]
    var inner = s
    c.stmts(n.sons, inner)
    var bs = c.breaks.pop()
    c.expr(n.body, inner)
    var after = (if isTrue(n.body): dead() else: inner)
    for b in bs: after = merge(after, b)
    s = after
  of nsnFor:
    let h = n.body
    var cond: NsNode = nil
    if h != nil and h.sons.len > 0: c.stmt(h.sons[0], s)
    if h != nil and h.sons.len > 1:
      cond = h.sons[1]
      c.expr(cond, s)
    let forever = cond == nil or cond.kind == nsnEmpty or isTrue(cond)
    c.loop(n.sons, s, forever)
  of nsnForeach:
    c.expr(n.body, s)
    c.loop(n.sons, s, false)
  of nsnSwitch:
    c.expr(n.body, s)
    c.breaks.add @[]
    var after = dead()
    var hasDefault = false
    for sec in n.sons:
      if sec.name == "default": hasDefault = true
      var t = s
      if sec.body != nil: c.stmts(sec.body.sons, t)
      after = merge(after, t)
    for b in c.breaks.pop(): after = merge(after, b)
    s = (if hasDefault: after else: merge(after, s))
  of nsnTry:
    let entry = s
    var after = dead()
    var fin: NsNode = nil
    for i, x in n.sons:
      if x.kind == nsnFinally: fin = x
      elif x.kind == nsnCatch:
        var t = entry
        c.stmt(x.body, t)
        after = merge(after, t)
      elif i == 0:
        var t = entry
        c.stmt(x, t)
        after = merge(after, t)
    if fin != nil and fin.body != nil:
      var t = entry
      c.stmt(fin.body, t)
      if t.unreachable: after = dead()
      elif not after.unreachable: after.assigned = after.assigned + t.assigned
    s = after
  of nsnReturn:
    c.expr(n.body, s)
    c.leave(s, n.info)
    s = dead()
  of nsnThrow:
    c.expr(n.body, s)
    s = dead()
  of nsnBreak:
    if c.breaks.len > 0: c.breaks[^1].add s
    s = dead()
  of nsnContinue:
    s = dead()
  of nsnYield:
    c.expr(n.body, s)
    if n.name == "break": s = dead()
  of nsnLocalFunc:
    discard
  else:
    c.expr(n.body, s)
    c.exprs(n.sons, s)

proc checkDefiniteAssignment*(config: ConfigRef; params: seq[NsNode]; body: NsNode) =
  ## One member body: CS0165 for a read before assignment, CS0177 for an `out`
  ## parameter left unassigned.
  if body == nil or body.kind != nsnBlock: return
  var c = DaCtx(config: config)
  var s = DaState()
  for p in params:
    if p.paramMod == "out":
      c.tracked.incl p.name
      c.outs.add p
  c.stmts(body.sons, s)
  c.leave(s, body.info)
