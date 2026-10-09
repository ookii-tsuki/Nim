# N# frontend - lexer
#
# A brace-and-semicolon, whitespace-insensitive lexer, std-only so it can be
# unit-tested in isolation. The whole source is tokenised up front; a streaming
# lexer can replace it later behind the same token type.
#
# C#'s preprocessor is lexical (it removes text before the grammar sees it), so it
# lives here too: `#if`/`#elif`/`#else`/`#endif` select lines, `#define`/`#undef`
# edit the file's symbol set, and a symbol the file does not define is asked of the
# compilation (`-d:X`) through the callback `tokenize` takes. `#region`, `#pragma`
# and `#nullable` carry no meaning for N# and are skipped; `#error`/`#warning`
# become tokens the parser reports.
#
# An interpolated string is not one token: `$"a{x,5:F2}b"` lexes as
#
#   nsInterpBegin  nsStrLit "a"  nsInterpHole  <tokens of x>  nsComma  <tokens of 5>
#   nsInterpHoleEnd (text = "F2")  nsStrLit "b"  nsInterpEnd
#
# so the expression inside a hole is lexed by this same lexer, with its own line
# and column, and parsed by the ordinary expression grammar.

import std/[strutils, sets]

type
  NsTokenKind* = enum
    nsEof
    nsIdent, nsIntLit, nsFloatLit, nsStrLit, nsCharLit
    nsLParen, nsRParen, nsLBrace, nsRBrace, nsLBracket, nsRBracket
    nsSemi, nsComma, nsDot, nsColon, nsColonColon, nsQuestion
    nsQuestionDot, nsQuestionQuestion
    nsQuestionQuestionEq
    nsAssign, nsEqEq, nsNotEq, nsArrow
    nsPlus, nsMinus, nsStar, nsSlash, nsPercent
    nsLt, nsGt, nsLe, nsGe
    nsAmp, nsAmpAmp, nsPipe, nsPipePipe, nsCaret, nsTilde, nsBang, nsAt
    nsPlusPlus, nsMinusMinus
    nsPlusEq, nsMinusEq, nsStarEq, nsSlashEq, nsPercentEq, nsAmpEq, nsPipeEq, nsCaretEq
    nsShl, nsShr, nsShlEq, nsShrEq
    nsDotDot           ## `..`, the range operator
    nsMinusGt          ## `->`, member access through a pointer
    nsInterpBegin, nsInterpHole, nsInterpHoleEnd, nsInterpEnd
    nsDirective        ## `#error`/`#warning`: text = "error msg" / "warning msg"
    nsInvalid          ## a character C# has no token for; text = the character

  NsToken* = object
    kind*: NsTokenKind
    text*: string
    line*: int
    col*: int
    suffix*: string    ## a numeric literal's type suffix, lower-cased: "u", "l", "ul", "f", "d", "m"
    verbatim*: bool    ## an identifier written `@name`, which is never a keyword

  NsDefinedProc* = proc (symbol: string): bool {.closure.}
    ## Asks the compilation whether a preprocessor symbol is defined (`-d:X`).

proc `$`*(k: NsTokenKind): string =
  case k
  of nsEof: "eof"
  of nsIdent: "identifier"
  of nsIntLit: "integer literal"
  of nsFloatLit: "float literal"
  of nsStrLit: "string literal"
  of nsCharLit: "char literal"
  of nsLParen: "'('"
  of nsRParen: "')'"
  of nsLBrace: "'{'"
  of nsRBrace: "'}'"
  of nsLBracket: "'['"
  of nsRBracket: "']'"
  of nsSemi: "';'"
  of nsComma: "','"
  of nsDot: "'.'"
  of nsColon: "':'"
  of nsColonColon: "'::'"
  of nsQuestion: "'?'"
  of nsQuestionDot: "'?.'"
  of nsQuestionQuestion: "'??'"
  of nsQuestionQuestionEq: "'??='"
  of nsAssign: "'='"
  of nsEqEq: "'=='"
  of nsNotEq: "'!='"
  of nsArrow: "'=>'"
  of nsPlus: "'+'"
  of nsMinus: "'-'"
  of nsStar: "'*'"
  of nsSlash: "'/'"
  of nsPercent: "'%'"
  of nsLt: "'<'"
  of nsGt: "'>'"
  of nsLe: "'<='"
  of nsGe: "'>='"
  of nsAmp: "'&'"
  of nsAmpAmp: "'&&'"
  of nsPipe: "'|'"
  of nsPipePipe: "'||'"
  of nsCaret: "'^'"
  of nsTilde: "'~'"
  of nsBang: "'!'"
  of nsAt: "'@'"
  of nsPlusPlus: "'++'"
  of nsMinusMinus: "'--'"
  of nsPlusEq: "'+='"
  of nsMinusEq: "'-='"
  of nsStarEq: "'*='"
  of nsSlashEq: "'/='"
  of nsPercentEq: "'%='"
  of nsAmpEq: "'&='"
  of nsPipeEq: "'|='"
  of nsCaretEq: "'^='"
  of nsShl: "'<<'"
  of nsShr: "'>>'"
  of nsShlEq: "'<<='"
  of nsShrEq: "'>>='"
  of nsDotDot: "'..'"
  of nsMinusGt: "'->'"
  of nsInterpBegin: "'$\"'"
  of nsInterpHole: "'{'"
  of nsInterpHoleEnd: "'}'"
  of nsInterpEnd: "'\"'"
  of nsDirective: "directive"
  of nsInvalid: "invalid character"

