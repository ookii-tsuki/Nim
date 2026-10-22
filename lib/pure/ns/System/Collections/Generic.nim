# N# standard library: the System.Collections.Generic namespace.
#
# C# collection types, imported by `using System.Collections.Generic;`.
#
# Every collection is a class, as it is in .NET: a `ref object` that owns its
# storage, so `var b = a;` aliases the same list and `null` is a valid value. This
# is the Nim a user's own `class List<T>` would lower to, written ahead of time; the
# containers (`seq`, `NsHashMap`, `Deque`) are private fields,
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
#   * `TryDequeue`, `TryPeek`, `TryPop`, `Remove(key, out value)`: not yet written
#     (`Dictionary.TryGetValue` is).
#   * `IComparer<T>`, `IEqualityComparer<T>` and the overloads that take them.
#     `IEnumerable<T>` is a concrete type here. The collection interfaces
#     (`IList<T>`, `IDictionary<K,V>`, ...) are at the end of this file.
#   * `Comparer<T>`, `EqualityComparer<T>`, `Capacity`, `AsReadOnly`, collection
#     initialisers (`new List<int> { 1, 2 }`, a language feature).
#   * a constructor from `Keys`/`Values` (`new List<K>(d.Keys)`): the view has two
#     type parameters, which Nim cannot infer behind an explicit `newList[K]`.

import std/[sets, deques, algorithm, sequtils]
import ../../System {.cyclic.}
import ../Collections
from ../../../nsharp/hashmap import NsHashMap, initNsHashMap, getPtr, put, remove,
  copyOfSet, nsKeyHash, withComparer, initLike
from ../../../nsharp/hashmap as nshash import nil
from ../../../nsharp/intrinsics import NsDisposeStack, nsDisposeRun, Type, nsTypeNamed, nsTypeOf, FullName, nsGenericName,
  nsVtByKey, nsKeyOf, Equals, GetHashCode,
  NsArray, NsArrayBase, nsArrayOf, len, items, `[]`, `[]=`
export Collections

# `{.nsStatic: "T".}` and `{.nsInterface.}`: see `nsharp/pragmas`.
from ../../../nsharp/pragmas import nsStatic, nsInterface

type
  NsCollectionBase* = object of RootObj
    ## The library's collections: classes, but not a user's (see `nsToIEnumerable`).
  List*[T] = ref object of NsCollectionBase
    ## C#'s `List<T>`: a growable array.
    data: seq[T]
    version: int
  KeyValuePair*[K, V] = object
    ## C#'s `KeyValuePair<K,V>`, the element a dictionary's `foreach` yields.
    Key*: K
    Value*: V
  Dictionary*[K, V] = ref object of NsCollectionBase
    ## C#'s `Dictionary<K,V>`, over .NET's own hash table (`nsharp/hashmap`): it
    ## enumerates in .NET's order, a removed entry's place reused by the next added.
    data: NsHashMap[K, V]
    version: int
  HashSet*[T] = ref object of NsCollectionBase
    ## C#'s `HashSet<T>`, over the same hash table as `Dictionary`: it enumerates
    ## in .NET's order, a removed element's place reused by the next added.
    data: NsHashMap[T, bool]
    version: int
    comparer: IEqualityComparer[T]
      ## The comparer it was made with; an empty one is the default.
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
  Queue*[T] = ref object of NsCollectionBase
    ## C#'s `Queue<T>` (FIFO).
    data: Deque[T]
    version: int
  Stack*[T] = ref object of NsCollectionBase
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
  LinkedList*[T] = ref object of NsCollectionBase
    ## C#'s `LinkedList<T>`: a doubly-linked list of `LinkedListNode<T>`.
    head, tail: LinkedListNode[T]
    count: int
    version: int
  KeyCollection*[K, V] = ref object of NsCollectionBase
    ## C#'s `Dictionary<K,V>.KeyCollection` (and the sorted dictionaries'): a live
    ## view of the keys. Exactly one of the owners is set.
    dict: Dictionary[K, V]
    sorted: SortedDictionary[K, V]
    list: SortedList[K, V]
  ValueCollection*[K, V] = ref object of NsCollectionBase
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
    disp: NsDisposeStack  ## the iterator's pending `finally` blocks, if it is one
    done: bool            ## run to its end, or disposed
  IEnumerable*[T] = ref object
    ## C#'s `IEnumerable<T>`: something that hands out enumerators.
    make: proc(): IEnumerator[T]
  nsVT_IReadOnlyCollection*[T] = object
    fCount*: proc (o: RootRef): int32 {.nimcall.}
    fEnum*: proc (o: RootRef): IEnumerable[T] {.nimcall.}
  IReadOnlyCollection*[T] {.nsInterface.} = object
    ## C#'s `IReadOnlyCollection<T>`: `Count`, and enumerable.
    nsObj*: RootRef
    nsVt*: ptr nsVT_IReadOnlyCollection[T]
  nsVT_IReadOnlyList*[T] = object
    fCount*: proc (o: RootRef): int32 {.nimcall.}
    fEnum*: proc (o: RootRef): IEnumerable[T] {.nimcall.}
    fGet*: proc (o: RootRef; i: int32): T {.nimcall.}
  IReadOnlyList*[T] {.nsInterface.} = object
    ## C#'s `IReadOnlyList<T>`: an `IReadOnlyCollection<T>` with an indexer to read.
    nsObj*: RootRef
    nsVt*: ptr nsVT_IReadOnlyList[T]
  nsVT_ICollection*[T] = object
    fCount*: proc (o: RootRef): int32 {.nimcall.}
    fEnum*: proc (o: RootRef): IEnumerable[T] {.nimcall.}
    fIsReadOnly*: bool
    fAdd*: proc (o: RootRef; x: T) {.nimcall.}
    fClear*: proc (o: RootRef) {.nimcall.}
    fContains*: proc (o: RootRef; x: T): bool {.nimcall.}
    fCopyTo*: proc (o: RootRef; arr: NsArray[T]; index: int32) {.nimcall.}
    fRemove*: proc (o: RootRef; x: T): bool {.nimcall.}
  ICollection*[T] {.nsInterface.} = object
    ## C#'s `ICollection<T>`.
    nsObj*: RootRef
    nsVt*: ptr nsVT_ICollection[T]
  nsVT_IList*[T] = object
    fCount*: proc (o: RootRef): int32 {.nimcall.}
    fEnum*: proc (o: RootRef): IEnumerable[T] {.nimcall.}
    fIsReadOnly*: bool
    fAdd*: proc (o: RootRef; x: T) {.nimcall.}
    fClear*: proc (o: RootRef) {.nimcall.}
    fContains*: proc (o: RootRef; x: T): bool {.nimcall.}
    fCopyTo*: proc (o: RootRef; arr: NsArray[T]; index: int32) {.nimcall.}
    fRemove*: proc (o: RootRef; x: T): bool {.nimcall.}
    fGet*: proc (o: RootRef; i: int32): T {.nimcall.}
    fSet*: proc (o: RootRef; i: int32; x: T) {.nimcall.}
    fIndexOf*: proc (o: RootRef; x: T): int32 {.nimcall.}
    fInsert*: proc (o: RootRef; i: int32; x: T) {.nimcall.}
    fRemoveAt*: proc (o: RootRef; i: int32) {.nimcall.}
  IList*[T] {.nsInterface.} = object
    ## C#'s `IList<T>`: an `ICollection<T>` with an index.
    nsObj*: RootRef
    nsVt*: ptr nsVT_IList[T]
  nsVT_ISet*[T] = object
    fCount*: proc (o: RootRef): int32 {.nimcall.}
    fEnum*: proc (o: RootRef): IEnumerable[T] {.nimcall.}
    fIsReadOnly*: bool
    fAdd*: proc (o: RootRef; x: T) {.nimcall.}
    fClear*: proc (o: RootRef) {.nimcall.}
    fContains*: proc (o: RootRef; x: T): bool {.nimcall.}
    fCopyTo*: proc (o: RootRef; arr: NsArray[T]; index: int32) {.nimcall.}
    fRemove*: proc (o: RootRef; x: T): bool {.nimcall.}
    fAddNew*: proc (o: RootRef; x: T): bool {.nimcall.}
    fUnionWith*: proc (o: RootRef; other: NsArray[T]) {.nimcall.}
    fIntersectWith*: proc (o: RootRef; other: NsArray[T]) {.nimcall.}
    fExceptWith*: proc (o: RootRef; other: NsArray[T]) {.nimcall.}
    fSymmetricExceptWith*: proc (o: RootRef; other: NsArray[T]; otherSet: HashSet[T]) {.nimcall.}
      ## `otherSet` is the `HashSet<T>` behind `other` when there is one, which
      ## .NET's `HashSet<T>` treats apart.
    fIsSubsetOf*: proc (o: RootRef; other: NsArray[T]): bool {.nimcall.}
    fIsSupersetOf*: proc (o: RootRef; other: NsArray[T]): bool {.nimcall.}
    fIsProperSubsetOf*: proc (o: RootRef; other: NsArray[T]): bool {.nimcall.}
    fIsProperSupersetOf*: proc (o: RootRef; other: NsArray[T]): bool {.nimcall.}
    fOverlaps*: proc (o: RootRef; other: NsArray[T]): bool {.nimcall.}
    fSetEquals*: proc (o: RootRef; other: NsArray[T]): bool {.nimcall.}
  ISet*[T] {.nsInterface.} = object
    ## C#'s `ISet<T>`: an `ICollection<T>` with the set operations.
    nsObj*: RootRef
    nsVt*: ptr nsVT_ISet[T]
  nsVT_IReadOnlySet*[T] = object
    fCount*: proc (o: RootRef): int32 {.nimcall.}
    fEnum*: proc (o: RootRef): IEnumerable[T] {.nimcall.}
    fContains*: proc (o: RootRef; x: T): bool {.nimcall.}
    fIsSubsetOf*: proc (o: RootRef; other: NsArray[T]): bool {.nimcall.}
    fIsSupersetOf*: proc (o: RootRef; other: NsArray[T]): bool {.nimcall.}
    fIsProperSubsetOf*: proc (o: RootRef; other: NsArray[T]): bool {.nimcall.}
    fIsProperSupersetOf*: proc (o: RootRef; other: NsArray[T]): bool {.nimcall.}
    fOverlaps*: proc (o: RootRef; other: NsArray[T]): bool {.nimcall.}
    fSetEquals*: proc (o: RootRef; other: NsArray[T]): bool {.nimcall.}
  IReadOnlySet*[T] {.nsInterface.} = object
    ## C#'s `IReadOnlySet<T>`: `Contains` and the set comparisons.
    nsObj*: RootRef
    nsVt*: ptr nsVT_IReadOnlySet[T]
  nsVT_IReadOnlyDictionary*[K, V] = object
    fCount*: proc (o: RootRef): int32 {.nimcall.}
    fEnum*: proc (o: RootRef): IEnumerable[KeyValuePair[K, V]] {.nimcall.}
    fGet*: proc (o: RootRef; k: K): V {.nimcall.}
    fContainsKey*: proc (o: RootRef; k: K): bool {.nimcall.}
    fTryGetValue*: proc (o: RootRef; k: K; v: var V): bool {.nimcall.}
    fKeys*: proc (o: RootRef): IEnumerable[K] {.nimcall.}
    fValues*: proc (o: RootRef): IEnumerable[V] {.nimcall.}
  IReadOnlyDictionary*[K, V] {.nsInterface.} = object
    ## C#'s `IReadOnlyDictionary<K,V>`.
    nsObj*: RootRef
    nsVt*: ptr nsVT_IReadOnlyDictionary[K, V]
  nsVT_IDictionary*[K, V] = object
    fCount*: proc (o: RootRef): int32 {.nimcall.}
    fEnum*: proc (o: RootRef): IEnumerable[KeyValuePair[K, V]] {.nimcall.}
    fGet*: proc (o: RootRef; k: K): V {.nimcall.}
    fSet*: proc (o: RootRef; k: K; v: V) {.nimcall.}
    fContainsKey*: proc (o: RootRef; k: K): bool {.nimcall.}
    fTryGetValue*: proc (o: RootRef; k: K; v: var V): bool {.nimcall.}
    fAdd*: proc (o: RootRef; k: K; v: V) {.nimcall.}
    fRemove*: proc (o: RootRef; k: K): bool {.nimcall.}
    fClear*: proc (o: RootRef) {.nimcall.}
    fKeys*: proc (o: RootRef): ICollection[K] {.nimcall.}
    fValues*: proc (o: RootRef): ICollection[V] {.nimcall.}
  IDictionary*[K, V] {.nsInterface.} = object
    ## C#'s `IDictionary<K,V>`.
    nsObj*: RootRef
    nsVt*: ptr nsVT_IDictionary[K, V]
  nsVT_IComparer*[T] = object
    fCompare*: proc (o: RootRef; a, b: T): int32 {.nimcall.}
  IComparer*[T] {.nsInterface.} = object
    ## C#'s `IComparer<T>`: `Compare(a, b)`.
    nsObj*: RootRef
    nsVt*: ptr nsVT_IComparer[T]
  nsVT_IEqualityComparer*[T] = object
    fEquals*: proc (o: RootRef; a, b: T): bool {.nimcall.}
    fGetHashCode*: proc (o: RootRef; x: T): int32 {.nimcall.}
  IEqualityComparer*[T] {.nsInterface.} = object
    ## C#'s `IEqualityComparer<T>`: `Equals(a, b)` and `GetHashCode(x)`.
    nsObj*: RootRef
    nsVt*: ptr nsVT_IEqualityComparer[T]
  Comparer*[T] = ref object of NsCollectionBase
    ## C#'s `Comparer<T>`: `Comparer<T>.Default`, or `Comparer<T>.Create(f)`.
    compare: proc (a, b: T): int32
  EqualityComparer*[T] = ref object of NsCollectionBase
    ## C#'s `EqualityComparer<T>`: `EqualityComparer<T>.Default`.
    discard
  Enumerable[T] = NsArray[T] | seq[T] | List[T] | HashSet[T] | SortedSet[T] | Queue[T] |
                  Stack[T] | LinkedList[T] | IEnumerable[T] | IList[T] | ICollection[T] |
                  IReadOnlyList[T] | IReadOnlyCollection[T] | ISet[T] | IReadOnlySet[T]
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

