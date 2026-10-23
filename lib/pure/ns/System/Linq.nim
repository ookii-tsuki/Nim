# N# standard library: the System.Linq namespace. Imported by `using System.Linq;`.
#
# LINQ's method syntax: .NET's `Enumerable` extension methods, as procs over
# `NsEnumerable[T]` -- an array, any collection, an `IEnumerable<T>`, an ordered
# query or a group (`System.Collections.Generic` declares the last two, so every
# `IEnumerable<T>` parameter takes them) -- which the frontend files under each of
# them, as a C# extension method of an interface is a member of every type
# implementing it.
#
# As in .NET, an operator that returns a sequence is deferred: it runs when its
# result is enumerated, afresh each time, and sees the source as it is then
# (`Where`, `Select`, `OrderBy`, `GroupBy`, ...). One that returns a value or a
# collection runs at once (`Count`, `First`, `ToList`, ...). Sorting is stable, a
# group keeps its keys in first-seen order, and keys and set operations compare as
# `Dictionary` and `HashSet` do. A failure throws .NET's exception with its message.
#
# Pinned surface (SPEC section 15.3):
#
#   filtering, projecting  Where Select SelectMany
#   ordering         OrderBy OrderByDescending ThenBy ThenByDescending Order
#                    OrderDescending Reverse
#   partitioning     Skip Take SkipWhile TakeWhile SkipLast TakeLast Chunk
#   sets             Distinct DistinctBy Union Intersect Except Concat Append Prepend
#   grouping, joining GroupBy (Key) Zip
#   elements         First FirstOrDefault Last LastOrDefault Single SingleOrDefault
#                    ElementAt ElementAtOrDefault DefaultIfEmpty
#   quantifiers      Any All Contains SequenceEqual
#   aggregates       Count LongCount Sum Min Max MinBy MaxBy Average Aggregate
#   conversions      ToList ToArray ToDictionary ToHashSet AsEnumerable
#   generators       Enumerable.Range Enumerable.Repeat Enumerable.Empty
#
# Deliberately absent: query syntax (`from x in xs`, not in N#), a dictionary or a
# string as a source, the `IEqualityComparer`/`IComparer` overloads, `Join`,
# `GroupJoin`, `ToLookup`, `OfType`/`Cast`, the nullable-element aggregates, and
# `AsParallel`.

import std/algorithm
import ../System
import Collections/Generic
from ../../nsharp/intrinsics import nsCkAdd, NsArray, nsArrayOf, Equals
from ../../nsharp/pragmas import nsStatic

{.push discardable.}

type
  Enumerable* = object
    ## `System.Linq.Enumerable`: its members are static (`Range`, `Repeat`, `Empty`).
  NsFunc2b*[T, R] = proc (a: T): R
    ## `Func<T, R>` for a second selector of one signature: Nim does not infer two
    ## instances of one generic proc type in a signature (`GroupBy(key, element)`).

proc nsLinqFail(message: string) {.noinline, noreturn.} =
  raise nsNewException(InvalidOperationException, message)

const
  noElements = "Sequence contains no elements"
  noMatch = "Sequence contains no matching element"

proc nsView[T](source: NsEnumerable[T]): IEnumerable[T] =
  ## The source as a sequence enumerated live.
  let src = source
  nsEnumerable(T):
    for x in items(src): yield x

proc nsToIEnumerable*[T](o: IOrderedEnumerable[T]): IEnumerable[T] = nsView(o)
  ## Where C# converts an ordered query to `IEnumerable<T>`.
proc nsToIEnumerable*[T](g: IGroupingBase[T]): IEnumerable[T] = nsView(g)

proc nsCompare[K](a, b: K): int =
  ## The default order of a key: its `CompareTo`, else the natural one.
  mixin CompareTo
  when compiles(a.CompareTo(b)): int(a.CompareTo(b))
  else: cmp(a, b)

# --- filtering and projecting -------------------------------------------------

