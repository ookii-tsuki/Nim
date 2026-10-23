# N# intrinsics: C#'s format strings
#
# What a hole of an interpolated string does with `{x,align:spec}`, and what
# `String.Format` does with `{0,align:spec}`. The specs are .NET's standard numeric
# ones (`C D E F G N P R X`, each with an optional precision) and its custom numeric
# ones (`0`, `#`, `.`, `,`, `%`, literals), rendered the way .NET's en-US culture
# renders them. A value that is not a number ignores its spec, as `object.ToString`
# does in .NET for a type that does not implement `IFormattable`.

import std/[strutils, math]
import std/options except `$`

proc nsGroup(intDigits: string): string =
  ## `1234567` as `1,234,567`.
  result = ""
  let n = intDigits.len
  for i in 0 ..< n:
    if i > 0 and (n - i) mod 3 == 0: result.add ','
    result.add intDigits[i]

proc nsPrecision(spec: string; default: int): int =
  if spec.len <= 1: return default
  try: result = parseInt(spec[1 .. ^1])
  except ValueError: result = default

proc nsExponent(e: int; minDigits: int; upper: bool): string =
  ## `E+003`: the sign is always written, and at least `minDigits` digits.
  result = (if upper: "E" else: "e") & (if e < 0: "-" else: "+")
  result.add align($abs(e), minDigits, '0')

proc nsSplitSci(s: string): tuple[neg: bool, digits: string, exp: int] =
  ## A float printed by Nim or by C (`-1.2345e+03`, `0.001`, `12.5`) as its sign, its
  ## significant digits without leading zeros, and the power of ten of the first one.
  var t = s
  result.neg = t.len > 0 and t[0] == '-'
  if result.neg: t = t[1 .. ^1]
  var e = 0
  let ei = t.find({'e', 'E'})
  if ei >= 0:
    e = parseInt(t[ei + 1 .. ^1])
    t = t[0 ..< ei]
  let dot = t.find('.')
  var intPart = (if dot >= 0: t[0 ..< dot] else: t)
  var frac = (if dot >= 0: t[dot + 1 .. ^1] else: "")
  var digits = intPart & frac
  var pointPos = intPart.len + e   ## digits before the decimal point
  var lead = 0
  while lead < digits.len - 1 and digits[lead] == '0': inc lead
  digits = digits[lead .. ^1]
  pointPos -= lead
  while digits.len > 1 and digits[^1] == '0': digits.setLen(digits.len - 1)
  if digits == "0": pointPos = 1
  result.digits = digits
  result.exp = pointPos - 1

proc nsFixedFromDigits(digits: string; exp: int): string =
  ## Positional notation for `0.digits * 10^(exp+1)`.
  if exp < 0:
    result = "0." & repeat('0', -exp - 1) & digits
  elif exp + 1 >= digits.len:
    result = digits & repeat('0', exp + 1 - digits.len)
  else:
    result = digits[0 .. exp] & "." & digits[exp + 1 .. ^1]

proc nsGeneral(x: float; precision: int; upper = true): string =
  ## `G`: the shortest round-trip form without a precision (.NET Core's default for
  ## `double.ToString()`), otherwise `precision` significant digits; scientific when
  ## the exponent is below -5 or at least the precision (15 for the shortest form).
  if x.isNaN: return "NaN"
  if x == Inf: return "∞"
  if x == NegInf: return "-∞"
  let s = (if precision <= 0: $x else: formatFloat(x, ffScientific, precision - 1))
  var (neg, digits, e) = nsSplitSci(s)
  let limit = (if precision <= 0: 15 else: precision)
  result = (if neg and digits != "0": "-" else: "")
  if e >= -5 and e < limit:
    result.add nsFixedFromDigits(digits, e)
  else:
    result.add digits[0]
    if digits.len > 1: result.add "." & digits[1 .. ^1]
    result.add nsExponent(e, 2, upper)

proc nsFixed(x: float; decimals: int): string =
  if x.isNaN: return "NaN"
  if x == Inf: return "∞"
  if x == NegInf: return "-∞"
  result = formatFloat(x, ffDecimal, decimals)
  ## Nim keeps the point at precision 0 (`4.`); .NET does not.
  if decimals <= 0 and result.endsWith('.'): result.setLen(result.len - 1)
  ## C's printf keeps the sign of a value that rounds to zero; .NET Core does too
  ## (`-0.00`), so nothing is stripped.

proc nsFixedInt(x: string; decimals: int): string =
  ## An integer rendered with `decimals` zeros after the point, exactly.
  result = x
  if decimals > 0: result.add "." & repeat('0', decimals)

