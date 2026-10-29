# N# intrinsics
#
# Imported into every compiled module, because C# needs no `using` for these:
# `"a" + b` concatenates anywhere, and any type can be printed.
#
# `$` is the one stringifier, and an object renders the way Nim renders a value of
# its type, so a class reads as its fields. A primitive keeps Nim's own rendering,
# which is why a bool reads `true` here and `True` in C#.

import format
from pragmas import nsHidden, nsFrame
export nsFrame
export format
import std/strutils
import std/hashes
from std/cmdline import paramStr
export hashes

# --- System.Type -----------------------------------------------------------------
#
# A type is known by its name, as `ToString()` writes it (``List`1[System.Int32]``),
# and by its assembly; `FullName` qualifies each generic argument with the
# argument's assembly, as .NET does, and is made once per `Type`.

const
  nsCoreLib* = "System.Private.CoreLib, Version=10.0.0.0, Culture=neutral, PublicKeyToken=7cec85d7bea7798e"
    ## .NET 10's core library: the built-in types and most of the library's.
  nsCollectionsLib* = "System.Collections, Version=10.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a"
    ## The collections .NET moved out of the core library (`Stack<T>`, `SortedSet<T>`...).

type
  Type* = ref object of RootObj
    ## C#'s `System.Type`.
    nsFull: string   ## the display name
    nsQual: string   ## `FullName`, once made ("" before)
    nsAsm: string    ## the assembly; "" for the program's own, or a library one named `System.*`
    nsArgs: seq[Type] ## a constructed generic type's arguments, for `FullName`

var nsProgramAsm = ""
proc nsProgramAssembly(): string =
  ## The assembly a program's own types are in, as .NET names it: the program's
  ## name (`dotnet` names the assembly after the project), version 1.0.0.0.
  if nsProgramAsm.len == 0:
    var name = $paramStr(0)
    let slash = name.rfind('/')
    if slash >= 0: name = name[slash + 1 .. ^1]
    if name.endsWith(".exe"): name.setLen(name.len - 4)
    nsProgramAsm = name & ", Version=1.0.0.0, Culture=neutral, PublicKeyToken=null"
  nsProgramAsm

proc nsTypeNamed*(full: string; assembly = ""): Type {.nsHidden.} = Type(nsFull: full, nsAsm: assembly)
proc nsDisplay*(t: Type): string {.nsHidden.} = t.nsFull
  ## The name as `ToString()` gives it, and generic arguments are written in it:
  ## ``System.Collections.Generic.List`1[System.Int32]``.
proc nsAssembly(t: Type): string =
  if t.nsAsm.len > 0: t.nsAsm
  elif t.nsFull.startsWith("System."): nsCoreLib
  else: nsProgramAssembly()

proc nsQualified(display: string): string =
  ## `FullName` from a display name alone (a type the program names only by its
  ## `nsTypeName`): each generic argument qualified by where its name says it is.
  let tick = display.find('`')
  if tick < 0: return display
  let open = display.find('[', tick)
  if open < 0: return display
  var args: seq[string] = @[]
  var depth = 0
  var start = open + 1
  var close = -1
  for i in open ..< display.len:
    case display[i]
    of '[': inc depth
    of ']':
      dec depth
      if depth == 0:
        close = i
        break
    of ',':
      if depth == 1:
        args.add display[start ..< i]
        start = i + 1
    else: discard
  if close < 0: return display
  args.add display[start ..< close]
  result = display[0 .. open]
  for k, a in args:
    if k > 0: result.add ','
    result.add '[' & nsQualified(a) & ", " & nsTypeNamed(a).nsAssembly & ']'
  result.add display[close .. ^1]

proc FullName*(t: Type): string =
  ## Made on first use, so a program that never asks pays nothing (and a host
  ## without a `main` never needs the program's name).
  if t.nsQual.len == 0:
    if t.nsArgs.len == 0: t.nsQual = nsQualified(t.nsFull)
    else:
      var qual = t.nsFull[0 .. t.nsFull.find('[')]
      for i, a in t.nsArgs:
        if i > 0: qual.add ','
        qual.add '[' & a.FullName & ", " & a.nsAssembly & ']'
      qual.add ']'
      t.nsQual = qual
  t.nsQual

proc nsGenericType*(base, assembly: string; args: varargs[Type]): Type {.nsHidden.} =
  ## A constructed generic type, ``System.Collections.Generic.List`1[System.Int32]``,
  ## from its arguments' types, which say their own assemblies.
  var display = base & "`" & $args.len & "["
  for i, a in args:
    if i > 0: display.add ','
    display.add a.nsFull
  display.add ']'
  Type(nsFull: display, nsAsm: assembly, nsArgs: @args)

proc Namespace*(t: Type): string =
  ## What comes before the type's own name, its generic arguments aside.
  var base = t.nsFull
  for stop in ['`', '[']:
    let i = base.find(stop)
    if i >= 0: base.setLen(i)
  let i = base.rfind('.')
  if i >= 0: base[0 ..< i] else: ""

method nsTypeName*(x: RootRef): string {.nsHidden, base.} = "System.Object"
  ## The dynamic type's name, which every class N# lowers, and each class of the
  ## library, overrides.
method nsDynType*(x: RootRef): Type {.nsHidden, base.} = nsTypeNamed(x.nsTypeName)
  ## `GetType()` of a class value: a generic class overrides it to say its type
  ## arguments' assemblies too.

var nsExceptionName*: proc (e: ref Exception): string {.nimcall.} = nil
  ## An exception's .NET type name, which `System` knows (see its
  ## `nsExceptionTypeName`). An exception type takes no method: the defects .NET's
  ## exceptions alias are declared in Nim's `system`, whose types cannot.

type
  NsExceptionState* = ref object of RootObj
    ## What a .NET exception holds beyond Nim's: `Source`, `HelpLink`, `HResult`,
    ## `Data`, an argument exception's parameter and value, a disposed object's
    ## name, and an `AggregateException`'s inner exceptions. Made the first time
    ## one is set, and kept in `system`'s `Exception.nsExtra`, which N# programs
    ## have.
    source*, helpLink*: string
    hasSource*, hasHelpLink*, hasHResult*: bool
    hresult*: int32
    data*: RootRef            ## `System.Collections.IDictionary`, made when first read
    paramName*: string
    actualValue*: RootRef
    objectName*: string
    fileName*: string             ## a `FileNotFoundException`'s
    inners*: seq[ref Exception]   ## an `AggregateException`'s, its first the inner one
    rawMessage*: string           ## an `AggregateException`'s message before theirs

proc nsState*(e: ref Exception): NsExceptionState {.nsHidden.} =
  ## The exception's own state, made the first time it is asked for.
  when compiles(e.nsExtra):
    if e.nsExtra.isNil: e.nsExtra = NsExceptionState()
    NsExceptionState(e.nsExtra)
  else:
    {.error: "N#'s exceptions keep their state in `Exception.nsExtra`, which " &
             "`system` declares for N# programs (`-d:nsharp`)".}

proc nsStateOrNil*(e: ref Exception): NsExceptionState {.nsHidden.} =
  ## The state, or nil when nothing was ever set: reading needs none made.
  when compiles(e.nsExtra): NsExceptionState(e.nsExtra) else: nil

proc nsProgramName*(): string {.nsHidden.} =
  ## The program's own assembly name, `Source` of what it throws.
  let a = nsProgramAssembly()
  a[0 ..< a.find(',')]

from system/stacktraces import reraisedFromBegin, reraisedFromEnd

