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
import std/hashes
export hashes

method ToString*(x: RootRef): string {.base.} =
  ## C#'s `object.ToString()`. Every class N# compiles overrides it with its own
  ## name, or with the user's override, so this is reached only by a class the
  ## compiler did not see.
  "System.Object"

proc ToString*[T: not RootRef](x: T): string = $x
  ## A value's `ToString()` is its `$`.

# `n.ToString("D2")`: a number in a .NET format, as an interpolation hole's. One
# overload per numeric type, as .NET declares them.
proc ToString*(x: int32; format: string): string = nsFormatNumber(x, format)
proc ToString*(x: int64; format: string): string = nsFormatNumber(x, format)
proc ToString*(x: int16; format: string): string = nsFormatNumber(x, format)
proc ToString*(x: int8; format: string): string = nsFormatNumber(x, format)
proc ToString*(x: uint32; format: string): string = nsFormatNumber(x, format)
proc ToString*(x: uint64; format: string): string = nsFormatNumber(x, format)
proc ToString*(x: uint16; format: string): string = nsFormatNumber(x, format)
proc ToString*(x: uint8; format: string): string = nsFormatNumber(x, format)
proc ToString*(x: float; format: string): string = nsFormatNumber(x, format)
proc ToString*(x: float32; format: string): string = nsFormatNumber(x, format)

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

# A C# enum is its underlying integer with names: `Read | Write` and `(Color)7` are
# values too, which a Nim `enum` cannot hold. The compiler declares each enum as a
# `distinct` integer, each member as a template over its `typedesc`
# (`Color.Red`), and calls `nsEnum` for the operators C# gives every enum.

proc nsEnumName*(v: int64; names: openArray[(string, int64)]; flags: bool): string =
  ## How .NET prints an enum value: the name of a member with that value; for a
  ## `[Flags]` enum, otherwise the names of the members whose bits make it up,
  ## highest first in the search and listed in declaration order; else the number.
  for (n, x) in names:
    if x == v: return n
  if flags and v != 0:
    var rest = v
    var parts: seq[string] = @[]
    for i in countdown(names.high, 0):
      let x = names[i][1]
      if x != 0 and (rest and x) == x:
        parts.insert(names[i][0], 0)
        rest = rest and not x
    if rest == 0 and parts.len > 0:
      result = ""
      for i, p in parts:
        if i > 0: result.add ", "
        result.add p
      return
  $v

template nsEnum*(E, U: untyped; flags: static bool; names: untyped) =
  ## The operators of the enum `E` over the integer `U`, and its printing from
  ## `names` (member, value) in declaration order. `HasFlag` is `System.Enum`'s.
  proc `==`*(a, b: E): bool {.borrow.}
  proc `<`*(a, b: E): bool {.borrow.}
  proc `<=`*(a, b: E): bool {.borrow.}
  proc `or`*(a, b: E): E = E(U(a) or U(b))
  proc `and`*(a, b: E): E = E(U(a) and U(b))
  proc `xor`*(a, b: E): E = E(U(a) xor U(b))
  proc `not`*(a: E): E = E(not U(a))
  proc hash*(a: E): Hash = hash(U(a))
  proc `$`*(a: E): string = nsEnumName(int64(U(a)), names, flags)
  proc ToString*(a: E): string = $a

import std/macros

macro Invoke*(d: typed; args: varargs[typed]): untyped =
  ## `d.Invoke(args)`, the member every delegate has: a call of `d`. For an
  ## event, which is the list of its handlers, each is called in order.
  var xs: seq[NimNode] = @[]
  for a in args: xs.add a
  if d.getTypeInst.typeKind == ntySequence:
    let h = genSym(nskForVar, "nsHandler")
    result = nnkForStmt.newTree(h, d, newStmtList(newCall(h, xs)))
  else:
    result = newCall(d, xs)

macro nsCombine*(a, b: typed): untyped =
  ## `a + b` for delegates (`d += h`): a delegate that calls `a` and then `b`,
  ## answering `b`'s result; a null side is the other one.
  let t = getTypeImpl(a)
  expectKind t, nnkProcTy
  let fp = t[0]
  var params = newNimNode(nnkFormalParams)
  params.add fp[0]
  var args: seq[NimNode] = @[]
  var k = 0
  for i in 1 ..< fp.len:
    let d = fp[i]
    for j in 0 ..< d.len - 2:
      let nm = ident("nsArg" & $k)
      inc k
      params.add newIdentDefs(nm, d[^2])
      args.add nm
  let na = genSym(nskLet, "nsA")
  let nb = genSym(nskLet, "nsB")
  let callA = newCall(na, args)
  let callB = newCall(nb, args)
  let first = (if fp[0].kind == nnkEmpty: callA
               else: newNimNode(nnkDiscardStmt).add(callA))
  let body = newStmtList(callB)
  let lam = newProc(newEmptyNode(), [], newStmtList(first, body), nnkLambda)
  lam[3] = params
  lam[4] = newNimNode(nnkPragma).add(ident"closure")
  result = quote do:
    (block:
      let `na` = `a`
      let `nb` = `b`
      (if `na` == nil: `nb` elif `nb` == nil: `na` else: `lam`))

proc nsSubscribe*[D](e: var seq[D]; h: D) =
  ## `e += h` on an event: `h` joins its handlers (a null one does not).
  if h != nil: e.add h

proc nsUnsubscribe*[D](e: var seq[D]; h: D) =
  ## `e -= h` on an event: the last handler equal to `h` leaves.
  for i in countdown(e.high, 0):
    if e[i] == h:
      e.delete(i)
      return

proc `==`*[D: proc](e: seq[D]; n: typeof(nil)): bool = e.len == 0
  ## An event without handlers is null, as C#'s is.