proc nsGroupFixed(s: string): string =
  ## Thousands separators on the integer part of a fixed-point string.
  var t = s
  var neg = false
  if t.len > 0 and t[0] == '-':
    neg = true
    t = t[1 .. ^1]
  let dot = t.find('.')
  let ip = (if dot >= 0: t[0 ..< dot] else: t)
  let rest = (if dot >= 0: t[dot .. ^1] else: "")
  result = (if neg: "-" else: "") & nsGroup(ip) & rest

proc nsScientific(x: float; decimals: int; upper: bool): string =
  if x.isNaN: return "NaN"
  let s = formatFloat(x, ffScientific, decimals)
  let ei = s.find({'e', 'E'})
  let mant = s[0 ..< ei]
  let e = parseInt(s[ei + 1 .. ^1])
  result = mant & nsExponent(e, 3, upper)

type NsDec = object
  ## A number's decimal digits, `point` of them before the decimal point (which may
  ## lie before or beyond them), and its sign.
  digits: string
  point: int
  neg: bool

proc nsDecOf(x: float): NsDec =
  ## The shortest digits that read back as `x`, as .NET formats from.
  result.neg = x < 0 or (x == 0 and 1.0 / x < 0)
  var s = $abs(x)
  var exp = 0
  let e = s.find({'e', 'E'})
  if e >= 0:
    exp = parseInt(s[e + 1 .. ^1])
    s.setLen(e)
  let dot = s.find('.')
  var ip = (if dot >= 0: s[0 ..< dot] else: s)
  var fp = (if dot >= 0: s[dot + 1 .. ^1] else: "")
  result.digits = ip & fp
  result.point = ip.len + exp
  var lead = 0
  while lead < result.digits.len - 1 and result.digits[lead] == '0': inc lead
  result.digits = result.digits[lead .. ^1]
  result.point -= lead
  while result.digits.len > 0 and result.digits[^1] == '0': result.digits.setLen(result.digits.len - 1)
  if result.digits.len == 0: result.point = 0

proc nsDecOf[T: SomeInteger](x: T): NsDec =
  result.neg = x < T(0)
  when T is SomeUnsignedInt: result.digits = $x
  else: result.digits = (if x < T(0): ($x)[1 .. ^1] else: $x)
  result.point = result.digits.len
  while result.digits.len > 0 and result.digits[^1] == '0': result.digits.setLen(result.digits.len - 1)
  if result.digits.len == 0: result.point = 0

proc nsRoundTo(d: var NsDec; frac: int) =
  ## Keeps `frac` decimals, rounding half away from zero, as a custom format does.
  let keep = d.point + frac
  if keep >= d.digits.len: return
  if keep < 0:
    d.digits = ""
    d.point = 0
    return
  let up = d.digits[keep] >= '5'
  d.digits.setLen(keep)
  if up:
    var i = keep - 1
    while i >= 0 and d.digits[i] == '9':
      d.digits[i] = '0'
      dec i
    if i < 0:
      d.digits = "1" & d.digits
      inc d.point
    else: d.digits[i] = char(ord(d.digits[i]) + 1)
  while d.digits.len > 0 and d.digits[^1] == '0': d.digits.setLen(d.digits.len - 1)
  if d.digits.len == 0: d.point = 0

proc nsSections(spec: string): seq[string] =
  ## `pos;neg;zero`, a `;` in quotes or after `\` not splitting.
  result = @[""]
  var i = 0
  while i < spec.len:
    let c = spec[i]
    if c in {'\'', '"'}:
      let close = spec.find(c, i + 1)
      let j = (if close < 0: spec.len - 1 else: close)
      result[^1].add spec[i .. j]
      i = j + 1
      continue
    if c == '\\' and i + 1 < spec.len:
      result[^1].add spec[i .. i + 1]
      i += 2
      continue
    if c == ';': result.add ""
    else: result[^1].add c
    inc i

type NsLayout = object
  nInt, minInt, nFrac, minFrac, scale: int
  grouping, hasPlaceholder: bool

proc nsLayoutOf(sec: string): NsLayout =
  ## What a section's placeholders ask for: the integer and fraction digits, the
  ## grouping, and the scaling by `,` before the point, `%` and `‰`.
  var inFrac = false
  var firstZero = -1
  var i = 0
  var pendingCommas = 0
  while i < sec.len:
    let c = sec[i]
    if c in {'\'', '"'}:
      let close = sec.find(c, i + 1)
      i = (if close < 0: sec.len else: close + 1)
      continue
    if c == '\\':
      i += 2
      continue
    if c in {'0', '#'}:
      result.hasPlaceholder = true
      if inFrac:
        inc result.nFrac
        if c == '0': result.minFrac = result.nFrac
      else:
        if pendingCommas > 0 and result.nInt > 0: result.grouping = true
        pendingCommas = 0
        if c == '0' and firstZero < 0: firstZero = result.nInt
        inc result.nInt
    elif c == ',' and not inFrac: inc pendingCommas
    elif c == '.' and not inFrac:
      inFrac = true
      result.scale -= 3 * pendingCommas
      pendingCommas = 0
    elif c == '%': result.scale += 2
    elif c == "\u2030"[0] and sec.continuesWith("\u2030", i):
      result.scale += 3
      i += "\u2030".len
      continue
    inc i
  if not inFrac: result.scale -= 3 * pendingCommas
  result.minInt = (if firstZero < 0: 0 else: result.nInt - firstZero)