proc snapshot[T](collection: Enumerable[T]): seq[T]
  ## The elements of any collection (C#'s `IEnumerable<T>`), copied first, so a
  ## member may be handed its own receiver. Defined at the end of the module, where
  ## every collection's `items` is declared: a call site's module may not see them.

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
  Dictionary[K, V](data: initNsHashMap[K, V]())
proc newDictionary*[K, V](capacity: int): Dictionary[K, V] =
  Dictionary[K, V](data: initNsHashMap[K, V](max(capacity, 0)))
proc newDictionary*[K, V](dictionary: Dictionary[K, V]): Dictionary[K, V] =
  ## The entries in the source's order, without its free places.
  result = Dictionary[K, V](data: initNsHashMap[K, V](nshash.len(dictionary.data)))
  for k, v in nshash.pairs(dictionary.data): discard result.data.put(k, v, false)

proc newHashSet*[T](): HashSet[T] = HashSet[T](data: initNsHashMap[T, bool]())

proc nsIsDefaultComparer[K](c: IEqualityComparer[K]): bool =
  ## A null comparer, or `EqualityComparer<K>.Default`: the keys' own equality.
  c.nsObj == nil or c.nsObj of EqualityComparer[K]

proc nsUseComparer[K, V](m: var NsHashMap[K, V]; c: IEqualityComparer[K]) =
  ## Keys compared by `c`; a null comparer is the default one.
  if not nsIsDefaultComparer(c):
    let cc = c
    m.withComparer(proc (a, b: K): bool = cc.Equals(a, b),
                   proc (k: K): int32 = cc.GetHashCode(k))

proc newDictionary*[K, V](comparer: IEqualityComparer[K]): Dictionary[K, V] =
  result = Dictionary[K, V](data: initNsHashMap[K, V]())
  result.data.nsUseComparer(comparer)
proc newDictionary*[K, V](capacity: int; comparer: IEqualityComparer[K]): Dictionary[K, V] =
  result = Dictionary[K, V](data: initNsHashMap[K, V](max(capacity, 0)))
  result.data.nsUseComparer(comparer)
proc newDictionary*[K, V](dictionary: Dictionary[K, V]; comparer: IEqualityComparer[K]):
    Dictionary[K, V] =
  result = Dictionary[K, V](data: initNsHashMap[K, V](nshash.len(dictionary.data)))
  result.data.nsUseComparer(comparer)
  for k, v in nshash.pairs(dictionary.data):
    if not result.data.put(k, v, false): raise keyDuplicate(k)
proc newHashSet*[T](comparer: IEqualityComparer[T]): HashSet[T] =
  result = HashSet[T](data: initNsHashMap[T, bool]())
  result.data.nsUseComparer(comparer)
  if not nsIsDefaultComparer(comparer): result.comparer = comparer
proc newHashSet*[T](collection: Enumerable[T]; comparer: IEqualityComparer[T]): HashSet[T] =
  result = HashSet[T](data: initNsHashMap[T, bool]())
  result.data.nsUseComparer(comparer)
  if not nsIsDefaultComparer(comparer): result.comparer = comparer
  for x in snapshot(collection): discard result.data.put(x, true, false)
proc newHashSet*[T](capacity: int): HashSet[T] =
  HashSet[T](data: initNsHashMap[T, bool](max(capacity, 0)))
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
  result = HashSet[T](data: initNsHashMap[T, bool]())
  for x in s: discard result.data.put(x, true, false)
proc hashSetOf[T](s: HashSet[T]): HashSet[T] =
  ## From another set, as .NET copies one (see `copyOfSet`).
  HashSet[T](data: copyOfSet(s.data))
proc sortedSetOf[T](s: seq[T]): SortedSet[T] =
  result = SortedSet[T](data: s)
  algorithm.sort(result.data)
  result.data = deduplicate(result.data, isSorted = true)
proc queueOf[T](s: seq[T]): Queue[T] = Queue[T](data: toDeque(s))
proc stackOf[T](s: seq[T]): Stack[T] = Stack[T](data: s)

template fromEnumerable(ctor, build: untyped) =
  proc ctor*[T](collection: openArray[T]): auto = build(@collection)
  proc ctor*[T](collection: NsArray[T]): auto = build(collection.nsData)
  proc ctor*[T](collection: List[T]): auto = build(snapshot(collection))
  proc ctor*[T](collection: HashSet[T]): auto =
    when compiles(build(collection)): build(collection) else: build(snapshot(collection))
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

proc Count*[T](l: List[T]): int32 {.inline.} = int32(l.data.len)
proc Count*[K, V](t: Dictionary[K, V]): int32 {.inline.} = int32(nshash.len(t.data))
proc Count*[T](s: HashSet[T]): int32 = int32(nshash.len(s.data))
proc Count*[T](s: SortedSet[T]): int32 = int32(s.data.len)
proc Count*[K, V](t: SortedDictionary[K, V]): int32 = int32(t.keys.len)
proc Count*[K, V](t: SortedList[K, V]): int32 = int32(t.keys.len)
proc Count*[T](q: Queue[T]): int32 = int32(q.data.len)
proc Count*[T](s: Stack[T]): int32 = int32(s.data.len)
proc Count*[T](l: LinkedList[T]): int32 = int32(l.count)
proc Count*[E, P](q: PriorityQueue[E, P]): int32 = int32(q.nodes.len)

# --- List<T> ----------------------------------------------------------------

{.push boundChecks: off.}
proc `[]`*[T](l: List[T]; i: int): lent T {.inline.} =
  ## The element itself, lent: reading one counts no reference.
  checkIndex(i, l.data.len)
  l.data[i]  # checked above, with .NET's exception
{.pop.}
proc `[]=`*[T](l: List[T]; i: int; x: sink T) {.inline.} =
  checkIndex(i, l.data.len)
  {.push boundChecks: off.}
  l.data[i] = x
  {.pop.}
  touch l

iterator items*[T](l: List[T]): T =
  let v = l.version
  var i = 0
  while true:
    checkVersion(l, v)
    if i >= l.data.len: break
    yield l.data[i]
    inc i

proc Add*[T](l: List[T]; x: sink T) =
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
proc CopyTo*[T](l: List[T]; arr: NsArray[T]) =
  for i in 0 ..< l.data.len: arr[i] = l.data[i]
proc CopyTo*[T](l: List[T]; arr: NsArray[T]; arrayIndex: int) =
  for i in 0 ..< l.data.len: arr[arrayIndex + i] = l.data[i]
proc ToArray*[T](l: List[T]): NsArray[T] = nsArrayOf(l.data)
proc TrimExcess*[T](l: List[T]) = discard

# --- Dictionary<K, V> -------------------------------------------------------

proc `[]`*[K, V](t: Dictionary[K, V]; k: K): V =
  ## One lookup; a missing key is `KeyNotFoundException`, with .NET's message.
  let p = t.data.getPtr(k)
  if p == nil: raise keyMissing(k)
  p[]
proc `[]=`*[K, V](t: Dictionary[K, V]; k: K; v: sink V) =
  discard t.data.put(k, v, true)
  touch t

iterator items*[K, V](t: Dictionary[K, V]): KeyValuePair[K, V] =
  let v = t.version
  for k, x in nshash.pairs(t.data):
    yield KeyValuePair[K, V](Key: k, Value: x)
    checkVersion(t, v)

proc Add*[K, V](t: Dictionary[K, V]; k: K; v: V) =
  if not t.data.put(k, v, false): raise keyDuplicate(k)
  touch t
