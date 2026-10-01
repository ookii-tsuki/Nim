#
#           N# prelude (Phase 1a)
#
# Auto-imported into every `.ns` module by the frontend as `import ns/prelude`.
# This is where the C#-facing surface is mapped onto Nim stdlib. Phase 1a covers
# Console output; collections and string helpers come later.

import std/[syncio]

type
  ArgumentException* = object of CatchableError
  InvalidOperationException* = object of CatchableError
  NullReferenceException* = object of CatchableError

proc WriteLine*[T](x: T) = echo x
proc Write*[T](x: T) = stdout.write x
proc ReadLine*(): string = stdin.readLine
