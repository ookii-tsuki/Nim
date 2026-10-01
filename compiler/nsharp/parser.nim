#
#           N# frontend - parser (Phase 0 scaffold)
#
# Parses the subset of `.ns` needed for the Phase-0 acceptance test
# (`nsharp/tests/hello.ns`) and emits an `nkStmtList` of ordinary Nim `PNode`s,
# which the existing `sem` then type-checks. See ../nsharp/ARCHITECTURE.md.
#
# Phase 0 deliberately covers: `using` directives, `namespace` (flattened),
# `class`/`struct` (members lowered to top-level procs), methods, and call
# expression statements. Everything else is skipped tolerantly.

import std/strutils
import std/tables
import ../ast, ../idents, ../lineinfos, ../msgs, ../options
import keywords, lexer

type
  NsParser* = object
    toks: seq[NsToken]
    pos: int
    cache: IdentCache
    config: ConfigRef
    fileIdx: FileIndex
    thisName: string            # "self" in methods, "result" in ctors
    classFields: seq[string]    # enclosing class members (for `x` -> self.x)
    curClass: string            # enclosing class name (for access checks)
    classes: TableRef[string, NsClassInfo]   # module class table (pre-scanned)
    delegates: TableRef[string, PNode]       # named delegate -> nkProcTy
    tmp: int                                 # fresh-parameter-name counter

  NsAccess = enum aPrivate, aProtected, aInternal, aPublic

  NsMemberInfo = object
    name: string
    access: NsAccess

  NsClassInfo = object
    name: string
    base: string
    members: seq[NsMemberInfo]
    ctorArities: seq[int]

  NsMemberKind = enum mkField, mkMethod, mkCtor, mkProperty

  NsMember = object
    kind: NsMemberKind
    isStatic: bool
    isPublic: bool              # exported (access != private)
    access: NsAccess
    name: string
    info: TLineInfo
    typ: PNode
    params: PNode
    body: PNode
    hasGet: bool
    hasSet: bool
    getBody: PNode     # nkEmpty for an auto getter
    setBody: PNode     # nkEmpty for an auto setter
    initKind: string   # ctor initializer: "", "base", or "this"
    initArgs: seq[PNode]

const
  NsModifierWords = ["public", "private", "protected", "internal", "static",
    "virtual", "override", "abstract", "sealed", "readonly", "const", "unsafe",
    "extern", "new"]
  NsTypeModifiers = ["public", "private", "protected", "internal", "abstract",
    "sealed", "static"]

proc peek(p: NsParser): NsToken {.inline.} = p.toks[p.pos]

proc peekAhead(p: NsParser, k: int): NsToken {.inline.} =
  let i = p.pos + k
  if i < p.toks.len: p.toks[i] else: p.toks[^1]

proc advance(p: var NsParser): NsToken {.inline.} =
  result = p.toks[p.pos]
  if p.pos < p.toks.len - 1: inc p.pos

proc at(p: NsParser, k: NsTokenKind): bool {.inline.} = p.peek.kind == k

proc infoOf(p: NsParser, t: NsToken): TLineInfo {.inline.} =
  newLineInfo(p.fileIdx, t.line, t.col)

proc identOf(p: NsParser, s: string, info: TLineInfo): PNode =
  newAtom(p.cache.getIdentExact(s), info)

proc emptyN(info: TLineInfo): PNode {.inline.} = newNodeI(nkEmpty, info)

proc mkProcDef(p: var NsParser, nameNode, params, body: PNode, info: TLineInfo): PNode =
  ## Generated procs are `{.discardable.}`: in C# any expression statement may
  ## drop a method's return value, while Nim rejects an unused result. Void procs
  ## have nothing to discard, so they get no pragma.
  result = newNodeI(nkProcDef, info, 7)
  result[0] = nameNode
  result[1] = emptyN(info)
  result[2] = emptyN(info)
  result[3] = params
  if params.len > 0 and params[0].kind == nkEmpty:
    result[4] = emptyN(info)
  else:
    let pragma = newNodeI(nkPragma, info)
    pragma.add p.identOf("discardable", info)
    result[4] = pragma
  result[5] = emptyN(info)
  result[6] = body

proc chainMemberNames(p: NsParser, clsName: string): seq[string]
proc accessibleFrom(p: NsParser, curClass, member: string): bool

proc err(p: NsParser, t: NsToken, msg: string) =
  localError(p.config, p.infoOf(t), "N# parse error: " & msg)

proc expect(p: var NsParser, k: NsTokenKind): NsToken =
  if p.peek.kind == k: return p.advance
  p.err(p.peek, "expected " & $k & " but got '" & p.peek.text & "'")
  return p.peek

proc skipToSemi(p: var NsParser) =
  while not p.at(nsSemi) and not p.at(nsEof) and not p.at(nsRBrace):
    discard p.advance
  if p.at(nsSemi): discard p.advance

proc builtinTypeName(s: string): string =
  case s
  of "int": "int32"
  of "uint": "uint32"
  of "long": "int64"
  of "ulong": "uint64"
  of "short": "int16"
  of "ushort": "uint16"
  of "byte": "uint8"
  of "sbyte": "int8"
  of "float": "float32"
  of "double": "float64"
  of "bool": "bool"
  of "char": "char"
  of "string": "string"
  of "object": "RootRef"
  of "Exception": "CatchableError"
  else: s

proc isExceptionBase(s: string): bool =
  case s
  of "Exception", "CatchableError", "SystemException", "ArgumentException",
     "InvalidOperationException", "NullReferenceException", "OverflowException",
     "IndexOutOfRangeException", "KeyNotFoundException", "NotSupportedException":
    true
  else:
    false

proc expectGt(p: var NsParser) =
  ## Consumes the `>` that closes a generic argument list. The `>>` token (from
  ## nested generics such as `List<List<int>>`) is split into two `>` in place.
  if p.at(nsGt):
    discard p.advance
  elif p.at(nsShr):
    let t = p.peek
    p.toks[p.pos] = NsToken(kind: nsGt, text: ">", line: t.line, col: t.col + 1)
  else:
    discard p.expect(nsGt)

proc atGtClose(p: NsParser): bool {.inline.} = p.at(nsGt) or p.at(nsShr)

proc parseType(p: var NsParser): PNode =
  ## Parses a type reference. `void` yields `nkEmpty` (caller treats as no
  ## return type). `T[]` maps to `seq[T]`; `Name<...>` becomes `Name[...]` so a
  ## C# generic type application reaches Nim's own generics unchanged.
  let t = p.peek
  if t.kind != nsIdent:
    return emptyN(p.infoOf(t))
  discard p.advance
  if t.text == "void":
    return emptyN(p.infoOf(t))
  var base = p.identOf(builtinTypeName(t.text), p.infoOf(t))
  if p.at(nsLt):
    discard p.advance
    let be = newNodeI(nkBracketExpr, p.infoOf(t))
    be.add base
    while not atGtClose(p) and not p.at(nsEof):
      be.add p.parseType()
      if p.at(nsComma): discard p.advance else: break
    p.expectGt()
    base = be
  while p.at(nsLBracket) and p.peekAhead(1).kind == nsRBracket:
    discard p.advance
    discard p.advance
    base = newTree(nkBracketExpr, p.infoOf(t), p.identOf("seq", p.infoOf(t)), base)
  result = base

proc parseExpr(p: var NsParser): PNode
proc parseStatement(p: var NsParser): PNode
proc parseBlock(p: var NsParser): PNode
proc parseNew(p: var NsParser, kw: NsToken): PNode

