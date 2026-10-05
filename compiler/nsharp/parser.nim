# N# frontend - parser
#
# Tokens to `ast.NsNode`. Pure grammar: no C#-to-Nim name mapping, no lowering and
# no access-control checking; those live in `desugar.nim`/`bcl.nim` and `sema.nim`.
# The only external dependency is the config, for diagnostics.
#
# `>>` splitting lives in `lexer.splitShr`. Unrecognised or unimplemented
# constructs, and modifiers N# does not implement, are reported rather than
# ignored; skipping happens only as error recovery, after a diagnostic.

import std/[strutils, sets]
import ../lineinfos, ../msgs, ../options
import ast, bcl, diagnostics, lexer

type
  NsParser = object
    toks: seq[NsToken]
    pos: int
    config: ConfigRef
    fileIdx: FileIndex
    condSeq: int            ## counts `?.` markers, so each chain link gets its own
    surface: NsBclSurface   ## the library's declarations, for telling a cast apart
    aliases: HashSet[string]
      ## The namespace aliases this file's own `using` directives introduce. A type
      ## reached through one (`(P.Gadget)x`) is a cast, not a parenthesised
      ## expression. A plain namespace name needs no record here: namespaces are
      ## global, so the compilation's own gather of them answers for every file.

const
  NsModifierWords = ["public", "private", "protected", "internal", "static",
    "virtual", "override", "abstract", "sealed", "readonly", "const", "unsafe",
    "extern", "new"]
  NsTypeModifiers = ["public", "private", "protected", "internal", "abstract",
    "sealed", "static"]
  ## Modifiers N# actually implements. Anything else recognised but unimplemented
  ## is reported by `parseModifierList` instead of being silently dropped.
  NsMemberModifiers = ["public", "private", "protected", "internal", "static"]
  NsClassModifiers = ["public", "private", "protected", "internal"]

# --- token helpers ----------------------------------------------------------

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

proc here(p: NsParser): TLineInfo {.inline.} = p.infoOf(p.peek)

proc err(p: NsParser, t: NsToken, d: NsDiag; args: varargs[string]) =
  nsError(p.config, p.infoOf(t), d, args)

proc diagForExpected(k: NsTokenKind): NsDiag =
  ## The code C# reports for a missing token of this kind.
  case k
  of nsSemi: ndSemicolonExpected
  of nsRParen: ndCloseParenExpected
  of nsRBrace: ndCloseBraceExpected
  of nsLBrace: ndOpenBraceExpected
  of nsIdent: ndIdentifierExpected
  else: ndSyntaxErrorExpected

proc expect(p: var NsParser, k: NsTokenKind): NsToken =
  if p.peek.kind == k: return p.advance
  p.err(p.peek, diagForExpected(k), $k)
  return p.peek

proc expectGt(p: var NsParser) =
  ## Closes a generic argument list. A `>>` is split by the lexer, which owns
  ## token surgery; this just consumes one `>`.
  if p.at(nsGt):
    discard p.advance
  elif splitShr(p.toks, p.pos):
    discard p.advance   # the first of the two `>` the split produced
  else:
    discard p.expect(nsGt)

proc atGtClose(p: NsParser): bool {.inline.} =
  p.at(nsGt) or p.at(nsShr)

proc skipBalancedGt(p: NsParser; start: int): int =
  ## Index just past the generic argument list starting at `start` (a `<`), or
  ## -1 when it is unterminated. A `>>` closes two levels.
  result = -1
  var i = start
  var depth = 0
  while true:
    case p.peekAhead(i).kind
    of nsEof: return -1
    of nsLt: inc depth
    of nsGt:
      dec depth
      if depth <= 0: return i + 1
    of nsShr:
      depth -= 2
      if depth <= 0: return i + 1
    else: discard
    inc i

# --- types ------------------------------------------------------------------

proc parseDottedName(p: var NsParser): string =
  ## `A.B.C` as written, or "" when no identifier is next.
  result = ""
  if p.peek.kind == nsIdent:
    result = p.advance.text
    while p.at(nsDot) and p.peekAhead(1).kind == nsIdent:
      discard p.advance
      result.add "."
      result.add p.advance.text

proc parseType(p: var NsParser): NsNode =
  ## A type as written: `void` becomes an `nsnVoidType`, `T[]` an `nsnArrayType`,
  ## and a name an `nsnTypeName` carrying its generic arguments and qualifier.
  ## Names are kept as written; mapping them to Nim spellings is `desugar`'s job.
  let t = p.peek
  if t.kind != nsIdent:
    return nsn(nsnEmpty, p.infoOf(t))
  if t.text == "void":
    discard p.advance
    return nsnVoidType(p.infoOf(t))
  result = nsnTypeName(p.parseDottedName(), p.infoOf(t))
  if p.at(nsLt):
    discard p.advance
    while not atGtClose(p) and not p.at(nsEof):
      result.add p.parseType()
      if p.at(nsComma): discard p.advance else: break
    p.expectGt()
  if p.at(nsQuestion):
    ## `T?`. It sits against the type, so a `?:` elsewhere is unaffected, and it is
    ## read before `[]` because `int?[]` is an array of nullable ints in C#.
    discard p.advance
    result = nsnNullableType(result, p.infoOf(t))
  while p.at(nsLBracket) and p.peekAhead(1).kind == nsRBracket:
    discard p.advance
    discard p.advance
    result = nsnArrayType(result, p.infoOf(t))

# --- expressions ------------------------------------------------------------

