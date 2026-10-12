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

`native/run.sh` times N# programs driven by C++ over the test engine against
the same work written in plain C++.

`hostpages.c` is a host for `-d:nimAllocPagesViaHost`, where Nim's allocator
takes its memory from the program embedding it instead of from the OS:

    NS_BENCH_FLAGS="-d:release -d:nimAllocPagesViaHost --compile:$PWD/hostpages.c" \
      NIM=../../bin/nim1 ./run_bench.sh bintrees
