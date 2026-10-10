# N# frontend - parser
#
# Tokens to `ast.NsNode`. Pure grammar: no C#-to-Nim name mapping, no lowering and
# no access-control checking; those live in `desugar.nim`/`bcl.nim` and `sema.nim`.
# The only external dependency is the config, for diagnostics.
#
# `>>` splitting lives in `lexer.splitShr`. Unrecognised or unimplemented
# constructs, and modifiers N# does not implement, are reported rather than
# ignored; skipping happens only as error recovery, after a diagnostic.

import std/[strutils, sets, tables]
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
    typeParams: seq[string]  ## the type parameters in scope, which are type names
    refReturn: bool
      ## The member just parsed returns by reference (`ref int F()`).
    inGuard: bool
      ## Parsing a switch arm's `when` guard: the arm's `=>` follows it, so a name
      ## before it is not a lambda's parameter.
    typeAliases: Table[string, NsNode]
      ## `using A = X.Y<int>;`: a name for a type, which the parser writes out in its
      ## place, as C# resolves it.
    aliases: HashSet[string]
      ## The namespace aliases this file's own `using` directives introduce. A type
      ## reached through one (`(P.Gadget)x`) is a cast, not a parenthesised
      ## expression. A plain namespace name needs no record here: namespaces are
      ## global, so the compilation's own gather of them answers for every file.

const
  NsModifierWords = ["public", "private", "protected", "internal", "static",
    "virtual", "override", "abstract", "sealed", "readonly", "const", "unsafe",
    "extern", "new", "implicit", "explicit", "event", "required"]
  NsTypeModifiers = ["public", "private", "protected", "internal", "abstract",
    "sealed", "static", "partial", "file"]
  ## Modifiers N# actually implements. Anything else recognised but unimplemented
  ## is reported by `parseModifierList` instead of being silently dropped.
  NsMemberModifiers = ["public", "private", "protected", "internal", "static",
    "const", "readonly", "virtual", "override", "abstract", "sealed", "new",
    "implicit", "explicit", "event", "required"]
  NsClassModifiers = ["public", "private", "protected", "internal", "abstract",
    "sealed", "static", "partial", "file"]

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
  if t.kind == nsLParen:
    ## `(int, string)` / `(int min, int max)`: a tuple type.
    discard p.advance
    result = nsn(nsnTupleType, p.infoOf(t))
    while not p.at(nsRParen) and not p.at(nsEof):
      let einfo = p.here()
      let et = p.parseType()
      var ename = ""
      if p.peek.kind == nsIdent: ename = p.advance.text
      result.add nsnParam(ename, et, einfo)
      if p.at(nsComma): discard p.advance else: break
    discard p.expect(nsRParen)
    if p.at(nsQuestion):
      discard p.advance
      result = nsnNullableType(result, p.infoOf(t))
    while p.at(nsLBracket) and p.peekAhead(1).kind == nsRBracket:
      discard p.advance
      discard p.advance
      result = nsnArrayType(result, p.infoOf(t))
    return
  if t.kind != nsIdent:
    return nsn(nsnEmpty, p.infoOf(t))
  if t.text == "void":
    discard p.advance
    return nsnVoidType(p.infoOf(t))
  result = nsnTypeName(p.parseDottedName(), p.infoOf(t))
  if p.typeAliases.hasKey(result.name) and not p.at(nsLt):
    ## A type alias stands for its target.
    result = copyNsTree(p.typeAliases[result.name])
  elif p.at(nsLt):
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
  while p.at(nsLBracket) and p.peekAhead(1).kind in {nsRBracket, nsComma}:
    ## `T[]`, or `T[,]` with one comma per extra dimension.
    discard p.advance
    var rank = 1
    while p.at(nsComma):
      discard p.advance
      inc rank
    discard p.expect(nsRBracket)
    result = nsnArrayType(result, p.infoOf(t))
    if result.typ.kind == nsnArrayType and (rank > 1 or result.typ.intVal > 1):
      ## C# reads `int[,][]` outside in, the reverse of how the nesting here
      ## builds it, so a multi-dimensional array never mixes with another array.
      p.err(p.peek, ndUnsupported, "a multi-dimensional array mixed with another array")
    if rank > 1: result.intVal = rank

proc parseTypeParams(p: var NsParser): seq[NsNode] =
  ## `<T, U>` after a declared name. A variance marker (`in T`, `out T`) is kept
  ## in the parameter's `strVal`; sema checks where it may stand.
  result = @[]
  if not p.at(nsLt): return
  discard p.advance
  while not atGtClose(p) and not p.at(nsEof):
    var variance = ""
    if p.at(nsIdent) and p.peek.text in ["in", "out"] and
       p.peekAhead(1).kind == nsIdent:
      variance = p.advance.text
    if p.peek.kind != nsIdent:
      p.err(p.peek, ndIdentifierExpected)
      break
    let t = p.advance
    result.add nsnTypeName(t.text, p.infoOf(t))
    result[^1].strVal = variance
    if p.at(nsComma): discard p.advance else: break
  p.expectGt()

proc parseWhereClauses(p: var NsParser): seq[NsNode] =
  ## `where T : class, IFoo, new()` clauses, one node per type parameter.
  result = @[]
  while p.at(nsIdent) and p.peek.text == "where" and p.peekAhead(1).kind == nsIdent:
    let info = p.here()
    discard p.advance
    let w = nsn(nsnWhere, info)
    w.name = p.advance.text
    discard p.expect(nsColon)
    while not p.at(nsEof):
      if p.at(nsIdent) and p.peek.text in ["class", "struct", "notnull", "unmanaged",
                                           "default"]:
        let t = p.advance
        w.add nsnIdent(t.text, p.infoOf(t))
        if p.at(nsQuestion): discard p.advance   # `class?`
      elif p.at(nsIdent) and p.peek.text == "new" and p.peekAhead(1).kind == nsLParen:
        let t = p.advance
        discard p.expect(nsLParen)
        discard p.expect(nsRParen)
        w.add nsnIdent("new", p.infoOf(t))
      else:
        w.add p.parseType()
      if p.at(nsComma): discard p.advance else: break
    result.add w

proc looksLikeTypeArgs(p: NsParser): bool =
  ## `M<int>(x)` against `a < b`: C#'s rule (ECMA-334 6.2.5). The tokens up to the
  ## matching `>` must be a type argument list, and the token after it one that
  ## cannot continue a relational expression.
  if not p.at(nsLt): return false
  let close = skipBalancedGt(p, 0)
  if close < 0: return false
  for k in 1 ..< close - 1:
    if p.peekAhead(k).kind notin {nsIdent, nsComma, nsDot, nsLt, nsGt, nsShr,
                                  nsLBracket, nsRBracket, nsQuestion}:
      return false
  p.peekAhead(close).kind in {nsLParen, nsRParen, nsRBracket, nsRBrace, nsColon,
                              nsSemi, nsComma, nsDot, nsQuestion, nsEqEq, nsNotEq,
                              nsEof}

proc parseTypeArgs(p: var NsParser): seq[NsNode] =
  result = @[]
  discard p.advance   # '<'
  while not atGtClose(p) and not p.at(nsEof):
    result.add p.parseType()
    if p.at(nsComma): discard p.advance else: break
  p.expectGt()

# --- expressions ------------------------------------------------------------

proc parseExpr(p: var NsParser): NsNode
proc parseBlock(p: var NsParser): NsNode

proc compoundOpOf(k: NsTokenKind): string =
  ## The operator of a compound assignment token (`+=` is `+`), or "".
  case k
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

proc parseStatement(p: var NsParser): NsNode
proc parseSimpleStmt(p: var NsParser): NsNode
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
    ## The `default` literal: typed by its target, which `sema.nim` fills in.
    return nsn(nsnDefault, p.infoOf(t))
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
  p.surface.isKnownTypeName(name) or p.aliases.contains(name) or name in p.typeParams or
    p.typeAliases.hasKey(name)

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

proc looksLikeLambdaShape(p: NsParser): bool

proc looksLikeLambda(p: NsParser): bool =
  ## Not at a guard's own level, where `=>` is the arm's.
  if p.inGuard: return false
  result = looksLikeLambdaShape(p)

proc looksLikeLambdaShape(p: NsParser): bool =
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
    ## The value of an expression-bodied lambda is its expression; one that assigns
    ## is a statement. Whether the delegate returns is decided when it is typed.
    let s = p.parseSimpleStmt()
    let b = nsn(nsnBlock, info)
    if s.kind == nsnExprStmt: b.add s.body
    else: b.add s
    result.body = b

proc typeShapeEnd(p: NsParser; start: int): int =
  ## The offset just past a type written at `start` -- a dotted name, an optional
  ## generic argument list, `?`, and any `[]` -- or -1 when no type starts there.
  if p.peekAhead(start).kind != nsIdent: return -1
  var i = start + 1
  while p.peekAhead(i).kind == nsDot and p.peekAhead(i + 1).kind == nsIdent: i += 2
  if p.peekAhead(i).kind == nsLt:
    i = skipBalancedGt(p, i)
    if i < 0: return -1
  if p.peekAhead(i).kind == nsQuestion: inc i
  while p.peekAhead(i).kind == nsLBracket and p.peekAhead(i + 1).kind == nsRBracket:
    i += 2
  i