proc Where*[T](source: NsEnumerable[T]; predicate: Func2[T, bool]): IEnumerable[T] =
  let src = source
  nsEnumerable(T):
    for x in items(src):
      if predicate(x): yield x
proc Where*[T](source: NsEnumerable[T]; predicate: Func3[T, int32, bool]): IEnumerable[T] =
  ## With the element's index.
  let src = source
  nsEnumerable(T):
    var i = 0'i32
    for x in items(src):
      if predicate(x, i): yield x
      inc i

proc Select*[T, R](source: NsEnumerable[T]; selector: Func2[T, R]): IEnumerable[R] =
  let src = source
  nsEnumerable(R):
    for x in items(src): yield selector(x)
proc Select*[T, R](source: NsEnumerable[T]; selector: Func3[T, int32, R]): IEnumerable[R] =
  let src = source
  nsEnumerable(R):
    var i = 0'i32
    for x in items(src):
      yield selector(x, i)
      inc i

proc nsElementOf[E](t: typedesc[NsEnumerable[E]]): E = discard
  ## The element type of a collection type, for `typeof`.

proc SelectMany*[T, C](source: NsEnumerable[T]; selector: Func2[T, C]):
    IEnumerable[typeof(nsElementOf(C))] =
  ## Each element's collection, one after another.
  type E = typeof(nsElementOf(C))
  let src = source
  nsEnumerable(E):
    for x in items(src):
      for y in items(selector(x)): yield y

# --- ordering -----------------------------------------------------------------

proc nsLevel[T, K](keySelector: Func2[T, K]; descending: bool):
    proc (xs: seq[T]): proc (i, j: int): int =
  ## One ordering level: the keys of the elements, computed once each.
  result = proc (xs: seq[T]): proc (i, j: int): int =
    var keys = newSeq[K](xs.len)
    for i, x in xs: keys[i] = keySelector(x)
    let ks = keys
    result = proc (i, j: int): int =
      if descending: nsCompare(ks[j], ks[i]) else: nsCompare(ks[i], ks[j])
proc nsSelf[T](x: T): T = x

proc OrderBy*[T, K](source: NsEnumerable[T]; keySelector: Func2[T, K]): IOrderedEnumerable[T] =
  IOrderedEnumerable[T](nsSource: nsView(source), nsOrder: @[nsLevel(keySelector, false)])
proc OrderByDescending*[T, K](source: NsEnumerable[T]; keySelector: Func2[T, K]):
    IOrderedEnumerable[T] =
  IOrderedEnumerable[T](nsSource: nsView(source), nsOrder: @[nsLevel(keySelector, true)])
proc ThenBy*[T, K](source: IOrderedEnumerable[T]; keySelector: Func2[T, K]):
    IOrderedEnumerable[T] =
  IOrderedEnumerable[T](nsSource: source.nsSource,
                        nsOrder: source.nsOrder & nsLevel(keySelector, false))
proc ThenByDescending*[T, K](source: IOrderedEnumerable[T]; keySelector: Func2[T, K]):
    IOrderedEnumerable[T] =
  IOrderedEnumerable[T](nsSource: source.nsSource,
                        nsOrder: source.nsOrder & nsLevel(keySelector, true))
proc Order*[T](source: NsEnumerable[T]): IOrderedEnumerable[T] =
  IOrderedEnumerable[T](nsSource: nsView(source),
                        nsOrder: @[nsLevel[T, T](nsSelf[T], false)])
proc OrderDescending*[T](source: NsEnumerable[T]): IOrderedEnumerable[T] =
  IOrderedEnumerable[T](nsSource: nsView(source),
                        nsOrder: @[nsLevel[T, T](nsSelf[T], true)])

proc Reverse*[T](source: NsEnumerable[T]): IEnumerable[T] =
  let src = source
  nsEnumerable(T):
    var xs: seq[T] = @[]
    for x in items(src): xs.add x
    for i in countdown(xs.high, 0): yield xs[i]

# --- partitioning -------------------------------------------------------------

