#
#           N# prelude - the `System` namespace
#
# The C# surface that lives in `System`: `Console` and the exception hierarchy.
# This module is NOT auto-imported. The frontend maps `using System;` onto it
# (see parseUsing in compiler/nsharp/parser.nim), so `Console.WriteLine` only
# resolves when the program actually has the `using`, exactly as in C#.
#
# Everything here is ordinary Nim; the C# namespace is a name we present, not a
# directory. See SPEC section 15.

import std/[syncio]

{.push discardable.}

type
  ArgumentException* = object of CatchableError
  InvalidOperationException* = object of CatchableError
  NullReferenceException* = object of CatchableError

# C# prints a bool as `True`/`False` (`Console.WriteLine(b)` calls
# `b.ToString()`); Nim's `$bool` gives `true`/`false`. SPEC section 7.3.
proc WriteLine*(x: bool) = echo (if x: "True" else: "False")
proc Write*(x: bool) = stdout.write(if x: "True" else: "False")

proc WriteLine*[T](x: T) = echo x
proc Write*[T](x: T) = stdout.write x
proc ReadLine*(): string = stdin.readLine

{.pop.}
