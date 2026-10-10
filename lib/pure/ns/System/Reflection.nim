# N# standard library: the System.Reflection namespace.
#
# Only what `System.Type` inherits from `MemberInfo`: its `Name`. A member is
# reached without the `using`, as in C#, because lowering imports the declaration
# it resolved by name.

import std/strutils
import ../../nsharp/intrinsics

proc Name*(t: Type): string =
  ## The name without namespace or enclosing types: `Outer+Inner` is `Inner`.
  result = t.FullName
  let i = max(result.rfind('.'), result.rfind('+'))
  if i >= 0: result = result[i + 1 .. ^1]
