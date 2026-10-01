#
#           N# frontend - lexer
#
# A brace + semicolon, whitespace-insensitive lexer (SPEC §3). Phase 0 keeps
# this dependency-light (std only) so it can be unit-tested in isolation.
#
# The whole source is tokenised up front (`tokenize`) - simple and adequate for
# the Phase-0 scaffold; a streaming lexer can replace it later behind the same
# token type.

type
  NsTokenKind* = enum
    nsEof
    nsIdent, nsIntLit, nsFloatLit, nsStrLit, nsCharLit
    nsLParen, nsRParen, nsLBrace, nsRBrace, nsLBracket, nsRBracket
    nsSemi, nsComma, nsDot, nsColon, nsColonColon, nsQuestion
    nsAssign, nsEqEq, nsNotEq, nsArrow
    nsPlus, nsMinus, nsStar, nsSlash, nsPercent
    nsLt, nsGt, nsLe, nsGe
    nsAmp, nsAmpAmp, nsPipe, nsPipePipe, nsCaret, nsTilde, nsBang, nsAt
    nsPlusPlus, nsMinusMinus
    nsPlusEq, nsMinusEq, nsStarEq, nsSlashEq, nsPercentEq, nsAmpEq, nsPipeEq, nsCaretEq
    nsShl, nsShr, nsShlEq, nsShrEq

  NsToken* = object
    kind*: NsTokenKind
    text*: string
    line*: int
    col*: int

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

proc tokenize*(source: string): seq[NsToken] =
  ## Tokenises `.ns` source. Always ends with an `nsEof` token.
  result = @[]
  var i = 0
  let n = source.len
  var line = 1
  var col = 1

  while i < n:
    let c = source[i]

    if c == '\n':
      inc i; inc line; col = 1
      continue
    if c in {' ', '\t', '\r'}:
      inc i; inc col
      continue

    # line comment
    if c == '/' and i + 1 < n and source[i + 1] == '/':
      while i < n and source[i] != '\n':
        inc i
      continue
    # block comment
    if c == '/' and i + 1 < n and source[i + 1] == '*':
      i += 2
      while i + 1 < n and not (source[i] == '*' and source[i + 1] == '/'):
        if source[i] == '\n':
          inc line
          col = 1
        inc i
      i += 2
      continue

    let startLine = line
    let startCol = col

    # string literal
    if c == '"':
      inc i; inc col
      var s = ""
      while i < n and source[i] != '"':
        if source[i] == '\\' and i + 1 < n:
          inc i; inc col
          case source[i]
          of 'n': s.add '\n'
          of 't': s.add '\t'
          of 'r': s.add '\r'
          of '"': s.add '"'
          of '\\': s.add '\\'
          of '0': s.add '\0'
          else: s.add source[i]
          inc i; inc col
        else:
          s.add source[i]
          inc i; inc col
      inc i; inc col
      result.add NsToken(kind: nsStrLit, text: s, line: startLine, col: startCol)
      continue

    # char literal
    if c == '\'':
      inc i; inc col
      var s = ""
      while i < n and source[i] != '\'':
        if source[i] == '\\' and i + 1 < n:
          inc i; inc col
          case source[i]
          of 'n': s.add '\n'
          of 't': s.add '\t'
          of 'r': s.add '\r'
          of '\'': s.add '\''
          of '\\': s.add '\\'
          of '0': s.add '\0'
          else: s.add source[i]
          inc i; inc col
        else:
          s.add source[i]
          inc i; inc col
      inc i; inc col
      result.add NsToken(kind: nsCharLit, text: s, line: startLine, col: startCol)
      continue

    # identifier / keyword
    if c in {'a'..'z', 'A'..'Z', '_'}:
      var s = ""
      while i < n and source[i] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        s.add source[i]
        inc i; inc col
      result.add NsToken(kind: nsIdent, text: s, line: startLine, col: startCol)
      continue

    # number
    if c in {'0'..'9'}:
      var s = ""
      var isFloat = false
      while i < n and source[i] in {'0'..'9', '.', '_', 'e', 'E', 'x', 'X',
                                    'a'..'f', 'A'..'F'}:
        if source[i] == '.':
          isFloat = true
        if source[i] != '_':
          s.add source[i]
        inc i; inc col
      result.add NsToken(kind: (if isFloat: nsFloatLit else: nsIntLit),
                         text: s, line: startLine, col: startCol)
      continue

    # three-character operators
    if i + 2 < n:
      let three = source[i] & source[i + 1] & source[i + 2]
      let kind3 = case three
        of "<<=": nsShlEq
        of ">>=": nsShrEq
        else: nsEof
      if kind3 != nsEof:
        result.add NsToken(kind: kind3, text: three, line: startLine, col: startCol)
        i += 3; col += 3
        continue

    # two-character operators
    if i + 1 < n:
      let two = source[i] & source[i + 1]
      let kind2 = case two
        of "==": nsEqEq
        of "!=": nsNotEq
        of "<=": nsLe
        of ">=": nsGe
        of "&&": nsAmpAmp
        of "||": nsPipePipe
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
        else: nsEof
      if kind2 != nsEof:
        result.add NsToken(kind: kind2, text: two, line: startLine, col: startCol)
        i += 2; col += 2
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
      else: nsEof
    if kind1 == nsEof:
      inc i; inc col   # unknown char: skip (Phase 0 is tolerant)
      continue
    result.add NsToken(kind: kind1, text: $c, line: startLine, col: startCol)
    inc i; inc col

  result.add NsToken(kind: nsEof, text: "", line: line, col: col)