proc Skip*[T](source: NsEnumerable[T]; count: int32): IEnumerable[T] =
  let src = source
  nsEnumerable(T):
    var i = 0'i32
    for x in items(src):
      if i >= count: yield x
      inc i
proc Take*[T](source: NsEnumerable[T]; count: int32): IEnumerable[T] =
  let src = source
  nsEnumerable(T):
    var i = 0'i32
    if count > 0:
      for x in items(src):
        yield x
        inc i
        if i >= count: break
proc SkipWhile*[T](source: NsEnumerable[T]; predicate: Func2[T, bool]): IEnumerable[T] =
  let src = source
  nsEnumerable(T):
    var skipping = true
    for x in items(src):
      if skipping and predicate(x): continue
      skipping = false
      yield x
proc TakeWhile*[T](source: NsEnumerable[T]; predicate: Func2[T, bool]): IEnumerable[T] =
  let src = source
  nsEnumerable(T):
    for x in items(src):
      if not predicate(x): break
      yield x
proc SkipLast*[T](source: NsEnumerable[T]; count: int32): IEnumerable[T] =
  let src = source
  nsEnumerable(T):
    var xs: seq[T] = @[]
    for x in items(src): xs.add x
    for i in 0 ..< clamp(xs.len - int(count), 0, xs.len): yield xs[i]
proc TakeLast*[T](source: NsEnumerable[T]; count: int32): IEnumerable[T] =
  let src = source
  nsEnumerable(T):
    var xs: seq[T] = @[]
    for x in items(src): xs.add x
    for i in max(0, xs.len - int(count)) ..< xs.len: yield xs[i]
proc Chunk*[T](source: NsEnumerable[T]; size: int32): IEnumerable[NsArray[T]] =
  ## The elements in arrays of `size`, the last one shorter.
  if size < 1:
    raise nsNewException(ArgumentOutOfRangeException, "size",
                         "Specified argument was out of the range of valid values.")
  let src = source
  nsEnumerable(NsArray[T]):
    var part: seq[T] = @[]
    for x in items(src):
      part.add x
      if part.len == int(size):
        yield nsArrayOf(part)
        part = @[]
    if part.len > 0: yield nsArrayOf(part)

# --- sets and concatenation ---------------------------------------------------

proc Distinct*[T](source: NsEnumerable[T]): IEnumerable[T] =
  let src = source
  nsEnumerable(T):
    let seen = newHashSet[T]()
    for x in items(src):
      if seen.Add(x): yield x
proc DistinctBy*[T, K](source: NsEnumerable[T]; keySelector: Func2[T, K]): IEnumerable[T] =
  let src = source
  nsEnumerable(T):
    let seen = newHashSet[K]()
    for x in items(src):
      if seen.Add(keySelector(x)): yield x

# A second sequence is an `NsEnumerable2`: Nim binds a type class to one type per
# signature, and the two may be different collections.
proc Union*[T](first: NsEnumerable[T]; second: NsEnumerable2[T]): IEnumerable[T] =
  let a = first
  let b = second
  nsEnumerable(T):
    let seen = newHashSet[T]()
    for x in items(a):
      if seen.Add(x): yield x
    for x in items(b):
      if seen.Add(x): yield x
proc Intersect*[T](first: NsEnumerable[T]; second: NsEnumerable2[T]): IEnumerable[T] =
  let a = first
  let b = second
  nsEnumerable(T):
    let other = newHashSet[T]()
    for x in items(b): other.Add(x)
    for x in items(a):
      if other.Remove(x): yield x
proc Except*[T](first: NsEnumerable[T]; second: NsEnumerable2[T]): IEnumerable[T] =
  let a = first
  let b = second
  nsEnumerable(T):
    let seen = newHashSet[T]()
    for x in items(b): seen.Add(x)
    for x in items(a):
      if seen.Add(x): yield x
proc Concat*[T](first: NsEnumerable[T]; second: NsEnumerable2[T]): IEnumerable[T] =
  let a = first
  let b = second
  nsEnumerable(T):
    for x in items(a): yield x
    for x in items(b): yield x
