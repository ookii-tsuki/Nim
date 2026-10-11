# N# benchmarks

Each `.ns` here is valid C# that prints a checksum. `run_bench.sh` builds it with
N# (`nim c -d:release`) and with the .NET SDK (`dotnet -c Release`), checks that
both print the same thing, and reports the best of three wall-clock times.

    NIM=../../bin/nim1 ./run_bench.sh            # all
    NIM=../../bin/nim1 ./run_bench.sh nbody      # one

| bench | exercises |
|---|---|
| `nbody` | field access on class references, floating point |
| `bintrees` | allocation, recursion, constructor arguments |
| `fannkuch` | integer arrays, tight loops |
| `spectral` | double arrays passed to methods |
| `dict` | `Dictionary<int, int>` and `Dictionary<string, int>` |
| `shapes` | interface and virtual calls |
| `strings` | interpolation, `Join`, `Split`, concatenation |
