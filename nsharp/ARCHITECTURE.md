# N# - Compiler Integration Architecture (minimal-diff plan)

> **Goal:** add the N# frontend to the Nim compiler while keeping the diff against
> upstream `nim-lang/Nim` as small and isolated as possible, so upstream fixes can
> be pulled with a trivial rebase.

Companion to [`SPEC.md`](SPEC.md) and [`GLOSSARY.md`](GLOSSARY.md).

---

## 1. What the compiler already gives us (findings)

Investigated before designing the integration:

- **`compiler/syntaxes.nim` is the intended parser seam.** `parseFile` /
  `openParser` receive a `FileIndex`, so the dispatcher can key off the file
  extension itself.
- **`addFileExt` does *not* append an extension if one already exists**
  (`lib/std/private/ospaths2.nim:733`). So `nim c app.ns` already resolves to
  `app.ns` for the *main* module - **`modules.nim` needs no change.**
- **There is no "override a compiler file" hook.** `patchFile` is a nimscript
  stdlib API (`lib/system/nimscript.nim:82`); `-d:nimCustomAst` only swaps the
  AST *type* inside `parser.nim`. So a few core files must be edited - but very
  few.
- **`--nilchecks` / `--refchecks` are deprecated no-ops** (`commands.nim:383`,
  `:889`). We therefore do **not** build the null model on them (see SPEC §7.3).

## 2. Principles

| Principle | Why |
|---|---|
| **All new code in new files** | New files never conflict on `git merge upstream` |
| **Wrap core edits in `when defined(nsharp)`** | With the flag off, the compiler is byte-identical to upstream (zero regression risk, tiny hunks, obvious intent) |
| **Never touch high-churn files** (`astdef`, `ast`, `nodekinds`, `sem*`, `sigmatch`, `cgen`) | N# rides existing `sem`; the frontend emits fully-formed `PNode`s |
| **One call per seam** | Core edits are 1–5 lines that delegate to `compiler/nsharp/` |
| **Desugar inside the frontend** | Avoids a `pipelines.nim` hook entirely |

## 3. Touched files (actual, Phase 0)

| File | Hunk | Status |
|---|---|---|
| `compiler/syntaxes.nim` | `when defined(nsharp):` - `.ns` `parseFile` dispatch to `nsharp/frontend` | ✅ Phase 0 |
| `compiler/pipelines.nim` | guarded branch: one-shot N# module parse → `sem`, then fall through to the shared tail | ✅ Phase 0 |
| `compiler/options.nim` | `NsExt` + `findModule` prefers a `.ns` sibling, then tries `.ns` (imports) | ✅ Phase 1b |
| `compiler/idents.nim` | additive `getIdentExact` (case/underscore-sensitive interning); Nim's `getIdent` and hashing untouched (SPEC §3.1) | ✅ Phase 1a |

**Untouched:** `modules.nim`, `nodekinds.nim`, `ast*.nim`, `sem*`, `sigmatch`,
`cgen`, `msgs`. `koch` / packaging need nothing: the build imports
`compiler/nim.nim` transitively and packaging ships the whole `compiler/` dir.

> **Why `pipelines.nim` and not `openParser`?** The main pipeline streams via
> `openParser` + repeated `parseTopLevelStmt`, which can't be swapped cheaply
> without editing `parser.nim`. Instead we intercept the whole module just before
> that loop, hand `sem` a complete `nkStmtList`, and `break` to the shared tail.
> `parseFile` (used by includes / `reorder` / docgen / nimsuggest) dispatches
> through `syntaxes.nim`.

The `syntaxes.nim` edit:

```nim
# compiler/syntaxes.nim
when defined(nsharp):
  import nsharp / frontend

proc parseFile*(fileIdx: FileIndex; cache: IdentCache; config: ConfigRef): PNode =
  when defined(nsharp):
    if frontend.isNsharpFile(config, fileIdx):
      return frontend.parseModule(fileIdx, cache, config)
  # ... existing Nim code, unchanged ...
```

