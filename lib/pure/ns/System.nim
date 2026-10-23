# N# standard library: the System namespace. Imported by `using System;`.
#
# Members are ordinary Nim procs: an instance member is reached by Nim's
# dot-call, a static one through the qualifier the frontend drops.

import std/[syncio, strutils, math, hashes, algorithm, times, typetraits, os, monotimes, cpuinfo]
from std/unicode import nil
# `System.Collections.Generic` builds on this namespace, and this one names its
# interfaces (`Array.Sort` takes an `IComparer<T>`), as .NET's namespaces may.
import System/Collections/Generic {.cyclic.}
from ../nsharp/intrinsics import NsBoxed, nsBoxEquals, nsBoxHash, Equals, GetHashCode, NsArray, nsArrayOf, len,
  items, `[]`, `[]=`, nsFormatValue, nsAlign, nsBox, nsNoValue, nsExceptionName, ToString, nsTypeName, nsStamped, nsAdoptException, nsEnumName,
  Type, nsTypeNamed, nsTypeOf

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
  ArithmeticException* = ArithmeticDefect
    ## The base of `OverflowException` and `DivideByZeroException`, as in .NET:
    ## Nim's defects for them derive from `ArithmeticDefect`.

  SystemException* = object of CatchableError
  ApplicationException* = object of SystemException
  ArgumentException* = object of SystemException
  ArgumentNullException* = object of ArgumentException
  InvalidOperationException* = object of SystemException
  NotSupportedException* = object of SystemException
  NotImplementedException* = object of SystemException
  ObjectDisposedException* = object of InvalidOperationException
  UnauthorizedAccessException* = object of SystemException

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
#
# The message is .NET's from the start: N#'s own throws make it, and a defect Nim's
# runtime raised is given it where a `catch` first sees it (the intrinsics'
# `nsAdoptException`), so reading it is reading the field.

proc Message*[T: ref Exception](e: T): string = e.msg

# `new E(...)` of a library exception: the message .NET's constructor makes, which
# a parameterless one takes from the type, and one naming a parameter or an object
# appends.

proc nsNetName(nimName: string): string =
  ## The .NET name of an exception from the name `raise` gives it, Nim's: the
  ## defects .NET's exceptions alias, and this library's own types.
  case nimName
  of "IndexDefect", "IndexOutOfRangeException": "System.IndexOutOfRangeException"
  of "NilAccessDefect", "NullReferenceException": "System.NullReferenceException"
  of "OverflowDefect", "OverflowException": "System.OverflowException"
  of "DivByZeroDefect", "DivideByZeroException": "System.DivideByZeroException"
  of "ObjectConversionDefect", "InvalidCastException": "System.InvalidCastException"
  of "RangeDefect", "ArgumentOutOfRangeException": "System.ArgumentOutOfRangeException"
  of "KeyError", "KeyNotFoundException": "System.Collections.Generic.KeyNotFoundException"
  of "ValueError", "FormatException": "System.FormatException"
  of "ArithmeticDefect", "ArithmeticException": "System.ArithmeticException"
  of "SystemException", "ApplicationException", "ArgumentException",
     "ArgumentNullException", "InvalidOperationException", "NotSupportedException",
     "NotImplementedException", "ObjectDisposedException", "UnauthorizedAccessException":
    "System." & nimName
  of "IOException", "FileNotFoundException", "DirectoryNotFoundException",
     "EndOfStreamException", "PathTooLongException":
    ## Declared by `System.IO`, which builds on this module.
    "System.IO." & nimName
  of "", "Exception", "CatchableError", "Defect": "System.Exception"
  else: nimName

proc nsExceptionTypeName(e: ref Exception): string =
  ## `e.GetType()` of an exception: its `name`, which its constructor sets to the
  ## .NET name (see `nsNewException`, and the allocator of an exception class), and
  ## `raise` to Nim's when nothing did.
  nsNetName(if e.name.isNil: "" else: $e.name)

proc nsDefaultMessage*[T: Exception](e: ref T): string =
  ## The message of an exception made without one, as .NET's parameterless
  ## constructors make it: the nearest library type's, or `Exception`'s, which
  ## names the type.
  when T is ArgumentNullException: "Value cannot be null."
  elif T is ArgumentException: "Value does not fall within the expected range."
  elif T is ArgumentOutOfRangeException: "Specified argument was out of the range of valid values."
  elif T is ObjectDisposedException: "Cannot access a disposed object."
  elif T is InvalidOperationException:
    "Operation is not valid due to the current state of the object."
  elif T is NotSupportedException: "Specified method is not supported."
  elif T is NotImplementedException: "The method or operation is not implemented."
  elif T is ApplicationException: "Error in the application."
  elif T is UnauthorizedAccessException: "Attempted to perform an unauthorized operation."
  elif T is SystemException: "System error."
  elif T is KeyNotFoundException: "The given key was not present in the dictionary."
  elif T is FormatException: "One of the identified items was in an invalid format."
  elif T is IndexOutOfRangeException: "Index was outside the bounds of the array."
  elif T is NullReferenceException: "Object reference not set to an instance of an object."
  elif T is InvalidCastException: "Specified cast is not valid."
  elif T is OverflowException: "Arithmetic operation resulted in an overflow."
  elif T is DivideByZeroException: "Attempted to divide by zero."
  elif T is ArithmeticException: "Overflow or underflow in the arithmetic operation."
  else:
    ## The types of namespaces that build on this one, which it cannot name.
    case nsExceptionTypeName(e)
    of "System.IO.IOException": "I/O error occurred."
    of "System.IO.FileNotFoundException": "Unable to find the specified file."
    of "System.IO.DirectoryNotFoundException": "Attempted to access a path that is not on the disk."
    of "System.IO.EndOfStreamException": "Attempted to read past the end of the stream."
    else: "Exception of type '" & nsExceptionTypeName(e) & "' was thrown."

proc nsMade[T: Exception](t: typedesc[T]): ref T =
  ## A new exception, named as .NET names its type.
  new(result)
  const name = nsNetName($T)
  result.name = name

proc nsParam(m, param: string): string =
  if param.len > 0: m & " (Parameter '" & param & "')" else: m

proc nsNewException*[T: Exception](t: typedesc[T]): ref T =
  ## `new E()`.
  result = nsMade(T)
  result.msg = nsDefaultMessage(result)

proc nsNewException*[T: Exception](t: typedesc[T]; a: string): ref T =
  ## `new E(message)`; of `ArgumentNullException` and `ArgumentOutOfRangeException`
  ## the parameter's name, and of `ObjectDisposedException` the object's.
  result = nsMade(T)
  when T is ArgumentNullException or T is ArgumentOutOfRangeException:
    result.msg = nsParam(nsDefaultMessage(result), a)
  elif T is ObjectDisposedException:
    result.msg = nsDefaultMessage(result) & "\nObject name: '" & a & "'."
  else:
    result.msg = a

proc nsNewException*[T: Exception](t: typedesc[T]; a, b: string): ref T =
  ## `new ArgumentException(message, paramName)`, and the `(paramName, message)`
  ## of its relatives; `new ObjectDisposedException(objectName, message)`.
  result = nsMade(T)
  when T is ArgumentNullException or T is ArgumentOutOfRangeException:
    result.msg = nsParam(b, a)
  elif T is ArgumentException:
    result.msg = nsParam(a, b)
  elif T is ObjectDisposedException:
    result.msg = b & "\nObject name: '" & a & "'."
  else:
    {.error: "this exception has no constructor taking two strings".}

proc nsNewException*[T: Exception](t: typedesc[T]; a: string;
                                   inner: ref Exception): ref T =
  ## `new E(message, innerException)`.
  result = nsMade(T)
  result.msg = a
  result.parent = inner

# An exception nothing catches ends the program as .NET's runtime ends it: its type,
# message and inner exceptions on stderr, and an abort (exit status 134).

proc nsAbort() {.importc: "abort", header: "<stdlib.h>", noreturn.}
proc nsSignal(sig: cint; handler: pointer): pointer {.importc: "signal", header: "<signal.h>".}
var nsSIGABRT {.importc: "SIGABRT", header: "<signal.h>".}: cint
proc nimErrorFlag(): ptr bool {.importc: "nimErrorFlag", nodecl.}
  ## The runtime's flag for an exception in flight, with goto-based exceptions.

proc nsTraceText(e: ref Exception): string =
  ## `   at Main in Program.ns:line 6`, innermost call first, when the build keeps
  ## stack traces: the program's own calls, not the library's or the module's
  ## initialisation.
  result = ""
  when declared(getStackTraceEntries):
    let entries = e.getStackTraceEntries()
    for i in countdown(entries.high, 0):
      let t = entries[i]
      let file = $t.filename
      if file.endsWith(".nim") or file.endsWith("/" & $t.procname & ".ns"): continue
      result.add "\n   at " & $t.procname & " in " & file
      if t.line > 0: result.add ":line " & $t.line

proc nsUnhandled(e: ref Exception) {.nimcall, gcsafe, raises: [], tags: [].} =
  {.cast(gcsafe), cast(raises: []), cast(tags: []).}:
    when compileOption("exceptions", "goto"):
      ## `e` is still in flight, which every call below would take for its own.
      nimErrorFlag()[] = false
    try:
      flushFile(stdout)
      var chain = @[e]
      while chain[^1].parent != nil: chain.add chain[^1].parent
      var text = "Unhandled exception. "
      for i, x in chain:
        if i > 0: text.add "\n ---> "
        nsAdoptException(x)
        text.add nsExceptionTypeName(x) & ": " & x.msg
      for i in countdown(chain.high, 0):
        text.add nsTraceText(chain[i])
        if i > 0: text.add "\n   --- End of inner exception stack trace ---"
      stderr.write text & "\n"
      flushFile(stderr)
    except CatchableError: discard
    ## Nim's handler for the signal would report it again.
    discard nsSignal(nsSIGABRT, nil)
    nsAbort()