proc looksLikeLambda(p: NsParser): bool =
  ## `x =>` or `( ... ) =>` (a parenthesised group immediately followed by `=>`).
  if p.peek.kind == nsIdent and p.peekAhead(1).kind == nsArrow:
    return true
  if p.peek.kind == nsLParen:
    var depth = 0
    var k = 0
    while k < 500:
      let t = p.peekAhead(k)
      if t.kind == nsEof: return false
      if t.kind == nsLParen: inc depth
      elif t.kind == nsRParen:
        dec depth
        if depth == 0: return p.peekAhead(k + 1).kind == nsArrow
      inc k
  false

proc parseLambda(p: var NsParser): PNode

proc parsePrimary(p: var NsParser): PNode =
  if looksLikeLambda(p):
    return p.parseLambda()
  let t = p.peek
  case t.kind
  of nsStrLit:
    discard p.advance
    result = newAtom(nkStrLit, t.text, p.infoOf(t))
  of nsIntLit:
    discard p.advance
    var v: BiggestInt = 0
    try: v = parseBiggestInt(t.text)
    except ValueError: discard
    result = newAtom(nkIntLit, v, p.infoOf(t))
  of nsCharLit:
    discard p.advance
    var v = 0
    if t.text.len == 1: v = ord(t.text[0])
    result = newAtom(nkCharLit, BiggestInt(v), p.infoOf(t))
  of nsIdent:
    discard p.advance
    if t.text == "null":
      result = newNodeI(nkNilLit, p.infoOf(t))
    elif t.text == "new":
      result = p.parseNew(t)
    elif t.text == "this" and p.thisName.len > 0:
      result = p.identOf(p.thisName, p.infoOf(t))
    elif p.thisName.len > 0 and t.text in p.classFields and t.text != "value":
      if not p.accessibleFrom(p.curClass, t.text):
        p.err(t, "'" & t.text & "' is inaccessible due to its protection level")
      result = newTree(nkDotExpr, p.infoOf(t), p.identOf(p.thisName, p.infoOf(t)),
                       p.identOf(t.text, p.infoOf(t)))
    else:
      result = p.identOf(t.text, p.infoOf(t))
  of nsLParen:
    discard p.advance
    result = p.parseExpr()
    discard p.expect(nsRParen)
  else:
    p.err(t, "unexpected token '" & t.text & "'")
    discard p.advance
    result = nil

proc parseLambda(p: var NsParser): PNode =
  ## `x => e`, `(a, b) => e`, `(a, b) => { ... }`. Parameter types are left
  ## empty and filled in later from the declared delegate type (annotateLambda).
  let info = p.infoOf(p.peek)
  var names: seq[string] = @[]
  var preTypes: seq[PNode] = @[]
  if p.peek.kind == nsIdent:
    names.add p.advance.text
    preTypes.add nil
  else:
    discard p.advance   # '('
    while not p.at(nsRParen) and not p.at(nsEof):
      if p.at(nsComma):
        discard p.advance
        continue
      if p.peek.kind != nsIdent: break
      let a = p.advance.text
      if p.peek.kind == nsIdent:
        # C# form `(int x) => ...`
        names.add p.advance.text
        preTypes.add p.identOf(builtinTypeName(a), info)
      else:
        names.add a
        preTypes.add nil
    discard p.expect(nsRParen)
  discard p.expect(nsArrow)
  var body: PNode
  if p.at(nsLBrace):
    body = p.parseBlock()
  else:
    body = newNodeI(nkStmtList, info)
    body.add p.parseExpr()
  let fp = newNodeI(nkFormalParams, info)
  fp.add emptyN(info)
  for i in 0 ..< names.len:
    let d = newNodeI(nkIdentDefs, info)
    d.add p.identOf(names[i], info)
    if preTypes[i] != nil: d.add preTypes[i] else: d.add emptyN(info)
    d.add emptyN(info)
    fp.add d
  result = newNodeI(nkLambda, info, 7)
  for i in 0 .. 6: result[i] = emptyN(info)
  result[3] = fp
  result[6] = body

proc annotateLambda(n, ty: PNode) =
  ## Copies the parameter and return types of a delegate's `proc` type into a
  ## lambda literal, so `IntFn f = x => ...;` types `x` without an annotation.
  if n == nil or ty == nil or ty.kind != nkProcTy or n.kind != nkLambda: return
  let target = ty[0]
  let fp = n[3]
  if fp.len == 0 or target.len == 0: return
  if fp[0].kind == nkEmpty:
    fp[0] = copyTree(target[0])
  for i in 1 ..< fp.len:
    if i < target.len and fp[i].kind == nkIdentDefs and fp[i].len >= 2 and
       fp[i][1].kind == nkEmpty and target[i].kind == nkIdentDefs and
       target[i].len >= 2:
      fp[i][1] = copyTree(target[i][1])

proc binPrec(k: NsTokenKind): int =
  case k
  of nsPipePipe: 3
  of nsAmpAmp: 4
  of nsPipe: 5
  of nsCaret: 6
  of nsAmp: 7
  of nsEqEq, nsNotEq: 8
  of nsLt, nsGt, nsLe, nsGe: 9
  of nsShl, nsShr: 10
  of nsPlus, nsMinus: 11
  of nsStar, nsSlash, nsPercent: 12
  else: 0

proc opName(k: NsTokenKind): string =
  case k
  of nsPipePipe: "or"
  of nsAmpAmp: "and"
  of nsPipe: "or"
  of nsCaret: "xor"
  of nsAmp: "and"
  of nsEqEq: "=="
  of nsNotEq: "!="
  of nsLt: "<"
  of nsGt: ">"
  of nsLe: "<="
  of nsGe: ">="
  of nsShl: "shl"
  of nsShr: "shr"
  of nsPlus: "+"
  of nsMinus: "-"
  of nsStar: "*"
  of nsSlash: "/"
  of nsPercent: "mod"
  else: "?"

proc parsePostfix(p: var NsParser): PNode =
  result = p.parsePrimary()
  if result == nil: return
  while true:
    if p.at(nsDot):
      discard p.advance
      let nameTok = p.peek
      if nameTok.kind != nsIdent: break
      discard p.advance
      if p.thisName.len > 0 and result.kind == nkIdent and
         result.ident.s == p.thisName and
         not p.accessibleFrom(p.curClass, nameTok.text):
        p.err(nameTok, "'" & nameTok.text & "' is inaccessible due to its protection level")
      let propName =
        if nameTok.text in ["Length", "Count"]: "len"
        elif nameTok.text == "Message": "msg"
        else: nameTok.text
      result = newTree(nkDotExpr, p.infoOf(nameTok), result,
                       p.identOf(propName, p.infoOf(nameTok)))
    elif p.at(nsLParen):
      discard p.advance
      var callee = result
      # Phase 1b: drop a class/namespace qualifier on a static call, so
      # `Class.Method(args)` and `Console.WriteLine(x)` both become `Method(args)`.
      # Temporary until classes are real (Phase 2).
      if callee.kind == nkDotExpr and callee[0].kind == nkIdent and
         callee[0].ident.s.len > 0 and callee[0].ident.s[0] in {'A'..'Z'}:
        callee = callee[1]
      var call = newNodeI(nkCall, callee.info)
      call.add callee
      while not p.at(nsRParen) and not p.at(nsEof):
        call.add p.parseExpr()
        if p.at(nsComma): discard p.advance else: break
      discard p.expect(nsRParen)
      result = call
    elif p.at(nsLBracket):
      discard p.advance
      var idx = newNodeI(nkBracketExpr, result.info)
      idx.add result
      idx.add p.parseExpr()
      discard p.expect(nsRBracket)
      result = idx
    elif p.at(nsPlusPlus) or p.at(nsMinusMinus):
      let opTok = p.advance
      let op = if opTok.kind == nsPlusPlus: "inc" else: "dec"
      result = newTree(nkCommand, p.infoOf(opTok), p.identOf(op, p.infoOf(opTok)), result)
    else:
      break