proc parseExpr(p: var NsParser): NsNode
proc parseBlock(p: var NsParser): NsNode
proc parseStatement(p: var NsParser): NsNode
proc parseNew(p: var NsParser, kw: NsToken): NsNode
proc parseUnary(p: var NsParser): NsNode

proc skipParens(p: var NsParser) =
  ## Consumes a balanced `( ... )`. The caller has already reported why the
  ## construct cannot be lowered, so this only keeps the parse in step.
  if not p.at(nsLParen): return
  var depth = 0
  while not p.at(nsEof):
    if p.at(nsLParen): inc depth
    elif p.at(nsRParen):
      dec depth
      if depth == 0:
        discard p.advance
        return
    discard p.advance

proc parseNameof(p: var NsParser; t: NsToken): NsNode =
  ## `nameof(a.b.c)` is a string literal of the last written name, so it is answered
  ## here rather than lowered.
  discard p.expect(nsLParen)
  var name = ""
  var stop = false
  var depth = 1
  while not p.at(nsEof):
    if p.at(nsLParen): inc depth
    elif p.at(nsRParen):
      dec depth
      if depth == 0: break
    elif depth == 1 and not stop:
      if p.peek.kind == nsIdent: name = p.peek.text
      elif p.peek.kind == nsLt: stop = true
    discard p.advance
  discard p.expect(nsRParen)
  result = nsnStrLit(name, p.infoOf(t))

proc parseDefault(p: var NsParser; t: NsToken): NsNode =
  ## `default(T)`. The bare `default` is typed by its target, which the frontend
  ## does not track here.
  if not p.at(nsLParen):
    p.err(t, ndUnsupported, "a target-typed 'default'")
    return nsn(nsnEmpty, p.infoOf(t))
  discard p.advance
  let ty = p.parseType()
  discard p.expect(nsRParen)
  result = nsn(nsnDefault, p.infoOf(t))
  result.typ = ty

proc isTypeName(p: NsParser; name: string): bool =
  ## True when a name is a type: C#'s own vocabulary, a type the library declares,
  ## a type or namespace this compilation declares, or a namespace alias this file
  ## introduces. The grammar has to tell a cast from a parenthesised expression, and
  ## this is the symbol table it reaches that through.
  p.surface.isKnownTypeName(name) or p.aliases.contains(name)

proc looksLikeCast(p: NsParser): bool =
  ## `(T)x` against `(x)`. The parenthesised name must be a type -- C#'s, the
  ## library's, this compilation's, or a namespace this file imports -- and must be
  ## followed by something that starts a value.
  if p.peek.kind != nsLParen: return false
  var i = 1
  if p.peekAhead(i).kind != nsIdent: return false
  if not p.isTypeName(p.peekAhead(i).text): return false
  inc i
  while p.peekAhead(i).kind == nsDot and p.peekAhead(i + 1).kind == nsIdent:
    i += 2
  if p.peekAhead(i).kind == nsLt:
    i = skipBalancedGt(p, i)
    if i < 0: return false
  while p.peekAhead(i).kind == nsLBracket and p.peekAhead(i + 1).kind == nsRBracket:
    i += 2
  if p.peekAhead(i).kind != nsRParen: return false
  p.peekAhead(i + 1).kind in {nsIdent, nsIntLit, nsFloatLit, nsStrLit, nsCharLit,
                              nsLParen, nsBang, nsTilde, nsMinus, nsPlus,
                              nsStar, nsAmp}

proc parseCast(p: var NsParser): NsNode =
  ## `(T)x` is a Nim conversion, which is also how a ref object is downcast.
  let info = p.here()
  discard p.expect(nsLParen)
  let typ = p.parseType()
  discard p.expect(nsRParen)
  result = nsn(nsnCast, info)
  result.typ = typ
  result.body = p.parseUnary()

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

proc parseLambda(p: var NsParser): NsNode =
  ## `x => e`, `(a, b) => e`, `(a, b) => { ... }`. Parameters without a written
  ## type keep `typ == nil`; `desugar` fills those from the declared delegate
  ## type, which is where the target type is finally known.
  let info = p.here()
  result = nsn(nsnLambda, info)
  if p.peek.kind == nsIdent:
    result.addParam nsnParam(p.advance.text, nil, info)
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
        result.addParam nsnParam(p.advance.text, nsnTypeName(a, info), info)
      else:
        result.addParam nsnParam(a, nil, info)
    discard p.expect(nsRParen)
  discard p.expect(nsArrow)
  if p.at(nsLBrace):
    result.body = p.parseBlock()
  else:
    let b = nsn(nsnBlock, info)
    b.add p.parseExpr()
    result.body = b

