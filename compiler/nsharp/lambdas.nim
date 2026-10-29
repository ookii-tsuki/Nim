# N# frontend - lambda typing
#
# C# types a lambda's parameters from the delegate it converts to: a declared
# local's type, an assignment's target, or the parameter of the method it is passed
# to -- with that method's and its class's type arguments substituted, the method's
# inferred from the other arguments when they are not written. Nim infers a lambda's
# types only when nothing about them is generic, so `sema.nim` works the signature
# out here and writes it on the lambda, and lowering emits a fully typed closure.
#
# A delegate this compilation declares has a C# signature; one the library declares
# (`Func<T, R>`, `Predicate<T>`) has a Nim one, read from the prelude, which is turned
# back into C# type nodes; a library member's parameter types are Nim as well, and
# their generic parameters are bound by unifying with the receiver's type.

import std/[tables, strutils]
import ../ast as nimast
import ast, bcl, numeric, symbols

type
  NsSig* = object
    ## A delegate's signature as C# type nodes; `known` is false when there is none.
    known*: bool
    params*: seq[NsNode]
    ret*: NsNode

proc lambdaResult*(lam: NsNode): NsNode
  ## The type a lambda yields; see its body below.

proc nimToCs*(t: PNode; names: seq[string]; args: seq[NsNode];
             info: NsNode): NsNode =
  ## A Nim type from the prelude as a C# type node, its generic parameters replaced.
  if t == nil or t.kind == nkEmpty: return nsnVoidType(info.info)
  if t.kind in {nkCommand, nkBracketExpr, nkPrefix} and t.len == 2 and
     t[0].kind == nkIdent and t[0].ident.s == "sink":
    ## `sink T` moves the argument in; C# sees a `T`.
    return nimToCs(t[1], names, args, info)
  case t.kind
  of nkIdent:
    let s = t.ident.s
    let k = names.find(s)
    if k >= 0 and k < args.len: return args[k]
    ## A declaration's `float` is Nim's, 64 bits: C#'s `double`.
    let num = (if s == "float": "double" else: numericOfSpelling(s))
    result = nsnTypeName((if num.len > 0: num else: s), info.info)
  of nkBracketExpr:
    if t[0].kind != nkIdent: return nil
    let head = t[0].ident.s
    if head in ["seq", "openArray", "varargs", "NsArray"] and t.len == 2:
      return nsnArrayType(nimToCs(t[1], names, args, info), info.info)
    result = nsnTypeName(head, info.info)
    for i in 1 ..< t.len: result.add nimToCs(t[i], names, args, info)
  of nkVarTy:
    result = (if t.len > 0: nimToCs(t[0], names, args, info) else: nil)
  of nkRefTy:
    ## `ref Exception`: how the library holds a C# exception, which C# names
    ## without the `ref`.
    result = (if t.len > 0: nimToCs(t[0], names, args, info) else: nil)
  else: result = nil

proc libSig(surface: NsBclSurface; name: string; args: seq[NsNode];
            info: NsNode): NsSig =
  ## The signature of a delegate the library declares; a name C# overloads by arity
  ## (`Func`) is declared with its argument count as a suffix.
  result = NsSig()
  var t: NsBclType
  if surface.types.hasKey(name & $args.len) and
     surface.types[name & $args.len].sig != nil:
    t = surface.types[name & $args.len]
  elif surface.types.hasKey(name) and surface.types[name].sig != nil:
    t = surface.types[name]
  else: return
  let fp = t.sig
  result.known = true
  result.ret = nimToCs(fp[0], t.genParams, args, info)
  for i in 1 ..< fp.len:
    let defs = fp[i]
    if defs.kind != nkIdentDefs: continue
    for k in 0 ..< defs.len - 2:
      result.params.add nimToCs(defs[defs.len - 2], t.genParams, args, info)

proc delegateSig*(scope: NsModuleScope; surface: NsBclSurface; t: NsNode): NsSig =
  ## The signature of a C# delegate type.
  result = NsSig()
  if t == nil or t.kind != nsnTypeName: return
  let name = canonicalTypeName(t.name)
  if scope.delegates.hasKey(name):
    let d = scope.delegates[name]
    var tps: seq[string] = @[]
    for tp in d.typeParams: tps.add tp.name
    result.known = true
    result.ret = substitute(d.typ, tps, t.sons)
    for p in d.params: result.params.add substitute(p.typ, tps, t.sons)
    return
  result = libSig(surface, nimTypeName(name), t.sons, t)