proc parseUnary(p: var NsParser): PNode =
  let t = p.peek
  case t.kind
  of nsMinus, nsPlus, nsBang, nsTilde:
    discard p.advance
    let operand = p.parseUnary()
    let op = case t.kind
      of nsMinus: "-"
      of nsPlus: "+"
      else: "not"
    result = newTree(nkPrefix, p.infoOf(t), p.identOf(op, p.infoOf(t)), operand)
  else:
    result = p.parsePostfix()

proc parseBinary(p: var NsParser, minPrec: int): PNode =
  result = p.parseUnary()
  while true:
    let prec = binPrec(p.peek.kind)
    if prec < minPrec or prec == 0: break
    let opTok = p.advance
    let rhs = p.parseBinary(prec + 1)
    result = newTree(nkInfix, p.infoOf(opTok),
                     p.identOf(opName(opTok.kind), p.infoOf(opTok)), result, rhs)

proc parseTernary(p: var NsParser): PNode =
  result = p.parseBinary(1)
  if p.at(nsQuestion):
    let info = p.infoOf(p.peek)
    discard p.advance
    let a = p.parseExpr()
    discard p.expect(nsColon)
    let b = p.parseExpr()
    var n = newNodeI(nkIfExpr, info)
    n.add newTree(nkElifExpr, info, result, a)
    n.add newTree(nkElseExpr, info, b)
    result = n

proc parseExpr(p: var NsParser): PNode =
  result = p.parseTernary()

proc parseNew(p: var NsParser, kw: NsToken): PNode =
  ## `new T(args)` -> `newT(args)`; `new T[n]` -> `newSeq[T](n)`;
  ## `new T[] { a, b }` -> `@[a, b]`.
  let info = p.infoOf(kw)
  if p.peek.kind != nsIdent:
    var call = newNodeI(nkCall, info)
    call.add p.identOf("new", info)
    return call
  let typeTok = p.advance
  let typeName = builtinTypeName(typeTok.text)
  var callee = p.identOf("new" & typeName, info)
  if p.at(nsLt):
    # `new List<int>()` -> `newList[int32]()`
    let be = newNodeI(nkBracketExpr, info)
    be.add callee
    discard p.advance
    while not atGtClose(p) and not p.at(nsEof):
      be.add p.parseType()
      if p.at(nsComma): discard p.advance else: break
    p.expectGt()
    callee = be
  elif p.at(nsLBracket):
    discard p.advance
    if p.at(nsRBracket):
      discard p.advance
      var br = newNodeI(nkBracket, info)
      if p.at(nsLBrace):
        discard p.advance
        while not p.at(nsRBrace) and not p.at(nsEof):
          br.add p.parseExpr()
          if p.at(nsComma): discard p.advance else: break
        discard p.expect(nsRBrace)
      return newTree(nkPrefix, info, p.identOf("@", info), br)
    else:
      let n = p.parseExpr()
      discard p.expect(nsRBracket)
      let typ = newTree(nkBracketExpr, info, p.identOf("newSeq", info),
                        p.identOf(typeName, info))
      var call = newNodeI(nkCall, info)
      call.add typ
      call.add n
      return call
  var call = newNodeI(nkCall, info)
  call.add callee
  if p.at(nsLParen):
    discard p.advance
    while not p.at(nsRParen) and not p.at(nsEof):
      call.add p.parseExpr()
      if p.at(nsComma): discard p.advance else: break
    discard p.expect(nsRParen)
  result = call

proc parseBlock(p: var NsParser): PNode =
  let info = p.infoOf(p.peek)
  discard p.expect(nsLBrace)
  result = newNodeI(nkStmtList, info)
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    let s = p.parseStatement()
    if s != nil: result.add s
    if p.at(nsSemi): discard p.advance
  discard p.expect(nsRBrace)

proc parseParams(p: var NsParser, retType: PNode): PNode =
  let info = p.infoOf(p.peek)
  result = newNodeI(nkFormalParams, info)
  result.add retType
  discard p.expect(nsLParen)
  while not p.at(nsRParen) and not p.at(nsEof):
    let ty = p.parseType()
    var pname = "arg"
    if p.peek.kind == nsIdent:
      pname = p.advance.text
    let defs = newNodeI(nkIdentDefs, info)
    defs.add p.identOf(pname, info)
    defs.add ty
    defs.add emptyN(info)
    result.add defs
    if p.at(nsComma): discard p.advance else: break
  discard p.expect(nsRParen)

proc parseBodyWith(p: var NsParser, thisName, clsName: string): PNode =
  ## Parses a `{ ... }` body with a `this` mapping, so `this` and bare instance
  ## member names rewrite to `self`/`result`.
  let saveThis = p.thisName
  let saveFields = p.classFields
  let saveClass = p.curClass
  p.thisName = thisName
  p.curClass = clsName
  p.classFields = p.chainMemberNames(clsName)
  result = p.parseBlock()
  p.thisName = saveThis
  p.classFields = saveFields
  p.curClass = saveClass

proc looksLikeDecl(p: NsParser): bool =
  ## A simple statement is a declaration when it starts with `var`/`let`/`const`
  ## or with a `Type name` shape, where the type may be `Type[]` or `Type<...>`.
  if p.peek.kind == nsIdent and p.peek.text in ["var", "let", "const"]:
    return true
  if p.peek.kind == nsIdent:
    var k = 1
    if p.peekAhead(1).kind == nsLBracket and p.peekAhead(2).kind == nsRBracket:
      k = 3
    elif p.peekAhead(1).kind == nsLt:
      # skip a balanced generic argument list (`Dictionary<string, int>`)
      var depth = 0
      while k < 200:
        let t = p.peekAhead(k)
        if t.kind == nsEof: return false
        if t.kind == nsLt:
          inc depth
        elif t.kind == nsGt:
          dec depth
          if depth <= 0:
            inc k
            break
        elif t.kind == nsShr:
          depth -= 2
          if depth <= 0:
            inc k
            break
        inc k
    if p.peekAhead(k).kind == nsIdent:
      return true
  false

proc parseVarDecl(p: var NsParser): PNode =
  let info = p.infoOf(p.peek)
  var sectKind = nkVarSection
  var ty: PNode = nil
  if p.peek.kind == nsIdent and p.peek.text == "var":
    discard p.advance
  elif p.peek.kind == nsIdent and p.peek.text == "let":
    sectKind = nkLetSection
    discard p.advance
  elif p.peek.kind == nsIdent and p.peek.text == "const":
    sectKind = nkConstSection
    discard p.advance
  else:
    ty = p.parseType()
  let nameTok = p.peek
  discard p.advance
  var init = emptyN(info)
  if p.at(nsAssign):
    discard p.advance
    init = p.parseExpr()
    if ty != nil:
      var annoTy = ty
      if annoTy.kind == nkIdent and p.delegates.hasKey(annoTy.ident.s):
        annoTy = p.delegates[annoTy.ident.s]
      annotateLambda(init, annoTy)
  let defs = newNodeI(nkIdentDefs, info)
  defs.add p.identOf(nameTok.text, info)
  if ty != nil: defs.add ty
  else: defs.add emptyN(info)
  defs.add init
  result = newNodeI(sectKind, info)
  result.add defs

proc parseSimpleStmt(p: var NsParser): PNode =
  if looksLikeDecl(p):
    return p.parseVarDecl()
  var lhs = p.parseExpr()
  if p.at(nsAssign):
    discard p.advance
    let rhs = p.parseExpr()
    return newTree(nkAsgn, lhs.info, lhs, rhs)
  let compound = case p.peek.kind
    of nsPlusEq: "+"
    of nsMinusEq: "-"
    of nsStarEq: "*"
    of nsSlashEq: "/"
    of nsPercentEq: "mod"
    of nsAmpEq: "and"
    of nsPipeEq: "or"
    of nsCaretEq: "xor"
    of nsShlEq: "shl"
    of nsShrEq: "shr"
    else: ""
  if compound.len > 0:
    let opTok = p.advance
    let rhs = p.parseExpr()
    let combined = newTree(nkInfix, lhs.info,
                           p.identOf(compound, p.infoOf(opTok)), lhs, rhs)
    return newTree(nkAsgn, lhs.info, lhs, combined)
  result = lhs