proc parseArgumentInner(p: var NsParser): NsNode

proc parseArgument(p: var NsParser): NsNode =
  ## A call argument may be a lambda even inside a switch arm's guard.
  let saved = p.inGuard
  p.inGuard = false
  result = p.parseArgumentInner()
  p.inGuard = saved

proc parseArgumentInner(p: var NsParser): NsNode =
  ## One call argument: `e`, `name: e`, `ref x`, `out x`, `out int x`, `out var x`,
  ## `in x`.
  if p.at(nsIdent) and p.peekAhead(1).kind == nsColon and
     p.peek.text notin ["ref", "out", "in"]:
    let t = p.advance
    discard p.advance   # ':'
    result = nsn(nsnNamedArg, p.infoOf(t))
    result.name = t.text
    result.body = p.parseArgument()
    return
  if p.at(nsIdent) and p.peek.text in ["ref", "out", "in"] and
     p.peekAhead(1).kind == nsIdent:
    let t = p.advance
    if t.text == "out" and p.typeShapeEnd(0) > 0 and
       p.peekAhead(p.typeShapeEnd(0)).kind == nsIdent:
      ## `out int x` / `out var x` declares `x` where the call is.
      let declInfo = p.here()
      result = nsn(nsnOutDecl, declInfo)
      if p.peek.text == "var" and p.peekAhead(1).kind == nsIdent:
        discard p.advance
      else:
        result.typ = p.parseType()
      if p.peek.kind == nsIdent:
        result.name = p.advance.text
      return
    result = nsn(nsnRefArg, p.infoOf(t))
    result.name = t.text
    result.body = p.parseExpr()
    return
  result = p.parseExpr()

proc parseIndexArgument(p: var NsParser): NsNode =
  ## An element access argument: an index (`^1` counts from the end) or a range
  ## `a..b`, either end left out.
  let info = p.here()
  var start: NsNode = nil
  if not p.at(nsDotDot): start = p.parseExpr()
  if not p.at(nsDotDot): return start
  discard p.advance
  result = nsn(nsnRange, info)
  var stop: NsNode = nil
  if not p.at(nsRBracket) and not p.at(nsComma): stop = p.parseExpr()
  result.sons = @[start, stop]

proc parseInterpolated(p: var NsParser): NsNode =
  ## `$"a{x,5:F2}b"`: the lexer has already split it into literal chunks and holes,
  ## so each hole is an ordinary expression, an optional `, alignment`, and the
  ## format text the hole-end token carries.
  let begin = p.advance
  result = nsn(nsnInterpolated, p.infoOf(begin))
  while not p.at(nsInterpEnd) and not p.at(nsEof):
    if p.at(nsStrLit):
      let t = p.advance
      result.add nsnStrLit(t.text, p.infoOf(t))
    elif p.at(nsInterpHole):
      let h = p.advance
      let hole = nsn(nsnInterpHole, p.infoOf(h))
      hole.body = p.parseExpr()
      if p.at(nsComma):
        discard p.advance
        hole.add p.parseExpr()
      if p.at(nsInterpHoleEnd):
        hole.strVal = p.advance.text
      else:
        p.err(p.peek, ndSyntaxErrorExpected, "}")
        while not p.at(nsInterpHoleEnd) and not p.at(nsInterpEnd) and not p.at(nsEof):
          discard p.advance
        if p.at(nsInterpHoleEnd): discard p.advance
      result.add hole
    else:
      p.err(p.peek, ndInvalidExpressionTerm, p.peek.text)
      discard p.advance
  discard p.expect(nsInterpEnd)

proc parseParams(p: var NsParser): seq[NsNode]

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
    try:
      if t.text.startsWith("0x"): v = cast[BiggestInt](parseHexInt(t.text))
      elif t.text.startsWith("0b"): v = cast[BiggestInt](parseBinInt(t.text))
      else: v = cast[BiggestInt](parseBiggestUInt(t.text))
    except ValueError:
      p.err(t, ndIntegralConstantTooLarge)
    result = nsnIntLit(v, p.infoOf(t))
    result.strVal = t.suffix
  of nsFloatLit:
    discard p.advance
    var v: BiggestFloat = 0.0
    try: v = BiggestFloat(parseFloat(t.text))
    except ValueError: discard
    result = nsnFloatLit(v, p.infoOf(t))
    result.strVal = t.suffix
    if t.suffix == "m":
      p.err(t, ndUnsupported, "the 'decimal' type")
  of nsCharLit:
    discard p.advance
    var v = 0
    if t.text.len == 1: v = ord(t.text[0])
    elif t.text.len > 1:
      ## A character outside ASCII: N#'s `char` is one byte (SPEC 4.4).
      p.err(t, ndUnsupported, "a char literal outside ASCII")
    result = nsnCharLit(BiggestInt(v), p.infoOf(t))
  of nsInterpBegin:
    result = p.parseInterpolated()
  of nsLBracket:
    ## A collection expression (C# 12), `[a, b, ..xs]`, typed by its target.
    discard p.advance
    result = nsn(nsnCollection, p.infoOf(t))
    while not p.at(nsRBracket) and not p.at(nsEof):
      if p.at(nsDotDot):
        let s = nsn(nsnSpread, p.here())
        discard p.advance
        s.body = p.parseExpr()
        result.add s
      else:
        result.add p.parseExpr()
      if p.at(nsComma): discard p.advance else: break
    discard p.expect(nsRBracket)
  of nsIdent:
    discard p.advance
    case t.text
    of "null": result = nsn(nsnNull, p.infoOf(t))
    of "new": result = p.parseNew(t)
    of "this": result = nsn(nsnThis, p.infoOf(t))
    of "base": result = nsn(nsnBase, p.infoOf(t))
    of "true": result = nsnBoolLit(true, p.infoOf(t))
    of "false": result = nsnBoolLit(false, p.infoOf(t))
    of "nameof": result = p.parseNameof(t)
    of "default": result = p.parseDefault(t)
    of "ref":
      ## `ref x` where a reference is taken: a `ref` local's initialiser, a `ref`
      ## return.
      result = nsn(nsnRefArg, p.infoOf(t))
      result.name = "ref"
      result.body = p.parseUnary()
    of "delegate":
      ## An anonymous method: `delegate (int x) { ... }`, or `delegate { ... }`,
      ## which converts to any delegate type whatever its parameters.
      result = nsn(nsnLambda, p.infoOf(t))
      if p.at(nsLParen):
        for prm in p.parseParams(): result.addParam prm
      else:
        result.strVal = "anyParams"
      result.body = p.parseBlock()
    of "throw":
      ## A throw expression: `x ?? throw e`, `c ? v : throw e`, `=> throw e`.
      result = nsn(nsnThrow, p.infoOf(t))
      result.body = p.parseExpr()
    of "checked", "unchecked":
      if p.at(nsLParen):
        ## `checked(e)`: `e` evaluated with overflow checking on (or off).
        result = nsn(nsnCheckedExpr, p.infoOf(t))
        result.name = t.text
        discard p.advance
        result.body = p.parseExpr()
        discard p.expect(nsRParen)
      else: result = nsnIdent(t.text, p.infoOf(t))
    of "sizeof", "typeof":
      ## `typeof(T)` is the `System.Type` of `T`; `sizeof(T)` its size in bytes.
      result = nsn((if t.text == "typeof": nsnTypeOf else: nsnSizeOf), p.infoOf(t))
      discard p.expect(nsLParen)
      result.typ = p.parseType()
      discard p.expect(nsRParen)
    else: result = nsnIdent(t.text, p.infoOf(t))
  of nsLParen:
    if looksLikeCast(p):
      return p.parseCast()
    let open = p.advance
    let first = p.parseArgument()
    if p.at(nsComma) or first.kind == nsnNamedArg:
      ## `(1, "one")`, `(Count: 3, Label: "x")`: a tuple.
      result = nsn(nsnTupleLit, p.infoOf(open))
      result.add first
      while p.at(nsComma):
        discard p.advance
        result.add p.parseArgument()
      discard p.expect(nsRParen)
      return
    result = first
    if p.at(nsAssign) or compoundOpOf(p.peek.kind).len > 0:
      ## `(x = e)`: an assignment whose value is the assigned one, as in
      ## `while ((line = Next()) != null)`.
      let op = (if p.at(nsAssign): "" else: compoundOpOf(p.peek.kind))
      discard p.advance
      result = nsn(nsnAssign, first.info)
      result.name = op
      result.intVal = 1
      result.sons = @[first, p.parseExpr()]
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
    if p.at(nsBang):
      ## `x!`, the null-forgiving operator: it only silences C#'s nullable
      ## warnings, which N# does not issue, so the value is `x` itself.
      discard p.advance
      continue
    if p.at(nsDot):
      discard p.advance
      let nameTok = p.peek
      if nameTok.kind != nsIdent: break
      discard p.advance
      result = nsnMember(result, nameTok.text, p.infoOf(nameTok))
      if p.looksLikeTypeArgs():
        result.typeArgs = p.parseTypeArgs()
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
        call.add p.parseArgument()
        if p.at(nsComma): discard p.advance else: break
      discard p.expect(nsRParen)
      result = call
    elif p.at(nsLBracket):
      let info = result.info
      discard p.advance
      let idx = nsn(nsnIndex, info)
      idx.body = result
      while true:
        idx.add p.parseIndexArgument()
        if p.at(nsComma): discard p.advance else: break
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
  if result.kind == nsnIdent and p.looksLikeTypeArgs():
    result.typeArgs = p.parseTypeArgs()
  result = p.parsePostfixTail(result)