proc nsMergeRethrown(trace: var seq[StackTraceEntry]) =
  ## `throw;` raises the exception again, and Nim then appends the stack the
  ## rethrow happened on between two markers. .NET's trace continues from the
  ## rethrowing method outward instead: those outer frames go in front (the trace is
  ## outermost first), and the rethrowing method, which both parts hold, once.
  while true:
    var first = -1
    for i, t in trace:
      if t.line == reraisedFromBegin:
        first = i
        break
    if first < 0: return
    var last = first + 1
    while last < trace.len and trace[last].line != reraisedFromEnd: inc last
    var merged = trace[first + 1 ..< min(last, trace.len)]
    if merged.len > 0: merged.setLen(merged.len - 1)
    merged.add trace[0 ..< first]
    if last + 1 < trace.len: merged.add trace[last + 1 .. ^1]
    trace = merged

proc nsCutTrace*(e: ref Exception) {.nsHidden.} =
  ## A `catch` sees the frames from the throw up to the method catching it, as
  ## .NET's `StackTrace` does, not the whole stack the throw happened on. (The JS
  ## backend keeps a trace as text.)
  when compileOption("stacktrace") and not defined(js):
    if e.trace.len == 0: return
    nsMergeRethrown(e.trace)
    var f = getFrame()
    while f != nil and ($f.filename).endsWith(".nim"): f = f.prev
    if f == nil: return
    var depth = 0
    var g = f
    while g != nil:
      inc depth
      g = g.prev
    ## The catching method is the trace's entry at its own depth.
    if depth >= 1 and depth <= e.trace.len and e.trace[depth - 1].procname == f.procname:
      e.trace = e.trace[depth - 1 .. ^1]

proc nsThrown*(e: ref Exception): ref Exception {.nsHidden.} =
  ## `throw e;` of an exception thrown before: .NET starts its trace again where it
  ## is thrown now, where Nim would keep the old one.
  if e != nil: e.trace.setLen 0
  e

proc nsOwnFrames(entries: seq[StackTraceEntry]): seq[StackTraceEntry] =
  ## The program's own frames of a trace, innermost first: not the library's (a
  ## `.nim` file) or a module's initialisation.
  result = @[]
  for i in countdown(entries.high, 0):
    let t = entries[i]
    let file = $t.filename
    if file.endsWith(".nim") or file.endsWith("/" & $t.procname & ".ns"): continue
    result.add t

proc nsFrames(e: ref Exception): seq[StackTraceEntry] =
  ## An exception's own frames, innermost first, when the build keeps stack traces.
  result = @[]
  when declared(getStackTraceEntries) and not defined(js):
    var entries = e.getStackTraceEntries()
    nsMergeRethrown(entries)
    result = nsOwnFrames(entries)

proc nsFrameText(frames: seq[StackTraceEntry]): string =
  ## `   at Demo.Program.Main() in Program.ns:line 6`, a line per frame.
  result = ""
  for t in frames:
    if result.len > 0: result.add "\n"
    result.add "   at " & $t.procname & " in " & $t.filename
    if t.line > 0: result.add ":line " & $t.line

proc nsCurrentStackTrace*(): string {.nsHidden.} =
  ## `Environment.StackTrace`: the calls the program is in now, innermost first,
  ## after .NET's own frame for reading it.
  result = "   at System.Environment.get_StackTrace()"
  when declared(getStackTraceEntries):
    let text = nsFrameText(nsOwnFrames(getStackTraceEntries()))
    if text.len > 0: result.add "\n" & text

proc nsThrownByLibrary*(e: ref Exception): bool {.nsHidden.} =
  ## Whether the library raised it: its innermost frame is the library's.
  when declared(getStackTraceEntries):
    let entries = e.getStackTraceEntries()
    entries.len > 0 and ($entries[^1].filename).endsWith(".nim")
  else: false

proc nsStackTrace*(e: ref Exception): string {.nsHidden.} =
  ## `Exception.StackTrace`: `   at Demo.Program.Main() in Program.ns:line 6`, a
  ## line per frame, innermost first; null ("") when it was never thrown, or the
  ## build keeps no stack traces.
  nsFrameText(nsFrames(e))

proc nsExceptionText(e: ref Exception): string =
  ## `Exception.ToString()` as .NET writes it: the type and message, the inner
  ## exception's text, then the stack trace; an `AggregateException` adds its other
  ## inner exceptions, numbered.
  result = (if nsExceptionName != nil: nsExceptionName(e) else: "System.Exception")
  if e.msg.len > 0: result.add ": " & e.msg
  if e.parent != nil:
    result.add "\n ---> " & nsExceptionText(e.parent) &
               "\n   --- End of inner exception stack trace ---"
  let trace = nsStackTrace(e)
  if trace.len > 0: result.add "\n" & trace
  let st = nsStateOrNil(e)
  if st != nil:
    for i, x in st.inners:
      if x == e.parent: continue
      result.add "\n ---> (Inner Exception #" & $i & ") " & nsExceptionText(x) & "<---\n"

method ToString*(x: RootRef): string {.base, discardable.} =
  ## `object.ToString()`: an exception's type and message, else the dynamic type's
  ## name. Every class N# compiles overrides it, with a print of its fields or the
  ## user's override, and the library's collections and arrays with their elements,
  ## so this is reached only by a type nothing overrides it for.
  if x of Exception: nsExceptionText((ref Exception)(x))
  else: x.nsDynType.nsDisplay

method ToString*(t: Type): string = t.nsFull
proc nsTypeOf*(t: typedesc[Type]): Type {.nsHidden.} = nsTypeNamed("System.Type")
proc `==`*(a, b: Type): bool =
  if a.isNil or b.isNil: a.isNil and b.isNil else: a.nsFull == b.nsFull

proc ToString*[T: not RootRef](x: T): string {.discardable.} = $x
  ## A value's `ToString()` is its `$`.

# `n.ToString("D2")`: a number in a .NET format, as an interpolation hole's. One
# overload per numeric type, as .NET declares them.
proc ToString*(x: int32; format: string): string {.discardable.} = nsFormatNumber(x, format)
proc ToString*(x: int64; format: string): string {.discardable.} = nsFormatNumber(x, format)
proc ToString*(x: int16; format: string): string {.discardable.} = nsFormatNumber(x, format)
proc ToString*(x: int8; format: string): string {.discardable.} = nsFormatNumber(x, format)
proc ToString*(x: uint32; format: string): string {.discardable.} = nsFormatNumber(x, format)
proc ToString*(x: uint64; format: string): string {.discardable.} = nsFormatNumber(x, format)
proc ToString*(x: uint16; format: string): string {.discardable.} = nsFormatNumber(x, format)
proc ToString*(x: uint8; format: string): string {.discardable.} = nsFormatNumber(x, format)
proc ToString*(x: float; format: string): string {.discardable.} = nsFormatNumber(x, format)
proc ToString*(x: float32; format: string): string {.discardable.} = nsFormatNumber(x, format)

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
#
# The smallest value over `-1` overflows, and .NET throws `OverflowException` for
# both `/` and `%` then, checked or not; the processor would trap on `%`.
template nsStamped*(T: typedesc; message, netName: string): untyped {.nsHidden.} =
  ## An exception N# raises under one of the defects .NET's exceptions alias,
  ## named as .NET names its type. Nim's runtime raises the same defects named as
  ## Nim does, which is how `nsAdoptException` tells them apart.
  (let nsE = newException(T, message); nsE.name = netName; nsE)

proc nsOverflowFail*() {.nsHidden, noinline, noreturn.} =
  raise nsStamped(OverflowDefect, "Arithmetic operation resulted in an overflow.",
                  "System.OverflowException")

proc nsIndexFail*() {.nsHidden, noinline, noreturn.} =
  raise nsStamped(IndexDefect, "Index was outside the bounds of the array.",
                  "System.IndexOutOfRangeException")

proc nsDivOverflow() {.noinline, noreturn.} = nsOverflowFail()