proc splitShr*(toks: var seq[NsToken]; i: int): bool =
  ## Splits the `>>` token at `i` into two `>` tokens, in place. `>>` is lexed
  ## greedily (it is also Nim's and C#'s shift operator), so closing two nested
  ## type argument lists, as in `List<List<int>>`, needs it split. Doing it here
  ## rather than in the parser keeps all token surgery in one module. C# has the
  ## same problem and resolves it the same way.
  ##
  ## Returns false when the token at `i` is not a `>>`.
  if i < 0 or i >= toks.len or toks[i].kind != nsShr: return false
  let t = toks[i]
  toks[i] = NsToken(kind: nsGt, text: ">", line: t.line, col: t.col)
  toks.insert(NsToken(kind: nsGt, text: ">", line: t.line, col: t.col + 1), i + 1)
  true

# --- the scanner ------------------------------------------------------------

type
  Scanner = object
    src: string
    i, stop: int           ## current index, and the index scanning ends at
    line, col: int
    toks: seq[NsToken]
    defines: HashSet[string]
    isDefined: NsDefinedProc
    conds: seq[tuple[active, taken, outerActive: bool]]
      ## The open `#if` groups: whether lines are kept now, whether a branch of the
      ## group was already kept, and whether the enclosing group keeps lines at all.

proc cur(s: Scanner): char {.inline.} =
  if s.i < s.stop: s.src[s.i] else: '\0'

proc at(s: Scanner; k: int): char {.inline.} =
  if s.i + k < s.stop: s.src[s.i + k] else: '\0'

proc step(s: var Scanner) {.inline.} =
  if s.i < s.stop:
    if s.src[s.i] == '\n':
      inc s.line
      s.col = 1
    else:
      inc s.col
    inc s.i

proc emit(s: var Scanner; kind: NsTokenKind; text: string; line, col: int;
          suffix = "") =
  s.toks.add NsToken(kind: kind, text: text, line: line, col: col, suffix: suffix)

proc active(s: Scanner): bool =
  s.conds.len == 0 or s.conds[^1].active

