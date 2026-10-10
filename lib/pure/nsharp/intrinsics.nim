# N# intrinsics
#
# Imported into every compiled module, because C# needs no `using` for these:
# `"a" + b` concatenates anywhere, and any type can be printed.
#
# `$` is the one stringifier, and an object renders the way Nim renders a value of
# its type, so a class reads as its fields. A primitive keeps Nim's own rendering,
# which is why a bool reads `true` here and `True` in C#.

import format
export format

method ToString*(x: RootRef): string {.base.} =
  ## C#'s `object.ToString()`. Every class N# compiles overrides it with its own
  ## name, or with the user's override, so this is reached only by a class the
  ## compiler did not see.
  "System.Object"

proc ToString*[T: not RootRef](x: T): string = $x
  ## A value's `ToString()` is its `$`.

proc `$`*[T: RootRef](x: T): string =
  ## Printing a class asks it, so an override is what `Console.WriteLine` shows.
  if x == nil: "" else: x.ToString()

proc `$`*[T: ref object and not RootRef](x: T): string = $x[]

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

import std/options

export options

# `.NET`'s nullable members and `??` are the *type's* business, so they are ordinary
# procs over `Option` reached by Nim's own dot-call, the way `int.high` reaches
# `high(int32)`. The compiler knows none of these names.

proc Value*[T](x: Option[T]): T =
  ## `x.Value`. C# throws `InvalidOperationException` when there is no value; Nim's
  ## `get` returns a `lent` view and raises `UnpackDefect`, which is the divergence
  ## to record.
  result = x.get

proc HasValue*[T](x: Option[T]): bool = x.isSome

proc GetValueOrDefault*[T](x: Option[T]): T =
  if x.isSome: result = x.get
  else: result = default(T)

proc nsAbsent*[T](x: Option[T]): bool =
  ## `a?.V` / `a ?? b` ask the type whether it is absent; the compiler emits this
  ## rather than naming a member, so the `Option` API stays the library's business.
  x.isNone

proc nsPresent*[T](x: Option[T]): T =
  ## The unwrapped value, for the present side of the same lowering.
  result = x.get

# C# lifts the arithmetic and comparison operators onto `T?`. Arithmetic yields the
# absent value when either operand is absent, comparison yields a plain `bool` that is
# false when either operand is absent, and `==` keeps "absent equals absent", which
# structural equality already gives.
#
# A bare value on the *left* (`1 + a`) has no lifted form: the result type would follow
# the literal rather than the nullable, so only `a + 1` and `a + b` are provided.
#
# `/` and `%` reuse the division check above, so a zero divisor raises rather than
# trapping whatever `checked` says.
template nsBoth[T](a, b: Option[T], body: untyped): Option[T] =
  ## `body` reads the unwrapped values, so it is only evaluated when both are present.
  if a.isSome and b.isSome: some(body) else: none(T)

proc `+`*[T: SomeNumber](a, b: Option[T]): Option[T] = nsBoth(a, b, a.get + b.get)
proc `+`*[T: SomeNumber](a: Option[T], b: T): Option[T] =
  if a.isSome: some(a.get + b) else: none(T)

proc `-`*[T: SomeNumber](a, b: Option[T]): Option[T] = nsBoth(a, b, a.get - b.get)
proc `-`*[T: SomeNumber](a: Option[T], b: T): Option[T] =
  if a.isSome: some(a.get - b) else: none(T)

proc `*`*[T: SomeNumber](a, b: Option[T]): Option[T] = nsBoth(a, b, a.get * b.get)
proc `*`*[T: SomeNumber](a: Option[T], b: T): Option[T] =
  if a.isSome: some(a.get * b) else: none(T)

proc `/`*[T: SomeInteger](a, b: Option[T]): Option[T] = nsBoth(a, b, nsDiv(a.get, b.get))
proc `/`*[T: SomeInteger](a: Option[T], b: T): Option[T] =
  if a.isSome: some(nsDiv(a.get, b)) else: none(T)

proc `mod`*[T: SomeInteger](a, b: Option[T]): Option[T] = nsBoth(a, b, nsMod(a.get, b.get))
proc `mod`*[T: SomeInteger](a: Option[T], b: T): Option[T] =
  if a.isSome: some(nsMod(a.get, b)) else: none(T)