proc InnerException*[T: ref Exception](e: T): ref Exception = e.parent
  ## The exception a constructor was handed as the cause, or null.


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
proc CompareTo*[T: SomeFloat](a, b: T): int32 =
  ## NaN is less than every number and equal to itself, as `double.CompareTo` has it,
  ## so a sort or `Max` places it.
  if a != a: (if b != b: 0'i32 else: -1'i32)
  elif b != b: 1'i32
  else: int32(cmp(a, b))
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
  raise nsStamped(OverflowException, "Value was either too large or too small for " & T & ".",
                  "System.OverflowException")

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
# Strings compare by Unicode code point, a character's case by Unicode's simple
# case mapping: .NET's ordinal comparison, over code points rather than UTF-16
# code units (the two orders differ only past U+FFFF). There is no culture, so
# the default comparison (`string.Compare`, `CompareTo`, `Comparer<string>`) is
# this one too, and answers -1, 0 or 1 as .NET's does.

proc nsCompareOrdinal(a, b: string; ignoreCase: bool): int32 =
  ## The difference of the first two code points that differ, else of the lengths.
  var i, j = 0
  while i < a.len and j < b.len:
    var x, y: unicode.Rune
    unicode.fastRuneAt(a, i, x)
    unicode.fastRuneAt(b, j, y)
    if ignoreCase:
      x = unicode.toUpper(x)
      y = unicode.toUpper(y)
    if int32(x) != int32(y): return int32(x) - int32(y)
  if i < a.len: 1'i32 elif j < b.len: -1'i32 else: 0'i32

proc nsCompareText(a, b: string): int32 =
  ## The default comparison: by code point, as -1, 0 or 1.
  let d = nsCompareOrdinal(a, b, false)
  if d < 0: -1 elif d > 0: 1 else: 0

proc Compare*(c: StringComparer; a, b: string): int32 = nsCompareOrdinal(a, b, c.nsIgnoreCase)
proc CompareOrdinal*(a, b: string): int32 {.nsStatic: "String".} = nsCompareOrdinal(a, b, false)
proc Equals*(c: StringComparer; a, b: string): bool =
  if c.nsIgnoreCase: nsCompareOrdinal(a, b, true) == 0 else: a == b
proc GetHashCode*(c: StringComparer; s: string): int32 =
  let h = (if c.nsIgnoreCase: hash(unicode.toUpper(s)) else: hash(s))
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
proc ToUpper*(s: string): string = unicode.toUpper(s)
proc ToLower*(s: string): string = unicode.toLower(s)
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
proc CompareTo*(s, other: string): int32 = nsCompareText(s, other)
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
proc Join*(separator: string; values: varargs[string]): string {.nsStatic: "String".} =
  values.join(separator)
proc Join*(separator: string; values: NsArray[string]): string {.nsStatic: "String".} =
  values.nsData.join(separator)
proc Join*[T](separator: string; values: NsArray[T]): string {.nsStatic: "String".} =
  ## `Join<T>(string, IEnumerable<T>)` over an array, each element as `ToString()`
  ## renders it; any other collection is `System.Collections.Generic`'s.
  mixin `$`
  for i, x in values.nsData:
    if i > 0: result.add separator
    result.add $x
proc Compare*(a, b: string): int32 {.nsStatic: "String".} = nsCompareText(a, b)
proc Equals*(t: typedesc[string]; a, b: string): bool = a == b
  ## `string.Equals(a, b)`; `a.Equals(b)` is the intrinsics'.

# `string.Format`: .NET's composite format. A hole is `{index[,alignment][:format]}`,
# `{{` and `}}` are braces, and an argument formats as an interpolation hole does
# (`nsFormatValue`). A malformed format throws `FormatException` with .NET's text.

proc nsFormatFail(offset: int; reason: string) {.noinline, noreturn.} =
  raise nsNewException(FormatException, "Input string was not in a correct format. " &
    "Failure to parse near offset " & $offset & ". " & reason)

proc nsComposite*(format: string; args: openArray[RootRef]): string =
  ## The composite format, which `string.Format`, `Console.WriteLine` and
  ## `StringBuilder.AppendFormat` share.
  result = newStringOfCap(format.len + 8 * args.len)
  var i = 0
  let n = format.len
  while i < n:
    let c = format[i]
    if c == '{':
      if i + 1 < n and format[i + 1] == '{':
        result.add '{'
        i += 2
        continue
      var j = i + 1
      if j >= n: nsFormatFail(j, "Format item ends prematurely.")
      if format[j] notin {'0'..'9'}: nsFormatFail(j, "Expected an ASCII digit.")
      var index = 0
      while j < n and format[j] in {'0'..'9'}:
        index = index * 10 + (ord(format[j]) - ord('0'))
        inc j
      while j < n and format[j] == ' ': inc j
      var width = 0
      if j < n and format[j] == ',':
        inc j
        while j < n and format[j] == ' ': inc j
        var negative = false
        if j < n and format[j] == '-':
          negative = true
          inc j
        if j >= n: nsFormatFail(j, "Format item ends prematurely.")
        if format[j] notin {'0'..'9'}: nsFormatFail(j, "Expected an ASCII digit.")
        while j < n and format[j] in {'0'..'9'}:
          width = width * 10 + (ord(format[j]) - ord('0'))
          inc j
        if negative: width = -width
        while j < n and format[j] == ' ': inc j
      var spec = ""
      if j < n and format[j] == ':':
        inc j
        while j < n and format[j] != '}':
          if format[j] == '{': nsFormatFail(j, "Format item ends prematurely.")
          spec.add format[j]
          inc j
      if j >= n or format[j] != '}': nsFormatFail(j, "Format item ends prematurely.")
      if index >= args.len:
        raise nsNewException(FormatException, "Index (zero based) must be greater than " &
          "or equal to zero and less than the size of the argument list.")
      result.add nsAlign(nsFormatValue(args[index], spec), width)
      i = j + 1
    elif c == '}':
      if i + 1 < n and format[i + 1] == '}':
        result.add '}'
        i += 2
      elif i + 1 >= n:
        nsFormatFail(i + 1, "Format item ends prematurely.")
      else:
        nsFormatFail(i + 1, "Unexpected closing brace without a corresponding opening brace.")
    else:
      result.add c
      inc i

proc Format*(format: string; args: varargs[RootRef, nsBox]): string {.nsStatic: "String".} =
  nsComposite(format, args)

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
    if Equals(a.nsData[i], value): return int32(i)

proc Length*[T](a: openArray[T]): int32 = int32(a.len)
proc Clone*[T](a: openArray[T]): NsArray[T] = nsArrayOf(@a)
proc Rank*[T](a: openArray[T]): int32 = 1
proc GetLength*[T](a: openArray[T]; dimension: int32): int32 =
  if dimension == 0: int32(a.len) else: 0
proc IndexOf*[T](a: openArray[T]; value: T): int32 {.nsStatic: "Array".} =
  result = -1
  for i in 0 ..< a.len:
    if Equals(a[i], value): return int32(i)

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
proc WriteLine*[A](format: string; arg0: A; args: varargs[RootRef, nsBox]) {.nsStatic: "Console".} =
  ## `Console.WriteLine("{0} {1}", a, b)`: a composite format (see `string.Format`).
  ## It takes at least one argument after the format, so a lone string is printed
  ## as it is, by the overload above.
  echo nsComposite(format, @[nsBox(arg0)] & @args)
proc Write*[A](format: string; arg0: A; args: varargs[RootRef, nsBox]) {.nsStatic: "Console".} =
  stdout.write nsComposite(format, @[nsBox(arg0)] & @args)
proc ReadLine*(): string = stdin.readLine

# --- System.Math ------------------------------------------------------------
#
# The integer overloads keep the argument's type, as C#'s do; `Abs` of the most
# negative value throws `OverflowException` in .NET and wraps here only if checks
# are off, which they are not inside the library. `Round` rounds a midpoint to the
# even neighbour, .NET's default.

# `int` and `double` overloads, as .NET declares them, so an untyped literal picks
# `int`; a generic one covers the other numeric types.
proc nsAbsInt[T: SomeSignedInt](x: T): T =
  if x == low(T):
    raise nsStamped(OverflowException,
      "Negating the minimum value of a twos complement number is invalid.",
      "System.OverflowException")
  abs(x)
proc Abs*(x: int32): int32 {.nsStatic: "Math".} = nsAbsInt(x)
proc Abs*(x: float): float {.nsStatic: "Math".} = abs(x)
proc Max*(a, b: int32): int32 {.nsStatic: "Math".} = max(a, b)
proc Max*(a, b: float): float {.nsStatic: "Math".} = max(a, b)
proc Min*(a, b: int32): int32 {.nsStatic: "Math".} = min(a, b)
proc Min*(a, b: float): float {.nsStatic: "Math".} = min(a, b)
proc Sign*(x: int32): int32 {.nsStatic: "Math".} = int32(cmp(x, int32(0)))
proc Sign*(x: float): int32 {.nsStatic: "Math".} =
  ## NaN has no sign: .NET throws `ArithmeticException`.
  if x != x:
    raise nsStamped(ArithmeticException,
      "Function does not accept floating point Not-a-Number values.", "System.ArithmeticException")
  int32(cmp(x, float(0)))
proc Abs*[T: SomeSignedInt](x: T): T {.nsStatic: "Math".} = nsAbsInt(x)
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
proc Round*(x: float; digits: int32): float {.nsStatic: "Math".} =
  ## To `digits` decimals, a midpoint to even, as .NET computes it: scaled, rounded
  ## and scaled back, so `Round(2.675, 2)` is 2.68 (`267.5` is the nearest double).
  if digits < 0 or digits > 15:
    raise nsNewException(ArgumentOutOfRangeException, "digits",
                         "Rounding digits must be between 0 and 15, inclusive.")
  if abs(x) >= 1e16: return x
  let scale = pow(10.0, float(digits))
  Round(x * scale) / scale