proc TryAdd*[K, V](t: Dictionary[K, V]; k: K; v: V): bool =
  result = t.data.put(k, v, false)
  if result: touch t
proc Clear*[K, V](t: Dictionary[K, V]) =
  nshash.clear(t.data)
  touch t
proc ContainsKey*[K, V](t: Dictionary[K, V]; k: K): bool {.inline.} =
  nshash.contains(t.data, k)
proc ContainsValue*[K, V](t: Dictionary[K, V]; v: V): bool =
  for x in nshash.values(t.data):
    if x == v: return true
proc GetValueOrDefault*[K, V](t: Dictionary[K, V]; k: K): V =
  let p = t.data.getPtr(k)
  if p != nil: result = p[]
proc GetValueOrDefault*[K, V](t: Dictionary[K, V]; k: K; defaultValue: V): V =
  let p = t.data.getPtr(k)
  if p != nil: p[] else: defaultValue
proc Remove*[K, V](t: Dictionary[K, V]; k: K): bool =
  result = t.data.remove(k)
  if result: touch t
proc TryGetValue*[K, V](t: Dictionary[K, V]; k: K; value: var V): bool =
  ## The value under `k` when there is one; `value` is the default when not.
  let p = t.data.getPtr(k)
  if p == nil:
    value = default(V)
    false
  else:
    value = p[]
    true
proc Keys*[K, V](t: Dictionary[K, V]): KeyCollection[K, V] =
  KeyCollection[K, V](dict: t)
proc Values*[K, V](t: Dictionary[K, V]): ValueCollection[K, V] =
  ValueCollection[K, V](dict: t)

# --- HashSet<T> -------------------------------------------------------------
#
# The set operations change the set in .NET's order, which decides the places
# later additions take: `ExceptWith` removes in the other collection's order,
# `IntersectWith` and `RemoveWhere` in the set's own.

iterator items*[T](s: HashSet[T]): T =
  let v = s.version
  for x in nshash.keys(s.data):
    yield x
    checkVersion(s, v)

proc Add*[T](s: HashSet[T]; x: T): bool =
  ## Reports whether the element was new, exactly as .NET's does.
  result = s.data.put(x, true, false)
  if result: touch s
proc Clear*[T](s: HashSet[T]) =
  nshash.clear(s.data)
  touch s
proc Contains*[T](s: HashSet[T]; x: T): bool = nshash.contains(s.data, x)
proc Remove*[T](s: HashSet[T]; x: T): bool =
  result = s.data.remove(x)
  if result: touch s
proc RemoveWhere*[T](s: HashSet[T]; match: Predicate[T]): int32 =
  var gone: seq[T] = @[]
  for x in nshash.keys(s.data):
    if match(x): gone.add x
  for x in gone: discard s.data.remove(x)
  if gone.len > 0: touch s
  int32(gone.len)
proc CopyTo*[T](s: HashSet[T]; arr: NsArray[T]) =
  var i = 0
  for x in nshash.keys(s.data):
    arr[i] = x
    inc i
proc CopyTo*[T](s: HashSet[T]; arr: NsArray[T]; arrayIndex: int) =
  var i = arrayIndex
  for x in nshash.keys(s.data):
    arr[i] = x
    inc i
proc ToArray*[T](s: HashSet[T]): NsArray[T] =
  var xs: seq[T] = @[]
  for x in nshash.keys(s.data): xs.add x
  nsArrayOf(xs)
proc UnionWith*[T](s: HashSet[T]; other: Enumerable[T]) =
  for x in snapshot(other): discard s.data.put(x, true, false)
  touch s
proc IntersectWith*[T](s: HashSet[T]; other: Enumerable[T]) =
  if nshash.len(s.data) == 0: return
  var keep = s.data.initLike(bool)
  for x in snapshot(other): discard keep.put(x, true, false)
  if nshash.len(keep) == 0:
    ## .NET clears the set then, which also forgets the free places.
    nshash.clear(s.data)
    touch s
    return
  var gone: seq[T] = @[]
  for x in nshash.keys(s.data):
    if not nshash.contains(keep, x): gone.add x
  for x in gone: discard s.data.remove(x)
  touch s
proc ExceptWith*[T](s: HashSet[T]; other: Enumerable[T]) =
  when other is HashSet[T]:
    if other == s:
      nshash.clear(s.data)
      touch s
      return
  if nshash.len(s.data) == 0: return
  for x in snapshot(other): discard s.data.remove(x)
  touch s
proc nsSameComparer[T](a, b: HashSet[T]): bool =
  ## .NET's `EqualityComparersAreEqual`: both default, or equal comparers.
  if a.comparer.nsObj == nil or b.comparer.nsObj == nil:
    a.comparer.nsObj == nil and b.comparer.nsObj == nil
  else: a.comparer.nsObj == b.comparer.nsObj or a.comparer.nsObj.Equals(b.comparer.nsObj)

proc nsAsHashSet[T](other: Enumerable[T]): HashSet[T] =
  ## The `HashSet<T>` behind `other`, as .NET's `other is HashSet<T>` finds it, or nil.
  when other is HashSet[T]: other
  elif compiles(other.nsObj):
    if other.nsObj != nil and other.nsObj of HashSet[T]: HashSet[T](other.nsObj) else: nil
  else: nil

proc nsSymmetricExceptWithSet[T](s, other: HashSet[T]) =
  ## .NET's path for a set with the same comparer: each element removed if
  ## present, else added.
  if other == s:
    nshash.clear(s.data)
  else:
    for x in snapshot(other):
      if not s.data.remove(x): discard s.data.put(x, true, false)
  touch s

proc SymmetricExceptWith*[T](s: HashSet[T]; other: Enumerable[T]) =
  let os = nsAsHashSet(other)
  if os != nil and nsSameComparer(s, os):
    nsSymmetricExceptWithSet(s, os)
    return
  ## .NET's path for any other collection: the new elements are added first,
  ## then the ones both had are removed, in the set's order.
  var seen = s.data.initLike(bool)
  var common = s.data.initLike(bool)
  for x in snapshot(other):
    if not seen.put(x, true, false): continue
    if not s.data.put(x, true, false): discard common.put(x, true, false)
  var gone: seq[T] = @[]
  for x in nshash.keys(s.data):
    if nshash.contains(common, x): gone.add x
  for x in gone: discard s.data.remove(x)
  touch s

proc plainSet[T](other: Enumerable[T]): NsHashMap[T, bool] =
  ## `other` as a set by its elements' own equality.
  result = initNsHashMap[T, bool]()
  for x in snapshot(other): discard result.put(x, true, false)

# The set comparisons read `other` as a set, by the set's own comparer: duplicates
# in it do not count.
proc otherSet[T](s: HashSet[T]; other: Enumerable[T]): NsHashMap[T, bool] =
  result = s.data.initLike(bool)
  for x in snapshot(other): discard result.put(x, true, false)

proc IsSubsetOf*[T](s: HashSet[T]; other: Enumerable[T]): bool =
  let o = s.otherSet(other)
  for x in nshash.keys(s.data):
    if not nshash.contains(o, x): return false
  true
proc IsProperSubsetOf*[T](s: HashSet[T]; other: Enumerable[T]): bool =
  let o = s.otherSet(other)
  if nshash.len(o) <= nshash.len(s.data): return false
  for x in nshash.keys(s.data):
    if not nshash.contains(o, x): return false
  true
proc IsSupersetOf*[T](s: HashSet[T]; other: Enumerable[T]): bool =
  for x in snapshot(other):
    if not nshash.contains(s.data, x): return false
  true
proc IsProperSupersetOf*[T](s: HashSet[T]; other: Enumerable[T]): bool =
  let o = s.otherSet(other)
  if nshash.len(o) >= nshash.len(s.data): return false
  for x in nshash.keys(o):
    if not nshash.contains(s.data, x): return false
  true
proc Overlaps*[T](s: HashSet[T]; other: Enumerable[T]): bool =
  for x in snapshot(other):
    if nshash.contains(s.data, x): return true
proc SetEquals*[T](s: HashSet[T]; other: Enumerable[T]): bool =
  let o = s.otherSet(other)
  if nshash.len(o) != nshash.len(s.data): return false
  for x in nshash.keys(o):
    if not nshash.contains(s.data, x): return false
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
proc ToArray*[T](s: SortedSet[T]): NsArray[T] = nsArrayOf(s.data)
proc UnionWith*[T](s: SortedSet[T]; other: Enumerable[T]) =
  for x in snapshot(other): discard s.Add(x)
  touch s
proc IntersectWith*[T](s: SortedSet[T]; other: Enumerable[T]) =
  let o = plainSet(other)
  var kept: seq[T] = @[]
  for x in s.data:
    if nshash.contains(o, x): kept.add x
  s.data = kept
  touch s
proc ExceptWith*[T](s: SortedSet[T]; other: Enumerable[T]) =
  for x in snapshot(other): discard s.Remove(x)
  touch s
proc SymmetricExceptWith*[T](s: SortedSet[T]; other: Enumerable[T]) =
  for x in nshash.keys(plainSet(other)):
    if not s.Remove(x): discard s.Add(x)
  touch s
proc IsSubsetOf*[T](s: SortedSet[T]; other: Enumerable[T]): bool =
  let o = plainSet(other)
  for x in s.data:
    if not nshash.contains(o, x): return false
  true
proc IsProperSubsetOf*[T](s: SortedSet[T]; other: Enumerable[T]): bool =
  let o = plainSet(other)
  if nshash.len(o) <= s.data.len: return false
  for x in s.data:
    if not nshash.contains(o, x): return false
  true
proc IsSupersetOf*[T](s: SortedSet[T]; other: Enumerable[T]): bool =
  for x in snapshot(other):
    if not s.Contains(x): return false
  true
proc IsProperSupersetOf*[T](s: SortedSet[T]; other: Enumerable[T]): bool =
  let o = plainSet(other)
  if nshash.len(o) >= s.data.len: return false
  for x in nshash.keys(o):
    if not s.Contains(x): return false
  true
proc Overlaps*[T](s: SortedSet[T]; other: Enumerable[T]): bool =
  for x in snapshot(other):
    if s.Contains(x): return true
proc SetEquals*[T](s: SortedSet[T]; other: Enumerable[T]): bool =
  let o = plainSet(other)
  if nshash.len(o) != s.data.len: return false
  for x in nshash.keys(o):
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

# --- String.Join over collections --------------------------------------------
#
# `string.Join(", ", xs)` over any collection (C#'s `IEnumerable<string>` and
# `Join<T>(string, IEnumerable<T>)`), a dictionary's `Keys` or `Values` included:
# each element as string concatenation renders it. The `string[]` overloads are
# `System`'s.

template joinAll(separator, xs: untyped): string =
  var r = ""
  var first = true
  for x in items(xs):
    if first: first = false
    else: r.add separator
    r.add $x
  r

