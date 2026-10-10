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
import std/strutils
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

# `System.Type`, as far as N# can tell one type from another without reflection:
# its name. `typeof(T)` is `nsTypeOf(T)`, which the compiler declares for each type
# it lowers and the library for the built-in ones; `x.GetType()` asks a class
# value for its dynamic type's name, through a `method` every class overrides.

type
  Type* = ref object of RootObj
    ## C#'s `System.Type`: a type, known by its namespace-qualified name.
    nsFull: string

proc nsTypeNamed*(full: string): Type = Type(nsFull: full)
proc FullName*(t: Type): string = t.nsFull
proc Namespace*(t: Type): string =
  let i = t.nsFull.rfind('.')
  if i >= 0: t.nsFull[0 ..< i] else: ""
method ToString*(t: Type): string = t.nsFull
proc `==`*(a, b: Type): bool =
  if a.isNil or b.isNil: a.isNil and b.isNil else: a.nsFull == b.nsFull

proc nsTypeOf*(t: typedesc[int8]): Type = nsTypeNamed("System.SByte")
proc nsTypeOf*(t: typedesc[uint8]): Type = nsTypeNamed("System.Byte")
proc nsTypeOf*(t: typedesc[int16]): Type = nsTypeNamed("System.Int16")
proc nsTypeOf*(t: typedesc[uint16]): Type = nsTypeNamed("System.UInt16")
proc nsTypeOf*(t: typedesc[int32]): Type = nsTypeNamed("System.Int32")
proc nsTypeOf*(t: typedesc[uint32]): Type = nsTypeNamed("System.UInt32")
proc nsTypeOf*(t: typedesc[int64]): Type = nsTypeNamed("System.Int64")
proc nsTypeOf*(t: typedesc[int]): Type = nsTypeNamed("System.Int32")
  ## Nim's `int` is an untyped C# `int` literal (`3.GetType()`); C#'s `long` is
  ## always `int64`.
proc nsTypeOf*(t: typedesc[uint64]): Type = nsTypeNamed("System.UInt64")
proc nsTypeOf*(t: typedesc[float32]): Type = nsTypeNamed("System.Single")
proc nsTypeOf*(t: typedesc[float]): Type = nsTypeNamed("System.Double")
proc nsTypeOf*(t: typedesc[bool]): Type = nsTypeNamed("System.Boolean")
proc nsTypeOf*(t: typedesc[char]): Type = nsTypeNamed("System.Char")
proc nsTypeOf*(t: typedesc[string]): Type = nsTypeNamed("System.String")
proc nsTypeOf*(t: typedesc[RootRef]): Type = nsTypeNamed("System.Object")

method nsTypeName*(x: RootRef): string {.base.} = "System.Object"
  ## The dynamic type's name; every class N# lowers overrides it.

proc GetType*(x: RootRef): Type =
  ## `x.GetType()` on a class value: its dynamic type.
  if x == nil: raise newException(NilAccessDefect, "attempt to access a nil address")
  nsTypeNamed(x.nsTypeName)
proc GetType*[T: not RootRef](x: T): Type = nsTypeOf(T)
  ## A value's type is its static one.

# `sizeof(T)` for the built-in value types, as C# defines them (a `char` is two
# bytes there, whatever N#'s is).
proc nsSizeOf*(t: typedesc[int8 | uint8 | bool]): int32 = 1
proc nsSizeOf*(t: typedesc[int16 | uint16 | char]): int32 = 2
proc nsSizeOf*(t: typedesc[int32 | uint32 | float32]): int32 = 4
proc nsSizeOf*(t: typedesc[int64 | uint64 | float]): int32 = 8

# --- boxing -----------------------------------------------------------------
#
# C# stores a value type in an `object` by boxing it. `object` is `RootRef` here,
# so a box is a `RootObj` holding the value, and what C# asks of any object --
# `ToString`, `Equals`, `GetHashCode`, `GetType` -- dispatches on the box to procs
# made for its element type. `(int)o` unboxes, and throws `InvalidCastException`
# (Nim's `ObjectConversionDefect`) when the box holds another type, as C# does.

type
  NsBoxed* = ref object of RootObj
    nsStr: proc (b: NsBoxed): string {.nimcall.}
    nsEq: proc (a: NsBoxed; b: RootRef): bool {.nimcall.}
    nsHash: proc (b: NsBoxed): int32 {.nimcall.}
    nsType: string
  NsBox*[T] = ref object of NsBoxed
    v*: T

proc nsBoxStr[T](b: NsBoxed): string = $NsBox[T](b).v
proc nsBoxEq[T](a: NsBoxed; b: RootRef): bool =
  ## Two boxes are equal when they hold equal values of one type.
  b != nil and b of NsBox[T] and NsBox[T](a).v == NsBox[T](b).v
proc nsBoxHash[T](b: NsBoxed): int32 = int32(hash(NsBox[T](b).v) and 0x7fffffff)

proc nsBoxOf[T](x: T): RootRef =
  var name = ""
  when compiles(nsTypeOf(T)): name = nsTypeOf(T).nsFull
  NsBox[T](v: x, nsStr: nsBoxStr[T], nsEq: nsBoxEq[T], nsHash: nsBoxHash[T],
           nsType: name)

proc nsBox*(x: RootRef): RootRef {.inline.} = x
  ## A reference is already an object.