proc Truncate*(x: float): float {.nsStatic: "Math".} = trunc(x)
proc Abs*[T: SomeFloat](x: T): T {.nsStatic: "Math".} = abs(x)
proc Sign*[T: SomeSignedInt](x: T): int32 {.nsStatic: "Math".} = int32(cmp(x, T(0)))
proc Clamp*[T: SomeNumber](value, min, max: T): T {.nsStatic: "Math".} =
  ## `value` held to `[min, max]`; `min > max` throws, as .NET does.
  if min > max:
    raise nsNewException(ArgumentException,
                         "'" & $min & "' cannot be greater than " & $max & ".")
  if value < min: min elif value > max: max else: value
proc Exp*(x: float): float {.nsStatic: "Math".} = exp(x)
proc Log*(x: float): float {.nsStatic: "Math".} = ln(x)
proc Log*(x, newBase: float): float {.nsStatic: "Math".} =
  ## With .NET's special cases: a base of 1 is NaN, as is 0 or +inf for any `x`
  ## but 1.
  if x != x: return x
  if newBase != newBase: return newBase
  if newBase == 1.0: return system.NaN
  if x != 1.0 and (newBase == 0.0 or newBase == Inf): return system.NaN
  ln(x) / ln(newBase)
proc Log10*(x: float): float {.nsStatic: "Math".} = log10(x)
proc Log2*(x: float): float {.nsStatic: "Math".} = log2(x)
proc Cbrt*(x: float): float {.nsStatic: "Math".} = cbrt(x)
proc Sin*(x: float): float {.nsStatic: "Math".} = sin(x)
proc Cos*(x: float): float {.nsStatic: "Math".} = cos(x)
proc Tan*(x: float): float {.nsStatic: "Math".} = tan(x)
proc Asin*(x: float): float {.nsStatic: "Math".} = arcsin(x)
proc Acos*(x: float): float {.nsStatic: "Math".} = arccos(x)
proc Atan*(x: float): float {.nsStatic: "Math".} = arctan(x)
proc Atan2*(y, x: float): float {.nsStatic: "Math".} = arctan2(y, x)
proc Sinh*(x: float): float {.nsStatic: "Math".} = sinh(x)
proc Cosh*(x: float): float {.nsStatic: "Math".} = cosh(x)
proc Tanh*(x: float): float {.nsStatic: "Math".} = tanh(x)
template PI*(t: typedesc[Math]): float = 3.141592653589793
template E*(t: typedesc[Math]): float = 2.718281828459045
template Tau*(t: typedesc[Math]): float = 6.283185307179586

# --- System.Char --------------------------------------------------------------
#
# A `char` here is a byte of UTF-8 text, so the classification is ASCII's: a
# character beyond it is not a `char` N# can hold.

proc IsDigit*(c: char): bool {.nsStatic: "Char".} = c in {'0'..'9'}
proc IsLetter*(c: char): bool {.nsStatic: "Char".} = c in {'a'..'z', 'A'..'Z'}
proc IsLetterOrDigit*(c: char): bool {.nsStatic: "Char".} =
  c in {'a'..'z', 'A'..'Z', '0'..'9'}
proc IsUpper*(c: char): bool {.nsStatic: "Char".} = c in {'A'..'Z'}
proc IsLower*(c: char): bool {.nsStatic: "Char".} = c in {'a'..'z'}
proc IsWhiteSpace*(c: char): bool {.nsStatic: "Char".} =
  c in {' ', '\t', '\n', '\v', '\f', '\r'}
proc IsPunctuation*(c: char): bool {.nsStatic: "Char".} =
  c in {'!', '"', '#', '%', '&', '\'', '(', ')', '*', ',', '-', '.', '/', ':', ';',
        '?', '@', '[', '\\', ']', '_', '{', '}'}
proc IsSymbol*(c: char): bool {.nsStatic: "Char".} =
  c in {'$', '+', '<', '=', '>', '^', '`', '|', '~'}
proc IsControl*(c: char): bool {.nsStatic: "Char".} = ord(c) < 32 or ord(c) == 127
proc IsNumber*(c: char): bool {.nsStatic: "Char".} = c in {'0'..'9'}
proc ToUpper*(c: char): char {.nsStatic: "Char".} = strutils.toUpperAscii(c)
proc ToLower*(c: char): char {.nsStatic: "Char".} = strutils.toLowerAscii(c)
proc GetNumericValue*(c: char): float {.nsStatic: "Char".} =
  if c in {'0'..'9'}: float(ord(c) - ord('0')) else: -1.0

# --- System.Random ------------------------------------------------------------
#
# A seeded `Random` is .NET's: the same subtractive generator (Knuth's, as .NET
# keeps it for a seed), so `new Random(42)` gives the numbers .NET gives. An
# unseeded one starts from the clock.

type
  Random* = ref object of RootObj
    ## `System.Random`.
    nsSeeds: array[56, int32]
    nsNext, nsNextP: int

method ToString*(r: Random): string = "System.Random"
method nsTypeName*(r: Random): string = "System.Random"
proc nsTypeOf*(t: typedesc[Random]): Type = nsTypeNamed("System.Random")

proc nsActualValue*(param, value, rule: string): ref ArgumentOutOfRangeException =
  ## .NET's message for an argument out of range that it names with its value:
  ## `maxValue ('-1') must be a non-negative value. (Parameter 'maxValue')`, then
  ## `Actual value was -1.`
  result = nsNewException(ArgumentOutOfRangeException)
  result.msg = param & " ('" & value & "') " & rule & " (Parameter '" & param &
               "')\nActual value was " & value & "."


proc nsSeed(r: Random; seed: int32) =
  const mBig = high(int32)
  var mj = 161803398'i32 - (if seed == low(int32): high(int32) else: abs(seed))
  r.nsSeeds[55] = mj
  var mk = 1'i32
  var ii = 0
  for i in 1 ..< 55:
    ii += 21
    if ii >= 55: ii -= 55
    r.nsSeeds[ii] = mk
    mk = mj - mk
    if mk < 0: mk += mBig
    mj = r.nsSeeds[ii]
  for k in 1 ..< 5:
    for i in 1 ..< 56:
      var n = i + 30
      if n >= 55: n -= 55
      r.nsSeeds[i] -= r.nsSeeds[1 + n]
      if r.nsSeeds[i] < 0: r.nsSeeds[i] += mBig
  r.nsNext = 0
  r.nsNextP = 21

proc newRandom*(seed: int32): Random =
  new(result)
  result.nsSeed(seed)

proc newRandom*(): Random =
  new(result)
  let t = getTime()
  result.nsSeed(cast[int32](t.toUnix xor t.nanosecond))

proc nsSample(r: Random): int32 =
  var a = r.nsNext + 1
  if a >= 56: a = 1
  var b = r.nsNextP + 1
  if b >= 56: b = 1
  var v = r.nsSeeds[a] - r.nsSeeds[b]
  if v == high(int32): dec v
  if v < 0: v += high(int32)
  r.nsSeeds[a] = v
  r.nsNext = a
  r.nsNextP = b
  v

proc nsUnit(r: Random): float = float(r.nsSample) * (1.0 / float(high(int32)))

proc Next*(r: Random): int32 = r.nsSample
  ## A value in `[0, int.MaxValue)`.
proc Next*(r: Random; maxValue: int32): int32 =
  ## A value in `[0, maxValue)`.
  if maxValue < 0:
    raise nsActualValue("maxValue", $maxValue, "must be a non-negative value.")
  int32(r.nsUnit * float(maxValue))