proc parseIf(p: var NsParser): PNode
proc parseWhile(p: var NsParser): PNode
proc parseFor(p: var NsParser): PNode
proc parseForeach(p: var NsParser): PNode
proc parseSwitch(p: var NsParser): PNode
proc parseTry(p: var NsParser): PNode

proc parseStatement(p: var NsParser): PNode =
  let t = p.peek
  if t.kind == nsLBrace:
    let info = p.infoOf(t)
    let body = p.parseBlock()
    return newTree(nkBlockStmt, info, emptyN(info), body)
  if t.kind == nsIdent:
    case t.text
    of "if": return p.parseIf()
    of "while": return p.parseWhile()
    of "for": return p.parseFor()
    of "foreach": return p.parseForeach()
    of "switch": return p.parseSwitch()
    of "try": return p.parseTry()
    of "throw":
      let info = p.infoOf(t)
      discard p.advance
      var e = p.parseExpr()
      if e != nil and e.kind == nkCall and e.len >= 1 and
         e[0].kind == nkIdent and e[0].ident.s.len > 3 and
         e[0].ident.s.startsWith("new"):
        let typName = e[0].ident.s[3 .. ^1]
        if not p.classes.hasKey(typName):
          # external/system exception: `newException(T, msg)`
          let msg = if e.len >= 2: e[1] else: newAtom(nkStrLit, "", info)
          let ne = newNodeI(nkCall, info)
          ne.add p.identOf("newException", info)
          ne.add p.identOf(typName, info)
          ne.add msg
          e = ne
        # else: user-declared exception class, raise its allocator result
      return newTree(nkRaiseStmt, info, e)
    of "return":
      let info = p.infoOf(t)
      discard p.advance
      var n = newNodeI(nkReturnStmt, info)
      if p.at(nsSemi) or p.at(nsRBrace) or p.at(nsEof):
        n.add emptyN(info)
      else:
        n.add p.parseExpr()
      return n
    of "break":
      let info = p.infoOf(t)
      discard p.advance
      return newNodeI(nkBreakStmt, info)
    of "continue":
      let info = p.infoOf(t)
      discard p.advance
      return newNodeI(nkContinueStmt, info)
    else: discard
  result = p.parseSimpleStmt()

proc parseIf(p: var NsParser): PNode =
  let info = p.infoOf(p.peek)
  discard p.advance
  discard p.expect(nsLParen)
  let cond = p.parseExpr()
  discard p.expect(nsRParen)
  let body = p.parseBlock()
  result = newNodeI(nkIfStmt, info)
  result.add newTree(nkElifBranch, info, cond, body)
  while p.peek.kind == nsIdent and p.peek.text == "else":
    let elseInfo = p.infoOf(p.peek)
    discard p.advance
    if p.peek.kind == nsIdent and p.peek.text == "if":
      discard p.advance
      discard p.expect(nsLParen)
      let c2 = p.parseExpr()
      discard p.expect(nsRParen)
      let b2 = p.parseBlock()
      result.add newTree(nkElifBranch, elseInfo, c2, b2)
    else:
      let b = p.parseBlock()
      result.add newTree(nkElse, elseInfo, b)
      break

proc parseWhile(p: var NsParser): PNode =
  let info = p.infoOf(p.peek)
  discard p.advance
  discard p.expect(nsLParen)
  let cond = p.parseExpr()
  discard p.expect(nsRParen)
  let body = p.parseBlock()
  result = newTree(nkWhileStmt, info, cond, body)

proc parseFor(p: var NsParser): PNode =
  ## `for (init; cond; step) body` -> `block: (init; while cond: (body; step))`
  let info = p.infoOf(p.peek)
  discard p.advance
  discard p.expect(nsLParen)
  var initStmt: PNode = nil
  if not p.at(nsSemi):
    initStmt = p.parseSimpleStmt()
  discard p.expect(nsSemi)
  var cond: PNode = nil
  if not p.at(nsSemi):
    cond = p.parseExpr()
  discard p.expect(nsSemi)
  var step: PNode = nil
  if not p.at(nsRParen):
    step = p.parseSimpleStmt()
  discard p.expect(nsRParen)
  let body = p.parseBlock()
  let blk = newNodeI(nkBlockStmt, info)
  blk.add emptyN(info)
  let sl = newNodeI(nkStmtList, info)
  if initStmt != nil: sl.add initStmt
  let w = newNodeI(nkWhileStmt, info)
  if cond != nil: w.add cond
  else: w.add p.identOf("true", info)
  var wbody = newNodeI(nkStmtList, info)
  for s in body: wbody.add s
  if step != nil: wbody.add step
  w.add wbody
  sl.add w
  blk.add sl
  result = blk

proc parseForeach(p: var NsParser): PNode =
  let info = p.infoOf(p.peek)
  discard p.advance
  discard p.expect(nsLParen)
  if p.peek.kind == nsIdent and p.peek.text == "var":
    discard p.advance
  else:
    discard p.parseType()
  let nameTok = p.peek
  discard p.advance
  if p.peek.kind == nsIdent and p.peek.text == "in":
    discard p.advance
  else:
    p.err(p.peek, "expected 'in' in foreach")
  let iter = p.parseExpr()
  discard p.expect(nsRParen)
  let body = p.parseBlock()
  result = newNodeI(nkForStmt, info)
  result.add p.identOf(nameTok.text, info)
  result.add iter
  result.add body

proc parseCaseBody(p: var NsParser): PNode =
  let info = p.infoOf(p.peek)
  result = newNodeI(nkStmtList, info)
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    if p.peek.kind == nsIdent and p.peek.text in ["case", "default"]:
      break
    result.add p.parseStatement()
    if p.at(nsSemi): discard p.advance
  # drop a trailing C# `break;` (Nim `case` has no fallthrough)
  if result.len > 0 and result[result.len - 1].kind == nkBreakStmt:
    var trimmed = newNodeI(nkStmtList, info)
    for i in 0 ..< result.len - 1:
      trimmed.add result[i]
    result = trimmed

proc parseSwitch(p: var NsParser): PNode =
  let info = p.infoOf(p.peek)
  discard p.advance   # switch
  discard p.expect(nsLParen)
  let sel = p.parseExpr()
  discard p.expect(nsRParen)
  discard p.expect(nsLBrace)
  result = newNodeI(nkCaseStmt, info)
  result.add sel
  var hasElse = false
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    if p.peek.kind == nsIdent and p.peek.text == "case":
      let branch = newNodeI(nkOfBranch, p.infoOf(p.peek))
      while p.peek.kind == nsIdent and p.peek.text == "case":
        discard p.advance
        while true:
          branch.add p.parseExpr()
          if p.at(nsComma): discard p.advance else: break
        discard p.expect(nsColon)
      branch.add p.parseCaseBody()
      result.add branch
    elif p.peek.kind == nsIdent and p.peek.text == "default":
      discard p.advance
      discard p.expect(nsColon)
      let e = newNodeI(nkElse, info)
      e.add p.parseCaseBody()
      result.add e
      hasElse = true
      break
    else:
      discard p.advance
  discard p.expect(nsRBrace)
  if not hasElse:
    # C# `switch` need not be exhaustive; Nim `case` needs an `else`
    let e = newNodeI(nkElse, info)
    let sl = newNodeI(nkStmtList, info)
    sl.add newTree(nkDiscardStmt, info, emptyN(info))
    e.add sl
    result.add e

