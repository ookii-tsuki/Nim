discard """
  matrix: "--experimental:vtables"
  output: '''
...
woof
'''
"""

# A subtype declared before its base in the type section stays in the
# hierarchy the vtables are built from.
type
  Dog = ref object of Animal
  Animal = ref object of RootObj

method speak(a: Animal): string {.base.} = "..."
method speak(d: Dog): string = "woof"

let xs: seq[Animal] = @[Animal(), Dog()]
for x in xs: echo x.speak