proc Append*[T](source: NsEnumerable[T]; element: T): IEnumerable[T] =
  let src = source
  nsEnumerable(T):
    for x in items(src): yield x
    yield element
proc Prepend*[T](source: NsEnumerable[T]; element: T): IEnumerable[T] =
  let src = source
  nsEnumerable(T):
    yield element
    for x in items(src): yield x

# --- grouping and zipping -----------------------------------------------------

proc GroupBy*[T, K](source: NsEnumerable[T]; keySelector: Func2[T, K]):
    IEnumerable[IGrouping[K, T]] =
  ## The groups in the order their keys first appear, each in source order.
  let src = source
  nsEnumerable(IGrouping[K, T]):
    let index = newDictionary[K, int]()
    var groups: seq[IGrouping[K, T]] = @[]
    for x in items(src):
      let k = keySelector(x)
      var at = 0
      if index.TryGetValue(k, at): groups[at].nsElems.add x
      else:
        index.Add(k, groups.len)
        groups.add IGrouping[K, T](nsKey: k, nsElems: @[x])
    for g in groups: yield g
proc GroupBy*[T, K, E](source: NsEnumerable[T]; keySelector: Func2[T, K];
                       elementSelector: NsFunc2b[T, E]): IEnumerable[IGrouping[K, E]] =
  let src = source
  nsEnumerable(IGrouping[K, E]):
    let index = newDictionary[K, int]()
    var groups: seq[IGrouping[K, E]] = @[]
    for x in items(src):
      let k = keySelector(x)
      var at = 0
      if index.TryGetValue(k, at): groups[at].nsElems.add elementSelector(x)
      else:
        index.Add(k, groups.len)
        groups.add IGrouping[K, E](nsKey: k, nsElems: @[elementSelector(x)])
    for g in groups: yield g

proc Zip*[T, U, R](first: NsEnumerable[T]; second: NsEnumerable2[U];
                   resultSelector: Func3[T, U, R]): IEnumerable[R] =
  ## Pairs of elements, as many as the shorter sequence has.
  let a = first
  let b = second
  nsEnumerable(R):
    ## In step, as .NET's: the second is read one element per element of the first.
    let e = nsView(b).GetEnumerator()
    try:
      for x in items(a):
        if not e.MoveNext(): break
        yield resultSelector(x, e.Current)
    finally:
      e.Dispose()

# --- elements -------------------------------------------------------------------

proc First*[T](source: NsEnumerable[T]): T =
  for x in items(source): return x
  nsLinqFail(noElements)
proc First*[T](source: NsEnumerable[T]; predicate: Func2[T, bool]): T =
  for x in items(source):
    if predicate(x): return x
  nsLinqFail(noMatch)
proc FirstOrDefault*[T](source: NsEnumerable[T]): T =
  for x in items(source): return x
proc FirstOrDefault*[T](source: NsEnumerable[T]; predicate: Func2[T, bool]): T =
  for x in items(source):
    if predicate(x): return x
proc FirstOrDefault*[T](source: NsEnumerable[T]; defaultValue: T): T =
  for x in items(source): return x
  defaultValue
proc Last*[T](source: NsEnumerable[T]): T =
  var found = false
  for x in items(source):
    result = x
    found = true
  if not found: nsLinqFail(noElements)
proc Last*[T](source: NsEnumerable[T]; predicate: Func2[T, bool]): T =
  var found = false
  for x in items(source):
    if predicate(x):
      result = x
      found = true
  if not found: nsLinqFail(noMatch)
proc LastOrDefault*[T](source: NsEnumerable[T]): T =
  for x in items(source): result = x
proc LastOrDefault*[T](source: NsEnumerable[T]; predicate: Func2[T, bool]): T =
  for x in items(source):
    if predicate(x): result = x
proc Single*[T](source: NsEnumerable[T]): T =
  var n = 0
  for x in items(source):
    if n == 1: nsLinqFail("Sequence contains more than one element")
    result = x
    inc n
  if n == 0: nsLinqFail(noElements)
