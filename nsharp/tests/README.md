# N# tests

Every `.ns` program is valid C# (or, under `diag/cases`, deliberately invalid C#),
so the same file is checked by N# and by the .NET compiler. A test lives in the
directory of the feature it exercises, named for what it checks:

| directory | what is there |
|---|---|
| `arith`, `arrays`, `classes`, `controlflow`, `conversions`, `delegates`, `enums`, `events`, `exceptions`, `generics`, `interfaces`, `iterators`, `lambdas`, `methods`, `namespaces`, `nullable`, `operators`, `patterns`, `properties`, `records`, `reflection`, `strings`, `structs`, `syntax`, `types`, `attributes` | the language, one directory per feature |
| `collections`, `linq`, `stdlib` | the library (`lib/pure/ns`): `System.Collections.Generic`, `System.Linq`, and the rest of `System` |
| `modules/<program>/` | a program of several files: `main.ns` and the modules beside it |
| `unsupported` | valid C# that N# rejects for now (`.unsupported`, NS9999) |
| `diag/cases` | invalid C#: N# must report Roslyn's error code (`run_diag.sh`) |
| `native` | N# driven from C++ (`run_native.sh`) |
| `ast`, `sema` | generated goldens, mirroring the paths above |

Beside `<name>.ns`: `.out` (expected stdout), `.csout` (C#'s stdout where it
differs only by a documented spelling), `.warn` / `.exit` / `.unsupported` markers;
see `run.sh`. In a feature directory every program has a marker, so programs never
share a directory with modules of another program.
