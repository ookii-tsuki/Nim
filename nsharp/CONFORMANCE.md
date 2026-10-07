# N# semantic conformance (Stage 0b)

The parser golden-AST check (`run_ast.sh`) pins the *shape* of a parse. This gate
pins its *meaning*: the semantic facts the N# frontend resolves must equal the
facts Roslyn resolves for the same file.

It exists because the frontend resolves names through the prelude
(`lib/pure/ns/`) rather than through a hardcoded table, and the only honest way to
know that resolution matches C# is to ask C#. A change that resolves `List.Add`
to the wrong namespace, or a member to the wrong type, fails here instead of being
noticed only by reading a diff.

## The two halves

| half | what it is | what it prints |
|------|-----------|----------------|
| `compiler/nsharp/tools/dumpsema.nim` | the frontend's own resolution | the projected facts N# resolved |
| `tools/nsoracle` (Roslyn) | the truth to measure against | the same facts, from C# |

Both read the *same* `.ns` file: every `.ns` test is deliberately valid C#, which
`run_cs.sh` already relies on. `tools/nsoracle/Program.cs` compiles it with
Roslyn and reads the facts back from the semantic model; its references are the
assemblies the SDK itself trusts, so no NuGet feed and no machine-specific path
is needed.

`nsharp/tests/run_sema.sh` runs both over every test that has a `.out` and diffs
the two.

## The projection

Two kinds of line, each block sorted, so the output is independent of walk order:

```
using <ns>                        // each `using` directive, `using A = X.Y` for an alias
member <recv>.<name> = <ns> | <ret>
```

A **`member`** line is one *instance* member access `x.M` on a receiver of a
library (non-source) type. It records the namespace the declaring type lives in
and the result class. That namespace is the fact that tells resolution *through
the library* from a name baked into the compiler.

* **receiver** (`<recv>`) is spelled the way the frontend spells it: the C#
  keyword of a built-in (`int`, `long`, `string`, `object`, ...), `array` for an
  array, otherwise the type's short name (`List`, `Dictionary`, `Console`).
* **namespace** (`<ns>`) is the fully qualified namespace of the declaring type
  (`System`, `System.Collections.Generic`).
* **result** (`<ret>`) is one of the shared tokens: `void`, `int`, `float`,
  `bool`, `char`, `string`. The numeric axis is deliberately coarse (every
  integer is `int`) but the axis that matters -- value vs. string vs. sequence vs.
  object -- is exact.

### What is deliberately out of scope

The projection is exact for a small surface rather than approximate for a large
one. Not projected, so that the two halves can agree exactly:

* **static accesses** (`Console.WriteLine`, `String.Concat`, `Array.IndexOf`,
  `int.MaxValue`). A type-qualified call names no library member through the
  prelude -- the prelude writes `Console`'s methods as module-level procs whose
  first parameter is the *argument*, not the class -- so N# cannot place them yet.
  Roslyn reads them as statics, so both sides skip them.
* **members of the program's own types**. That is the program's own business.
* **`T?` receivers**. The frontend lowers `T?` to an `Option` whose members live
  in the intrinsics, which is no C# namespace to agree on.
* **results that need a richer vocabulary** than the six tokens (a collection, an
  exception, an array): they are `other` and are not projected.
* **members whose result is one of the declaration's own type parameters**
  (`Queue<T>.Dequeue` returns `T`). The declaration alone does not name the class
  -- and the receiver's class is what the token would be -- so neither side emits
  it even though Roslyn has substituted the argument.

## Running it

```sh
./nsharp/tests/run_sema.sh            # verify against the committed goldens
./nsharp/tests/run_sema.sh --update   # (re)generate the goldens from Roslyn
NIM1=/path/to/nim1 ./nsharp/tests/run_sema.sh
```

The golden under `nsharp/tests/sema/<name>.golden` is the **Roslyn** output.
Verification compares the oracle half against it too, so a golden also records the
BCL it was measured against and `run_sema.sh` reports `ORACLE DRIFT` if Roslyn
stops reproducing it (regenerate with `--update`). It is wired into `run.sh`
(`NS_SKIP_SEMA=1` to skip) and skips cleanly when `dotnet` is absent -- the N#
half is then still checked against the committed goldens.

## What it has already caught

Turning the gate on over the existing suite found four real frontend defects,
each fixed rather than papered over:

1. **Grouped parameters were indexed wrongly.** `loadMembers` read a proc's
   receiver from the second *name* of a grouped parameter instead of its *type*
   (`s, value: string` filed `Contains` under `value`). The declaration's type is
   at `[^2]`; fixed in `compiler/nsharp/bcl.nim`.
2. **`RootRef` was unclassified.** A member declared over Nim's `ref object` root
   (`Equals`, `GetHashCode`) filed under `RootRef` but was looked up under the
   class key `#class`. `RootRef`/`RootObj` are now classified as classes in
   `NsNimKinds`.
3. **`HashSet<T>.Add` returned the wrong type.** The prelude declared it `void`;
   .NET returns `bool`. Fixed in `lib/pure/ns/System/Collections/Generic.nim`.
4. **An inferred `var` lost its type name.** `var x = ...` recorded the *local's*
   (empty) name instead of the initialiser's, so `x.Count` on a `List` read as an
   array. `walkDecl` now takes the name from the initialiser, as `walkForeach`
   already did, and `walkCall` records the result type name.

## Growing it

The projection is meant to widen one exact step at a time. The next steps, in
rough order of value:

* **static members.** Have the surface index a prelude module's own procs under
  the type the C# namespace maps to (`Console`), so `Console.WriteLine = System |
  void` projects and the oracle covers the most common call in the suite.
* **a richer result vocabulary.** Add tokens for a sequence/array/exception so
  `Dequeue`/`Pop` and collection-returning members project once the frontend can
  name their element.
* **`T?` members.** Project the `Nullable<T>` members once the prelude names them
  in a namespace the oracle can agree with.

