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

proc nsNilFail*() {.noinline, noreturn.} =
  raise newException(NilAccessDefect, "attempt to access a nil address")

template nsCheckNil*(x: untyped): untyped =
  ## C# throws when a method is called on a nil receiver even if the body never
  ## touches `self`. A dereference check cannot see that, so the receiver is tested
  ## at the call. `desugar.nim` emits this around a dot-called class receiver that
  ## is not a plain variable (`list[i].M()`); `x` is evaluated once, into a
  ## variable that owns nothing, so no reference is counted when `x` lends it (a
  ## temporary `x` makes is destroyed with the statement, as it would be anyway).
  (let nsR {.cursor.} = x; (if nsR == nil: nsNilFail()); nsR)

template nsCheckNilVar*(x: untyped): untyped =
  ## `nsCheckNil` for a receiver that is a variable: read twice rather than
  ## copied, so the check costs no reference count, and the throw is out of line.
  (if x == nil: nsNilFail()
   x)

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

# A delegate is a Nim closure. `d += h` makes a closure that calls each delegate of
# an invocation list, flattened so that it never holds another combined one; `d -= h`
# needs that list back, so a combined closure answers it when called while
# `nsMultiQuery` is set. Only closures `nsCombine` made are ever called that way:
# they are told apart by their proc, one per place `nsCombine` is expanded.
var nsMultiQuery* {.threadvar.}: bool

proc nsMultiSlot*[D](): var seq[D] =
  var slot {.global.}: seq[D]
  slot

proc nsMultiProcs*[D](): var seq[pointer] =
  var procs {.global.}: seq[pointer]
  procs

proc nsRawProc*[D](f: D): pointer =
  ## The proc behind a closure, or nil for a proc type `rawProc` does not take.
  when compiles(rawProc(f)): rawProc(f)
  else: cast[pointer](f)

proc nsMarkMulti*[D](f: D) =
  let p = nsRawProc(f)
  if p notin nsMultiProcs[D](): nsMultiProcs[D]().add p

proc nsDelegateParams(t: NimNode): (NimNode, seq[NimNode], seq[NimNode]) =
  ## A delegate type's return type, and for each parameter a fresh name and type.
  let fp = getTypeImpl(t)[0]
  var names, types: seq[NimNode]
  var k = 0
  for i in 1 ..< fp.len:
    let d = fp[i]
    for j in 0 ..< d.len - 2:
      names.add ident("nsArg" & $k)
      types.add d[^2]
      inc k
  (fp[0], names, types)

macro nsQueryList(d: typed): untyped =
  ## Calls combined delegate `d` with default arguments: in query mode it only
  ## records its list.
  let (ret, names, types) = nsDelegateParams(d)
  result = newStmtList()
  for i, t in types:
    result.add newNimNode(nnkVarSection).add(newIdentDefs(names[i], t))
  let call = newCall(d, names)
  result.add(if ret.kind == nnkEmpty: call else: newNimNode(nnkDiscardStmt).add(call))
  result = newBlockStmt(result)

template nsListOf*(d: typed): untyped =
  ## The invocation list of `d`: none for null, itself for a single delegate.
  block:
    let nsX = d
    var nsR: seq[typeof(nsX)]
    if nsX != nil:
      if nsRawProc(nsX) in nsMultiProcs[typeof(nsX)]():
        nsMultiQuery = true
        nsQueryList(nsX)
        nsMultiQuery = false
        nsR = move nsMultiSlot[typeof(nsX)]()
      else:
        nsR = @[nsX]
    nsR