# `checked` integer `+`, `-`, `*` and negation: the C compiler's overflow builtins,
# the test Nim's own `overflowChecks` makes, failing with .NET's message.
when defined(gcc) or defined(clang) or defined(llvm_gcc) or defined(icc):
  proc nsAddOvf[T](a, b: T; r: var T): bool {.importc: "__builtin_add_overflow", nodecl.}
  proc nsSubOvf[T](a, b: T; r: var T): bool {.importc: "__builtin_sub_overflow", nodecl.}
  proc nsMulOvf[T](a, b: T; r: var T): bool {.importc: "__builtin_mul_overflow", nodecl.}

  proc nsCkAdd*[T: SomeInteger](a, b: T): T {.inline.} =
    if nsAddOvf(a, b, result): nsOverflowFail()
  proc nsCkSub*[T: SomeInteger](a, b: T): T {.inline.} =
    if nsSubOvf(a, b, result): nsOverflowFail()
  proc nsCkMul*[T: SomeInteger](a, b: T): T {.inline.} =
    if nsMulOvf(a, b, result): nsOverflowFail()
else:
  ## Another C compiler: Nim's checked arithmetic, whose defect `nsAdoptException` names.
  {.push overflowChecks: on.}
  proc nsCkAdd*[T: SomeInteger](a, b: T): T {.inline.} = a + b
  proc nsCkSub*[T: SomeInteger](a, b: T): T {.inline.} = a - b
  proc nsCkMul*[T: SomeInteger](a, b: T): T {.inline.} = a * b
  {.pop.}

{.push rangeChecks: off.}
proc nsCkConv*[T: SomeInteger; S: SomeInteger](t: typedesc[T]; x: S): T {.nsHidden, inline.} =
  ## `checked((T)x)` between integer types: .NET's `OverflowException` when `x` is
  ## outside `T`, which Nim's range check does not make for an unsigned `T`.
  when S is SomeSignedInt and T is SomeUnsignedInt:
    if x < 0 or uint64(x) > uint64(high(T)): nsOverflowFail()
  elif S is SomeUnsignedInt:
    if uint64(x) > uint64(high(T)): nsOverflowFail()
  else:
    if int64(x) < int64(low(T)) or int64(x) > int64(high(T)): nsOverflowFail()
  T(x)
{.pop.}

proc nsCkNeg*[T: SomeInteger](a: T): T {.nsHidden, inline.} =
  when T is SomeSignedInt:
    if a == low(T): nsOverflowFail()
    -a
  else:
    if a != 0: nsOverflowFail()
    a

proc nsDiv*[T: SomeInteger](a, b: T): T {.nsHidden, inline.} =
  if b == 0: raise newException(DivByZeroDefect, "Attempted to divide by zero.")
  when T is SomeSignedInt:
    if b == T(-1) and a == low(T): nsDivOverflow()
  system.`div`(a, b)

proc nsMod*[T: SomeInteger](a, b: T): T {.nsHidden, inline.} =
  if b == 0: raise newException(DivByZeroDefect, "Attempted to divide by zero.")
  when T is SomeSignedInt:
    if b == T(-1) and a == low(T): nsDivOverflow()
  system.`mod`(a, b)

# C#'s floating-point `%` truncates toward zero and keeps the dividend's sign, C's
# `fmod`; Nim's integer `mod` does not apply to floats.
from std/math import nil

proc nsFmod*(a, b: float64): float64 {.nsHidden, inline.} = math.`mod`(a, b)
proc nsFmod*(a, b: float32): float32 {.nsHidden, inline.} = math.`mod`(a, b)

# A shift count is masked to the operand's width, as C# does (`1 << 33 == 2`); in
# C a count that large is undefined. `>>>` shifts zeros in whatever the sign.
template nsShiftMask[T](n: SomeInteger): int = int(n) and (sizeof(T) * 8 - 1)

proc nsShl*[T: SomeInteger](a: T; n: SomeInteger): T {.nsHidden, inline.} = a shl nsShiftMask[T](n)
proc nsShr*[T: SomeInteger](a: T; n: SomeInteger): T {.nsHidden, inline.} = a shr nsShiftMask[T](n)
proc nsUShr*[T: SomeInteger](a: T; n: SomeInteger): T {.nsHidden, inline.} =
  when T is SomeUnsignedInt: a shr nsShiftMask[T](n)
  elif sizeof(T) == 8: cast[T](cast[uint64](a) shr nsShiftMask[T](n))
  elif sizeof(T) == 4: cast[T](cast[uint32](a) shr nsShiftMask[T](n))
  elif sizeof(T) == 2: cast[T](cast[uint16](a) shr nsShiftMask[T](n))
  else: cast[T](cast[uint8](a) shr nsShiftMask[T](n))

import std/options except `$`

export options except `$`

proc `$`*[T](x: Option[T]): string =
  ## A `T?` prints as its value, and as nothing when it has none, as C# formats a
  ## null.
  if x.isSome: $x.get else: ""

# A class or struct that does not override `ToString` prints its fields, as Nim's
# `$` prints an object: `(Name: "Rex", Age: 3)`, base class fields first. This is
# a deliberate departure from C#, which prints the type's name. The compiler
# lists the fields (an auto-property shows under its own name, events and statics
# not at all) and these say how each value is written.

method nsValueText*(x: RootRef): string {.nsHidden, base.} = $x
  ## An object as an element or field prints; a boxed value overrides it, so a
  ## boxed string is quoted as a string is.

proc nsFieldValue*[T](x: T): string {.nsHidden.} =
  ## One field's value: a string or char quoted, null as `null`, anything else as
  ## it prints.
  when T is string or T is char: result.addQuoted(x)
  elif T is Option:
    result = (if x.isSome: nsFieldValue(x.get) else: "null")
  elif T is RootRef:
    result = (if x.isNil: "null" else: nsValueText(x))
  elif T is ref or T is ptr or T is pointer:
    result = (if x.isNil: "null" else: $x)
  elif T is object and compiles(x.nsObj):
    ## An interface value: the object it holds, or null.
    result = (if x.nsObj.isNil: "null" else: nsValueText(x.nsObj))
  elif (T is proc):
    result = (if x.isNil: "null" else: "...")
  elif compiles($x): result = $x
  else: result = "..."

proc nsFieldAdd*[T](text: var string; name: string; value: T) {.nsHidden.} =
  ## `, name: value` onto the fields printed so far.
  if text.len > 0: text.add ", "
  text.add name
  text.add ": "
  text.add nsFieldValue(value)

var nsPrinting {.threadvar.}: seq[pointer]
const nsPrintDepth = 64
  ## How deep objects print inside one another: a longer chain (a linked list of
  ## thousands of nodes) ends in `...`, so printing it neither recurses without
  ## bound nor copies its text once per level.

template nsGuarded*(self: typed; text: untyped): string {.nsHidden.} =
  ## `text`, or `...` for an object already being printed further out, so a cycle
  ## (`a.Next = a`, a list holding itself) ends, or one `nsPrintDepth` levels in.
  when self is ref:
    let nsAt = cast[pointer](self)
    if nsPrinting.len >= nsPrintDepth or nsAt in nsPrinting: "..."
    else:
      nsPrinting.add nsAt
      try: text
      finally: discard nsPrinting.pop()
  else: text

template nsObjectText*(self: typed; fields: untyped): string {.nsHidden.} =
  ## `(fields)`: a class or struct without a `ToString` of its own.
  nsGuarded(self, "(" & fields & ")")

proc nsItemsText*[O, C](owner: O; c: C): string {.nsHidden.} =
  ## `owner`'s elements `c`, in `foreach` order: `[1, 2]`. (C# prints the type's
  ## name; `GetType()` still gives it.)
  mixin items
  nsGuarded(owner):
    var text = "["
    for x in c:
      if text.len > 1: text.add ", "
      text.add nsFieldValue(x)
    text.add ']'
    text

proc nsItemsText*[C](c: C): string {.nsHidden.} = nsItemsText(c, c)
  ## A collection as its elements.