proc unify(pt, at: NsNode; tps: seq[string]; binding: var seq[NsNode]) =
  ## Infers type arguments by matching a declared type against an argument's type.
  if pt == nil or at == nil: return
  if pt.kind == nsnTypeName and pt.sons.len == 0:
    let k = tps.find(pt.name)
    if k >= 0 and binding[k] == nil: binding[k] = at
    return
  if pt.kind == nsnTypeName and at.kind == nsnTypeName and
     canonicalTypeName(pt.name) == canonicalTypeName(at.name) and
     pt.sons.len == at.sons.len:
    for i in 0 ..< pt.sons.len: unify(pt.sons[i], at.sons[i], tps, binding)
  elif pt.kind == nsnArrayType and at.kind == nsnArrayType:
    unify(pt.typ, at.typ, tps, binding)

proc sameShape(a, b: PNode): bool =
  ## Whether two written types are the same text: kinds and identifiers alike.
  if a == nil or b == nil: return a == b
  if a.kind != b.kind or a.safeLen != b.safeLen: return false
  if a.kind == nkIdent: return a.ident.s == b.ident.s
  for i in 0 ..< a.safeLen:
    if not sameShape(a[i], b[i]): return false
  true

proc substNim(t: PNode; names: seq[string]; by: seq[PNode]): PNode =
  ## `t` with the identifiers in `names` replaced by `by`'s types.
  if t == nil: return nil
  if t.kind == nkIdent:
    let k = names.find(t.ident.s)
    if k >= 0 and k < by.len: return copyTree(by[k])
    return t
  result = copyNode(t)
  for i in 0 ..< t.safeLen: result.add substNim(t[i], names, by)

proc unifyNim(pt: PNode; at: NsNode; names: seq[string]; binding: var seq[NsNode])

proc unifyThroughLibrary(pt: PNode; at: NsNode; names: seq[string];
                         binding: var seq[NsNode]): bool =
  ## `NsEnumerable[T]` against `List<int>`: through the alternative of the type
  ## class that `at` is; `List<T>`'s declared base, when `pt` names that. True when
  ## one of them applied.
  let head = pt[0].ident.s
  if nsLibraryTypes.hasKey(head) and nsLibraryTypes[head].union.len > 0:
    let u = nsLibraryTypes[head]
    var args: seq[PNode] = @[]
    for i in 1 ..< pt.len: args.add pt[i]
    for alt in u.union:
      let a = substNim(alt, u.genParams, args)
      if a.kind == nkBracketExpr and a[0].kind == nkIdent and
         (at.kind == nsnArrayType and a[0].ident.s in ["seq", "NsArray"] or
          at.kind == nsnTypeName and a[0].ident.s == nimTypeName(at.name)):
        unifyNim(a, at, names, binding)
        return true
      if a.kind == nkBracketExpr and a[0].kind == nkIdent and a[0].ident.s != head and
         nsLibraryTypes.hasKey(a[0].ident.s) and nsLibraryTypes[a[0].ident.s].union.len > 0 and
         unifyThroughLibrary(a, at, names, binding):
        ## A type class among the alternatives (`NsEnumerable[T]`).
        return true
  ## `at` is a library type deriving the one `pt` names (`IGrouping<K, T>` is an
  ## `IGroupingBase<T>`): its base, with its own type arguments put in.
  if at.kind == nsnTypeName and nsLibraryTypes.hasKey(nimTypeName(at.name)):
    let t = nsLibraryTypes[nimTypeName(at.name)]
    if t.baseNode != nil and t.genParams.len == at.sons.len:
      let b = nimToCs(t.baseNode, t.genParams, at.sons, at)
      if b != nil and b.kind == nsnTypeName and b.name != at.name:
        unifyNim(pt, b, names, binding)
        return true
  false