macro nsCombine*(a, b: typed): untyped =
  ## `a + b` for delegates (`d += h`): a delegate calling `a`'s list and then
  ## `b`'s, answering the last one's result; a null side is the other one.
  let (ret, names, types) = nsDelegateParams(a)
  var params = newNimNode(nnkFormalParams)
  params.add ret
  for i, nm in names: params.add newIdentDefs(nm, types[i])
  let na = genSym(nskLet, "nsA")
  let nb = genSym(nskLet, "nsB")
  let nl = genSym(nskLet, "nsL")
  let i = genSym(nskForVar, "nsI")
  let each = newCall(newNimNode(nnkBracketExpr).add(nl, i), names)
  let last = newCall(newNimNode(nnkBracketExpr).add(nl,
    newNimNode(nnkPrefix).add(ident"^", newLit(1))), names)
  let query = quote do:
    if nsMultiQuery:
      nsMultiSlot[typeof(`na`)]() = `nl`
      return
  let loop = quote do:
    for `i` in 0 ..< `nl`.len - 1: `each`
  if ret.kind != nnkEmpty:
    loop[^1] = newStmtList(newNimNode(nnkDiscardStmt).add(each))
  let lam = newProc(newEmptyNode(), [], newStmtList(query, loop, last), nnkLambda)
  lam[3] = params
  lam[4] = newNimNode(nnkPragma).add(ident"closure")
  let f = genSym(nskLet, "nsF")
  result = quote do:
    (block:
      let `na` = `a`
      let `nb`: typeof(`na`) = `b`
      let `nl` = nsListOf(`na`) & nsListOf(`nb`)
      if `nl`.len == 0: typeof(`na`)(nil)
      elif `nl`.len == 1: `nl`[0]
      else:
        let `f`: typeof(`na`) = `lam`
        nsMarkMulti(`f`)
        `f`)

proc nsWithout*[D](la, lb: seq[D]): seq[D] =
  ## `la` without the last run of delegates equal to `lb`, as C#'s `Delegate.Remove`
  ## takes it out; `la` itself when it holds no such run.
  result = la
  if lb.len == 0 or lb.len > la.len: return
  for i in countdown(la.len - lb.len, 0):
    if la[i ..< i + lb.len] == lb:
      return la[0 ..< i] & la[i + lb.len .. ^1]

macro nsRemove*(a, b: typed): untyped =
  ## `a - b` for delegates (`d -= h`): the delegate of the list that remains.
  let r = genSym(nskVar, "nsR")
  let x = genSym(nskForVar, "nsX")
  result = quote do:
    (block:
      var `r`: typeof(`a`) = nil
      for `x` in nsWithout(nsListOf(`a`), nsListOf(`b`)): `r` = nsCombine(`r`, `x`)
      `r`)

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

method Equals*(a, b: RootRef): bool {.base.} = a == b
  ## `object.Equals`: the reference, unless a class overrides it.
method GetHashCode*(x: RootRef): int32 {.base.} =
  ## `object.GetHashCode`: the reference's address, folded to 32 bits.
  cast[int32](cast[int](x) xor (cast[int](x) shr 32))
method Equals*(a: NsBoxed; b: RootRef): bool = a.nsEq(a, b)
  ## A boxed value is equal to a box of an equal value (see `NsBox`).
method GetHashCode*(x: NsBoxed): int32 = x.nsHash(x)

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

# --- arrays -------------------------------------------------------------------
#
# `T[]` is a reference, as a C# array is: assigning or passing one shares it, and
# `null` is an array too. The elements are a `seq`, which the array never resizes.
# An index out of range throws `IndexOutOfRangeException` (Nim's `IndexDefect`), a
# null array `NullReferenceException`.

type
  NsArrayBase* = ref object of RootObj
    nsName: proc (): string {.nimcall.}  ## `System.Int32[]`, what C# prints
  NsArray*[T] = ref object of NsArrayBase
    nsData*: seq[T]

proc nsArrayName[T](): string {.nimcall.} =
  mixin nsTypeOf
  var name = "System.Object"
  when compiles(nsTypeOf(T)): name = nsTypeOf(T).nsFull
  name & "[]"

method ToString*(a: NsArrayBase): string = a.nsName()
method nsTypeName*(a: NsArrayBase): string = a.nsName()

proc nsArrayOf*[T](data: sink seq[T]): NsArray[T] {.inline.} =
  ## The array holding `data`: an array literal, or a library result.
  NsArray[T](nsData: data, nsName: nsArrayName[T])

proc nsNewArray*[T](t: typedesc[T]; n: SomeInteger): NsArray[T] =
  ## `new T[n]`: `n` default elements.
  if n < 0: raise newException(OverflowDefect, "Arithmetic operation resulted in an overflow.")
  nsArrayOf(newSeq[T](int(n)))

template nsArrCheck(a: untyped) =
  ## The null test C# makes at every access to an array.
  when not defined(danger):
    if a == nil: nsNilFail()