proc parsePrimary(p: var NsParser): NsNode =
  if looksLikeLambda(p):
    return p.parseLambda()
  let t = p.peek
  case t.kind
  of nsStrLit:
    discard p.advance
    result = nsnStrLit(t.text, p.infoOf(t))
  of nsIntLit:
    discard p.advance
    var v: BiggestInt = 0
    try: v = parseBiggestInt(t.text)
    except ValueError: discard
    result = nsnIntLit(v, p.infoOf(t))
  of nsFloatLit:
    discard p.advance
    var v: BiggestFloat = 0.0
    try: v = BiggestFloat(parseFloat(t.text))
    except ValueError: discard
    result = nsnFloatLit(v, p.infoOf(t))
  of nsCharLit:
    discard p.advance
    var v = 0
    if t.text.len == 1: v = ord(t.text[0])
    result = nsnCharLit(BiggestInt(v), p.infoOf(t))
  of nsIdent:
    discard p.advance
    case t.text
    of "null": result = nsn(nsnNull, p.infoOf(t))
    of "new": result = p.parseNew(t)
    of "this": result = nsn(nsnThis, p.infoOf(t))
    of "true": result = nsnBoolLit(true, p.infoOf(t))
    of "false": result = nsnBoolLit(false, p.infoOf(t))
    of "nameof": result = p.parseNameof(t)
    of "default": result = p.parseDefault(t)
    of "sizeof", "typeof":
      ## `sizeof` needs an unsafe context and `typeof` a type value, neither of
      ## which N# has yet.
      p.err(t, ndUnsupported, "the '" & t.text & "' operator")
      p.skipParens()
      result = nsn(nsnEmpty, p.infoOf(t))
    else: result = nsnIdent(t.text, p.infoOf(t))
  of nsLParen:
    if looksLikeCast(p):
      return p.parseCast()
    discard p.advance
    result = p.parseExpr()
    discard p.expect(nsRParen)
  else:
    p.err(t, ndInvalidExpressionTerm, t.text)
    discard p.advance
    result = nil

const NsCondMarker = "$cond"
  ## The name a `?.` tail uses for the guarded value; `desugar.nim` binds it to a
  ## temporary. `$` cannot appear in a C# identifier, so no source name collides with
  ## it, and each link of a chain gets its own numbered marker.

proc parsePostfixTail(p: var NsParser; start: NsNode): NsNode =
  ## The accesses that may follow an expression: `.name`, `(args)`, `[i]`, `++`/`--`
  ## and the null-conditional forms. Everything after a `?.` belongs to the guarded
  ## side, because C# evaluates the rest of the chain only when the receiver is not
  ## null, so a `?.` tail is parsed by this same loop with a marker standing in for
  ## the receiver.
  result = start
  while true:
    if p.at(nsDot):
      discard p.advance
      let nameTok = p.peek
      if nameTok.kind != nsIdent: break
      discard p.advance
      result = nsnMember(result, nameTok.text, p.infoOf(nameTok))
    elif p.at(nsQuestionDot):
      let opTok = p.advance
      let nameTok = p.peek
      ## `?.` is one token, so the member name follows it directly; the rest of the
      ## chain is parsed on from there and belongs to the guarded side.
      if nameTok.kind != nsIdent: break
      discard p.advance
      inc p.condSeq
      let marker = nsnIdent(NsCondMarker & $p.condSeq, p.infoOf(opTok))
      let member = nsnMember(marker, nameTok.text, p.infoOf(nameTok))
      let n = nsn(nsnNullDot, p.infoOf(opTok))
      n.name = marker.name
      n.body = result
      n.sons = @[parsePostfixTail(p, member)]
      result = n
    elif p.at(nsQuestion) and p.peekAhead(1).kind == nsLBracket:
      let qTok = p.advance
      discard p.advance                       # the `[`
      inc p.condSeq
      let marker = nsnIdent(NsCondMarker & $p.condSeq, p.infoOf(qTok))
      let idx = nsn(nsnIndex, p.infoOf(qTok))
      idx.body = marker
      idx.add p.parseExpr()
      discard p.expect(nsRBracket)
      let n = nsn(nsnNullDot, p.infoOf(qTok))
      n.name = marker.name
      n.body = result
      n.sons = @[parsePostfixTail(p, idx)]
      result = n
    elif p.at(nsLParen):
      let info = result.info
      discard p.advance
      let call = nsn(nsnCall, info)
      call.body = result
      while not p.at(nsRParen) and not p.at(nsEof):
        call.add p.parseExpr()
        if p.at(nsComma): discard p.advance else: break
      discard p.expect(nsRParen)
      result = call
    elif p.at(nsLBracket):
      let info = result.info
      discard p.advance
      let idx = nsn(nsnIndex, info)
      idx.body = result
      idx.add p.parseExpr()
      discard p.expect(nsRBracket)
      result = idx
    elif p.at(nsPlusPlus) or p.at(nsMinusMinus):
      let opTok = p.advance
      let n = nsn(nsnIncDec, p.infoOf(opTok))
      n.name = if opTok.kind == nsPlusPlus: "inc" else: "dec"
      n.body = result
      result = n
    else:
      break

proc parsePostfix(p: var NsParser): NsNode =
  result = p.parsePrimary()
  if result == nil: return
  result = p.parsePostfixTail(result)

proc parseUnary(p: var NsParser): NsNode =
  let t = p.peek
  case t.kind
  of nsMinus, nsPlus, nsBang, nsTilde:
    discard p.advance
    let operand = p.parseUnary()
    let op = case t.kind
      of nsMinus: "-"
      of nsPlus: "+"
      else: "not"
    result = nsnUnary(op, operand, p.infoOf(t))
  else:
    result = p.parsePostfix()

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