proc unifyNim(pt: PNode; at: NsNode; names: seq[string]; binding: var seq[NsNode]) =
  ## The same, for a library declaration's Nim parameter type.
  if pt != nil and pt.kind in {nkCommand, nkBracketExpr, nkPrefix} and pt.len == 2 and
     pt[0].kind == nkIdent and pt[0].ident.s == "sink":
    unifyNim(pt[1], at, names, binding)
    return
  if pt == nil or at == nil: return
  case pt.kind
  of nkVarTy, nkPtrTy, nkRefTy:
    if pt.len > 0: unifyNim(pt[0], at, names, binding)
  of nkIdent:
    let k = names.find(pt.ident.s)
    if k >= 0 and binding[k] == nil: binding[k] = at
  of nkBracketExpr:
    if at.kind == nsnTypeName and pt[0].kind == nkIdent and
       pt[0].ident.s == nimTypeName(at.name) and pt.len - 1 == at.sons.len:
      for i in 1 ..< pt.len: unifyNim(pt[i], at.sons[i - 1], names, binding)
    elif at.kind == nsnArrayType and pt[0].kind == nkIdent and
         pt[0].ident.s in ["seq", "openArray", "varargs", "NsArray"] and pt.len == 2:
      unifyNim(pt[1], at.typ, names, binding)
    elif pt[0].kind == nkIdent:
      discard unifyThroughLibrary(pt, at, names, binding)
  else: discard

proc valueType*(v: NsNode): NsNode =
  ## The type of a value, as a type node, when the frontend knows it.
  if v == nil: return nil
  if v.rtype != nil: return v.rtype
  if v.kind == nsnIntLit: return nsnTypeName((if v.typeName.len > 0: v.typeName
                                              else: "int"), v.info)
  if v.kind == nsnFloatLit: return nsnTypeName((if v.typeName.len > 0: v.typeName
                                                else: "double"), v.info)
  if v.kind == nsnStrLit: return nsnTypeName("string", v.info)
  if v.typeName.len > 0 and v.typeKind notin {tkType, tkSequence, tkNullable}:
    return nsnTypeName(v.typeName, v.info)
  nil

proc argOf(a: NsNode): NsNode =
  if a != nil and a.kind == nsnNamedArg: a.body else: a

proc isLambda(a: NsNode): bool =
  let v = argOf(a)
  v != nil and v.kind == nsnLambda

type NsUserBinding = object
  ## The type arguments a call of a method this compilation declares binds: its own
  ## type parameters (`tps`), and its class's, which the receiver gives.
  tps, ownerTps: seq[string]
  ownerArgs, binding: seq[NsNode]

proc userBinding(scope: NsModuleScope; surface: NsBclSurface; call: NsNode): NsUserBinding =
  ## What the arguments bind: the written type arguments, the values', and the
  ## results of the lambdas sema has walked.
  let callee = call.body
  let recv = (if callee != nil and callee.kind == nsnMember: callee.body else: nil)
  # a method this compilation declares: sema recorded the parameter each argument fills
  var tps: seq[string] = @[]
  var ownerTps: seq[string] = @[]
  var ownerArgs: seq[NsNode] = @[]
  if recv != nil:
    let owner = recv.typeName
    let info = scope.findMemberInfo(owner, callee.name)
    if info.name.len > 0:
      tps = info.typeParams
      if scope.classes.hasKey(info.owner):
        ownerTps = scope.classes[info.owner].typeParams
        if recv.typeKind == tkType: ownerArgs = recv.typeArgs
        elif recv.rtype != nil and recv.rtype.kind == nsnTypeName:
          ownerArgs = recv.rtype.sons
  var binding = newSeq[NsNode](tps.len)
  if callee != nil and callee.typeArgs.len == tps.len:
    for i in 0 ..< tps.len: binding[i] = callee.typeArgs[i]
  for a in call.sons:
    let v = argOf(a)
    if a.argParam != nil and not isLambda(a):
      unify(a.argParam.typ, valueType(v), tps, binding)
  ## A lambda sema has walked binds what its delegate's result names (`T(() => 42)`
  ## binds `R` to `int`); sema asks again once the bodies are walked. Several results
  ## for one parameter take the widest (`Pick(() => 1, () => 2.5)` is a `double`).
  for a in call.sons:
    if not isLambda(a) or a.argParam == nil: continue
    let lam = argOf(a)
    if lam.kind == nsnLambda and lam.typeKind != tkDelegate: continue
    var pt = a.argParam.typ
    if a.argElement and pt != nil and pt.kind == nsnArrayType: pt = pt.typ
    let raw = delegateSig(scope, surface, substitute(pt, ownerTps, ownerArgs))
    if not raw.known or raw.ret == nil: continue
    let lr = lambdaResult(lam)
    let k = (if raw.ret.kind == nsnTypeName and raw.ret.sons.len == 0: tps.find(raw.ret.name)
             else: -1)
    if k >= 0 and lr != nil and binding[k] != nil and binding[k].kind == nsnTypeName and
       lr.kind == nsnTypeName:
      let was = numericOfSpelling(canonicalTypeName(binding[k].name))
      let now = numericOfSpelling(canonicalTypeName(lr.name))
      if was.len > 0 and now.len > 0 and was != now and implicitlyConvertible(was, now):
        binding[k] = lr
    else:
      unify(raw.ret, lr, tps, binding)
  NsUserBinding(tps: tps, ownerTps: ownerTps, ownerArgs: ownerArgs, binding: binding)

