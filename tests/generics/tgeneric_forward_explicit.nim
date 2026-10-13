discard """
  output: '''
5
10
'''
"""

# A forward declared generic routine instantiated before its body exists is
# checked once the body is seen, with its generic parameters bound, so the body
# can instantiate another one explicitly.
proc size[T](): int
proc init[T](): int
proc main() =
  echo size[int]()
  echo size[float]() + init[string]()

proc size[T](): int =
  discard init[T]()
  5

proc init[T](): int = (when T is string: 5 else: 0)

main()
