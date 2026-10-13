discard """
  output: '''
4
50
'''
"""

# A generic method instantiated while only its forward declaration exists
# gets its result symbol, and so does its dispatcher, once the body is seen.
type
  Bag[T] = ref object of RootObj
    items: seq[T]
  Scaled[T] = ref object of Bag[T]

method first[T](b: Bag[T]): T {.base.}
method first[T](b: Scaled[T]): T

proc firstOf(b: Bag[int]): int = b.first

method first[T](b: Bag[T]): T {.base.} = b.items[0]
method first[T](b: Scaled[T]): T = b.items[0] * 10

echo firstOf(Bag[int](items: @[4, 5]))
echo firstOf(Scaled[int](items: @[5]))