proc inferredDelegateTypes*(scope: NsModuleScope; surface: NsBclSurface;
                            call: NsNode): seq[NsNode] =
  ## For each lambda argument of a call of a generic method this compilation
  ## declares, the delegate type it fills with every type argument bound; none when
  ## one is not. Nim cannot infer through two uses of one generic delegate
  ## (`Compose(a, f, g)`), so lowering converts each lambda to its type.
  if call.body == nil or call.body.kind != nsnMember: return
  let ub = userBinding(scope, surface, call)
  if ub.tps.len == 0: return
  for b in ub.binding:
    if b == nil or b.kind notin {nsnTypeName, nsnArrayType} or
       (b.kind == nsnTypeName and b.name.startsWith("$")): return
  result = newSeq[NsNode](call.sons.len)
  for j, a in call.sons:
    if not isLambda(a) or a.argParam == nil: continue
    var pt = a.argParam.typ
    if a.argElement and pt != nil and pt.kind == nsnArrayType: pt = pt.typ
    result[j] = substitute(substitute(pt, ub.ownerTps, ub.ownerArgs), ub.tps, ub.binding)

proc callLambdaSigs*(scope: NsModuleScope; surface: NsBclSurface;
                     call: NsNode): seq[NsSig] =
  ## For each argument of a call, the signature a lambda passed there takes.
  result = newSeq[NsSig](call.sons.len)
  var needed = false
  for a in call.sons:
    if isLambda(a): needed = true
  if not needed: return
  let callee = call.body
  let recv = (if callee != nil and callee.kind == nsnMember: callee.body else: nil)
  let ub = userBinding(scope, surface, call)
  let tps = ub.tps
  let ownerTps = ub.ownerTps
  let ownerArgs = ub.ownerArgs
  let binding = ub.binding
  var bound: seq[string] = @[]
  var boundTo: seq[NsNode] = @[]
  var open: seq[string] = @[]
  for i, b in binding:
    if b != nil:
      bound.add tps[i]
      boundTo.add b
    else: open.add tps[i]
  proc mentions(t: NsNode; names: seq[string]): bool =
    if t == nil or names.len == 0: return false
    if t.kind == nsnTypeName and t.sons.len == 0 and t.name in names: return true
    if mentions(t.typ, names): return true
    for x in t.sons:
      if mentions(x, names): return true
    false
  var anyParam = false
  for j, a in call.sons:
    if not isLambda(a) or a.argParam == nil: continue
    anyParam = true
    var pt = a.argParam.typ
    if a.argElement and pt != nil and pt.kind == nsnArrayType: pt = pt.typ
    pt = substitute(pt, ownerTps, ownerArgs)
    pt = substitute(pt, bound, boundTo)
    result[j] = delegateSig(scope, surface, pt)
    ## A type the arguments have not bound yet is left for the lambda to say.
    for p in result[j].params.mitems:
      if mentions(p, open): p = nil
    if mentions(result[j].ret, open): result[j].ret = nil
  if anyParam or recv == nil: return
  if recv.typeKind == tkType:
    ## A static library member (`Array.Sort(xs, (a, b) => ...)`): its parameters are
    ## the arguments, the generic ones bound by those that are not lambdas.
    let owner = unqualified(recv.typeName)
    for m in surface.overloads(owner, surface.kindOfName(owner), callee.name):
      if not m.isStatic: continue
      ## A member over the type (`Comparer<int>.Create(f)`) takes the type first, and
      ## the qualifier's type arguments bind its parameters.
      var off = 0
      var nb = newSeq[NsNode](m.genParams.len)
      if m.paramTypes.len == call.sons.len + 1 and m.paramTypes[0].kind == nkBracketExpr and
         m.paramTypes[0].len == 2 and m.paramTypes[0][0].kind == nkIdent and
         m.paramTypes[0][0].ident.s == "typedesc":
        off = 1
        let q = nsnTypeName(recv.typeName, recv.info)
        q.sons = recv.typeArgs
        unifyNim(m.paramTypes[0][1], q, m.genParams, nb)
      elif m.paramTypes.len != call.sons.len: continue
      for j, a in call.sons:
        if not isLambda(a):
          unifyNim(m.paramTypes[j + off], valueType(argOf(a)), m.genParams, nb)
      var ok = true
      for b in nb:
        if b == nil: ok = false
      if not ok: continue
      var typed = false
      for j, a in call.sons:
        if isLambda(a):
          let pt = nimToCs(m.paramTypes[j + off], m.genParams, nb, a)
          if pt != nil and pt.kind == nsnTypeName:
            result[j] = libSig(surface, pt.name, pt.sons, a)
            typed = typed or result[j].known
      if typed: return
    return
  # a library member: its declaration's parameter types, bound by the receiver's
  let rk = recv.typeKind
  var keys: seq[string] = @[]
  let nimName = surface.nimSpellingOf(recv.typeName)
  if nimName.len > 0: keys.add surface.withBases(nimName)
  let kk = kindKey(rk)
  if kk.len > 0: keys.add kk
  for key in keys:
    for m in surface.members.getOrDefault(key):
      if m.name != callee.name or m.paramTypes.len != call.sons.len + 1: continue
      var nb = newSeq[NsNode](m.genParams.len)
      let rt = valueType(recv)
      if rt != nil: unifyNim(m.paramTypes[0], rt, m.genParams, nb)
      if callee.typeArgs.len == m.genParams.len:
        ## `xs.Select<int, object>(f)`: written, every type argument is given.
        for k in 0 ..< nb.len: nb[k] = callee.typeArgs[k]
      for j, a in call.sons:
        if not isLambda(a): unifyNim(m.paramTypes[j + 1], valueType(argOf(a)),
                                     m.genParams, nb)
      ## A parameter only a lambda's result binds (`Select<T, R>`'s `R`) is left
      ## open: the lambda's parameters are what it needs, and its body says the rest.
      var bound = nb
      for k in 0 ..< bound.len:
        if bound[k] == nil: bound[k] = nsnTypeName("$" & m.genParams[k], callee.info)
      var typed = false
      var fits = true
      var sigs = newSeq[NsSig](call.sons.len)
      for j, a in call.sons:
        if isLambda(a):
          let pt = nimToCs(m.paramTypes[j + 1], m.genParams, bound, a)
          if pt != nil and pt.kind == nsnTypeName:
            var sig = libSig(surface, pt.name, pt.sons, a)
            let lam = argOf(a)
            if sig.known and lam.strVal != "anyParams" and lam.params.len != sig.params.len:
              ## `(n, i) => ...` is the overload whose delegate takes two.
              fits = false
              break
            var open = false
            for p in sig.params:
              if p == nil or (p.kind == nsnTypeName and p.name.startsWith("$")): open = true
            if open: sig.known = false
            elif sig.ret != nil and sig.ret.kind == nsnTypeName and sig.ret.name.startsWith("$"):
              sig.ret = nil
            elif callee.typeArgs.len == m.genParams.len:
              ## Written, the type arguments say the result (`Select<int, object>`).
              discard
            else:
              ## Overloads of this arity whose delegates differ (`Sum`'s `Func<T, int>`
              ## and `Func<T, double>`): the lambda's body says which, not the first.
              for o in surface.members.getOrDefault(key):
                if o.name == m.name and o.paramTypes.len == m.paramTypes.len and
                   not sameShape(o.paramTypes[j + 1], m.paramTypes[j + 1]):
                  sig.ret = nil
                  break
            sigs[j] = sig
            typed = typed or sig.known
      if not fits: continue
      for j in 0 ..< sigs.len:
        if sigs[j].known: result[j] = sigs[j]
      if typed: return