proc parseUnary(p: var NsParser): NsNode =
  let t = p.peek
  case t.kind
  of nsPlusPlus, nsMinusMinus:
    ## `++x`: the increment, whose value is the new one.
    discard p.advance
    result = nsn(nsnIncDec, p.infoOf(t))
    result.name = if t.kind == nsPlusPlus: "inc" else: "dec"
    result.strVal = "prefix"
    result.body = p.parseUnary()
  of nsCaret:
    ## `^k`: an index counted from the end.
    discard p.advance
    result = nsn(nsnFromEnd, p.infoOf(t))
    result.body = p.parseUnary()
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

proc parsePattern(p: var NsParser): NsNode

proc parseSwitchExpr(p: var NsParser; subject: NsNode): NsNode =
  ## `x switch { pattern [when guard] => value, ... }`
  result = nsn(nsnSwitchExpr, p.here())
  result.body = subject
  discard p.advance   # 'switch'
  discard p.expect(nsLBrace)
  while not p.at(nsRBrace) and not p.at(nsEof):
    let arm = nsn(nsnSwitchArm, p.here())
    arm.add p.parsePattern()
    var guard: NsNode = nil
    if p.at(nsIdent) and p.peek.text == "when":
      discard p.advance
      let saved = p.inGuard
      p.inGuard = true
      guard = p.parseExpr()
      p.inGuard = saved
    arm.sons.add guard
    discard p.expect(nsArrow)
    arm.add p.parseExpr()
    result.add arm
    if p.at(nsComma): discard p.advance else: break
  discard p.expect(nsRBrace)

proc parseInitializerList(p: var NsParser): seq[NsNode]

proc parseBinary(p: var NsParser; minPrec: int): NsNode =
  result = p.parseUnary()
  while p.at(nsIdent) and p.peek.text in ["switch", "with"] and
        p.peekAhead(1).kind == nsLBrace:
    ## A switch expression binds tighter than any binary operator, and so does
    ## `r with { ... }`.
    if p.peek.text == "switch":
      result = p.parseSwitchExpr(result)
    else:
      let w = nsn(nsnWith, p.here())
      discard p.advance
      w.body = result
      w.inits = p.parseInitializerList()
      result = w
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
    elif typeOp and opTok.text == "is":
      ## `x is T` stays a type test; anything else (`is T t`, `is null`,
      ## `is > 5`, `is { P: 1 }`, `is not ...`) is a pattern.
      let pat = p.parsePattern()
      if pat.kind == nsnPatType and pat.name.len == 0:
        let n = nsn(nsnIs, p.infoOf(opTok))
        n.body = result
        n.typ = pat.typ
        result = n
      else:
        let n = nsn(nsnIsPattern, p.infoOf(opTok))
        n.body = result
        n.add pat
        result = n
    elif typeOp:
      let n = nsn(nsnAs, p.infoOf(opTok))
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

proc looksLikeTypePattern(p: NsParser): bool =
  ## Whether a pattern starting here is a type (`Circle c`, `int`, `List<int>`)
  ## rather than a constant (`Color.Red`, `MaxSize`): the name's last part must be a
  ## type, by the same lookup a cast uses.
  if p.peek.kind != nsIdent: return false
  let e = p.typeShapeEnd(0)
  if e < 0: return false
  var last = p.peek.text
  var i = 1
  while p.peekAhead(i).kind == nsDot and p.peekAhead(i + 1).kind == nsIdent:
    last = p.peekAhead(i + 1).text
    i += 2
  p.isTypeName(last) or p.peekAhead(e).kind == nsIdent and
    p.peekAhead(e).text notin ["and", "or", "when"]

proc parsePropertySubpatterns(p: var NsParser; n: NsNode) =
  ## `{ Name: pattern, A.B: pattern }`
  discard p.expect(nsLBrace)
  while not p.at(nsRBrace) and not p.at(nsEof):
    let f = nsn(nsnPatField, p.here())
    f.name = p.parseDottedName()
    discard p.expect(nsColon)
    f.body = p.parsePattern()
    n.add f
    if p.at(nsComma): discard p.advance else: break
  discard p.expect(nsRBrace)

proc parsePrimaryPattern(p: var NsParser): NsNode =
  let t = p.peek
  let info = p.infoOf(t)
  case t.kind
  of nsLParen:
    ## `(p)` groups; `(p, q)` is a positional pattern over a tuple or `Deconstruct`.
    discard p.advance
    let first = p.parsePattern()
    if not p.at(nsComma):
      discard p.expect(nsRParen)
      return first
    result = nsn(nsnPatPositional, info)
    result.add first
    while p.at(nsComma):
      discard p.advance
      result.add p.parsePattern()
    discard p.expect(nsRParen)
    if p.at(nsIdent) and p.peek.text notin ["and", "or", "when"]:
      result.name = p.advance.text
  of nsLt, nsGt, nsLe, nsGe:
    discard p.advance
    result = nsn(nsnPatRel, info)
    result.name = t.text
    result.body = p.parseBinary(10)
  of nsLBrace:
    result = nsn(nsnPatProp, info)
    p.parsePropertySubpatterns(result)
    if p.at(nsIdent) and p.peek.text notin ["and", "or", "when"]:
      result.name = p.advance.text
  of nsLBracket:
    ## A list pattern (C# 11): element patterns in order, and at most one `..`
    ## slice, which may carry a pattern of its own.
    discard p.advance
    result = nsn(nsnPatList, info)
    while not p.at(nsRBracket) and not p.at(nsEof):
      if p.at(nsDotDot):
        let s = nsn(nsnPatSlice, p.here())
        discard p.advance
        if not p.at(nsComma) and not p.at(nsRBracket): s.body = p.parsePattern()
        result.add s
      else:
        result.add p.parsePattern()
      if p.at(nsComma): discard p.advance else: break
    discard p.expect(nsRBracket)
  else:
    if t.kind == nsIdent and t.text == "_" :
      discard p.advance
      return nsn(nsnPatDiscard, info)
    if t.kind == nsIdent and t.text == "var" and p.peekAhead(1).kind == nsIdent:
      discard p.advance
      result = nsn(nsnPatVar, info)
      result.name = p.advance.text
      return
    if t.kind == nsIdent and t.text notin ["null", "true", "false", "default"] and
       p.looksLikeTypePattern():
      let ty = p.parseType()
      if p.at(nsLParen):
        ## `T(p, q)`: of type `T`, deconstructed.
        discard p.advance
        result = nsn(nsnPatPositional, info)
        result.typ = ty
        while not p.at(nsRParen) and not p.at(nsEof):
          result.add p.parsePattern()
          if p.at(nsComma): discard p.advance else: break
        discard p.expect(nsRParen)
      elif p.at(nsLBrace):
        result = nsn(nsnPatProp, info)
        result.typ = ty
        p.parsePropertySubpatterns(result)
      else:
        result = nsn(nsnPatType, info)
        result.typ = ty
      if p.at(nsIdent) and p.peek.text notin ["and", "or", "when"]:
        result.name = p.advance.text
      return
    result = nsn(nsnPatConst, info)
    result.body = p.parseBinary(10)

proc parseNotPattern(p: var NsParser): NsNode =
  if p.at(nsIdent) and p.peek.text == "not":
    let info = p.here()
    discard p.advance
    result = nsn(nsnPatNot, info)
    result.body = p.parseNotPattern()
  else:
    result = p.parsePrimaryPattern()

proc parseAndPattern(p: var NsParser): NsNode =
  result = p.parseNotPattern()
  while p.at(nsIdent) and p.peek.text == "and":
    let info = p.here()
    discard p.advance
    let n = nsn(nsnPatAnd, info)
    n.add result
    n.add p.parseNotPattern()
    result = n

proc parsePattern(p: var NsParser): NsNode =
  ## C# 9 patterns: `or` of `and` of `not` of a primary pattern.
  result = p.parseAndPattern()
  while p.at(nsIdent) and p.peek.text == "or":
    let info = p.here()
    discard p.advance
    let n = nsn(nsnPatOr, info)
    n.add result
    n.add p.parseAndPattern()
    result = n

