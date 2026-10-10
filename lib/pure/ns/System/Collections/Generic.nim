# N# standard library: the System.Collections.Generic namespace.
#
# C# collection types, imported by `using System.Collections.Generic;`.
#
# Every collection is a class, as it is in .NET: a `ref object` that owns its
# storage, so `var b = a;` aliases the same list and `null` is a valid value. This
# is the Nim a user's own `class List<T>` would lower to, written ahead of time; the
# Nim containers (`seq`, `OrderedTable`, `OrderedSet`, `Deque`) are private fields,
# never the type itself. `KeyValuePair<K,V>` is the one struct.
#
# C# names are kept at the source level (SPEC section 15, "Naming"): members are
# ordinary procs named as C# names them and reached through Nim's dot-call; a C#
# property (`Count`, `First`, `Keys`) is a proc taking only the receiver.
#
# Mutating members bump a version, and every enumerator checks it, so changing a
# collection inside its own `foreach` throws `InvalidOperationException` as .NET's
# does.
#
# Pinned surface (SPEC section 15.1):
#
#   List<T>          Add AddRange BinarySearch Clear Contains ConvertAll CopyTo
#                    Count Exists Find FindAll FindIndex FindLast FindLastIndex
#                    ForEach GetRange IndexOf Insert InsertRange LastIndexOf Remove
#                    RemoveAll RemoveAt RemoveRange Reverse Sort ToArray TrimExcess
#                    TrueForAll, [] []=
#   Dictionary<K,V>  Add Clear ContainsKey ContainsValue Count GetValueOrDefault
#                    Keys Remove TryAdd Values, [] []=, foreach KeyValuePair
#   KeyCollection, ValueCollection  Count CopyTo, foreach (live views)
#   KeyValuePair<K,V> Key Value
#   HashSet<T>       Add Clear Contains Count ExceptWith IntersectWith
#                    IsProperSubsetOf IsProperSupersetOf IsSubsetOf IsSupersetOf
#                    Overlaps Remove RemoveWhere SetEquals SymmetricExceptWith
#                    ToArray UnionWith
#   SortedSet<T>     the HashSet<T> members, plus Max Min Reverse, in sorted order
#   SortedDictionary<K,V>  the Dictionary<K,V> members, in key order
#   SortedList<K,V>  the SortedDictionary<K,V> members, plus GetKeyAtIndex
#                    GetValueAtIndex IndexOfKey IndexOfValue RemoveAt
#   Queue<T>         Clear Contains CopyTo Count Dequeue Enqueue Peek ToArray
#                    TrimExcess
#   Stack<T>         Clear Contains CopyTo Count Peek Pop Push ToArray TrimExcess
#   LinkedList<T>    AddAfter AddBefore AddFirst AddLast Clear Contains Count Find
#                    FindLast First Last Remove RemoveFirst RemoveLast
#   LinkedListNode<T> Next Previous Value
#   PriorityQueue<E,P> Clear Count Dequeue Enqueue EnqueueDequeue Peek
#
# Every collection can be walked with `foreach`. Constructors take nothing, a
# capacity (ignored, as it only sizes the backing store), or any collection of
# elements (C#'s `IEnumerable<T>`); a member whose C# parameter is an
# `IEnumerable<T>` likewise takes any collection or array.
#
# Deliberately absent, with the reason:
#   * `TryGetValue`, `TryDequeue`, `TryPeek`, `TryPop`, `Remove(key, out value)`:
#     `out` parameters are not parsed yet.
#   * the interfaces other than `IEnumerable<T>`/`IEnumerator<T>` (`IList<T>`,
#     `IComparer<T>`, ...) and the overloads that take them. `IEnumerable<T>` is a
#     concrete type here: iterator methods return it and collections convert to
#     it, but a class cannot implement it.
#   * `Comparer<T>`, `EqualityComparer<T>`, `Capacity`, `AsReadOnly`, collection
#     initialisers (`new List<int> { 1, 2 }`, a language feature).
#   * a constructor from `Keys`/`Values` (`new List<K>(d.Keys)`): the view has two
#     type parameters, which Nim cannot infer behind an explicit `newList[K]`.

import std/[tables, sets, deques, algorithm, sequtils]
import ../../System
import ../Collections
from ../../../nsharp/intrinsics import Type, nsTypeNamed, nsTypeOf, FullName, nsGenericName
export Collections

type
  List*[T] = ref object
    ## C#'s `List<T>`: a growable array.
    data: seq[T]
    version: int
  KeyValuePair*[K, V] = object
    ## C#'s `KeyValuePair<K,V>`, the element a dictionary's `foreach` yields.
    Key*: K
    Value*: V
  Dictionary*[K, V] = ref object
    ## C#'s `Dictionary<K,V>`. Insertion-ordered, which is the order .NET
    ## enumerates in for a dictionary nothing was removed from.
    data: OrderedTable[K, V]
    version: int
  HashSet*[T] = ref object
    ## C#'s `HashSet<T>`, insertion-ordered as `Dictionary` is.
    data: OrderedSet[T]
    version: int
  SortedSet*[T] = ref object
    ## C#'s `SortedSet<T>`: a sorted array, searched by bisection.
    data: seq[T]
    version: int
  SortedDictionary*[K, V] = ref object
    ## C#'s `SortedDictionary<K,V>`: parallel sorted arrays of keys and values.
    keys: seq[K]
    vals: seq[V]
    version: int
  SortedList*[K, V] = ref object
    ## C#'s `SortedList<K,V>`: the same store as `SortedDictionary`, indexable.
    keys: seq[K]
    vals: seq[V]
    version: int
  Queue*[T] = ref object
    ## C#'s `Queue<T>` (FIFO).
    data: Deque[T]
    version: int
  Stack*[T] = ref object
    ## C#'s `Stack<T>` (LIFO). The top is the end of `data`.
    data: seq[T]
    version: int
  LinkedListNode*[T] = ref object
    ## C#'s `LinkedListNode<T>`. `Value` is a field C# reads and writes; `Next`
    ## and `Previous` are read-only properties below. `List` is absent: a proc
    ## cannot share the name of the `List` type in Nim.
    Value*: T
    owner: LinkedList[T]
    next, prev: LinkedListNode[T]
  LinkedList*[T] = ref object
    ## C#'s `LinkedList<T>`: a doubly-linked list of `LinkedListNode<T>`.
    head, tail: LinkedListNode[T]
    count: int
    version: int
  KeyCollection*[K, V] = ref object
    ## C#'s `Dictionary<K,V>.KeyCollection` (and the sorted dictionaries'): a live
    ## view of the keys. Exactly one of the owners is set.
    dict: Dictionary[K, V]
    sorted: SortedDictionary[K, V]
    list: SortedList[K, V]
  ValueCollection*[K, V] = ref object
    ## C#'s `Dictionary<K,V>.ValueCollection`: a live view of the values.
    dict: Dictionary[K, V]
    sorted: SortedDictionary[K, V]
    list: SortedList[K, V]
  PriorityQueue*[E, P] = ref object
    ## C#'s `PriorityQueue<TElement,TPriority>`: a min-heap on the priority. It is
    ## the 4-ary heap .NET uses, so equal priorities leave in .NET's order too.
    nodes: seq[(E, P)]
    version: int

  IEnumerator*[T] = ref object of NsEnumerator
    ## C#'s `IEnumerator<T>`: `MoveNext` (inherited) steps, `Current` is the element
    ## stepped to.
    step: iterator(): T
    current: T
  IEnumerable*[T] = ref object
    ## C#'s `IEnumerable<T>`: something that hands out enumerators.
    make: proc(): IEnumerator[T]
  Enumerable[T] = seq[T] | List[T] | HashSet[T] | SortedSet[T] | Queue[T] |
                  Stack[T] | LinkedList[T] | IEnumerable[T]
    ## What a C# `IEnumerable<T>` parameter takes here: an array or a collection.