proc applySig*(lam: NsNode; sig: NsSig) =
  ## Writes a signature on a lambda's untyped parameters and its result.
  if lam == nil or lam.kind != nsnLambda or not sig.known: return
  if lam.strVal == "anyParams" and lam.params.len == 0:
    ## `delegate { ... }` takes whatever parameters its delegate has, unnamed.
    for i, t in sig.params:
      lam.addParam nsnParam("nsUnused" & $i, t, lam.info)
  for i, p in lam.params:
    if p.typ == nil and i < sig.params.len: p.typ = sig.params[i]
  if lam.typ == nil: lam.typ = sig.ret

proc libResultType*(surface: NsBclSurface; recv: NsNode; name: string;
                    nargs: int): NsNode =
  ## The result type of a library member on a receiver of a known generic type
  ## (`dict[k]` is the dictionary's `V`), its generic parameters bound by the
  ## receiver's type arguments; nil when the library does not say.
  if recv == nil or recv.rtype == nil or recv.rtype.kind != nsnTypeName: return nil
  let rt = recv.rtype
  let nimName = surface.nimSpellingOf(rt.name)
  if nimName.len == 0: return nil
  for m in surface.members.getOrDefault(nimName):
    if m.name != name or m.paramTypes.len != nargs + 1 or m.ret.len == 0: continue
    var nb = newSeq[NsNode](m.genParams.len)
    unifyNim(m.paramTypes[0], rt, m.genParams, nb)
    var ok = true
    for b in nb:
      if b == nil: ok = false
    if not ok: continue
    if m.genParams.find(m.ret) >= 0: return nb[m.genParams.find(m.ret)]
    return nil
  nil

