import mcyclic_genbase_b {.cyclic.}

type
  Base* = ref object of RootObj
    x*: int

proc describe*[T](g: Gen[T]): string = $g.x & " " & $g.cur