proc Join*[T](separator: string; values: Enumerable[T]): string {.nsStatic: "String".} =
  joinAll(separator, snapshot(values))
proc Join*[T](separator: char; values: Enumerable[T]): string {.nsStatic: "String".} =
  joinAll(separator, snapshot(values))
proc Join*[K, V](separator: string; values: KeyCollection[K, V]): string {.nsStatic: "String".} =
  joinAll(separator, values)
proc Join*[K, V](separator: string; values: ValueCollection[K, V]): string {.nsStatic: "String".} =
  joinAll(separator, values)
proc Join*[K, V](separator: char; values: KeyCollection[K, V]): string {.nsStatic: "String".} =
  joinAll(separator, values)
proc Join*[K, V](separator: char; values: ValueCollection[K, V]): string {.nsStatic: "String".} =
  joinAll(separator, values)

proc CopyTo*[K, V](c: KeyCollection[K, V]; arr: NsArray[K]; index: int) =
  var i = index
  for k in items(c):
    arr[i] = k
    inc i
proc CopyTo*[K, V](c: ValueCollection[K, V]; arr: NsArray[V]; index: int) =
  var i = index
  for v in items(c):
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
proc ToArray*[T](q: Queue[T]): NsArray[T] =
  var xs: seq[T] = @[]
  for x in q.data: xs.add x
  nsArrayOf(xs)
proc CopyTo*[T](q: Queue[T]; arr: NsArray[T]; arrayIndex: int) =
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
proc ToArray*[T](s: Stack[T]): NsArray[T] =
  ## Top first, as .NET orders it.
  var xs: seq[T] = @[]
  for i in countdown(s.data.high, 0): xs.add s.data[i]
  nsArrayOf(xs)
proc CopyTo*[T](s: Stack[T]; arr: NsArray[T]; arrayIndex: int) =
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
proc CopyTo*[T](l: LinkedList[T]; arr: NsArray[T]; arrayIndex: int) =
  var i = arrayIndex
  for x in items(l):
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

proc nsEnumeratorOf*[T](step: iterator(): T; disp: NsDisposeStack = nil): IEnumerator[T] =
  ## The enumerator that runs `step`, one element per `MoveNext`.
  let e = IEnumerator[T](step: step, disp: disp)
  e.nsStep = proc (): bool =
    if e.done: return false
    let v = e.step()
    if finished(e.step):
      e.done = true
      return false
    e.current = v
    true
  e

proc Current*[T](e: IEnumerator[T]): T = e.current

proc nsDisposeEnumerator*[T](e: IEnumerator[T]) =
  ## Ends the enumeration: an iterator suspended inside `try` blocks runs their
  ## `finally` blocks, innermost first, and `MoveNext` answers false from then on.
  ## `System` declares `Dispose` with it, since .NET's is `IDisposable`'s.
  if not e.done:
    e.done = true
    if e.disp != nil: nsDisposeRun(e.disp)

proc GetEnumerator*[T](s: IEnumerable[T]): IEnumerator[T] = s.make()

iterator items*[T](s: IEnumerable[T]): T =
  ## `foreach` disposes the enumerator however the loop is left (13.9.5).
  let e = s.make()
  try:
    while e.MoveNext(): yield e.current
  finally:
    e.nsDisposeEnumerator()

template nsEnumerator*(T: typedesc; body: untyped): untyped =
  ## The enumerator of an iterator block whose member returns `IEnumerator<T>`.
  ## `nsDisp` is where the block's `try` statements register their `finally`.
  block:
    let nsDisp {.inject.} = NsDisposeStack()
    let nsStepIt = iterator(): T {.closure.} =
      body
    nsEnumeratorOf[T](nsStepIt, nsDisp)

template nsEnumerable*(T: typedesc; body: untyped): untyped =
  ## The sequence of an iterator block whose member returns `IEnumerable<T>`: each
  ## enumeration starts the block again.
  IEnumerable[T](make: proc(): IEnumerator[T] =
    let nsDisp {.inject.} = NsDisposeStack()
    let nsStepIt = iterator(): T {.closure.} =
      body
    nsEnumeratorOf[T](nsStepIt, nsDisp))

template nsSequenceView(xs: untyped; T: typedesc): untyped =
  IEnumerable[T](make: proc(): IEnumerator[T] =
    nsEnumeratorOf[T](iterator(): T {.closure.} =
      for x in items(xs): yield x))

# The compiler calls these where C# converts an array or a collection to
# `IEnumerable<T>` implicitly, so the view is enumerated live. A Nim converter
# would be tried, and fail to instantiate, wherever a ref value meets an
# overloaded operator.
proc nsToIEnumerable*[T](xs: seq[T]): IEnumerable[T] = nsSequenceView(xs, T)
proc nsToIEnumerable*[T](xs: NsArray[T]): IEnumerable[T] = nsSequenceView(xs, T)
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

# --- classes implementing `IEnumerable<T>` / `IEnumerator<T>` --------------------
#
# A class naming one of them keeps its own `GetEnumerator` (or `MoveNext` and
# `Current`); where C# converts it to the interface, the compiler calls these.

proc nsToIEnumerator*[T](e: IEnumerator[T]): IEnumerator[T] = e

proc nsToIEnumerator*[C: ref RootObj and not NsArrayBase and not ref NsCollectionBase](c: C): auto =
  ## A user enumerator as the library's: each `MoveNext` steps the class's.
  mixin Current, MoveNext
  type E = typeof(c.Current)
  nsEnumeratorOf[E](iterator(): E {.closure.} =
    while c.MoveNext(): yield c.Current)

proc nsToIEnumerable*[C: ref RootObj and not NsArrayBase and not ref NsCollectionBase](c: C): auto =
  ## A user sequence as the library's: each enumeration asks it for a new
  ## enumerator.
  mixin GetEnumerator
  type E = typeof(nsToIEnumerator(c.GetEnumerator()).Current)
  IEnumerable[E](make: proc(): IEnumerator[E] = nsToIEnumerator(c.GetEnumerator()))

# --- the collection interfaces --------------------------------------------------
#
# `IList<T>`, `ICollection<T>`, `IReadOnlyList<T>`, `IReadOnlyCollection<T>`: each is
# what a user interface lowers to, written ahead of time -- a value holding the
# instance (`nsObj`) and a table of its members (`nsVt`). A table is built once per
# implementing type by a generic builder that calls that type's own members by
# name; where the type cannot do something (adding to an array) the entry throws
# what .NET throws. The compiler converts a collection to an interface through
# `nsTo<Interface>`, as it does to `IEnumerable<T>`, and `is`/`as` ask the object
# through `nsVtByKey`.

proc nsFixedSize() {.noinline, noreturn.} =
  raise newException(NotSupportedException, "Collection was of a fixed size.")

template nsIfaceObj(v: untyped): RootRef =
  ## The instance behind an interface value; null throws, as a call on it does.
  (if v.nsObj == nil: raise newException(NullReferenceException,
                                         "Object reference not set to an instance of an object.");
   v.nsObj)

# The tables. `C` is the implementing type; an array is fixed in size and takes no
# `Add`, `Insert`, `Remove`, `RemoveAt` or `Clear` through an interface.

proc nsEnumOf[C, T](c: C): IEnumerable[T] =
  ## A sequence over what implements an interface: the library's collections and
  ## arrays walk their own items; a user's class its `GetEnumerator`.
  mixin nsToIEnumerable
  when C is NsArray or C is ref NsCollectionBase: nsSequenceView(c, T)
  else: nsToIEnumerable(c)

proc nsReadOnlyCollectionVt[C, T](): ptr nsVT_IReadOnlyCollection[T] =
  mixin Count
  var store {.global.}: nsVT_IReadOnlyCollection[T]
  var ready {.global.} = false
  if not ready:
    ready = true
    store = nsVT_IReadOnlyCollection[T](
      fCount: proc (o: RootRef): int32 {.nimcall.} =
        when C is NsArray: int32(cast[C](o).len) else: Count(cast[C](o)),
      fEnum: proc (o: RootRef): IEnumerable[T] {.nimcall.} = nsEnumOf[C, T](cast[C](o)))
  addr store

proc nsReadOnlyListVt[C, T](): ptr nsVT_IReadOnlyList[T] =
  mixin Count
  var store {.global.}: nsVT_IReadOnlyList[T]
  var ready {.global.} = false
  if not ready:
    ready = true
    store = nsVT_IReadOnlyList[T](
      fCount: proc (o: RootRef): int32 {.nimcall.} =
        when C is NsArray: int32(cast[C](o).len) else: Count(cast[C](o)),
      fEnum: proc (o: RootRef): IEnumerable[T] {.nimcall.} = nsEnumOf[C, T](cast[C](o)),
      fGet: proc (o: RootRef; i: int32): T {.nimcall.} = cast[C](o)[i])
  addr store

proc nsViewMutated(C: typedesc) {.noinline, noreturn.} =
  ## A dictionary's `Keys` or `Values` changed through `ICollection<T>`.
  let what = (when C is KeyCollection: "key" else: "value")
  raise newException(NotSupportedException,
                     "Mutating a " & what & " collection derived from a dictionary is not allowed.")

template nsIsView(C: typedesc): bool = C is KeyCollection or C is ValueCollection

proc nsCollectionVt[C, T](): ptr nsVT_ICollection[T] =
  mixin Count, Add, AddLast, Clear, Contains, CopyTo, Remove
  var store {.global.}: nsVT_ICollection[T]
  var ready {.global.} = false
  if not ready:
    ready = true
    store = nsVT_ICollection[T](
      fCount: proc (o: RootRef): int32 {.nimcall.} =
        when C is NsArray: int32(cast[C](o).len) else: Count(cast[C](o)),
      fEnum: proc (o: RootRef): IEnumerable[T] {.nimcall.} = nsEnumOf[C, T](cast[C](o)),
      fIsReadOnly: C is NsArray or nsIsView(C),
      fAdd: proc (o: RootRef; x: T) {.nimcall.} =
        when C is NsArray: nsFixedSize()
        elif nsIsView(C): nsViewMutated(C)
        elif C is LinkedList: discard AddLast(cast[C](o), x)
        elif typeof(Add(cast[C](o), x)) is void: Add(cast[C](o), x)
        else: discard Add(cast[C](o), x),
      fClear: proc (o: RootRef) {.nimcall.} =
        when C is NsArray: nsFixedSize()
        elif nsIsView(C): nsViewMutated(C)
        else: Clear(cast[C](o)),
      fContains: proc (o: RootRef; x: T): bool {.nimcall.} =
        when C is NsArray: IndexOf(cast[C](o), x) >= 0
        elif nsIsView(C):
          for y in cast[C](o):
            if y == x: return true
          false
        else: Contains(cast[C](o), x),
      fCopyTo: proc (o: RootRef; arr: NsArray[T]; index: int32) {.nimcall.} =
        when C is NsArray:
          var i = index
          for x in cast[C](o):
            arr[i] = x
            inc i
        else: CopyTo(cast[C](o), arr, index),
      fRemove: proc (o: RootRef; x: T): bool {.nimcall.} =
        when C is NsArray: nsFixedSize()
        elif nsIsView(C): nsViewMutated(C)
        else: Remove(cast[C](o), x))
  addr store