proc libIterElement*(surface: NsBclSurface; coll: NsNode): NsNode
proc unifyDelegateResult(surface: NsBclSurface; pt: PNode; lam: NsNode;
                         names: seq[string]; binding: var seq[NsNode])

proc delegateResultFits(surface: NsBclSurface; pt: PNode; lam: NsNode;
                        genParams: seq[string]): bool =
  ## Whether a lambda fits a delegate parameter's declared result: any when that is
  ## one of the declaration's parameters, else the same type (`Func<T, int>`).
  if pt == nil or pt.kind != nkBracketExpr or pt[0].kind != nkIdent: return true
  let head = pt[0].ident.s
  if not surface.types.hasKey(head) or surface.types[head].sig == nil: return true
  let t = surface.types[head]
  let ret = t.sig[0]
  if ret == nil or ret.kind != nkIdent: return true
  let k = t.genParams.find(ret.ident.s)
  if k < 0 or k + 1 >= pt.len: return true
  let want = pt[k + 1]
  if want.kind == nkIdent and genParams.find(want.ident.s) >= 0: return true
  let lr = lambdaResult(lam)
  if lr == nil or lr.kind != nsnTypeName: return false
  let cs = nimToCs(want, genParams, @[], lam)
  cs != nil and cs.kind == nsnTypeName and canonicalTypeName(cs.name) == canonicalTypeName(lr.name)

proc libInstanceResult*(surface: NsBclSurface; recv: NsNode; name: string;
                        nargs: int; args: seq[NsNode] = @[]): tuple[typ: NsNode, isParam: bool] =
  ## The result of the library overload a call on `recv` takes when its overloads
  ## differ by their source's element type (`Sum` of an `int[]` is `int Sum(
  ## IEnumerable<int>)`'s, of a `double[]` the `double` one's): of those taking this
  ## many arguments, the first whose source's element type is the receiver's, a
  ## generic one taking any. `isParam` says the result is a type parameter's.
  result = (typ: nil, isParam: false)
  if recv == nil or recv.rtype == nil: return
  let rt = recv.rtype
  let elem = (if rt.kind == nsnArrayType: rt.typ else: libIterElement(surface, recv))
  if elem == nil or elem.kind != nsnTypeName: return
  let nimName = (if rt.kind == nsnArrayType: surface.nimSpellingOf("[]")
                 elif rt.kind == nsnTypeName: surface.nimSpellingOf(rt.name) else: "")
  if nimName.len == 0: return
  var generic: NsBclMember
  var exact: NsBclMember
  for key in surface.withBases(nimName):
    for m in surface.members.getOrDefault(key):
      ## A member of the receiver's own type wins over an extension method, as in
      ## C# (`list.Reverse()` is `List<T>.Reverse`).
      if m.name == name and m.paramTypes.len == nargs + 1 and not m.viaUnion: return
  for key in surface.withBases(nimName):
    for m in surface.members.getOrDefault(key):
      if m.name != name or m.paramTypes.len != nargs + 1 or m.retType == nil: continue
      var lambdasFit = true
      for j, a in args:
        let v = argOf(a)
        if v != nil and v.kind == nsnLambda and j + 1 < m.paramTypes.len and
           not delegateResultFits(surface, m.paramTypes[j + 1], v, m.genParams):
          lambdasFit = false
      if not lambdasFit: continue
      let p0 = m.paramTypes[0]
      if p0.kind != nkBracketExpr or p0.len != 2: continue
      let pe = p0[1]
      if pe.kind == nkIdent and m.genParams.find(pe.ident.s) >= 0:
        if generic.name.len == 0: generic = m
      else:
        let cs = nimToCs(pe, m.genParams, @[], recv)
        if cs != nil and cs.kind == nsnTypeName and
           canonicalTypeName(cs.name) == canonicalTypeName(elem.name) and exact.name.len == 0:
          exact = m
  let m = (if exact.name.len > 0: exact else: generic)
  if m.name.len == 0: return
  var nb = newSeq[NsNode](m.genParams.len)
  unifyNim(m.paramTypes[0], rt, m.genParams, nb)
  for j, a in args:
    let v = argOf(a)
    if v != nil and v.kind == nsnLambda and j + 1 < m.paramTypes.len:
      unifyDelegateResult(surface, m.paramTypes[j + 1], v, m.genParams, nb)
  let isParam = m.retType.kind == nkIdent and m.genParams.find(m.retType.ident.s) >= 0
  for b in nb:
    if b == nil and isParam: return
  let t = nimToCs(m.retType, m.genParams, nb, recv)
  if t != nil and not (t.kind == nsnTypeName and t.name.startsWith("$")):
    ## A number-constrained result is a concrete overload's, of a number only.
    if m.retNumeric and not (t.kind == nsnTypeName and isNumericName(canonicalTypeName(t.name))):
      return
    result = (typ: t, isParam: isParam and not m.retNumeric)