proc parseTry(p: var NsParser): PNode =
  let info = p.infoOf(p.peek)
  discard p.advance   # try
  result = newNodeI(nkTryStmt, info)
  result.add p.parseBlock()
  while true:
    if p.peek.kind == nsIdent and p.peek.text == "catch":
      let cinfo = p.infoOf(p.peek)
      discard p.advance
      var branch: PNode
      if p.at(nsLParen):
        discard p.advance
        let typ = p.parseType()
        var name = "e"
        if p.peek.kind == nsIdent:
          name = p.advance.text
        discard p.expect(nsRParen)
        let asNode = newNodeI(nkInfix, cinfo)
        asNode.add p.identOf("as", cinfo)
        asNode.add typ
        asNode.add p.identOf(name, cinfo)
        branch = newNodeI(nkExceptBranch, cinfo)
        branch.add asNode
      else:
        branch = newNodeI(nkExceptBranch, cinfo)
      branch.add p.parseBlock()
      result.add branch
    elif p.peek.kind == nsIdent and p.peek.text == "finally":
      let finfo = p.infoOf(p.peek)
      discard p.advance
      let f = newNodeI(nkFinally, finfo)
      f.add p.parseBlock()
      result.add f
      break
    else:
      break

proc parseTopLevelDecl(p: var NsParser, stmts: var seq[PNode])

proc parseUsing(p: var NsParser, stmts: var seq[PNode]) =
  # `using X;` / `import X;` -> `import "X"`. `System` is the prelude and is
  # already auto-imported, so it is a no-op.
  let info = p.infoOf(p.peek)
  discard p.advance
  var name = ""
  if p.peek.kind == nsIdent:
    name = p.advance.text
    while p.at(nsDot) and p.peekAhead(1).kind == nsIdent:
      discard p.advance
      name.add "."
      name.add p.advance.text
  while not p.at(nsSemi) and not p.at(nsEof):
    discard p.advance
  if p.at(nsSemi): discard p.advance
  # C# BCL namespaces are gated: a type is only in scope once its namespace was
  # `using`-ed, so `List<int>` without `using System.Collections.Generic;` fails
  # to compile, exactly as in C#. This is the single namespace -> N# module
  # table (SPEC section 15); the module file names are ours to choose, the C#
  # namespace is only the name we present.
  let target =
    case name
    of "System": "ns/system"
    of "System.Collections.Generic": "ns/collections"
    else: ""
  if target.len > 0:
    let imp = newNodeI(nkImportStmt, info)
    imp.add newAtom(nkStrLit, target, info)
    stmts.add imp
    return
  # Remaining `System.*` namespaces are not implemented yet, so they are ignored
  # rather than reported (using their types still fails, which is the point).
  if name.len == 0 or name == "System" or name.startsWith("System."):
    return
  let imp = newNodeI(nkImportStmt, info)
  imp.add newAtom(nkStrLit, name, info)
  stmts.add imp

proc skipParens(p: var NsParser) =
  var depth = 0
  while not p.at(nsEof):
    if p.at(nsLParen):
      inc depth
    elif p.at(nsRParen):
      dec depth
      if depth == 0:
        discard p.advance
        return
    discard p.advance

proc skipBraces(p: var NsParser) =
  var depth = 0
  while not p.at(nsEof):
    if p.at(nsLBrace):
      inc depth
    elif p.at(nsRBrace):
      dec depth
      if depth == 0:
        discard p.advance
        return
    discard p.advance

proc countParenArgs(p: var NsParser): int =
  ## Consumes a `( ... )` group and returns its argument count. Assumes the
  ## current token is `(`.
  var depth = 0
  var count = 0
  var saw = false
  while not p.at(nsEof):
    if p.at(nsLParen):
      inc depth
      discard p.advance
    elif p.at(nsRParen):
      dec depth
      discard p.advance
      if depth == 0: break
    elif p.at(nsComma) and depth == 1:
      inc count
      saw = true
      discard p.advance
    else:
      saw = true
      discard p.advance
  result = if saw: count + 1 else: 0

proc accessOf(mods: seq[string]): NsAccess =
  result = aPrivate
  for w in mods:
    case w
    of "public": result = aPublic
    of "protected": result = aProtected
    of "internal": result = aInternal
    of "private": result = aPrivate
    else: discard

proc skipItem(p: var NsParser) =
  ## Skips a top-level item up to `;`, a balanced `{ ... }` block, or `}`.
  while not p.at(nsEof):
    if p.at(nsLBrace):
      p.skipBraces()
      return
    elif p.at(nsSemi):
      discard p.advance
      return
    elif p.at(nsRBrace):
      return
    discard p.advance

proc prescanClass(p: var NsParser) =
  while p.peek.kind == nsIdent and p.peek.text in NsTypeModifiers:
    discard p.advance
  discard p.advance   # class / struct / interface
  if p.peek.kind != nsIdent: return
  let name = p.advance.text
  var info = NsClassInfo(name: name)
  if p.at(nsColon):
    discard p.advance
    if p.peek.kind == nsIdent:
      info.base = p.advance.text
    while p.at(nsComma):
      discard p.advance
      if p.peek.kind == nsIdent: discard p.advance
  while not p.at(nsLBrace) and not p.at(nsEof):
    discard p.advance
  if p.at(nsLBrace): discard p.advance
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    var mods: seq[string] = @[]
    while p.peek.kind == nsIdent and p.peek.text in NsModifierWords:
      mods.add p.advance.text
    if p.peek.kind == nsIdent and p.peek.text == name and
       p.peekAhead(1).kind == nsLParen:
      discard p.advance
      if p.at(nsLParen): info.ctorArities.add p.countParenArgs()
      if p.at(nsColon):   # `: base(...)` / `: this(...)` initializer
        discard p.advance
        if p.peek.kind == nsIdent: discard p.advance
        if p.at(nsLParen): discard p.countParenArgs()
      if p.at(nsLBrace): p.skipBraces()
      continue
    if p.peek.kind != nsIdent:
      discard p.advance
      continue
    discard p.parseType()
    if p.peek.kind != nsIdent:
      while not p.at(nsSemi) and not p.at(nsRBrace) and not p.at(nsEof):
        discard p.advance
      if p.at(nsSemi): discard p.advance
      continue
    let mname = p.advance.text
    info.members.add NsMemberInfo(name: mname, access: accessOf(mods))
    if p.at(nsLParen):
      p.skipParens()
      if p.at(nsLBrace): p.skipBraces()
      elif p.at(nsArrow):
        discard p.advance
        discard p.parseExpr()
        if p.at(nsSemi): discard p.advance
    elif p.at(nsLBrace):
      p.skipBraces()
    elif p.at(nsArrow):
      discard p.advance
      discard p.parseExpr()
      if p.at(nsSemi): discard p.advance
    else:
      while not p.at(nsSemi) and not p.at(nsRBrace) and not p.at(nsEof):
        discard p.advance
      if p.at(nsSemi): discard p.advance
  if p.at(nsRBrace): discard p.advance
  p.classes[name] = info

proc prescanClasses(p: var NsParser) =
  ## Walks the whole module to build the class table before any body is parsed,
  ## so access checks can see base-class members regardless of source order.
  let save = p.pos
  p.pos = 0
  while not p.at(nsEof):
    if p.at(nsSemi) or p.at(nsRBrace):
      discard p.advance
      continue
    var k = 0
    while p.peekAhead(k).kind == nsIdent and p.peekAhead(k).text in NsTypeModifiers:
      inc k
    let head = p.peekAhead(k)
    if head.kind == nsIdent and head.text in ["class", "struct", "interface"]:
      p.prescanClass()
    elif p.peek.kind == nsIdent and p.peek.text in ["using", "import", "namespace"]:
      discard p.advance
      var stopped = false
      while not p.at(nsEof) and not stopped:
        if p.at(nsSemi):
          discard p.advance
          stopped = true
        elif p.at(nsLBrace):
          discard p.advance
          stopped = true
        else:
          discard p.advance
    else:
      p.skipItem()
  p.pos = save