proc nsListVt[C, T](): ptr nsVT_IList[T] =
  var store {.global.}: nsVT_IList[T]
  var ready {.global.} = false
  if not ready:
    ready = true
    let c = nsCollectionVt[C, T]()
    store.fCount = c.fCount
    store.fEnum = c.fEnum
    store.fIsReadOnly = c.fIsReadOnly
    store.fAdd = c.fAdd
    store.fClear = c.fClear
    store.fContains = c.fContains
    store.fCopyTo = c.fCopyTo
    store.fRemove = c.fRemove
    store.fGet = proc (o: RootRef; i: int32): T {.nimcall.} = cast[C](o)[i]
    store.fSet = proc (o: RootRef; i: int32; x: T) {.nimcall.} = cast[C](o)[i] = x
    store.fIndexOf = proc (o: RootRef; x: T): int32 {.nimcall.} =
      when C is NsArray: IndexOf(cast[C](o), x) else: IndexOf(cast[C](o), x)
    store.fInsert = proc (o: RootRef; i: int32; x: T) {.nimcall.} =
      when C is NsArray: nsFixedSize() else: Insert(cast[C](o), i, x)
    store.fRemoveAt = proc (o: RootRef; i: int32) {.nimcall.} =
      when C is NsArray: nsFixedSize() else: RemoveAt(cast[C](o), i)
  addr store


proc nsSetVt[C, T](): ptr nsVT_ISet[T] =
  mixin Add, UnionWith, IntersectWith, ExceptWith, SymmetricExceptWith, IsSubsetOf, IsSupersetOf, IsProperSubsetOf, IsProperSupersetOf, Overlaps, SetEquals
  var store {.global.}: nsVT_ISet[T]
  var ready {.global.} = false
  if not ready:
    ready = true
    let c = nsCollectionVt[C, T]()
    store.fCount = c.fCount
    store.fEnum = c.fEnum
    store.fIsReadOnly = c.fIsReadOnly
    store.fAdd = c.fAdd
    store.fClear = c.fClear
    store.fContains = c.fContains
    store.fCopyTo = c.fCopyTo
    store.fRemove = c.fRemove
    store.fAddNew = proc (o: RootRef; x: T): bool {.nimcall.} = Add(cast[C](o), x)
    store.fUnionWith = proc (o: RootRef; other: NsArray[T]) {.nimcall.} = UnionWith(cast[C](o), other)
    store.fIntersectWith = proc (o: RootRef; other: NsArray[T]) {.nimcall.} = IntersectWith(cast[C](o), other)
    store.fExceptWith = proc (o: RootRef; other: NsArray[T]) {.nimcall.} = ExceptWith(cast[C](o), other)
    store.fSymmetricExceptWith = proc (o: RootRef; other: NsArray[T]; otherSet: HashSet[T]) {.nimcall.} =
      when C is HashSet[T]:
        if otherSet != nil: SymmetricExceptWith(cast[C](o), otherSet)
        else: SymmetricExceptWith(cast[C](o), other)
      else: SymmetricExceptWith(cast[C](o), other)
    store.fIsSubsetOf = proc (o: RootRef; other: NsArray[T]): bool {.nimcall.} = IsSubsetOf(cast[C](o), other)
    store.fIsSupersetOf = proc (o: RootRef; other: NsArray[T]): bool {.nimcall.} = IsSupersetOf(cast[C](o), other)
    store.fIsProperSubsetOf = proc (o: RootRef; other: NsArray[T]): bool {.nimcall.} = IsProperSubsetOf(cast[C](o), other)
    store.fIsProperSupersetOf = proc (o: RootRef; other: NsArray[T]): bool {.nimcall.} = IsProperSupersetOf(cast[C](o), other)
    store.fOverlaps = proc (o: RootRef; other: NsArray[T]): bool {.nimcall.} = Overlaps(cast[C](o), other)
    store.fSetEquals = proc (o: RootRef; other: NsArray[T]): bool {.nimcall.} = SetEquals(cast[C](o), other)
  addr store

proc nsReadOnlySetVt[C, T](): ptr nsVT_IReadOnlySet[T] =
  mixin Count, Contains, IsSubsetOf, IsSupersetOf, IsProperSubsetOf, IsProperSupersetOf, Overlaps, SetEquals
  var store {.global.}: nsVT_IReadOnlySet[T]
  var ready {.global.} = false
  if not ready:
    ready = true
    store.fCount = proc (o: RootRef): int32 {.nimcall.} = Count(cast[C](o))
    store.fEnum = proc (o: RootRef): IEnumerable[T] {.nimcall.} = nsEnumOf[C, T](cast[C](o))
    store.fContains = proc (o: RootRef; x: T): bool {.nimcall.} = Contains(cast[C](o), x)
    store.fIsSubsetOf = proc (o: RootRef; other: NsArray[T]): bool {.nimcall.} = IsSubsetOf(cast[C](o), other)
    store.fIsSupersetOf = proc (o: RootRef; other: NsArray[T]): bool {.nimcall.} = IsSupersetOf(cast[C](o), other)
    store.fIsProperSubsetOf = proc (o: RootRef; other: NsArray[T]): bool {.nimcall.} = IsProperSubsetOf(cast[C](o), other)
    store.fIsProperSupersetOf = proc (o: RootRef; other: NsArray[T]): bool {.nimcall.} = IsProperSupersetOf(cast[C](o), other)
    store.fOverlaps = proc (o: RootRef; other: NsArray[T]): bool {.nimcall.} = Overlaps(cast[C](o), other)
    store.fSetEquals = proc (o: RootRef; other: NsArray[T]): bool {.nimcall.} = SetEquals(cast[C](o), other)
  addr store

proc nsReadOnlyDictionaryVt[C, K, V](): ptr nsVT_IReadOnlyDictionary[K, V] =
  mixin Count, ContainsKey, TryGetValue, Keys, Values
  var store {.global.}: nsVT_IReadOnlyDictionary[K, V]
  var ready {.global.} = false
  if not ready:
    ready = true
    store.fCount = proc (o: RootRef): int32 {.nimcall.} = Count(cast[C](o))
    store.fEnum = proc (o: RootRef): IEnumerable[KeyValuePair[K, V]] {.nimcall.} =
      nsEnumOf[C, KeyValuePair[K, V]](cast[C](o))
    store.fGet = proc (o: RootRef; k: K): V {.nimcall.} = cast[C](o)[k]
    store.fContainsKey = proc (o: RootRef; k: K): bool {.nimcall.} = ContainsKey(cast[C](o), k)
    store.fTryGetValue = proc (o: RootRef; k: K; v: var V): bool {.nimcall.} =
      TryGetValue(cast[C](o), k, v)
    store.fKeys = proc (o: RootRef): IEnumerable[K] {.nimcall.} = nsSequenceView(Keys(cast[C](o)), K)
    store.fValues = proc (o: RootRef): IEnumerable[V] {.nimcall.} =
      nsSequenceView(Values(cast[C](o)), V)
  addr store

proc nsDictionaryVt[C, K, V](): ptr nsVT_IDictionary[K, V] =
  mixin Count, ContainsKey, TryGetValue, Keys, Values, Add, Remove, Clear
  var store {.global.}: nsVT_IDictionary[K, V]
  var ready {.global.} = false
  if not ready:
    ready = true
    store.fCount = proc (o: RootRef): int32 {.nimcall.} = Count(cast[C](o))
    store.fEnum = proc (o: RootRef): IEnumerable[KeyValuePair[K, V]] {.nimcall.} =
      nsEnumOf[C, KeyValuePair[K, V]](cast[C](o))
    store.fGet = proc (o: RootRef; k: K): V {.nimcall.} = cast[C](o)[k]
    store.fSet = proc (o: RootRef; k: K; v: V) {.nimcall.} = cast[C](o)[k] = v
    store.fContainsKey = proc (o: RootRef; k: K): bool {.nimcall.} = ContainsKey(cast[C](o), k)
    store.fTryGetValue = proc (o: RootRef; k: K; v: var V): bool {.nimcall.} =
      TryGetValue(cast[C](o), k, v)
    store.fAdd = proc (o: RootRef; k: K; v: V) {.nimcall.} = Add(cast[C](o), k, v)
    store.fRemove = proc (o: RootRef; k: K): bool {.nimcall.} = Remove(cast[C](o), k)
    store.fClear = proc (o: RootRef) {.nimcall.} = Clear(cast[C](o))
    store.fKeys = proc (o: RootRef): ICollection[K] {.nimcall.} =
      let ks = Keys(cast[C](o))
      ICollection[K](nsObj: ks, nsVt: nsCollectionVt[typeof(ks), K]())
    store.fValues = proc (o: RootRef): ICollection[V] {.nimcall.} =
      let vs = Values(cast[C](o))
      ICollection[V](nsObj: vs, nsVt: nsCollectionVt[typeof(vs), V]())
  addr store

# The members, through the table.

proc Count*[T](v: IReadOnlyCollection[T]): int32 = v.nsVt.fCount(nsIfaceObj(v))
iterator items*[T](v: IReadOnlyCollection[T]): T =
  let e = v.nsVt.fEnum(nsIfaceObj(v)).make()
  while e.MoveNext(): yield e.Current
proc `$`*[T](v: IReadOnlyCollection[T]): string = $v.nsObj
proc ToString*[T](v: IReadOnlyCollection[T]): string = $v.nsObj
proc nsToIEnumerable*[T](v: IReadOnlyCollection[T]): IEnumerable[T] =
  if v.nsObj != nil: result = v.nsVt.fEnum(v.nsObj)
proc Count*[T](v: IReadOnlyList[T]): int32 = v.nsVt.fCount(nsIfaceObj(v))
iterator items*[T](v: IReadOnlyList[T]): T =
  let e = v.nsVt.fEnum(nsIfaceObj(v)).make()
  while e.MoveNext(): yield e.Current
proc `$`*[T](v: IReadOnlyList[T]): string = $v.nsObj
proc ToString*[T](v: IReadOnlyList[T]): string = $v.nsObj
proc nsToIEnumerable*[T](v: IReadOnlyList[T]): IEnumerable[T] =
  if v.nsObj != nil: result = v.nsVt.fEnum(v.nsObj)
proc Count*[T](v: ICollection[T]): int32 = v.nsVt.fCount(nsIfaceObj(v))
iterator items*[T](v: ICollection[T]): T =
  let e = v.nsVt.fEnum(nsIfaceObj(v)).make()
  while e.MoveNext(): yield e.Current