proc nsPairsText*[C](c: C): string {.nsHidden.} =
  ## A dictionary as its entries: `{"a": 1, "b": 2}`.
  mixin items
  nsGuarded(c):
    var text = "{"
    for kv in c:
      if text.len > 1: text.add ", "
      text.add nsFieldValue(kv.Key)
      text.add ": "
      text.add nsFieldValue(kv.Value)
    text.add '}'
    text

# `.NET`'s nullable members and `??` are the *type's* business, so they are ordinary
# procs over `Option` reached by Nim's own dot-call, the way `int.high` reaches
# `high(int32)`. The compiler knows none of these names.

var nsNoValue*: proc () {.nimcall.} = nil
  ## What reading an absent `T?` throws: `System` sets it to throw .NET's
  ## `InvalidOperationException`, whose type the intrinsics cannot name; without
  ## it, Nim's `UnpackDefect`.

proc nsAbsentValue() {.noinline.} =
  if nsNoValue != nil: nsNoValue()
  raise newException(UnpackDefect, "Nullable object must have a value.")

proc Value*[T](x: Option[T]): T =
  ## `x.Value`: C# throws `InvalidOperationException` when there is no value.
  if x.isNone: nsAbsentValue()
  result = x.get

proc HasValue*[T](x: Option[T]): bool = x.isSome

proc GetValueOrDefault*[T](x: Option[T]): T =
  if x.isSome: result = x.get
  else: result = default(T)

proc nsAbsent*[T](x: Option[T]): bool {.nsHidden.} =
  ## `a?.V` / `a ?? b` ask the type whether it is absent; the compiler emits this
  ## rather than naming a member, so the `Option` API stays the library's business.
  x.isNone

proc nsPresent*[T](x: Option[T]): T {.nsHidden.} =
  ## The unwrapped value, for the present side of the same lowering, and for
  ## `(int)x`, which throws as `x.Value` does when there is none.
  if x.isNone: nsAbsentValue()
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

# A bare value on the left (`1 + a`, `3 == a`) is lifted the same way; `sema.nim`
# gives a literal there the nullable's element type, so `T` is the same on both sides.
proc `+`*[T: SomeNumber](a: T, b: Option[T]): Option[T] =
  if b.isSome: some(a + b.get) else: none(T)
proc `-`*[T: SomeNumber](a: T, b: Option[T]): Option[T] =
  if b.isSome: some(a - b.get) else: none(T)
proc `*`*[T: SomeNumber](a: T, b: Option[T]): Option[T] =
  if b.isSome: some(a * b.get) else: none(T)
proc `/`*[T: SomeInteger](a: T, b: Option[T]): Option[T] =
  if b.isSome: some(nsDiv(a, b.get)) else: none(T)
proc `mod`*[T: SomeInteger](a: T, b: Option[T]): Option[T] =
  if b.isSome: some(nsMod(a, b.get)) else: none(T)
proc `<`*[T: SomeNumber](a: T, b: Option[T]): bool = b.isSome and a < b.get
proc `<=`*[T: SomeNumber](a: T, b: Option[T]): bool = b.isSome and a <= b.get
proc `>`*[T: SomeNumber](a: T, b: Option[T]): bool = b.isSome and a > b.get
proc `>=`*[T: SomeNumber](a: T, b: Option[T]): bool = b.isSome and a >= b.get

# Lifted `==` against a bare value: equal only when present and equal (12.4.8).
proc `==`*[T](a: Option[T], b: T): bool = a.isSome and a.get == b
proc `==`*[T](a: T, b: Option[T]): bool = b.isSome and a == b.get

# `bool?`'s `&` and `|` are three-valued (12.13.5): `false & null` is `false`,
# `true | null` is `true`, and the rest with an absent operand is absent. `^` is
# absent when either is.
proc `and`*(a, b: Option[bool]): Option[bool] =
  if (a.isSome and not a.get) or (b.isSome and not b.get): some(false)
  elif a.isSome and b.isSome: some(true)
  else: none(bool)
proc `or`*(a, b: Option[bool]): Option[bool] =
  if (a.isSome and a.get) or (b.isSome and b.get): some(true)
  elif a.isSome and b.isSome: some(false)
  else: none(bool)
proc `xor`*(a, b: Option[bool]): Option[bool] =
  if a.isSome and b.isSome: some(a.get xor b.get) else: none(bool)
proc `and`*(a: Option[bool], b: bool): Option[bool] = a and some(b)
proc `and`*(a: bool, b: Option[bool]): Option[bool] = some(a) and b
proc `or`*(a: Option[bool], b: bool): Option[bool] = a or some(b)
proc `or`*(a: bool, b: Option[bool]): Option[bool] = some(a) or b
proc `xor`*(a: Option[bool], b: bool): Option[bool] = a xor some(b)
proc `xor`*(a: bool, b: Option[bool]): Option[bool] = some(a) xor b
proc `not`*(a: Option[bool]): Option[bool] =
  if a.isSome: some(not a.get) else: none(bool)

proc nsOptAs*[T, U](a: Option[T]; t: typedesc[U]): Option[U] {.nsHidden.} =
  ## A lifted conversion, `long? l = i;` for an `int? i`: absent stays absent.
  if a.isSome: some(U(a.get)) else: none(U)

proc nsNilFail*() {.nsHidden, noinline, noreturn.} =
  raise nsStamped(NilAccessDefect, "Object reference not set to an instance of an object.",
                  "System.NullReferenceException")

template nsCheckNil*(x: untyped): untyped {.nsHidden.} =
  ## C# throws when a method is called on a nil receiver even if the body never
  ## touches `self`. A dereference check cannot see that, so the receiver is tested
  ## at the call. `desugar.nim` emits this around a dot-called class receiver that
  ## is not a plain variable (`list[i].M()`); `x` is evaluated once, into a
  ## variable that owns nothing, so no reference is counted when `x` lends it (a
  ## temporary `x` makes is destroyed with the statement, as it would be anyway).
  (let nsR {.cursor.} = x; (if nsR == nil: nsNilFail()); nsR)

template nsCheckNilVar*(x: untyped): untyped {.nsHidden.} =
  ## `nsCheckNil` for a receiver that is a variable: read twice rather than
  ## copied, so the check costs no reference count, and the throw is out of line.
  (if x == nil: nsNilFail()
   x)

proc nsIfaceCast*[T](v: T; src: RootRef): T {.nsHidden.} =
  ## `(I)x` for an interface `I`: `v` is what the object's class answered for `I`,
  ## empty when it does not implement it. C# throws `InvalidCastException` then,
  ## unless `x` was null, which casts to the null interface value.
  mixin nsTypeName, nsTypeOf
  if src != nil and v.nsObj == nil:
    when compiles(nsTypeOf(T)):
      raise newException(ObjectConversionDefect, "Unable to cast object of type '" &
        src.nsDynType.nsDisplay & "' to type '" & nsTypeOf(T).nsDisplay & "'.")
    else:
      raise newException(ObjectConversionDefect, "Specified cast is not valid.")
  v

proc nsCreate*[T: not ref](t: typedesc[T]): T {.nsHidden.} =
  ## `new T()` for a value type: its default. A class declares its own `nsCreate`,
  ## which calls its parameterless constructor.
  default(T)

type
  NsDisposeStack* = ref object
    ## The `finally` blocks an iterator is suspended inside, innermost last: what
    ## disposing its enumerator runs (ECMA-334 15.15.5), as `foreach` does when it
    ## is left early.
    fins: seq[proc () {.closure.}]

proc nsDisposePush*(d: NsDisposeStack; f: proc () {.closure.}) {.nsHidden, inline.} = d.fins.add f
proc nsDisposePop*(d: NsDisposeStack) {.nsHidden, inline.} =
  if d.fins.len > 0: d.fins.setLen(d.fins.len - 1)
