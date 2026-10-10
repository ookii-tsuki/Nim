# N# standard library: the System.Collections namespace.
#
# Imported by `using System.Collections;`, and by `System.Collections.Generic`,
# whose enumerator builds on the one type here. The non-generic collections and
# interfaces (`ArrayList`, `IEnumerable`) are not declared yet.

import ../System

type
  NsEnumerator* = ref object of RootObj
    ## The non-generic half of every enumerator -- .NET's `System.Collections
    ## .IEnumerator`, which declares `MoveNext` -- since stepping does not depend on
    ## the element type. `IEnumerator<T>` derives from it.
    nsStep*: proc (): bool

proc MoveNext*(e: NsEnumerator): bool = e.nsStep()