proc parseBinary(p: var NsParser; minPrec: int): NsNode =
  result = p.parseUnary()
  while true:
    var prec = binPrec(p.peek.kind)
    let typeOp = prec == 0 and p.at(nsIdent) and p.peek.text in ["is", "as"]
    let coalesce = prec == 0 and p.at(nsQuestionQuestion)
    if typeOp:
      ## C# puts `is` and `as` at the relational level, and their right operand is
      ## a type rather than an expression.
      prec = 9
    elif coalesce:
      ## `??` sits above the conditional operator and below `||`.
      prec = 2
    if prec < minPrec or prec == 0: break
    let opTok = p.advance
    if coalesce:
      let rhs = p.parseBinary(prec + 1)
      let n = nsn(nsnNullCoalesce, p.infoOf(opTok))
      n.name = "??"
      n.sons = @[result, rhs]
      result = n
    elif typeOp:
      let n = nsn(if opTok.text == "is": nsnIs else: nsnAs, p.infoOf(opTok))
      n.body = result
      n.typ = p.parseType()
      result = n
    else:
      let rhs = p.parseBinary(prec + 1)
      result = nsnBinary(opName(opTok.kind), result, rhs, p.infoOf(opTok))

proc parseTernary(p: var NsParser): NsNode =
  result = p.parseBinary(1)
  if p.at(nsQuestion):
    let info = p.here()
    discard p.advance
    let a = p.parseExpr()
    discard p.expect(nsColon)
    let b = p.parseExpr()
    let n = nsn(nsnTernary, info)
    n.sons = @[result, a, b]
    result = n

proc parseExpr(p: var NsParser): NsNode =
  result = p.parseTernary()

proc parseNew(p: var NsParser, kw: NsToken): NsNode =
  ## `new T(args)` -> `nsnNew`; `new T[n]` -> `nsnNewArray`; `new T[] { .. }` ->
  ## `nsnArrayLit`. The type name is kept verbatim; `desugar` maps it.
  let info = p.infoOf(kw)
  if p.peek.kind != nsIdent:
    result = nsn(nsnCall, info)
    result.body = nsnIdent("new", info)
    return
  let typeTok = p.advance
  var typ = nsnTypeName(typeTok.text, info)
  while p.at(nsDot) and p.peekAhead(1).kind == nsIdent:
    discard p.advance
    typ.name.add "."
    typ.name.add p.advance.text
  if p.at(nsLt):
    discard p.advance
    while not atGtClose(p) and not p.at(nsEof):
      typ.add p.parseType()
      if p.at(nsComma): discard p.advance else: break
    p.expectGt()
  elif p.at(nsLBracket):
    discard p.advance
    if p.at(nsRBracket):
      discard p.advance
      result = nsn(nsnArrayLit, info)
      if p.at(nsLBrace):
        discard p.advance
        while not p.at(nsRBrace) and not p.at(nsEof):
          result.add p.parseExpr()
          if p.at(nsComma): discard p.advance else: break
        discard p.expect(nsRBrace)
      return
    else:
      result = nsn(nsnNewArray, info)
      result.typ = typ
      result.add p.parseExpr()
      discard p.expect(nsRBracket)
      return
  result = nsn(nsnNew, info)
  result.typ = typ
  if p.at(nsLParen):
    discard p.advance
    while not p.at(nsRParen) and not p.at(nsEof):
      result.add p.parseExpr()
      if p.at(nsComma): discard p.advance else: break
    discard p.expect(nsRParen)

# --- statements -------------------------------------------------------------

proc parseBlock(p: var NsParser): NsNode =
  let info = p.here()
  discard p.expect(nsLBrace)
  result = nsn(nsnBlock, info)
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    let s = p.parseStatement()
    if s != nil: result.add s
    if p.at(nsSemi): discard p.advance
  discard p.expect(nsRBrace)

proc parseParams(p: var NsParser): seq[NsNode] =
  ## A C# parameter list. A parameter written without a name keeps the
  ## placeholder `arg`, matching the previous behaviour.
  result = @[]
  discard p.expect(nsLParen)
  while not p.at(nsRParen) and not p.at(nsEof):
    let info = p.here()
    let ty = p.parseType()
    if p.peek.kind != nsIdent:
      p.err(p.peek, ndIdentifierExpected)
    var pname = ""
    if p.peek.kind == nsIdent:
      pname = p.advance.text
    result.add nsnParam(pname, ty, info)
    if p.at(nsComma): discard p.advance else: break
  discard p.expect(nsRParen)

proc looksLikeDecl(p: NsParser): bool =
  ## C# decides between a local declaration and an expression statement
  ## syntactically: a local declaration is `Type identifier declarator`. So
  ## recognise the *shape* of a type (a qualified name, an optional generic
  ## argument list, and any number of `[]` suffixes) and then require an
  ## identifier followed by a declarator token. Without that last requirement
  ## `Foo<int>(x);` would be read as a declaration; with it, it is correctly an
  ## expression statement.
  if p.peek.kind != nsIdent: return false
  if p.peek.text in ["var", "let", "const"]: return true
  var i = 1
  while p.peekAhead(i).kind == nsDot and p.peekAhead(i + 1).kind == nsIdent:
    i += 2
  if p.peekAhead(i).kind == nsLt:
    i = skipBalancedGt(p, i)
    if i < 0: return false
  if p.peekAhead(i).kind == nsQuestion:
    ## `int? x = ...`. A ternary in statement position still fails the declarator
    ## test below, so `x ? y : z;` stays an expression.
    inc i
  while p.peekAhead(i).kind == nsLBracket and p.peekAhead(i + 1).kind == nsRBracket:
    i += 2
  if p.peekAhead(i).kind != nsIdent: return false
  p.peekAhead(i + 1).kind in {nsAssign, nsSemi, nsComma, nsRParen, nsEof}

