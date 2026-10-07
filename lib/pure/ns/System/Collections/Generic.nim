# N# standard library: the System.Collections.Generic namespace.
#
# C# collection types on top of Nim's stdlib, imported by
# `using System.Collections.Generic;`.
#
# C# names are kept at the source level (SPEC section 15, "Naming"), so `List<T>`
# is a `seq[T]` and `Add`, `Contains`, ... are ordinary procs reached through
# Nim's dot-call syntax. `.Count` is C#'s name for what Nim spells `len`, so the
# library declares it per collection below; `Length` reaches the `openArray` procs
# in `System`, the way C# reaches `Array.Length`.
#
# Pinned surface (SPEC section 15.1). Deliberately absent:
#   * predicate members - Find, FindAll, Exists, RemoveAll, ForEach,
#     Sort(comparison) - need lambdas typed from a *method parameter*, which 3b
#     does not do yet (it only types lambdas from a declared local of delegate
#     type).
#   * TryGetValue(k, out v) - `out` parameters are not parsed yet.
#
#   List<T>         Add AddRange Clear Contains Count IndexOf Insert Remove
#                   RemoveAt Reverse Sort ToArray, [] and []= via seq
#   Dictionary<K,V> Add Clear ContainsKey ContainsValue Count Remove Keys Values,
#                   [] and []= via Table
#   HashSet<T>      Add Clear Contains Count Remove ToArray UnionWith IntersectWith
#                   ExceptWith
#   Queue<T>        Enqueue Dequeue Peek Count Contains Clear ToArray
#   Stack<T>        Push Pop Peek Count Contains Clear ToArray
#   LinkedList<T>   AddFirst AddLast RemoveFirst RemoveLast Remove Contains Clear
#                   Count (and iteration via `foreach`)

import std/tables
import std/deques
import std/algorithm
import std/sets

# Nim's `import` is not transitive for symbol visibility. `Dictionary` is a
# `Table` and `HashSet` is a `HashSet`, so their operations (indexing, `in`,
# `keys`, `values`, ...) have to reach the N# user too.
export tables
export sets

type
  List*[T] = seq[T]
  Dictionary*[K, V] = Table[K, V]
  Queue*[T] = object
    data: Deque[T]
  Stack*[T] = object
    data: Deque[T]
  LinkedList*[T] = object
    ## C#'s doubly-linked list. Members are spelled as C# spells them
    ## (`AddFirst`, `RemoveLast`, ...); the backing store is Nim's `seq`.
    data: seq[T]
  LinkedListNode*[T] = ref object
    ## C#'s `LinkedList<T>` node. `AddFirst`/`AddLast` return one, so the type
    ## has to exist here; the frontend places it as a class, which is what makes
    ## the semantic projection agree with C#'s `LinkedListNode<T>` (SPEC 15.1).
    value*: T

{.push discardable.}

proc newList*[T](): List[T] = @[]
proc newDictionary*[K, V](): Dictionary[K, V] = initTable[K, V]()
proc newHashSet*[T](): HashSet[T] = initHashSet[T]()
proc newQueue*[T](): Queue[T] = Queue[T](data: initDeque[T]())
proc newStack*[T](): Stack[T] = Stack[T](data: initDeque[T]())
proc newLinkedList*[T](): LinkedList[T] = LinkedList[T](data: @[])

# --- Count -----------------------------------------------------------------
#
# C# reads `Count` on every collection it has; Nim spells the same thing `len`, so
# each collection C# knows gets a declaration of its own here. `HashSet` is Nim's
# own type, which the library only builds on, so this is where its `Count` lives.

proc Count*[T](l: List[T]): int32 = int32(l.len)
proc Count*[K, V](t: Dictionary[K, V]): int32 = int32(t.len)
proc Count*[T](s: HashSet[T]): int32 = int32(s.len)
proc Count*[T](q: Queue[T]): int32 = int32(q.data.len)
proc Count*[T](s: Stack[T]): int32 = int32(s.data.len)
proc Count*[T](l: LinkedList[T]): int32 = int32(l.data.len)

# --- List<T> ---------------------------------------------------------------

proc Add*[T](l: var List[T], x: T) = l.add x
proc AddRange*[T](l: var List[T], items: openArray[T]) = l.add items
proc Clear*[T](l: var List[T]) = l.setLen(0)
proc Contains*[T](l: List[T], x: T): bool = x in l
proc IndexOf*[T](l: List[T], x: T): int = l.find(x)
proc Insert*[T](l: var List[T], i: int, x: T) = l.insert(x, i)
proc RemoveAt*[T](l: var List[T], i: int) = l.delete(i)
proc Remove*[T](l: var List[T], x: T): bool =
  let i = l.find(x)
  if i >= 0:
    l.delete(i)
    result = true
