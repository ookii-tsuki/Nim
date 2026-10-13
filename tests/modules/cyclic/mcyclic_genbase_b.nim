import mcyclic_genbase_a {.cyclic.}

type
  Gen*[T] = ref object of Base
    ## derives from a type of the other module, which this module's type
    ## pass sees only as a forward declaration when it is the group's root
    cur*: T
