# N# standard library: the System namespace. Imported by `using System;`.
#
# Members are ordinary Nim procs: an instance member is reached by Nim's
# dot-call, a static one through the qualifier the frontend drops.

import std/[syncio, strutils, math, hashes, algorithm]
# `System.Collections.Generic` builds on this namespace, and this one names its
# interfaces (`Array.Sort` takes an `IComparer<T>`), as .NET's namespaces may.
import System/Collections/Generic {.cyclic.}
from ../nsharp/intrinsics import NsBoxed, nsBoxEquals, nsBoxHash, Equals, GetHashCode, NsArray, nsArrayOf, len,
  items, `[]`, `[]=`

# `{.nsStatic: "T".}` and `{.nsInterface.}`: see `nsharp/pragmas`.
from ../nsharp/pragmas import nsStatic, nsInterface

{.push discardable.}

type
  # --- System.Exception -------------------------------------------------------
  #
  # The .NET exception types: Nim raises a matching defect under this name, so the
  # alias is what `catch` catches, and `Exception` is Nim's exception root.
  NullReferenceException* = NilAccessDefect
  OverflowException* = OverflowDefect
  IndexOutOfRangeException* = IndexDefect
  DivideByZeroException* = DivByZeroDefect
  InvalidCastException* = ObjectConversionDefect
  ArgumentOutOfRangeException* = RangeDefect
  KeyNotFoundException* = KeyError
  FormatException* = ValueError

  SystemException* = object of CatchableError
  ApplicationException* = object of SystemException
  ArgumentException* = object of SystemException
  ArgumentNullException* = object of ArgumentException
  InvalidOperationException* = object of SystemException
  NotSupportedException* = object of SystemException
  NotImplementedException* = object of SystemException
  ObjectDisposedException* = object of InvalidOperationException

  # --- System delegates the collections take -------------------------------------
  #
  # `Predicate<T>` and friends are ordinary generic delegates, so they are proc
  # types here, as a user's own `delegate bool P<T>(T x)` would be.
  Predicate*[T] = proc (x: T): bool
  Comparison*[T] = proc (x, y: T): int32
  Converter*[T, U] = proc (x: T): U
  Action*[T] = proc (x: T)

  # `Func<...>` and `Action<...>` are one name per arity in C#; Nim names a type
  # once, so each arity is declared with its count, and the frontend picks the
  # declaration whose suffix is the number of type arguments written.
  Action0* = proc ()
  EventArgs* = ref object of RootObj
    ## The base of an event's data; `EventArgs.Empty` carries none.
  EventHandler* = proc (sender: RootRef, e: EventArgs)
    ## The usual event delegate: who raised it, and with what.
  EventHandler1*[T] = proc (sender: RootRef, e: T)
    ## `EventHandler<T>`, whose data is a `T`.
  Action2*[T1, T2] = proc (a: T1, b: T2)
  Action3*[T1, T2, T3] = proc (a: T1, b: T2, c: T3)
  Action4*[T1, T2, T3, T4] = proc (a: T1, b: T2, c: T3, d: T4)
  Func1*[R] = proc (): R
  Func2*[T, R] = proc (a: T): R
  Func3*[T1, T2, R] = proc (a: T1, b: T2): R
  Func4*[T1, T2, T3, R] = proc (a: T1, b: T2, c: T3): R
  Func5*[T1, T2, T3, T4, R] = proc (a: T1, b: T2, c: T3, d: T4): R

  IComparable*[T] {.nsInterface.} = object
    ## `int CompareTo(T other)`, which `List<T>.Sort()` and friends call.
  IEquatable*[T] {.nsInterface.} = object
    ## `bool Equals(T other)`.
  IDisposable* {.nsInterface.} = object
    ## `void Dispose()`, which the `using` statement calls.

  StringComparer* = ref object of RootObj
    ## C#'s `StringComparer`: `StringComparer.Ordinal` and `.OrdinalIgnoreCase`.
    nsIgnoreCase: bool

  Attribute* = ref object of RootObj
    ## The base of every attribute class. N# has no reflection, so an attribute is
    ## read by the compiler alone: `[Flags]` and `[Obsolete]` change what it does.
  FlagsAttribute* = ref object of Attribute
    ## `[Flags]`: an enum's value prints as the names of its set bits.
  ObsoleteAttribute* = ref object of Attribute
    ## `[Obsolete("why")]`: a use of the member warns (CS0618), or fails when the
    ## second argument is `true` (CS0619).
  AttributeUsageAttribute* = ref object of Attribute
    ## `[AttributeUsage(...)]`: where an attribute may be written; not checked.
  SerializableAttribute* = ref object of Attribute
    ## `[Serializable]`: no effect without a serializer.
  STAThreadAttribute* = ref object of Attribute
    ## `[STAThread]`: no effect; N# programs have one thread.
  Math* = object
    ## `System.Math`: its members are static (`{.nsStatic: "Math".}` below).
  Console* = object
    ## Declared so the frontend resolves the name as a type; nothing is ever an
    ## instance of it.

