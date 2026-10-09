# N# frontend - C#'s numeric conversions
#
# The language rules C# applies to its built-in numeric types, which Nim does not:
# binary numeric promotion (`byte + byte` is an `int`, `int * double` a `double`)
# and the implicit numeric conversions (`int` to `long` or `double`, `char` to
# `int`). `sema.nim` uses these to record the conversion an operand or a value
# needs, and `desugar.nim` spells it as a Nim conversion. Names are C#'s keywords.

const
  NsIntegralNames* = ["sbyte", "byte", "short", "ushort", "int", "uint", "long",
                      "ulong", "nint", "nuint", "char"]
  NsFloatingNames* = ["float", "double"]

  NsNimNumericNames: array[14, (string, string)] = [
    ("int8", "sbyte"), ("uint8", "byte"), ("int16", "short"), ("uint16", "ushort"),
    ("int32", "int"), ("uint32", "uint"), ("int64", "long"), ("uint64", "ulong"),
    ("int", "nint"), ("uint", "nuint"), ("float32", "float"), ("float64", "double"),
    ("float", "double"), ("char", "char")]

proc isNumericName*(s: string): bool =
  s in NsIntegralNames or s in NsFloatingNames

proc numericOfSpelling*(s: string): string =
  ## A C# numeric keyword for a C# or Nim spelling, or "".
  if isNumericName(s): return s
  for (nim, cs) in NsNimNumericNames:
    if nim == s: return cs
  ""

proc isFloating*(s: string): bool = s in NsFloatingNames

proc isUnsigned(s: string): bool = s in ["byte", "ushort", "uint", "ulong", "nuint", "char"]

proc implicitlyConvertible*(src, dst: string): bool =
  ## C#'s implicit numeric conversions (ECMA-334 10.2.3), identity included.
  if src == dst: return true
  case src
  of "sbyte": dst in ["short", "int", "long", "nint", "float", "double"]
  of "byte": dst in ["short", "ushort", "int", "uint", "long", "ulong", "nint", "nuint",
                     "float", "double"]
  of "short": dst in ["int", "long", "nint", "float", "double"]
  of "ushort": dst in ["int", "uint", "long", "ulong", "nint", "nuint", "float", "double"]
  of "int": dst in ["long", "nint", "float", "double"]
  of "uint": dst in ["long", "ulong", "nuint", "float", "double"]
  of "long", "nint": dst in ["float", "double"] or (src == "nint" and dst == "long")
  of "ulong", "nuint": dst in ["float", "double"] or (src == "nuint" and dst == "ulong")
  of "char": dst in ["ushort", "int", "uint", "long", "ulong", "nint", "nuint", "float",
                     "double"]
  of "float": dst == "double"
  else: false

proc unaryPromoted*(s: string): string =
  ## Unary numeric promotion: the small integral types widen to `int`.
  if s in ["sbyte", "byte", "short", "ushort", "char"]: "int" else: s

proc promoted*(a, b: string): string =
  ## Binary numeric promotion (ECMA-334 12.4.7.3), or "" when C# rejects the pair
  ## (`long` with `ulong`). Both operands are numeric names.
  if a == "double" or b == "double": return "double"
  if a == "float" or b == "float": return "float"
  if a == "ulong" or b == "ulong":
    let other = (if a == "ulong": b else: a)
    if other in ["sbyte", "short", "int", "long", "nint"]: return ""
    return "ulong"
  if a == "long" or b == "long": return "long"
  if a == "nint" or b == "nint": return "nint"
  if a == "nuint" or b == "nuint": return "nuint"
  if a == "uint" or b == "uint":
    let other = (if a == "uint": b else: a)
    if other in ["sbyte", "short", "int"]: return "long"
    return "uint"
  "int"

proc fitsLiteral*(v: BiggestInt; dst: string): bool =
  ## Whether a constant integer may be implicitly converted to `dst` (C# permits a
  ## constant expression whose value is in range).
  case dst
  of "sbyte": v >= -128 and v <= 127
  of "byte": v >= 0 and v <= 255
  of "short": v >= -32768 and v <= 32767
  of "ushort": v >= 0 and v <= 65535
  of "int": v >= low(int32) and v <= high(int32)
  of "uint": v >= 0 and v <= 0xFFFF_FFFF'i64
  of "long", "nint": true
  of "ulong", "nuint": v >= 0
  of "float", "double": true
  else: false

proc isSignedName*(s: string): bool = not isUnsigned(s) and not isFloating(s)