proc parseArrowBody(p: var NsParser; info: TLineInfo; asReturn: bool): NsNode =
  ## The body after `=>`: an expression, which C# also lets be an assignment
  ## (`x => total += x`, `set => field = value`). An assignment is a statement here,
  ## never a returned value.
  result = nsn(nsnBlock, info)
  let s = p.parseSimpleStmt()
  if s.kind == nsnExprStmt and s.body != nil and s.body.kind == nsnThrow:
    ## `=> throw e`: the body throws, whatever the member returns.
    result.add s.body
  elif s.kind == nsnExprStmt and asReturn:
    let r = nsn(nsnReturn, s.info)
    r.body = s.body
    result.add r
  else:
    result.add s

proc parseInitializerList(p: var NsParser): seq[NsNode] =
  ## `{ A = 1, B = { ... }, [k] = v, x, { k, v } }`: an object initialiser's member
  ## assignments, an index initialiser's, and a collection initialiser's `Add`s.
  result = @[]
  discard p.expect(nsLBrace)
  while not p.at(nsRBrace) and not p.at(nsEof):
    let info = p.here()
    if p.at(nsIdent) and p.peekAhead(1).kind == nsAssign:
      let m = nsn(nsnInitMember, info)
      m.name = p.advance.text
      discard p.advance   # '='
      if p.at(nsLBrace):
        let lst = nsn(nsnInitList, p.here())
        lst.sons = p.parseInitializerList()
        m.body = lst
      else:
        m.body = p.parseExpr()
      result.add m
    elif p.at(nsLBracket):
      let m = nsn(nsnInitIndex, info)
      discard p.advance
      while not p.at(nsRBracket) and not p.at(nsEof):
        m.add p.parseExpr()
        if p.at(nsComma): discard p.advance else: break
      discard p.expect(nsRBracket)
      discard p.expect(nsAssign)
      m.body = p.parseExpr()
      result.add m
    elif p.at(nsLBrace):
      let m = nsn(nsnInitAdd, info)
      discard p.advance
      while not p.at(nsRBrace) and not p.at(nsEof):
        m.add p.parseExpr()
        if p.at(nsComma): discard p.advance else: break
      discard p.expect(nsRBrace)
      result.add m
    else:
      let m = nsn(nsnInitAdd, info)
      m.add p.parseExpr()
      result.add m
    if p.at(nsComma): discard p.advance else: break
  discard p.expect(nsRBrace)

proc parseMdElements(p: var NsParser; lit: NsNode; level, rank: int) =
  ## `{ {1, 2}, {3, 4} }` of a `T[,]` initialiser: the elements in row-major
  ## order, and each dimension's length, which every row must share (CS0847).
  let info = p.here()
  discard p.expect(nsLBrace)
  var n = 0
  while not p.at(nsRBrace) and not p.at(nsEof):
    if level + 1 < rank: p.parseMdElements(lit, level + 1, rank)
    else: lit.add p.parseExpr()
    inc n
    if p.at(nsComma): discard p.advance else: break
  discard p.expect(nsRBrace)
  while lit.params.len < rank: lit.params.add nsnIntLit(-1, info)
  if lit.params[level].intVal < 0:
    lit.params[level].intVal = n
  elif lit.params[level].intVal != n:
    nsError(p.config, info, ndArrayInitLength, $lit.params[level].intVal)

proc parseArrayElements(p: var NsParser; lit: NsNode) =
  ## `{ a, b, c }` of an array initialiser.
  if lit.intVal > 1:
    p.parseMdElements(lit, 0, int(lit.intVal))
    return
  discard p.expect(nsLBrace)
  while not p.at(nsRBrace) and not p.at(nsEof):
    lit.add p.parseExpr()
    if p.at(nsComma): discard p.advance else: break
  discard p.expect(nsRBrace)

proc parseNew(p: var NsParser, kw: NsToken): NsNode =
  ## `new T(args) { inits }` -> `nsnNew`; `new(args)` is target-typed (no `typ`);
  ## `new T[n]` -> `nsnNewArray`; `new T[] { .. }` and `new[] { .. }` -> `nsnArrayLit`.
  ## The type name is kept verbatim; `desugar` maps it.
  let info = p.infoOf(kw)
  if p.at(nsLBrace):
    ## `new { Name = x, y, p.Z }`: an anonymous type. A member written without a
    ## name takes the last name of its value (CS0746 when it has none).
    discard p.advance
    result = nsn(nsnAnonNew, info)
    while not p.at(nsRBrace) and not p.at(nsEof):
      let m = nsn(nsnNamedArg, p.here())
      if p.at(nsIdent) and p.peekAhead(1).kind == nsAssign:
        m.name = p.advance.text
        discard p.advance
        m.body = p.parseExpr()
      else:
        m.body = p.parseExpr()
        if m.body.kind in {nsnIdent, nsnMember}: m.name = m.body.name
        else: nsError(p.config, m.info, ndAnonDeclarator)
      result.add m
      if p.at(nsComma): discard p.advance else: break
    discard p.expect(nsRBrace)
    return
  if p.at(nsLBracket) and p.peekAhead(1).kind == nsRBracket:
    ## `new[] { 1, 2 }`: the element type is inferred from the elements.
    discard p.advance
    discard p.advance
    result = nsn(nsnArrayLit, info)
    p.parseArrayElements(result)
    return
  var typ: NsNode = nil
  if p.peek.kind == nsIdent:
    let typeTok = p.advance
    typ = nsnTypeName(typeTok.text, info)
    while p.at(nsDot) and p.peekAhead(1).kind == nsIdent:
      discard p.advance
      typ.name.add "."
      typ.name.add p.advance.text
    if p.typeAliases.hasKey(typ.name) and not p.at(nsLt):
      ## `new A()` through a type alias.
      typ = copyNsTree(p.typeAliases[typ.name])
      typ.info = info
    elif p.at(nsLt):
      discard p.advance
      while not atGtClose(p) and not p.at(nsEof):
        typ.add p.parseType()
        if p.at(nsComma): discard p.advance else: break
      p.expectGt()
    if p.at(nsLBracket):
      discard p.advance
      if p.at(nsComma) or p.at(nsRBracket):
        ## `new T[] { .. }`, `new T[,] { {..}, {..} }`.
        var rank = 1
        while p.at(nsComma):
          discard p.advance
          inc rank
        discard p.expect(nsRBracket)
        result = nsn(nsnArrayLit, info)
        result.typ = typ
        if rank > 1: result.intVal = rank
        if p.at(nsLBrace): p.parseArrayElements(result)
        return
      result = nsn(nsnNewArray, info)
      result.typ = typ
      result.add p.parseExpr()
      while p.at(nsComma):
        ## `new T[n, m]`: a multi-dimensional array.
        discard p.advance
        result.add p.parseExpr()
      discard p.expect(nsRBracket)
      if p.at(nsLBrace):
        ## `new T[2, 2] { {..}, {..} }`: the sizes restate the initialiser's.
        let lit = nsn(nsnArrayLit, info)
        lit.typ = typ
        if result.sons.len > 1: lit.intVal = result.sons.len
        p.parseArrayElements(lit)
        return lit
      return
  elif not p.at(nsLParen):
    p.err(p.peek, ndInvalidExpressionTerm, p.peek.text)
    return nsn(nsnEmpty, info)
  result = nsn(nsnNew, info)
  result.typ = typ
  if p.at(nsLParen):
    discard p.advance
    while not p.at(nsRParen) and not p.at(nsEof):
      result.add p.parseArgument()
      if p.at(nsComma): discard p.advance else: break
    discard p.expect(nsRParen)
  if p.at(nsLBrace):
    result.inits = p.parseInitializerList()

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

proc parseAttributes(p: var NsParser): seq[NsNode] =
  ## `[A, B(x, Name = y)]` sections before a declaration, each attribute with its
  ## arguments, and `[target: A]` with a target (`return`, `assembly`). Where an
  ## attribute is allowed a `[` starts nothing else.
  result = @[]
  while p.at(nsLBracket):
    discard p.advance
    var target = ""
    if p.at(nsIdent) and p.peekAhead(1).kind == nsColon:
      target = p.advance.text
      discard p.advance
    while not p.at(nsRBracket) and not p.at(nsEof):
      let info = p.here()
      var name = ""
      while p.at(nsIdent) or p.at(nsDot):
        name.add p.advance.text
      let a = nsn(nsnAttribute, info)
      a.name = name
      a.strVal = target
      if name.len == 0:
        p.err(p.peek, ndIdentifierExpected)
        discard p.advance
        continue
      if p.at(nsLt):
        ## `[Tag<int>]`: a generic attribute (C# 11).
        a.typeArgs = p.parseTypeArgs()
      if p.at(nsLParen):
        discard p.advance
        while not p.at(nsRParen) and not p.at(nsEof):
          if p.at(nsIdent) and p.peekAhead(1).kind == nsAssign:
            ## `Name = value`: a named property of the attribute.
            let na = nsn(nsnNamedArg, p.here())
            na.name = p.advance.text
            discard p.advance
            na.body = p.parseExpr()
            a.add na
          else:
            a.add p.parseArgument()
          if p.at(nsComma): discard p.advance else: break
        discard p.expect(nsRParen)
      result.add a
      if p.at(nsComma): discard p.advance else: break
    discard p.expect(nsRBracket)