proc Next*(r: Random; minValue, maxValue: int32): int32 =
  ## A value in `[minValue, maxValue)`; a range wider than `int` takes two samples,
  ## as .NET's does.
  if minValue > maxValue:
    raise nsNewException(ArgumentOutOfRangeException, "minValue",
                         "'minValue' cannot be greater than maxValue.")
  let range = int64(maxValue) - int64(minValue)
  if range <= int64(high(int32)):
    return int32(int64(r.nsUnit * float(range)) + int64(minValue))
  var v = r.nsSample
  if r.nsSample mod 2 == 0: v = -v
  var d = float(v) + float(high(int32) - 1)
  d /= float(2'u32 * uint32(high(int32)) - 1)
  int32(int64(d * float(range)) + int64(minValue))
proc NextDouble*(r: Random): float = r.nsUnit
  ## A value in `[0, 1)`.

# --- System.Array: copying, filling and searching -----------------------------

proc nsRangeFail(param, message: string) {.noinline, noreturn.} =
  raise nsNewException(ArgumentOutOfRangeException, param, message)

proc Copy*[T](sourceArray: NsArray[T]; sourceIndex: int32; destinationArray: NsArray[T];
              destinationIndex, length: int32) {.nsStatic: "Array".} =
  ## Overlapping ranges of one array copy as if through a temporary, as .NET's do.
  if sourceArray == nil or destinationArray == nil:
    raise nsNewException(ArgumentNullException,
                         (if sourceArray == nil: "sourceArray" else: "destinationArray"))
  if sourceIndex < 0:
    raise nsActualValue("sourceIndex", $sourceIndex, "must be greater than or equal to '0'.")
  if destinationIndex < 0:
    raise nsActualValue("destinationIndex", $destinationIndex,
                        "must be greater than or equal to '0'.")
  if length < 0: raise nsActualValue("length", $length, "must be a non-negative value.")
  if int(sourceIndex) + int(length) > sourceArray.len:
    raise nsNewException(ArgumentException, "Source array was not long enough. Check " &
      "the source index, length, and the array's lower bounds.", "sourceArray")
  if int(destinationIndex) + int(length) > destinationArray.len:
    raise nsNewException(ArgumentException, "Destination array was not long enough. " &
      "Check the destination index, length, and the array's lower bounds.",
      "destinationArray")
  if sourceArray == destinationArray and destinationIndex > sourceIndex:
    for k in countdown(int(length) - 1, 0):
      destinationArray.nsData[int(destinationIndex) + k] = sourceArray.nsData[int(sourceIndex) + k]
  else:
    for k in 0 ..< int(length):
      destinationArray.nsData[int(destinationIndex) + k] = sourceArray.nsData[int(sourceIndex) + k]
proc Copy*[T](sourceArray, destinationArray: NsArray[T]; length: int32) {.nsStatic: "Array".} =
  Copy(sourceArray, 0, destinationArray, 0, length)
proc Empty*[T](): NsArray[T] {.nsStatic: "Array".} = nsArrayOf(newSeq[T]())
  ## `Array.Empty<T>()`: an array of no elements.
proc Fill*[T](a: NsArray[T]; value: T) {.nsStatic: "Array".} =
  for x in a.nsData.mitems: x = value
proc Clear*[T](a: NsArray[T]) {.nsStatic: "Array".} =
  for x in a.nsData.mitems: x = default(T)
proc Clear*[T](a: NsArray[T]; index, length: int32) {.nsStatic: "Array".} =
  if index < 0 or length < 0 or int(index) + int(length) > a.len:
    raise nsNewException(IndexOutOfRangeException)
  for k in int(index) ..< int(index) + int(length): a.nsData[k] = default(T)
proc Resize*[T](a: var NsArray[T]; newSize: int32) {.nsStatic: "Array".} =
  ## A new array of `newSize` elements, the old ones first; a null one is made.
  if newSize < 0: nsRangeFail("newSize", "Non-negative number required.")
  var data = newSeq[T](int(newSize))
  if a != nil:
    for k in 0 ..< min(a.len, int(newSize)): data[k] = a.nsData[k]
  a = nsArrayOf(data)
proc Reverse*[T](a: NsArray[T]) {.nsStatic: "Array".} = algorithm.reverse(a.nsData)
proc Reverse*[T](a: NsArray[T]; index, length: int32) {.nsStatic: "Array".} =
  if index < 0: nsRangeFail("index", "Non-negative number required.")
  if length < 0: nsRangeFail("length", "Non-negative number required.")
  if int(index) + int(length) > a.len:
    raise nsNewException(ArgumentException, "Offset and length were out of bounds for " &
      "the array or count is greater than the number of elements from index to the " &
      "end of the source collection.")
  if length > 0: algorithm.reverse(a.nsData, int(index), int(index) + int(length) - 1)
proc LastIndexOf*[T](a: NsArray[T]; value: T): int32 {.nsStatic: "Array".} =
  result = -1
  ## `Equals`, as .NET's: a NaN finds a NaN.
  for i in countdown(a.len - 1, 0):
    if Equals(a.nsData[i], value): return int32(i)
proc Exists*[T](a: NsArray[T]; match: Predicate[T]): bool {.nsStatic: "Array".} =
  for x in a.nsData:
    if match(x): return true
proc TrueForAll*[T](a: NsArray[T]; match: Predicate[T]): bool {.nsStatic: "Array".} =
  for x in a.nsData:
    if not match(x): return false
  true
proc Find*[T](a: NsArray[T]; match: Predicate[T]): T {.nsStatic: "Array".} =
  for x in a.nsData:
    if match(x): return x
proc FindLast*[T](a: NsArray[T]; match: Predicate[T]): T {.nsStatic: "Array".} =
  for i in countdown(a.len - 1, 0):
    if match(a.nsData[i]): return a.nsData[i]
proc FindIndex*[T](a: NsArray[T]; match: Predicate[T]): int32 {.nsStatic: "Array".} =
  result = -1
  for i in 0 ..< a.len:
    if match(a.nsData[i]): return int32(i)
proc ForEach*[T](a: NsArray[T]; action: Action[T]) {.nsStatic: "Array".} =
  for x in a.nsData: action(x)

# --- System.Convert -------------------------------------------------------------
#
# Members over `typedesc[Convert]`, as `Math.PI` is reached, so that `ToString` and
# its kin never meet the instance members of the same name. A number converts to
# an integer type rounded to even, as .NET rounds, and out of range throws
# `OverflowException` naming the target as .NET's messages do; a string converts as
# that type's `Parse` reads it.

type
  Convert* = object
    ## `System.Convert`: its members are static.

proc nsConvFail(T: string) {.noinline, noreturn.} =
  raise nsStamped(OverflowException, "Value was either too large or too small for " & T & ".",
                  "System.OverflowException")

proc nsToInteger[T: SomeInteger](x: float): T =
  ## Rounded half to even; NaN and values out of range overflow.
  var r = floor(x)
  let d = x - r
  if d > 0.5 or (d == 0.5 and floorMod(r, 2.0) != 0.0): r += 1.0
  if not (r >= float(low(T)) and r < float(high(T)) + 1.0): nsConvFail(nsNetName(T))
  T(r)

proc nsToInteger[T: SomeInteger; S: SomeInteger](x: S): T =
  when S is SomeUnsignedInt:
    if uint64(x) > uint64(high(T)): nsConvFail(nsNetName(T))
  elif T is SomeUnsignedInt:
    if x < 0 or uint64(x) > uint64(high(T)): nsConvFail(nsNetName(T))
  else:
    if int64(x) < int64(low(T)) or int64(x) > int64(high(T)): nsConvFail(nsNetName(T))
  T(x)

proc nsDigitsIn(s: string; base: int32; bits: int; neg: var bool): uint64 =
  ## `Convert.ToInt32(s, fromBase)`: digits of base 2, 8, 10 or 16 (`0x` allowed
  ## before hexadecimal), whose bits are the value, so `ffffffff` is -1; a sign
  ## first, though a minus only in base 10.
  if base notin [2'i32, 8, 10, 16]:
    raise nsNewException(ArgumentException, "Invalid Base.")
  var i = 0
  neg = false
  if i < s.len and s[i] in {'+', '-'}:
    if s[i] == '-':
      if base != 10:
        raise nsNewException(ArgumentException,
                             "String cannot contain a minus sign if the base is not 10.")
      neg = true
    inc i
  let first = i
  if base == 16 and s.len > i + 2 and s[i] == '0' and s[i + 1] in {'x', 'X'}: i += 2
  if i >= s.len: raise newException(FormatException, "Could not find any recognizable digits.")
  result = 0
  while i < s.len:
    let c = toLowerAscii(s[i])
    let d = (if c in {'0'..'9'}: ord(c) - ord('0') elif c in {'a'..'f'}: ord(c) - ord('a') + 10 else: 99)
    if d >= int(base):
      if i == first: raise newException(FormatException, "Could not find any recognizable digits.")
      raise newException(FormatException, "Additional non-parsable characters are at the end of the string.")
    let limit = (if bits == 64: high(uint64) else: (1'u64 shl bits) - 1)
    if result > (limit - uint64(d)) div uint64(base):
      nsConvFail(if bits == 64: "a UInt64" else: "a UInt32")
    result = result * uint64(base) + uint64(d)
    inc i

proc ToInt32*(t: typedesc[Convert]; value: float): int32 = nsToInteger[int32](value)
proc ToInt32*[S: SomeInteger](t: typedesc[Convert]; value: S): int32 = nsToInteger[int32, S](value)
proc ToInt32*(t: typedesc[Convert]; value: bool): int32 = int32(ord(value))
proc ToInt32*(t: typedesc[Convert]; value: char): int32 = int32(ord(value))
proc ToInt32*(t: typedesc[Convert]; value: string): int32 = Parse(int32, value)
proc ToInt32*(t: typedesc[Convert]; value: string; fromBase: int32): int32 =
  var neg: bool
  let v = nsDigitsIn(value, fromBase, 32, neg)
  if fromBase == 10:
    if v > uint64(high(int32)) + uint64(neg): nsConvFail("an Int32")
    if neg: int32(-int64(v)) else: int32(v)
  else: cast[int32](uint32(v))
proc ToInt64*(t: typedesc[Convert]; value: float): int64 = nsToInteger[int64](value)
proc ToInt64*[S: SomeInteger](t: typedesc[Convert]; value: S): int64 = nsToInteger[int64, S](value)
proc ToInt64*(t: typedesc[Convert]; value: bool): int64 = int64(ord(value))
proc ToInt64*(t: typedesc[Convert]; value: char): int64 = int64(ord(value))
proc ToInt64*(t: typedesc[Convert]; value: string): int64 = Parse(int64, value)
proc ToInt64*(t: typedesc[Convert]; value: string; fromBase: int32): int64 =
  var neg: bool
  let v = nsDigitsIn(value, fromBase, 64, neg)
  if fromBase == 10:
    if v > uint64(high(int64)) + uint64(neg): nsConvFail("an Int64")
    if neg: cast[int64](0'u64 - v) else: int64(v)
  else: cast[int64](v)
proc ToInt16*(t: typedesc[Convert]; value: float): int16 =
  ## Through `ToInt32`, as .NET's, which names that type when out of its range.
  nsToInteger[int16, int32](nsToInteger[int32](value))
proc ToInt16*[S: SomeInteger](t: typedesc[Convert]; value: S): int16 = nsToInteger[int16, S](value)
proc ToInt16*(t: typedesc[Convert]; value: bool): int16 = int16(ord(value))
proc ToInt16*(t: typedesc[Convert]; value: string): int16 = Parse(int16, value)
proc ToByte*(t: typedesc[Convert]; value: float): uint8 =
  nsToInteger[uint8, int32](nsToInteger[int32](value))
proc ToByte*[S: SomeInteger](t: typedesc[Convert]; value: S): uint8 = nsToInteger[uint8, S](value)
proc ToByte*(t: typedesc[Convert]; value: bool): uint8 = uint8(ord(value))
proc ToByte*(t: typedesc[Convert]; value: char): uint8 = uint8(ord(value))
proc ToByte*(t: typedesc[Convert]; value: string): uint8 = Parse(uint8, value)
proc ToUInt32*(t: typedesc[Convert]; value: float): uint32 = nsToInteger[uint32](value)
proc ToUInt32*[S: SomeInteger](t: typedesc[Convert]; value: S): uint32 = nsToInteger[uint32, S](value)
proc ToUInt32*(t: typedesc[Convert]; value: string): uint32 = Parse(uint32, value)

proc ToDouble*[S: SomeNumber](t: typedesc[Convert]; value: S): float = float(value)
proc ToDouble*(t: typedesc[Convert]; value: bool): float = (if value: 1.0 else: 0.0)
proc ToDouble*(t: typedesc[Convert]; value: string): float = Parse(float, value)
proc ToSingle*[S: SomeNumber](t: typedesc[Convert]; value: S): float32 = float32(value)
proc ToSingle*(t: typedesc[Convert]; value: string): float32 = Parse(float32, value)

proc ToBoolean*[S: SomeNumber](t: typedesc[Convert]; value: S): bool = value != S(0)
proc ToBoolean*(t: typedesc[Convert]; value: string): bool = Parse(bool, value)

proc ToChar*[S: SomeInteger](t: typedesc[Convert]; value: S): char =
  ## A code above 255 overflows: N#'s `char` holds one byte, where .NET's holds
  ## UTF-16 code units.
  when S is SomeSignedInt:
    if value < 0 or int64(value) > 255: nsConvFail("a character")
  else:
    if uint64(value) > 255: nsConvFail("a character")
  char(value)
proc ToChar*(t: typedesc[Convert]; value: string): char = Parse(char, value)

proc ToString*[S](t: typedesc[Convert]; value: S): string = ToString(value)
  ## `value.ToString()`.
proc ToString*[S: SomeInteger](t: typedesc[Convert]; value: S; toBase: int32): string =
  ## In base 2, 8, 10 or 16; outside 10 a negative number is its bits, as many as
  ## the type has.
  if toBase notin [2'i32, 8, 10, 16]:
    raise nsNewException(ArgumentException, "Invalid Base.")
  if toBase == 10: return $value
  ## A bare literal arrives as Nim's `int`, and is C#'s `int`, 32 bits.
  var u = (when S is int: uint64(cast[uint32](int32(value)))
           elif sizeof(S) == 8: cast[uint64](value) elif sizeof(S) == 4: uint64(cast[uint32](value))
           elif sizeof(S) == 2: uint64(cast[uint16](value)) else: uint64(cast[uint8](value)))
  if u == 0: return "0"
  result = ""
  while u != 0:
    result.insert($("0123456789abcdef"[int(u mod uint64(toBase))]), 0)
    u = u div uint64(toBase)

# --- System.Enum ----------------------------------------------------------------
#
# Generic statics over an enum type, reading its members through what the lowering
# of every enum declares: `nsEnumMembers` (names and values in declaration order)
# and `nsEnumIsFlags`.

type
  Enum* = object
    ## `System.Enum`, reached for its static members.

proc nsEnumOf[T](v: int64): T = T(distinctBase(T)(v))

proc GetValues*[T: distinct](): NsArray[T] {.nsStatic: "Enum".} =
  ## The members' values in declaration order.
  mixin nsEnumMembers
  var xs: seq[T] = @[]
  for m in nsEnumMembers(T): xs.add nsEnumOf[T](m[1])
  nsArrayOf(xs)

proc GetNames*[T: distinct](): NsArray[string] {.nsStatic: "Enum".} =
  mixin nsEnumMembers
  var xs: seq[string] = @[]
  for m in nsEnumMembers(T): xs.add m[0]
  nsArrayOf(xs)

proc GetName*[T: distinct](value: T): string {.nsStatic: "Enum".} =
  ## The name of the first member with this value; null when none has it.
  mixin nsEnumMembers
  for m in nsEnumMembers(T):
    if m[1] == int64(distinctBase(T)(value)): return m[0]
  ""

proc IsDefined*[T: distinct](value: T): bool {.nsStatic: "Enum".} =
  mixin nsEnumMembers
  for m in nsEnumMembers(T):
    if m[1] == int64(distinctBase(T)(value)): return true
  false

proc nsEnumParse[T](value: string; ignoreCase: bool; r: var T): int =
  ## 0 parsed; 1 no text; 2 a name not found; 3 a number out of range. A number
  ## is taken whatever it is; otherwise names, separated by commas, are or-ed.
  mixin nsEnumMembers
  let (i, e) = nsTrimmed(value)
  if i >= e: return 1
  let s = value.substr(i, e - 1)
  if s[0] in {'0'..'9', '-', '+'}:
    var n: distinctBase(T)
    case nsParseInt(s, n)
    of npOk:
      r = T(n)
      return 0
    of npOverflow: return 3
    of npFormat: discard
  var bits = 0'i64
  for part in s.split(','):
    let w = part.strip
    var found = false
    for m in nsEnumMembers(T):
      if (if ignoreCase: cmpIgnoreCase(m[0], w) == 0 else: m[0] == w):
        bits = bits or m[1]
        found = true
        break
    if not found: return 2
  r = nsEnumOf[T](bits)
  0

proc nsEnumParseFail(value, under: string; how: int) {.noinline, noreturn.} =
  if how == 1:
    raise nsNewException(ArgumentException,
      "Must specify valid information for parsing in the string.", "value")
  if how == 3:
    nsConvFail(under)
  raise nsNewException(ArgumentException, "Requested value '" & value & "' was not found.")

proc Parse*[T: distinct](value: string): T {.nsStatic: "Enum".} =
  let how = nsEnumParse(value, false, result)
  if how != 0: nsEnumParseFail(value, nsNetName(distinctBase(T)), how)
proc Parse*[T: distinct](value: string; ignoreCase: bool): T {.nsStatic: "Enum".} =
  let how = nsEnumParse(value, ignoreCase, result)
  if how != 0: nsEnumParseFail(value, nsNetName(distinctBase(T)), how)
proc TryParse*[T: distinct](value: string; r: var T): bool {.nsStatic: "Enum".} =
  ## Leaves the default (zero) when the text is not a member or number.
  var x: T
  result = nsEnumParse(value, false, x) == 0
  r = (if result: x else: default(T))
proc TryParse*[T: distinct](value: string; ignoreCase: bool; r: var T): bool {.nsStatic: "Enum".} =
  var x: T
  result = nsEnumParse(value, ignoreCase, x) == 0
  r = (if result: x else: default(T))

# --- System.Environment ---------------------------------------------------------

type
  Environment* = object
    ## `System.Environment`: its members are static.

proc nsExit(code: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}

template NewLine*(t: typedesc[Environment]): string = "\n"
  ## `"\n"`, as on the Unix systems N# targets.
proc Exit*(t: typedesc[Environment]; exitCode: int32) =
  ## Ends the program now, with this status; what was written is flushed first.
  flushFile(stdout)
  flushFile(stderr)
  nsExit(cint(exitCode))
proc GetCommandLineArgs*(t: typedesc[Environment]): NsArray[string] =
  ## The program's path, then its arguments.
  var xs = @[getAppFilename()]
  for i in 1 .. paramCount(): xs.add paramStr(i)
  nsArrayOf(xs)
proc GetEnvironmentVariable*(t: typedesc[Environment]; variable: string): string =
  ## The variable's value; null (N#'s empty string) when it is not set.
  getEnv(variable)
proc SetEnvironmentVariable*(t: typedesc[Environment]; variable, value: string) =
  ## A null or empty value removes the variable, as in .NET.
  if value.len == 0: delEnv(variable) else: putEnv(variable, value)
proc TickCount*(t: typedesc[Environment]): int32 =
  ## Milliseconds since an arbitrary start (the monotonic clock's), wrapping.
  cast[int32](uint32(getMonoTime().ticks div 1_000_000))
proc TickCount64*(t: typedesc[Environment]): int64 = getMonoTime().ticks div 1_000_000
proc ProcessorCount*(t: typedesc[Environment]): int32 = int32(max(1, countProcessors()))
proc CurrentDirectory*(t: typedesc[Environment]): string = getCurrentDir()
proc UserName*(t: typedesc[Environment]): string = getEnv("USER")

# --- System.TimeSpan ------------------------------------------------------------
#
# A struct of ticks (100 ns), as in .NET; its arithmetic overflows into
# `OverflowException`, and it prints as `[-][d.]hh:mm:ss[.fffffff]` in every
# culture.

type
  TimeSpan* = object
    ## `System.TimeSpan`.
    nsTicks: int64

const
  nsTicksPerMs = 10_000'i64
  nsTicksPerSecond = 10_000_000'i64
  nsTicksPerMinute = 600_000_000'i64
  nsTicksPerHour = 36_000_000_000'i64
  nsTicksPerDay = 864_000_000_000'i64

proc addOverflow(a, b: int64; r: var int64): bool =
  if (b > 0 and a > high(int64) - b) or (b < 0 and a < low(int64) - b): return true
  r = a + b
proc subOverflow(a, b: int64; r: var int64): bool =
  if (b < 0 and a > high(int64) + b) or (b > 0 and a < low(int64) + b): return true
  r = a - b

proc nsSpanFail() {.noinline, noreturn.} =
  raise nsStamped(OverflowException, "TimeSpan overflowed because the duration is too long.",
                  "System.OverflowException")

proc nsSpanRange() {.noinline, noreturn.} =
  ## A constructor's or a whole-unit `From*`'s overflow, which .NET reports as an
  ## argument out of range.
  raise nsNewException(ArgumentOutOfRangeException, "",
                       "TimeSpan overflowed because the duration is too long.")

proc nsSpanTicks(a, b: int64): int64 =
  ## `a * b` ticks (`b` positive), out of range as a TimeSpan's arguments are.
  if a > high(int64) div b or a < low(int64) div b: nsSpanRange()
  a * b

proc nsSpanOfMs(days, hours, minutes, seconds, milliseconds: int64): TimeSpan =
  ## The parts, which cannot overflow `long` as 32-bit values, then the range.
  let ms = (days * 86400 + hours * 3600 + minutes * 60 + seconds) * 1000 + milliseconds
  TimeSpan(nsTicks: nsSpanTicks(ms, nsTicksPerMs))

proc newTimeSpan*(ticks: int64): TimeSpan = TimeSpan(nsTicks: ticks)
proc newTimeSpan*(hours, minutes, seconds: int32): TimeSpan =
  nsSpanOfMs(0, hours, minutes, seconds, 0)
proc newTimeSpan*(days, hours, minutes, seconds: int32): TimeSpan =
  nsSpanOfMs(days, hours, minutes, seconds, 0)
proc newTimeSpan*(days, hours, minutes, seconds, milliseconds: int32): TimeSpan =
  nsSpanOfMs(days, hours, minutes, seconds, milliseconds)

proc nsSpanOf(value: float; scale: int64): TimeSpan =
  if value != value:
    raise nsNewException(ArgumentException, "TimeSpan does not accept floating point Not-a-Number values.")
  let t = value * float(scale)
  if not (t >= -9.223372036854775808e18 and t < 9.223372036854775808e18): nsSpanFail()
  TimeSpan(nsTicks: int64(t))

proc FromDays*(t: typedesc[TimeSpan]; value: float): TimeSpan = nsSpanOf(value, nsTicksPerDay)
proc FromHours*(t: typedesc[TimeSpan]; value: float): TimeSpan = nsSpanOf(value, nsTicksPerHour)
proc FromMinutes*(t: typedesc[TimeSpan]; value: float): TimeSpan = nsSpanOf(value, nsTicksPerMinute)
proc FromSeconds*(t: typedesc[TimeSpan]; value: float): TimeSpan = nsSpanOf(value, nsTicksPerSecond)
proc FromMilliseconds*(t: typedesc[TimeSpan]; value: float): TimeSpan = nsSpanOf(value, nsTicksPerMs)
proc FromTicks*(t: typedesc[TimeSpan]; value: int64): TimeSpan = TimeSpan(nsTicks: value)
# .NET 9's whole-unit overloads, which a whole number picks.
proc FromDays*[S: SomeInteger](t: typedesc[TimeSpan]; value: S): TimeSpan =
  TimeSpan(nsTicks: nsSpanTicks(int64(value), nsTicksPerDay))
proc FromHours*[S: SomeInteger](t: typedesc[TimeSpan]; value: S): TimeSpan =
  TimeSpan(nsTicks: nsSpanTicks(int64(value), nsTicksPerHour))
proc FromMinutes*[S: SomeInteger](t: typedesc[TimeSpan]; value: S): TimeSpan =
  TimeSpan(nsTicks: nsSpanTicks(int64(value), nsTicksPerMinute))
proc FromSeconds*[S: SomeInteger](t: typedesc[TimeSpan]; value: S): TimeSpan =
  TimeSpan(nsTicks: nsSpanTicks(int64(value), nsTicksPerSecond))
proc FromMilliseconds*[S: SomeInteger](t: typedesc[TimeSpan]; value: S): TimeSpan =
  TimeSpan(nsTicks: nsSpanTicks(int64(value), nsTicksPerMs))

template Zero*(t: typedesc[TimeSpan]): TimeSpan = TimeSpan(nsTicks: 0)
template MaxValue*(t: typedesc[TimeSpan]): TimeSpan = TimeSpan(nsTicks: high(int64))
template MinValue*(t: typedesc[TimeSpan]): TimeSpan = TimeSpan(nsTicks: low(int64))
template TicksPerMillisecond*(t: typedesc[TimeSpan]): int64 = nsTicksPerMs
template TicksPerSecond*(t: typedesc[TimeSpan]): int64 = nsTicksPerSecond
template TicksPerMinute*(t: typedesc[TimeSpan]): int64 = nsTicksPerMinute
template TicksPerHour*(t: typedesc[TimeSpan]): int64 = nsTicksPerHour
template TicksPerDay*(t: typedesc[TimeSpan]): int64 = nsTicksPerDay

proc Ticks*(s: TimeSpan): int64 = s.nsTicks
proc Days*(s: TimeSpan): int32 = int32(s.nsTicks div nsTicksPerDay)
proc Hours*(s: TimeSpan): int32 = int32(s.nsTicks div nsTicksPerHour mod 24)
proc Minutes*(s: TimeSpan): int32 = int32(s.nsTicks div nsTicksPerMinute mod 60)
proc Seconds*(s: TimeSpan): int32 = int32(s.nsTicks div nsTicksPerSecond mod 60)
proc Milliseconds*(s: TimeSpan): int32 = int32(s.nsTicks div nsTicksPerMs mod 1000)
proc TotalDays*(s: TimeSpan): float = float(s.nsTicks) / float(nsTicksPerDay)
proc TotalHours*(s: TimeSpan): float = float(s.nsTicks) / float(nsTicksPerHour)
proc TotalMinutes*(s: TimeSpan): float = float(s.nsTicks) / float(nsTicksPerMinute)
proc TotalSeconds*(s: TimeSpan): float = float(s.nsTicks) / float(nsTicksPerSecond)
proc TotalMilliseconds*(s: TimeSpan): float = float(s.nsTicks) / float(nsTicksPerMs)

proc `+`*(a, b: TimeSpan): TimeSpan =
  var r: int64
  if addOverflow(a.nsTicks, b.nsTicks, r): nsSpanFail()
  TimeSpan(nsTicks: r)
proc `-`*(a, b: TimeSpan): TimeSpan =
  var r: int64
  if subOverflow(a.nsTicks, b.nsTicks, r): nsSpanFail()
  TimeSpan(nsTicks: r)
proc `-`*(a: TimeSpan): TimeSpan =
  if a.nsTicks == low(int64):
    raise nsStamped(OverflowException,
      "Negating the minimum value of a twos complement number is invalid.", "System.OverflowException")
  TimeSpan(nsTicks: -a.nsTicks)
proc `+`*(a: TimeSpan): TimeSpan = a
proc `*`*(a: TimeSpan; factor: float): TimeSpan =
  if factor != factor:
    raise nsNewException(ArgumentException, "TimeSpan does not accept floating point Not-a-Number values.")
  let t = Round(float(a.nsTicks) * factor)
  if not (t >= -9.223372036854775808e18 and t < 9.223372036854775808e18): nsSpanFail()
  TimeSpan(nsTicks: int64(t))
proc `*`*(factor: float; a: TimeSpan): TimeSpan = a * factor
proc `/`*(a: TimeSpan; divisor: float): TimeSpan =
  if divisor != divisor:
    raise nsNewException(ArgumentException, "TimeSpan does not accept floating point Not-a-Number values.")
  let t = Round(float(a.nsTicks) / divisor)
  if not (t >= -9.223372036854775808e18 and t < 9.223372036854775808e18): nsSpanFail()
  TimeSpan(nsTicks: int64(t))
proc `/`*(a, b: TimeSpan): float = float(a.nsTicks) / float(b.nsTicks)
proc `<`*(a, b: TimeSpan): bool = a.nsTicks < b.nsTicks
proc `<=`*(a, b: TimeSpan): bool = a.nsTicks <= b.nsTicks
proc Add*(a, b: TimeSpan): TimeSpan = a + b
proc Subtract*(a, b: TimeSpan): TimeSpan = a - b
proc Negate*(a: TimeSpan): TimeSpan = -a
proc Duration*(a: TimeSpan): TimeSpan =
  if a.nsTicks == low(int64):
    raise nsStamped(OverflowException,
      "The duration cannot be returned for TimeSpan.MinValue because the absolute value of " &
      "TimeSpan.MinValue exceeds the value of TimeSpan.MaxValue.", "System.OverflowException")
  TimeSpan(nsTicks: abs(a.nsTicks))
proc Multiply*(a: TimeSpan; factor: float): TimeSpan = a * factor
proc Divide*(a: TimeSpan; divisor: float): TimeSpan = a / divisor
proc CompareTo*(a, b: TimeSpan): int32 = int32(cmp(a.nsTicks, b.nsTicks))
proc Equals*(a, b: TimeSpan): bool = a.nsTicks == b.nsTicks
proc GetHashCode*(a: TimeSpan): int32 = int32(a.nsTicks xor (a.nsTicks shr 32))
proc Compare*(t: typedesc[TimeSpan]; a, b: TimeSpan): int32 = int32(cmp(a.nsTicks, b.nsTicks))

proc nsPad(v: int64; width: int): string = align($v, width, '0')

proc ToString*(s: TimeSpan): string =
  ## `[-][d.]hh:mm:ss[.fffffff]`.
  result = ""
  var t = uint64(s.nsTicks)
  if s.nsTicks < 0:
    result.add '-'
    t = 0'u64 - t
  let days = t div uint64(nsTicksPerDay)
  let rest = int64(t mod uint64(nsTicksPerDay))
  if days != 0: result.add $days & "."
  result.add nsPad(rest div nsTicksPerHour, 2) & ":" &
             nsPad(rest div nsTicksPerMinute mod 60, 2) & ":" &
             nsPad(rest div nsTicksPerSecond mod 60, 2)
  let frac = rest mod nsTicksPerSecond
  if frac != 0: result.add "." & nsPad(frac, 7)
proc `$`*(s: TimeSpan): string = s.ToString
proc nsTypeOf*(t: typedesc[TimeSpan]): Type = nsTypeNamed("System.TimeSpan")

# --- System.DateTime ------------------------------------------------------------
#
# A struct of ticks since 0001-01-01 and a kind, as in .NET. The proleptic
# Gregorian calendar throughout; `Now` is the local time. Without a format it
# prints in en-US's general pattern (`M/d/yyyy h:mm:ss tt`), the culture the
# gates pin; a format of the standard letters or custom specifiers is honoured.

type
  DayOfWeek* = distinct int32
    ## `System.DayOfWeek`, an enum declared as the lowering declares one.
  DateTimeKind* = distinct int32
    ## `System.DateTimeKind`.
  DateTime* = object
    ## `System.DateTime`.
    nsTicks: int64
    nsKind: int32

const nsDayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
const nsMonthNames = ["January", "February", "March", "April", "May", "June", "July",
                      "August", "September", "October", "November", "December"]

template Sunday*(t: typedesc[DayOfWeek]): DayOfWeek = DayOfWeek(0)
template Monday*(t: typedesc[DayOfWeek]): DayOfWeek = DayOfWeek(1)
template Tuesday*(t: typedesc[DayOfWeek]): DayOfWeek = DayOfWeek(2)
template Wednesday*(t: typedesc[DayOfWeek]): DayOfWeek = DayOfWeek(3)
template Thursday*(t: typedesc[DayOfWeek]): DayOfWeek = DayOfWeek(4)
template Friday*(t: typedesc[DayOfWeek]): DayOfWeek = DayOfWeek(5)
template Saturday*(t: typedesc[DayOfWeek]): DayOfWeek = DayOfWeek(6)
proc `==`*(a, b: DayOfWeek): bool = int32(a) == int32(b)
proc `<`*(a, b: DayOfWeek): bool = int32(a) < int32(b)
proc `<=`*(a, b: DayOfWeek): bool = int32(a) <= int32(b)
proc hash*(a: DayOfWeek): Hash = hash(int32(a))
proc nsEnumMembers*(t: typedesc[DayOfWeek]): array[7, (string, int64)] =
  const table = [("Sunday", 0'i64), ("Monday", 1'i64), ("Tuesday", 2'i64),
                 ("Wednesday", 3'i64), ("Thursday", 4'i64), ("Friday", 5'i64),
                 ("Saturday", 6'i64)]
  table
proc nsEnumIsFlags*(t: typedesc[DayOfWeek]): bool = false
proc `$`*(a: DayOfWeek): string = nsEnumName(int64(a), nsEnumMembers(DayOfWeek), false)
proc ToString*(a: DayOfWeek): string = $a
proc nsTypeOf*(t: typedesc[DayOfWeek]): Type = nsTypeNamed("System.DayOfWeek")

template Unspecified*(t: typedesc[DateTimeKind]): DateTimeKind = DateTimeKind(0)
template Utc*(t: typedesc[DateTimeKind]): DateTimeKind = DateTimeKind(1)
template Local*(t: typedesc[DateTimeKind]): DateTimeKind = DateTimeKind(2)
proc `==`*(a, b: DateTimeKind): bool = int32(a) == int32(b)
proc hash*(a: DateTimeKind): Hash = hash(int32(a))
proc nsEnumMembers*(t: typedesc[DateTimeKind]): array[3, (string, int64)] =
  const table = [("Unspecified", 0'i64), ("Utc", 1'i64), ("Local", 2'i64)]
  table
proc nsEnumIsFlags*(t: typedesc[DateTimeKind]): bool = false
proc `$`*(a: DateTimeKind): string = nsEnumName(int64(a), nsEnumMembers(DateTimeKind), false)
proc ToString*(a: DateTimeKind): string = $a
proc nsTypeOf*(t: typedesc[DateTimeKind]): Type = nsTypeNamed("System.DateTimeKind")

const
  nsMaxDateTicks = 3_155_378_975_999_999_999'i64  ## 9999-12-31 23:59:59.9999999
  nsUnixEpochTicks = 621_355_968_000_000_000'i64

proc nsIsLeap(y: int64): bool = (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0
proc nsDaysIn(y, m: int64): int64 =
  case m
  of 2: (if nsIsLeap(y): 29 else: 28)
  of 4, 6, 9, 11: 30
  else: 31

proc nsDaysFromCivil(y0, m, d: int64): int64 =
  ## Days from 0001-01-01 (Hinnant's algorithm, shifted from 1970).
  let y = (if m <= 2: y0 - 1 else: y0)
  let era = floorDiv(y, 400)
  let yoe = y - era * 400
  let doy = (153 * (if m > 2: m - 3 else: m + 9) + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468 + 719162

proc nsCivil(days: int64): (int64, int64, int64) =
  let z = days - 719162 + 719468
  let era = floorDiv(z, 146097)
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = (if mp < 10: mp + 3 else: mp - 9)
  ((if m <= 2: yoe + era * 400 + 1 else: yoe + era * 400), m, d)

proc nsDateFail(message, param: string) {.noinline, noreturn.} =
  raise nsNewException(ArgumentOutOfRangeException, param, message)

proc nsDateTicks(year, month, day: int32): int64 =
  if year < 1 or year > 9999 or month < 1 or month > 12 or day < 1 or
     day > nsDaysIn(year, month):
    nsDateFail("Year, Month, and Day parameters describe an un-representable DateTime.", "")
  nsDaysFromCivil(year, month, day) * nsTicksPerDay

proc nsTimeTicks(hour, minute, second: int32): int64 =
  if hour notin 0'i32 .. 23 or minute notin 0'i32 .. 59 or second notin 0'i32 .. 59:
    nsDateFail("Hour, Minute, and Second parameters describe an un-representable DateTime.", "")
  (int64(hour) * 3600 + int64(minute) * 60 + int64(second)) * nsTicksPerSecond

proc nsDate(ticks: int64; kind: int32 = 0): DateTime =
  if ticks < 0 or ticks > nsMaxDateTicks:
    nsDateFail("The added or subtracted value results in an un-representable DateTime.", "value")
  DateTime(nsTicks: ticks, nsKind: kind)

proc newDateTime*(ticks: int64): DateTime =
  if ticks < 0 or ticks > nsMaxDateTicks:
    nsDateFail("Ticks must be between DateTime.MinValue.Ticks and DateTime.MaxValue.Ticks.", "ticks")
  DateTime(nsTicks: ticks)
proc newDateTime*(year, month, day: int32): DateTime =
  DateTime(nsTicks: nsDateTicks(year, month, day))
proc newDateTime*(year, month, day, hour, minute, second: int32): DateTime =
  DateTime(nsTicks: nsDateTicks(year, month, day) + nsTimeTicks(hour, minute, second))
proc newDateTime*(year, month, day, hour, minute, second, millisecond: int32): DateTime =
  if millisecond notin 0'i32 .. 999:
    nsDateFail("Valid values are between 0 and 999, inclusive.", "millisecond")
  DateTime(nsTicks: nsDateTicks(year, month, day) + nsTimeTicks(hour, minute, second) +
                    int64(millisecond) * nsTicksPerMs)
proc newDateTime*(year, month, day, hour, minute, second: int32; kind: DateTimeKind): DateTime =
  DateTime(nsTicks: nsDateTicks(year, month, day) + nsTimeTicks(hour, minute, second),
           nsKind: int32(kind))

proc UtcNow*(t: typedesc[DateTime]): DateTime =
  let n = getTime()
  DateTime(nsTicks: nsUnixEpochTicks + n.toUnix * nsTicksPerSecond + n.nanosecond div 100,
           nsKind: 1)
proc Now*(t: typedesc[DateTime]): DateTime =
  let n = times.now()
  let local = n.toTime.toUnix - n.utcOffset
  DateTime(nsTicks: nsUnixEpochTicks + local * nsTicksPerSecond + n.nanosecond div 100,
           nsKind: 2)
proc Today*(t: typedesc[DateTime]): DateTime =
  let n = Now(DateTime)
  DateTime(nsTicks: n.nsTicks - n.nsTicks mod nsTicksPerDay, nsKind: 2)
template MinValue*(t: typedesc[DateTime]): DateTime = DateTime(nsTicks: 0)
template MaxValue*(t: typedesc[DateTime]): DateTime = DateTime(nsTicks: nsMaxDateTicks)
template UnixEpoch*(t: typedesc[DateTime]): DateTime = DateTime(nsTicks: nsUnixEpochTicks, nsKind: 1)
proc IsLeapYear*(t: typedesc[DateTime]; year: int32): bool =
  if year < 1 or year > 9999: nsDateFail("Year must be between 1 and 9999.", "year")
  nsIsLeap(year)
proc DaysInMonth*(t: typedesc[DateTime]; year, month: int32): int32 =
  if month < 1 or month > 12: nsDateFail("Month must be between one and twelve.", "month")
  if year < 1 or year > 9999: nsDateFail("Year must be between 1 and 9999.", "year")
  int32(nsDaysIn(year, month))

proc Ticks*(d: DateTime): int64 = d.nsTicks
proc Kind*(d: DateTime): DateTimeKind = DateTimeKind(d.nsKind)
proc Year*(d: DateTime): int32 = int32(nsCivil(d.nsTicks div nsTicksPerDay)[0])
proc Month*(d: DateTime): int32 = int32(nsCivil(d.nsTicks div nsTicksPerDay)[1])
proc Day*(d: DateTime): int32 = int32(nsCivil(d.nsTicks div nsTicksPerDay)[2])
proc Hour*(d: DateTime): int32 = int32(d.nsTicks div nsTicksPerHour mod 24)
proc Minute*(d: DateTime): int32 = int32(d.nsTicks div nsTicksPerMinute mod 60)
proc Second*(d: DateTime): int32 = int32(d.nsTicks div nsTicksPerSecond mod 60)
proc Millisecond*(d: DateTime): int32 = int32(d.nsTicks div nsTicksPerMs mod 1000)
proc nsM_DayOfWeek*(d: DateTime): DayOfWeek = DayOfWeek(int32((d.nsTicks div nsTicksPerDay + 1) mod 7))
proc DayOfYear*(d: DateTime): int32 =
  let (y, _, _) = nsCivil(d.nsTicks div nsTicksPerDay)
  int32(d.nsTicks div nsTicksPerDay - nsDaysFromCivil(y, 1, 1) + 1)
proc Date*(d: DateTime): DateTime =
  DateTime(nsTicks: d.nsTicks - d.nsTicks mod nsTicksPerDay, nsKind: d.nsKind)
proc TimeOfDay*(d: DateTime): TimeSpan = TimeSpan(nsTicks: d.nsTicks mod nsTicksPerDay)

proc AddTicks*(d: DateTime; value: int64): DateTime =
  var r: int64
  if addOverflow(d.nsTicks, value, r): r = -1
  nsDate(r, d.nsKind)
proc nsAddUnits(d: DateTime; value: float; scale: int64): DateTime =
  ## The whole units, then the fraction of one, as .NET adds them.
  let whole = trunc(value)
  let t = whole * float(scale)
  if not (t > -float(nsMaxDateTicks) - 1 and t < float(nsMaxDateTicks) + 1):
    nsDateFail("Value to add was out of range.", "value")
  d.AddTicks(int64(whole) * scale + int64((value - whole) * float(scale)))
proc AddMilliseconds*(d: DateTime; value: float): DateTime = d.nsAddUnits(value, nsTicksPerMs)
proc AddSeconds*(d: DateTime; value: float): DateTime = d.nsAddUnits(value, nsTicksPerSecond)
proc AddMinutes*(d: DateTime; value: float): DateTime = d.nsAddUnits(value, nsTicksPerMinute)
proc AddHours*(d: DateTime; value: float): DateTime = d.nsAddUnits(value, nsTicksPerHour)
proc AddDays*(d: DateTime; value: float): DateTime = d.nsAddUnits(value, nsTicksPerDay)
proc AddMonths*(d: DateTime; months: int32): DateTime =
  ## The same day of the month, or the month's last when it has fewer days.
  if months < -120000 or months > 120000:
    nsDateFail("Months value must be between +/-120000.", "months")
  let (y, m, day) = nsCivil(d.nsTicks div nsTicksPerDay)
  let i = m - 1 + months
  let ny = y + floorDiv(i, 12)
  let nm = floorMod(i, 12) + 1
  if ny < 1 or ny > 9999:
    nsDateFail("The added or subtracted value results in an un-representable DateTime.", "months")
  DateTime(nsTicks: nsDaysFromCivil(ny, nm, min(day, nsDaysIn(ny, nm))) * nsTicksPerDay +
                    d.nsTicks mod nsTicksPerDay, nsKind: d.nsKind)
proc AddYears*(d: DateTime; value: int32): DateTime =
  if value < -10000 or value > 10000:
    nsDateFail("Years value must be between +/-10000.", "value")
  let (y, m, day) = nsCivil(d.nsTicks div nsTicksPerDay)
  let ny = y + value
  if ny < 1 or ny > 9999:
    nsDateFail("The added or subtracted value results in an un-representable DateTime.", "value")
  DateTime(nsTicks: nsDaysFromCivil(ny, m, min(day, nsDaysIn(ny, m))) * nsTicksPerDay +
                    d.nsTicks mod nsTicksPerDay, nsKind: d.nsKind)
proc Add*(d: DateTime; value: TimeSpan): DateTime = d.AddTicks(value.nsTicks)
proc Subtract*(d: DateTime; value: TimeSpan): DateTime =
  var r: int64
  if subOverflow(d.nsTicks, value.nsTicks, r): r = -1
  nsDate(r, d.nsKind)
proc Subtract*(a, b: DateTime): TimeSpan = TimeSpan(nsTicks: a.nsTicks - b.nsTicks)
proc `+`*(d: DateTime; value: TimeSpan): DateTime = d.Add(value)
proc `-`*(d: DateTime; value: TimeSpan): DateTime = d.Subtract(value)
proc `-`*(a, b: DateTime): TimeSpan = a.Subtract(b)
proc `==`*(a, b: DateTime): bool = a.nsTicks == b.nsTicks
  ## The instant alone, as .NET compares: the kind is not part of it.
proc `<`*(a, b: DateTime): bool = a.nsTicks < b.nsTicks
proc `<=`*(a, b: DateTime): bool = a.nsTicks <= b.nsTicks
proc CompareTo*(a, b: DateTime): int32 = int32(cmp(a.nsTicks, b.nsTicks))
proc Equals*(a, b: DateTime): bool = a.nsTicks == b.nsTicks
proc GetHashCode*(a: DateTime): int32 = int32(a.nsTicks xor (a.nsTicks shr 32))
proc Compare*(t: typedesc[DateTime]; a, b: DateTime): int32 = int32(cmp(a.nsTicks, b.nsTicks))

proc nsFormatDate(d: DateTime; format: string): string =
  ## en-US's names and separators; the standard patterns by their letter, whose
  ## AM/PM follows a narrow no-break space (U+202F), as ICU's en-US has it.
  var f = format
  if f.len == 1:
    case f[0]
    of 'd': f = "M/d/yyyy"
    of 'D': f = "dddd, MMMM d, yyyy"
    of 't': f = "h:mm\u202Ftt"
    of 'T': f = "h:mm:ss\u202Ftt"
    of 'g': f = "M/d/yyyy h:mm\u202Ftt"
    of 'G': f = "M/d/yyyy h:mm:ss\u202Ftt"
    of 'f': f = "dddd, MMMM d, yyyy h:mm\u202Ftt"
    of 'F': f = "dddd, MMMM d, yyyy h:mm:ss\u202Ftt"
    of 's': f = "yyyy'-'MM'-'dd'T'HH':'mm':'ss"
    of 'o', 'O': f = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fffffffK"
    of 'u': f = "yyyy'-'MM'-'dd HH':'mm':'ss'Z'"
    of 'R', 'r': f = "ddd, dd MMM yyyy HH':'mm':'ss 'GMT'"
    of 'M', 'm': f = "MMMM d"
    of 'Y', 'y': f = "MMMM yyyy"
    else:
      raise newException(FormatException, "Input string was not in a correct format.")
  let (y, mo, da) = nsCivil(d.nsTicks div nsTicksPerDay)
  let h = d.nsTicks div nsTicksPerHour mod 24
  result = ""
  var i = 0
  while i < f.len:
    let c = f[i]
    var n = 1
    while i + n < f.len and f[i + n] == c and c in {'y', 'M', 'd', 'h', 'H', 'm', 's', 'f', 'F', 't'}: inc n
    case c
    of 'y':
      if n <= 2: result.add nsPad(y mod 100, n) else: result.add nsPad(y, n)
    of 'M':
      if n <= 2: result.add nsPad(mo, n)
      elif n == 3: result.add nsMonthNames[mo - 1][0 .. 2]
      else: result.add nsMonthNames[mo - 1]
    of 'd':
      if n <= 2: result.add nsPad(da, n)
      else:
        let w = nsDayNames[int((d.nsTicks div nsTicksPerDay + 1) mod 7)]
        result.add(if n == 3: w[0 .. 2] else: w)
    of 'h': result.add nsPad((if h mod 12 == 0: 12 else: h mod 12), min(n, 2))
    of 'H': result.add nsPad(h, min(n, 2))
    of 'm': result.add nsPad(d.nsTicks div nsTicksPerMinute mod 60, min(n, 2))
    of 's': result.add nsPad(d.nsTicks div nsTicksPerSecond mod 60, min(n, 2))
    of 'f', 'F':
      if n > 7: raise newException(FormatException, "Input string was not in a correct format.")
      var digits = nsPad(d.nsTicks mod nsTicksPerSecond, 7)[0 ..< n]
      if c == 'F':
        digits = digits.strip(leading = false, chars = {'0'})
        if digits.len == 0 and result.endsWith("."): result.setLen(result.len - 1)
      result.add digits
    of 't': result.add(if n == 1: (if h < 12: "A" else: "P") else: (if h < 12: "AM" else: "PM"))
    of 'K':
      if d.nsKind == 1: result.add 'Z'
      elif d.nsKind == 2:
        let off = -times.now().utcOffset div 60
        result.add (if off < 0: "-" else: "+") & nsPad(abs(off) div 60, 2) & ":" & nsPad(abs(off) mod 60, 2)
    of '\'', '"':
      var j = i + 1
      while j < f.len and f[j] != c:
        result.add f[j]
        inc j
      n = j - i + 1
    of '\\':
      if i + 1 < f.len: result.add f[i + 1]
      n = 2
    of '%': discard
    else: result.add c
    i += n

proc ToString*(d: DateTime): string = nsFormatDate(d, "G")
proc ToString*(d: DateTime; format: string): string =
  nsFormatDate(d, if format.len == 0: "G" else: format)
proc `$`*(d: DateTime): string = d.ToString
proc nsTypeOf*(t: typedesc[DateTime]): Type = nsTypeNamed("System.DateTime")
proc ToShortDateString*(d: DateTime): string = nsFormatDate(d, "d")
proc ToLongDateString*(d: DateTime): string = nsFormatDate(d, "D")
proc ToShortTimeString*(d: DateTime): string = nsFormatDate(d, "t")
proc ToLongTimeString*(d: DateTime): string = nsFormatDate(d, "T")

{.pop.}

proc Dispose*[T](e: IEnumerator[T]) = e.nsDisposeEnumerator()
  ## `IDisposable.Dispose` of an enumerator (see `nsDisposeEnumerator`).

# An absent `T?` read with `.Value` or a cast throws .NET's exception (see the
# intrinsics' `nsNoValue`). A statement, so it comes after every declaration: a
# module of an import cycle shares only the declarations before its first one.
nsExceptionName = nsExceptionTypeName
unhandledExceptionHook = nsUnhandled
nsNoValue = proc () {.nimcall.} =
  raise newException(InvalidOperationException, "Nullable object must have a value.")
