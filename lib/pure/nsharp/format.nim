# N# intrinsics: C#'s format strings
#
# What a hole of an interpolated string does with `{x,align:spec}`, and what
# `String.Format` does with `{0,align:spec}`. The specs are .NET's standard numeric
# ones (`C D E F G N P R X`, each with an optional precision) and its custom numeric
# ones (`0`, `#`, `.`, `,`, `%`, literals), rendered the way .NET's en-US culture
# renders them. A value that is not a number ignores its spec, as `object.ToString`
# does in .NET for a type that does not implement `IFormattable`.

import std/[strutils, math]

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

proc nsCustom(x: float; spec: string): string =
  ## A custom numeric format: `0` is a digit that is always shown, `#` one shown when
  ## significant, `.` the decimal point, `,` in the integer part turns grouping on, and
  ## `%` multiplies by a hundred. Anything else is copied as written.
  var v = x
  if '%' in spec: v = v * 100
  var prefix, suffix, body = ""
  var i = 0
  while i < spec.len and spec[i] notin {'0', '#', '.', ','}:
    prefix.add spec[i]
    inc i
  while i < spec.len and spec[i] in {'0', '#', '.', ','}:
    body.add spec[i]
    inc i
  suffix = spec[i .. ^1]
  let dot = body.find('.')
  let ipat = (if dot >= 0: body[0 ..< dot] else: body)
  let fpat = (if dot >= 0: body[dot + 1 .. ^1] else: "")
  let grouping = ',' in ipat
  var minInt = 0
  for c in ipat:
    if c == '0': inc minInt
  var minFrac, maxFrac = 0
  for c in fpat:
    if c == '0':
      inc minFrac
      inc maxFrac
    elif c == '#': inc maxFrac
  var s = formatFloat(abs(v), ffDecimal, maxFrac)
  let d = s.find('.')
  var ip = (if d >= 0: s[0 ..< d] else: s)
  var fp = (if d >= 0: s[d + 1 .. ^1] else: "")
  while fp.len > minFrac and fp[^1] == '0': fp.setLen(fp.len - 1)
  while ip.len > 1 and ip[0] == '0': ip = ip[1 .. ^1]
  if ip == "0" and minInt == 0: ip = ""
  if ip.len < minInt: ip = repeat('0', minInt - ip.len) & ip
  if grouping: ip = nsGroup(ip)
  result = ip
  if fp.len > 0: result.add "." & fp
  if result.len == 0: result = "0"
  let isZero = result.allCharsInSet({'0', '.', ','})
  if v < 0 and not isZero: result = "-" & result
  result = prefix & result & suffix

proc nsHex[T: SomeInteger](x: T; digits: int; upper: bool): string =
  ## `X`: two's complement of the value's own width, as .NET does for a negative one.
  let u = cast[uint64](int64(x)) and
          (if sizeof(T) >= 8: high(uint64) else: (1'u64 shl (8 * sizeof(T))) - 1)
  result = toHex(u).strip(leading = true, trailing = false, chars = {'0'})
  if result.len == 0: result = "0"
  if not upper: result = result.toLowerAscii
  if result.len < digits: result = repeat('0', digits - result.len) & result

proc nsFormatNumber*[T: SomeInteger](x: T; spec: string): string =
  if spec.len == 0: return $x
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
  else: result = nsCustom(float(x), spec)

proc nsFormatNumber*[T: SomeFloat](x: T; spec: string): string =
  let v = float(x)
  if spec.len == 0: return $x
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
  of 'D', 'X':
    raise newException(ValueError, "Format specifier was invalid.")
  else: result = nsCustom(v, spec)

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
    else:
      $nsV