proc parseParams(p: var NsParser): seq[NsNode] =
  ## A C# parameter list. A parameter written without a name keeps the
  ## placeholder `arg`, matching the previous behaviour.
  result = @[]
  discard p.expect(nsLParen)
  while not p.at(nsRParen) and not p.at(nsEof):
    let pattrs = p.parseAttributes()
    let info = p.here()
    var pmod = ""
    while p.at(nsIdent) and p.peek.text in ["ref", "out", "in", "params", "this",
                                            "scoped"] and
          p.peekAhead(1).kind == nsIdent:
      let m = p.advance.text
      if m != "scoped": pmod = m
    let ty = p.parseType()
    if p.peek.kind != nsIdent:
      p.err(p.peek, ndIdentifierExpected)
    var pname = ""
    if p.peek.kind == nsIdent:
      pname = p.advance.text
    let prm = nsnParam(pname, ty, info)
    prm.paramMod = pmod
    prm.attributes = pattrs
    if p.at(nsAssign):
      ## An optional parameter's default value.
      discard p.advance
      prm.body = p.parseExpr()
    result.add prm
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
  while p.peekAhead(i).kind == nsLBracket and
        p.peekAhead(i + 1).kind in {nsRBracket, nsComma}:
    inc i
    while p.peekAhead(i).kind == nsComma: inc i
    if p.peekAhead(i).kind != nsRBracket: return false
    inc i
  if p.peekAhead(i).kind != nsIdent: return false
  p.peekAhead(i + 1).kind in {nsAssign, nsSemi, nsComma, nsRParen, nsEof}

proc parseInitializer(p: var NsParser; declared: NsNode): NsNode =
  ## A declaration's initialiser: an expression, or `{ a, b }` for an array.
  if p.at(nsLBrace):
    result = nsn(nsnArrayLit, p.here())
    if declared != nil and declared.kind == nsnArrayType:
      result.typ = declared.typ
      result.intVal = declared.intVal
    p.parseArrayElements(result)
  else:
    result = p.parseExpr()

proc matchingParen(p: NsParser; start: int): int =
  ## The offset of the `)` closing the `(` at `start`, or -1.
  var depth = 0
  var i = start
  while true:
    case p.peekAhead(i).kind
    of nsEof: return -1
    of nsLParen: inc depth
    of nsRParen:
      dec depth
      if depth == 0: return i
    else: discard
    inc i

proc parseDeconstruction(p: var NsParser; allVar: bool): NsNode =
  ## `(int a, var b, x, _) = value;` -- each element declares (with a type or
  ## `var`), assigns an existing lvalue, or discards.
  result = nsn(nsnDeconstruct, p.here())
  discard p.expect(nsLParen)
  while not p.at(nsRParen) and not p.at(nsEof):
    let info = p.here()
    if p.at(nsIdent) and p.peek.text == "_" and
       p.peekAhead(1).kind in {nsComma, nsRParen}:
      discard p.advance
      result.add nsn(nsnPatDiscard, info)
    elif allVar and p.at(nsIdent):
      let d = nsn(nsnLocalDecl, info)
      d.name = p.advance.text
      result.add d
    elif p.at(nsIdent) and p.peek.text == "var" and p.peekAhead(1).kind == nsIdent:
      discard p.advance
      let d = nsn(nsnLocalDecl, info)
      d.name = p.advance.text
      result.add d
    elif p.typeShapeEnd(0) > 0 and p.peekAhead(p.typeShapeEnd(0)).kind == nsIdent and
         p.peekAhead(p.typeShapeEnd(0) + 1).kind in {nsComma, nsRParen}:
      let d = nsn(nsnLocalDecl, info)
      d.typ = p.parseType()
      d.name = p.advance.text
      result.add d
    else:
      result.add p.parseExpr()
    if p.at(nsComma): discard p.advance else: break
  discard p.expect(nsRParen)
  discard p.expect(nsAssign)
  result.body = p.parseExpr()

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
    ## `const int X = 1;`: C# writes the type after `const`.
    result.declKind = dkConst
    discard p.advance
  if hasType:
    result.typ = p.parseType()
  if not hasType and p.at(nsLParen):
    ## `var (a, b) = t;`: a deconstruction declaring every element.
    return p.parseDeconstruction(true)
  let nameTok = p.peek
  discard p.advance
  result.name = nameTok.text
  if p.at(nsAssign):
    discard p.advance
    result.body = p.parseInitializer(result.typ)
  if p.at(nsComma) and p.peekAhead(1).kind == nsIdent:
    ## `int a = 1, b = 2;`: one declaration per declarator, of the same type, in
    ## the same scope.
    let group = nsn(nsnMultiDecl, info)
    group.add result
    while p.at(nsComma) and p.peekAhead(1).kind == nsIdent:
      discard p.advance
      let d = nsn(nsnLocalDecl, p.here())
      d.declKind = result.declKind
      d.typ = result.typ
      d.name = p.advance.text
      if p.at(nsAssign):
        discard p.advance
        d.body = p.parseInitializer(result.typ)
      group.add d
    result = group

proc parseSimpleStmt(p: var NsParser): NsNode =
  if p.at(nsLParen):
    let close = p.matchingParen(0)
    if close > 0 and p.peekAhead(close + 1).kind == nsAssign:
      ## `(a, b) = (b, a);`
      return p.parseDeconstruction(false)
    if close > 0 and p.peekAhead(close + 1).kind == nsIdent and
       p.peekAhead(close + 2).kind in {nsAssign, nsSemi, nsComma}:
      ## `(int, string) t = ...;`: a local of a tuple type.
      return p.parseVarDecl()
  if looksLikeDecl(p):
    return p.parseVarDecl()
  let lhs = p.parseExpr()
  if lhs == nil:
    ## An invalid term, already reported.
    return nsn(nsnEmpty, p.here())
  if p.at(nsAssign):
    discard p.advance
    result = nsn(nsnAssign, lhs.info)
    result.sons = @[lhs, p.parseExpr()]
    return
  let compound = compoundOpOf(p.peek.kind)
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
proc parseUsingStmt(p: var NsParser): NsNode
proc parseLock(p: var NsParser): NsNode

proc looksLikeLocalFunc(p: NsParser): bool =
  ## `R F(...) { }` / `R F<T>(...) => e;` inside a body, optionally `static`.
  var start = 0
  while p.peekAhead(start).kind == nsIdent and
        p.peekAhead(start).text in ["static", "async", "unsafe", "ref", "readonly"]:
    inc start
  let e = p.typeShapeEnd(start)
  if e < 0 or p.peekAhead(e).kind != nsIdent: return false
  var i = e + 1
  if p.peekAhead(i).kind == nsLt:
    i = skipBalancedGt(p, i)
    if i < 0: return false
  if p.peekAhead(i).kind != nsLParen: return false
  var depth = 0
  while true:
    case p.peekAhead(i).kind
    of nsEof: return false
    of nsLParen: inc depth
    of nsRParen:
      dec depth
      if depth == 0: break
    else: discard
    inc i
  inc i
  while p.peekAhead(i).kind == nsIdent and p.peekAhead(i).text == "where":
    ## `where T : ...` clauses run to the body.
    while p.peekAhead(i).kind notin {nsLBrace, nsArrow, nsEof}: inc i
  p.peekAhead(i).kind in {nsLBrace, nsArrow}

proc parseClassMember(p: var NsParser; clsName: string; isInterface = false): NsNode

proc parseStatement(p: var NsParser): NsNode =
  let t = p.peek
  if t.kind == nsIdent and p.looksLikeLocalFunc():
    ## A local function is a method declared in a body.
    result = p.parseClassMember("")
    if result != nil and result.kind == nsnMethodDecl:
      result.kind = nsnLocalFunc
    return
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
    of "checked", "unchecked":
      ## `checked(x + y);` is an expression statement; `checked { }` a block.
      if p.peekAhead(1).kind != nsLParen:
        return p.parseChecked(t.text == "checked")
    of "using":
      if p.peekAhead(1).kind == nsLParen or p.peekAhead(1).kind == nsIdent:
        return p.parseUsingStmt()
    of "ref":
      if p.peekAhead(1).kind == nsIdent:
        ## `ref int r = ref a[0];` / `ref var r = ...`: a reference local.
        discard p.advance
        if p.at(nsIdent) and p.peek.text == "readonly": discard p.advance
        result = p.parseVarDecl()
        if result.kind == nsnMultiDecl:
          for d in result.sons: d.paramMod = "ref"
        else: result.paramMod = "ref"
        return
    of "lock":
      if p.peekAhead(1).kind == nsLParen: return p.parseLock()
    of "goto":
      if p.peekAhead(1).kind == nsIdent:
        ## `goto label`, `goto case c`, `goto default`: N# has no jumps (SPEC 6).
        p.err(t, ndUnsupported, "'goto'")
        while not p.at(nsSemi) and not p.at(nsRBrace) and not p.at(nsEof):
          discard p.advance
        return nsn(nsnEmpty, p.infoOf(t))
    of "yield":
      if p.peekAhead(1).kind == nsIdent and p.peekAhead(1).text in ["return", "break"]:
        result = nsn(nsnYield, p.infoOf(t))
        discard p.advance
        result.name = p.advance.text
        if result.name == "return": result.body = p.parseExpr()
        return
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

