#
#           N# frontend — parser (Phase 0 scaffold)
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
  newAtom(p.cache.getIdent(s), info)

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
    result = p.identOf(t.text, p.infoOf(t))
  of nsLParen:
    discard p.advance
    result = p.parseExpr()
    discard p.expect(nsRParen)
  else:
    p.err(t, "unexpected token '" & t.text & "'")
    discard p.advance
    result = nil

proc applyBuiltins(p: NsParser, n: PNode): PNode =
  ## Phase-0 prelude mapping: `Console.WriteLine(x)` -> `echo x`.
  ## (Phase 1 replaces this with a real `lib/ns` prelude import.)
  if n == nil: return nil
  if n.kind == nkCall and n.len >= 1 and n[0].kind == nkDotExpr and
     n[0][0].kind == nkIdent and n[0][0].ident.s == "Console" and
     n[0][1].kind == nkIdent and n[0][1].ident.s == "WriteLine":
    var call = newNodeI(nkCall, n.info)
    call.add p.identOf("echo", n.info)
    for i in 1 ..< n.len: call.add n[i]
    return call
  result = n

proc parseExpr(p: var NsParser): PNode =
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
      var call = newNodeI(nkCall, result.info)
      call.add result
      while not p.at(nsRParen) and not p.at(nsEof):
        let arg = p.parseExpr()
        if arg != nil: call.add arg
        if p.at(nsComma): discard p.advance else: break
      discard p.expect(nsRParen)
      result = call
    else:
      break
  result = p.applyBuiltins(result)

proc parseBlock(p: var NsParser): PNode =
  let info = p.infoOf(p.peek)
  discard p.expect(nsLBrace)
  result = newNodeI(nkStmtList, info)
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    let e = p.parseExpr()
    if e != nil: result.add e
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

proc parseTopLevelDecl(p: var NsParser, stmts: var seq[PNode])

proc skipUsing(p: var NsParser) =
  # `using <qualified> ;` — recognized and ignored in Phase 0.
  while not p.at(nsSemi) and not p.at(nsEof):
    discard p.advance
  if p.at(nsSemi): discard p.advance

proc parseMember(p: var NsParser, stmts: var seq[PNode]) =
  while p.peek.kind == nsIdent and p.peek.text in NsModifierWords:
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
    stmts.add p.parseMethod(nameTok, retType)
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
  if t.kind == nsIdent and t.text == "using":
    p.skipUsing()
  elif t.kind == nsIdent and t.text == "namespace":
    p.parseNamespace(stmts)
  elif t.kind == nsIdent and t.text in ["class", "struct", "interface"]:
    p.parseTypeDecl(stmts)
  else:
    let e = p.parseExpr()
    if e != nil: stmts.add e
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
  for s in stmts: result.add s
  for s in stmts:
    if s.kind == nkProcDef and s[0].kind == nkIdent and s[0].ident.s == "Main":
      result.add p.makeMainCall(s)
      break