const
  modifiedMsg = "Collection was modified; enumeration operation may not execute."
  indexMsg = "Index was out of range. Must be non-negative and less than the " &
             "size of the collection. (Parameter 'index')"

template touch(c: untyped) = inc c.version

template checkVersion(c: untyped; v: int) =
  if c.version != v: raise newException(InvalidOperationException, modifiedMsg)

template checkIndex(i, len: int) =
  if i < 0 or i >= len: raise newException(ArgumentOutOfRangeException, indexMsg)

template checkRange(index, count, len: int) =
  ## `(index, count)` must name a slice of the collection, as .NET requires.
  if index < 0 or count < 0:
    raise newException(ArgumentOutOfRangeException, indexMsg)
  if len - index < count:
    raise newException(ArgumentException, "Offset and length were out of " &
      "bounds for the array or count is greater than the number of elements " &
      "from index to the end of the source collection.")

proc keyMissing[K](k: K): ref KeyNotFoundException =
  newException(KeyNotFoundException,
               "The given key '" & $k & "' was not present in the dictionary.")

proc keyDuplicate[K](k: K): ref ArgumentException =
  newException(ArgumentException,
               "An item with the same key has already been added. Key: " & $k)

proc snapshot[T](collection: Enumerable[T]): seq[T] =
  ## The elements of any collection (C#'s `IEnumerable<T>`), copied first, so a
  ## member may be handed its own receiver. `items` is bound where the procs taking
  ## a collection are instantiated, so it reaches the iterators declared below.
  mixin items
  for x in collection: result.add x

proc lowerBound[T](s: seq[T]; x: T): int =
  ## The first index whose element is not less than `x`.
  var lo = 0
  var hi = s.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if s[mid] < x: lo = mid + 1
    else: hi = mid
  lo

proc cmpOf[T](c: Comparison[T]): proc (a, b: T): int =
  result = proc (a, b: T): int = int(c(a, b))

{.push discardable.}

# --- constructors -----------------------------------------------------------

proc newList*[T](): List[T] = List[T]()
proc newList*[T](capacity: int): List[T] =
  if capacity < 0: raise newException(ArgumentOutOfRangeException, indexMsg)
  List[T](data: newSeqOfCap[T](capacity))

proc newKeyValuePair*[K, V](key: K; value: V): KeyValuePair[K, V] =
  KeyValuePair[K, V](Key: key, Value: value)

proc newDictionary*[K, V](): Dictionary[K, V] =
  Dictionary[K, V](data: initOrderedTable[K, V]())
proc newDictionary*[K, V](capacity: int): Dictionary[K, V] =
  Dictionary[K, V](data: initOrderedTable[K, V](max(capacity, 0)))
proc newDictionary*[K, V](dictionary: Dictionary[K, V]): Dictionary[K, V] =
  Dictionary[K, V](data: dictionary.data)

proc newHashSet*[T](): HashSet[T] = HashSet[T](data: initOrderedSet[T]())
proc newHashSet*[T](capacity: int): HashSet[T] =
  HashSet[T](data: initOrderedSet[T](max(capacity, 0)))
proc newSortedSet*[T](): SortedSet[T] = SortedSet[T]()

proc newSortedDictionary*[K, V](): SortedDictionary[K, V] = SortedDictionary[K, V]()
proc newSortedList*[K, V](): SortedList[K, V] = SortedList[K, V]()
proc newSortedList*[K, V](capacity: int): SortedList[K, V] = SortedList[K, V]()

proc newQueue*[T](): Queue[T] = Queue[T](data: initDeque[T]())
proc newQueue*[T](capacity: int): Queue[T] =
  Queue[T](data: initDeque[T](max(capacity, 0)))
proc newStack*[T](): Stack[T] = Stack[T]()
proc newStack*[T](capacity: int): Stack[T] =
  Stack[T](data: newSeqOfCap[T](max(capacity, 0)))

# A constructor from C#'s `IEnumerable<T>` is written once per source type: Nim
# cannot take the element type explicitly (`newList[int32](xs)`) and infer the
# source through a type class at the same time.

proc listOf[T](s: seq[T]): List[T] = List[T](data: s)
proc hashSetOf[T](s: seq[T]): HashSet[T] =
  result = HashSet[T](data: initOrderedSet[T]())
  for x in s: result.data.incl x
proc sortedSetOf[T](s: seq[T]): SortedSet[T] =
  result = SortedSet[T](data: s)
  algorithm.sort(result.data)
  result.data = deduplicate(result.data, isSorted = true)
proc queueOf[T](s: seq[T]): Queue[T] = Queue[T](data: toDeque(s))
proc stackOf[T](s: seq[T]): Stack[T] = Stack[T](data: s)

template fromEnumerable(ctor, build: untyped) =
  proc ctor*[T](collection: openArray[T]): auto = build(@collection)
  proc ctor*[T](collection: List[T]): auto = build(snapshot(collection))
  proc ctor*[T](collection: HashSet[T]): auto = build(snapshot(collection))
  proc ctor*[T](collection: SortedSet[T]): auto = build(snapshot(collection))
  proc ctor*[T](collection: Queue[T]): auto = build(snapshot(collection))
  proc ctor*[T](collection: Stack[T]): auto = build(snapshot(collection))
  proc ctor*[T](collection: LinkedList[T]): auto = build(snapshot(collection))
  proc ctor*[T](collection: IEnumerable[T]): auto = build(snapshot(collection))