proc nsEmit(sec: string; lay: NsLayout; d: NsDec): string =
  ## The section with its placeholders filled: integer digits right-aligned to the
  ## integer placeholders (the first takes any extra), fraction digits in order.
  var ip = (if d.point > 0:
              (if d.point <= d.digits.len: d.digits[0 ..< d.point]
               else: d.digits & repeat('0', d.point - d.digits.len))
            else: "")
  var fp = (if d.point >= 0: (if d.point < d.digits.len: d.digits[d.point .. ^1] else: "")
            else: repeat('0', -d.point) & d.digits)
  while fp.len < lay.minFrac: fp.add '0'
  if ip.len < lay.minInt: ip = repeat('0', lay.minInt - ip.len) & ip
  result = ""
  var intSeen = 0
  var fracSeen = 0
  var inFrac = false
  let extra = ip.len - lay.nInt
  proc addInt(r: var string; p: int) =
    r.add ip[p]
    if lay.grouping and p < ip.len - 1 and (ip.len - 1 - p) mod 3 == 0: r.add ','
  var i = 0
  while i < sec.len:
    let c = sec[i]
    if c in {'\'', '"'}:
      let close = sec.find(c, i + 1)
      let j = (if close < 0: sec.len else: close)
      result.add sec[i + 1 ..< j]
      i = j + 1
      continue
    if c == '\\':
      if i + 1 < sec.len: result.add sec[i + 1]
      i += 2
      continue
    if c in {'0', '#'}:
      if inFrac:
        if fracSeen < fp.len: result.add fp[fracSeen]
        inc fracSeen
      else:
        if intSeen == 0:
          for p in 0 ..< max(extra + 1, 0):
            if p < ip.len: result.addInt(p)
        else:
          let p = extra + intSeen
          if p >= 0 and p < ip.len: result.addInt(p)
        inc intSeen
    elif c == '.' and not inFrac:
      inFrac = true
      if fp.len > 0: result.add '.'
    elif c == ',' and not inFrac: discard
    else: result.add c
    inc i

proc nsCustom(d0: NsDec; spec: string): string =
  ## A custom numeric format (.NET's): `0` a digit always shown, `#` one shown when
  ## significant, `.` the point, `,` grouping between placeholders and a division by
  ## 1000 before the point, `%` and `‰` scaling, quoted and `\`-escaped literals,
  ## and up to three sections, for positive, negative and zero values.
  let secs = nsSections(spec)
  let isZero = d0.digits.len == 0
  var idx = 0
  if secs.len >= 3 and isZero and secs[2].len > 0: idx = 2
  elif d0.neg and secs.len >= 2 and secs[1].len > 0: idx = 1
  var lay = nsLayoutOf(secs[idx])
  var d = d0
  d.point += lay.scale
  nsRoundTo(d, lay.nFrac)
  if d.digits.len == 0 and not isZero:
    ## Rounded to zero: the zero section, or the first one, keeping the sign.
    if secs.len >= 3 and secs[2].len > 0: idx = 2
    elif idx == 1: idx = 0
    if idx != 1:
      lay = nsLayoutOf(secs[idx])
      d = d0
      d.point += lay.scale
      nsRoundTo(d, lay.nFrac)
  result = nsEmit(secs[idx], lay, d)
  if d0.neg and idx == 0: result = "-" & result