proc parseVarDecl(p: var NsParser): NsNode =
  ## `var`/`let`/`const` introduce an untyped declaration; otherwise the type is
  ## written first, as in C#.
  let info = p.here()
  result = nsn(nsnLocalDecl, info)
  var hasType = true
  if p.at(nsIdent) and p.peek.text == "var":
    discard p.advance
    hasType = false
  elif p.at(nsIdent) and p.peek.text == "let":
    result.declKind = dkLet
    hasType = false
    discard p.advance
  elif p.at(nsIdent) and p.peek.text == "const":
    result.declKind = dkConst
    hasType = false
    discard p.advance
  if hasType:
    result.typ = p.parseType()
  let nameTok = p.peek
  discard p.advance
  result.name = nameTok.text
  if p.at(nsAssign):
    discard p.advance
    result.body = p.parseExpr()

proc parseSimpleStmt(p: var NsParser): NsNode =
  if looksLikeDecl(p):
    return p.parseVarDecl()
  let lhs = p.parseExpr()
  if p.at(nsAssign):
    discard p.advance
    result = nsn(nsnAssign, lhs.info)
    result.sons = @[lhs, p.parseExpr()]
    return
  let compound = case p.peek.kind
    of nsPlusEq: "+"
    of nsMinusEq: "-"
    of nsStarEq: "*"
    of nsSlashEq: "/"
    of nsPercentEq: "mod"
    of nsQuestionQuestionEq: "??"
    of nsAmpEq: "and"
    of nsPipeEq: "or"
    of nsCaretEq: "xor"
    of nsShlEq: "shl"
    of nsShrEq: "shr"
    else: ""
  if compound.len > 0:
    discard p.advance
    result = nsn(nsnAssign, lhs.info)
    result.name = compound
    result.sons = @[lhs, p.parseExpr()]
    return
  result = nsn(nsnExprStmt, lhs.info)
  result.body = lhs

# --- control flow -----------------------------------------------------------

proc parseIf(p: var NsParser): NsNode
proc parseWhile(p: var NsParser): NsNode
proc parseDoWhile(p: var NsParser): NsNode
proc parseChecked(p: var NsParser; isChecked: bool): NsNode
proc parseFor(p: var NsParser): NsNode
proc parseForeach(p: var NsParser): NsNode
proc parseSwitch(p: var NsParser): NsNode
proc parseTry(p: var NsParser): NsNode

proc parseStatement(p: var NsParser): NsNode =
  let t = p.peek
  if t.kind == nsLBrace:
    let info = p.infoOf(t)
    result = nsn(nsnBlockStmt, info)
    result.sons = p.parseBlock().sons
    return
  if t.kind == nsIdent:
    case t.text
    of "if": return p.parseIf()
    of "while": return p.parseWhile()
    of "do": return p.parseDoWhile()
    of "checked": return p.parseChecked(true)
    of "unchecked": return p.parseChecked(false)
    of "for": return p.parseFor()
    of "foreach": return p.parseForeach()
    of "switch": return p.parseSwitch()
    of "try": return p.parseTry()
    of "throw":
      result = nsn(nsnThrow, p.infoOf(t))
      discard p.advance
      result.body = p.parseExpr()
      return
    of "return":
      result = nsn(nsnReturn, p.infoOf(t))
      discard p.advance
      if not (p.at(nsSemi) or p.at(nsRBrace) or p.at(nsEof)):
        result.body = p.parseExpr()
      return
    of "break":
      result = nsn(nsnBreak, p.infoOf(t))
      discard p.advance
      return
    of "continue":
      result = nsn(nsnContinue, p.infoOf(t))
      discard p.advance
      return
    else: discard
  result = p.parseSimpleStmt()

proc parseIf(p: var NsParser): NsNode =
  let info = p.here()
  discard p.advance
  discard p.expect(nsLParen)
  let cond = p.parseExpr()
  discard p.expect(nsRParen)
  result = nsn(nsnIf, info)
  let br = nsn(nsnIfBranch, info)
  br.body = cond
  br.sons = p.parseBlock().sons
  result.add br
  while p.at(nsIdent) and p.peek.text == "else":
    let elseInfo = p.here()
    discard p.advance
    if p.at(nsIdent) and p.peek.text == "if":
      discard p.advance
      discard p.expect(nsLParen)
      let c2 = p.parseExpr()
      discard p.expect(nsRParen)
      let b2 = nsn(nsnIfBranch, elseInfo)
      b2.body = c2
      b2.sons = p.parseBlock().sons
      result.add b2
    else:
      let eb = nsn(nsnElseBranch, elseInfo)
      eb.sons = p.parseBlock().sons
      result.add eb
      break

proc parseWhile(p: var NsParser): NsNode =
  let info = p.here()
  discard p.advance
  discard p.expect(nsLParen)
  let cond = p.parseExpr()
  discard p.expect(nsRParen)
  result = nsn(nsnWhile, info)
  result.body = cond
  result.sons = p.parseBlock().sons

proc parseDoWhile(p: var NsParser): NsNode =
  ## `do { B } while (c);`, whose body runs before the condition is first read.
  let info = p.here()
  discard p.advance
  result = nsn(nsnDoWhile, info)
  result.sons = p.parseBlock().sons
  if p.at(nsIdent) and p.peek.text == "while":
    discard p.advance
  else:
    p.err(p.peek, ndSyntaxErrorExpected, "while")
  discard p.expect(nsLParen)
  result.body = p.parseExpr()
  discard p.expect(nsRParen)
  if p.at(nsSemi): discard p.advance