# --- System.Exception -------------------------------------------------------
#
# `e.Message` reaches a proc on the exception root, and is generic because an N#
# exception is a value object but is raised as a `ref`, which does not convert to
# its base in an argument position.

proc Message*[T: ref Exception](e: T): string = e.msg

# --- System.Int32, Double, Char, String -------------------------------------
#
# C# reads these as `static` fields of a built-in type. Nim reaches a type member
# by dot-call on the type, so the values live here rather than in the compiler.

template MaxValue*[T: SomeInteger](t: typedesc[T]): T = high(T)
template MinValue*[T: SomeInteger](t: typedesc[T]): T = low(T)
template MaxValue*[T: SomeFloat](t: typedesc[T]): T = high(T)
template MinValue*[T: SomeFloat](t: typedesc[T]): T = low(T)
template MaxValue*(t: typedesc[char]): char = high(char)
template MinValue*(t: typedesc[char]): char = low(char)
template Empty*(t: typedesc[string]): string = ""
# .NET defines `Epsilon` as the smallest positive subnormal, which Nim does not
# name, so these carry the runtime's own literals.
template Epsilon*(t: typedesc[float32]): float32 = 1.4012984643248171e-45
template Epsilon*(t: typedesc[float64]): float64 = 4.9406564584124654e-324
template NaN*(t: typedesc[float32]): float32 = float32(system.NaN)
template NaN*(t: typedesc[float64]): float64 = system.NaN
template PositiveInfinity*[T: SomeFloat](t: typedesc[T]): T = T(system.Inf)
template NegativeInfinity*[T: SomeFloat](t: typedesc[T]): T = T(system.NegInf)

# `IComparable<T>.CompareTo` on the built-in types.
proc CompareTo*[T: SomeInteger](a, b: T): int32 = int32(cmp(a, b))
proc CompareTo*[T: SomeFloat](a, b: T): int32 = int32(cmp(a, b))
proc CompareTo*(a, b: char): int32 = int32(cmp(a, b))
proc CompareTo*(a, b: bool): int32 = int32(cmp(a, b))

# `double.IsNaN(x)` and the rest of the floating-point tests.
proc IsNaN*[T: SomeFloat](t: typedesc[T]; x: T): bool = x != x
proc IsInfinity*[T: SomeFloat](t: typedesc[T]; x: T): bool = x == T(Inf) or x == T(NegInf)
proc IsPositiveInfinity*[T: SomeFloat](t: typedesc[T]; x: T): bool = x == T(Inf)
proc IsNegativeInfinity*[T: SomeFloat](t: typedesc[T]; x: T): bool = x == T(NegInf)
proc IsFinite*[T: SomeFloat](t: typedesc[T]; x: T): bool =
  x == x and x != T(Inf) and x != T(NegInf)

# --- Parse / TryParse on the built-in types -----------------------------------
#
# .NET's rules under the en-US culture, N#'s (as `ToString` follows it). An integer
# is surrounding white space,
# an optional sign and digits (`NumberStyles.Integer`); anything else is a
# `FormatException`, a value the type cannot hold an `OverflowException` (the format
# is judged first, over the whole string). A floating-point number also takes a
# decimal point, an exponent, `,` group separators after the integral part's first
# digit and the symbols `NaN` and `∞`, signed or not (`NumberStyles.Float |
# AllowThousands`); one too
# large becomes an infinity, as since .NET Core 3.0. `TryParse` answers whether it
# could, leaving the default value when not.