fromEnumerable(newList, listOf)
fromEnumerable(newHashSet, hashSetOf)
fromEnumerable(newSortedSet, sortedSetOf)
fromEnumerable(newQueue, queueOf)
fromEnumerable(newStack, stackOf)

proc newLinkedListNode*[T](value: T): LinkedListNode[T] =
  LinkedListNode[T](Value: value)
proc newLinkedList*[T](): LinkedList[T] = LinkedList[T]()

proc newPriorityQueue*[E, P](): PriorityQueue[E, P] = PriorityQueue[E, P]()
proc newPriorityQueue*[E, P](capacity: int): PriorityQueue[E, P] =
  PriorityQueue[E, P](nodes: newSeqOfCap[(E, P)](max(capacity, 0)))

# --- Count ------------------------------------------------------------------

proc Count*[T](l: List[T]): int32 = int32(l.data.len)
proc Count*[K, V](t: Dictionary[K, V]): int32 = int32(t.data.len)
proc Count*[T](s: HashSet[T]): int32 = int32(s.data.len)
proc Count*[T](s: SortedSet[T]): int32 = int32(s.data.len)
proc Count*[K, V](t: SortedDictionary[K, V]): int32 = int32(t.keys.len)
proc Count*[K, V](t: SortedList[K, V]): int32 = int32(t.keys.len)
proc Count*[T](q: Queue[T]): int32 = int32(q.data.len)
proc Count*[T](s: Stack[T]): int32 = int32(s.data.len)
proc Count*[T](l: LinkedList[T]): int32 = int32(l.count)
proc Count*[E, P](q: PriorityQueue[E, P]): int32 = int32(q.nodes.len)

# --- List<T> ----------------------------------------------------------------

proc `[]`*[T](l: List[T]; i: int): T =
  checkIndex(i, l.data.len)
  l.data[i]
proc `[]=`*[T](l: List[T]; i: int; x: T) =
  checkIndex(i, l.data.len)
  l.data[i] = x
  touch l

iterator items*[T](l: List[T]): T =
  let v = l.version
  var i = 0
  while true:
    checkVersion(l, v)
    if i >= l.data.len: break
    yield l.data[i]
    inc i

proc Add*[T](l: List[T]; x: T) =
  l.data.add x
  touch l
proc AddRange*[T](l: List[T]; collection: Enumerable[T]) =
  l.data.add snapshot(collection)
  touch l
proc Clear*[T](l: List[T]) =
  l.data.setLen(0)
  touch l
proc Contains*[T](l: List[T]; x: T): bool = x in l.data
proc IndexOf*[T](l: List[T]; x: T): int32 = int32(l.data.find(x))
proc IndexOf*[T](l: List[T]; x: T; index: int): int32 =
  if index < 0 or index > l.data.len:
    raise newException(ArgumentOutOfRangeException, indexMsg)
  for i in index ..< l.data.len:
    if l.data[i] == x: return int32(i)
  -1
proc LastIndexOf*[T](l: List[T]; x: T): int32 =
  for i in countdown(l.data.high, 0):
    if l.data[i] == x: return int32(i)
  -1
proc Insert*[T](l: List[T]; i: int; x: T) =
  if i < 0 or i > l.data.len:
    raise newException(ArgumentOutOfRangeException, indexMsg)
  l.data.insert(x, i)
  touch l
proc InsertRange*[T](l: List[T]; i: int; collection: Enumerable[T]) =
  if i < 0 or i > l.data.len:
    raise newException(ArgumentOutOfRangeException, indexMsg)
  l.data.insert(snapshot(collection), i)
  touch l
proc RemoveAt*[T](l: List[T]; i: int) =
  checkIndex(i, l.data.len)
  l.data.delete(i)
  touch l
proc RemoveRange*[T](l: List[T]; index, count: int) =
  checkRange(index, count, l.data.len)
  if count > 0:
    l.data = l.data[0 ..< index] & l.data[index + count .. ^1]
    touch l
proc Remove*[T](l: List[T]; x: T): bool =
  let i = l.data.find(x)
  if i >= 0:
    l.data.delete(i)
    touch l
    result = true
proc RemoveAll*[T](l: List[T]; match: Predicate[T]): int32 =
  var kept: seq[T] = @[]
  for x in l.data:
    if match(x): inc result
    else: kept.add x
  if result > 0:
    l.data = kept
    touch l
proc GetRange*[T](l: List[T]; index, count: int): List[T] =
  checkRange(index, count, l.data.len)
  List[T](data: l.data[index ..< index + count])
proc Reverse*[T](l: List[T]) =
  algorithm.reverse(l.data)
  touch l
proc Reverse*[T](l: List[T]; index, count: int) =
  checkRange(index, count, l.data.len)
  if count > 0: algorithm.reverse(l.data, index, index + count - 1)
  touch l
proc Sort*[T](l: List[T]) =
  algorithm.sort(l.data)
  touch l
proc Sort*[T](l: List[T]; comparison: Comparison[T]) =
  algorithm.sort(l.data, cmpOf(comparison))
  touch l
proc BinarySearch*[T](l: List[T]; x: T): int32 =
  ## The index of `x` in a sorted list, or the complement of where it would go.
  var lo = 0
  var hi = l.data.high
  while lo <= hi:
    let mid = (lo + hi) div 2
    let c = cmp(l.data[mid], x)
    if c == 0: return int32(mid)
    if c < 0: lo = mid + 1
    else: hi = mid - 1
  not int32(lo)
proc Exists*[T](l: List[T]; match: Predicate[T]): bool =
  for x in l.data:
    if match(x): return true
proc TrueForAll*[T](l: List[T]; match: Predicate[T]): bool =
  for x in l.data:
    if not match(x): return false
  true
proc Find*[T](l: List[T]; match: Predicate[T]): T =
  ## The first match, or `default(T)` when there is none, as .NET returns.
  for x in l.data:
    if match(x): return x
  default(T)
proc FindLast*[T](l: List[T]; match: Predicate[T]): T =
  for i in countdown(l.data.high, 0):
    if match(l.data[i]): return l.data[i]
  default(T)
proc FindIndex*[T](l: List[T]; match: Predicate[T]): int32 =
  for i in 0 ..< l.data.len:
    if match(l.data[i]): return int32(i)
  -1
proc FindLastIndex*[T](l: List[T]; match: Predicate[T]): int32 =
  for i in countdown(l.data.high, 0):
    if match(l.data[i]): return int32(i)
  -1