proc returnedType(n: NsNode): NsNode =
  ## The type of the first `return e` of a body whose type is known, not looking
  ## into a nested lambda or local function, whose returns are their own.
  if n == nil or n.kind in {nsnLambda, nsnLocalFunc}: return nil
  if n.kind == nsnReturn: return (if n.body != nil: valueType(n.body) else: nil)
  for s in n.sons:
    let t = returnedType(s)
    if t != nil: return t
  returnedType(n.body)

proc lambdaResult*(lam: NsNode): NsNode =
  ## The type a lambda's body yields, when the frontend knows it: its declared
  ## result, an expression body's type, or what a block body returns.
  if lam == nil or lam.kind != nsnLambda: return nil
  if lam.typ != nil and lam.typ.kind == nsnTypeName: return lam.typ
  let b = lam.body
  if b != nil and b.strVal == "expr" and b.sons.len == 1: return valueType(b.sons[0])
  returnedType(b)

proc unifyDelegateResult(surface: NsBclSurface; pt: PNode; lam: NsNode;
                         names: seq[string]; binding: var seq[NsNode]) =
  ## Binds the parameter a delegate parameter's result names (`R` of `Func<T, R>`)
  ## to what the lambda passed for it yields.
  if pt == nil or pt.kind != nkBracketExpr or pt[0].kind != nkIdent: return
  let lr = lambdaResult(lam)
  if lr == nil: return
  let head = pt[0].ident.s
  if not surface.types.hasKey(head) or surface.types[head].sig == nil: return
  let t = surface.types[head]
  let ret = t.sig[0]
  if ret == nil or ret.kind != nkIdent: return
  let k = t.genParams.find(ret.ident.s)
  if k >= 0 and k + 1 < pt.len: unifyNim(pt[k + 1], lr, names, binding)

proc libGenericResult*(surface: NsBclSurface; recv: NsNode; name: string;
                       nargs: int; args: seq[NsNode] = @[]): NsNode =
  ## The result type of a library member that is itself a generic type
  ## (`d.Keys` is a `KeyCollection<K, V>`, `xs.Where(f)` an `IEnumerable<T>`), its
  ## parameters bound by the receiver's type arguments, and by the arguments when
  ## they are given (`xs.Select(x => "n" + x)` is an `IEnumerable<string>`); nil
  ## when any stays open.
  if recv == nil: return nil
  ## A receiver typed by name alone (a literal, a library call's result): its name.
  let rt = (if recv.rtype != nil: recv.rtype
            elif recv.typeName.len > 0 and not recv.typeName.endsWith("[]"):
              nsnTypeName(recv.typeName, recv.info)
            elif recv.typeKind == tkString: nsnTypeName("string", recv.info)
            else: nil)
  if rt == nil or rt.kind notin {nsnTypeName, nsnArrayType}: return nil
  let nimName = (if rt.kind == nsnArrayType: surface.nimSpellingOf("[]")
                 else: surface.nimSpellingOf(rt.name))
  if nimName.len == 0: return nil
  for key in surface.withBases(nimName):
    for m in surface.members.getOrDefault(key):
      if m.name != name or m.paramTypes.len != nargs + 1 or m.retType == nil: continue
      ## A generic type (`IEnumerable[T]`), one of the parameters (`Max(): T`), or
      ## a reference to one of the library's types (`Flatten(): ref AggregateException`).
      if m.retType.kind notin {nkBracketExpr, nkRefTy} and
         not (m.retType.kind == nkIdent and m.genParams.find(m.retType.ident.s) >= 0):
        continue
      var nb = newSeq[NsNode](m.genParams.len)
      unifyNim(m.paramTypes[0], rt, m.genParams, nb)
      for j, a in args:
        if j + 1 >= m.paramTypes.len: break
        let v = argOf(a)
        if v != nil and v.kind == nsnLambda:
          unifyDelegateResult(surface, m.paramTypes[j + 1], v, m.genParams, nb)
        else:
          unifyNim(m.paramTypes[j + 1], valueType(v), m.genParams, nb)
      var ok = true
      for b in nb:
        if b == nil: ok = false
      if not ok: continue
      return nimToCs(m.retType, m.genParams, nb, recv)
  nil

