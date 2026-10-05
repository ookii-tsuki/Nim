# N# standard library: the System namespace.
#
# Covers Object, String, Array and Console. Members are ordinary Nim procs: an
# instance member is reached through Nim's dot-call, a static one such as
# `String.IsNullOrEmpty` through the qualifier the frontend drops.
#
# Imported by `using System;`.

import std/[syncio, strutils]

{.push discardable.}

type
  # --- System.Exception -------------------------------------------------------
  #
  # The .NET exception types. Where Nim's runtime raises a matching defect the
  # name is an alias for it, so `catch (NullReferenceException)` catches a real
  # nil dereference instead of never firing at all. `Exception` itself is Nim's
  # exception root, from which both `Defect` and `CatchableError` derive, so
  # `catch (Exception)` catches what C# would catch.
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

  Console* = object
    ## `.NET`'s `Console` is a static class: nothing is ever an instance of it. It
    ## is declared so the frontend resolves the name as a type, and its members are
    ## the module's own procs, reached through the qualifier the frontend drops.

# --- System.Exception -------------------------------------------------------
#
# `e.Message` is a property of every exception in C#, and here it is an ordinary
# proc over the exception root, reached by Nim's dot-call. It is generic because an
# N# exception class derives from `Exception` as a *value* object and is raised as
# a `ref` of it, exactly as Nim raises a `ref` of a `Defect`; and because a `ref`
# does not convert to its base in an argument position.

proc Message*[T: ref Exception](e: T): string = e.msg

# --- System.Int32, Double, Char, String -------------------------------------
#
# C# reads these as `static` fields of the built-in types; .NET declares them as
# `const` in the runtime library. Nim reaches a member of a type through a
# dot-call on the type, the way `int.high` reaches `high(int32)`, so the values
# belong here rather than in the compiler.

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
# `object` is `RootRef`, so these take any N# class. `ToString` lives in the N#
# intrinsics, which is imported into every module; GetHashCode wants the dynamic
# type, which N# has no RTTI for, so it falls back to the bare-object answer.

method Equals*(a, b: RootRef): bool {.base.} = a == b
method GetHashCode*(x: RootRef): int32 {.base.} = int32(cast[int](x))
proc ReferenceEquals*(a, b: RootRef): bool = a == b

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
proc IsNullOrEmpty*(s: string): bool = s.len == 0
proc IsNullOrWhiteSpace*(s: string): bool =
  s.len == 0 or s.allCharsInSet({' ', '\t', '\n', '\r', '\v', '\f'})
proc Concat*(a, b: string): string = a & b
proc Join*(separator: string; values: openArray[string]): string =
  values.join(separator)
proc Compare*(a, b: string): int32 = int32(cmp(a, b))

# --- System.Array -----------------------------------------------------------
#
# A C# array is a Nim `seq`, so the members are `openArray` procs.

proc Length*[T](a: openArray[T]): int32 = int32(a.len)
proc Clone*[T](a: openArray[T]): seq[T] = @a
proc GetLength*[T](a: openArray[T]; dimension: int32): int32 =
  if dimension == 0: int32(a.len) else: 0
proc IndexOf*[T](a: openArray[T]; value: T): int32 =
  result = -1
  for i in 0 ..< a.len:
    if a[i] == value: return int32(i)

# --- System.Console ---------------------------------------------------------

# `$` is Nim's rendering, so a bool reads `true` and a special float reads `nan`.
# Where C# spells something differently the test records C#'s output in a `.csout`
# beside its `.out` (SPEC section 7), rather than the library special-casing it.

proc WriteLine*[T](x: T) = echo x
proc Write*[T](x: T) = stdout.write x
proc ReadLine*(): string = stdin.readLine

{.pop.}