proc `<`*[T: SomeNumber](a, b: Option[T]): bool = a.isSome and b.isSome and a.get < b.get
proc `<`*[T: SomeNumber](a: Option[T], b: T): bool = a.isSome and a.get < b

proc `<=`*[T: SomeNumber](a, b: Option[T]): bool = a.isSome and b.isSome and a.get <= b.get
proc `<=`*[T: SomeNumber](a: Option[T], b: T): bool = a.isSome and a.get <= b

proc `>`*[T: SomeNumber](a, b: Option[T]): bool = a.isSome and b.isSome and a.get > b.get
proc `>`*[T: SomeNumber](a: Option[T], b: T): bool = a.isSome and a.get > b

proc `>=`*[T: SomeNumber](a, b: Option[T]): bool = a.isSome and b.isSome and a.get >= b.get
proc `>=`*[T: SomeNumber](a: Option[T], b: T): bool = a.isSome and a.get >= b

proc nsCheckNil*[T: ref object](x: T): T {.inline.} =
  ## C# throws when a method is called on a nil receiver even if the body never
  ## touches `self`. A dereference check cannot see that, so the receiver is tested
  ## at the call. `desugar.nim` emits this around a dot-called class receiver; `x`
  ## is evaluated once, here.
  if x == nil: raise newException(NilAccessDefect, "attempt to access a nil address")
  x

proc nsIfaceCast*[T](v: T; src: RootRef): T =
  ## `(I)x` for an interface `I`: `v` is what the object's class answered for `I`,
  ## empty when it does not implement it. C# throws `InvalidCastException` then,
  ## unless `x` was null, which casts to the null interface value.
  if src != nil and v.nsObj == nil:
    raise newException(ObjectConversionDefect, "Specified cast is not valid.")
  v

proc nsCreate*[T: not ref](t: typedesc[T]): T =
  ## `new T()` for a value type: its default. A class declares its own `nsCreate`,
  ## which calls its parameterless constructor.
  default(T)

template nsStmt*(x: untyped) =
  ## A delegate call used as a statement: C# drops its result, and a Nim proc value
  ## cannot be `{.discardable.}`, so a result is discarded here.
  when typeof(x) is void: x
  else: discard x

# `x++` / `++x` used as a value, and on a target Nim's `inc` cannot take: a property
# or an indexer (whose getter's result is no variable) or a float. The new value is
# assigned, so a property's setter runs. A plain integer statement increment is
# Nim's own `inc`/`dec`.
template nsStepped(v: typed; up: static bool): untyped =
  when typeof(v) is SomeFloat: (when up: v + 1 else: v - 1)
  else: (when up: succ(v) else: pred(v))
template nsPostInc*(x: untyped): untyped =
  (let nsOld = x; x = nsStepped(nsOld, true); nsOld)
template nsPostDec*(x: untyped): untyped =
  (let nsOld = x; x = nsStepped(nsOld, false); nsOld)
template nsPreInc*(x: untyped): untyped =
  (x = nsStepped(x, true); x)
template nsPreDec*(x: untyped): untyped =
  (x = nsStepped(x, false); x)
template nsInc*(x: untyped) =
  x = nsStepped(x, true)
template nsDec*(x: untyped) =
  x = nsStepped(x, false)

type
  SwitchExpressionException* = object of CatchableError
    ## What a switch expression throws when no arm matches. C# declares it in
    ## `System.Runtime.CompilerServices`; the compiler raises it, so it lives here.

template nsDispose*(x: typed) =
  ## What `using` runs when its scope is left: `x.Dispose()`, unless `x` is null.
  when x is ref:
    if x != nil: x.Dispose()
  elif compiles(x.nsObj):
    if x.nsObj != nil: x.Dispose()
  else:
    x.Dispose()

import std/cmdline

proc nsCommandLine*(): seq[string] =
  ## `Main`'s `string[] args`: the command line without the program's name.
  commandLineParams()

proc nsVal*[T](x: T): T {.inline.} =
  ## A variable's value read now: `x + F()` in C# reads `x` before `F` runs, while
  ## Nim reads a variable operand after the call. The compiler wraps an operand in
  ## this when a later one may change it.
  x