proc parseEmbedded(p: var NsParser): seq[NsNode] =
  ## The body of `if`, `else`, `while`, `do`, `for` and `foreach`: a block, or the
  ## single embedded statement C# also allows there.
  if p.at(nsLBrace): return p.parseBlock().sons
  result = @[]
  if p.at(nsSemi):
    ## `while (f()) ;`: the empty statement.
    discard p.advance
    return
  let s = p.parseStatement()
  if s != nil: result.add s
  if p.at(nsSemi): discard p.advance

proc parseIf(p: var NsParser): NsNode =
  let info = p.here()
  discard p.advance
  discard p.expect(nsLParen)
  let cond = p.parseExpr()
  discard p.expect(nsRParen)
  result = nsn(nsnIf, info)
  let br = nsn(nsnIfBranch, info)
  br.body = cond
  br.sons = p.parseEmbedded()
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
      b2.sons = p.parseEmbedded()
      result.add b2
    else:
      let eb = nsn(nsnElseBranch, elseInfo)
      eb.sons = p.parseEmbedded()
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
  result.sons = p.parseEmbedded()

proc parseDoWhile(p: var NsParser): NsNode =
  ## `do { B } while (c);`, whose body runs before the condition is first read.
  let info = p.here()
  discard p.advance
  result = nsn(nsnDoWhile, info)
  result.sons = p.parseEmbedded()
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
  result.sons = p.parseEmbedded()

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
  result.sons = p.parseEmbedded()

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
        let lab = nsn(nsnCaseLabel, p.here())
        lab.body = p.parsePattern()
        if p.at(nsIdent) and p.peek.text == "when":
          discard p.advance
          lab.add p.parseExpr()
        sec.add lab
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

proc parseUsingResource(p: var NsParser; into: var seq[NsNode]) =
  ## `var r = e`, `T a = e, b = f`, or an expression whose value is disposed.
  let d = p.parseVarDecl()
  if d.kind == nsnMultiDecl:
    for x in d.sons: into.add x
  else: into.add d

proc parseUsingStmt(p: var NsParser): NsNode =
  ## `using (resources) statement`, and the declaration `using var r = e;`, whose
  ## resources are disposed at the end of the enclosing block.
  let info = p.here()
  discard p.advance
  result = nsn(nsnUsingStmt, info)
  if p.at(nsLParen):
    discard p.advance
    if looksLikeDecl(p): p.parseUsingResource(result.sons)
    else: result.add p.parseExpr()
    discard p.expect(nsRParen)
    let blk = nsn(nsnBlock, p.here())
    blk.sons = p.parseEmbedded()
    result.body = blk
  else:
    p.parseUsingResource(result.sons)

proc parseLock(p: var NsParser): NsNode =
  ## `lock (x) statement`.
  let info = p.here()
  discard p.advance
  result = nsn(nsnLock, info)
  discard p.expect(nsLParen)
  result.body = p.parseExpr()
  discard p.expect(nsRParen)
  result.sons = p.parseEmbedded()

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
      if p.at(nsIdent) and p.peek.text == "when" and p.peekAhead(1).kind == nsLParen:
        ## `catch (E e) when (cond)`: the clause applies only when the filter holds.
        discard p.advance
        discard p.expect(nsLParen)
        c.add p.parseExpr()
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

proc parseOperatorBody(p: var NsParser; n: NsNode) =
  ## An operator's body: a block, or `=> e;`.
  if p.at(nsArrow):
    let info = p.here()
    discard p.advance
    n.body = p.parseArrowBody(info, n.typ != nil and n.typ.kind != nsnVoidType)
    if p.at(nsSemi): discard p.advance
  elif p.at(nsSemi):
    ## `static abstract T operator +(T a, T b);` in an interface.
    discard p.advance
  else:
    n.body = p.parseBlock()


proc parseAccessors(p: var NsParser; info: TLineInfo): (NsNode, NsNode) =
  ## A property's or indexer's accessors: `=> e`, or `{ get ...; set ...; }` where
  ## each accessor is `;` (an auto accessor), a block, or `=> e;`, and may carry its
  ## own access modifier (`private set;`). `init` is a setter C# restricts to object
  ## initialisers and constructors.
  var getter, setter: NsNode = nil
  if p.at(nsArrow):
    ## `R P => e;` is `R P { get { return e; } }`.
    discard p.advance
    getter = p.parseArrowBody(info, true)
    if p.at(nsSemi): discard p.advance
    return (getter, setter)
  discard p.expect(nsLBrace)
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    let mods = p.parseModifierList(["public", "private", "protected", "internal"],
                                   ["public", "private", "protected", "internal"])
    if p.at(nsIdent) and p.peek.text in ["get", "set", "init"]:
      let isGet = p.peek.text == "get"
      let isInit = p.peek.text == "init"
      discard p.advance
      var acc: NsNode
      if p.at(nsLBrace):
        acc = p.parseBlock()
      elif p.at(nsArrow):
        discard p.advance
        acc = p.parseArrowBody(info, isGet)
        if p.at(nsSemi): discard p.advance
      else:
        ## `get;` / `set;`: an auto-property accessor.
        acc = nsn(nsnEmpty, info)
        if p.at(nsSemi): discard p.advance
      if mods.len > 0:
        acc.attrs = NsAttrs(access: accessOf(mods))
        acc.strVal = "access"
      if isInit: acc.name = "init"
      if isGet: getter = acc else: setter = acc
    else:
      p.err(p.peek, ndUnsupported, "this property accessor")
      discard p.advance
  discard p.expect(nsRBrace)
  (getter, setter)

proc parseTypeDecl(p: var NsParser): NsNode
proc parseEnumDecl(p: var NsParser): NsNode
proc parseDelegateDecl(p: var NsParser): NsNode

proc parseClassMemberInner(p: var NsParser; clsName: string;
                           isInterface: bool): NsNode

proc parseClassMember(p: var NsParser; clsName: string;
                      isInterface = false): NsNode =
  ## A member, with the attributes written before it.
  let attrs = p.parseAttributes()
  p.refReturn = false
  result = p.parseClassMemberInner(clsName, isInterface)
  if result != nil and p.refReturn and result.kind == nsnMethodDecl:
    result.paramMod = "ref"
  elif result != nil and p.refReturn:
    p.err(p.peek, ndUnsupported, "a reference return from this member")
  p.refReturn = false
  if result != nil:
    if result.kind == nsnMultiDecl:
      for f in result.sons: f.attributes = attrs
    else: result.attributes = attrs

