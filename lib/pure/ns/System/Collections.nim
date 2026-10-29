# N# standard library: the System.Collections namespace.
#
# Imported by `using System.Collections;`, and by `System.Collections.Generic`,
# whose enumerator builds on the one type here, and by `System`, whose exceptions'
# `Data` is the non-generic `IDictionary` here. The other non-generic collections
# and interfaces (`ArrayList`, `IEnumerable`) are not declared yet.
#
#   IDictionary   [k] [k]= Add Contains Remove Clear Count, foreach as DictionaryEntry
#   DictionaryEntry  Key Value

from ../../nsharp/pragmas import nsHidden
from ../../nsharp/intrinsics import Equals, ToString, nsTypeName, Type, nsTypeNamed, nsTypeOf,
  nsBox, nsGuarded, nsFieldValue

type
  NsEnumerator* = ref object of RootObj
    ## The non-generic half of every enumerator -- .NET's `System.Collections
    ## .IEnumerator`, which declares `MoveNext` -- since stepping does not depend on
    ## the element type. `IEnumerator<T>` derives from it.
    nsStep* {.nsHidden.}: proc (): bool

proc MoveNext*(e: NsEnumerator): bool {.discardable.} = e.nsStep()
  ## C# lets a call statement drop the result.

# --- System.Collections.IDictionary ----------------------------------------------
#
# The non-generic dictionary `Exception.Data` is: object keys and values, compared
# as `Equals` compares them, in the order they were added (.NET's
# `ListDictionaryInternal`, a short list, is what `Data` holds). Declared with its
# arity, as `Action0` is, so `IDictionary<K, V>` keeps the plain name.

type
  DictionaryEntry* = object
    ## `System.Collections.DictionaryEntry`: one entry, as `foreach` over a
    ## non-generic dictionary sees it.
    Key*: RootRef
    Value*: RootRef
  IDictionary0* = ref object of RootObj
    ## `System.Collections.IDictionary`.
    nsKeys: seq[RootRef]
    nsValues: seq[RootRef]

var nsDuplicateKey* {.nsHidden.}: proc (key: string) {.nimcall.}
  ## Throws `Add`'s `ArgumentException`, which `System` declares and sets this to.

proc newIDictionary0*(): IDictionary0 {.nsHidden.} = IDictionary0()

proc nsFind(d: IDictionary0; key: RootRef): int =
  for i, k in d.nsKeys:
    if Equals(k, key): return i
  -1

# Keys and values are `object`s: each member takes any value and boxes it, as a C#
# `object` parameter does.

proc `[]`*[K](d: IDictionary0; key: K): RootRef =
  ## The value, or null for a key it does not hold.
  let i = d.nsFind(nsBox(key))
  if i >= 0: d.nsValues[i] else: nil

proc `[]=`*[K, V](d: IDictionary0; key: K; value: V) =
  let k = nsBox(key)
  let i = d.nsFind(k)
  if i >= 0: d.nsValues[i] = nsBox(value)
  else:
    d.nsKeys.add k
    d.nsValues.add nsBox(value)

proc Add*[K, V](d: IDictionary0; key: K; value: V) =
  let k = nsBox(key)
  if d.nsFind(k) >= 0 and nsDuplicateKey != nil: nsDuplicateKey(k.ToString())
  d.nsKeys.add k
  d.nsValues.add nsBox(value)

proc Contains*[K](d: IDictionary0; key: K): bool = d.nsFind(nsBox(key)) >= 0

proc Remove*[K](d: IDictionary0; key: K) =
  let i = d.nsFind(nsBox(key))
  if i >= 0:
    d.nsKeys.delete i
    d.nsValues.delete i

proc Clear*(d: IDictionary0) =
  d.nsKeys.setLen 0
  d.nsValues.setLen 0

proc Count*(d: IDictionary0): int32 = int32(d.nsKeys.len)

iterator items*(d: IDictionary0): DictionaryEntry {.nsHidden.} =
  for i in 0 ..< d.nsKeys.len: yield DictionaryEntry(Key: d.nsKeys[i], Value: d.nsValues[i])

method ToString*(d: IDictionary0): string = "System.Collections.ListDictionaryInternal"
method nsTypeName*(d: IDictionary0): string {.nsHidden.} = "System.Collections.ListDictionaryInternal"
proc nsTypeOf*(t: typedesc[IDictionary0]): Type {.nsHidden.} =
  nsTypeNamed("System.Collections.IDictionary")
proc nsTypeOf*(t: typedesc[DictionaryEntry]): Type {.nsHidden.} =
  nsTypeNamed("System.Collections.DictionaryEntry")
