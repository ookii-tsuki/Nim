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
import ../ast, ../idents, ../lineinfos, ../msgs, ../options
import keywords, lexer

type
  NsParser* = object
    toks: seq[NsToken]
    pos: int
    cache: IdentCache
    config: ConfigRef
    fileIdx: FileIndex

const
  NsModifierWords = ["public", "private", "protected", "internal", "static",
    "virtual", "override", "abstract", "sealed", "readonly", "const", "unsafe",
    "extern", "new"]

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

proc parseType(p: var NsParser): PNode =
  ## Parses a type reference. `void` yields `nkEmpty` (caller treats as no
  ## return type). `T[]` maps to `seq[T]`.
  let t = p.peek
  if t.kind != nsIdent:
    return emptyN(p.infoOf(t))
  discard p.advance
  if t.text == "void":
    return emptyN(p.infoOf(t))
  var base =
    case t.text
    of "int": p.identOf("int32", p.infoOf(t))
    of "uint": p.identOf("uint32", p.infoOf(t))
    of "long": p.identOf("int64", p.infoOf(t))
    of "ulong": p.identOf("uint64", p.infoOf(t))
    of "short": p.identOf("int16", p.infoOf(t))
    of "ushort": p.identOf("uint16", p.infoOf(t))
    of "byte": p.identOf("uint8", p.infoOf(t))
    of "sbyte": p.identOf("int8", p.infoOf(t))
    of "float": p.identOf("float32", p.infoOf(t))
    of "double": p.identOf("float64", p.infoOf(t))
    of "bool": p.identOf("bool", p.infoOf(t))
    of "char": p.identOf("char", p.infoOf(t))
    of "string": p.identOf("string", p.infoOf(t))
    of "object": p.identOf("RootRef", p.infoOf(t))
    else: p.identOf(t.text, p.infoOf(t))
  while p.at(nsLBracket) and p.peekAhead(1).kind == nsRBracket:
    discard p.advance
    discard p.advance
    base = newTree(nkBracketExpr, p.infoOf(t), p.identOf("seq", p.infoOf(t)), base)
  result = base

proc parseExpr(p: var NsParser): PNode
proc parseStatement(p: var NsParser): PNode

proc parsePrimary(p: var NsParser): PNode =
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
      result = newTree(nkDotExpr, p.infoOf(nameTok), result,
                       p.identOf(nameTok.text, p.infoOf(nameTok)))
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

proc parseMethod(p: var NsParser, nameTok: NsToken, retType: PNode): PNode =
  let info = p.infoOf(nameTok)
  let params = newNodeI(nkFormalParams, info)
  params.add retType
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
    params.add defs
    if p.at(nsComma): discard p.advance else: break
  discard p.expect(nsRParen)
  var finalParams = params
  if nameTok.text == "Main":
    # Phase 0 entry point: parameters are ignored (called as `Main()`).
    finalParams = newNodeI(nkFormalParams, info)
    finalParams.add retType
  let body = p.parseBlock()
  result = newNodeI(nkProcDef, info, 7)
  result[0] = p.identOf(nameTok.text, info)   # name
  result[1] = emptyN(info)                    # pattern
  result[2] = emptyN(info)                    # generic params
  result[3] = finalParams                     # formal params
  result[4] = emptyN(info)                    # pragmas
  result[5] = emptyN(info)                    # exceptions
  result[6] = body                            # body

proc looksLikeDecl(p: NsParser): bool =
  ## A simple statement is a declaration when it starts with `var`/`let`/`const`
  ## or with `Type name` / `Type[] name`.
  if p.peek.kind == nsIdent and p.peek.text in ["var", "let", "const"]:
    return true
  if p.peek.kind == nsIdent:
    var k = 1
    if p.peekAhead(1).kind == nsLBracket and p.peekAhead(2).kind == nsRBracket:
      k = 3
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
  if name.len == 0 or name == "System" or name.startsWith("System."):
    return
  let imp = newNodeI(nkImportStmt, info)
  imp.add newAtom(nkStrLit, name, info)
  stmts.add imp

proc parseMember(p: var NsParser, stmts: var seq[PNode]) =
  var isPublic = false
  while p.peek.kind == nsIdent and p.peek.text in NsModifierWords:
    if p.peek.text == "public": isPublic = true
    discard p.advance
  let typeTok = p.peek
  if typeTok.kind != nsIdent:
    discard p.advance
    return
  let retType = p.parseType()
  if p.peek.kind != nsIdent:
    p.skipToSemi()
    return
  let nameTok = p.advance
  if p.at(nsLParen):
    var procDef = p.parseMethod(nameTok, retType)
    if isPublic:
      procDef[0] = newTree(nkPostfix, p.infoOf(nameTok),
                           p.identOf("*", p.infoOf(nameTok)), procDef[0])
    stmts.add procDef
  else:
    p.skipToSemi()   # a field declaration

proc parseTypeDecl(p: var NsParser, stmts: var seq[PNode]) =
  ## `class`/`struct`/`interface`: Phase 0 lowers members to top-level procs.
  discard p.advance
  if p.peek.kind == nsIdent:
    discard p.advance   # type name
  while not p.at(nsLBrace) and not p.at(nsEof):
    discard p.advance   # base list / generic params, etc.
  discard p.expect(nsLBrace)
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    p.parseMember(stmts)
  discard p.expect(nsRBrace)

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
  let t = p.peek
  if t.kind == nsIdent and t.text in ["using", "import"]:
    p.parseUsing(stmts)
  elif t.kind == nsIdent and t.text == "namespace":
    p.parseNamespace(stmts)
  elif t.kind == nsIdent and t.text in ["class", "struct", "interface"]:
    p.parseTypeDecl(stmts)
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
                   config: config, fileIdx: fileIdx)
  var stmts: seq[PNode] = @[]
  while not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    p.parseTopLevelDecl(stmts)
  result = newNodeI(nkStmtList, newLineInfo(fileIdx, 1, 1))
  # Auto-import the N# prelude (lib/pure/ns/prelude.nim), which provides the
  # C#-facing surface (Console, ...).
  let prelude = newNodeI(nkImportStmt, newLineInfo(fileIdx, 1, 1))
  prelude.add newAtom(nkStrLit, "ns/prelude", newLineInfo(fileIdx, 1, 1))
  result.add prelude
  for s in stmts: result.add s
  for s in stmts:
    if s.kind == nkProcDef and s[0].kind == nkIdent and s[0].ident.s == "Main":
      result.add p.makeMainCall(s)
      break
