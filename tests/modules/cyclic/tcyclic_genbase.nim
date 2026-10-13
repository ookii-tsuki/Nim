discard """
  joinable: false
  output: "1 x"
"""

# the generic type's module is the root of the group:
import mcyclic_genbase_b, mcyclic_genbase_a

echo describe(Gen[string](x: 1, cur: "x"))