type NsParsed = enum npOk, npFormat, npOverflow

proc nsNetName(T: typedesc): string =
  ## How .NET's overflow message names the type.
  when T is int8: "a signed byte"
  elif T is uint8: "an unsigned byte"
  elif T is int16: "an Int16"
  elif T is uint16: "a UInt16"
  elif T is int32: "an Int32"
  elif T is uint32: "a UInt32"
  elif T is int64: "an Int64"
  elif T is uint64: "a UInt64"
  elif T is float32: "a Single"
  else: "a Double"

proc nsTrimmed(s: string): (int, int) =
  var i = 0
  var e = s.len
  while i < e and s[i] in Whitespace: inc i
  while e > i and s[e - 1] in Whitespace: dec e
  (i, e)

proc nsParseInteger(s: string; posLimit, negLimit: uint64;
                    v: var uint64; neg: var bool): NsParsed =
  ## The magnitude and sign of an integer; out of range when the magnitude passes
  ## the limit for its sign.
  var (i, e) = nsTrimmed(s)
  neg = false
  v = 0
  if i < e and s[i] in {'+', '-'}:
    neg = s[i] == '-'
    inc i
  if i >= e: return npFormat
  var over = false
  for k in i ..< e:
    let c = s[k]
    if c notin {'0'..'9'}: return npFormat
    let d = uint64(ord(c) - ord('0'))
    if not over:
      if v > (high(uint64) - d) div 10: over = true
      else: v = v * 10 + d
  if over or v > (if neg: negLimit else: posLimit): return npOverflow
  npOk