## 3.1 Phase 0 status - ✅ complete

`nim c -r nsharp/tests/hello.ns` prints `hello from N#`, and ordinary `.nim`
compilation is unaffected. Enable with `-d:nsharp`.

**Toolchain note:** this checkout's `devel` source needs a matching compiler to
bootstrap (system Nim 2.2.4 fails in `icbif.nim`). Build via `csources_v3`:

```
git clone --depth 1 -b master https://github.com/nim-lang/csources_v3.git
git -C csources_v3 checkout eeab3ac46e93f10efda8e58c4db02b9438319d71
make -C csources_v3 -j10                       # -> bin/nim (bootstrap compiler)
bin/nim c --skipUserCfg --skipParentCfg -d:nimKochBootstrap -d:nsharp -o:bin/nim1 compiler/nim.nim
bin/nim1 c --skipUserCfg --skipParentCfg -d:nsharp -o:bin/nim compiler/nim.nim
```

(`dist/checksums` and `dist/nimony` must be present - `koch installdeps` caches them.)

## 4. Directory layout

```
compiler/nsharp/          # ALL compiler-integrated code (new → merge-safe)
  frontend.nim            # entry points the core edits call
  lexer.nim  parser.nim  keywords.nim
  ast.nim  symbols.nim  sema.nim  desugar.nim
  nsgen.nim               # namespaces spanning files (§5.1.1 of SPEC.md)
  tools/dumpast.nim       # parser golden-AST test seam
lib/pure/ns/              # N# namespace root: a file's path is its C# namespace
  System.nim              #   the System namespace
  System/Collections/Generic.nim   #   the System.Collections.Generic namespace
nsharp/                   # language assets (repo root)
  SPEC.md  GLOSSARY.md  ARCHITECTURE.md  tests/    # future: vscode/
```

No `--path` or config edits are needed: `compiler/nsharp/` is reached by the
compiler's normal relative-import resolution, so `config/*.cfg` and
`compiler/nim.cfg` stay untouched.

## 5. Backport workflow

1. Keep `upstream` wired to `nim-lang/Nim` (already configured).
2. Keep N# work on a dedicated branch. The diff = **new dirs + 3 tiny hunks.**
3. **Rebase, don't merge:** `git fetch upstream && git rebase upstream/devel`.
   New files auto-apply; at most 3 small hunks to resolve.
4. Optionally ship as a patch series:
   `git format-patch upstream/devel..nsharp` and re-apply per upstream release.
5. **Upstream the generic seams** when convenient - (a) extension-based parser
   dispatch in `syntaxes.nim`, (b) `IdentCache` case-sensitivity mode. Both are
   small and generally useful; if accepted, the fork diff shrinks to *just*
   `compiler/nsharp/`.
6. Separate CI job + separate test dir (`nsharp/tests`) so upstream test churn
   never conflicts.

## 6. The one risk, stated plainly

`compiler/idents.nim` is the only place we reach into behavior Nim relies on
(case-insensitive identifier identity - SPEC §3.1). The change is **additive**: a
new `getIdentExact` proc used only by the N# frontend, plus an `exact = false`
default parameter on `getIdent`. Nim's `getIdent` and its style-insensitive hash
are unchanged, so Nim behavior is identical when the new path is not taken. The
only subtlety is that N# can create two idents for spellings Nim considers equal;
a cross-language case-only collision is detected and reported. This is the single
hunk to re-check on every upstream rebase.

## 7. Phase 0 acceptance criterion

Phase 0 is done when this compiles and runs:

```csharp
// nsharp/tests/hello.ns
using System;

namespace Hello
{
    class Program
    {
        static void Main(string[] args)
        {
            Console.WriteLine("hello from N#");
        }
    }
}
```

```
$ nim c -r nsharp/tests/hello.ns
hello from N#
```

…with `compiler/nsharp/` containing only a lexer/parser scaffold sufficient for
this program, dispatched by extension, touching no compiler file beyond those
listed in §3.

## 8. Phase 1 status - complete (1a + 1b)