proc addUtf8(r: var string; cp: int) =
  ## A code point as UTF-8, since an N# string is UTF-8 bytes (SPEC 4.4).
  if cp < 0x80: r.add char(cp)
  elif cp < 0x800:
    r.add char(0xC0 or (cp shr 6))
    r.add char(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    r.add char(0xE0 or (cp shr 12))
    r.add char(0x80 or ((cp shr 6) and 0x3F))
    r.add char(0x80 or (cp and 0x3F))
  else:
    r.add char(0xF0 or (cp shr 18))
    r.add char(0x80 or ((cp shr 12) and 0x3F))
    r.add char(0x80 or ((cp shr 6) and 0x3F))
    r.add char(0x80 or (cp and 0x3F))

proc readHex(s: var Scanner; maxDigits: int; exact: bool): int =
  result = 0
  var n = 0
  while n < maxDigits and s.cur in HexDigits:
    result = result * 16 + parseHexInt($s.cur)
    s.step
    inc n
  discard exact

proc readEscape(s: var Scanner; into: var string) =
  ## The character after a backslash, appended to `into` (C# escape set).
  let c = s.cur
  s.step
  case c
  of 'n': into.add '\n'
  of 't': into.add '\t'
  of 'r': into.add '\r'
  of 'a': into.add '\a'
  of 'b': into.add '\b'
  of 'f': into.add '\f'
  of 'v': into.add '\v'
  of 'e': into.add '\e'
  of '0': into.add '\0'
  of '\'': into.add '\''
  of '"': into.add '"'
  of '\\': into.add '\\'
  of 'u': into.addUtf8 s.readHex(4, true)
  of 'U': into.addUtf8 s.readHex(8, true)
  of 'x': into.addUtf8 s.readHex(4, false)
  else: into.add c

proc lexAll(s: var Scanner)

proc lexHole(s: var Scanner; verbatim: bool) =
  ## One `{ ... }` of an interpolated string, starting just past the `{`. The hole's
  ## extent is found first (strings, chars and brackets nest; a `:` at depth 0 starts
  ## the format), then the expression part is lexed by the ordinary lexer.
  let hl = s.line
  let hc = s.col - 1
  s.emit(nsInterpHole, "{", hl, hc)
  var depth = 0
  var j = s.i
  var fmtStart = -1
  while j < s.stop:
    let c = s.src[j]
    if c == '"' or c == '\'':
      ## Skip a nested literal, so its braces and colons do not count.
      let q = c
      inc j
      while j < s.stop and s.src[j] != q:
        if s.src[j] == '\\': inc j
        inc j
    elif c in {'(', '[', '{'}: inc depth
    elif c in {')', ']'}: dec depth
    elif c == '}':
      if depth == 0: break
      dec depth
    elif c == ':' and depth == 0:
      ## `a ? b : c` needs parentheses inside a hole in C# as well, and `::` is the
      ## alias qualifier.
      if j + 1 < s.stop and s.src[j + 1] == ':': inc j
      else:
        fmtStart = j
        break
    inc j
  let exprEnd = (if fmtStart >= 0: fmtStart else: j)
  var inner = Scanner(src: s.src, i: s.i, stop: exprEnd, line: s.line, col: s.col,
                      defines: s.defines, isDefined: s.isDefined)
  inner.lexAll()
  for t in inner.toks: s.toks.add t
  while s.i < exprEnd: s.step
  var fmt = ""
  if fmtStart >= 0:
    s.step   # ':'
    while s.i < s.stop and s.cur != '}':
      if not verbatim and s.cur == '\\':
        s.step
        s.readEscape(fmt)
      else:
        fmt.add s.cur
        s.step
  let el = s.line
  let ec = s.col
  if s.cur == '}': s.step
  s.emit(nsInterpHoleEnd, fmt, el, ec)

proc lexInterpolated(s: var Scanner; verbatim: bool; line, col: int) =
  ## The body of `$"..."` / `$@"..."`, starting just past the opening quote.
  s.emit(nsInterpBegin, "$\"", line, col)
  var chunk = ""
  var cl = s.line
  var cc = s.col
  proc flush(s: var Scanner; chunk: var string; cl, cc: int) =
    if chunk.len > 0:
      s.emit(nsStrLit, chunk, cl, cc)
      chunk = ""
  while s.i < s.stop:
    let c = s.cur
    if c == '"':
      if verbatim and s.at(1) == '"':
        chunk.add '"'
        s.step; s.step
        continue
      break
    if c == '{':
      if s.at(1) == '{':
        chunk.add '{'
        s.step; s.step
        continue
      s.flush(chunk, cl, cc)
      s.step
      s.lexHole(verbatim)
      cl = s.line
      cc = s.col
      continue
    if c == '}' and s.at(1) == '}':
      chunk.add '}'
      s.step; s.step
      continue
    if c == '\\' and not verbatim:
      s.step
      s.readEscape(chunk)
      continue
    chunk.add c
    s.step
  s.flush(chunk, cl, cc)
  let el = s.line
  let ec = s.col
  if s.cur == '"': s.step
  s.emit(nsInterpEnd, "\"", el, ec)

proc lexRawString(s: var Scanner; line, col: int) =
  ## `"""..."""` (C# 11). A multi-line raw string drops its first and last line and
  ## the closing line's indentation from every line, as C# does.
  var quotes = 0
  while s.cur == '"':
    inc quotes
    s.step
  var body = ""
  while s.i < s.stop:
    if s.cur == '"':
      var k = 0
      while s.at(k) == '"': inc k
      if k >= quotes:
        for _ in 0 ..< quotes: s.step
        break
      for _ in 0 ..< k:
        body.add '"'
        s.step
      continue
    body.add s.cur
    s.step
  if '\n' in body:
    var lines = body.split('\n')
    if lines.len > 0 and lines[0].strip.len == 0: lines.delete(0)
    var indent = ""
    if lines.len > 0 and lines[^1].strip.len == 0:
      indent = lines[^1]
      lines.setLen(lines.len - 1)
    var outp: seq[string] = @[]
    for ln in lines:
      var x = ln
      if x.endsWith("\r"): x.setLen(x.len - 1)
      if x.startsWith(indent): x = x[indent.len .. ^1]
      outp.add x
    body = outp.join("\n")
  s.emit(nsStrLit, body, line, col)

proc lexNumber(s: var Scanner) =
  ## Decimal, `0x`, `0b`, `_` separators, a fraction only when a digit follows the
  ## dot (so `1..2` and `1.ToString()` read as C# reads them), an exponent, and the
  ## suffixes `u l ul lu f d m`. The text is normalised for `parseBiggestInt`.
  let line = s.line
  let col = s.col
  var text = ""
  var isFloat = false
  if s.cur == '0' and s.at(1) in {'x', 'X'}:
    s.step; s.step
    text = "0x"
    while s.cur in HexDigits + {'_'}:
      if s.cur != '_': text.add s.cur
      s.step
  elif s.cur == '0' and s.at(1) in {'b', 'B'}:
    s.step; s.step
    text = "0b"
    while s.cur in {'0', '1', '_'}:
      if s.cur != '_': text.add s.cur
      s.step
  else:
    while s.cur in Digits + {'_'}:
      if s.cur != '_': text.add s.cur
      s.step
    if s.cur == '.' and s.at(1) in Digits:
      isFloat = true
      text.add '.'
      s.step
      while s.cur in Digits + {'_'}:
        if s.cur != '_': text.add s.cur
        s.step
    if s.cur in {'e', 'E'} and
       (s.at(1) in Digits or (s.at(1) in {'+', '-'} and s.at(2) in Digits)):
      isFloat = true
      text.add 'e'
      s.step
      if s.cur in {'+', '-'}:
        text.add s.cur
        s.step
      while s.cur in Digits:
        text.add s.cur
        s.step
  var suffix = ""
  while s.cur in {'u', 'U', 'l', 'L', 'f', 'F', 'd', 'D', 'm', 'M'}:
    suffix.add toLowerAscii(s.cur)
    s.step
  if suffix == "lu": suffix = "ul"
  if suffix in ["f", "d", "m"]: isFloat = true
  s.emit((if isFloat: nsFloatLit else: nsIntLit), text, line, col, suffix)

proc evalCondition(s: Scanner; expr: string): bool =
  ## A `#if` condition: symbols, `true`/`false`, `!`, `&&`, `||`, `==`, `!=` and
  ## parentheses. A symbol the file does not `#define` is asked of the compilation.
  var p = 0
  proc skipWs() =
    while p < expr.len and expr[p] in {' ', '\t'}: inc p
  proc orExpr(): bool
  proc primary(): bool =
    skipWs()
    if p < expr.len and expr[p] == '!':
      inc p
      return not primary()
    if p < expr.len and expr[p] == '(':
      inc p
      result = orExpr()
      skipWs()
      if p < expr.len and expr[p] == ')': inc p
      return
    var name = ""
    while p < expr.len and expr[p] in IdentChars:
      name.add expr[p]
      inc p
    case name
    of "true": true
    of "false": false
    else:
      name in s.defines or (s.isDefined != nil and s.isDefined(name))
  proc eqExpr(): bool =
    result = primary()
    while true:
      skipWs()
      if p + 1 < expr.len and expr[p] == '=' and expr[p + 1] == '=':
        p += 2
        result = result == primary()
      elif p + 1 < expr.len and expr[p] == '!' and expr[p + 1] == '=':
        p += 2
        result = result != primary()
      else: break
  proc andExpr(): bool =
    result = eqExpr()
    while true:
      skipWs()
      if p + 1 < expr.len and expr[p] == '&' and expr[p + 1] == '&':
        p += 2
        let r = eqExpr()
        result = result and r
      else: break
  proc orExpr(): bool =
    result = andExpr()
    while true:
      skipWs()
      if p + 1 < expr.len and expr[p] == '|' and expr[p + 1] == '|':
        p += 2
        let r = andExpr()
        result = result or r
      else: break
  orExpr()

proc lexDirective(s: var Scanner) =
  ## A preprocessor line, starting at `#`. Only whitespace may precede it on its line,
  ## which the caller has checked.
  let line = s.line
  let col = s.col
  s.step   # '#'
  while s.cur in {' ', '\t'}: s.step
  var word = ""
  while s.cur in IdentChars:
    word.add s.cur
    s.step
  var rest = ""
  while s.i < s.stop and s.cur != '\n':
    rest.add s.cur
    s.step
  let comment = rest.find("//")
  var arg = (if comment >= 0: rest[0 ..< comment] else: rest).strip
  case word
  of "if":
    let outer = s.active
    let v = outer and s.evalCondition(arg)
    s.conds.add (active: v, taken: v, outerActive: outer)
  of "elif":
    if s.conds.len > 0:
      let g = s.conds[^1]
      let v = g.outerActive and not g.taken and s.evalCondition(arg)
      s.conds[^1] = (active: v, taken: g.taken or v, outerActive: g.outerActive)
  of "else":
    if s.conds.len > 0:
      let g = s.conds[^1]
      let v = g.outerActive and not g.taken
      s.conds[^1] = (active: v, taken: true, outerActive: g.outerActive)
  of "endif":
    if s.conds.len > 0: discard s.conds.pop()
  of "define", "undef":
    if s.toks.len > 0:
      ## C# allows these only before the file's first token (CS1032).
      s.emit(nsDirective, "late " & word, line, col)
    elif s.active:
      if word == "define": s.defines.incl arg
      else: s.defines.excl arg
  of "error", "warning":
    if s.active:
      s.emit(nsDirective, word & " " & arg, line, col)
  else:
    ## `#region`, `#endregion`, `#pragma`, `#nullable`, `#line`: no meaning in N#.
    discard

proc lexAll(s: var Scanner) =
  var lineStart = true   ## only whitespace so far on this line
  while s.i < s.stop:
    let c = s.cur

    if c == '\n':
      s.step
      lineStart = true
      continue
    if c in {' ', '\t', '\r', '\f', '\v'}:
      s.step
      continue
    if c == '#' and lineStart:
      s.lexDirective()
      continue
    if not s.active:
      ## A line an `#if` removed: skip it whole.
      while s.i < s.stop and s.cur != '\n': s.step
      continue
    lineStart = false

    # line comment
    if c == '/' and s.at(1) == '/':
      while s.i < s.stop and s.cur != '\n': s.step
      continue
    # block comment
    if c == '/' and s.at(1) == '*':
      s.step; s.step
      while s.i < s.stop and not (s.cur == '*' and s.at(1) == '/'): s.step
      s.step; s.step
      continue

    let line = s.line
    let col = s.col

    # interpolated strings: $"..", $@"..", @$".."
    if c == '$' and s.at(1) == '"':
      s.step; s.step
      s.lexInterpolated(false, line, col)
      continue
    if (c == '$' and s.at(1) == '@' and s.at(2) == '"') or
       (c == '@' and s.at(1) == '$' and s.at(2) == '"'):
      s.step; s.step; s.step
      s.lexInterpolated(true, line, col)
      continue
    # verbatim string @"..", where "" is a quote and nothing is an escape
    if c == '@' and s.at(1) == '"':
      s.step; s.step
      var str = ""
      while s.i < s.stop:
        if s.cur == '"':
          if s.at(1) == '"':
            str.add '"'
            s.step; s.step
            continue
          break
        str.add s.cur
        s.step
      s.step
      s.emit(nsStrLit, str, line, col)
      continue
    # verbatim identifier @class
    if c == '@' and s.at(1) in IdentStartChars:
      s.step
      var name = ""
      while s.cur in IdentChars:
        name.add s.cur
        s.step
      s.toks.add NsToken(kind: nsIdent, text: name, line: line, col: col,
                         verbatim: true)
      continue

    # raw string literal """..."""
    if c == '"' and s.at(1) == '"' and s.at(2) == '"':
      s.lexRawString(line, col)
      continue

    # string literal
    if c == '"':
      s.step
      var str = ""
      while s.i < s.stop and s.cur != '"' and s.cur != '\n':
        if s.cur == '\\':
          s.step
          s.readEscape(str)
        else:
          str.add s.cur
          s.step
      s.step
      s.emit(nsStrLit, str, line, col)
      continue

    # char literal
    if c == '\'':
      s.step
      var str = ""
      while s.i < s.stop and s.cur != '\'' and s.cur != '\n':
        if s.cur == '\\':
          s.step
          s.readEscape(str)
        else:
          str.add s.cur
          s.step
      s.step
      s.emit(nsCharLit, str, line, col)
      continue

    # identifier / keyword
    if c in IdentStartChars:
      var name = ""
      while s.cur in IdentChars:
        name.add s.cur
        s.step
      s.emit(nsIdent, name, line, col)
      continue

    # number (also `.5`)
    if c in Digits or (c == '.' and s.at(1) in Digits):
      if c == '.':
        ## `.5` is `0.5`.
        s.step
        var text = "0."
        while s.cur in Digits + {'_'}:
          if s.cur != '_': text.add s.cur
          s.step
        var suffix = ""
        while s.cur in {'f', 'F', 'd', 'D', 'm', 'M'}:
          suffix.add toLowerAscii(s.cur)
          s.step
        s.emit(nsFloatLit, text, line, col, suffix)
        continue
      s.lexNumber()
      continue

    # three-character operators
    let three = $c & $s.at(1) & $s.at(2)
    let kind3 = case three
      of "<<=": nsShlEq
      of ">>=": nsShrEq
      of "??=": nsQuestionQuestionEq
      else: nsEof
    if kind3 != nsEof:
      s.emit(kind3, three, line, col)
      s.step; s.step; s.step
      continue

    # two-character operators
    let two = $c & $s.at(1)
    let kind2 = case two
      of "==": nsEqEq
      of "!=": nsNotEq
      of "<=": nsLe
      of ">=": nsGe
      of "&&": nsAmpAmp
      of "||": nsPipePipe
      of "?.": nsQuestionDot
      of "??": nsQuestionQuestion
      of "=>": nsArrow
      of "::": nsColonColon
      of "++": nsPlusPlus
      of "--": nsMinusMinus
      of "+=": nsPlusEq
      of "-=": nsMinusEq
      of "*=": nsStarEq
      of "/=": nsSlashEq
      of "%=": nsPercentEq
      of "&=": nsAmpEq
      of "|=": nsPipeEq
      of "^=": nsCaretEq
      of "<<": nsShl
      of ">>": nsShr
      of "..": nsDotDot
      of "->": nsMinusGt
      else: nsEof
    if kind2 == nsQuestionDot and s.at(2) in Digits:
      ## `a?.5:b` is a ternary over `.5`, not a null-conditional access.
      discard
    elif kind2 != nsEof:
      s.emit(kind2, two, line, col)
      s.step; s.step
      continue

    # single-character tokens
    let kind1 = case c
      of '(': nsLParen
      of ')': nsRParen
      of '{': nsLBrace
      of '}': nsRBrace
      of '[': nsLBracket
      of ']': nsRBracket
      of ';': nsSemi
      of ',': nsComma
      of '.': nsDot
      of ':': nsColon
      of '?': nsQuestion
      of '=': nsAssign
      of '+': nsPlus
      of '-': nsMinus
      of '*': nsStar
      of '/': nsSlash
      of '%': nsPercent
      of '<': nsLt
      of '>': nsGt
      of '&': nsAmp
      of '|': nsPipe
      of '^': nsCaret
      of '~': nsTilde
      of '!': nsBang
      of '@': nsAt
      else: nsInvalid
    s.emit(kind1, $c, line, col)
    s.step

proc tokenize*(source: string; isDefined: NsDefinedProc = nil): seq[NsToken] =
  ## Tokenises `.ns` source. Always ends with an `nsEof` token. `isDefined` answers
  ## for a preprocessor symbol the file does not `#define` itself.
  var s = Scanner(src: source, i: 0, stop: source.len, line: 1, col: 1,
                  defines: initHashSet[string](), isDefined: isDefined)
  ## A byte order mark is not part of the program.
  if source.startsWith("\xEF\xBB\xBF"):
    s.i = 3
  s.lexAll()
  result = move s.toks
  result.add NsToken(kind: nsEof, text: "", line: s.line, col: s.col)