proc parseClassMemberInner(p: var NsParser; clsName: string;
                           isInterface: bool): NsNode =
  block nestedType:
    ## A type declared inside a type. It stays a member here, as C# writes it;
    ## `hoistNestedTypes` moves it out once the file is parsed.
    var k = 0
    while p.peekAhead(k).kind == nsIdent and
          p.peekAhead(k).text in NsTypeModifiers or
          (p.peekAhead(k).kind == nsIdent and p.peekAhead(k).text == "new"):
      inc k
    let head = p.peekAhead(k)
    if head.kind != nsIdent or p.peekAhead(k + 1).kind != nsIdent: break nestedType
    case head.text
    of "class", "struct", "interface", "record":
      if k > 0 and p.peekAhead(k - 1).text == "new": break nestedType
      return p.parseTypeDecl()
    of "enum": return p.parseEnumDecl()
    of "delegate": return p.parseDelegateDecl()
    else: discard
  let modInfo = p.here()
  let mods = p.parseModifierList(NsModifierWords, NsMemberModifiers)
  let isConst = "const" in mods
  let isStatic = "static" in mods or isConst
  let attrs = NsAttrs(access: accessOf(mods), isStatic: isStatic, isConst: isConst,
                      isReadonly: "readonly" in mods, isVirtual: "virtual" in mods,
                      isOverride: "override" in mods, isAbstract: "abstract" in mods,
                      isSealed: "sealed" in mods, isNew: "new" in mods,
                      isEvent: "event" in mods, isRequired: "required" in mods)

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
          result.initArgs.add p.parseArgument()
          if p.at(nsComma): discard p.advance else: break
        discard p.expect(nsRParen)
    result.body = p.parseBlock()
    return

  if p.peek.kind != nsIdent and not p.at(nsLParen):
    p.err(p.peek, ndMemberDeclarationExpected, p.peek.text)
    discard p.advance
    return nsn(nsnEmpty, modInfo)

  if p.peek.text == "operator" and ("implicit" in mods or "explicit" in mods):
    ## `public static implicit operator double(Vec v)`: a conversion.
    result = nsn(nsnOperatorDecl, p.here())
    discard p.advance
    result.name = (if "implicit" in mods: "implicit" else: "explicit")
    var cattrs = attrs
    if p.at(nsIdent) and p.peek.text == "checked" and p.peekAhead(1).kind == nsIdent:
      ## `explicit operator checked int(Money m)` (C# 11).
      discard p.advance
      cattrs.isChecked = true
    result.typ = p.parseType()
    result.attrs = cattrs
    result.params = p.parseParams()
    p.parseOperatorBody(result)
    return

  if p.at(nsIdent) and p.peek.text == "ref" and p.peekAhead(1).kind == nsIdent:
    ## `ref T M()` / `ref readonly T M()`: a reference return.
    discard p.advance
    if p.at(nsIdent) and p.peek.text == "readonly" and p.peekAhead(1).kind == nsIdent:
      discard p.advance
    p.refReturn = true
  let ty = p.parseType()
  if p.at(nsIdent) and p.peek.text == "operator":
    ## `public static Vec operator +(Vec a, Vec b)`
    result = nsn(nsnOperatorDecl, p.here())
    discard p.advance
    var cattrs = attrs
    if p.at(nsIdent) and p.peek.text == "checked":
      ## `operator checked +` (C# 11): the version a `checked` context calls.
      discard p.advance
      cattrs.isChecked = true
    let opTok = p.advance
    result.name = opTok.text
    if opTok.kind == nsGt and p.at(nsGt):
      ## `>>` is lexed as two tokens when it closed a generic list elsewhere.
      discard p.advance
      result.name = ">>"
    result.typ = ty
    result.attrs = cattrs
    result.params = p.parseParams()
    p.parseOperatorBody(result)
    return
  if p.at(nsIdent) and p.peek.text == "this" and p.peekAhead(1).kind == nsLBracket:
    ## `public T this[int i] { get ...; set ...; }`
    result = nsn(nsnIndexerDecl, p.here())
    discard p.advance
    discard p.advance   # '['
    result.typ = ty
    result.attrs = attrs
    while not p.at(nsRBracket) and not p.at(nsEof):
      let pinfo = p.here()
      let pty = p.parseType()
      var pname = ""
      if p.peek.kind == nsIdent: pname = p.advance.text
      else: p.err(p.peek, ndIdentifierExpected)
      result.params.add nsnParam(pname, pty, pinfo)
      if p.at(nsComma): discard p.advance else: break
    discard p.expect(nsRBracket)
    let (getter, setter) = p.parseAccessors(result.info)
    result.sons = @[getter, setter]
    return
  if p.peek.kind != nsIdent:
    p.err(p.peek, ndIdentifierExpected)
    p.recoverToSemi()
    if p.at(nsSemi): discard p.advance
    return nsn(nsnEmpty, modInfo)

  var nameTok = p.advance
  var explicitIface = ""
  while p.at(nsDot) and p.peekAhead(1).kind == nsIdent:
    ## `R IShape.Area()`: an explicit interface implementation.
    explicitIface = (if explicitIface.len > 0: explicitIface & "." else: "") &
                    nameTok.text
    discard p.advance
    nameTok = p.advance
  let info = p.infoOf(nameTok)

  if p.at(nsLParen) or p.at(nsLt):
    result = nsn(nsnMethodDecl, info)
    result.name = nameTok.text
    result.explicitIface = explicitIface
    result.typ = ty
    result.attrs = attrs
    result.typeParams = p.parseTypeParams()
    let savedTps = p.typeParams
    for t in result.typeParams: p.typeParams.add t.name
    result.params = p.parseParams()
    result.constraints = p.parseWhereClauses()
    defer: p.typeParams = savedTps
    if p.at(nsSemi):
      ## An interface or `abstract` member has no body; `sema.nim` reports one that
      ## should have had one.
      discard p.advance
    elif p.at(nsArrow):
      ## `R M() => e;` is `R M() { return e; }`, or the statement for `void`.
      let arrowInfo = p.here()
      discard p.advance
      result.body = p.parseArrowBody(arrowInfo, ty.kind != nsnVoidType)
      if p.at(nsSemi): discard p.advance
    else:
      result.body = p.parseBlock()
  elif p.at(nsLBrace) or p.at(nsArrow):
    result = nsn(nsnPropertyDecl, info)
    result.name = nameTok.text
    result.explicitIface = explicitIface
    result.typ = ty
    result.attrs = attrs
    let (getter, setter) = p.parseAccessors(info)
    if p.at(nsAssign):
      ## `{ get; set; } = value;` initialises the backing field.
      discard p.advance
      result.body = p.parseExpr()
      if p.at(nsSemi): discard p.advance
    result.params = @[getter, setter]
  else:
    result = nsn(nsnFieldDecl, info)
    result.name = nameTok.text
    result.typ = ty
    result.attrs = attrs
    if p.at(nsAssign):
      discard p.advance
      result.body = p.parseInitializer(ty)
    if p.at(nsComma) and p.peekAhead(1).kind == nsIdent:
      ## `int a = 1, b;`: one field per declarator, with the same type and
      ## modifiers; the class takes them as separate members.
      let group = nsn(nsnMultiDecl, info)
      group.add result
      while p.at(nsComma) and p.peekAhead(1).kind == nsIdent:
        discard p.advance
        let f = nsn(nsnFieldDecl, p.here())
        f.name = p.advance.text
        f.typ = ty
        f.attrs = attrs
        if p.at(nsAssign):
          discard p.advance
          f.body = p.parseInitializer(ty)
        group.add f
      result = group
    if p.at(nsSemi): discard p.advance

proc parseTypeDecl(p: var NsParser): NsNode =
  let startInfo = p.here()
  let mods = p.parseModifierList(NsTypeModifiers, NsClassModifiers)
  let kwTok = p.advance
  var ckind = ckClass
  if kwTok.text == "struct": ckind = ckStruct
  elif kwTok.text == "interface": ckind = ckInterface
  let isRecord = kwTok.text == "record"
  if isRecord and p.at(nsIdent) and p.peek.text in ["class", "struct"] and
     p.peekAhead(1).kind == nsIdent:
    ## `record class R` is `record R`; `record struct R` is a value type.
    if p.advance.text == "struct": ckind = ckStruct
  if p.peek.kind != nsIdent:
    return nsn(nsnEmpty, startInfo)
  let nameTok = p.advance
  result = nsn(nsnClassDecl, p.infoOf(nameTok))
  result.name = nameTok.text
  result.classKind = ckind
  result.typeParams = p.parseTypeParams()
  let savedTps = p.typeParams
  for t in result.typeParams: p.typeParams.add t.name
  if p.at(nsLParen) and ckind != ckInterface:
    ## `record R(int X, string Y)`: the positional parameters, which become the
    ## record's properties, constructor and `Deconstruct`; `class C(int x)`: a
    ## primary constructor (C# 12), whose parameters the whole body sees.
    result.params = p.parseParams()
  result.attrs = NsAttrs(access: accessOfTopLevel(mods), isAbstract: "abstract" in mods,
                         isSealed: "sealed" in mods, isStatic: "static" in mods,
                         isPartial: "partial" in mods, isFile: "file" in mods)
  if p.at(nsColon):
    ## `: Base, I1, I2`. Which of them is a class is not the grammar's to say:
    ## `symbols.nim` decides, once every type is known.
    discard p.advance
    result.bases.add p.parseType()
    if result.params.len > 0 and p.at(nsLParen):
      ## `: Base(X)`: the base's constructor arguments, from the primary ones.
      discard p.advance
      while not p.at(nsRParen) and not p.at(nsEof):
        result.initArgs.add p.parseArgument()
        if p.at(nsComma): discard p.advance else: break
      discard p.expect(nsRParen)
    while p.at(nsComma):
      discard p.advance
      result.bases.add p.parseType()
    result.typ = result.bases[0]
  result.constraints = p.parseWhereClauses()
  result.attrs.isRecord = isRecord
  if (isRecord or result.params.len > 0) and p.at(nsSemi):
    ## `record R(int X);` and `class C(int x);` have no body.
    discard p.advance
    p.typeParams = savedTps
    return
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
    if m != nil and m.kind == nsnMultiDecl:
      for f in m.sons: result.add f
    elif m != nil: result.add m
  discard p.expect(nsRBrace)
  p.typeParams = savedTps