proc parseChecked(p: var NsParser; isChecked: bool): NsNode =
  ## `checked { ... }` turns overflow checking on for its statements and
  ## `unchecked` turns it off.
  let info = p.here()
  let kwTok = p.advance
  if not p.at(nsLBrace):
    ## The expression form would need a statement to carry the switch.
    p.err(kwTok, ndUnsupported, "the '" & kwTok.text & "(...)' form")
    p.skipParens()
    return nsn(nsnEmpty, info)
  result = nsn(if isChecked: nsnChecked else: nsnUnchecked, info)
  result.sons = p.parseBlock().sons

proc parseFor(p: var NsParser): NsNode =
  let info = p.here()
  discard p.advance
  discard p.expect(nsLParen)
  var init: NsNode = nil
  if not p.at(nsSemi): init = p.parseSimpleStmt()
  discard p.expect(nsSemi)
  var cond: NsNode = nil
  if not p.at(nsSemi): cond = p.parseExpr()
  discard p.expect(nsSemi)
  var step: NsNode = nil
  if not p.at(nsRParen): step = p.parseSimpleStmt()
  discard p.expect(nsRParen)
  result = nsn(nsnFor, info)
  let header = nsn(nsnForHeader, info)
  header.sons = @[init, cond, step]
  result.body = header
  result.sons = p.parseBlock().sons

proc parseForeach(p: var NsParser): NsNode =
  let info = p.here()
  discard p.advance
  discard p.expect(nsLParen)
  result = nsn(nsnForeach, info)
  if p.at(nsIdent) and p.peek.text == "var":
    discard p.advance
  else:
    result.typ = p.parseType()
  let nameTok = p.peek
  discard p.advance
  result.name = nameTok.text
  if p.at(nsIdent) and p.peek.text == "in":
    discard p.advance
  else:
    p.err(p.peek, ndForeachInExpected)
  result.body = p.parseExpr()
  discard p.expect(nsRParen)
  result.sons = p.parseBlock().sons

proc parseSwitchBody(p: var NsParser): seq[NsNode] =
  ## Statements of one switch section: up to the next label or the closing brace.
  ## The section's `break` (if any) is kept in the tree; dropping it is part of
  ## lowering, not parsing.
  result = @[]
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    if p.at(nsIdent) and p.peek.text in ["case", "default"]:
      break
    result.add p.parseStatement()
    if p.at(nsSemi): discard p.advance

proc parseSwitch(p: var NsParser): NsNode =
  let info = p.here()
  discard p.advance
  discard p.expect(nsLParen)
  result = nsn(nsnSwitch, info)
  result.body = p.parseExpr()
  discard p.expect(nsRParen)
  discard p.expect(nsLBrace)
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    if p.at(nsIdent) and p.peek.text == "case":
      let sinfo = p.here()
      let sec = nsn(nsnSwitchSection, sinfo)
      sec.name = "case"
      # stacked labels (`case 1: case 2:`) form one section
      while p.at(nsIdent) and p.peek.text == "case":
        discard p.advance
        while true:
          sec.add p.parseExpr()
          if p.at(nsComma): discard p.advance else: break
        discard p.expect(nsColon)
      let b = nsn(nsnBlock, sinfo)
      b.sons = p.parseSwitchBody()
      sec.body = b
      result.add sec
    elif p.at(nsIdent) and p.peek.text == "default":
      let sinfo = p.here()
      discard p.advance
      discard p.expect(nsColon)
      let sec = nsn(nsnSwitchSection, sinfo)
      sec.name = "default"
      let b = nsn(nsnBlock, sinfo)
      b.sons = p.parseSwitchBody()
      sec.body = b
      result.add sec
      break
    else:
      discard p.advance
  discard p.expect(nsRBrace)

proc parseTry(p: var NsParser): NsNode =
  let info = p.here()
  discard p.advance
  result = nsn(nsnTry, info)
  result.body = p.parseBlock()
  while true:
    if p.at(nsIdent) and p.peek.text == "catch":
      let cinfo = p.here()
      discard p.advance
      let c = nsn(nsnCatch, cinfo)
      c.name = "e"
      if p.at(nsLParen):
        discard p.advance
        c.typ = p.parseType()
        if p.peek.kind == nsIdent:
          c.name = p.advance.text
        discard p.expect(nsRParen)
      c.body = p.parseBlock()
      result.add c
    elif p.at(nsIdent) and p.peek.text == "finally":
      let finfo = p.here()
      discard p.advance
      let f = nsn(nsnFinally, finfo)
      f.body = p.parseBlock()
      result.add f
      break
    else:
      break

# --- declarations -----------------------------------------------------------

proc parseTopLevelDecl(p: var NsParser; nsPrefix = ""): NsNode

proc accessOf(mods: seq[string]): NsAccess =
  ## The last recognised access modifier wins, as in C#.
  result = aPrivate
  for w in mods:
    case w
    of "public": result = aPublic
    of "protected": result = aProtected
    of "internal": result = aInternal
    of "private": result = aPrivate
    else: discard

proc accessOfTopLevel(mods: seq[string]): NsAccess =
  ## A top-level type is `internal` by default, not `private`: in C# it is
  ## visible to every file of the same program without any modifier. An explicit
  ## modifier still wins, so `private class X` stays private.
  for w in mods:
    if w in ["public", "private", "protected", "internal"]:
      return accessOf(mods)
  aInternal

