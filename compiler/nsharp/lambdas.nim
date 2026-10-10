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

import std/tables
import ../ast as nimast
import ast, bcl, numeric, symbols

type
  NsSig* = object
    ## A delegate's signature as C# type nodes; `known` is false when there is none.
    known*: bool
    params*: seq[NsNode]
    ret*: NsNode

proc nimToCs(t: PNode; names: seq[string]; args: seq[NsNode];
             info: NsNode): NsNode =
  ## A Nim type from the prelude as a C# type node, its generic parameters replaced.
  if t == nil or t.kind == nkEmpty: return nsnVoidType(info.info)
  case t.kind
  of nkIdent:
    let s = t.ident.s
    let k = names.find(s)
    if k >= 0 and k < args.len: return args[k]
    let num = numericOfSpelling(s)
    result = nsnTypeName((if num.len > 0: num else: s), info.info)
  of nkBracketExpr:
    if t[0].kind != nkIdent: return nil
    let head = t[0].ident.s
    if head in ["seq", "openArray", "varargs"] and t.len == 2:
      return nsnArrayType(nimToCs(t[1], names, args, info), info.info)
    result = nsnTypeName(head, info.info)
    for i in 1 ..< t.len: result.add nimToCs(t[i], names, args, info)
  of nkVarTy:
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

proc unifyNim(pt: PNode; at: NsNode; names: seq[string]; binding: var seq[NsNode]) =
  ## The same, for a library declaration's Nim parameter type.
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
         pt[0].ident.s in ["seq", "openArray", "varargs"] and pt.len == 2:
      unifyNim(pt[1], at.typ, names, binding)
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
  var anyParam = false
  for j, a in call.sons:
    if not isLambda(a) or a.argParam == nil: continue
    anyParam = true
    var pt = a.argParam.typ
    if a.argElement and pt != nil and pt.kind == nsnArrayType: pt = pt.typ
    pt = substitute(pt, ownerTps, ownerArgs)
    var known = true
    for b in binding:
      if b == nil: known = false
    if known: pt = substitute(pt, tps, binding)
    result[j] = delegateSig(scope, surface, pt)
  if anyParam or recv == nil or recv.typeKind == tkType: return
  # a library member: its declaration's parameter types, bound by the receiver's
  let rk = recv.typeKind
  var keys: seq[string] = @[]
  let nimName = surface.nimSpellingOf(recv.typeName)
  if nimName.len > 0: keys.add nimName
  let kk = kindKey(rk)
  if kk.len > 0: keys.add kk
  for key in keys:
    for m in surface.members.getOrDefault(key):
      if m.name != callee.name or m.paramTypes.len != call.sons.len + 1: continue
      var nb = newSeq[NsNode](m.genParams.len)
      let rt = valueType(recv)
      if rt != nil: unifyNim(m.paramTypes[0], rt, m.genParams, nb)
      for j, a in call.sons:
        if not isLambda(a): unifyNim(m.paramTypes[j + 1], valueType(argOf(a)),
                                     m.genParams, nb)
      var ok = true
      for b in nb:
        if b == nil: ok = false
      if not ok: continue
      for j, a in call.sons:
        if isLambda(a):
          let pt = nimToCs(m.paramTypes[j + 1], m.genParams, nb, a)
          if pt != nil and pt.kind == nsnTypeName:
            let head = pt.name
            var args = pt.sons
            result[j] = libSig(surface, head, args, a)
      return

proc applySig*(lam: NsNode; sig: NsSig) =
  ## Writes a signature on a lambda's untyped parameters and its result.
  if lam == nil or lam.kind != nsnLambda or not sig.known: return
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