Delivered in 1a: case-sensitive identifiers (`getIdentExact`), the N# prelude
(`lib/pure/ns/prelude.nim`, auto-imported), a precedence-climbing expression
parser, and statements (typed/`var` locals, assignment and compound assignment,
`if`/`else`, `while`, C-style `for` desugared to `while`, `foreach`, `return`,
`break`, `continue`, blocks).

Delivered in 1b: user-defined functions and recursion (methods lower to top-level
procs), and imports (`using X;` / `import X;` map to `import "X"`; `.ns` modules
resolve via a sibling-first rule in `findModule`), plus `public` mapping to an
exported (`*`) symbol and a temporary class-qualifier drop so that
`Class.StaticMethod(args)` and `Console.WriteLine(x)` both become `Method(args)`.

Test suite: `nsharp/tests/run.sh` compiles each `.ns` and diffs stdout against the
matching `.out`. Current tests (6/6): `hello`, `p1a/case`, `p1a/sum`, `p1a/control`,
`p1b/fib`, `p1b/main` (two modules).

Delivered in 2a: real classes. `class C { ... }` becomes `type C = ref object`
with its fields; a constructor `C(params) { ... }` becomes `proc newC(...): C`
(allocating `result`); `new C(args)` calls it; instance methods take a leading
`self: C` parameter; `this` maps to `self` in methods and `result` in
constructors; bare class field names in method bodies rewrite to
`self.field`/`result.field`. Static methods are unchanged. `struct` maps to a Nim
`object` (value type).

Delivered in 2b: properties and inheritance. `R P { get; set; }` (auto),
`{ get { } set { } }` (computed), and `R P => expr` (expression-bodied) become a
backing field (for auto) plus getter/setter procs; the write path uses Nim's
`propertyWriteAccess` and needs no `sem` change. `class D : B` emits
`ref object of B` (classes default to `of RootObj`). Instance members are emitted
in source order, because Nim resolves `self.Prop` (a dot-call to a getter) only
when the getter is already defined.

Delivered in 2c: C# access modifiers. A module-level pre-scan builds a class
table (name, base, member accesses) before any body is parsed; the frontend then
enforces type-scoped access for implicit-`this` and bare member references
(private is not accessible from a derived class, protected is, public/internal
are). Default member access is private, as in C#. `nsharp/tests/run.sh` also
supports expected-compile-failure tests via a `<name>.fail` marker.

Delivered in 2d: constructor initializers. `: base(args)` and `: this(args)` are
parsed; a constructor now emits an initializer `initC(self: C, params)` (which
runs the base initializer, then the body) plus an allocator
`newC(params): C = new(result); initC(result, params)`. The base constructor
therefore runs first, as in C#. A derived class whose base has no accessible
parameterless constructor must name a base constructor, else it is an error
(matching C# CS7036); this is validated using the constructor arities recorded in
the class table.

Test suite (21 total): `hello`, `p1a/*` (3), `p1b/*` (2), `p2a/counter`,
`p2b/auto`, `p2b/shapes`, `p2c/protected`, `p2c/private` (expected failure),
`p2d/nobase` (expected failure), `p3a/data`, `p3a/exceptions`, `p3b/callbacks`,
`p3b/collections`, `p3b/nousing` (expected failure), `p3c/typed`,
`p3c/virtual`, `p3c/interface`, `p3c/fieldinit`.

A `<name>.fail` marker means both N# and C# must reject the program (an access
violation, a missing base constructor). A `<name>.unsupported` marker means the
program is **valid C# that N# deliberately refuses**: `run.sh` requires the N#
compile to fail and `run_cs.sh` requires the C# compiler to accept it, so the
marker cannot be used to hide a broken test. `p3c/virtual`, `p3c/interface` and
`p3c/fieldinit` cover the modifiers and constructs that Stage 3 of the parser
cleanup stopped ignoring silently.