proc Single*[T](source: NsEnumerable[T]; predicate: Func2[T, bool]): T =
  var n = 0
  for x in items(source):
    if predicate(x):
      if n == 1: nsLinqFail("Sequence contains more than one matching element")
      result = x
      inc n
  if n == 0: nsLinqFail(noMatch)
proc SingleOrDefault*[T](source: NsEnumerable[T]): T =
  var n = 0
  for x in items(source):
    if n == 1: nsLinqFail("Sequence contains more than one element")
    result = x
    inc n
proc SingleOrDefault*[T](source: NsEnumerable[T]; predicate: Func2[T, bool]): T =
  var n = 0
  for x in items(source):
    if predicate(x):
      if n == 1: nsLinqFail("Sequence contains more than one matching element")
      result = x
      inc n
proc ElementAt*[T](source: NsEnumerable[T]; index: int32): T =
  var i = 0'i32
  if index >= 0:
    for x in items(source):
      if i == index: return x
      inc i
  raise nsNewException(ArgumentOutOfRangeException, "index", "Index was out of range. " &
    "Must be non-negative and less than the size of the collection.")
proc ElementAtOrDefault*[T](source: NsEnumerable[T]; index: int32): T =
  var i = 0'i32
  if index >= 0:
    for x in items(source):
      if i == index: return x
      inc i
proc DefaultIfEmpty*[T](source: NsEnumerable[T]): IEnumerable[T] =
  let src = source
  nsEnumerable(T):
    var any = false
    for x in items(src):
      any = true
      yield x
    if not any: yield default(T)

# --- quantifiers ----------------------------------------------------------------

proc Any*[T](source: NsEnumerable[T]): bool =
  for x in items(source): return true
proc Any*[T](source: NsEnumerable[T]; predicate: Func2[T, bool]): bool =
  for x in items(source):
    if predicate(x): return true
proc All*[T](source: NsEnumerable[T]; predicate: Func2[T, bool]): bool =
  for x in items(source):
    if not predicate(x): return false
  true
proc Contains*[T](source: NsEnumerable[T]; value: T): bool =
  mixin Equals
  for x in items(source):
    if Equals(x, value): return true
proc SequenceEqual*[T](first: NsEnumerable[T]; second: NsEnumerable2[T]): bool =
  mixin Equals
  var xs, ys: seq[T]
  for x in items(first): xs.add x
  for y in items(second): ys.add y
  if xs.len != ys.len: return false
  for i in 0 ..< xs.len:
    if not Equals(xs[i], ys[i]): return false
  true

# --- aggregates -----------------------------------------------------------------