proc FindAll*[T](l: List[T]; match: Predicate[T]): List[T] =
  result = List[T]()
  for x in l.data:
    if match(x): result.data.add x
proc ForEach*[T](l: List[T]; action: Action[T]) =
  let v = l.version
  for i in 0 ..< l.data.len:
    checkVersion(l, v)
    action(l.data[i])
  checkVersion(l, v)
proc ConvertAll*[T, U](l: List[T]; conv: Converter[T, U]): List[U] =
  result = List[U]()
  for x in l.data: result.data.add conv(x)
proc CopyTo*[T](l: List[T]; arr: var openArray[T]) =
  for i in 0 ..< l.data.len: arr[i] = l.data[i]
proc CopyTo*[T](l: List[T]; arr: var openArray[T]; arrayIndex: int) =
  for i in 0 ..< l.data.len: arr[arrayIndex + i] = l.data[i]
proc ToArray*[T](l: List[T]): seq[T] = l.data
proc TrimExcess*[T](l: List[T]) = discard

# --- Dictionary<K, V> -------------------------------------------------------

proc `[]`*[K, V](t: Dictionary[K, V]; k: K): V =
  if not t.data.hasKey(k): raise keyMissing(k)
  t.data[k]
proc `[]=`*[K, V](t: Dictionary[K, V]; k: K; v: V) =
  t.data[k] = v
  touch t

iterator items*[K, V](t: Dictionary[K, V]): KeyValuePair[K, V] =
  let v = t.version
  for k, x in t.data.pairs:
    yield KeyValuePair[K, V](Key: k, Value: x)
    checkVersion(t, v)

proc Add*[K, V](t: Dictionary[K, V]; k: K; v: V) =
  if t.data.hasKey(k): raise keyDuplicate(k)
  t.data[k] = v
  touch t
proc TryAdd*[K, V](t: Dictionary[K, V]; k: K; v: V): bool =
  if t.data.hasKey(k): return false
  t.data[k] = v
  touch t
  true
proc Clear*[K, V](t: Dictionary[K, V]) =
  t.data.clear()
  touch t
proc ContainsKey*[K, V](t: Dictionary[K, V]; k: K): bool = t.data.hasKey(k)
proc ContainsValue*[K, V](t: Dictionary[K, V]; v: V): bool =
  for x in t.data.values:
    if x == v: return true
proc GetValueOrDefault*[K, V](t: Dictionary[K, V]; k: K): V =
  t.data.getOrDefault(k)
proc GetValueOrDefault*[K, V](t: Dictionary[K, V]; k: K; defaultValue: V): V =
  t.data.getOrDefault(k, defaultValue)
proc Remove*[K, V](t: Dictionary[K, V]; k: K): bool =
  if t.data.hasKey(k):
    t.data.del(k)
    touch t
    result = true
proc Keys*[K, V](t: Dictionary[K, V]): KeyCollection[K, V] =
  KeyCollection[K, V](dict: t)
proc Values*[K, V](t: Dictionary[K, V]): ValueCollection[K, V] =
  ValueCollection[K, V](dict: t)

# --- HashSet<T> -------------------------------------------------------------

iterator items*[T](s: HashSet[T]): T =
  let v = s.version
  for x in sets.items(s.data):
    yield x
    checkVersion(s, v)

proc Add*[T](s: HashSet[T]; x: T): bool =
  ## Reports whether the element was new, exactly as .NET's does.
  if s.data.containsOrIncl(x): false
  else:
    touch s
    true
proc Clear*[T](s: HashSet[T]) =
  s.data.clear()
  touch s
proc Contains*[T](s: HashSet[T]; x: T): bool = x in s.data
proc Remove*[T](s: HashSet[T]; x: T): bool =
  if s.data.missingOrExcl(x): false
  else:
    touch s
    true
proc RemoveWhere*[T](s: HashSet[T]; match: Predicate[T]): int32 =
  var gone: seq[T] = @[]
  for x in sets.items(s.data):
    if match(x): gone.add x
  for x in gone: s.data.excl x
  if gone.len > 0: touch s
  int32(gone.len)
proc ToArray*[T](s: HashSet[T]): seq[T] =
  for x in sets.items(s.data): result.add x
proc UnionWith*[T](s: HashSet[T]; other: Enumerable[T]) =
  for x in snapshot(other): s.data.incl x
  touch s
proc IntersectWith*[T](s: HashSet[T]; other: Enumerable[T]) =
  var keep = initHashSet[T]()
  for x in snapshot(other): keep.incl x
  var next = initOrderedSet[T]()
  for x in sets.items(s.data):
    if x in keep: next.incl x
  s.data = next
  touch s
proc ExceptWith*[T](s: HashSet[T]; other: Enumerable[T]) =
  for x in snapshot(other): s.data.excl x
  touch s
proc SymmetricExceptWith*[T](s: HashSet[T]; other: Enumerable[T]) =
  var seen = initHashSet[T]()
  for x in snapshot(other):
    if seen.containsOrIncl(x): continue
    if x in s.data: s.data.excl x
    else: s.data.incl x
  touch s

# The set comparisons read `other` as a set: duplicates in it do not count.
proc otherSet[T](other: Enumerable[T]): sets.HashSet[T] =
  result = initHashSet[T]()
  for x in snapshot(other): result.incl x

proc IsSubsetOf*[T](s: HashSet[T]; other: Enumerable[T]): bool =
  let o = otherSet(other)
  for x in sets.items(s.data):
    if x notin o: return false
  true
proc IsProperSubsetOf*[T](s: HashSet[T]; other: Enumerable[T]): bool =
  let o = otherSet(other)
  if o.len <= s.data.len: return false
  for x in sets.items(s.data):
    if x notin o: return false
  true
proc IsSupersetOf*[T](s: HashSet[T]; other: Enumerable[T]): bool =
  for x in snapshot(other):
    if x notin s.data: return false
  true
proc IsProperSupersetOf*[T](s: HashSet[T]; other: Enumerable[T]): bool =
  let o = otherSet(other)
  if o.len >= s.data.len: return false
  for x in sets.items(o):
    if x notin s.data: return false
  true
proc Overlaps*[T](s: HashSet[T]; other: Enumerable[T]): bool =
  for x in snapshot(other):
    if x in s.data: return true
proc SetEquals*[T](s: HashSet[T]; other: Enumerable[T]): bool =
  let o = otherSet(other)
  if o.len != s.data.len: return false
  for x in sets.items(o):
    if x notin s.data: return false
  true

# --- SortedSet<T> -----------------------------------------------------------

iterator items*[T](s: SortedSet[T]): T =
  let v = s.version
  var i = 0
  while true:
    checkVersion(s, v)
    if i >= s.data.len: break
    yield s.data[i]
    inc i

