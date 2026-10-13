discard """
  output: '''
7 s@[1.5]3
'''
"""

# A generic object type deriving from a type declared later in the section is
# checked again once the base exists, with its generic parameters in scope.
type
  Gen[T] = ref object of Base[T]
    cur: T
  Two[A, B] = ref object of Plain
    a: A
    b: seq[B]
  Base[T] = ref object of RootObj
    held: T
  Plain = ref object of RootObj
    x: int

let g = Gen[int](cur: 5, held: 2)
let t = Two[string, float](a: "s", b: @[1.5], x: 3)
echo g.cur + g.held, " ", t.a, t.b, t.x