proc nsDisposeRun*(d: NsDisposeStack) {.nsHidden.} =
  while d.fins.len > 0:
    let f = d.fins.pop()
    f()

proc nsCellOf*[T](v: T): ref T {.nsHidden, inline.} =
  ## A loop-body variable a lambda captures: one cell per iteration, which every
  ## closure of that iteration shares and no other iteration does.
  new(result)
  result[] = v

proc nsIsNull*[T](x: T): bool {.nsHidden, inline.} =
  ## `x == null` for a value of a type parameter: never for a value type, as C#
  ## has it, the empty string for a `string` (N#'s null one), and `nil` otherwise.
  when T is string: x.len == 0
  elif T is Option: x.isNone
  elif compiles(x.nsObj): x.nsObj == nil
  elif compiles(x == nil): x == nil
  else: false

template nsStmt*(x: untyped) {.nsHidden.} =
  ## A delegate call used as a statement: C# drops its result, and a Nim proc value
  ## cannot be `{.discardable.}`, so a result is discarded here.
  when typeof(x) is void: x
  else: discard x

# `x++` / `++x` used as a value, and on a target Nim's `inc` cannot take: a property
# or an indexer (whose getter's result is no variable) or a float. The new value is
# assigned, so a property's setter runs. A plain integer statement increment is
# Nim's own `inc`/`dec`.
template nsStepped(v: typed; up: static bool): untyped =
  when typeof(v) is Option:
    ## `x++` on a `T?` steps a present value and leaves an absent one.
    (if v.isSome: some(when typeof(v.get) is SomeFloat: (when up: v.get + 1 else: v.get - 1)
                       else: (when up: succ(v.get) else: pred(v.get)))
     else: v)
  elif typeof(v) is SomeFloat: (when up: v + 1 else: v - 1)
  else: (when up: succ(v) else: pred(v))
template nsPostInc*(x: untyped): untyped {.nsHidden.} =
  (let nsOld = x; x = nsStepped(nsOld, true); nsOld)
template nsPostDec*(x: untyped): untyped {.nsHidden.} =
  (let nsOld = x; x = nsStepped(nsOld, false); nsOld)
template nsPreInc*(x: untyped): untyped {.nsHidden.} =
  (x = nsStepped(x, true); x)
template nsPreDec*(x: untyped): untyped {.nsHidden.} =
  (x = nsStepped(x, false); x)
template nsInc*(x: untyped) {.nsHidden.} =
  x = nsStepped(x, true)
template nsDec*(x: untyped) {.nsHidden.} =
  x = nsStepped(x, false)

type
  SwitchExpressionException* = object of CatchableError
    ## What a switch expression throws when no arm matches. C# declares it in
    ## `System.Runtime.CompilerServices`; the compiler raises it, so it lives here.

template nsDispose*(x: typed) {.nsHidden.} =
  ## What `using` runs when its scope is left: `x.Dispose()`, unless `x` is null.
  when x is ref:
    if x != nil: x.Dispose()
  elif compiles(x.nsObj):
    if x.nsObj != nil: x.Dispose()
  else:
    x.Dispose()

import std/cmdline

proc nsVal*[T](x: T): T {.nsHidden, inline.} =
  ## A variable's value read now: `x + F()` in C# reads `x` before `F` runs, while
  ## Nim reads a variable operand after the call. The compiler wraps an operand in
  ## this when a later one may change it.
  x

# A C# enum is its underlying integer with names: `Read | Write` and `(Color)7` are
# values too, which a Nim `enum` cannot hold. The compiler declares each enum as a
# `distinct` integer, each member as a template over its `typedesc`
# (`Color.Red`), and calls `nsEnum` for the operators C# gives every enum.

proc nsEnumName*(v: int64; names: openArray[(string, int64)]; flags: bool): string {.nsHidden.} =
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

proc nsMultiSlot*[D](): var seq[D] {.nsHidden.} =
  var slot {.global.}: seq[D]
  slot

proc nsMultiProcs*[D](): var seq[pointer] {.nsHidden.} =
  var procs {.global.}: seq[pointer]
  procs

proc nsRawProc*[D](f: D): pointer {.nsHidden.} =
  ## The proc behind a closure, or nil for a proc type `rawProc` does not take.
  when compiles(rawProc(f)): rawProc(f)
  else: cast[pointer](f)

proc nsMarkMulti*[D](f: D) {.nsHidden.} =
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

template nsListOf*(d: typed): untyped {.nsHidden.} =
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

macro nsCombine*(a, b: typed): untyped {.nsHidden.} =
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

proc nsWithout*[D](la, lb: seq[D]): seq[D] {.nsHidden.} =
  ## `la` without the last run of delegates equal to `lb`, as C#'s `Delegate.Remove`
  ## takes it out; `la` itself when it holds no such run.
  result = la
  if lb.len == 0 or lb.len > la.len: return
  for i in countdown(la.len - lb.len, 0):
    if la[i ..< i + lb.len] == lb:
      return la[0 ..< i] & la[i + lb.len .. ^1]

macro nsRemove*(a, b: typed): untyped {.nsHidden.} =
  ## `a - b` for delegates (`d -= h`): the delegate of the list that remains.
  let r = genSym(nskVar, "nsR")
  let x = genSym(nskForVar, "nsX")
  result = quote do:
    (block:
      var `r`: typeof(`a`) = nil
      for `x` in nsWithout(nsListOf(`a`), nsListOf(`b`)): `r` = nsCombine(`r`, `x`)
      `r`)

proc nsSubscribe*[D](e: var seq[D]; h: D) {.nsHidden.} =
  ## `e += h` on an event: `h` joins its handlers (a null one does not).
  if h != nil: e.add h

proc nsUnsubscribe*[D](e: var seq[D]; h: D) {.nsHidden.} =
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

proc nsTypeOf*(t: typedesc[int8]): Type {.nsHidden.} = nsTypeNamed("System.SByte")
proc nsTypeOf*(t: typedesc[uint8]): Type {.nsHidden.} = nsTypeNamed("System.Byte")
proc nsTypeOf*(t: typedesc[int16]): Type {.nsHidden.} = nsTypeNamed("System.Int16")
proc nsTypeOf*(t: typedesc[uint16]): Type {.nsHidden.} = nsTypeNamed("System.UInt16")
proc nsTypeOf*(t: typedesc[int32]): Type {.nsHidden.} = nsTypeNamed("System.Int32")
proc nsTypeOf*(t: typedesc[uint32]): Type {.nsHidden.} = nsTypeNamed("System.UInt32")
proc nsTypeOf*(t: typedesc[int64]): Type {.nsHidden.} = nsTypeNamed("System.Int64")
proc nsTypeOf*(t: typedesc[int]): Type {.nsHidden.} = nsTypeNamed("System.Int32")
  ## Nim's `int` is an untyped C# `int` literal (`3.GetType()`); C#'s `long` is
  ## always `int64`.
proc nsTypeOf*(t: typedesc[uint64]): Type {.nsHidden.} = nsTypeNamed("System.UInt64")
proc nsTypeOf*(t: typedesc[float32]): Type {.nsHidden.} = nsTypeNamed("System.Single")
proc nsTypeOf*(t: typedesc[float]): Type {.nsHidden.} = nsTypeNamed("System.Double")
proc nsTypeOf*(t: typedesc[bool]): Type {.nsHidden.} = nsTypeNamed("System.Boolean")
proc nsTypeOf*(t: typedesc[char]): Type {.nsHidden.} = nsTypeNamed("System.Char")
proc nsTypeOf*(t: typedesc[string]): Type {.nsHidden.} = nsTypeNamed("System.String")
proc nsTypeOf*(t: typedesc[RootRef]): Type {.nsHidden.} = nsTypeNamed("System.Object")