proc Reverse*[T](l: var List[T]) = algorithm.reverse(l)
proc Sort*[T](l: var List[T]) = algorithm.sort(l)
proc ToArray*[T](l: List[T]): seq[T] = l

# --- Dictionary<K, V> ------------------------------------------------------

proc Add*[K, V](t: var Dictionary[K, V], k: K, v: V) = t[k] = v
proc Clear*[K, V](t: var Dictionary[K, V]) = t.clear()
proc ContainsKey*[K, V](t: Dictionary[K, V], k: K): bool = t.hasKey(k)
proc ContainsValue*[K, V](t: Dictionary[K, V], v: V): bool =
  for x in t.values:
    if x == v: return true
proc Remove*[K, V](t: var Dictionary[K, V], k: K): bool =
  if t.hasKey(k):
    t.del(k)
    result = true
proc Keys*[K, V](t: Dictionary[K, V]): seq[K] =
  for k in t.keys: result.add k
proc Values*[K, V](t: Dictionary[K, V]): seq[V] =
  for v in t.values: result.add v

# --- HashSet<T> ------------------------------------------------------------

proc Add*[T](s: var HashSet[T], x: T): bool =
  ## `HashSet<T>.Add` reports whether the element was new, exactly as .NET's does.
  if x in s: false
  else:
    s.incl x
    true
proc Clear*[T](s: var HashSet[T]) = s.clear()
proc Contains*[T](s: HashSet[T], x: T): bool = x in s
proc Remove*[T](s: var HashSet[T], x: T): bool =
  if x in s:
    s.excl(x)
    result = true
proc ToArray*[T](s: HashSet[T]): seq[T] =
  for x in s: result.add x
proc UnionWith*[T](s: var HashSet[T], items: openArray[T]) =
  for x in items: s.incl x
proc IntersectWith*[T](s: var HashSet[T], items: openArray[T]) =
  var other = initHashSet[T]()
  for x in items: other.incl x
  s = s * other
proc ExceptWith*[T](s: var HashSet[T], items: openArray[T]) =
  for x in items: s.excl x

# --- Queue<T> (FIFO) -------------------------------------------------------

proc Enqueue*[T](q: var Queue[T], x: T) = q.data.addLast x
proc Dequeue*[T](q: var Queue[T]): T = q.data.popFirst
proc Peek*[T](q: Queue[T]): T = q.data.peekFirst
proc len*[T](q: Queue[T]): int = q.data.len
proc Contains*[T](q: Queue[T], x: T): bool = x in q.data
proc Clear*[T](q: var Queue[T]) = q.data.clear()
proc ToArray*[T](q: Queue[T]): seq[T] =
  for x in q.data: result.add x

# --- Stack<T> (LIFO) -------------------------------------------------------

proc Push*[T](s: var Stack[T], x: T) = s.data.addLast x
proc Pop*[T](s: var Stack[T]): T = s.data.popLast
proc Peek*[T](s: Stack[T]): T = s.data.peekLast
proc len*[T](s: Stack[T]): int = s.data.len
proc Contains*[T](s: Stack[T], x: T): bool = x in s.data
proc Clear*[T](s: var Stack[T]) = s.data.clear()
proc ToArray*[T](s: Stack[T]): seq[T] =
  for x in s.data: result.add x

# --- LinkedList<T> ---------------------------------------------------------
#
# C#'s `LinkedList<T>` members, named as C# names them. `AddFirst`/`AddLast`
# return the new node, as C# does, so they hand back a `LinkedListNode<T>`;
# `First`/`Last` and the `AddAfter`/`AddBefore` families stay absent until a test
# needs them (SPEC section 15.1).

proc AddFirst*[T](l: var LinkedList[T], x: T): LinkedListNode[T] =
  l.data.insert(x, 0)
  LinkedListNode[T](value: x)
proc AddLast*[T](l: var LinkedList[T], x: T): LinkedListNode[T] =
  l.data.add x
  LinkedListNode[T](value: x)
proc RemoveFirst*[T](l: var LinkedList[T]) =
  ## C#'s `RemoveFirst` removes the node at the head and returns nothing.
  if l.data.len > 0: l.data.delete(0)
proc RemoveLast*[T](l: var LinkedList[T]) =
  if l.data.len > 0: l.data.setLen(l.data.len - 1)
proc Remove*[T](l: var LinkedList[T], x: T): bool =
  ## `LinkedList<T>.Remove` drops the first node holding `x`.
  let i = l.data.find(x)
  if i >= 0:
    l.data.delete(i)
    result = true
proc Contains*[T](l: LinkedList[T], x: T): bool = x in l.data
proc Clear*[T](l: var LinkedList[T]) = l.data.setLen(0)
iterator items*[T](l: LinkedList[T]): T =
  ## Lets `foreach (int x in list)` reach the elements, as C# requires.
  for x in l.data: yield x

{.pop.}
