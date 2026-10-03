# N# intrinsics
#
# Imported into every compiled module, because C# needs no `using` for these:
# `"a" + b` concatenates anywhere, and any type can be printed.
#
# `$` is the one stringifier, and an object renders the way Nim renders a value of
# its type, so a class reads as its fields. A primitive keeps Nim's own rendering,
# which is why a bool reads `true` here and `True` in C#.

proc `$`*[T: ref object](x: T): string = $x[]
proc ToString*[T: ref object](x: T): string = $x[]

proc `+`*(a, b: string): string = a & b
proc `+`*[T](a: string, b: T): string = a & $b
proc `+`*[T](a: T, b: string): string = $a & b