proc chainMemberNames(p: NsParser, clsName: string): seq[string] =
  ## Names of all members along the class chain (own + bases).
  result = @[]
  var c = clsName
  var guard = 0
  while c.len > 0 and p.classes.hasKey(c) and guard < 64:
    for m in p.classes[c].members:
      if m.name notin result: result.add m.name
    c = p.classes[c].base
    inc guard

proc findMember(p: NsParser, clsName, member: string):
    tuple[found: bool, access: NsAccess, decl: string] =
  var c = clsName
  var guard = 0
  while c.len > 0 and p.classes.hasKey(c) and guard < 64:
    for m in p.classes[c].members:
      if m.name == member: return (true, m.access, c)
    c = p.classes[c].base
    inc guard
  result = (false, aPrivate, "")

proc accessibleFrom(p: NsParser, curClass, member: string): bool =
  let (found, ac, decl) = p.findMember(curClass, member)
  if not found: return true
  case ac
  of aPrivate: decl == curClass
  of aProtected, aInternal, aPublic: true

proc parseClassMember(p: var NsParser, clsName: string): NsMember =
  result.info = p.infoOf(p.peek)
  var mods: seq[string] = @[]
  while p.peek.kind == nsIdent and p.peek.text in NsModifierWords:
    if p.peek.text == "static": result.isStatic = true
    mods.add p.advance.text
  result.access = accessOf(mods)
  result.isPublic = result.access != aPrivate
  # constructor: `ClsName(params) { body }`
  if p.peek.kind == nsIdent and p.peek.text == clsName and
     p.peekAhead(1).kind == nsLParen:
    result.kind = mkCtor
    result.name = clsName
    result.info = p.infoOf(p.peek)
    discard p.advance
    result.params = p.parseParams(emptyN(result.info))
    if p.at(nsColon):
      discard p.advance
      if p.peek.kind == nsIdent and p.peek.text in ["base", "this"]:
        result.initKind = p.advance.text
      if p.at(nsLParen):
        discard p.advance
        while not p.at(nsRParen) and not p.at(nsEof):
          result.initArgs.add p.parseExpr()
          if p.at(nsComma): discard p.advance else: break
        discard p.expect(nsRParen)
    result.body = p.parseBodyWith("self", clsName)
    return
  if p.peek.kind != nsIdent:
    discard p.advance
    result.kind = mkField
    return
  let ty = p.parseType()
  if p.peek.kind != nsIdent:
    p.skipToSemi()
    result.kind = mkField
    return
  let nameTok = p.advance
  result.name = nameTok.text
  result.info = p.infoOf(nameTok)
  result.typ = ty
  if p.at(nsLParen):
    result.kind = mkMethod
    result.params = p.parseParams(ty)
    result.body = p.parseBodyWith((if result.isStatic: "" else: "self"), clsName)
  elif p.at(nsLBrace) or p.at(nsArrow):
    result.kind = mkProperty
    if p.at(nsArrow):
      discard p.advance
      result.hasGet = true
      result.getBody = p.parseExpr()
      if p.at(nsSemi): discard p.advance
    else:
      discard p.advance   # '{'
      while not p.at(nsRBrace) and not p.at(nsEof):
        if p.at(nsSemi):
          discard p.advance
          continue
        if p.peek.kind == nsIdent and p.peek.text == "get":
          result.hasGet = true
          discard p.advance
          if p.at(nsLBrace):
            result.getBody = p.parseBodyWith("self", clsName)
          else:
            result.getBody = emptyN(result.info)
            if p.at(nsSemi): discard p.advance
        elif p.peek.kind == nsIdent and p.peek.text == "set":
          result.hasSet = true
          discard p.advance
          if p.at(nsLBrace):
            result.setBody = p.parseBodyWith("self", clsName)
          else:
            result.setBody = emptyN(result.info)
            if p.at(nsSemi): discard p.advance
        else:
          discard p.advance   # accessor visibility (public/private) etc.
      discard p.expect(nsRBrace)
  else:
    result.kind = mkField
    if p.at(nsAssign):
      discard p.advance
      discard p.parseExpr()
    if p.at(nsSemi): discard p.advance

proc emitProperty(p: var NsParser, clsName: string, m: NsMember,
                  stmts: var seq[PNode]) =
  if m.isStatic: return
  proc mkProc(nameNode, params, body: PNode, info: TLineInfo): PNode =
    result = newNodeI(nkProcDef, info, 7)
    result[0] = nameNode
    result[1] = emptyN(info)
    result[2] = emptyN(info)
    result[3] = params
    result[4] = emptyN(info)
    result[5] = emptyN(info)
    result[6] = body
  proc selfParam(p: NsParser, clsName: string, info: TLineInfo): PNode =
    result = newNodeI(nkIdentDefs, info)
    result.add p.identOf("self", info)
    result.add p.identOf(clsName, info)
    result.add emptyN(info)
  if m.hasGet:
    var gbody: PNode
    if m.getBody.kind == nkEmpty:
      gbody = newNodeI(nkDotExpr, m.info)
      gbody.add p.identOf("self", m.info)
      gbody.add p.identOf(m.name & "Backing", m.info)
    else:
      gbody = m.getBody
    let gp = newNodeI(nkFormalParams, m.info)
    gp.add m.typ
    gp.add selfParam(p, clsName, m.info)
    let gname =
      if m.isPublic:
        newTree(nkPostfix, m.info, p.identOf("*", m.info), p.identOf(m.name, m.info))
      else:
        p.identOf(m.name, m.info)
    stmts.add mkProc(gname, gp, gbody, m.info)
  if m.hasSet:
    var sbody: PNode
    if m.setBody.kind == nkEmpty:
      sbody = newNodeI(nkAsgn, m.info)
      let dot = newNodeI(nkDotExpr, m.info)
      dot.add p.identOf("self", m.info)
      dot.add p.identOf(m.name & "Backing", m.info)
      sbody.add dot
      sbody.add p.identOf("value", m.info)
    else:
      sbody = m.setBody
    let sp = newNodeI(nkFormalParams, m.info)
    sp.add emptyN(m.info)
    sp.add selfParam(p, clsName, m.info)
    let vdefs = newNodeI(nkIdentDefs, m.info)
    vdefs.add p.identOf("value", m.info)
    vdefs.add m.typ
    vdefs.add emptyN(m.info)
    sp.add vdefs
    let sname =
      if m.isPublic:
        newTree(nkPostfix, m.info, p.identOf("*", m.info),
                p.identOf(m.name & "=", m.info))
      else:
        p.identOf(m.name & "=", m.info)
    stmts.add mkProc(sname, sp, sbody, m.info)