proc `[]`*[T](a: NsArray[T]; i: SomeInteger): var T {.inline.} =
  nsArrCheck(a)
  a.nsData[int(i)]
proc `[]=`*[T](a: NsArray[T]; i: SomeInteger; v: sink T) {.inline.} =
  nsArrCheck(a)
  a.nsData[int(i)] = v
proc `[]`*[T](a: NsArray[T]; i: BackwardsIndex): var T {.inline.} =
  nsArrCheck(a)
  a.nsData[i]
proc `[]=`*[T](a: NsArray[T]; i: BackwardsIndex; v: sink T) {.inline.} =
  nsArrCheck(a)
  a.nsData[i] = v
proc `[]`*[T; U, V: Ordinal | BackwardsIndex](a: NsArray[T]; r: HSlice[U, V]): NsArray[T] =
  ## `a[1..^1]`: a new array of those elements, as C# copies a range.
  nsArrCheck(a)
  nsArrayOf(a.nsData[r])
proc len*[T](a: NsArray[T]): int {.inline.} =
  nsArrCheck(a)
  a.nsData.len
proc high*[T](a: NsArray[T]): int {.inline.} = a.len - 1

template nsForBound*(i, a: untyped; cond: bool): bool =
  ## A counted loop's condition (`i < a.Length`), marked for the lowering's own
  ## bounds-check removal; a marker it leaves is the condition.
  cond

{.push boundChecks: off.}
proc nsAtUnchecked*[T](a: NsArray[T]; i: SomeInteger): var T {.inline.} =
  ## `a[i]` in a loop that keeps `0 <= i < a.Length` and the array: neither the
  ## null test (the condition made it) nor the bounds check.
  a.nsData[int(i)]
{.pop.}

iterator items*[T](a: NsArray[T]): T =
  nsArrCheck(a)
  for x in a.nsData: yield x
iterator mitems*[T](a: NsArray[T]): var T =
  nsArrCheck(a)
  for x in a.nsData.mitems: yield x
iterator pairs*[T](a: NsArray[T]): (int, T) =
  nsArrCheck(a)
  for i, x in a.nsData: yield (i, x)

template nsElemRef*(x: untyped): untyped =
  ## `ref a[i]`: the element as a location of its own, which a `ref` return or
  ## a `ref` local may keep while the array lives.
  cast[ptr typeof(x)](addr x)[]

proc nsArrayFrom*[T](xs: openArray[T]): NsArray[T] = nsArrayOf(@xs)
  ## A copy of `xs` as an array: `params` elements, a library collection's.

proc nsCommandLine*(): NsArray[string] =
  ## `Main`'s `string[] args`: the command line without the program's name.
  nsArrayOf(commandLineParams())

# --- variance -----------------------------------------------------------------

proc nsVariant*[A, B](x: A; t: typedesc[B]): B =
  ## `IProducer<Cat>` as `IProducer<Animal>`, `Func<Cat>` as `Func<Animal>`: C#
  ## allows these only over reference type arguments, which Nim represents alike,
  ## so the value is reread as the other instantiation (and copied as one, which
  ## keeps the reference counts right).
  static: doAssert sizeof(A) == sizeof(B)
  cast[ptr B](unsafeAddr x)[]

# --- `typeof` of constructed types ---------------------------------------------

proc nsGenericName*(base: string; args: varargs[string]): string =
  ## .NET's name of a constructed generic type: ``System.Collections.Generic.List`1[System.Int32]``.
  base & "`" & $args.len & "[" & args.join(",") & "]"

proc nsTypeOf*[T](t: typedesc[NsArray[T]]): Type = nsTypeNamed(nsArrayName[T]())
  ## `typeof(int[])` is `System.Int32[]`.
proc nsTypeOf*[T](t: typedesc[NsMdArray[T]]): Type = nsTypeNamed(nsMdName[T](2))
  ## `typeof(int[,])`; a rank above 2 is not told apart by the type.

# --- type tests against generic interfaces ------------------------------------
#
# `o is IBox<int>`: every class implementing an instantiation of a generic
# interface overrides `nsVtByKey`, answering that instantiation's table by its
# type's name, and passing any other key to its base class.

import std/typetraits

method nsVtByKey*(x: RootRef; key: string): pointer {.base.} = nil

proc nsKeyOf*(t: typedesc): string = name(t)