proc Add*[T](s: SortedSet[T]; x: T): bool =
  let i = lowerBound(s.data, x)
  if i < s.data.len and s.data[i] == x: return false
  s.data.insert(x, i)
  touch s
  true
proc Clear*[T](s: SortedSet[T]) =
  s.data.setLen(0)
  touch s
proc Contains*[T](s: SortedSet[T]; x: T): bool =
  let i = lowerBound(s.data, x)
  i < s.data.len and s.data[i] == x
proc Remove*[T](s: SortedSet[T]; x: T): bool =
  let i = lowerBound(s.data, x)
  if i < s.data.len and s.data[i] == x:
    s.data.delete(i)
    touch s
    result = true
proc RemoveWhere*[T](s: SortedSet[T]; match: Predicate[T]): int32 =
  var kept: seq[T] = @[]
  for x in s.data:
    if match(x): inc result
    else: kept.add x
  if result > 0:
    s.data = kept
    touch s
proc Min*[T](s: SortedSet[T]): T =
  ## `default(T)` on an empty set, as .NET returns.
  if s.data.len == 0: default(T) else: s.data[0]
proc Max*[T](s: SortedSet[T]): T =
  if s.data.len == 0: default(T) else: s.data[^1]
proc Reverse*[T](s: SortedSet[T]): List[T] =
  ## The elements in descending order.
  result = List[T]()
  for i in countdown(s.data.high, 0): result.data.add s.data[i]
proc ToArray*[T](s: SortedSet[T]): seq[T] = s.data
proc UnionWith*[T](s: SortedSet[T]; other: Enumerable[T]) =
  for x in snapshot(other): discard s.Add(x)
  touch s
proc IntersectWith*[T](s: SortedSet[T]; other: Enumerable[T]) =
  let o = otherSet(other)
  var kept: seq[T] = @[]
  for x in s.data:
    if x in o: kept.add x
  s.data = kept
  touch s
proc ExceptWith*[T](s: SortedSet[T]; other: Enumerable[T]) =
  for x in snapshot(other): discard s.Remove(x)
  touch s
proc SymmetricExceptWith*[T](s: SortedSet[T]; other: Enumerable[T]) =
  for x in sets.items(otherSet(other)):
    if not s.Remove(x): discard s.Add(x)
  touch s
proc IsSubsetOf*[T](s: SortedSet[T]; other: Enumerable[T]): bool =
  let o = otherSet(other)
  for x in s.data:
    if x notin o: return false
  true
proc IsProperSubsetOf*[T](s: SortedSet[T]; other: Enumerable[T]): bool =
  let o = otherSet(other)
  if o.len <= s.data.len: return false
  for x in s.data:
    if x notin o: return false
  true
proc IsSupersetOf*[T](s: SortedSet[T]; other: Enumerable[T]): bool =
  for x in snapshot(other):
    if not s.Contains(x): return false
  true
proc IsProperSupersetOf*[T](s: SortedSet[T]; other: Enumerable[T]): bool =
  let o = otherSet(other)
  if o.len >= s.data.len: return false
  for x in sets.items(o):
    if not s.Contains(x): return false
  true
proc Overlaps*[T](s: SortedSet[T]; other: Enumerable[T]): bool =
  for x in snapshot(other):
    if s.Contains(x): return true
proc SetEquals*[T](s: SortedSet[T]; other: Enumerable[T]): bool =
  let o = otherSet(other)
  if o.len != s.data.len: return false
  for x in sets.items(o):
    if not s.Contains(x): return false
  true

# --- SortedDictionary<K, V> and SortedList<K, V> -----------------------------
#
# The two share a store, so each member is written once over its fields and
# declared on both types below.

proc findKey[K](keys: seq[K]; k: K): int =
  ## The key's index, or -1.
  let i = lowerBound(keys, k)
  if i < keys.len and keys[i] == k: i else: -1

template sortedGet(t, k: untyped): untyped =
  let i = findKey(t.keys, k)
  if i < 0: raise keyMissing(k)
  t.vals[i]

template sortedSet(t, k, v: untyped) =
  let i = lowerBound(t.keys, k)
  if i < t.keys.len and t.keys[i] == k: t.vals[i] = v
  else:
    t.keys.insert(k, i)
    t.vals.insert(v, i)
  touch t

template sortedAdd(t, k, v: untyped) =
  let i = lowerBound(t.keys, k)
  if i < t.keys.len and t.keys[i] == k: raise keyDuplicate(k)
  t.keys.insert(k, i)
  t.vals.insert(v, i)
  touch t

template sortedRemove(t, k: untyped): bool =
  let i = findKey(t.keys, k)
  if i >= 0:
    t.keys.delete(i)
    t.vals.delete(i)
    touch t
  i >= 0

template sortedItems(t: untyped; K, V: typedesc) =
  let v = t.version
  var i = 0
  while true:
    checkVersion(t, v)
    if i >= t.keys.len: break
    yield KeyValuePair[K, V](Key: t.keys[i], Value: t.vals[i])
    inc i

proc `[]`*[K, V](t: SortedDictionary[K, V]; k: K): V = sortedGet(t, k)
proc `[]=`*[K, V](t: SortedDictionary[K, V]; k: K; v: V) = sortedSet(t, k, v)
iterator items*[K, V](t: SortedDictionary[K, V]): KeyValuePair[K, V] =
  sortedItems(t, K, V)
proc Add*[K, V](t: SortedDictionary[K, V]; k: K; v: V) = sortedAdd(t, k, v)
proc TryAdd*[K, V](t: SortedDictionary[K, V]; k: K; v: V): bool =
  if findKey(t.keys, k) >= 0: return false
  sortedAdd(t, k, v)
  true
proc Clear*[K, V](t: SortedDictionary[K, V]) =
  t.keys.setLen(0)
  t.vals.setLen(0)
  touch t
proc ContainsKey*[K, V](t: SortedDictionary[K, V]; k: K): bool =
  findKey(t.keys, k) >= 0
proc ContainsValue*[K, V](t: SortedDictionary[K, V]; v: V): bool = v in t.vals
proc GetValueOrDefault*[K, V](t: SortedDictionary[K, V]; k: K): V =
  let i = findKey(t.keys, k)
  if i < 0: default(V) else: t.vals[i]
proc GetValueOrDefault*[K, V](t: SortedDictionary[K, V]; k: K; defaultValue: V): V =
  let i = findKey(t.keys, k)
  if i < 0: defaultValue else: t.vals[i]