proc Count*[T](source: NsEnumerable[T]): int32 =
  for x in items(source): result = nsCkAdd(result, 1'i32)
proc Count*[T](source: NsEnumerable[T]; predicate: Func2[T, bool]): int32 =
  for x in items(source):
    if predicate(x): result = nsCkAdd(result, 1'i32)
proc LongCount*[T](source: NsEnumerable[T]): int64 =
  for x in items(source): inc result

proc nsAddTo[N](acc: var N; x: N) {.inline.} =
  ## An integer sum overflows as .NET's does, with `OverflowException`.
  when N is SomeInteger: acc = nsCkAdd(acc, x)
  else: acc = acc + x

# The numeric aggregates have one overload per element type, as .NET declares them,
# so the result is known from the source (`int Sum(IEnumerable<int>)`).

proc Sum*(source: NsEnumerable[int32]): int32 =
  for x in items(source): nsAddTo(result, x)
proc Sum*(source: NsEnumerable[int64]): int64 =
  for x in items(source): nsAddTo(result, x)
proc Sum*(source: NsEnumerable[float]): float =
  for x in items(source): nsAddTo(result, x)
proc Sum*(source: NsEnumerable[float32]): float32 =
  for x in items(source): nsAddTo(result, x)
proc Sum*[T; N: SomeNumber](source: NsEnumerable[T]; selector: Func2[T, N]): N =
  ## .NET's per-type overloads (`int Sum(Func<T, int>)`, ...) as one: Nim does not
  ## tell overloads apart by a delegate's result alone.
  for x in items(source): nsAddTo(result, selector(x))

template nsTotal(total, x: untyped) =
  ## An integer total is a `long`, checked, as .NET sums it.
  when typeof(x) is SomeInteger: total = nsCkAdd(total, int64(x))
  else: total += float(x)
proc nsMean[N](source: NsEnumerable[N]): float =
  var n = 0
  var total: (when N is SomeInteger: int64 else: float)
  for x in items(source):
    nsTotal(total, x)
    inc n
  if n == 0: nsLinqFail(noElements)
  float(total) / float(n)
proc Average*(source: NsEnumerable[int32]): float = nsMean(source)
proc Average*(source: NsEnumerable[int64]): float = nsMean(source)
proc Average*(source: NsEnumerable[float]): float = nsMean(source)
proc Average*(source: NsEnumerable[float32]): float32 =
  ## A `float` source averages to a `float`, summed in `double`.
  float32(nsMean(source))
proc Average*[T; N: SomeNumber](source: NsEnumerable[T]; selector: Func2[T, N]): float =
  var n = 0
  var total: (when N is SomeInteger: int64 else: float)
  for x in items(source):
    nsTotal(total, selector(x))
    inc n
  if n == 0: nsLinqFail(noElements)
  float(total) / float(n)

template nsNullable(T: typedesc): bool =
  ## A result C# can answer null with: an empty source gives it, and null elements
  ## are passed over, where a value type's empty source throws.
  T is ref or T is string

template nsSkipped[T](x: T): bool =
  when T is ref: x.isNil else: false

proc nsMinOf[T](source: NsEnumerable[T]): T =
  ## The least; a NaN is the least of floating-point values, as in .NET.
  var first = true
  for x in items(source):
    if nsSkipped(x): continue
    when T is SomeFloat:
      if x != x: return x
    if first or nsCompare(x, result) < 0: result = x
    first = false
  when not nsNullable(T):
    if first: nsLinqFail(noElements)
proc nsMaxOf[T](source: NsEnumerable[T]): T =
  var first = true
  for x in items(source):
    if nsSkipped(x): continue
    if first or nsCompare(x, result) > 0: result = x
    first = false
  when not nsNullable(T):
    if first: nsLinqFail(noElements)

proc Min*(source: NsEnumerable[int32]): int32 = nsMinOf(source)
proc Min*(source: NsEnumerable[int64]): int64 = nsMinOf(source)
proc Min*(source: NsEnumerable[float]): float = nsMinOf(source)
proc Min*[T](source: NsEnumerable[T]): T = nsMinOf(source)
proc Max*(source: NsEnumerable[int32]): int32 = nsMaxOf(source)
proc Max*(source: NsEnumerable[int64]): int64 = nsMaxOf(source)
proc Max*(source: NsEnumerable[float]): float = nsMaxOf(source)
proc Max*[T](source: NsEnumerable[T]): T = nsMaxOf(source)
proc nsMinBy[T, R](source: NsEnumerable[T]; selector: Func2[T, R]): R =
  var first = true
  for x in items(source):
    let v = selector(x)
    if nsSkipped(v): continue
    when R is SomeFloat:
      if v != v: return v
    if first or nsCompare(v, result) < 0: result = v
    first = false
  when not nsNullable(R):
    if first: nsLinqFail(noElements)
proc nsMaxBy[T, R](source: NsEnumerable[T]; selector: Func2[T, R]): R =
  var first = true
  for x in items(source):
    let v = selector(x)
    if nsSkipped(v): continue
    if first or nsCompare(v, result) > 0: result = v
    first = false
  when not nsNullable(R):
    if first: nsLinqFail(noElements)
proc Min*[T; N: SomeNumber](source: NsEnumerable[T]; selector: Func2[T, N]): N =
  ## .NET's per-type overloads, as for `Sum`; any other result is the generic one's.
  nsMinBy(source, selector)
proc Min*[T, R](source: NsEnumerable[T]; selector: Func2[T, R]): R = nsMinBy(source, selector)
proc Max*[T; N: SomeNumber](source: NsEnumerable[T]; selector: Func2[T, N]): N =
  nsMaxBy(source, selector)
proc Max*[T, R](source: NsEnumerable[T]; selector: Func2[T, R]): R = nsMaxBy(source, selector)

proc MinBy*[T, K](source: NsEnumerable[T]; keySelector: Func2[T, K]): T =
  ## An element whose key is null is passed over; an empty source of a reference
  ## type gives null.
  var first = true
  var best: K
  for x in items(source):
    let k = keySelector(x)
    if nsSkipped(k): continue
    if first or nsCompare(k, best) < 0:
      best = k
      result = x
    first = false
  when not nsNullable(T):
    if first: nsLinqFail(noElements)
proc MaxBy*[T, K](source: NsEnumerable[T]; keySelector: Func2[T, K]): T =
  ## An element whose key is null is passed over; an empty source of a reference
  ## type gives null.
  var first = true
  var best: K
  for x in items(source):
    let k = keySelector(x)
    if nsSkipped(k): continue
    if first or nsCompare(k, best) > 0:
      best = k
      result = x
    first = false
  when not nsNullable(T):
    if first: nsLinqFail(noElements)

proc Aggregate*[T](source: NsEnumerable[T]; fn: Func3[T, T, T]): T =
  var first = true
  for x in items(source):
    result = (if first: x else: fn(result, x))
    first = false
  if first: nsLinqFail(noElements)
proc Aggregate*[T, A](source: NsEnumerable[T]; seed: A; fn: Func3[A, T, A]): A =
  result = seed
  for x in items(source): result = fn(result, x)

# --- conversions ----------------------------------------------------------------

proc ToList*[T](source: NsEnumerable[T]): List[T] =
  result = newList[T]()
  for x in items(source): result.Add(x)
proc ToArray*[T](source: NsEnumerable[T]): NsArray[T] =
  var xs: seq[T] = @[]
  for x in items(source): xs.add x
  nsArrayOf(xs)
proc ToHashSet*[T](source: NsEnumerable[T]): HashSet[T] =
  result = newHashSet[T]()
  for x in items(source): result.Add(x)
proc ToDictionary*[T, K](source: NsEnumerable[T]; keySelector: Func2[T, K]): Dictionary[K, T] =
  result = newDictionary[K, T]()
  for x in items(source): result.Add(keySelector(x), x)
proc ToDictionary*[T, K, V](source: NsEnumerable[T]; keySelector: Func2[T, K];
                            elementSelector: NsFunc2b[T, V]): Dictionary[K, V] =
  result = newDictionary[K, V]()
  for x in items(source): result.Add(keySelector(x), elementSelector(x))
proc AsEnumerable*[T](source: NsEnumerable[T]): IEnumerable[T] = nsView(source)

# --- generators -----------------------------------------------------------------

proc Range*(start, count: int32): IEnumerable[int32] {.nsStatic: "Enumerable".} =
  ## `count` integers from `start`.
  if count < 0 or int64(start) + int64(count) - 1 > int64(high(int32)):
    raise nsNewException(ArgumentOutOfRangeException, "count",
                         "Specified argument was out of the range of valid values.")
  nsEnumerable(int32):
    for i in 0'i32 ..< count: yield start + i
proc Repeat*[T](element: T; count: int32): IEnumerable[T] {.nsStatic: "Enumerable".} =
  if count < 0:
    raise nsNewException(ArgumentOutOfRangeException, "count",
                         "Specified argument was out of the range of valid values.")
  nsEnumerable(T):
    for i in 0'i32 ..< count: yield element
proc Empty*[T](): IEnumerable[T] {.nsStatic: "Enumerable".} =
  nsEnumerable(T):
    discard

{.pop.}