proc emitClass(p: var NsParser, clsName: string, isClass, isPublic: bool,
               baseType: PNode, members: seq[NsMember], stmts: var seq[PNode]) =
  let info = if members.len > 0: members[0].info else: newLineInfo(p.fileIdx, 1, 1)
  # 1. the type: `type C = ref object` (class) or `object` (struct)
  let recList = newNodeI(nkRecList, info)
  for m in members:
    if m.kind == mkField:
      let defs = newNodeI(nkIdentDefs, m.info)
      defs.add (if m.isPublic:
                  newTree(nkPostfix, m.info, p.identOf("*", m.info), p.identOf(m.name, m.info))
                else:
                  p.identOf(m.name, m.info))
      defs.add m.typ
      defs.add emptyN(m.info)
      recList.add defs
    elif m.kind == mkProperty and
         ((m.hasGet and m.getBody.kind == nkEmpty) or
          (m.hasSet and m.setBody.kind == nkEmpty)):
      # auto-property backing field
      let defs = newNodeI(nkIdentDefs, m.info)
      defs.add p.identOf(m.name & "Backing", m.info)
      defs.add m.typ
      defs.add emptyN(m.info)
      recList.add defs
  let objTy = newNodeI(nkObjectTy, info)
  objTy.add emptyN(info)
  if baseType != nil:
    objTy.add newTree(nkOfInherit, info, baseType)
  elif isClass:
    objTy.add newTree(nkOfInherit, info, p.identOf("RootObj", info))
  else:
    objTy.add emptyN(info)
  objTy.add recList
  let baseName0 = if baseType != nil and baseType.kind == nkIdent: baseType.ident.s else: ""
  let isException = isClass and isExceptionBase(baseName0)
  var typeValue = objTy
  if isClass and not isException:
    typeValue = newTree(nkRefTy, info, objTy)
  let typeDef = newNodeI(nkTypeDef, info)
  typeDef.add (if isPublic:
                 newTree(nkPostfix, info, p.identOf("*", info), p.identOf(clsName, info))
               else:
                 p.identOf(clsName, info))
  typeDef.add emptyN(info)
  typeDef.add typeValue
  let sec = newNodeI(nkTypeSection, info)
  sec.add typeDef
  stmts.add sec
  # 2. members in source order (so a method can reference a property defined
  #    earlier in the class, which Nim's dot-call resolution requires)
  var hasCtor = false
  for m in members:
    case m.kind
    of mkMethod:
      var params = m.params
      if m.name == "Main" and m.isStatic:
        # entry point: parameters ignored (called as `Main()`)
        let np = newNodeI(nkFormalParams, m.info)
        np.add params[0]
        params = np
      elif not m.isStatic:
        # prepend `self: ClsName`
        let np = newNodeI(nkFormalParams, m.info)
        np.add params[0]
        let selfDefs = newNodeI(nkIdentDefs, m.info)
        selfDefs.add p.identOf("self", m.info)
        selfDefs.add (if isException: newTree(nkRefTy, m.info, p.identOf(clsName, m.info))
                      else: p.identOf(clsName, m.info))
        selfDefs.add emptyN(m.info)
        np.add selfDefs
        for i in 1 ..< params.len: np.add params[i]
        params = np
      let nameNode =
        if m.isPublic:
          newTree(nkPostfix, m.info, p.identOf("*", m.info), p.identOf(m.name, m.info))
        else:
          p.identOf(m.name, m.info)
      let procDef = newNodeI(nkProcDef, m.info, 7)
      procDef[0] = nameNode
      procDef[1] = emptyN(m.info)
      procDef[2] = emptyN(m.info)
      procDef[3] = params
      procDef[4] = emptyN(m.info)
      procDef[5] = emptyN(m.info)
      procDef[6] = m.body
      stmts.add procDef
    of mkCtor:
      hasCtor = true
      let baseName = if baseType != nil and baseType.kind == nkIdent: baseType.ident.s else: ""
      # initializer: `proc initC(self: C, params) = <base init>; <body>`
      let ip = newNodeI(nkFormalParams, m.info)
      ip.add emptyN(m.info)
      let iself = newNodeI(nkIdentDefs, m.info)
      iself.add p.identOf("self", m.info)
      iself.add (if isException: newTree(nkRefTy, m.info, p.identOf(clsName, m.info))
                 else: p.identOf(clsName, m.info))
      iself.add emptyN(m.info)
      ip.add iself
      for i in 1 ..< m.params.len: ip.add copyTree(m.params[i])
      let ibody = newNodeI(nkStmtList, m.info)
      var initName = ""
      if m.initKind == "base": initName = "init" & baseName
      elif m.initKind == "this": initName = "init" & clsName
      elif baseName.len > 0: initName = "init" & baseName
      let externalExcBase = isException and baseName.len > 0 and
                            not p.classes.hasKey(baseName) and isExceptionBase(baseName)
      if externalExcBase:
        # `: base(msg)` on an external exception base sets the message
        if m.initArgs.len > 0:
          ibody.add newTree(nkAsgn, m.info,
            newTree(nkDotExpr, m.info, p.identOf("self", m.info), p.identOf("msg", m.info)),
            m.initArgs[0])
      elif initName.len > 0:
        let icall = newNodeI(nkCall, m.info)
        icall.add p.identOf(initName, m.info)
        icall.add p.identOf("self", m.info)
        for a in m.initArgs: icall.add a
        ibody.add icall
      for s in m.body: ibody.add s
      let inode =
        if m.isPublic:
          newTree(nkPostfix, m.info, p.identOf("*", m.info), p.identOf("init" & clsName, m.info))
        else:
          p.identOf("init" & clsName, m.info)
      stmts.add mkProcDef(p, inode, ip, ibody, m.info)
      # allocator: `proc newC(params): C = new(result); initC(result, params)`
      let ap = newNodeI(nkFormalParams, m.info)
      ap.add (if isException: newTree(nkRefTy, m.info, p.identOf(clsName, m.info))
              else: p.identOf(clsName, m.info))
      for i in 1 ..< m.params.len: ap.add copyTree(m.params[i])
      let abody = newNodeI(nkStmtList, m.info)
      let newCall = newNodeI(nkCall, m.info)
      newCall.add p.identOf("new", m.info)
      newCall.add p.identOf("result", m.info)
      abody.add newCall
      let fwd = newNodeI(nkCall, m.info)
      fwd.add p.identOf("init" & clsName, m.info)
      fwd.add p.identOf("result", m.info)
      for i in 1 ..< m.params.len:
        let defs = m.params[i]
        if defs.kind == nkIdentDefs and defs.len >= 1 and defs[0].kind == nkIdent:
          fwd.add p.identOf(defs[0].ident.s, m.info)
      abody.add fwd
      let anode =
        if m.isPublic:
          newTree(nkPostfix, m.info, p.identOf("*", m.info), p.identOf("new" & clsName, m.info))
        else:
          p.identOf("new" & clsName, m.info)
      stmts.add mkProcDef(p, anode, ap, abody, m.info)
    of mkProperty:
      p.emitProperty(clsName, m, stmts)
    of mkField:
      discard
  # 3. default constructor when none was declared
  if not hasCtor:
    let baseName = if baseType != nil and baseType.kind == nkIdent: baseType.ident.s else: ""
    let baseParamless =
      baseName.len == 0 or not p.classes.hasKey(baseName) or
      p.classes[baseName].ctorArities.len == 0 or
      0 in p.classes[baseName].ctorArities
    # initializer: `proc initC(self: C) = <base init>`
    let ip = newNodeI(nkFormalParams, info)
    ip.add emptyN(info)
    let iself = newNodeI(nkIdentDefs, info)
    iself.add p.identOf("self", info)
    iself.add (if isException: newTree(nkRefTy, info, p.identOf(clsName, info))
               else: p.identOf(clsName, info))
    iself.add emptyN(info)
    ip.add iself
    let ibody = newNodeI(nkStmtList, info)
    if baseName.len > 0 and baseParamless and
       (p.classes.hasKey(baseName) or not isExceptionBase(baseName)):
      let icall = newNodeI(nkCall, info)
      icall.add p.identOf("init" & baseName, info)
      icall.add p.identOf("self", info)
      ibody.add icall
    stmts.add mkProcDef(p,
      newTree(nkPostfix, info, p.identOf("*", info), p.identOf("init" & clsName, info)),
      ip, ibody, info)
    # allocator: `proc newC(): C = new(result); initC(result)`
    let ap = newNodeI(nkFormalParams, info)
    ap.add (if isException: newTree(nkRefTy, info, p.identOf(clsName, info))
            else: p.identOf(clsName, info))
    let abody = newNodeI(nkStmtList, info)
    let newCall = newNodeI(nkCall, info)
    newCall.add p.identOf("new", info)
    newCall.add p.identOf("result", info)
    abody.add newCall
    let fwd = newNodeI(nkCall, info)
    fwd.add p.identOf("init" & clsName, info)
    fwd.add p.identOf("result", info)
    abody.add fwd
    stmts.add mkProcDef(p,
      newTree(nkPostfix, info, p.identOf("*", info), p.identOf("new" & clsName, info)),
      ap, abody, info)