proc Remove*[K, V](t: SortedDictionary[K, V]; k: K): bool = sortedRemove(t, k)
proc Keys*[K, V](t: SortedDictionary[K, V]): KeyCollection[K, V] =
  KeyCollection[K, V](sorted: t)
proc Values*[K, V](t: SortedDictionary[K, V]): ValueCollection[K, V] =
  ValueCollection[K, V](sorted: t)

proc `[]`*[K, V](t: SortedList[K, V]; k: K): V = sortedGet(t, k)
proc `[]=`*[K, V](t: SortedList[K, V]; k: K; v: V) = sortedSet(t, k, v)
iterator items*[K, V](t: SortedList[K, V]): KeyValuePair[K, V] =
  sortedItems(t, K, V)
proc Add*[K, V](t: SortedList[K, V]; k: K; v: V) = sortedAdd(t, k, v)
proc TryAdd*[K, V](t: SortedList[K, V]; k: K; v: V): bool =
  if findKey(t.keys, k) >= 0: return false
  sortedAdd(t, k, v)
  true
proc Clear*[K, V](t: SortedList[K, V]) =
  t.keys.setLen(0)
  t.vals.setLen(0)
  touch t
proc ContainsKey*[K, V](t: SortedList[K, V]; k: K): bool = findKey(t.keys, k) >= 0
proc ContainsValue*[K, V](t: SortedList[K, V]; v: V): bool = v in t.vals
proc GetValueOrDefault*[K, V](t: SortedList[K, V]; k: K): V =
  let i = findKey(t.keys, k)
  if i < 0: default(V) else: t.vals[i]
proc GetValueOrDefault*[K, V](t: SortedList[K, V]; k: K; defaultValue: V): V =
  let i = findKey(t.keys, k)
  if i < 0: defaultValue else: t.vals[i]
proc Remove*[K, V](t: SortedList[K, V]; k: K): bool = sortedRemove(t, k)
proc RemoveAt*[K, V](t: SortedList[K, V]; index: int) =
  checkIndex(index, t.keys.len)
  t.keys.delete(index)
  t.vals.delete(index)
  touch t
proc Keys*[K, V](t: SortedList[K, V]): KeyCollection[K, V] =
  ## C# types this `IList<K>`; it is the same live view here.
  KeyCollection[K, V](list: t)
proc Values*[K, V](t: SortedList[K, V]): ValueCollection[K, V] =
  ValueCollection[K, V](list: t)

# --- KeyCollection and ValueCollection ---------------------------------------
#
# Views, not copies: they read the dictionary they came from, so a key added after
# `Keys` was taken is seen, and walking one while its dictionary changes throws.

proc Count*[K, V](c: KeyCollection[K, V]): int32 =
  if c.dict != nil: c.dict.Count
  elif c.sorted != nil: c.sorted.Count
  else: c.list.Count
proc Count*[K, V](c: ValueCollection[K, V]): int32 =
  if c.dict != nil: c.dict.Count
  elif c.sorted != nil: c.sorted.Count
  else: c.list.Count

iterator items*[K, V](c: KeyCollection[K, V]): K =
  if c.dict != nil:
    for kv in c.dict: yield kv.Key
  elif c.sorted != nil:
    for kv in c.sorted: yield kv.Key
  else:
    for kv in c.list: yield kv.Key
iterator items*[K, V](c: ValueCollection[K, V]): V =
  if c.dict != nil:
    for kv in c.dict: yield kv.Value
  elif c.sorted != nil:
    for kv in c.sorted: yield kv.Value
  else:
    for kv in c.list: yield kv.Value

proc CopyTo*[K, V](c: KeyCollection[K, V]; arr: var openArray[K]; index: int) =
  var i = index
  for k in c:
    arr[i] = k
    inc i
proc CopyTo*[K, V](c: ValueCollection[K, V]; arr: var openArray[V]; index: int) =
  var i = index
  for v in c:
    arr[i] = v
    inc i
proc IndexOfKey*[K, V](t: SortedList[K, V]; k: K): int32 = int32(findKey(t.keys, k))
proc IndexOfValue*[K, V](t: SortedList[K, V]; v: V): int32 = int32(t.vals.find(v))
proc GetKeyAtIndex*[K, V](t: SortedList[K, V]; index: int): K =
  checkIndex(index, t.keys.len)
  t.keys[index]
proc GetValueAtIndex*[K, V](t: SortedList[K, V]; index: int): V =
  checkIndex(index, t.keys.len)
  t.vals[index]

# --- Queue<T> (FIFO) --------------------------------------------------------

iterator items*[T](q: Queue[T]): T =
  ## Front to back, the order `Dequeue` would give.
  let v = q.version
  var i = 0
  while true:
    checkVersion(q, v)
    if i >= q.data.len: break
    yield q.data[i]
    inc i

proc Enqueue*[T](q: Queue[T]; x: T) =
  q.data.addLast x
  touch q
proc Dequeue*[T](q: Queue[T]): T =
  if q.data.len == 0: raise newException(InvalidOperationException, "Queue empty.")
  touch q
  q.data.popFirst
proc Peek*[T](q: Queue[T]): T =
  if q.data.len == 0: raise newException(InvalidOperationException, "Queue empty.")
  q.data.peekFirst
proc Contains*[T](q: Queue[T]; x: T): bool = x in q.data
proc Clear*[T](q: Queue[T]) =
  q.data.clear()
  touch q
proc ToArray*[T](q: Queue[T]): seq[T] =
  for x in q.data: result.add x
proc CopyTo*[T](q: Queue[T]; arr: var openArray[T]; arrayIndex: int) =
  var i = arrayIndex
  for x in q.data:
    arr[i] = x
    inc i
proc TrimExcess*[T](q: Queue[T]) = discard

# --- Stack<T> (LIFO) --------------------------------------------------------

iterator items*[T](s: Stack[T]): T =
  ## Top to bottom, the order `Pop` would give, as .NET enumerates a stack.
  let v = s.version
  var i = s.data.high
  while true:
    checkVersion(s, v)
    if i < 0: break
    yield s.data[i]
    dec i

proc Push*[T](s: Stack[T]; x: T) =
  s.data.add x
  touch s
proc Pop*[T](s: Stack[T]): T =
  if s.data.len == 0: raise newException(InvalidOperationException, "Stack empty.")
  touch s
  s.data.pop
proc Peek*[T](s: Stack[T]): T =
  if s.data.len == 0: raise newException(InvalidOperationException, "Stack empty.")
  s.data[^1]
proc Contains*[T](s: Stack[T]; x: T): bool = x in s.data
proc Clear*[T](s: Stack[T]) =
  s.data.setLen(0)
  touch s