proc nsIfaceObject*[I: object](v: I): RootRef {.inline.} =
  ## An interface value used as an `object`: the instance it holds (null for none).
  v.nsObj

proc nsAsByKey*[I](o: RootRef; t: typedesc[I]): I =
  ## The interface value of `o`, or the empty one when its class does not
  ## implement `I`. A library interface may answer for objects it knows by type
  ## (`nsLibAs`: an `int[]` is an `IList<int>`).
  mixin nsLibAs
  when compiles(nsLibAs(o, t)):
    result = nsLibAs(o, t)
    if result.nsObj != nil: return
  if o != nil:
    let p = nsVtByKey(o, nsKeyOf(I))
    if p != nil:
      result.nsObj = o
      result.nsVt = cast[typeof(result.nsVt)](p)

# --- native C++ handles ----------------------------------------------------------
#
# A `[Native(Handle = "Ns::Id<{0}>")]` class is held through that handle: the
# compiler declares the handle type (`NsH_<Class>[T]`, `T` the C++ class) and
# instantiates these over it. A handle reads as `null` when the engine says it
# is invalid; using one throws `NullReferenceException`, as a null reference
# does in C#, unless checks are off (`-d:danger`).

template nsHandleProcs*(H, R: untyped; hdr, validPat, nullPat, derefPat: untyped) =
  ## A handle family's helpers: `validPat` tests a handle (`static_cast<bool>(#)`,
  ## or the binding's `Valid`), `nullPat` makes the invalid one, with `'1` the
  ## class, and `derefPat` reaches the object (`#.operator->()`, or `Deref`).
  proc nsRawDeref[T](h: H[T]): ptr T {.importcpp: derefPat, header: hdr.}
  proc nsValid*[T](h: H[T]): bool {.importcpp: validPat, header: hdr, inject.}
  proc nsNullOf[T](t: typedesc[T]; h: typedesc[H[T]]): H[T] {.importcpp: nullPat, header: hdr.}
    ## `h` keeps one family's from being taken for another's.
  proc nsDeref*[T](h: H[T]): ptr T {.inline, inject.} =
    when not defined(danger):
      if not nsValid(h): nsNilFail()
    nsRawDeref(h)
  proc nsAs*[T, U](h: H[U]; t: typedesc[H[T]]): H[T] {.importcpp: "'0(#)", header: hdr, inject.}
    ## The handle as one of another class of its family: an upcast, or a downcast
    ## the engine may check.
  proc nsNull*[T](t: typedesc[H[T]]): H[T] {.inline, inject.} =
    ## The invalid handle, C#'s `null`.
    nsNullOf(T, H[T])
  converter nsToRoot*[U](h: H[U]): H[R] {.inject.} = nsAs(h, H[R])
    ## Any handle of the family is one of its root class: an upcast C# makes
    ## implicitly, which a library call (`List<Node>.Add(coin)`) relies on.

proc nsDerefCached*[H, T](h: H; p: var ptr T): ptr T {.inline.} =
  ## The object a handle local reaches, resolved once and kept in `p` until a
  ## statement that may move engine objects clears it (desugar's handle hoisting).
  mixin nsDeref
  if p.isNil: p = nsDeref(h)
  p

# --- managed fields of native-derived classes ------------------------------------
#
# A field of a class deriving a native C++ class, whose type Nim manages, is an
# `NsField[T]` (nsfield.hpp): C++ copies, moves and destroys it through Nim's
# hooks for `T`, which `nsUseField(T)` registers when the module starts. Nim sees
# no managed content in it, so it never manages the struct a second time.