proc `$`*[T](v: ICollection[T]): string = $v.nsObj
proc ToString*[T](v: ICollection[T]): string = $v.nsObj
proc nsToIEnumerable*[T](v: ICollection[T]): IEnumerable[T] =
  if v.nsObj != nil: result = v.nsVt.fEnum(v.nsObj)
proc Count*[T](v: IList[T]): int32 = v.nsVt.fCount(nsIfaceObj(v))
iterator items*[T](v: IList[T]): T =
  let e = v.nsVt.fEnum(nsIfaceObj(v)).make()
  while e.MoveNext(): yield e.Current
proc `$`*[T](v: IList[T]): string = $v.nsObj
proc ToString*[T](v: IList[T]): string = $v.nsObj
proc nsToIEnumerable*[T](v: IList[T]): IEnumerable[T] =
  if v.nsObj != nil: result = v.nsVt.fEnum(v.nsObj)
proc `[]`*[T](v: IReadOnlyList[T]; i: int32): T = v.nsVt.fGet(nsIfaceObj(v), i)
proc IsReadOnly*[T](v: ICollection[T]): bool =
  discard nsIfaceObj(v)
  v.nsVt.fIsReadOnly
proc Add*[T](v: ICollection[T]; x: T) = v.nsVt.fAdd(nsIfaceObj(v), x)
proc Clear*[T](v: ICollection[T]) = v.nsVt.fClear(nsIfaceObj(v))
proc Contains*[T](v: ICollection[T]; x: T): bool = v.nsVt.fContains(nsIfaceObj(v), x)
proc CopyTo*[T](v: ICollection[T]; arr: NsArray[T]; arrayIndex: int32) =
  v.nsVt.fCopyTo(nsIfaceObj(v), arr, arrayIndex)
proc Remove*[T](v: ICollection[T]; x: T): bool = v.nsVt.fRemove(nsIfaceObj(v), x)
proc IsReadOnly*[T](v: IList[T]): bool =
  discard nsIfaceObj(v)
  v.nsVt.fIsReadOnly
proc Add*[T](v: IList[T]; x: T) = v.nsVt.fAdd(nsIfaceObj(v), x)
proc Clear*[T](v: IList[T]) = v.nsVt.fClear(nsIfaceObj(v))
proc Contains*[T](v: IList[T]; x: T): bool = v.nsVt.fContains(nsIfaceObj(v), x)
proc CopyTo*[T](v: IList[T]; arr: NsArray[T]; arrayIndex: int32) =
  v.nsVt.fCopyTo(nsIfaceObj(v), arr, arrayIndex)
proc Remove*[T](v: IList[T]; x: T): bool = v.nsVt.fRemove(nsIfaceObj(v), x)
proc `[]`*[T](v: IList[T]; i: int32): T = v.nsVt.fGet(nsIfaceObj(v), i)
proc `[]=`*[T](v: IList[T]; i: int32; x: T) = v.nsVt.fSet(nsIfaceObj(v), i, x)
proc IndexOf*[T](v: IList[T]; x: T): int32 = v.nsVt.fIndexOf(nsIfaceObj(v), x)
proc Insert*[T](v: IList[T]; i: int32; x: T) = v.nsVt.fInsert(nsIfaceObj(v), i, x)
proc RemoveAt*[T](v: IList[T]; i: int32) = v.nsVt.fRemoveAt(nsIfaceObj(v), i)

proc Count*[T](v: ISet[T]): int32 = v.nsVt.fCount(nsIfaceObj(v))
iterator items*[T](v: ISet[T]): T =
  let e = v.nsVt.fEnum(nsIfaceObj(v)).make()
  while e.MoveNext(): yield e.Current
proc `$`*[T](v: ISet[T]): string = $v.nsObj
proc ToString*[T](v: ISet[T]): string = $v.nsObj
proc nsToIEnumerable*[T](v: ISet[T]): IEnumerable[T] =
  if v.nsObj != nil: result = v.nsVt.fEnum(v.nsObj)