proc parseEnumDecl(p: var NsParser, stmts: var seq[PNode]) =
  let info = p.infoOf(p.peek)
  var isPublic = false
  while p.peek.kind == nsIdent and p.peek.text in NsTypeModifiers:
    if p.peek.text == "public": isPublic = true
    discard p.advance
  discard p.advance   # enum
  if p.peek.kind != nsIdent: return
  let nameTok = p.advance
  let enumTy = newNodeI(nkEnumTy, info)
  enumTy.add emptyN(info)
  if p.at(nsLBrace):
    discard p.advance
    while not p.at(nsRBrace) and not p.at(nsEof):
      if p.at(nsComma):
        discard p.advance
        continue
      if p.peek.kind != nsIdent:
        discard p.advance
        continue
      let fieldTok = p.advance
      var field = p.identOf(fieldTok.text, p.infoOf(fieldTok))
      if p.at(nsAssign):
        discard p.advance
        let val = p.parseExpr()
        let fd = newNodeI(nkEnumFieldDef, p.infoOf(fieldTok))
        fd.add field
        fd.add val
        field = fd
      enumTy.add field
    discard p.expect(nsRBrace)
  let td = newNodeI(nkTypeDef, info)
  td.add (if isPublic:
            newTree(nkPostfix, info, p.identOf("*", info), p.identOf(nameTok.text, info))
          else:
            p.identOf(nameTok.text, info))
  td.add emptyN(info)
  td.add enumTy
  let sec = newNodeI(nkTypeSection, info)
  sec.add td
  stmts.add sec

proc parseDelegateDecl(p: var NsParser, stmts: var seq[PNode]) =
  ## `delegate R Name(params);` -> `type Name = proc (params): R {.closure.}`.
  ## `{.closure.}` so both plain methods and capturing lambdas fit, as in C#.
  let info = p.infoOf(p.peek)
  var isPublic = false
  while p.peek.kind == nsIdent and p.peek.text in NsTypeModifiers:
    if p.peek.text == "public": isPublic = true
    discard p.advance
  discard p.advance   # delegate
  let ret = p.parseType()
  if p.peek.kind != nsIdent: return
  let nameTok = p.advance
  let params = p.parseParams(ret)
  if p.at(nsSemi): discard p.advance
  let pragma = newNodeI(nkPragma, info)
  pragma.add p.identOf("closure", info)
  let procTy = newTree(nkProcTy, info, params, pragma)
  p.delegates[nameTok.text] = procTy
  let td = newNodeI(nkTypeDef, info)
  td.add (if isPublic:
            newTree(nkPostfix, info, p.identOf("*", info), p.identOf(nameTok.text, info))
          else:
            p.identOf(nameTok.text, info))
  td.add emptyN(info)
  td.add copyTree(procTy)
  let sec = newNodeI(nkTypeSection, info)
  sec.add td
  stmts.add sec

proc parseTypeDecl(p: var NsParser, stmts: var seq[PNode]) =
  var isPublic = false
  while p.peek.kind == nsIdent and p.peek.text in NsTypeModifiers:
    if p.peek.text == "public": isPublic = true
    discard p.advance
  let kw = p.peek.text
  discard p.advance
  if p.peek.kind != nsIdent:
    return
  let nameTok = p.peek
  let clsName = p.advance.text
  var baseType: PNode = nil
  if p.at(nsColon):
    discard p.advance
    baseType = p.parseType()
    while p.at(nsComma):
      discard p.advance
      discard p.parseType()   # additional interfaces, ignored for now
  while not p.at(nsLBrace) and not p.at(nsEof):
    discard p.advance
  discard p.expect(nsLBrace)
  var members: seq[NsMember] = @[]
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    members.add p.parseClassMember(clsName)
  discard p.expect(nsRBrace)
  if kw == "interface":
    return
  # C#: a base with no accessible parameterless constructor forces every derived
  # constructor to name a base constructor explicitly.
  let baseName = if baseType != nil and baseType.kind == nkIdent: baseType.ident.s else: ""
  if baseName.len > 0 and p.classes.hasKey(baseName):
    let bArities = p.classes[baseName].ctorArities
    let baseHasParamless = bArities.len == 0 or 0 in bArities
    if not baseHasParamless:
      var anyCtor = false
      for m in members:
        if m.kind == mkCtor:
          anyCtor = true
          if m.initKind.len == 0:
            localError(p.config, m.info,
              "'" & clsName & "' must call a base constructor: '" & baseName &
              "' has no accessible parameterless constructor")
      if not anyCtor:
        localError(p.config, p.infoOf(nameTok),
          "'" & clsName & "' must define a constructor: '" & baseName &
          "' has no accessible parameterless constructor")
  p.emitClass(clsName, kw == "class", isPublic, baseType, members, stmts)

proc parseNamespace(p: var NsParser, stmts: var seq[PNode]) =
  discard p.advance
  while p.peek.kind in {nsIdent, nsDot}:
    discard p.advance
  discard p.expect(nsLBrace)
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    p.parseTopLevelDecl(stmts)
  discard p.expect(nsRBrace)

proc parseTopLevelDecl(p: var NsParser, stmts: var seq[PNode]) =
  # a type declaration, possibly after modifiers (`public class C`)
  var k = 0
  while p.peekAhead(k).kind == nsIdent and p.peekAhead(k).text in NsTypeModifiers:
    inc k
  let head = p.peekAhead(k)
  if head.kind == nsIdent and head.text in ["class", "struct", "interface"]:
    p.parseTypeDecl(stmts)
  elif head.kind == nsIdent and head.text == "enum":
    p.parseEnumDecl(stmts)
  elif head.kind == nsIdent and head.text == "delegate":
    p.parseDelegateDecl(stmts)
  elif p.peek.kind == nsIdent and p.peek.text in ["using", "import"]:
    p.parseUsing(stmts)
  elif p.peek.kind == nsIdent and p.peek.text == "namespace":
    p.parseNamespace(stmts)
  else:
    let s = p.parseStatement()
    if s != nil: stmts.add s
    if p.at(nsSemi): discard p.advance

proc makeMainCall(p: NsParser, procDef: PNode): PNode =
  ## `when isMainModule: Main()` for the discovered entry point.
  let info = procDef.info
  let call = newNodeI(nkCall, info)
  call.add p.identOf("Main", info)
  let body = newNodeI(nkStmtList, info)
  body.add call
  let branch = newTree(nkElifBranch, info, p.identOf("isMainModule", info), body)
  result = newTree(nkWhenStmt, info, branch)

proc parseNsModule*(source: string; fileIdx: FileIndex; cache: IdentCache;
                   config: ConfigRef): PNode =
  var p = NsParser(toks: tokenize(source), pos: 0, cache: cache,
                   config: config, fileIdx: fileIdx,
                   classes: newTable[string, NsClassInfo](),
                   delegates: newTable[string, PNode]())
  p.prescanClasses()
  var stmts: seq[PNode] = @[]
  while not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    p.parseTopLevelDecl(stmts)
  result = newNodeI(nkStmtList, newLineInfo(fileIdx, 1, 1))
  # No implicit imports: the C# BCL surface is gated by `using` (see parseUsing),
  # so `Console` needs `using System;` and `List<T>` needs
  # `using System.Collections.Generic;`, as in C#.
  for s in stmts: result.add s
  for s in stmts:
    if s.kind != nkProcDef: continue
    var nm = s[0]
    if nm.kind == nkPostfix and nm.len == 2: nm = nm[1]
    if nm.kind == nkIdent and nm.ident.s == "Main":
      result.add p.makeMainCall(s)
      break