proc ToArray*[T](s: Stack[T]): seq[T] =
  ## Top first, as .NET orders it.
  for i in countdown(s.data.high, 0): result.add s.data[i]
proc CopyTo*[T](s: Stack[T]; arr: var openArray[T]; arrayIndex: int) =
  var i = arrayIndex
  for j in countdown(s.data.high, 0):
    arr[i] = s.data[j]
    inc i
proc TrimExcess*[T](s: Stack[T]) = discard

# --- LinkedList<T> and LinkedListNode<T> -------------------------------------

proc Next*[T](n: LinkedListNode[T]): LinkedListNode[T] = n.next
proc Previous*[T](n: LinkedListNode[T]): LinkedListNode[T] = n.prev

proc First*[T](l: LinkedList[T]): LinkedListNode[T] = l.head
proc Last*[T](l: LinkedList[T]): LinkedListNode[T] = l.tail

iterator items*[T](l: LinkedList[T]): T =
  let v = l.version
  var n = l.head
  while true:
    checkVersion(l, v)
    if n == nil: break
    yield n.Value
    n = n.next

proc checkOwned[T](l: LinkedList[T]; node: LinkedListNode[T]) =
  if node == nil:
    raise newException(ArgumentNullException, "Value cannot be null. (Parameter 'node')")
  if node.owner != l:
    raise newException(InvalidOperationException,
                       "The LinkedList node does not belong to current LinkedList.")

proc checkFree[T](node: LinkedListNode[T]) =
  if node == nil:
    raise newException(ArgumentNullException, "Value cannot be null. (Parameter 'node')")
  if node.owner != nil:
    raise newException(InvalidOperationException,
                       "The LinkedList node already belongs to a LinkedList.")

proc linkBefore[T](l: LinkedList[T]; at, node: LinkedListNode[T]) =
  ## Links a free node before `at`, or at the end when `at` is nil.
  node.owner = l
  node.next = at
  if at == nil:
    node.prev = l.tail
    if l.tail != nil: l.tail.next = node
    else: l.head = node
    l.tail = node
  else:
    node.prev = at.prev
    if at.prev != nil: at.prev.next = node
    else: l.head = node
    at.prev = node
  inc l.count
  touch l

proc unlink[T](l: LinkedList[T]; node: LinkedListNode[T]) =
  if node.prev != nil: node.prev.next = node.next
  else: l.head = node.next
  if node.next != nil: node.next.prev = node.prev
  else: l.tail = node.prev
  node.owner = nil
  node.next = nil
  node.prev = nil
  dec l.count
  touch l

proc AddFirst*[T](l: LinkedList[T]; x: T): LinkedListNode[T] =
  result = LinkedListNode[T](Value: x)
  l.linkBefore(l.head, result)
proc AddFirst*[T](l: LinkedList[T]; node: LinkedListNode[T]) =
  checkFree(node)
  l.linkBefore(l.head, node)
proc AddLast*[T](l: LinkedList[T]; x: T): LinkedListNode[T] =
  result = LinkedListNode[T](Value: x)
  l.linkBefore(nil, result)
proc AddLast*[T](l: LinkedList[T]; node: LinkedListNode[T]) =
  checkFree(node)
  l.linkBefore(nil, node)
proc AddBefore*[T](l: LinkedList[T]; at: LinkedListNode[T]; x: T): LinkedListNode[T] =
  l.checkOwned(at)
  result = LinkedListNode[T](Value: x)
  l.linkBefore(at, result)
proc AddBefore*[T](l: LinkedList[T]; at, node: LinkedListNode[T]) =
  l.checkOwned(at)
  checkFree(node)
  l.linkBefore(at, node)
proc AddAfter*[T](l: LinkedList[T]; at: LinkedListNode[T]; x: T): LinkedListNode[T] =
  l.checkOwned(at)
  result = LinkedListNode[T](Value: x)
  l.linkBefore(at.next, result)
proc AddAfter*[T](l: LinkedList[T]; at, node: LinkedListNode[T]) =
  l.checkOwned(at)
  checkFree(node)
  l.linkBefore(at.next, node)
proc Find*[T](l: LinkedList[T]; x: T): LinkedListNode[T] =
  ## The first node holding `x`, or null.
  var n = l.head
  while n != nil:
    if n.Value == x: return n
    n = n.next
proc FindLast*[T](l: LinkedList[T]; x: T): LinkedListNode[T] =
  var n = l.tail
  while n != nil:
    if n.Value == x: return n
    n = n.prev
proc Contains*[T](l: LinkedList[T]; x: T): bool = l.Find(x) != nil
proc Remove*[T](l: LinkedList[T]; x: T): bool =
  ## Drops the first node holding `x`.
  let n = l.Find(x)
  if n != nil:
    l.unlink(n)
    result = true
proc Remove*[T](l: LinkedList[T]; node: LinkedListNode[T]) =
  l.checkOwned(node)
  l.unlink(node)
proc RemoveFirst*[T](l: LinkedList[T]) =
  if l.head == nil:
    raise newException(InvalidOperationException, "The LinkedList is empty.")
  l.unlink(l.head)
proc RemoveLast*[T](l: LinkedList[T]) =
  if l.tail == nil:
    raise newException(InvalidOperationException, "The LinkedList is empty.")
  l.unlink(l.tail)
proc Clear*[T](l: LinkedList[T]) =
  var n = l.head
  while n != nil:
    let next = n.next
    n.owner = nil
    n.next = nil
    n.prev = nil
    n = next
  l.head = nil
  l.tail = nil
  l.count = 0
  touch l
proc CopyTo*[T](l: LinkedList[T]; arr: var openArray[T]; arrayIndex: int) =
  var i = arrayIndex
  for x in l:
    arr[i] = x
    inc i

# --- PriorityQueue<TElement, TPriority> --------------------------------------
#
# .NET's own 4-ary min-heap, step for step: the order elements of equal priority
# leave in is part of the observable behaviour.

proc moveUp[E, P](q: PriorityQueue[E, P]; node: (E, P); index: int) =
  var i = index
  while i > 0:
    let parent = (i - 1) shr 2
    if node[1] < q.nodes[parent][1]:
      q.nodes[i] = q.nodes[parent]
      i = parent
    else: break
  q.nodes[i] = node

proc moveDown[E, P](q: PriorityQueue[E, P]; node: (E, P); index: int) =
  var i = index
  let size = q.nodes.len
  while true:
    var c = (i shl 2) + 1
    if c >= size: break
    var minIndex = c
    let upper = min(c + 4, size)
    inc c
    while c < upper:
      if q.nodes[c][1] < q.nodes[minIndex][1]: minIndex = c
      inc c
    if not (q.nodes[minIndex][1] < node[1]): break
    q.nodes[i] = q.nodes[minIndex]
    i = minIndex
  q.nodes[i] = node