proc nsAdoptExceptionName*(e: ref Exception) {.nsHidden.} =
  ## A defect Nim's runtime raised (a check N# leaves to Nim, such as a string's
  ## index) is named as Nim names its type, where N#'s own throws are named as .NET
  ## does (`nsStamped`): it takes .NET's name and message here, once.
  if e == nil or e.name.isNil: return
  if e of IndexDefect:
    if e.name == cstring"IndexDefect":
      e.msg = "Index was outside the bounds of the array."
      e.name = "System.IndexOutOfRangeException"
  elif e of OverflowDefect:
    if e.name == cstring"OverflowDefect":
      e.msg = "Arithmetic operation resulted in an overflow."
      e.name = "System.OverflowException"
  elif e of NilAccessDefect:
    if e.name == cstring"NilAccessDefect":
      e.msg = "Object reference not set to an instance of an object."
      e.name = "System.NullReferenceException"

proc nsAdoptException*(e: ref Exception) {.nsHidden.} =
  ## An exception as the program first sees it, in a `catch`: named and worded as
  ## .NET's, and its stack trace ending at the catching method.
  nsCutTrace(e)
  nsAdoptExceptionName(e)

proc GetType*(x: RootRef): Type {.discardable.} =
  ## `x.GetType()` on a class value: its dynamic type.
  if x == nil: nsNilFail()
  if x of Exception and nsExceptionName != nil:
    nsTypeNamed(nsExceptionName((ref Exception)(x)))
  else:
    x.nsDynType
proc GetType*[T: not RootRef](x: T): Type {.discardable.} = nsTypeOf(T)
  ## A value's type is its static one.

# `sizeof(T)` for the built-in value types, as C# defines them (a `char` is two
# bytes there, whatever N#'s is).
proc nsSizeOf*(t: typedesc[int8 | uint8 | bool]): int32 {.nsHidden.} = 1
proc nsSizeOf*(t: typedesc[int16 | uint16 | char]): int32 {.nsHidden.} = 2
proc nsSizeOf*(t: typedesc[int32 | uint32 | float32]): int32 {.nsHidden.} = 4
proc nsSizeOf*(t: typedesc[int64 | uint64 | float]): int32 {.nsHidden.} = 8

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
    nsFmt: proc (b: NsBoxed; spec: string): string {.nimcall.}
    nsType: string
  NsBox*[T] = ref object of NsBoxed
    v* {.nsHidden.}: T

method nsValueText*[T](b: NsBox[T]): string {.nsHidden.} = nsFieldValue(b.v)

# `Equals` and `GetHashCode` of a value, as .NET defines them for its built-in types:
# a `double` equals itself when NaN, and hashes its bits with every NaN alike and
# `-0.0` as `0.0`; a `long` folds its halves, a `char` repeats itself in the upper
# half. A struct compares and hashes its fields. A string's hash is .NET's only in
# being stable for one run.

# One overload per kind of type, as `CompareTo` is declared, so each type's members
# are found under it.

proc Equals*[T: SomeInteger](a, b: T): bool {.discardable.} = a == b
proc Equals*[T: SomeFloat](a, b: T): bool {.discardable.} = a == b or (a != a and b != b)
proc Equals*(a, b: char): bool {.discardable.} = a == b
proc Equals*(a, b: bool): bool {.discardable.} = a == b
proc Equals*(a, b: string): bool {.discardable.} = a == b
proc Equals*[T: object | tuple | enum](a, b: T): bool {.discardable.} = a == b
  ## A struct's: its fields' (C#'s `ValueType.Equals`); an enum's value.

proc GetHashCode*[T: SomeInteger](x: T): int32 {.discardable.} =
  ## Nim's `int` is an untyped C# `int` literal, so it hashes as an `int` does.
  when T is int64 | uint64:
    cast[int32](x) xor cast[int32](cast[uint64](x) shr 32)
  elif T is uint32: cast[int32](x)
  else: int32(x)