proc libIterElement*(surface: NsBclSurface; coll: NsNode): NsNode =
  ## What `foreach` yields over a library collection: the result of the library's
  ## `items` iterator for it, bound by the collection's type arguments.
  if coll == nil or coll.rtype == nil or coll.rtype.kind != nsnTypeName: return nil
  let rt = coll.rtype
  let nimName = surface.nimSpellingOf(rt.name)
  if nimName.len == 0: return nil
  for m in surface.members.getOrDefault(nimName):
    if m.name != "items" or m.paramTypes.len != 1 or m.retType == nil: continue
    var nb = newSeq[NsNode](m.genParams.len)
    unifyNim(m.paramTypes[0], rt, m.genParams, nb)
    var ok = true
    for b in nb:
      if b == nil: ok = false
    if not ok: continue
    return nimToCs(m.retType, m.genParams, nb, coll)
  nil

proc libParams*(m: NsBclMember; recv: NsNode; staticCall: bool; info: NsNode):
    tuple[params: seq[NsNode], variadic: bool] =
  ## The C# parameter types of a library overload after its receiver, its generic
  ## parameters bound from the receiver's type arguments; a parameter whose type
  ## stays unbound is nil, which a check takes as accepting anything.
  result = (params: newSeq[NsNode](), variadic: false)
  var nb = newSeq[NsNode](m.genParams.len)
  var start = 0
  if m.paramTypes.len > 0:
    let p0 = m.paramTypes[0]
    let overType = p0.kind == nkBracketExpr and p0.len > 0 and p0[0].kind == nkIdent and
                   p0[0].ident.s == "typedesc"
    if overType or not staticCall: start = 1
    if not staticCall and recv != nil and recv.rtype != nil:
      unifyNim(p0, recv.rtype, m.genParams, nb)
    elif overType and staticCall and recv != nil and recv.typeName.len > 0 and p0.len == 2:
      ## `int.TryParse(...)` over `typedesc[T]`: the qualifier is `T`.
      unifyNim(p0[1], nsnTypeName(recv.typeName, recv.info), m.genParams, nb)
  ## The method's own type arguments, written (`Enum.Parse<Color>(s)`), bind the
  ## parameters the receiver leaves, in order.
  if info != nil and info.typeArgs.len == nb.len and nb.len > 0:
    ## Every type argument written (`Select<int, object>`, the receiver's included).
    for k in 0 ..< nb.len: nb[k] = info.typeArgs[k]
  elif info != nil and info.typeArgs.len > 0:
    var open: seq[int] = @[]
    for k in 0 ..< nb.len:
      if nb[k] == nil: open.add k
    if open.len == info.typeArgs.len:
      for i, k in open: nb[k] = info.typeArgs[i]
  ## A generic parameter the receiver does not bind is `$T`: the arguments bind it.
  for k in 0 ..< nb.len:
    if nb[k] == nil: nb[k] = nsnTypeName("$" & m.genParams[k], info.info)
  for i in start ..< m.paramTypes.len:
    let t = m.paramTypes[i]
    if i == m.paramTypes.len - 1 and t.kind == nkBracketExpr and t.len >= 2 and
       t[0].kind == nkIdent and t[0].ident.s == "varargs":
      result.variadic = true
      result.params.add nimToCs(t[1], m.genParams, nb, info)
    else:
      result.params.add nimToCs(t, m.genParams, nb, info)
