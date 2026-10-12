# The hash table under N#'s `Dictionary<K,V>` and `HashSet<T>`: .NET's own design,
# so that enumeration order and cost follow .NET's.
#
# Entries live in one array in the order they were added, and a removed entry's
# slot goes on a free list that the next addition reuses -- so a dictionary
# enumerates as .NET's does after removals too. Buckets hold 1-based indexes of
# chains through the entries. The table's size is a prime from .NET's list, and a
# hash code is reduced by .NET's `FastMod`, so an integer key can hash to itself
# (as `int.GetHashCode()` does) and still spread: keys that are multiples of a power
# of two do not pile up as they would under a power-of-two mask.

import std/hashes
from intrinsics import Equals, GetHashCode

type
  NsEntry[K, V] = object
    hashCode: uint32
    next: int32          ## the next entry in the chain; below -1 on the free list
    key: K
    value: V
  NsHashMap*[K, V] = object
    buckets: seq[int32]  ## 1-based index of a chain's first entry; 0 is empty
    entries: seq[NsEntry[K, V]]
    count: int32         ## entries used, the free ones included
    freeList: int32
    freeCount: int32
    multiplier: uint64   ## `FastMod`'s for the bucket count
    eq: proc (a, b: K): bool {.closure.}
      ## A comparer's equality and hash (`IEqualityComparer<K>`); nil for the key's own.
    hasher: proc (k: K): uint32 {.closure.}

const
  StartOfFreeList = -3'i32
  Primes = [3'i32, 7, 11, 17, 23, 29, 37, 47, 59, 71, 89, 107, 131, 163, 197, 239, 293,
    353, 431, 521, 631, 761, 919, 1103, 1327, 1597, 1931, 2333, 2801, 3371, 4049, 4861,
    5839, 7013, 8419, 10103, 12143, 14591, 17519, 21023, 25229, 30293, 36353, 43627,
    52361, 62851, 75431, 90523, 108631, 130363, 156437, 187751, 225307, 270371, 324449,
    389357, 467237, 560689, 672827, 807403, 968897, 1162687, 1395263, 1674319, 2009191,
    2411033, 2893249, 3471899, 4166287, 4999559, 5999471, 7199369]

proc isPrime(n: int): bool =
  if (n and 1) == 0: return n == 2
  var d = 3
  while d * d <= n:
    if n mod d == 0: return false
    d += 2
  true

proc getPrime(atLeast: int): int32 =
  ## .NET's `HashHelpers.GetPrime`.
  for p in Primes:
    if p >= atLeast: return p
  var n = atLeast or 1
  while n < int(high(int32)):
    if isPrime(n) and (n - 1) mod 101 != 0: return int32(n)
    n += 2
  int32(atLeast)

