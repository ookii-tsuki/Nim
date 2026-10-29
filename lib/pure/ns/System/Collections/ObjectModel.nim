# N# standard library: the System.Collections.ObjectModel namespace.
#
# `ReadOnlyCollection<T>`, which `AggregateException.InnerExceptions` returns: a
# view of a list that cannot be changed through it.
#
#   ReadOnlyCollection   Count [i] Contains IndexOf, foreach

from ../../../nsharp/pragmas import nsHidden
from ../../../nsharp/intrinsics import ToString, nsTypeName, Type, nsTypeOf, nsTypeNamed,
  nsGenericType, nsCoreLib, nsItemsText, nsDisplay

type
  ReadOnlyCollection*[T] = ref object of RootObj
    ## `System.Collections.ObjectModel.ReadOnlyCollection<T>`.
    nsItems: seq[T]

proc nsReadOnly*[T](items: seq[T]): ReadOnlyCollection[T] {.nsHidden.} =
  ReadOnlyCollection[T](nsItems: items)

proc Count*[T](c: ReadOnlyCollection[T]): int32 = int32(c.nsItems.len)

proc `[]`*[T](c: ReadOnlyCollection[T]; i: int32): T =
  ## Out of range is `ArgumentOutOfRangeException`, Nim's range defect.
  if i < 0 or i >= int32(c.nsItems.len):
    raise newException(RangeDefect, "Index was out of range. Must be non-negative and " &
                       "less than the size of the collection. (Parameter 'index')")
  c.nsItems[i]

proc Contains*[T](c: ReadOnlyCollection[T]; x: T): bool = x in c.nsItems

proc IndexOf*[T](c: ReadOnlyCollection[T]; x: T): int32 = int32(c.nsItems.find(x))

iterator items*[T](c: ReadOnlyCollection[T]): T {.nsHidden.} =
  for x in c.nsItems: yield x

proc len*[T](c: ReadOnlyCollection[T]): int {.nsHidden.} = c.nsItems.len

method ToString*[T](c: ReadOnlyCollection[T]): string = nsItemsText(c, c.nsItems)
  ## Its elements, `[1, 2]`, as the other collections print (SPEC 7).

proc nsTypeOf*[T](t: typedesc[ReadOnlyCollection[T]]): Type {.nsHidden.} =
  mixin nsTypeOf
  nsGenericType("System.Collections.ObjectModel.ReadOnlyCollection", nsCoreLib, nsTypeOf(T))