proc GetHashCode*[T: SomeFloat](x: T): int32 {.discardable.} =
  when T is float64:
    var bits = cast[uint64](x)
    if ((bits - 1) and 0x7FFF_FFFF_FFFF_FFFF'u64) >= 0x7FF0_0000_0000_0000'u64:
      bits = bits and 0x7FF0_0000_0000_0000'u64
    cast[int32](bits) xor cast[int32](bits shr 32)
  else:
    var bits = cast[uint32](x)
    if ((bits - 1) and 0x7FFF_FFFF'u32) >= 0x7F80_0000'u32: bits = bits and 0x7F80_0000'u32
    cast[int32](bits)
proc GetHashCode*(x: char): int32 {.discardable.} = int32(ord(x)) or (int32(ord(x)) shl 16)
proc GetHashCode*(x: bool): int32 {.discardable.} = (if x: 1'i32 else: 0'i32)
proc GetHashCode*(x: string): int32 {.discardable.} = cast[int32](hash(x))
proc GetHashCode*[T: object | tuple | enum](x: T): int32 {.discardable.} =
  when T is enum: int32(ord(x))
  else:
    var h: Hash = 0
    for f in fields(x):
      when compiles(GetHashCode(f)): h = h !& int(GetHashCode(f))
      else: h = h !& hash(f)
    cast[int32](!$h)

proc nsBoxStr[T](b: NsBoxed): string = $NsBox[T](b).v
proc nsBoxFmt[T](b: NsBoxed; spec: string): string = nsFmt(NsBox[T](b).v, spec)
proc nsBoxEq[T](a: NsBoxed; b: RootRef): bool =
  ## Two boxes are equal when they hold equal values of one type.
  if b == nil or not (b of NsBox[T]): return false
  when compiles(Equals(NsBox[T](a).v, NsBox[T](b).v)): Equals(NsBox[T](a).v, NsBox[T](b).v)
  else: NsBox[T](a).v == NsBox[T](b).v
proc nsBoxHash[T](b: NsBoxed): int32 =
  when compiles(GetHashCode(NsBox[T](b).v)): GetHashCode(NsBox[T](b).v)
  else: int32(hash(NsBox[T](b).v) and 0x7fffffff)

proc nsBoxOf[T](x: T): RootRef =
  var name = ""
  when compiles(nsTypeOf(T)): name = nsTypeOf(T).nsFull
  NsBox[T](v: x, nsStr: nsBoxStr[T], nsEq: nsBoxEq[T], nsHash: nsBoxHash[T],
           nsFmt: nsBoxFmt[T], nsType: name)

proc nsFormatValue*(o: RootRef; spec: string): string {.nsHidden.} =
  ## One hole of a composite format (`string.Format`) holding an `object`: a boxed
  ## value takes the spec as an interpolation hole does, null is empty, and any
  ## other object is its `ToString()`.
  mixin ToString
  if o == nil: ""
  elif o of NsBoxed: NsBoxed(o).nsFmt(NsBoxed(o), spec)
  else: o.ToString()

proc nsBox*(x: RootRef): RootRef {.nsHidden, inline.} = x
  ## A reference is already an object.
proc nsBox*[T: not RootRef](x: T): RootRef {.nsHidden.} =
  ## An untyped integer literal (Nim's `int`) is a C# `int`; any other value keeps
  ## its type, `3'i64` a `long`. One generic, so a typed literal is not converted to
  ## `int` to reach a narrower overload.
  when T is int: nsBoxOf(int32(x)) else: nsBoxOf(x)
proc nsBox*[T](x: Option[T]): RootRef {.nsHidden.} =
  ## Boxing a `T?` boxes its value, or is null when it has none (ECMA-334 8.3.12).
  if x.isSome: nsBoxOf(x.get) else: nil

from std/tables import Table, getOrDefault, `[]=`
var nsLiteralBoxes {.threadvar.}: Table[string, RootRef]
proc nsBoxLit*(s: string): RootRef {.nsHidden.} =
  ## A string literal as an `object`: identical literals are one instance (6.4.5.6),
  ## so `(object)"x" == (object)"x"`.
  result = nsLiteralBoxes.getOrDefault(s)
  if result == nil:
    result = nsBoxOf(s)
    nsLiteralBoxes[s] = result

method ToString*(b: NsBoxed): string = b.nsStr(b)
method nsTypeName*(b: NsBoxed): string {.nsHidden.} = b.nsType
proc nsBoxEquals*(a: NsBoxed; b: RootRef): bool {.nsHidden.} = a.nsEq(a, b)
proc nsBoxHash*(a: NsBoxed): int32 {.nsHidden.} = a.nsHash(a)

method Equals*(a, b: RootRef): bool {.base, discardable.} = a == b
  ## `object.Equals`: the reference, unless a class overrides it.
method GetHashCode*(x: RootRef): int32 {.base, discardable.} =
  ## `object.GetHashCode`: the reference's address, folded to 32 bits.
  cast[int32](cast[int](x) xor (cast[int](x) shr 32))
method Equals*(a: NsBoxed; b: RootRef): bool = a.nsEq(a, b)
  ## A boxed value is equal to a box of an equal value (see `NsBox`).
method GetHashCode*(x: NsBoxed): int32 = x.nsHash(x)

proc nsCastFail(src, dst: string) {.noinline, noreturn.} =
  raise newException(ObjectConversionDefect,
    "Unable to cast object of type '" & src & "' to type '" & dst & "'.")

proc nsDowncast*[T: RootRef](x: RootRef; t: typedesc[T]): T {.nsHidden, inline.} =
  ## `(T)x` from a base class: `x` itself when it is a `T` or null, else .NET's
  ## `InvalidCastException`.
  mixin nsTypeOf
  if x != nil and not (x of T): nsCastFail(GetType(x).nsDisplay, nsTypeOf(T).nsDisplay)
  T(x)

proc nsUnbox*[T](o: RootRef; t: typedesc[T]): T {.nsHidden.} =
  ## `(T)o`: the boxed value, which must be exactly a `T`.
  mixin nsTypeOf
  when T is Option:
    ## `(int?)o`: null is the absent value, a box of an `int` a present one.
    type E = typeof(default(T).get)
    if o == nil: none(E) else: some(nsUnbox(o, E))
  elif T is RootRef:
    if o != nil and not (o of T): nsCastFail(GetType(o).nsDisplay, nsTypeOf(T).nsDisplay)
    T(o)
  else:
    if o == nil:
      nsNilFail()
    if not (o of NsBox[T]): nsCastFail(GetType(o).nsDisplay, nsTypeOf(T).nsDisplay)
    NsBox[T](o).v

proc nsAsValue*[T](o: RootRef; t: typedesc[T]): T {.nsHidden.} =
  ## `o as T` for a `string`, an array or a `T?`: the value when `o` holds one of
  ## the type, null (the empty string, nil, the absent value) otherwise.
  when T is Option:
    type E = typeof(default(T).get)
    if o != nil and o of NsBox[E]: some(NsBox[E](o).v) else: none(E)
  elif T is RootRef:
    if o != nil and o of T: T(o) else: nil
  else:
    if o != nil and o of NsBox[T]: NsBox[T](o).v else: default(T)

proc nsIsType*[T](o: RootRef; t: typedesc[T]): bool {.nsHidden.} =
  ## `o is T`: a reference of that class, or a box of that value type; `o is T?`
  ## tests for a box of `T`, since a boxed nullable is a boxed value (8.3.12).
  when T is RootRef: o != nil and o of T
  elif T is Option:
    type E = typeof(default(T).get)
    o != nil and o of NsBox[E]
  else: o != nil and o of NsBox[T]

# --- multi-dimensional arrays ---------------------------------------------------
#
# `T[,]` is a reference, as a C# array is: the lengths and the elements in
# row-major order, which is also the order `foreach` visits them in. An index out
# of a dimension's range throws `IndexOutOfRangeException` (Nim's `IndexDefect`).

type
  NsMdBase* = ref object of RootObj
    nsName: string    ## `System.Int32[,]`, the type's name
  NsMdArray*[T] = ref object of NsMdBase
    nsDims: seq[int]
    nsData: seq[T]

proc nsMdName[T](rank: int): string =
  var name = "System.Object"
  when compiles(nsTypeOf(T)): name = nsTypeOf(T).nsFull
  name & "[" & repeat(',', rank - 1) & "]"

method ToString*(a: NsMdBase): string = a.nsName
method ToString*[T](a: NsMdArray[T]): string =
  ## Its elements as nested rows, `[[1, 2], [3, 4]]`, not C#'s `System.Int32[,]`.
  proc rows(a: NsMdArray[T]; dim, at: int; text: var string) =
    text.add '['
    var stride = 1
    for k in dim + 1 ..< a.nsDims.len: stride *= a.nsDims[k]
    for i in 0 ..< a.nsDims[dim]:
      if i > 0: text.add ", "
      if dim == a.nsDims.high: text.add nsFieldValue(a.nsData[at + i])
      else: rows(a, dim + 1, at + i * stride, text)
    text.add ']'
  nsGuarded(a):
    var text = ""
    rows(a, 0, 0, text)
    text
method nsTypeName*(a: NsMdBase): string {.nsHidden.} = a.nsName

proc nsNewMd*[T](t: typedesc[T]; dims: varargs[int]): NsMdArray[T] {.nsHidden.} =
  var n = 1
  for d in dims:
    if d < 0: nsOverflowFail()
    n *= d
  NsMdArray[T](nsDims: @dims, nsData: newSeq[T](n), nsName: nsMdName[T](dims.len))

proc nsMdOf*[T](data: seq[T]; dims: seq[int]): NsMdArray[T] {.nsHidden.} =
  NsMdArray[T](nsDims: dims, nsData: data, nsName: nsMdName[T](dims.len))

proc nsFlat[T](a: NsMdArray[T]; idx: openArray[int]): int =
  if a == nil: nsNilFail()
  if idx.len != a.nsDims.len: nsIndexFail()
  for k, i in idx:
    if i < 0 or i >= a.nsDims[k]:
      nsIndexFail()
    result = result * a.nsDims[k] + i

proc `[]`*[T](a: NsMdArray[T]; i, j: SomeInteger): var T =
  a.nsData[a.nsFlat([int(i), int(j)])]
proc `[]`*[T](a: NsMdArray[T]; i, j, k: SomeInteger): var T =
  a.nsData[a.nsFlat([int(i), int(j), int(k)])]
proc `[]=`*[T](a: NsMdArray[T]; i, j: SomeInteger; v: T) =
  a.nsData[a.nsFlat([int(i), int(j)])] = v
proc `[]=`*[T](a: NsMdArray[T]; i, j, k: SomeInteger; v: T) =
  a.nsData[a.nsFlat([int(i), int(j), int(k)])] = v

proc len*[T](a: NsMdArray[T]): int {.nsHidden.} = a.nsData.len
  ## `Length`: every element, across the dimensions.
proc Length*[T](a: NsMdArray[T]): int32 = int32(a.nsData.len)
proc Rank*[T](a: NsMdArray[T]): int32 = int32(a.nsDims.len)
proc GetLength*[T](a: NsMdArray[T]; d: SomeInteger): int32 =
  if d < 0 or int(d) >= a.nsDims.len:
    nsIndexFail()
  int32(a.nsDims[d])
proc GetUpperBound*[T](a: NsMdArray[T]; d: SomeInteger): int32 = a.GetLength(d) - 1
proc GetLowerBound*[T](a: NsMdArray[T]; d: SomeInteger): int32 = 0
iterator items*[T](a: NsMdArray[T]): T {.nsHidden.} =
  for x in a.nsData: yield x

# --- arrays -------------------------------------------------------------------
#
# `T[]` is a reference, as a C# array is: assigning or passing one shares it, and
# `null` is an array too. The elements are a `seq`, which the array never resizes.
# An index out of range throws `IndexOutOfRangeException` (Nim's `IndexDefect`), a
# null array `NullReferenceException`.

type
  NsArrayBase* = ref object of RootObj
    nsName: proc (): string {.nimcall.}  ## `System.Int32[]`, the type's name
  NsArray*[T] = ref object of NsArrayBase
    nsData* {.nsHidden.}: seq[T]

proc nsArrayName[T](): string {.nimcall.} =
  mixin nsTypeOf
  var name = "System.Object"
  when compiles(nsTypeOf(T)): name = nsTypeOf(T).nsFull
  name & "[]"

method ToString*(a: NsArrayBase): string = a.nsName()
method nsTypeName*(a: NsArrayBase): string {.nsHidden.} = a.nsName()

proc nsArrayOf*[T](data: sink seq[T]): NsArray[T] {.nsHidden, inline.} =
  ## The array holding `data`: an array literal, or a library result.
  NsArray[T](nsData: data, nsName: nsArrayName[T])

proc nsNewArray*[T](t: typedesc[T]; n: SomeInteger): NsArray[T] {.nsHidden.} =
  ## `new T[n]`: `n` default elements.
  if n < 0: nsOverflowFail()
  nsArrayOf(newSeq[T](int(n)))

template nsArrCheck(a: untyped) =
  ## The null test C# makes at every access to an array.
  when not defined(danger):
    if a == nil: nsNilFail()

# The bounds check is made here, in place of Nim's (which is off for the access), so
# a failure throws with .NET's message and costs nothing more: one unsigned compare,
# the throw out of line. It follows the compilation's `boundChecks` setting.
const nsBoundChecks = compileOption("boundChecks")

template nsBoundCheck(i, n: int) =
  when nsBoundChecks:
    if cast[uint](i) >= cast[uint](n): nsIndexFail()

{.push boundChecks: off.}
proc `[]`*[T](a: NsArray[T]; i: SomeInteger): var T {.inline.} =
  nsArrCheck(a)
  nsBoundCheck(int(i), a.nsData.len)
  a.nsData[int(i)]
proc `[]=`*[T](a: NsArray[T]; i: SomeInteger; v: sink T) {.inline.} =
  nsArrCheck(a)
  nsBoundCheck(int(i), a.nsData.len)
  a.nsData[int(i)] = v
proc `[]`*[T](a: NsArray[T]; i: BackwardsIndex): var T {.inline.} =
  nsArrCheck(a)
  nsBoundCheck(a.nsData.len - int(i), a.nsData.len)
  a.nsData[i]
proc `[]=`*[T](a: NsArray[T]; i: BackwardsIndex; v: sink T) {.inline.} =
  nsArrCheck(a)
  nsBoundCheck(a.nsData.len - int(i), a.nsData.len)
  a.nsData[i] = v
{.pop.}
proc `[]`*[T; U, V: Ordinal | BackwardsIndex](a: NsArray[T]; r: HSlice[U, V]): NsArray[T] =
  ## `a[1..^1]`: a new array of those elements, as C# copies a range.
  nsArrCheck(a)
  nsArrayOf(a.nsData[r])
proc len*[T](a: NsArray[T]): int {.nsHidden, inline.} =
  nsArrCheck(a)
  a.nsData.len
proc high*[T](a: NsArray[T]): int {.nsHidden, inline.} = a.len - 1

template nsForBound*(i, a: untyped; cond: bool): bool {.nsHidden.} =
  ## A counted loop's condition (`i < a.Length`), marked for the lowering's own
  ## bounds-check removal; a marker it leaves is the condition.
  cond

{.push boundChecks: off.}
proc nsAtUnchecked*[T](a: NsArray[T]; i: SomeInteger): var T {.nsHidden, inline.} =
  ## `a[i]` in a loop that keeps `0 <= i < a.Length` and the array: neither the
  ## null test (the condition made it) nor the bounds check.
  a.nsData[int(i)]
{.pop.}

iterator items*[T](a: NsArray[T]): T {.nsHidden.} =
  nsArrCheck(a)
  for x in a.nsData: yield x
iterator mitems*[T](a: NsArray[T]): var T {.nsHidden.} =
  nsArrCheck(a)
  for x in a.nsData.mitems: yield x
iterator pairs*[T](a: NsArray[T]): (int, T) {.nsHidden.} =
  nsArrCheck(a)
  for i, x in a.nsData: yield (i, x)

method ToString*[T](a: NsArray[T]): string = nsItemsText(a, a.nsData)
  ## Its elements, `[1, 2]`, not C#'s `System.Int32[]` (`GetType()` still says that).

template nsElemRef*(x: untyped): untyped {.nsHidden.} =
  ## `ref a[i]`: the element as a location of its own, which a `ref` return or
  ## a `ref` local may keep while the array lives.
  cast[ptr typeof(x)](addr x)[]

proc nsArrayFrom*[T](xs: openArray[T]): NsArray[T] {.nsHidden.} = nsArrayOf(@xs)
  ## A copy of `xs` as an array: `params` elements, a library collection's.

proc nsCommandLine*(): NsArray[string] {.nsHidden.} =
  ## `Main`'s `string[] args`: the command line without the program's name.
  nsArrayOf(commandLineParams())

# --- variance -----------------------------------------------------------------

proc nsVariant*[A, B](x: A; t: typedesc[B]): B {.nsHidden.} =
  ## `IProducer<Cat>` as `IProducer<Animal>`, `Func<Cat>` as `Func<Animal>`: C#
  ## allows these only over reference type arguments, which Nim represents alike,
  ## so the value is reread as the other instantiation (and copied as one, which
  ## keeps the reference counts right).
  static: doAssert sizeof(A) == sizeof(B)
  cast[ptr B](unsafeAddr x)[]

# --- `typeof` of constructed types ---------------------------------------------

proc nsGenericName*(base: string; args: varargs[string]): string {.nsHidden.} =
  ## .NET's name of a constructed generic type: ``System.Collections.Generic.List`1[System.Int32]``.
  base & "`" & $args.len & "[" & args.join(",") & "]"

proc nsTypeOf*[T](t: typedesc[NsArray[T]]): Type {.nsHidden.} = nsTypeNamed(nsArrayName[T]())
  ## `typeof(int[])` is `System.Int32[]`.
proc nsTypeOf*[T](t: typedesc[NsMdArray[T]]): Type {.nsHidden.} = nsTypeNamed(nsMdName[T](2))
  ## `typeof(int[,])`; a rank above 2 is not told apart by the type.

# --- type tests against generic interfaces ------------------------------------
#
# `o is IBox<int>`: every class implementing an instantiation of a generic
# interface overrides `nsVtByKey`, answering that instantiation's table by its
# type's name, and passing any other key to its base class.

import std/typetraits

method nsVtByKey*(x: RootRef; key: string): pointer {.nsHidden, base.} = nil

proc nsKeyOf*(t: typedesc): string {.nsHidden.} = name(t)

proc nsIfaceObject*[I: object](v: I): RootRef {.nsHidden, inline.} =
  ## An interface value used as an `object`: the instance it holds (null for none).
  v.nsObj

proc nsAsByKey*[I](o: RootRef; t: typedesc[I]): I {.nsHidden.} =
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

template nsHandleProcs*(H, R: untyped; hdr, validPat, nullPat, derefPat: untyped) {.nsHidden.} =
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

proc nsDerefCached*[H, T](h: H; p: var ptr T): ptr T {.nsHidden, inline.} =
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
    nsAdoptException(e)
    let kind = (if nsExceptionName != nil: nsExceptionName(e) else: $e.name)
    nsOnUnhandled(cstring(where), cstring(e.msg), cstring(kind))

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
      box* {.nsHidden.}: pointer
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
    p* {.nsHidden.}: ptr T
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