proc nsBox*(x: int): RootRef = nsBoxOf(int32(x))
  ## An untyped integer literal is a C# `int`.
proc nsBox*[T: not RootRef and not int](x: T): RootRef = nsBoxOf(x)

method ToString*(b: NsBoxed): string = b.nsStr(b)
method nsTypeName*(b: NsBoxed): string = b.nsType
proc nsBoxEquals*(a: NsBoxed; b: RootRef): bool = a.nsEq(a, b)
proc nsBoxHash*(a: NsBoxed): int32 = a.nsHash(a)

proc nsUnbox*[T](o: RootRef; t: typedesc[T]): T =
  ## `(T)o`: the boxed value, which must be exactly a `T`.
  when T is RootRef:
    if o != nil and not (o of T):
      raise newException(ObjectConversionDefect, "Specified cast is not valid.")
    T(o)
  else:
    if o == nil:
      raise newException(NilAccessDefect, "Object reference not set to an instance of an object.")
    if not (o of NsBox[T]):
      raise newException(ObjectConversionDefect, "Specified cast is not valid.")
    NsBox[T](o).v

proc nsIsType*[T](o: RootRef; t: typedesc[T]): bool =
  ## `o is T`: a reference of that class, or a box of that value type.
  when T is RootRef: o != nil and o of T
  else: o != nil and o of NsBox[T]

# --- multi-dimensional arrays ---------------------------------------------------
#
# `T[,]` is a reference, as a C# array is: the lengths and the elements in
# row-major order, which is also the order `foreach` visits them in. An index out
# of a dimension's range throws `IndexOutOfRangeException` (Nim's `IndexDefect`).

type
  NsMdBase* = ref object of RootObj
    nsName: string    ## `System.Int32[,]`, what C# prints for the array
  NsMdArray*[T] = ref object of NsMdBase
    nsDims: seq[int]
    nsData: seq[T]

proc nsMdName[T](rank: int): string =
  var name = "System.Object"
  when compiles(nsTypeOf(T)): name = nsTypeOf(T).nsFull
  name & "[" & repeat(',', rank - 1) & "]"

method ToString*(a: NsMdBase): string = a.nsName
method nsTypeName*(a: NsMdBase): string = a.nsName

proc nsNewMd*[T](t: typedesc[T]; dims: varargs[int]): NsMdArray[T] =
  var n = 1
  for d in dims:
    if d < 0: raise newException(OverflowDefect, "Arithmetic operation resulted in an overflow.")
    n *= d
  NsMdArray[T](nsDims: @dims, nsData: newSeq[T](n), nsName: nsMdName[T](dims.len))

proc nsMdOf*[T](data: seq[T]; dims: seq[int]): NsMdArray[T] =
  NsMdArray[T](nsDims: dims, nsData: data, nsName: nsMdName[T](dims.len))

proc nsFlat[T](a: NsMdArray[T]; idx: openArray[int]): int =
  if a == nil: raise newException(NilAccessDefect, "Object reference not set to an instance of an object.")
  if idx.len != a.nsDims.len: raise newException(IndexDefect, "Index was outside the bounds of the array.")
  for k, i in idx:
    if i < 0 or i >= a.nsDims[k]:
      raise newException(IndexDefect, "Index was outside the bounds of the array.")
    result = result * a.nsDims[k] + i

proc `[]`*[T](a: NsMdArray[T]; i, j: SomeInteger): var T =
  a.nsData[a.nsFlat([int(i), int(j)])]
proc `[]`*[T](a: NsMdArray[T]; i, j, k: SomeInteger): var T =
  a.nsData[a.nsFlat([int(i), int(j), int(k)])]
proc `[]=`*[T](a: NsMdArray[T]; i, j: SomeInteger; v: T) =
  a.nsData[a.nsFlat([int(i), int(j)])] = v
proc `[]=`*[T](a: NsMdArray[T]; i, j, k: SomeInteger; v: T) =
  a.nsData[a.nsFlat([int(i), int(j), int(k)])] = v

proc len*[T](a: NsMdArray[T]): int = a.nsData.len
  ## `Length`: every element, across the dimensions.
proc Length*[T](a: NsMdArray[T]): int32 = int32(a.nsData.len)
proc Rank*[T](a: NsMdArray[T]): int32 = int32(a.nsDims.len)
proc GetLength*[T](a: NsMdArray[T]; d: SomeInteger): int32 =
  if d < 0 or int(d) >= a.nsDims.len:
    raise newException(IndexDefect, "Index was outside the bounds of the array.")
  int32(a.nsDims[d])
proc GetUpperBound*[T](a: NsMdArray[T]; d: SomeInteger): int32 = a.GetLength(d) - 1
proc GetLowerBound*[T](a: NsMdArray[T]; d: SomeInteger): int32 = 0
iterator items*[T](a: NsMdArray[T]): T =
  for x in a.nsData: yield x

# --- variance -----------------------------------------------------------------

proc nsVariant*[A, B](x: A; t: typedesc[B]): B =
  ## `IProducer<Cat>` as `IProducer<Animal>`, `Func<Cat>` as `Func<Animal>`: C#
  ## allows these only over reference type arguments, which Nim represents alike,
  ## so the value is reread as the other instantiation (and copied as one, which
  ## keeps the reference counts right).
  static: doAssert sizeof(A) == sizeof(B)
  cast[ptr B](unsafeAddr x)[]
