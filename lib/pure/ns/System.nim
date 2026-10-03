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
  ArgumentException* = object of CatchableError
  InvalidOperationException* = object of CatchableError
  NullReferenceException* = object of CatchableError

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

# C# prints a bool as `True`/`False` (`Console.WriteLine(b)` calls `b.ToString()`);
# Nim's `$bool` gives `true`/`false`.
proc WriteLine*(x: bool) = echo (if x: "True" else: "False")
proc Write*(x: bool) = stdout.write(if x: "True" else: "False")

proc WriteLine*[T](x: T) = echo x
proc Write*[T](x: T) = stdout.write x
proc ReadLine*(): string = stdin.readLine

{.pop.}