proc Enqueue*[E, P](q: PriorityQueue[E, P]; element: E; priority: P) =
  let node = (element, priority)
  q.nodes.add node
  q.moveUp(node, q.nodes.high)
  touch q
proc Peek*[E, P](q: PriorityQueue[E, P]): E =
  if q.nodes.len == 0: raise newException(InvalidOperationException, "Queue empty.")
  q.nodes[0][0]
proc Dequeue*[E, P](q: PriorityQueue[E, P]): E =
  if q.nodes.len == 0: raise newException(InvalidOperationException, "Queue empty.")
  result = q.nodes[0][0]
  let last = q.nodes.pop
  if q.nodes.len > 0: q.moveDown(last, 0)
  touch q
proc EnqueueDequeue*[E, P](q: PriorityQueue[E, P]; element: E; priority: P): E =
  ## Enqueues, then dequeues; an element that would leave at once never enters.
  if q.nodes.len == 0 or not (q.nodes[0][1] < priority): return element
  result = q.nodes[0][0]
  q.moveDown((element, priority), 0)
  touch q
proc Clear*[E, P](q: PriorityQueue[E, P]) =
  q.nodes.setLen(0)
  touch q

{.pop.}

# --- IEnumerable<T> / IEnumerator<T> -------------------------------------------
#
# C#'s sequence interfaces, as the one shape every iterator method returns: an
# `IEnumerable<T>` makes a fresh `IEnumerator<T>` per enumeration, and the
# enumerator runs a closure iterator one step per `MoveNext`. An iterator method
# (`yield return`) lowers to `nsEnumerable(T): body` (or `nsEnumerator`), and every
# collection converts to `IEnumerable<T>` (`nsToIEnumerable`), enumerated live,
# as .NET's interface views are.

proc nsEnumeratorOf*[T](step: iterator(): T): IEnumerator[T] =
  ## The enumerator that runs `step`, one element per `MoveNext`.
  let e = IEnumerator[T](step: step)
  e.nsStep = proc (): bool =
    let v = e.step()
    if finished(e.step): return false
    e.current = v
    true
  e

proc Current*[T](e: IEnumerator[T]): T = e.current

proc Dispose*[T](e: IEnumerator[T]) = discard
  ## An enumerator holds nothing to release.

proc GetEnumerator*[T](s: IEnumerable[T]): IEnumerator[T] = s.make()

iterator items*[T](s: IEnumerable[T]): T =
  let e = s.make()
  while e.MoveNext(): yield e.current

template nsEnumerator*(T: typedesc; body: untyped): untyped =
  ## The enumerator of an iterator block whose member returns `IEnumerator<T>`.
  nsEnumeratorOf[T](iterator(): T {.closure.} =
    body)

template nsEnumerable*(T: typedesc; body: untyped): untyped =
  ## The sequence of an iterator block whose member returns `IEnumerable<T>`: each
  ## enumeration starts the block again.
  IEnumerable[T](make: proc(): IEnumerator[T] =
    nsEnumeratorOf[T](iterator(): T {.closure.} =
      body))

template nsSequenceView(xs: untyped; T: typedesc): untyped =
  IEnumerable[T](make: proc(): IEnumerator[T] =
    nsEnumeratorOf[T](iterator(): T {.closure.} =
      for x in xs: yield x))

# The compiler calls these where C# converts an array or a collection to
# `IEnumerable<T>` implicitly, so the view is enumerated live. A Nim converter
# would be tried, and fail to instantiate, wherever a ref value meets an
# overloaded operator.
proc nsToIEnumerable*[T](xs: seq[T]): IEnumerable[T] = nsSequenceView(xs, T)
proc nsToIEnumerable*[T](xs: List[T]): IEnumerable[T] = nsSequenceView(xs, T)
proc nsToIEnumerable*[T](xs: HashSet[T]): IEnumerable[T] = nsSequenceView(xs, T)
proc nsToIEnumerable*[T](xs: SortedSet[T]): IEnumerable[T] = nsSequenceView(xs, T)
proc nsToIEnumerable*[T](xs: Queue[T]): IEnumerable[T] = nsSequenceView(xs, T)
proc nsToIEnumerable*[T](xs: Stack[T]): IEnumerable[T] = nsSequenceView(xs, T)
proc nsToIEnumerable*[T](xs: LinkedList[T]): IEnumerable[T] = nsSequenceView(xs, T)

# --- `typeof` -----------------------------------------------------------------
#
# `typeof(List<int>)`: .NET's name, the type arguments' names in brackets.

const nsGenNs = "System.Collections.Generic."
proc nsTypeOf*[T](t: typedesc[List[T]]): Type =
  nsTypeNamed(nsGenericName(nsGenNs & "List", nsTypeOf(T).FullName))
proc nsTypeOf*[T](t: typedesc[HashSet[T]]): Type =
  nsTypeNamed(nsGenericName(nsGenNs & "HashSet", nsTypeOf(T).FullName))
proc nsTypeOf*[T](t: typedesc[SortedSet[T]]): Type =
  nsTypeNamed(nsGenericName(nsGenNs & "SortedSet", nsTypeOf(T).FullName))
proc nsTypeOf*[T](t: typedesc[Queue[T]]): Type =
  nsTypeNamed(nsGenericName(nsGenNs & "Queue", nsTypeOf(T).FullName))
proc nsTypeOf*[T](t: typedesc[Stack[T]]): Type =
  nsTypeNamed(nsGenericName(nsGenNs & "Stack", nsTypeOf(T).FullName))
proc nsTypeOf*[T](t: typedesc[LinkedList[T]]): Type =
  nsTypeNamed(nsGenericName(nsGenNs & "LinkedList", nsTypeOf(T).FullName))
proc nsTypeOf*[K, V](t: typedesc[Dictionary[K, V]]): Type =
  nsTypeNamed(nsGenericName(nsGenNs & "Dictionary", nsTypeOf(K).FullName, nsTypeOf(V).FullName))
proc nsTypeOf*[K, V](t: typedesc[SortedDictionary[K, V]]): Type =
  nsTypeNamed(nsGenericName(nsGenNs & "SortedDictionary", nsTypeOf(K).FullName,
                            nsTypeOf(V).FullName))
proc nsTypeOf*[K, V](t: typedesc[KeyValuePair[K, V]]): Type =
  nsTypeNamed(nsGenericName(nsGenNs & "KeyValuePair", nsTypeOf(K).FullName,
                            nsTypeOf(V).FullName))
