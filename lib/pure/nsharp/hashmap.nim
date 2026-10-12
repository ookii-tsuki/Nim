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
  ## An integer is its own hash, as in .NET; anything else is Nim's `hash`.
  when K is SomeInteger or K is char or K is bool or K is enum:
    when sizeof(K) == 8:
      let x = cast[uint64](k)
      uint32(x and 0xFFFF_FFFF'u64) xor uint32(x shr 32)
    else:
      uint32(cast[uint64](int64(ord(k))) and 0xFFFF_FFFF'u64)
  else:
    cast[uint32](int32(hash(k) and 0x7FFF_FFFF))

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

proc len*(m: NsHashMap): int {.inline.} = int(m.count - m.freeCount)

proc find[K, V](m: NsHashMap[K, V]; k: K): int {.inline.} =
  ## The entry holding `k`, or -1.
  if m.buckets.len == 0: return -1
  let h = nsKeyHash(k)
  var i = int(m.buckets[m.bucketOf(h)]) - 1
  while i >= 0:
    let e = addr m.entries[i]
    if e.hashCode == h and e.key == k: return i
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
  let h = nsKeyHash(k)
  var b = m.bucketOf(h)
  var i = int(m.buckets[b]) - 1
  while i >= 0:
    if m.entries[i].hashCode == h and m.entries[i].key == k:
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
  let h = nsKeyHash(k)
  let b = m.bucketOf(h)
  var last = -1
  var i = int(m.buckets[b]) - 1
  while i >= 0:
    if m.entries[i].hashCode == h and m.entries[i].key == k:
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
  ## .NET's `HashSet<T>(HashSet<T>)`: the source's exact layout, free places and
  ## all, unless it is larger than its elements need (`ExpandPrime(Count + 1)` is
  ## smaller than its buckets); then its elements in order, compacted.
  if src.len == 0: return initNsHashMap[K, V]()
  if int(getPrime(2 * (src.len + 1))) >= src.buckets.len: return src
  result = initNsHashMap[K, V](src.len)
  for k, v in src.pairs: discard result.put(k, v, false)