`nsharp/tests/run.sh` is the N# runner; it then runs `nsharp/tests/run_cs.sh`,
the C#<->N# equivalence gate, unless `NS_SKIP_CS=1` is set. Because every `.ns`
test is kept deliberately valid C#, `run_cs.sh` recompiles each one with the
.NET SDK (one temp project, `net10.0`, `--no-incremental` per test) and requires
the C# program's stdout to match the same `<name>.out`. A `.fail` test must be
rejected by C# too. A sibling `.ns` with no `.out`/`.fail` (e.g. `p1b/Math.ns`)
is a module and is compiled together with the program. The gate skips cleanly
when `dotnet` is not on PATH.

`nsharp/tests/run_ast.sh` is the parser golden-AST check (Stage 0a of the parser
cleanup, see PARSER-CLEANUP.md), run by `run.sh` unless `NS_SKIP_AST=1`. It
builds `compiler/nsharp/tools/dumpast.nim`, a standalone tool that drives
`parseNsModule` directly so the compiler tree stays untouched, and diffs its
output against `nsharp/tests/ast/<name>.golden` for all 18 `.ns` files (including
the module-only `p1b/Math.ns` and the expected-failure tests). The dump is
deliberately the *parse output*, not post-`sem`: the lowering fused into the
parser is exactly what the refactor must preserve, and a program's stdout cannot
show that. Regenerate with `run_ast.sh --update`; the output is verified
deterministic (two runs produce identical goldens).

**Frontend layout.** As of Stage 1 of the parser cleanup the frontend is six
single-purpose modules rather than one parse-and-lower script, and
`frontend.nim` is the pipeline (parse, collect declarations, check, lower):

| module | job |
|---|---|
| `compiler/nsharp/ast.nim` | the N# syntax tree (`NsNode`), which mirrors C# syntax |
| `compiler/nsharp/parser.nim` | tokens -> `NsNode`; grammar only, no name mapping |
| `compiler/nsharp/symbols.nim` | `NsNode` -> module scope (declaration collection) |
| `compiler/nsharp/sema.nim` | checks and name resolution over the tree |
| `compiler/nsharp/bcl.nim` | the one C#-to-Nim name and namespace table |
| `compiler/nsharp/desugar.nim` | `NsNode` -> Nim `PNode` (all lowering) |

`dumpast --ns <file>` prints the parser's own output, which is the N# syntax tree
before any C#-to-Nim mapping; the default mode prints the lowered Nim tree that
the golden tests pin.

Delivered in 3a: data and control. `enum` (ordinal Nim enums; qualified access
`E.A` works directly), `switch`/`case`/`default` (desugared to Nim `case`; a
trailing C# `break;` is dropped, and a non-exhaustive switch gets an
`else: discard` whose body must carry an `nkEmpty` child), arrays (`T[]` ->
`seq[T]`, `new T[n]` -> `newSeq[T](n)`, `new T[] { .. }` -> `@[..]`,
`.Length`/`.Count` -> `len`), and exceptions (`throw` -> `raise`,
`try`/`catch`/`finally` -> Nim `try`/`except`/`finally`, `e.Message` -> `msg`).
C# `Exception` maps to Nim `CatchableError`. A class deriving from an exception
base is emitted as a value `object` (so `except` can match it) but its `self`
parameters are `ref T` and its allocator returns `ref T`, because Nim can only
`raise` a ref. `throw new T(args)` calls the user allocator (`raise newT(args)`)
for a declared class, and `raise newException(T, msg)` for a system/prelude
exception. `checked`/`unchecked` remains deferred (the `{.push.}` statement
pragma node shape needs more work than it is worth right now).

The gate is not a formality. It immediately found that C# prints `WriteLine` of a
`bool` as `True`/`False`, while N# printed `true`/`false`. The prelude now has
`bool` overloads of `WriteLine`/`Write` that match .NET, and `p1a/sum.out` was
corrected. Anything that intentionally differs from C# must be written down in
SPEC section 7.3 rather than silently baked into an expected file.

Delivered in 3b: callbacks and collections.

