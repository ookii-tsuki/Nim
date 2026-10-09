# N# standard library: the System namespace. Imported by `using System;`.
#
# Members are ordinary Nim procs: an instance member is reached by Nim's
# dot-call, a static one through the qualifier the frontend drops.

import std/[syncio, strutils]

# `{.nsStatic: "T".}` marks a proc C# reaches through a type qualifier
# (`Console.WriteLine`, `String.Concat`) rather than a receiver; the frontend
# re-files it as a member of that type, marked `static`. A name the library
# cannot place is reported rather than skipped. Members over `typedesc` already
# name their type, so they carry no pragma.
template nsStatic(typ: string) {.pragma.}

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

# --- System.Object ----------------------------------------------------------
#
# `object` is `RootRef`. `ToString` is in the intrinsics; `GetHashCode` has no
# RTTI, so it falls back to the bare-object answer.

method Equals*(a, b: RootRef): bool {.base.} = a == b
method GetHashCode*(x: RootRef): int32 {.base.} = int32(cast[int](x))
proc ReferenceEquals*(a, b: RootRef): bool {.nsStatic: "object".} = a == b

# --- System.String ----------------------------------------------------------

proc Length*(s: string): int32 = int32(s.len)
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
proc Split*(s: string; separator: char): seq[string] = s.split(separator)
proc PadLeft*(s: string; totalWidth: int32): string = s.align(int(totalWidth))
proc PadRight*(s: string; totalWidth: int32): string = s.alignLeft(int(totalWidth))
proc CompareTo*(s, other: string): int32 = int32(cmp(s, other))
proc ToCharArray*(s: string): seq[char] =
  for c in s: result.add c
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
proc Compare*(a, b: string): int32 {.nsStatic: "String".} = int32(cmp(a, b))

# --- System.Array -----------------------------------------------------------
#
# A C# array is a Nim `seq`, so the members are `openArray` procs.

proc Length*[T](a: openArray[T]): int32 = int32(a.len)
proc Clone*[T](a: openArray[T]): seq[T] = @a
proc GetLength*[T](a: openArray[T]; dimension: int32): int32 =
  if dimension == 0: int32(a.len) else: 0
proc IndexOf*[T](a: openArray[T]; value: T): int32 {.nsStatic: "Array".} =
  result = -1
  for i in 0 ..< a.len:
    if a[i] == value: return int32(i)

# --- System.Console ---------------------------------------------------------

# `$` is Nim's rendering, so a bool reads `true`; where C# spells differently the
# test records C#'s output in a `.csout` beside the `.out` (SPEC 7).

proc WriteLine*[T](x: T) {.nsStatic: "Console".} = echo x
proc Write*[T](x: T) {.nsStatic: "Console".} = stdout.write x
proc ReadLine*(): string = stdin.readLine

{.pop.}