proc parseModifierList(p: var NsParser; words, allowed: openArray[string]): seq[string] =
  ## Consumes the leading modifier words of a declaration. A modifier N# does not
  ## implement yet is reported rather than silently ignored: accepting `override`
  ## and then emitting a plain method is a silent no-op, which is worse than
  ## refusing to compile.
  result = @[]
  while p.at(nsIdent) and p.peek.text in words:
    let tok = p.advance
    if tok.text notin allowed:
      p.err(tok, ndUnsupported, "the '" & tok.text & "' modifier")
    result.add tok.text

proc recoverToSemi(p: var NsParser) =
  ## Error recovery after a diagnostic has already been reported: skip to the end
  ## of the declaration. Never used to hide a construct silently.
  while not p.at(nsSemi) and not p.at(nsEof) and not p.at(nsRBrace):
    discard p.advance

proc parseClassMember(p: var NsParser; clsName: string;
                      isInterface = false): NsNode =
  let modInfo = p.here()
  let mods = p.parseModifierList(NsModifierWords, NsMemberModifiers)
  let isStatic = "static" in mods
  let attrs = NsAttrs(access: accessOf(mods), isStatic: isStatic)

  # constructor: `ClassName(params)` (no return type, as in C#)
  if p.at(nsIdent) and p.peek.text == clsName and p.peekAhead(1).kind == nsLParen:
    result = nsn(nsnCtorDecl, p.here())
    result.name = clsName
    result.attrs = attrs
    discard p.advance
    result.params = p.parseParams()
    if p.at(nsColon):
      discard p.advance
      if p.at(nsIdent) and p.peek.text in ["base", "this"]:
        result.initKind = p.advance.text
      if p.at(nsLParen):
        discard p.advance
        while not p.at(nsRParen) and not p.at(nsEof):
          result.initArgs.add p.parseExpr()
          if p.at(nsComma): discard p.advance else: break
        discard p.expect(nsRParen)
    result.body = p.parseBlock()
    return

  if p.peek.kind != nsIdent:
    p.err(p.peek, ndMemberDeclarationExpected, p.peek.text)
    discard p.advance
    return nsn(nsnEmpty, modInfo)

  let ty = p.parseType()
  if p.peek.kind != nsIdent:
    p.err(p.peek, ndIdentifierExpected)
    p.recoverToSemi()
    if p.at(nsSemi): discard p.advance
    return nsn(nsnEmpty, modInfo)

  let nameTok = p.advance
  let info = p.infoOf(nameTok)

  if p.at(nsLParen):
    result = nsn(nsnMethodDecl, info)
    result.name = nameTok.text
    result.typ = ty
    result.attrs = attrs
    result.params = p.parseParams()
    if isInterface and p.at(nsSemi):
      ## An interface member has no body. Accepting it here lets the check that
      ## reports interfaces as unsupported run, which says more than a syntax error.
      discard p.advance
    else:
      result.body = p.parseBlock()
  elif p.at(nsLBrace) or p.at(nsArrow):
    result = nsn(nsnPropertyDecl, info)
    result.name = nameTok.text
    result.typ = ty
    result.attrs = attrs
    var getter: NsNode = nil
    var setter: NsNode = nil
    if p.at(nsArrow):
      discard p.advance
      let g = nsn(nsnBlock, info)
      g.add p.parseExpr()
      getter = g
      if p.at(nsSemi): discard p.advance
    else:
      discard p.advance   # '{'
      while not p.at(nsRBrace) and not p.at(nsEof):
        if p.at(nsSemi):
          discard p.advance
          continue
        if p.at(nsIdent) and p.peek.text == "get":
          discard p.advance
          if p.at(nsLBrace):
            getter = p.parseBlock()
          else:
            # `get;` - an auto-property accessor
            getter = nsn(nsnEmpty, info)
            if p.at(nsSemi): discard p.advance
        elif p.at(nsIdent) and p.peek.text == "set":
          discard p.advance
          if p.at(nsLBrace):
            setter = p.parseBlock()
          else:
            setter = nsn(nsnEmpty, info)
            if p.at(nsSemi): discard p.advance
        else:
          p.err(p.peek, ndUnsupported, "this property accessor")
          discard p.advance
      discard p.expect(nsRBrace)
    result.params = @[getter, setter]
  else:
    result = nsn(nsnFieldDecl, info)
    result.name = nameTok.text
    result.typ = ty
    result.attrs = attrs
    if p.at(nsAssign):
      discard p.advance
      result.body = p.parseExpr()
    if p.at(nsSemi): discard p.advance

proc parseTypeDecl(p: var NsParser): NsNode =
  let startInfo = p.here()
  let mods = p.parseModifierList(NsTypeModifiers, NsClassModifiers)
  let kwTok = p.advance
  var ckind = ckClass
  if kwTok.text == "struct": ckind = ckStruct
  elif kwTok.text == "interface": ckind = ckInterface
  if p.peek.kind != nsIdent:
    return nsn(nsnEmpty, startInfo)
  let nameTok = p.advance
  result = nsn(nsnClassDecl, p.infoOf(nameTok))
  result.name = nameTok.text
  result.classKind = ckind
  result.attrs = NsAttrs(access: accessOfTopLevel(mods))
  if p.at(nsColon):
    discard p.advance
    result.typ = p.parseType()
    if p.at(nsComma):
      ## A second base can only be an interface, which N# does not implement.
      p.err(p.peek, ndUnsupported, "a second base type")
      while p.at(nsComma):
        discard p.advance
        discard p.parseType()
  if not p.at(nsLBrace):
    p.err(p.peek, ndOpenBraceExpectedBody, nameTok.text)
    ## Error recovery, after the diagnostic above: skip to the body or the end.
    while not p.at(nsLBrace) and not p.at(nsSemi) and not p.at(nsRBrace) and
          not p.at(nsEof):
      discard p.advance
    if not p.at(nsLBrace):
      if p.at(nsSemi): discard p.advance
      return result
  discard p.expect(nsLBrace)
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    let m = p.parseClassMember(nameTok.text, ckind == ckInterface)
    if m != nil: result.add m
  discard p.expect(nsRBrace)