* `delegate R D(params);` becomes a Nim `proc` type with `{.closure.}`, so both
  plain methods and capturing lambdas fit, as C# delegates do. There is no
  `Func`/`Action` yet: those are BCL *generic* types, and Nim cannot overload a
  type name by generic arity (`redefinition of 'Func'`) nor expand a macro in
  type position (`type expected`), so they wait for the generics work in 3d.
* Lambdas (`x => e`, `(a, b) => e`, `(a, b) => { ... }`) parse to `nkLambda` with
  untyped parameters; `annotateLambda` copies the parameter and return types in
  from the declared delegate type, so `IntFn f = x => ...;` types `x`.
* C# generic syntax is lowered onto Nim's generics: `Name<...>` -> `Name[...]` in
  type position, and `new Name<...>(...)` -> `newName[...](...)`. A `>>` token
  from nested generics is split in place into two `>`; `looksLikeDecl` skips a
  balanced `<>` so `Dictionary<string, int> d = ...` reads as a declaration.
* Collections live in `lib/pure/ns/System/Collections/Generic.nim` (surface pinned
  in SPEC section 15.1): `List<T>` = `seq[T]`, `Dictionary<K,V>` = `Table[K,V]`,
  `HashSet<T>` = `HashSet[T]`, and `Queue<T>`/`Stack<T>` wrap `Deque[T]`. The shim
  re-exports `tables`/`sets`, because Nim's `import` is not transitive and users
  need indexing, `in`, `keys`, `values`. `Add`/`Contains`/... are capitalized
  C#-named procs reached through Nim dot-calls; `.Count` lowers to `.len`.
* Every generated proc is `{.discardable.}` (and the collection shims use
  `{.push discardable.}`): C# lets any expression statement drop a method's
  result, while Nim rejects an unused result, so `nums.Remove(1);` needed it.
* The C# BCL is gated by `using`. A namespace name is a module path, so
  `using System;` is `import "System"` and `using System.Collections.Generic;` is
  `import "System/Collections/Generic"`, resolved under `lib/pure/ns/`, the
  namespace root the frontend puts on the search path. There is no rename table.
  Nothing is visible without its `using`; `nsharp/tests/p3b/nousing.ns` pins that,
  and the C# compiler rejects it for the same reason (CS0246).

Still deferred to Phase 3: generics (3d, including `Func`/`Action`), interfaces,
`virtual`/`override` (dynamic dispatch), collection predicates and
`TryGetValue(k, out v)` (SPEC section 15.1), static properties, `unsafe`, C++
`extern`, records, `checked`/`unchecked`, and the integer `/` -> `div`
semantic-trap desugar (needs type info at desugar time). Known 2b gaps: within a
class a member may only reference a property defined earlier (the source-order
rule), and static properties are not yet supported.

---

*Change log*
- **v16** - `using Alias = X.Y;` and qualified names. A namespace alias imports its
  target, since a qualifier is dropped when lowering. `parseType`, `parseNew` and
  `looksLikeDecl` accept `A.B`, `bcl.unqualified` strips the qualifier, and a
  member of a namespace qualifier stays a qualifier in `sema`, so
  `System.Console.WriteLine` and `P.Gadget.Count()` resolve. An alias of a type
  (`using A = List<int>;`) is reported. New `p4d` (alias) and `p4e` (type alias
  rejected) tests; suite now 28 tests, 36 golden ASTs, 28 C# cross-checks.
- **v15** - Namespaces. A C# namespace spans files, which Nim cannot express, so
  each used namespace is emitted as `<P>_decl` / `<P>_impl` / `<P>` (barrel) under
  `<nimcache>/.nsgen` (`compiler/nsharp/nsgen.nim`). A namespace name is a module
  path, so `namespace A.B` is the path `A/B`, nested blocks compose, and
  `using X.Y;` is `import "X/Y"` with no namespace table anywhere. The N# library
  is the namespace root `lib/pure/ns/`, which the frontend puts on the search
  path: `System` is `System.nim`, `System.Collections.Generic` is
  `System/Collections/Generic.nim`. New `p4a` (namespace spanning files) and `p4c`
  (dotted + nested, also merged across files) tests, both C# cross-checked; suite
  now 26 tests, 33 golden ASTs, 26 C# cross-checks.
