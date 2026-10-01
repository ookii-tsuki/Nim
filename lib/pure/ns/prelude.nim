#
#           N# prelude
#
# `lib/pure/ns/` is the home of the N# standard library ("N# BCL-lite", SPEC
# section 15). These modules are NOT auto-imported: the C# BCL surface is gated
# by `using` directives, which the frontend maps onto them (see parseUsing in
# compiler/nsharp/parser.nim). So `Console` needs `using System;`, and `List<T>`
# needs `using System.Collections.Generic;`, exactly as in C#.
#
#   ns/system.nim      ->  System                       (Console, exceptions)
#   ns/collections.nim ->  System.Collections.Generic   (List, Dictionary, ...)
#
# This module is the umbrella over the whole surface, for tooling and tests.

import ns/system
import ns/collections

export system
export collections

