discard """
  output: '''
x
nil
'''
"""

# A generic converter is not a candidate for an argument that binds none of its
# generic parameters (`nil` into `Box[T]`): the overload that would need it
# simply does not match, rather than failing with "cannot instantiate: 'T'".
type
  IBox[T] = object
    obj: RootRef
  Box[T] = ref object of RootObj
    v: T

converter toIBox[T](x: Box[T]): IBox[T] = IBox[T](obj: x)
proc `==`[I: object](a: I; b: typeof(nil)): bool = a.obj == nil
proc get[T](self: Box[T]): T = self.v

let a = Box[string](v: "x")
echo (if a == nil: "nil" else: a.get())
let b: Box[string] = nil
echo (if b == nil: "nil" else: b.get())