- **v14** - Stages 2 and 3 of the parser cleanup. Stage 2: `sema.nim` attaches
  coarse type information and lowering uses it, so `.Length`/`.Count`/`.Message`
  renaming is type-directed and integer `/` is `div` (the old name-only rule
  rewrote a user property called `Length` and broke legal C#). Stage 3: no more
  silent semantics (unimplemented modifiers, `interface`, static properties and
  field initialisers are reported), `looksLikeDecl` applies the real C#
  declaration rule, `>>` splitting moved into the lexer, and a parser progress
  guard was added. New `.unsupported` test marker and `p3c/*` tests; suite now
  21 tests, 22 golden ASTs, 21 C# cross-checks.
- **v13** - Stage 1 of the parser cleanup: the frontend is now `ast.nim` +
  `parser.nim` (grammar only) + `symbols.nim` + `sema.nim` + `bcl.nim` +
  `desugar.nim`, with `frontend.nim` as the pipeline. `prescanClasses`/the
  token-level member scanner are gone; declarations are collected from the tree;
  access control and the base-constructor rule moved into `sema`. All 18 golden
  trees are byte-identical and the whole suite is green. See PARSER-CLEANUP.md.
- **v12** - Stage 0a of the parser cleanup: added `nsharp/tests/run_ast.sh` and
  `compiler/nsharp/tools/dumpast.nim`, a golden-AST net over the parse output of
  all 18 `.ns` files, wired into `run.sh` (`NS_SKIP_AST=1` to skip). The plan
  lives in `nsharp/PARSER-CLEANUP.md`. No compiler source changed.
- **v11** - Phase 3b: `delegate` types (`{.closure.}` proc types), lambdas with
  delegate-typed parameters, C# generic syntax (`Name<...>` -> `Name[...]`) and
  the collection shim `ns/collections.nim`. The C# BCL is now gated by `using`
  instead of being implicitly imported (`ns/system.nim` + `ns/collections.nim`,
  driven by a namespace table in `parseUsing`), and generated procs are
  `{.discardable.}`.
- **v10** - added `nsharp/tests/run_cs.sh`, the permanent C#<->N# equivalence
  gate, wired into `run.sh` (opt out with `NS_SKIP_CS=1`). It caught the
  `WriteLine(bool)` formatting difference, now fixed in the prelude.
- **v9** - Phase 3a output cross-checked against the .NET 10 SDK (`dotnet run`);
  added the `p3a/exceptions` test plus the value-object/`ref`-raise exception
  class model.
- **v8** - recorded Phase 3a: enums, switch/case, arrays (seq mapping), and
  exceptions; C# `Exception` -> Nim `CatchableError`.
- **v7** - recorded Phase 2d: constructor initializers (`: base(...)` /
  `: this(...)`), the allocator/initializer split so base constructors run
  first, and the CS7036-style validation (verified against the .NET compiler).
- **v6** - recorded Phase 2c: C# access modifiers (class-table pre-scan,
  type-scoped enforcement for implicit-this and bare member references,
  default private), and expected-failure test support.
- **v5** - recorded Phase 2b: properties (auto/computed/expression-bodied) and
  basic inheritance; the source-order emission rule.
- **v4** - recorded Phase 2a: real classes (type + fields, constructors, `new`,
  instance methods with `self`, `this`, field qualification).
- **v3** - recorded Phase 1b: functions/recursion and imports; `options.nim`
  `.ns` resolution; updated the touched-file table and the Phase 1 status.
- **v2** - recorded Phase 1a: `getIdentExact` case sensitivity, prelude, and the
  expression/statement core; updated the touched-file table and the risk note.
- **v1** - initial integration architecture: seam findings, the 3-file plan,
  directory layout, rebase/backport workflow, and the Phase 0 acceptance test.