proc nsKeyHash*[K](k: K): uint32 {.inline.} =
  ## An integer is its own hash, as in .NET; an object its `GetHashCode()`; anything
  ## else is Nim's `hash`.
  mixin GetHashCode, hash
  when K is ref RootObj and compiles(hash(k)):
    ## A record's members' hash.
    cast[uint32](int32(hash(k) and 0x7FFF_FFFF))
  elif K is ref RootObj:
    if k.isNil: 0'u32 else: cast[uint32](int32(k.GetHashCode()) and 0x7FFF_FFFF'i32)
  elif K is SomeInteger or K is char or K is bool or K is enum:
    when sizeof(K) == 8:
      let x = cast[uint64](k)
      uint32(x and 0xFFFF_FFFF'u64) xor uint32(x shr 32)
    else:
      uint32(cast[uint64](int64(ord(k))) and 0xFFFF_FFFF'u64)
  elif K is ref or K is ptr:
    ## A reference outside the class hierarchy: its address.
    cast[uint32](int32((cast[int](k) xor (cast[int](k) shr 32)) and 0x7FFF_FFFF))
  elif compiles(k.nsObj):
    ## An interface value: the object behind it.
    nsKeyHash(k.nsObj)
  elif (K is object or K is tuple) and not compiles(hash(k)):
    ## A struct with no hash of its own: its fields', as .NET's
    ## `ValueType.GetHashCode` does.
    var h: Hash = 0
    for f in fields(k): h = h !& int(nsKeyHash(f))
    cast[uint32](int32(!$h and 0x7FFF_FFFF))
  else:
    cast[uint32](int32(hash(k) and 0x7FFF_FFFF))

template hashOf[K, V](m: NsHashMap[K, V]; k: K): uint32 =
  (if m.hasher == nil: nsKeyHash(k) else: m.hasher(k))

proc nsKeyEquals*[K](a, b: K): bool {.inline.} =
  ## An object's `Equals`, as .NET compares keys; anything else is `==`.
  mixin Equals
  when K is ref RootObj:
    if a.isNil or b.isNil: a.isNil and b.isNil else: a.Equals(b)
  elif compiles(a.nsObj): nsKeyEquals(a.nsObj, b.nsObj)
  else: a == b

template same[K, V](m: NsHashMap[K, V]; a, b: K): bool =
  (if m.eq == nil: nsKeyEquals(a, b) else: m.eq(a, b))

proc withComparer*[K, V](m: var NsHashMap[K, V]; eq: proc (a, b: K): bool {.closure.};
                         hasher: proc (k: K): int32 {.closure.}) =
  ## Keys compared and hashed by a comparer; set before anything is added.
  m.eq = eq
  m.hasher = proc (k: K): uint32 = cast[uint32](hasher(k) and 0x7FFF_FFFF'i32)

proc bucketOf(m: NsHashMap; h: uint32): int {.inline.} =
  ## .NET's `FastMod`: `h mod buckets.len` without a division.
  let d = uint64(m.buckets.len)
  int((((m.multiplier * uint64(h)) shr 32) + 1) * d shr 32)

proc initBuckets[K, V](m: var NsHashMap[K, V]; capacity: int) =
  let size = getPrime(capacity)
  m.buckets = newSeq[int32](size)
  m.entries = newSeq[NsEntry[K, V]](size)
  m.multiplier = high(uint64) div uint64(size) + 1
  m.freeList = -1

proc initNsHashMap*[K, V](capacity = 0): NsHashMap[K, V] =
  if capacity > 0: result.initBuckets(capacity)
  result.freeList = -1

proc initLike*[K, V, W](m: NsHashMap[K, V]; t: typedesc[W]): NsHashMap[K, W] =
  ## An empty table comparing keys as `m` does.
  result = initNsHashMap[K, W]()
  result.eq = m.eq
  result.hasher = m.hasher

proc len*(m: NsHashMap): int {.inline.} = int(m.count - m.freeCount)

proc find[K, V](m: NsHashMap[K, V]; k: K): int {.inline.} =
  ## The entry holding `k`, or -1.
  if m.buckets.len == 0: return -1
  let h = m.hashOf(k)
  var i = int(m.buckets[m.bucketOf(h)]) - 1
  while i >= 0:
    let e = addr m.entries[i]
    if e.hashCode == h and m.same(e.key, k): return i
    i = int(e.next)
  -1

proc contains*[K, V](m: NsHashMap[K, V]; k: K): bool {.inline.} = m.find(k) >= 0

proc getPtr*[K, V](m: var NsHashMap[K, V]; k: K): ptr V {.inline.} =
  ## The value under `k`, or nil.
  let i = m.find(k)
  if i < 0: nil else: addr m.entries[i].value

proc resize[K, V](m: var NsHashMap[K, V]) =
  ## .NET's `ExpandPrime`: the next prime past twice the entries.
  let size = getPrime(2 * int(m.count))
  m.entries.setLen(size)
  m.buckets = newSeq[int32](size)
  m.multiplier = high(uint64) div uint64(size) + 1
  for i in 0 ..< int(m.count):
    if m.entries[i].next >= -1:
      let b = m.bucketOf(m.entries[i].hashCode)
      m.entries[i].next = m.buckets[b] - 1
      m.buckets[b] = int32(i + 1)

proc put*[K, V](m: var NsHashMap[K, V]; k: K; v: sink V; overwrite: bool): bool =
  ## Adds `k`, or replaces its value when `overwrite`; whether it was new.
  if m.buckets.len == 0: m.initBuckets(0)
  let h = m.hashOf(k)
  var b = m.bucketOf(h)
  var i = int(m.buckets[b]) - 1
  while i >= 0:
    if m.entries[i].hashCode == h and m.same(m.entries[i].key, k):
      if overwrite: m.entries[i].value = v
      return false
    i = int(m.entries[i].next)
  var index: int
  if m.freeCount > 0:
    index = int(m.freeList)
    m.freeList = StartOfFreeList - m.entries[index].next
    dec m.freeCount
  else:
    if int(m.count) == m.entries.len:
      m.resize()
      b = m.bucketOf(h)
    index = int(m.count)
    inc m.count
  m.entries[index] = NsEntry[K, V](hashCode: h, next: m.buckets[b] - 1, key: k, value: v)
  m.buckets[b] = int32(index + 1)
  true

proc remove*[K, V](m: var NsHashMap[K, V]; k: K): bool =
  if m.buckets.len == 0: return false
  let h = m.hashOf(k)
  let b = m.bucketOf(h)
  var last = -1
  var i = int(m.buckets[b]) - 1
  while i >= 0:
    if m.entries[i].hashCode == h and m.same(m.entries[i].key, k):
      if last < 0: m.buckets[b] = m.entries[i].next + 1
      else: m.entries[last].next = m.entries[i].next
      m.entries[i] = NsEntry[K, V](next: StartOfFreeList - m.freeList)
      m.freeList = int32(i)
      inc m.freeCount
      return true
    last = i
    i = int(m.entries[i].next)
  false

proc clear*[K, V](m: var NsHashMap[K, V]) =
  if m.count > 0:
    for b in m.buckets.mitems: b = 0
    for i in 0 ..< int(m.count): m.entries[i] = default(NsEntry[K, V])
    m.count = 0
    m.freeList = -1
    m.freeCount = 0

iterator pairs*[K, V](m: NsHashMap[K, V]): (K, V) =
  ## In .NET's enumeration order: the entries array, free slots skipped.
  var i = 0
  while i < int(m.count):
    if m.entries[i].next >= -1: yield (m.entries[i].key, m.entries[i].value)
    inc i

iterator keys*[K, V](m: NsHashMap[K, V]): K =
  for k, _ in m.pairs: yield k

iterator values*[K, V](m: NsHashMap[K, V]): V =
  for _, v in m.pairs: yield v

proc copyOfSet*[K, V](src: NsHashMap[K, V]): NsHashMap[K, V] =
  ## .NET's `HashSet<T>(HashSet<T>)`, which takes the default comparer: the
  ## source's exact layout, free places and all, when the source has the default
  ## comparer too and is not larger than its elements need (`ExpandPrime(Count + 1)`
  ## is smaller than its buckets); else its elements in order, added afresh.
  if src.len == 0: return initNsHashMap[K, V]()
  if src.eq == nil and int(getPrime(2 * (src.len + 1))) >= src.buckets.len: return src
  result = initNsHashMap[K, V](src.len)
  for k, v in src.pairs: discard result.put(k, v, false)