proc nsParseInt[T: SomeInteger](s: string; r: var T): NsParsed =
  var v: uint64
  var neg: bool
  when T is SomeSignedInt:
    result = nsParseInteger(s, uint64(high(T)), uint64(high(T)) + 1, v, neg)
    if result == npOk: r = (if neg: T(cast[int64](0'u64 - v)) else: T(v))
  else:
    result = nsParseInteger(s, uint64(high(T)), 0, v, neg)
    if result == npOk: r = T(v)

proc nsParseFloat(s: string; r: var float64): NsParsed =
  let (i0, e) = nsTrimmed(s)
  var i = i0
  var neg = false
  if i < e and s[i] in {'+', '-'}:
    neg = s[i] == '-'
    inc i
  let rest = s.substr(i, e - 1).toLowerAscii
  if rest == "∞":
    r = (if neg: NegInf else: Inf)
    return npOk
  if rest == "nan":
    r = system.NaN
    return npOk
  var clean = (if neg: "-" else: "")
  var digits = 0
  while i < e and (s[i] in {'0'..'9'} or (s[i] == ',' and digits > 0)):
    if s[i] != ',':
      clean.add s[i]
      inc digits
    inc i
  if i < e and s[i] == '.':
    clean.add '.'
    inc i
    while i < e and s[i] in {'0'..'9'}:
      clean.add s[i]
      inc digits
      inc i
  if digits == 0: return npFormat
  if i < e and s[i] in {'e', 'E'}:
    clean.add 'e'
    inc i
    if i < e and s[i] in {'+', '-'}:
      clean.add s[i]
      inc i
    if i >= e or s[i] notin {'0'..'9'}: return npFormat
    while i < e and s[i] in {'0'..'9'}:
      clean.add s[i]
      inc i
  if i != e: return npFormat
  r = parseFloat(clean)
  npOk

proc nsParseFail(s, T: string; how: NsParsed) {.noinline, noreturn.} =
  if how == npFormat:
    raise newException(FormatException,
                       "The input string '" & s & "' was not in a correct format.")
  raise newException(OverflowException,
                     "Value was either too large or too small for " & T & ".")

proc Parse*[T: SomeInteger](t: typedesc[T]; s: string): T =
  let how = nsParseInt(s, result)
  if how != npOk: nsParseFail(s, nsNetName(T), how)

proc TryParse*[T: SomeInteger](t: typedesc[T]; s: string; value: var T): bool =
  value = 0
  var r: T
  result = nsParseInt(s, r) == npOk
  if result: value = r

proc Parse*[T: SomeFloat](t: typedesc[T]; s: string): T =
  var r: float64
  let how = nsParseFloat(s, r)
  if how != npOk: nsParseFail(s, nsNetName(T), how)
  T(r)

proc TryParse*[T: SomeFloat](t: typedesc[T]; s: string; value: var T): bool =
  value = 0
  var r: float64
  result = nsParseFloat(s, r) == npOk
  if result: value = T(r)

proc nsParseBool(s: string; r: var bool): bool =
  ## `True` or `False` in any case, white space (and NULs) around it allowed.
  var i = 0
  var e = s.len
  while i < e and s[i] in Whitespace + {'\0'}: inc i
  while e > i and s[e - 1] in Whitespace + {'\0'}: dec e
  let w = s.substr(i, e - 1).toLowerAscii
  if w == "true": r = true
  elif w == "false": r = false
  else: return false
  true

proc Parse*(t: typedesc[bool]; s: string): bool =
  if not nsParseBool(s, result):
    raise newException(FormatException,
                       "String '" & s & "' was not recognized as a valid Boolean.")

proc TryParse*(t: typedesc[bool]; s: string; value: var bool): bool =
  value = false
  nsParseBool(s, value)

proc Parse*(t: typedesc[char]; s: string): char =
  if s.len != 1: raise newException(FormatException, "String must be exactly one character long.")
  s[0]

proc TryParse*(t: typedesc[char]; s: string; value: var char): bool =
  value = '\0'
  if s.len != 1: return false
  value = s[0]
  true

# --- System.StringComparer ---------------------------------------------------
#
# Ordinal comparison is .NET's `CompareOrdinal`: the difference of the first
# characters that differ, else of the lengths. Ignoring case compares the
# upper-case forms.

proc Ordinal*(t: typedesc[StringComparer]): StringComparer =
  var store {.global.}: StringComparer
  if store.isNil: store = StringComparer()
  store
proc OrdinalIgnoreCase*(t: typedesc[StringComparer]): StringComparer =
  var store {.global.}: StringComparer
  if store.isNil: store = StringComparer(nsIgnoreCase: true)
  store
proc nsCompareOrdinal(a, b: string; ignoreCase: bool): int32 =
  for i in 0 ..< min(a.len, b.len):
    let x = (if ignoreCase: toUpperAscii(a[i]) else: a[i])
    let y = (if ignoreCase: toUpperAscii(b[i]) else: b[i])
    if x != y: return int32(ord(x) - ord(y))
  int32(a.len - b.len)
proc Compare*(c: StringComparer; a, b: string): int32 = nsCompareOrdinal(a, b, c.nsIgnoreCase)
proc CompareOrdinal*(a, b: string): int32 {.nsStatic: "String".} = nsCompareOrdinal(a, b, false)
proc Equals*(c: StringComparer; a, b: string): bool =
  if c.nsIgnoreCase: cmpIgnoreCase(a, b) == 0 else: a == b
proc GetHashCode*(c: StringComparer; s: string): int32 =
  let h = (if c.nsIgnoreCase: hash(toUpperAscii(s)) else: hash(s))
  cast[int32](h and 0x7FFF_FFFF)

# --- System.Object ----------------------------------------------------------
#
# `object` is `RootRef`. `ToString`, `Equals` and `GetHashCode` are in the
# intrinsics, where a dictionary's keys reach them.

proc ReferenceEquals*(a, b: RootRef): bool {.nsStatic: "object".} = a == b
proc HasFlag*[E](a, b: E): bool = (int64(a) and int64(b)) == int64(b)
  ## `System.Enum.HasFlag`: every bit of `b` is set in `a`. An enum is its
  ## underlying integer (see `nsEnum` in the intrinsics).
proc newRootRef*(): RootRef = RootRef()
proc initAttribute*(self: Attribute) = discard
proc initEventArgs*(self: EventArgs) = discard
  ## The base constructor a user `EventArgs` class's constructor runs.
proc newEventArgs*(): EventArgs = EventArgs()
proc Empty*(t: typedesc[EventArgs]): EventArgs = EventArgs()
  ## `EventArgs.Empty`.
  ## The base constructor a user attribute class's constructor runs.
  ## `new object()`: a fresh object with no members, such as a lock's target.

# --- System.String ----------------------------------------------------------

proc Length*(s: string): int32 = int32(s.len)
proc newstring*(c: char; count: int32): string = repeat(c, count)
  ## `new string(c, n)`: `c` repeated `n` times. Spelled as the lowering spells
  ## `new` + `string`; to Nim it is an overload of `newString`, told apart by arity.
proc ToString*(s: string): string = s
proc ToUpper*(s: string): string = s.toUpperAscii
proc ToLower*(s: string): string = s.toLowerAscii
proc Substring*(s: string; start: int32): string = s[int(start) .. ^1]
proc Substring*(s: string; start, length: int32): string =
  s[int(start) ..< int(start) + int(length)]
proc Contains*(s, value: string): bool = s.contains(value)
proc StartsWith*(s, value: string): bool = s.startsWith(value)
proc EndsWith*(s, value: string): bool = s.endsWith(value)
proc IndexOf*(s: string; value: char): int32 = int32(s.find(value))
proc IndexOf*(s, value: string): int32 = int32(s.find(value))
proc Trim*(s: string): string = s.strip
proc Replace*(s, oldValue, newValue: string): string =
  s.replace(oldValue, newValue)
proc Split*(s: string; separator: char): NsArray[string] = nsArrayOf(s.split(separator))
proc PadLeft*(s: string; totalWidth: int32): string = s.align(int(totalWidth))
proc PadRight*(s: string; totalWidth: int32): string = s.alignLeft(int(totalWidth))
proc CompareTo*(s, other: string): int32 = int32(cmp(s, other))
proc ToCharArray*(s: string): NsArray[char] =
  var cs = newSeq[char](s.len)
  for i, c in s: cs[i] = c
  nsArrayOf(cs)
proc Insert*(s: string; startIndex: int32; value: string): string =
  s[0 ..< int(startIndex)] & value & s[int(startIndex) .. ^1]
proc Remove*(s: string; startIndex: int32): string = s[0 ..< int(startIndex)]
proc Remove*(s: string; startIndex, count: int32): string =
  s[0 ..< int(startIndex)] & s[int(startIndex) + int(count) .. ^1]

# Static members; the frontend drops the `String.` qualifier.
proc IsNullOrEmpty*(s: string): bool {.nsStatic: "String".} = s.len == 0
proc IsNullOrWhiteSpace*(s: string): bool {.nsStatic: "String".} =
  s.len == 0 or s.allCharsInSet({' ', '\t', '\n', '\r', '\v', '\f'})
proc Concat*(a, b: string): string {.nsStatic: "String".} = a & b
proc Join*(separator: string; values: openArray[string]): string {.nsStatic: "String".} =
  values.join(separator)
proc Join*(separator: string; values: NsArray[string]): string {.nsStatic: "String".} =
  values.nsData.join(separator)
proc Compare*(a, b: string): int32 {.nsStatic: "String".} = int32(cmp(a, b))

# --- System.Array -----------------------------------------------------------
#
# A C# array is the intrinsics' `NsArray`; a `params` parameter is a Nim
# `varargs`, which the `openArray` overloads serve.

proc Length*[T](a: NsArray[T]): int32 {.inline.} = int32(a.len)
proc Clone*[T](a: NsArray[T]): NsArray[T] = nsArrayOf(a.nsData)
  ## A new array of the same elements.
proc Rank*[T](a: NsArray[T]): int32 = 1
  ## A `T[]` has one dimension; a `T[,]` is the intrinsics' `NsMdArray`.
proc GetLength*[T](a: NsArray[T]; dimension: int32): int32 =
  if dimension == 0: int32(a.len) else: 0
proc IndexOf*[T](a: NsArray[T]; value: T): int32 {.nsStatic: "Array".} =
  result = -1
  for i in 0 ..< a.len:
    if a.nsData[i] == value: return int32(i)

proc Length*[T](a: openArray[T]): int32 = int32(a.len)
proc Clone*[T](a: openArray[T]): NsArray[T] = nsArrayOf(@a)
proc Rank*[T](a: openArray[T]): int32 = 1
proc GetLength*[T](a: openArray[T]; dimension: int32): int32 =
  if dimension == 0: int32(a.len) else: 0
proc IndexOf*[T](a: openArray[T]; value: T): int32 {.nsStatic: "Array".} =
  result = -1
  for i in 0 ..< a.len:
    if a[i] == value: return int32(i)

# `Array.Sort`: in the elements' own order (`CompareTo`, else the natural one), by a
# `Comparison<T>`, or by an `IComparer<T>`, where a null one means the default.

proc nsArrayCompare[T](a, b: T): int =
  mixin CompareTo
  when compiles(a.CompareTo(b)): int(a.CompareTo(b))
  else: cmp(a, b)

proc Sort*[T](a: NsArray[T]) {.nsStatic: "Array".} =
  algorithm.sort(a.nsData, proc (x, y: T): int = nsArrayCompare(x, y))
proc Sort*[T](a: NsArray[T]; comparison: Comparison[T]) {.nsStatic: "Array".} =
  algorithm.sort(a.nsData, proc (x, y: T): int = int(comparison(x, y)))
proc Sort*[T](a: NsArray[T]; comparer: IComparer[T]) {.nsStatic: "Array".} =
  if comparer.nsObj == nil: Sort(a)
  else: algorithm.sort(a.nsData, proc (x, y: T): int = int(comparer.Compare(x, y)))

# --- System.Console ---------------------------------------------------------

# `$` is Nim's rendering, so a bool reads `true`; where C# spells differently the
# test records C#'s output in a `.csout` beside the `.out` (SPEC 7).

proc WriteLine*[T](x: T) {.nsStatic: "Console".} = echo x
proc WriteLine*() {.nsStatic: "Console".} = echo ""
proc Write*[T](x: T) {.nsStatic: "Console".} = stdout.write x
proc ReadLine*(): string = stdin.readLine

# --- System.Math ------------------------------------------------------------
#
# The integer overloads keep the argument's type, as C#'s do; `Abs` of the most
# negative value throws `OverflowException` in .NET and wraps here only if checks
# are off, which they are not inside the library. `Round` rounds a midpoint to the
# even neighbour, .NET's default.

# `int` and `double` overloads, as .NET declares them, so an untyped literal picks
# `int`; a generic one covers the other numeric types.
proc Abs*(x: int32): int32 {.nsStatic: "Math".} = abs(x)
proc Abs*(x: float): float {.nsStatic: "Math".} = abs(x)
proc Max*(a, b: int32): int32 {.nsStatic: "Math".} = max(a, b)
proc Max*(a, b: float): float {.nsStatic: "Math".} = max(a, b)
proc Min*(a, b: int32): int32 {.nsStatic: "Math".} = min(a, b)
proc Min*(a, b: float): float {.nsStatic: "Math".} = min(a, b)
proc Sign*(x: int32): int32 {.nsStatic: "Math".} = int32(cmp(x, int32(0)))
proc Sign*(x: float): int32 {.nsStatic: "Math".} = int32(cmp(x, float(0)))
proc Abs*[T: SomeSignedInt](x: T): T {.nsStatic: "Math".} = abs(x)
proc Max*[T: SomeNumber](a, b: T): T {.nsStatic: "Math".} = max(a, b)
proc Min*[T: SomeNumber](a, b: T): T {.nsStatic: "Math".} = min(a, b)
proc Sqrt*(x: float): float {.nsStatic: "Math".} = sqrt(x)
proc Pow*(x, y: float): float {.nsStatic: "Math".} = pow(x, y)
proc Floor*(x: float): float {.nsStatic: "Math".} = floor(x)
proc Ceiling*(x: float): float {.nsStatic: "Math".} = ceil(x)
proc Round*(x: float): float {.nsStatic: "Math".} =
  result = round(x)
  if abs(x - trunc(x)) == 0.5 and floorMod(result, 2.0) != 0.0:
    result = result - copySign(1.0, x)

{.pop.}