proc parseEnumDecl(p: var NsParser): NsNode =
  let info = p.here()
  let mods = p.parseModifierList(NsTypeModifiers, NsClassModifiers)
  discard p.advance   # enum
  if p.peek.kind != nsIdent:
    return nsn(nsnEmpty, info)
  let nameTok = p.advance
  result = nsn(nsnEnumDecl, p.infoOf(nameTok))
  result.name = nameTok.text
  result.attrs = NsAttrs(access: accessOfTopLevel(mods), isFile: "file" in mods)
  if p.at(nsColon):
    ## `enum E : byte`: the underlying integer type.
    discard p.advance
    result.typ = p.parseType()
  if p.at(nsLBrace):
    discard p.advance
    while not p.at(nsRBrace) and not p.at(nsEof):
      if p.at(nsComma):
        discard p.advance
        continue
      let fattrs = p.parseAttributes()
      if p.peek.kind != nsIdent:
        discard p.advance
        continue
      let fieldTok = p.advance
      let f = nsn(nsnEnumField, p.infoOf(fieldTok))
      f.name = fieldTok.text
      f.attributes = fattrs
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
  result.attrs = NsAttrs(access: accessOfTopLevel(mods), isFile: "file" in mods)
  result.typeParams = p.parseTypeParams()
  result.params = p.parseParams()
  result.constraints = p.parseWhereClauses()
  if p.at(nsSemi): discard p.advance

proc parseUsing(p: var NsParser): NsNode =
  ## `using X.Y;` names a namespace. `using Alias = X.Y;` names the same namespace
  ## through an alias, which works because lowering drops the qualifier, so the
  ## target is what gets imported -- but the alias itself is what a *qualifier*
  ## written with it is resolved against, so it is recorded on the node.
  result = nsn(nsnUsing, p.here())
  discard p.advance
  if p.at(nsIdent) and p.peek.text == "static" and p.peekAhead(1).kind == nsIdent:
    ## `using static N.T;`: the statics of `T` are reachable by their bare names.
    ## `T`'s namespace is imported; sema resolves the names.
    discard p.advance
    let target = p.parseType()
    result.strVal = "static"
    result.typ = target
    let dot = target.name.rfind('.')
    result.name = (if dot > 0: target.name[0 ..< dot] else: "")
    while not p.at(nsSemi) and not p.at(nsEof): discard p.advance
    if p.at(nsSemi): discard p.advance
    return
  let first = p.parseDottedName()
  if p.at(nsAssign):
    discard p.advance
    let target = p.parseType()
    let last = target.name.split('.')[^1]
    if target.kind == nsnTypeName and
       (target.sons.len > 0 or (not isDeclaredNamespace(target.name) and
        (isDeclaredType(last) or p.surface.isKnownTypeName(last)))):
      ## An alias of a type: the parser writes the target wherever the alias is
      ## named, and the target's namespace is imported.
      p.typeAliases[first] = target
      result.strVal = "type"
      result.alias = first
      result.typ = target
      let dot = target.name.rfind('.')
      result.name = (if dot > 0: target.name[0 ..< dot] else: "")
      while not p.at(nsSemi) and not p.at(nsEof): discard p.advance
      if p.at(nsSemi): discard p.advance
      return
    result.name = target.name
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
  result.body = nsn(nsnBlock, info)
  if p.at(nsSemi):
    ## `namespace A.B;`: the rest of the file is its body.
    discard p.advance
    while not p.at(nsEof):
      if p.at(nsSemi):
        discard p.advance
        continue
      let before = p.pos
      let d = p.parseTopLevelDecl(result.name)
      if d != nil: result.body.add d
      if p.pos == before:
        p.err(p.peek, ndParserStalled)
        discard p.advance
    return
  discard p.expect(nsLBrace)
  while not p.at(nsRBrace) and not p.at(nsEof):
    if p.at(nsSemi):
      discard p.advance
      continue
    let d = p.parseTopLevelDecl(result.name)
    if d != nil: result.body.add d
  discard p.expect(nsRBrace)

proc parseTopLevelDeclInner(p: var NsParser; nsPrefix: string): NsNode

proc parseTopLevelDecl(p: var NsParser; nsPrefix: string): NsNode =
  ## A declaration with the attributes written before it. `[assembly: X]` applies to
  ## the program, which N# gives no reflection to read it, so it is dropped.
  let attrs = p.parseAttributes()
  var kept: seq[NsNode] = @[]
  for a in attrs:
    if a.strVal notin ["assembly", "module"]: kept.add a
  if kept.len == 0 and attrs.len > 0 and
     (p.at(nsEof) or p.at(nsRBrace)):
    return nil
  result = p.parseTopLevelDeclInner(nsPrefix)
  if result != nil: result.attributes = kept

proc parseTopLevelDeclInner(p: var NsParser; nsPrefix: string): NsNode =
  ## `nsPrefix` is the enclosing namespace, for a nested `namespace` statement.
  var k = 0
  while p.peekAhead(k).kind == nsIdent and p.peekAhead(k).text in NsTypeModifiers:
    inc k
  let head = p.peekAhead(k)
  if head.kind == nsIdent and head.text in ["class", "struct", "interface", "record"]:
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

proc hoistNestedTypes(list: var seq[NsNode]; config: ConfigRef) =
  ## A nested type becomes a sibling of the type that declares it, recording the
  ## enclosing types for its runtime name (`Demo.Outer+Inner`). C# resolves
  ## `Outer.Inner` by its last name already, so the qualifier needs no lowering. A
  ## generic enclosing type would lend the nested one its type parameters, which a
  ## sibling cannot see, so that is reported.
  var i = 0
  while i < list.len:
    let d = list[i]
    if d.kind == nsnNamespace and d.body != nil:
      hoistNestedTypes(d.body.sons, config)
    elif d.kind == nsnClassDecl:
      var kept: seq[NsNode] = @[]
      var nested: seq[NsNode] = @[]
      for m in d.sons:
        if m.kind in {nsnClassDecl, nsnEnumDecl, nsnDelegateDecl}:
          m.outer = (if d.outer.len > 0: d.outer & "+" else: "") & d.name
          if m.attrs.isFile: nsError(config, m.info, ndNestedFileType, m.name)
          nested.add m
        else: kept.add m
      d.sons = kept
      if nested.len > 0 and d.typeParams.len > 0:
        nsError(config, nested[0].info, ndUnsupported, "a type nested in a generic type")
      var j = i + 1
      for m in nested:
        list.insert(m, j)
        inc j
    inc i

proc synthesizeEntryPoint(module: NsNode) =
  ## C# 9 top-level statements: the statements written outside any type are the
  ## body of a `static void Main(string[] args)` in a class `Program` of the global
  ## namespace, which the C# compiler synthesizes. The tree gets that class, so the
  ## later stages see an ordinary entry point; a local function among the
  ## statements is a local function of `Main`, as in C#.
  var stmts: seq[NsNode] = @[]
  var kept: seq[NsNode] = @[]
  for d in module.sons:
    if d.kind in {nsnClassDecl, nsnEnumDecl, nsnDelegateDecl, nsnUsing, nsnNamespace,
                  nsnEmpty}:
      kept.add d
    else: stmts.add d
  if stmts.len == 0: return
  let info = stmts[0].info
  let main = nsn(nsnMethodDecl, info)
  main.name = "Main"
  main.typ = nsn(nsnVoidType, info)
  main.attrs.isStatic = true
  let args = nsn(nsnParam, info)
  args.name = "args"
  args.typ = nsnArrayType(nsnTypeName("string", info), info)
  main.params = @[args]
  main.body = nsn(nsnBlock, info)
  main.body.sons = stmts
  let cls = nsn(nsnClassDecl, info)
  cls.name = "Program"
  cls.attrs.access = aInternal
  cls.add main
  kept.add cls
  module.sons = kept

proc parseNsModule*(source: string; fileIdx: FileIndex;
                    config: ConfigRef): NsNode =
  ## Parses one `.ns` file into an `nsnModule`. No declaration collection, no
  ## semantic checks and no lowering happen here; see `frontend.nim`. The library's
  ## surface is read here because the grammar needs it: a cast is told from a
  ## parenthesised expression by looking the name up as a type.
  let isDefined = proc (sym: string): bool = options.isDefined(config, sym)
  var toks = tokenize(source, isDefined)
  ## Tokens that are diagnostics rather than grammar: a character C# has no token
  ## for, and `#error`/`#warning`.
  var kept: seq[NsToken] = @[]
  for t in toks:
    case t.kind
    of nsInvalid:
      nsError(config, newLineInfo(fileIdx, t.line, t.col), ndUnexpectedCharacter, t.text)
    of nsDirective:
      let sp = t.text.find(' ')
      let msg = (if sp >= 0: t.text[sp + 1 .. ^1] else: "")
      if t.text.startsWith("late "):
        nsError(config, newLineInfo(fileIdx, t.line, t.col), ndDefineAfterToken)
      elif t.text.startsWith("error"):
        nsError(config, newLineInfo(fileIdx, t.line, t.col), ndErrorDirective, msg)
      else:
        nsWarn(config, newLineInfo(fileIdx, t.line, t.col), ndWarningDirective, msg)
    else: kept.add t
  var p = NsParser(toks: kept, pos: 0, config: config,
                   fileIdx: fileIdx, surface: bclSurface(config),
                   aliases: initHashSet[string](),
                   typeAliases: initTable[string, NsNode]())
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
  hoistNestedTypes(result.sons, config)
  synthesizeEntryPoint(result)