proc nsHex[T: SomeInteger](x: T; digits: int; upper: bool): string =
  ## `X`: two's complement of the value's own width, as .NET does for a negative one.
  let u = cast[uint64](int64(x)) and
          (if sizeof(T) >= 8: high(uint64) else: (1'u64 shl (8 * sizeof(T))) - 1)
  result = toHex(u).strip(leading = true, trailing = false, chars = {'0'})
  if result.len == 0: result = "0"
  if not upper: result = result.toLowerAscii
  if result.len < digits: result = repeat('0', digits - result.len) & result

proc nsIsStandard(spec: string): bool =
  ## A letter followed only by digits is a standard format; anything else is custom.
  if spec.len == 0 or spec[0] notin Letters: return false
  for i in 1 ..< spec.len:
    if spec[i] notin Digits: return false
  true

proc nsStandardLetter(spec: string; valid: set[char]) =
  ## A standard format must be one the type has.
  if spec[0] notin valid:
    raise newException(ValueError, "Format specifier was invalid.")

proc nsBinary[T: SomeInteger](x: T; digits: int): string =
  ## `B`: the bits of the value's own width, as .NET does for a negative one.
  var u = cast[uint64](int64(x)) and
          (if sizeof(T) >= 8: high(uint64) else: (1'u64 shl (8 * sizeof(T))) - 1)
  result = ""
  while u != 0:
    result.insert($char(ord('0') + int(u and 1)), 0)
    u = u shr 1
  if result.len == 0: result = "0"
  if result.len < digits: result = repeat('0', digits - result.len) & result

proc nsFormatNumber*[T: SomeInteger](x: T; spec: string): string =
  if spec.len == 0: return $x
  if not nsIsStandard(spec): return nsCustom(nsDecOf(x), spec)
  nsStandardLetter(spec, {'B', 'b', 'C', 'c', 'D', 'd', 'E', 'e', 'F', 'f', 'G', 'g',
                          'N', 'n', 'P', 'p', 'R', 'r', 'X', 'x'})
  let k = spec[0]
  let upper = k in {'A'..'Z'}
  case toUpperAscii(k)
  of 'D':
    let p = nsPrecision(spec, 0)
    var a = $abs(BiggestInt(x))
    when T is SomeUnsignedInt: a = $x
    if a.len < p: a = repeat('0', p - a.len) & a
    result = (if BiggestInt(x) < 0 and T isnot SomeUnsignedInt: "-" else: "") & a
  of 'X': result = nsHex(x, nsPrecision(spec, 0), upper)
  of 'B': result = nsBinary(x, nsPrecision(spec, 0))
  of 'F': result = nsFixedInt($x, nsPrecision(spec, 2))
  of 'N': result = nsGroupFixed(nsFixedInt($x, nsPrecision(spec, 2)))
  of 'E': result = nsScientific(float(x), nsPrecision(spec, 6), upper)
  of 'G', 'R':
    let p = nsPrecision(spec, 0)
    result = (if p == 0: $x else: nsGeneral(float(x), p, upper))
  of 'P':
    result = nsGroupFixed(nsFixedInt($(BiggestInt(x) * 100), nsPrecision(spec, 2))) & "%"
  of 'C':
    let body = nsGroupFixed(nsFixedInt($abs(BiggestInt(x)), nsPrecision(spec, 2)))
    result = (if BiggestInt(x) < 0: "-$" else: "$") & body
  else: result = nsCustom(nsDecOf(x), spec)

proc nsFormatNumber*[T: SomeFloat](x: T; spec: string): string =
  let v = float(x)
  if spec.len == 0: return $x
  if not nsIsStandard(spec):
    if v != v: return "NaN"
    if v == Inf: return "∞"
    if v == NegInf: return "-∞"
    return nsCustom(nsDecOf(v), spec)
  nsStandardLetter(spec, {'C', 'c', 'E', 'e', 'F', 'f', 'G', 'g', 'N', 'n', 'P', 'p',
                          'R', 'r'})
  let k = spec[0]
  let upper = k in {'A'..'Z'}
  case toUpperAscii(k)
  of 'F': result = nsFixed(v, nsPrecision(spec, 2))
  of 'N': result = nsGroupFixed(nsFixed(v, nsPrecision(spec, 2)))
  of 'E': result = nsScientific(v, nsPrecision(spec, 6), upper)
  of 'G': result = nsGeneral(v, nsPrecision(spec, 0), upper)
  of 'R': result = nsGeneral(v, 0, upper)
  of 'P': result = nsGroupFixed(nsFixed(v * 100, nsPrecision(spec, 2))) & "%"
  of 'C':
    let body = nsGroupFixed(nsFixed(abs(v), nsPrecision(spec, 2)))
    result = (if v < 0: "-$" else: "$") & body
  else: result = nsCustom(nsDecOf(v), spec)

proc nsAlign*(s: string; width: int): string =
  ## `{x,8}` right-aligns in eight columns and `{x,-8}` left-aligns.
  if width > 0 and s.len < width: repeat(' ', width - s.len) & s
  elif width < 0 and s.len < -width: s & repeat(' ', -width - s.len)
  else: s

template nsFmt*(x: untyped; spec: string): string =
  ## One hole: a number takes its format spec, anything else is stringified.
  ## A template, so a user's `$` for the hole's type is seen where it is used.
  block:
    let nsV = x
    when nsV is SomeNumber:
      nsFormatNumber(nsV, spec)
    elif nsV is Option:
      ## A `T?` formats its value, and a null formats as nothing.
      when typeof(nsV.get) is SomeNumber:
        if nsV.isSome: nsFormatNumber(nsV.get, spec) else: ""
      else:
        $nsV
    else:
      $nsV