proc parseEnumDecl(p: var NsParser): NsNode =
  let info = p.here()
  let mods = p.parseModifierList(NsTypeModifiers, NsClassModifiers)
  discard p.advance   # enum
  if p.peek.kind != nsIdent:
    return nsn(nsnEmpty, info)
  let nameTok = p.advance
  result = nsn(nsnEnumDecl, p.infoOf(nameTok))
  result.name = nameTok.text
  result.attrs = NsAttrs(access: accessOfTopLevel(mods))
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
      let f = nsn(nsnEnumField, p.infoOf(fieldTok))
      f.name = fieldTok.text
      if p.at(nsAssign):
        discard p.advance
        f.body = p.parseExpr()
      result.add f
    discard p.expect(nsRBrace)

proc parseDelegateDecl(p: var NsParser): NsNode =
  let info = p.here()
  let mods = p.parseModifierList(NsTypeModifiers, NsClassModifiers)
  discard p.advance   # delegate
  let ret = p.parseType()
  if p.peek.kind != nsIdent:
    return nsn(nsnEmpty, info)
  let nameTok = p.advance
  result = nsn(nsnDelegateDecl, p.infoOf(nameTok))
  result.name = nameTok.text
  result.typ = ret
  result.attrs = NsAttrs(access: accessOfTopLevel(mods))
  result.params = p.parseParams()
  if p.at(nsSemi): discard p.advance

proc parseUsing(p: var NsParser): NsNode =
  ## `using X.Y;` names a namespace. `using Alias = X.Y;` names the same namespace
  ## through an alias, which works because lowering drops the qualifier, so the
  ## target is what gets imported -- but the alias itself is what a *qualifier*
  ## written with it is resolved against, so it is recorded on the node.
  result = nsn(nsnUsing, p.here())
  discard p.advance
  let first = p.parseDottedName()
  if p.at(nsAssign):
    discard p.advance
    let target = p.parseDottedName()
    if p.at(nsLt):
      p.err(p.peek, ndUnsupported, "an alias of a type")
    else:
      result.name = target
      result.alias = first
  else:
    result.name = first
  ## Only the alias is this file's own name for the target; the target itself is a
  ## namespace, and namespaces are global.
  if result.alias.len > 0: p.aliases.incl result.alias
  while not p.at(nsSemi) and not p.at(nsEof):
    discard p.advance
  if p.at(nsSemi): discard p.advance

proc parseNamespace(p: var NsParser; nsPrefix = ""): NsNode =
  ## `namespace A.B { }` and `namespace A { namespace B { } }` both give `A.B`.
  let info = p.here()
  discard p.advance
  result = nsn(nsnNamespace, info)
  var local = ""
  while p.peek.kind in {nsIdent, nsDot}:
    local.add p.advance.text
  result.name = if nsPrefix.len > 0 and local.len > 0: nsPrefix & "." & local
                else: nsPrefix & local
  discard p.expect(nsLBrace)
  result.body = nsn(nsnBlock, info)
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    let d = p.parseTopLevelDecl(result.name)
    if d != nil: result.body.add d
  discard p.expect(nsRBrace)

proc parseTopLevelDecl(p: var NsParser; nsPrefix: string): NsNode =
  ## `nsPrefix` is the enclosing namespace, for a nested `namespace` statement.
  var k = 0
  while p.peekAhead(k).kind == nsIdent and p.peekAhead(k).text in NsTypeModifiers:
    inc k
  let head = p.peekAhead(k)
  if head.kind == nsIdent and head.text in ["class", "struct", "interface"]:
    return p.parseTypeDecl()
  elif head.kind == nsIdent and head.text == "enum":
    return p.parseEnumDecl()
  elif head.kind == nsIdent and head.text == "delegate":
    return p.parseDelegateDecl()
  elif p.at(nsIdent) and p.peek.text in ["using", "import"]:
    return p.parseUsing()
  elif p.at(nsIdent) and p.peek.text == "namespace":
    return p.parseNamespace(nsPrefix)
  else:
    result = p.parseStatement()
    if p.at(nsSemi): discard p.advance

# --- entry point ------------------------------------------------------------

proc parseNsModule*(source: string; fileIdx: FileIndex;
                    config: ConfigRef): NsNode =
  ## Parses one `.ns` file into an `nsnModule`. No declaration collection, no
  ## semantic checks and no lowering happen here; see `frontend.nim`. The library's
  ## surface is read here because the grammar needs it: a cast is told from a
  ## parenthesised expression by looking the name up as a type.
  var p = NsParser(toks: tokenize(source), pos: 0, config: config,
                   fileIdx: fileIdx, surface: bclSurface(config),
                   aliases: initHashSet[string]())
  result = nsn(nsnModule, newLineInfo(fileIdx, 1, 1))
  while not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    let before = p.pos
    let d = p.parseTopLevelDecl()
    if d != nil: result.add d
    if p.pos == before:
      ## Progress guarantee: without it a grammar bug would spin forever rather
      ## than report anything.
      p.err(p.peek, ndParserStalled)
      discard p.advance