when defined(cpp):
  # Guarded so a C build keeps compiling this module as C.
  type
    NsField*[T] {.importcpp: "NsField<'0>", header: "pure/nsharp/nsfield.hpp".} = object

  proc nsVal*[T](f: var NsField[T]): var T {.inline.} =
    ## The value, to read or assign: `NsField<T>`'s only member, so at its address.
    ## A Nim proc rather than an `importcpp` one, whose `var` result C++ would hold
    ## as a reference that an inlined iterator cannot declare before assigning it.
    cast[ptr T](addr f)[]

  type NsFwd*[T] {.importcpp: "'0".} = object
    ## A `[Forward]` argument: the value as it is, which a C `varargs` call would
    ## otherwise pass a `string` to as a `cstring`.
  proc nsFwd*[T](x: T): NsFwd[T] {.importcpp: "#".}

  proc nsFieldDestroy[T](p: ptr T) {.cdecl.} = `=destroy`(p[])
  proc nsFieldCopy[T](d: ptr T; s: ptr T) {.cdecl.} = d[] = s[]
  proc nsSetHooks[T](t: typedesc[T]; d: proc (p: ptr T) {.cdecl.};
                     c: proc (d, s: ptr T) {.cdecl.}) {.
    importcpp: "NsHooks<'1>::Set(@)",
    header: "pure/nsharp/nsfield.hpp".}

  template nsUseField*(T: typedesc) =
    ## Registers Nim's hooks for a field type, before the engine creates an object.
    nsSetHooks(T, nsFieldDestroy[T], nsFieldCopy[T])

  proc nsOnUnhandled(where, message, kind: cstring) {.exportc: "nsOnUnhandled", cdecl,
      codegenDecl: "extern \"C\" __attribute__((weak)) $1 $2$3".} =
    ## What happens to an exception that would escape into C++ (`nsEscaped`): this
    ## default reports it and stops the program. It is a weak symbol, so an engine
    ## defining `extern "C" void nsOnUnhandled(const char* where, const char*
    ## message, const char* type)` replaces it -- to log through its own console,
    ## break into a debugger, or return, in which case the C++ entry point returns
    ## its default result and the program goes on.
    writeLine(stderr, "Unhandled exception in " & $where & ": " & $message & " [" & $kind & "]")
    quit(1)

  proc nsEscaped*(where: string) =
    ## An exception reached a place C++ entered N# (`where`: `Class.Member`): C++
    ## cannot see it, so it is handed to `nsOnUnhandled` and goes no further.
    let e = getCurrentException()
    nsOnUnhandled(cstring(where), cstring(e.msg), e.name)

  # --- native objects N# owns --------------------------------------------------------
  #
  # A class of a native family with no `Handle` is held through `NsH_<Root>[T]`
  # (declared by the binding's lowering): a pointer to the object, and the box
  # keeping it alive when N# made it (nil when C++ lent it). `new C(...)` makes
  # the box, a Nim `ref` whose storage the C++ constructor runs in (placement
  # new), and whose destruction runs the C++ destructor (nsobj.hpp).

  type
    NsBoxBase* = object of RootObj
    NsStorage*[T] {.importcpp: "NsStorage<'0>", header: "pure/nsharp/nsobj.hpp".} = object
    NsObjBox*[T] = object of NsBoxBase
      v: NsStorage[T]
    NsOwner* {.importcpp: "NsOwner", header: "pure/nsharp/nsobj.hpp".} = object
      ## The box of an object of an N# class deriving a native one, which `this`
      ## keeps alive; a copy C++ makes has none.
      box*: pointer
    NsPass*[R] {.importcpp: "NsPass<'0>", header: "pure/nsharp/nsobj.hpp".} = object
      ## An N# reference passed to C++, which becomes the pointer or reference the
      ## parameter is.

  proc nsStorageAt[T](s: NsStorage[T]): ptr T {.importcpp: "#.get()",
    header: "pure/nsharp/nsobj.hpp".}
  proc nsDestroyAt[T](p: ptr T) {.importcpp: "nsDestroyAt(#)",
    header: "pure/nsharp/nsobj.hpp".}
  proc `=destroy`*[T](b: NsObjBox[T]) =
    nsDestroyAt(nsStorageAt(b.v))
  proc `=copy`*[T](d: var NsObjBox[T]; s: NsObjBox[T]) {.error.}

  proc nsNewBox*[T](t: typedesc[T]): ref NsObjBox[T] {.inline.} =
    ## A box for a `T`, which the caller constructs at `nsAt` before anything
    ## else can drop it.
    new(result)
  proc nsAt*[T](b: ref NsObjBox[T]): ptr T {.inline.} = nsStorageAt(b.v)

  type NsHeapBox*[T] = object of NsBoxBase
    ## An object C++ made with `new` and handed over (`[return: Owned]`), which N#
    ## deletes when the last reference goes.
    p*: ptr T
  proc nsDelete[T](p: ptr T) {.importcpp: "delete #".}
  proc `=destroy`*[T](b: NsHeapBox[T]) =
    if b.p != nil: nsDelete(b.p)
  proc `=copy`*[T](d: var NsHeapBox[T]; s: NsHeapBox[T]) {.error.}

  proc nsUnconst*[T](p: ptr T): ptr T {.importcpp: "const_cast<'0>(#)".}
    ## `this` in a `const` member function, as the N# body it runs takes it.
  proc nsPtrAs*[T, U](p: ptr U; t: typedesc[T]): ptr T {.importcpp: "static_cast<'0>(#)".}
    ## A pointer as one to another class of its family.
  proc nsPassOf*[R](p: ptr R): NsPass[R] {.importcpp: "NsPass<'*1>{#}",
    header: "pure/nsharp/nsobj.hpp".}

  proc nsKeepOf*(box: pointer): ref NsBoxBase {.inline.} =
    ## The box an `NsOwner` records, as a reference of its own: assigning from the
    ## cast counts it, as a copy does.
    if box != nil:
      result = cast[ref NsBoxBase](box)

  template nsObjProcs*(H, R: untyped) =
    ## The helpers of a family N# may own: `H[T]` is its reference type and `R` its
    ## root class. They mirror `nsHandleProcs`, so lowering treats both alike.
    proc nsValid*[T](h: H[T]): bool {.inline, inject.} = h.p != nil
    proc nsDeref*[T](h: H[T]): ptr T {.inline, inject.} =
      when not defined(danger):
        if h.p == nil: nsNilFail()
      h.p
    proc nsAs*[T, U](h: H[U]; t: typedesc[H[T]]): H[T] {.inline, inject.} =
      ## As one of another class of the family: an upcast, or a downcast C++
      ## does not check.
      H[T](p: nsPtrAs(h.p, T), keep: h.keep)
    proc nsNull*[T](t: typedesc[H[T]]): H[T] {.inline, inject.} = H[T]()
    proc `==`*[T, U](a: H[T]; b: H[U]): bool {.inline, inject.} =
      ## Identity, compared as the root class.
      nsPtrAs(a.p, R) == nsPtrAs(b.p, R)
    proc nsMake*[T](t: typedesc[H[T]]; b: ref NsObjBox[T]): H[T] {.inline, inject.} =
      ## The reference to an object N# just made in `b`.
      H[T](p: nsAt(b), keep: b)
    proc nsSelfObj*[T](t: typedesc[H[T]]; p: ptr T; box: pointer): H[T] {.inline, inject.} =
      ## `this` as a value: kept alive by its box when N# made it, lent otherwise.
      H[T](p: p, keep: nsKeepOf(box))
    proc nsBorrow*[T](t: typedesc[H[T]]; p: ptr T): H[T] {.inline, inject.} =
      ## An object C++ lends (`[return: Borrowed]`): nothing keeps it alive.
      H[T](p: p)
    proc nsAdopt*[T](t: typedesc[H[T]]; p: ptr T): H[T] {.inline, inject.} =
      ## An object C++ hands over (`[return: Owned]`), deleted with the last reference.
      if p != nil:
        let b = (ref NsHeapBox[T])(p: p)
        result = H[T](p: p, keep: b)
    proc nsAdoptPtr*[T](t: typedesc[H[T]]; p: pointer): H[T] {.inline, inject.} =
      ## `nsAdopt` of what a `[Forward]` factory returns.
      nsAdopt(H[T], cast[ptr T](p))
    proc nsBorrowPtr*[T](t: typedesc[H[T]]; p: pointer): H[T] {.inline, inject.} =
      nsBorrow(H[T], cast[ptr T](p))
    converter nsToRoot*[U](h: H[U]): H[R] {.inject.} = nsAs(h, H[R])
    converter nsToPass*[U](h: H[U]): NsPass[R] {.inject.} = nsPassOf(nsPtrAs(h.p, R))

  proc nsCopyCStr(dest: pointer; p: cstring; len: int64) {.exportc: "nsCopyCStr", cdecl,
      codegenDecl: "extern \"C\" $1 $2$3".} =
    ## A C string C++ returns, copied into the N# string at `dest` (nsobj.hpp).
    var s = newString(len)
    if len > 0: copyMem(addr s[0], p, len)
    cast[ptr string](dest)[] = s
