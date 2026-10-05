# N# intrinsics
#
# Imported into every compiled module, because C# needs no `using` for these:
# `"a" + b` concatenates anywhere, and any type can be printed.
#
# `$` is the one stringifier, and an object renders the way Nim renders a value of
# its type, so a class reads as its fields. A primitive keeps Nim's own rendering,
# which is why a bool reads `true` here and `True` in C#.

proc `$`*[T: ref object](x: T): string = $x[]
proc ToString*[T: ref object](x: T): string = $x[]

proc `+`*(a, b: string): string = a & b
proc `+`*[T](a: string, b: T): string = a & $b
proc `+`*[T](a: T, b: string): string = $a & b

# C# integer division truncates and throws on a zero divisor whatever the `checked`
# state, while Nim's check rides on `overflowChecks`, which N# turns off so that
# arithmetic wraps the way C#'s does. The check is therefore made here, and sema
# routes integer `/` and `%` to these.
proc nsDiv*[T: SomeInteger](a, b: T): T {.inline.} =
  if b == 0: raise newException(DivByZeroDefect, "Attempted to divide by zero.")
  system.`div`(a, b)

proc nsMod*[T: SomeInteger](a, b: T): T {.inline.} =
  if b == 0: raise newException(DivByZeroDefect, "Attempted to divide by zero.")
  system.`mod`(a, b)

proc nsCheckNil*[T: ref object](x: T): T {.inline.} =
  ## C# throws when a method is called on a nil receiver even if the body never
  ## touches `self`. A dereference check cannot see that, so the receiver is tested
  ## at the call. `desugar.nim` emits this around a dot-called class receiver; `x`
  ## is evaluated once, here.
  if x == nil: raise newException(NilAccessDefect, "attempt to access a nil address")
  x