proc Contains*[T](v: ISet[T]; x: T): bool = v.nsVt.fContains(nsIfaceObj(v), x)
proc IsSubsetOf*[T](v: ISet[T]; other: Enumerable[T]): bool =
  v.nsVt.fIsSubsetOf(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc IsSupersetOf*[T](v: ISet[T]; other: Enumerable[T]): bool =
  v.nsVt.fIsSupersetOf(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc IsProperSubsetOf*[T](v: ISet[T]; other: Enumerable[T]): bool =
  v.nsVt.fIsProperSubsetOf(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc IsProperSupersetOf*[T](v: ISet[T]; other: Enumerable[T]): bool =
  v.nsVt.fIsProperSupersetOf(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc Overlaps*[T](v: ISet[T]; other: Enumerable[T]): bool =
  v.nsVt.fOverlaps(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc SetEquals*[T](v: ISet[T]; other: Enumerable[T]): bool =
  v.nsVt.fSetEquals(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc Count*[T](v: IReadOnlySet[T]): int32 = v.nsVt.fCount(nsIfaceObj(v))
iterator items*[T](v: IReadOnlySet[T]): T =
  let e = v.nsVt.fEnum(nsIfaceObj(v)).make()
  while e.MoveNext(): yield e.Current
proc `$`*[T](v: IReadOnlySet[T]): string = $v.nsObj
proc ToString*[T](v: IReadOnlySet[T]): string = $v.nsObj
proc nsToIEnumerable*[T](v: IReadOnlySet[T]): IEnumerable[T] =
  if v.nsObj != nil: result = v.nsVt.fEnum(v.nsObj)
proc Contains*[T](v: IReadOnlySet[T]; x: T): bool = v.nsVt.fContains(nsIfaceObj(v), x)
proc IsSubsetOf*[T](v: IReadOnlySet[T]; other: Enumerable[T]): bool =
  v.nsVt.fIsSubsetOf(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc IsSupersetOf*[T](v: IReadOnlySet[T]; other: Enumerable[T]): bool =
  v.nsVt.fIsSupersetOf(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc IsProperSubsetOf*[T](v: IReadOnlySet[T]; other: Enumerable[T]): bool =
  v.nsVt.fIsProperSubsetOf(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc IsProperSupersetOf*[T](v: IReadOnlySet[T]; other: Enumerable[T]): bool =
  v.nsVt.fIsProperSupersetOf(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc Overlaps*[T](v: IReadOnlySet[T]; other: Enumerable[T]): bool =
  v.nsVt.fOverlaps(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc SetEquals*[T](v: IReadOnlySet[T]; other: Enumerable[T]): bool =
  v.nsVt.fSetEquals(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc IsReadOnly*[T](v: ISet[T]): bool =
  discard nsIfaceObj(v)
  v.nsVt.fIsReadOnly
proc Add*[T](v: ISet[T]; x: T): bool = v.nsVt.fAddNew(nsIfaceObj(v), x)
proc Clear*[T](v: ISet[T]) = v.nsVt.fClear(nsIfaceObj(v))
proc CopyTo*[T](v: ISet[T]; arr: NsArray[T]; arrayIndex: int32) =
  v.nsVt.fCopyTo(nsIfaceObj(v), arr, arrayIndex)
proc Remove*[T](v: ISet[T]; x: T): bool = v.nsVt.fRemove(nsIfaceObj(v), x)
proc UnionWith*[T](v: ISet[T]; other: Enumerable[T]) =
  v.nsVt.fUnionWith(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc IntersectWith*[T](v: ISet[T]; other: Enumerable[T]) =
  v.nsVt.fIntersectWith(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc ExceptWith*[T](v: ISet[T]; other: Enumerable[T]) =
  v.nsVt.fExceptWith(nsIfaceObj(v), nsArrayOf(snapshot(other)))
proc SymmetricExceptWith*[T](v: ISet[T]; other: Enumerable[T]) =
  v.nsVt.fSymmetricExceptWith(nsIfaceObj(v), nsArrayOf(snapshot(other)), nsAsHashSet(other))
proc Count*[K, V](v: IReadOnlyDictionary[K, V]): int32 = v.nsVt.fCount(nsIfaceObj(v))
iterator items*[K, V](v: IReadOnlyDictionary[K, V]): KeyValuePair[K, V] =
  let e = v.nsVt.fEnum(nsIfaceObj(v)).make()
  while e.MoveNext(): yield e.Current
proc `$`*[K, V](v: IReadOnlyDictionary[K, V]): string = $v.nsObj
proc ToString*[K, V](v: IReadOnlyDictionary[K, V]): string = $v.nsObj
proc nsToIEnumerable*[K, V](v: IReadOnlyDictionary[K, V]): IEnumerable[KeyValuePair[K, V]] =
  if v.nsObj != nil: result = v.nsVt.fEnum(v.nsObj)
proc `[]`*[K, V](v: IReadOnlyDictionary[K, V]; k: K): V = v.nsVt.fGet(nsIfaceObj(v), k)
proc ContainsKey*[K, V](v: IReadOnlyDictionary[K, V]; k: K): bool = v.nsVt.fContainsKey(nsIfaceObj(v), k)
proc TryGetValue*[K, V](v: IReadOnlyDictionary[K, V]; k: K; value: var V): bool =
  v.nsVt.fTryGetValue(nsIfaceObj(v), k, value)
proc Count*[K, V](v: IDictionary[K, V]): int32 = v.nsVt.fCount(nsIfaceObj(v))
iterator items*[K, V](v: IDictionary[K, V]): KeyValuePair[K, V] =
  let e = v.nsVt.fEnum(nsIfaceObj(v)).make()
  while e.MoveNext(): yield e.Current
proc `$`*[K, V](v: IDictionary[K, V]): string = $v.nsObj
proc ToString*[K, V](v: IDictionary[K, V]): string = $v.nsObj
proc nsToIEnumerable*[K, V](v: IDictionary[K, V]): IEnumerable[KeyValuePair[K, V]] =
  if v.nsObj != nil: result = v.nsVt.fEnum(v.nsObj)
proc `[]`*[K, V](v: IDictionary[K, V]; k: K): V = v.nsVt.fGet(nsIfaceObj(v), k)
proc ContainsKey*[K, V](v: IDictionary[K, V]; k: K): bool = v.nsVt.fContainsKey(nsIfaceObj(v), k)
proc TryGetValue*[K, V](v: IDictionary[K, V]; k: K; value: var V): bool =
  v.nsVt.fTryGetValue(nsIfaceObj(v), k, value)
proc Keys*[K, V](v: IReadOnlyDictionary[K, V]): IEnumerable[K] = v.nsVt.fKeys(nsIfaceObj(v))
proc Values*[K, V](v: IReadOnlyDictionary[K, V]): IEnumerable[V] = v.nsVt.fValues(nsIfaceObj(v))
proc Keys*[K, V](v: IDictionary[K, V]): ICollection[K] = v.nsVt.fKeys(nsIfaceObj(v))
proc Values*[K, V](v: IDictionary[K, V]): ICollection[V] = v.nsVt.fValues(nsIfaceObj(v))
proc `[]=`*[K, V](v: IDictionary[K, V]; k: K; x: V) = v.nsVt.fSet(nsIfaceObj(v), k, x)
proc Add*[K, V](v: IDictionary[K, V]; k: K; x: V) = v.nsVt.fAdd(nsIfaceObj(v), k, x)
proc Remove*[K, V](v: IDictionary[K, V]; k: K): bool = v.nsVt.fRemove(nsIfaceObj(v), k)
proc Clear*[K, V](v: IDictionary[K, V]) = v.nsVt.fClear(nsIfaceObj(v))
proc IsReadOnly*[K, V](v: IDictionary[K, V]): bool =
  discard nsIfaceObj(v)
  false

# The conversions the compiler inserts: from a collection or an array, and from an
# interface to one it extends (`IList<T>` is an `ICollection<T>`), which asks the
# object for that interface's table.

proc nsIfaceUp[I](o: RootRef): I =
  if o != nil: result = I(nsObj: o, nsVt: cast[typeof(result.nsVt)](nsVtByKey(o, nsKeyOf(I))))

proc nsToIReadOnlyCollection*[T](xs: List[T]): IReadOnlyCollection[T] =
  if xs != nil: result = IReadOnlyCollection[T](nsObj: xs, nsVt: nsReadOnlyCollectionVt[List[T], T]())
proc nsToIReadOnlyCollection*[T](xs: NsArray[T]): IReadOnlyCollection[T] =
  if xs != nil: result = IReadOnlyCollection[T](nsObj: xs, nsVt: nsReadOnlyCollectionVt[NsArray[T], T]())
proc nsToIReadOnlyCollection*[T](v: IReadOnlyList[T]): IReadOnlyCollection[T] =
  nsIfaceUp[IReadOnlyCollection[T]](v.nsObj)
proc nsToIReadOnlyList*[T](xs: List[T]): IReadOnlyList[T] =
  if xs != nil: result = IReadOnlyList[T](nsObj: xs, nsVt: nsReadOnlyListVt[List[T], T]())
proc nsToIReadOnlyList*[T](xs: NsArray[T]): IReadOnlyList[T] =
  if xs != nil: result = IReadOnlyList[T](nsObj: xs, nsVt: nsReadOnlyListVt[NsArray[T], T]())
proc nsToICollection*[T](xs: List[T]): ICollection[T] =
  if xs != nil: result = ICollection[T](nsObj: xs, nsVt: nsCollectionVt[List[T], T]())
proc nsToICollection*[T](xs: NsArray[T]): ICollection[T] =
  if xs != nil: result = ICollection[T](nsObj: xs, nsVt: nsCollectionVt[NsArray[T], T]())
proc nsToICollection*[T](v: IList[T]): ICollection[T] = nsIfaceUp[ICollection[T]](v.nsObj)
proc nsToIList*[T](xs: List[T]): IList[T] =
  if xs != nil: result = IList[T](nsObj: xs, nsVt: nsListVt[List[T], T]())
proc nsToIList*[T](xs: NsArray[T]): IList[T] =
  if xs != nil: result = IList[T](nsObj: xs, nsVt: nsListVt[NsArray[T], T]())

proc nsToISet*[T](xs: HashSet[T]): ISet[T] =
  if xs != nil: result = ISet[T](nsObj: xs, nsVt: nsSetVt[HashSet[T], T]())
proc nsToIReadOnlySet*[T](xs: HashSet[T]): IReadOnlySet[T] =
  if xs != nil: result = IReadOnlySet[T](nsObj: xs, nsVt: nsReadOnlySetVt[HashSet[T], T]())
proc nsToICollection*[T](xs: HashSet[T]): ICollection[T] =
  if xs != nil: result = ICollection[T](nsObj: xs, nsVt: nsCollectionVt[HashSet[T], T]())
proc nsToIReadOnlyCollection*[T](xs: HashSet[T]): IReadOnlyCollection[T] =
  if xs != nil: result = IReadOnlyCollection[T](nsObj: xs, nsVt: nsReadOnlyCollectionVt[HashSet[T], T]())
proc nsToIReadOnlyCollection*[T](xs: Queue[T]): IReadOnlyCollection[T] =
  if xs != nil: result = IReadOnlyCollection[T](nsObj: xs, nsVt: nsReadOnlyCollectionVt[Queue[T], T]())
proc nsToIReadOnlyCollection*[T](xs: Stack[T]): IReadOnlyCollection[T] =
  if xs != nil: result = IReadOnlyCollection[T](nsObj: xs, nsVt: nsReadOnlyCollectionVt[Stack[T], T]())
proc nsToIReadOnlyCollection*[T](xs: LinkedList[T]): IReadOnlyCollection[T] =
  if xs != nil: result = IReadOnlyCollection[T](nsObj: xs, nsVt: nsReadOnlyCollectionVt[LinkedList[T], T]())
proc nsToICollection*[T](xs: LinkedList[T]): ICollection[T] =
  if xs != nil: result = ICollection[T](nsObj: xs, nsVt: nsCollectionVt[LinkedList[T], T]())
proc nsToIDictionary*[K, V](xs: Dictionary[K, V]): IDictionary[K, V] =
  if xs != nil: result = IDictionary[K, V](nsObj: xs, nsVt: nsDictionaryVt[Dictionary[K, V], K, V]())
proc nsToIReadOnlyDictionary*[K, V](xs: Dictionary[K, V]): IReadOnlyDictionary[K, V] =
  if xs != nil:
    result = IReadOnlyDictionary[K, V](nsObj: xs,
                                       nsVt: nsReadOnlyDictionaryVt[Dictionary[K, V], K, V]())
proc nsToIReadOnlyCollection*[K, V](xs: Dictionary[K, V]): IReadOnlyCollection[KeyValuePair[K, V]] =
  if xs != nil:
    result = IReadOnlyCollection[KeyValuePair[K, V]](nsObj: xs,
      nsVt: nsReadOnlyCollectionVt[Dictionary[K, V], KeyValuePair[K, V]]())
proc nsToICollection*[T](v: ISet[T]): ICollection[T] = nsIfaceUp[ICollection[T]](v.nsObj)
proc nsToIReadOnlyCollection*[T](v: IReadOnlySet[T]): IReadOnlyCollection[T] =
  nsIfaceUp[IReadOnlyCollection[T]](v.nsObj)
proc nsToIReadOnlyCollection*[K, V](v: IReadOnlyDictionary[K, V]): IReadOnlyCollection[KeyValuePair[K, V]] =
  nsIfaceUp[IReadOnlyCollection[KeyValuePair[K, V]]](v.nsObj)

# `is`/`as`: the tables an object has, by the interface's key.

# An array's tables: an array is no class of its own here (its type is the
# runtime's), so a type test answers for it by the element type the interface names.
proc nsLibAs*[T](o: RootRef; t: typedesc[IList[T]]): IList[T] =
  if o of NsArray[T]: result = nsToIList(NsArray[T](o))
proc nsLibAs*[T](o: RootRef; t: typedesc[ICollection[T]]): ICollection[T] =
  if o of NsArray[T]: result = nsToICollection(NsArray[T](o))
proc nsLibAs*[T](o: RootRef; t: typedesc[IReadOnlyList[T]]): IReadOnlyList[T] =
  if o of NsArray[T]: result = nsToIReadOnlyList(NsArray[T](o))
proc nsLibAs*[T](o: RootRef; t: typedesc[IReadOnlyCollection[T]]): IReadOnlyCollection[T] =
  if o of NsArray[T]: result = nsToIReadOnlyCollection(NsArray[T](o))

method nsVtByKey*[T](x: List[T]; key: string): pointer =
  if key == nsKeyOf(IList[T]): return nsListVt[List[T], T]()
  if key == nsKeyOf(ICollection[T]): return nsCollectionVt[List[T], T]()
  if key == nsKeyOf(IReadOnlyList[T]): return nsReadOnlyListVt[List[T], T]()
  if key == nsKeyOf(IReadOnlyCollection[T]): return nsReadOnlyCollectionVt[List[T], T]()
  procCall nsVtByKey(RootRef(x), key)
method nsVtByKey*[T](x: HashSet[T]; key: string): pointer =
  if key == nsKeyOf(ISet[T]): return nsSetVt[HashSet[T], T]()
  if key == nsKeyOf(IReadOnlySet[T]): return nsReadOnlySetVt[HashSet[T], T]()
  if key == nsKeyOf(ICollection[T]): return nsCollectionVt[HashSet[T], T]()
  if key == nsKeyOf(IReadOnlyCollection[T]): return nsReadOnlyCollectionVt[HashSet[T], T]()
  procCall nsVtByKey(RootRef(x), key)
method nsVtByKey*[K, V](x: Dictionary[K, V]; key: string): pointer =
  if key == nsKeyOf(IDictionary[K, V]): return nsDictionaryVt[Dictionary[K, V], K, V]()
  if key == nsKeyOf(IReadOnlyDictionary[K, V]):
    return nsReadOnlyDictionaryVt[Dictionary[K, V], K, V]()
  if key == nsKeyOf(IReadOnlyCollection[KeyValuePair[K, V]]):
    return nsReadOnlyCollectionVt[Dictionary[K, V], KeyValuePair[K, V]]()
  procCall nsVtByKey(RootRef(x), key)
method nsVtByKey*[T](x: Queue[T]; key: string): pointer =
  if key == nsKeyOf(IReadOnlyCollection[T]): return nsReadOnlyCollectionVt[Queue[T], T]()
  procCall nsVtByKey(RootRef(x), key)
method nsVtByKey*[T](x: Stack[T]; key: string): pointer =
  if key == nsKeyOf(IReadOnlyCollection[T]): return nsReadOnlyCollectionVt[Stack[T], T]()
  procCall nsVtByKey(RootRef(x), key)
method nsVtByKey*[T](x: LinkedList[T]; key: string): pointer =
  if key == nsKeyOf(ICollection[T]): return nsCollectionVt[LinkedList[T], T]()
  if key == nsKeyOf(IReadOnlyCollection[T]): return nsReadOnlyCollectionVt[LinkedList[T], T]()
  procCall nsVtByKey(RootRef(x), key)

# --- a user's class implementing a library interface ------------------------------
#
# The conversion the compiler inserts names the interface (`t`), which gives its
# type arguments; the table is built from the class's own members. The class's
# `nsVtByKey` override asks `nsKeysOf<Interface>` for the interface and those it
# extends.

type NsUserClass = ref RootObj and not NsArrayBase and not ref NsCollectionBase

proc nsToIList*[C: NsUserClass; T](c: C; t: typedesc[IList[T]]): IList[T] =
  if c != nil: result = IList[T](nsObj: c, nsVt: nsListVt[C, T]())
proc nsToICollection*[C: NsUserClass; T](c: C; t: typedesc[ICollection[T]]): ICollection[T] =
  if c != nil: result = ICollection[T](nsObj: c, nsVt: nsCollectionVt[C, T]())
proc nsToIReadOnlyList*[C: NsUserClass; T](c: C; t: typedesc[IReadOnlyList[T]]): IReadOnlyList[T] =
  if c != nil: result = IReadOnlyList[T](nsObj: c, nsVt: nsReadOnlyListVt[C, T]())
proc nsToIReadOnlyCollection*[C: NsUserClass; T](c: C; t: typedesc[IReadOnlyCollection[T]]):
    IReadOnlyCollection[T] =
  if c != nil: result = IReadOnlyCollection[T](nsObj: c, nsVt: nsReadOnlyCollectionVt[C, T]())
proc nsToISet*[C: NsUserClass; T](c: C; t: typedesc[ISet[T]]): ISet[T] =
  if c != nil: result = ISet[T](nsObj: c, nsVt: nsSetVt[C, T]())
proc nsToIReadOnlySet*[C: NsUserClass; T](c: C; t: typedesc[IReadOnlySet[T]]): IReadOnlySet[T] =
  if c != nil: result = IReadOnlySet[T](nsObj: c, nsVt: nsReadOnlySetVt[C, T]())
proc nsToIDictionary*[C: NsUserClass; K, V](c: C; t: typedesc[IDictionary[K, V]]): IDictionary[K, V] =
  if c != nil: result = IDictionary[K, V](nsObj: c, nsVt: nsDictionaryVt[C, K, V]())
proc nsToIReadOnlyDictionary*[C: NsUserClass; K, V](c: C; t: typedesc[IReadOnlyDictionary[K, V]]):
    IReadOnlyDictionary[K, V] =
  if c != nil:
    result = IReadOnlyDictionary[K, V](nsObj: c, nsVt: nsReadOnlyDictionaryVt[C, K, V]())

proc nsKeysOfIList*[C, T](key: string): pointer =
  if key == nsKeyOf(IList[T]): return nsListVt[C, T]()
  if key == nsKeyOf(ICollection[T]): return nsCollectionVt[C, T]()
proc nsKeysOfICollection*[C, T](key: string): pointer =
  if key == nsKeyOf(ICollection[T]): return nsCollectionVt[C, T]()
proc nsKeysOfIReadOnlyList*[C, T](key: string): pointer =
  if key == nsKeyOf(IReadOnlyList[T]): return nsReadOnlyListVt[C, T]()
  if key == nsKeyOf(IReadOnlyCollection[T]): return nsReadOnlyCollectionVt[C, T]()
proc nsKeysOfIReadOnlyCollection*[C, T](key: string): pointer =
  if key == nsKeyOf(IReadOnlyCollection[T]): return nsReadOnlyCollectionVt[C, T]()
proc nsKeysOfISet*[C, T](key: string): pointer =
  if key == nsKeyOf(ISet[T]): return nsSetVt[C, T]()
  if key == nsKeyOf(ICollection[T]): return nsCollectionVt[C, T]()
proc nsKeysOfIReadOnlySet*[C, T](key: string): pointer =
  if key == nsKeyOf(IReadOnlySet[T]): return nsReadOnlySetVt[C, T]()
  if key == nsKeyOf(IReadOnlyCollection[T]): return nsReadOnlyCollectionVt[C, T]()
proc nsKeysOfIDictionary*[C, K, V](key: string): pointer =
  if key == nsKeyOf(IDictionary[K, V]): return nsDictionaryVt[C, K, V]()
proc nsKeysOfIReadOnlyDictionary*[C, K, V](key: string): pointer =
  if key == nsKeyOf(IReadOnlyDictionary[K, V]): return nsReadOnlyDictionaryVt[C, K, V]()
  if key == nsKeyOf(IReadOnlyCollection[KeyValuePair[K, V]]):
    return nsReadOnlyCollectionVt[C, KeyValuePair[K, V]]()

# --- comparers -------------------------------------------------------------------
#
# `IComparer<T>` and `IEqualityComparer<T>`, the default ones (a type's own
# `CompareTo` / `Equals` and `GetHashCode` when it has them, else its natural
# order and equality), `Comparer<T>.Create`, and the overloads taking them.

proc nsDefaultCompare[T](a, b: T): int32 =
  mixin CompareTo
  when compiles(a.CompareTo(b)): int32(a.CompareTo(b))
  else: int32(cmp(a, b))

proc nsDefaultEquals[T](a, b: T): bool =
  mixin Equals
  when T is ref RootObj:
    if a.isNil or b.isNil: a.isNil and b.isNil else: a.Equals(b)
  else: a == b

proc nsDefaultHash[T](x: T): int32 =
  mixin GetHashCode
  when T is ref RootObj:
    if x.isNil: 0'i32 else: x.GetHashCode()
  else: cast[int32](nsKeyHash(x))

proc Compare*[T](v: IComparer[T]; a, b: T): int32 = v.nsVt.fCompare(nsIfaceObj(v), a, b)
proc Equals*[T](v: IEqualityComparer[T]; a, b: T): bool = v.nsVt.fEquals(nsIfaceObj(v), a, b)
proc GetHashCode*[T](v: IEqualityComparer[T]; x: T): int32 =
  v.nsVt.fGetHashCode(nsIfaceObj(v), x)
proc `$`*[T](v: IComparer[T]): string = $v.nsObj
proc `$`*[T](v: IEqualityComparer[T]): string = $v.nsObj

proc nsComparerVt[C, T](): ptr nsVT_IComparer[T] =
  mixin Compare
  var store {.global.}: nsVT_IComparer[T]
  var ready {.global.} = false
  if not ready:
    ready = true
    store.fCompare = proc (o: RootRef; a, b: T): int32 {.nimcall.} = Compare(cast[C](o), a, b)
  addr store

proc nsEqualityComparerVt[C, T](): ptr nsVT_IEqualityComparer[T] =
  mixin Equals, GetHashCode
  var store {.global.}: nsVT_IEqualityComparer[T]
  var ready {.global.} = false
  if not ready:
    ready = true
    store.fEquals = proc (o: RootRef; a, b: T): bool {.nimcall.} = Equals(cast[C](o), a, b)
    store.fGetHashCode = proc (o: RootRef; x: T): int32 {.nimcall.} =
      GetHashCode(cast[C](o), x)
  addr store

proc Default*[T](t: typedesc[Comparer[T]]): Comparer[T] =
  ## A type's own order: its `CompareTo`, else the natural one.
  var store {.global.}: Comparer[T]
  if store.isNil: store = Comparer[T](compare: nsDefaultCompare[T])
  store
proc Create*[T](t: typedesc[Comparer[T]]; comparison: Comparison[T]): Comparer[T] =
  Comparer[T](compare: proc (a, b: T): int32 = comparison(a, b))
proc Compare*[T](c: Comparer[T]; a, b: T): int32 = c.compare(a, b)

proc Default*[T](t: typedesc[EqualityComparer[T]]): EqualityComparer[T] =
  ## A type's own equality: its `Equals` and `GetHashCode`, else `==` and the hash.
  var store {.global.}: EqualityComparer[T]
  if store.isNil: store = EqualityComparer[T]()
  store
proc Equals*[T](c: EqualityComparer[T]; a, b: T): bool = nsDefaultEquals(a, b)
proc GetHashCode*[T](c: EqualityComparer[T]; x: T): int32 = nsDefaultHash(x)

proc nsToIComparer*[T](c: Comparer[T]): IComparer[T] =
  if c != nil: result = IComparer[T](nsObj: c, nsVt: nsComparerVt[Comparer[T], T]())
proc nsToIEqualityComparer*[T](c: EqualityComparer[T]): IEqualityComparer[T] =
  if c != nil:
    result = IEqualityComparer[T](nsObj: c, nsVt: nsEqualityComparerVt[EqualityComparer[T], T]())
proc nsToIComparer*[C: NsUserClass; T](c: C; t: typedesc[IComparer[T]]): IComparer[T] =
  if c != nil: result = IComparer[T](nsObj: c, nsVt: nsComparerVt[C, T]())
proc nsToIEqualityComparer*[C: NsUserClass; T](c: C; t: typedesc[IEqualityComparer[T]]):
    IEqualityComparer[T] =
  if c != nil: result = IEqualityComparer[T](nsObj: c, nsVt: nsEqualityComparerVt[C, T]())
proc nsKeysOfIComparer*[C, T](key: string): pointer =
  if key == nsKeyOf(IComparer[T]): return nsComparerVt[C, T]()
proc nsKeysOfIEqualityComparer*[C, T](key: string): pointer =
  if key == nsKeyOf(IEqualityComparer[T]): return nsEqualityComparerVt[C, T]()
method nsVtByKey*[T](x: Comparer[T]; key: string): pointer =
  if key == nsKeyOf(IComparer[T]): return nsComparerVt[Comparer[T], T]()
  procCall nsVtByKey(RootRef(x), key)
method nsVtByKey*[T](x: EqualityComparer[T]; key: string): pointer =
  if key == nsKeyOf(IEqualityComparer[T]): return nsEqualityComparerVt[EqualityComparer[T], T]()
  procCall nsVtByKey(RootRef(x), key)

proc Sort*[T](l: List[T]; comparer: IComparer[T]) =
  ## In the comparer's order; null is the default one.
  if comparer.nsObj == nil: l.Sort()
  else:
    algorithm.sort(l.data, proc (a, b: T): int = int(comparer.Compare(a, b)))
    touch l
proc BinarySearch*[T](l: List[T]; x: T; comparer: IComparer[T]): int32 =
  ## The index of `x` in a list sorted by the comparer, or the complement of where
  ## it would go.
  var lo = 0
  var hi = l.data.len - 1
  while lo <= hi:
    let mid = lo + (hi - lo) div 2
    let c = (if comparer.nsObj == nil: nsDefaultCompare(l.data[mid], x)
             else: comparer.Compare(l.data[mid], x))
    if c == 0: return int32(mid)
    if c < 0: lo = mid + 1
    else: hi = mid - 1
  int32(not lo)

proc nsToIComparer*(c: StringComparer): IComparer[string] =
  if c != nil: result = IComparer[string](nsObj: c, nsVt: nsComparerVt[StringComparer, string]())
proc nsToIEqualityComparer*(c: StringComparer): IEqualityComparer[string] =
  if c != nil:
    result = IEqualityComparer[string](nsObj: c,
                                       nsVt: nsEqualityComparerVt[StringComparer, string]())
proc nsLibAs*(o: RootRef; t: typedesc[IComparer[string]]): IComparer[string] =
  if o of StringComparer: result = nsToIComparer(StringComparer(o))
proc nsLibAs*(o: RootRef; t: typedesc[IEqualityComparer[string]]): IEqualityComparer[string] =
  if o of StringComparer: result = nsToIEqualityComparer(StringComparer(o))

proc snapshot[T](collection: Enumerable[T]): seq[T] =
  for x in items(collection): result.add x
