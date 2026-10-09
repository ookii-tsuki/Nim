# N# parser cleanup plan

Owner-facing plan for turning `compiler/nsharp/parser.nim` from a
parse-and-lower-in-one-pass script into a conventional frontend. Written after
reading all 1642 lines and comparing with `compiler/parser.nim`.

## 1. Where it diverges from standard compiler design

1. **No AST of its own, so parsing and lowering are fused.** The parse output is
   Nim's `PNode`, and C# semantics are baked in while parsing. Nim's own parser
   emits a faithful Nim AST; `sem` resolves names and `transf` lowers. Here there
   is no seam where a semantic decision could live, so every semantic rule became
   a name rewrite at parse time. Some lowering even re-parses its own output:
   `throw` recovers the type name with `e[0].ident.s[3 .. ^1]`, slicing back off
   the `"new"` prefix `parseNew` had just added.
2. **No symbol table and no resolver, so identity is by string.** `thisName`,
   `curClass`, `classes: TableRef[string, ...]`, `delegates`, and entry-point
   detection via `ident.s == "Main"`. This is the root cause of the hardcoding:
   with no resolver, `Class.Method()` versus `obj.Method()` can only be guessed,
   and the current guess is ASCII case (`ident.s[0] in {'A'..'Z'}`).
3. **Two parsers for one grammar.** `prescanClasses`/`prescanClass` re-implement
   a member scanner at token level (`skipParens`, `skipBraces`, `countParenArgs`)
   to build the class table before the real parse, because derived bodies need
   base members. The class grammar therefore exists twice and must not drift.
4. **Heuristic disambiguation where a grammar belongs.** `looksLikeDecl` guesses
   declaration-versus-expression from token shapes with a `k < 200` bound;
   `expectGt`/`atGtClose` handle `>>` by writing into the token array;
   `looksLikeLambda` scans up to 500 tokens.
5. **Silent semantics loss.** `NsModifierWords` accepts `virtual`, `override`,
   `readonly`, `const`, `unsafe`, `extern`, `new` and then ignores them, so
   `public override string ToString()` compiles with no override. `interface` is
   parsed and dropped, extra bases are `discard`ed, field initializers are parsed
   and thrown away, static properties vanish, and `parseParams` invents the name
   `"arg"`. 141 `discard p.advance` sites plus `skipToSemi`/`skipItem`/
   `skipParens`/`skipBraces` delete unknown constructs without a diagnostic.
6. **Name mapping is scattered and unconditional.** `builtinTypeName`,
   `isExceptionBase`, the `using` table, and in `parsePostfix` the rule
   `.Length`/`.Count` -> `len` and `.Message` -> `msg` applied to *any* receiver,
   so a user class with `public int Length` is silently rewritten and fails.
   Correct behaviour needs the receiver's type. The same missing seam is why the
   integer `/` -> `div` rule is still unimplemented.
7. **No error recovery and no progress guarantee.** `p.err` is `localError` plus
   continue; parsers return `nil` (22 sites) and callers test for it; `advance`
   clamps at EOF with no analogue of Nim's `p.hasProgress`.

## 2. Debt list

- Context as mutable parser globals (`thisName`, `classFields`, `curClass`,
  `tmp`) with manual save/restore in `parseBodyWith`.
- `emitProperty` defines a nested `mkProc` duplicating the top-level `mkProcDef`.
- Ad-hoc IR (`NsMember`, `NsClassInfo`) exists for classes only.
- `guard < 64` in `chainMemberNames`/`findMember` hides base-class cycles.
- The "members must be defined in source order" rule is a lowering artefact
  leaking into user-visible semantics.
- No parser-level tests (only end-to-end stdout), now partly addressed by
  Stage 0a.
- Stale file header ("Phase 0 scaffold", "skipped tolerantly").

## 3. Target layout

```
nsharp/
  lexer.nim      tokens only; owns `>>` splitting as an API, no in-place mutation
  ast.nim        the N# AST: node kinds, ctors, repr (the parser's output)
  parser.nim     tokens -> ast. Pure grammar. No name mapping, no lowering,
                 no access checks
  symbols.nim    scope tree, Symbol, one-pass declaration collection
  sema.nim       resolution of `Class.Member`, `expr.Member`, bare ids, `this`,
                 access control, and declared types for locals/params/fields
  bcl.nim        the ONE mapping table: C# name/namespace -> Nim name/module,
                 primitive widths
  desugar.nim    ast -> Nim PNode (new, switch, throw, classes, properties,
                 ctors, lambdas)
  frontend.nim   unchanged public entry
```

## 4. Stages

**Stage 0a - golden-AST net. DONE.**
`nsharp/tests/run_ast.sh` plus `compiler/nsharp/tools/dumpast.nim`. The tool
drives `parseNsModule` directly (no compiler change) and diffs against 18 goldens
under `nsharp/tests/ast/`. Wired into `run.sh` (`NS_SKIP_AST=1` to skip). Output
verified deterministic. Acceptance met: net green, no compiler source touched.

**Stage 0b - Roslyn syntax probe (kept for later).**
The SDK ships Roslyn at `$(MSBuildSDKsPath)/../Roslyn/bincore/`
(`Microsoft.CodeAnalysis.CSharp.dll`), so it is referenceable offline with no
NuGet. Use it first as a *specification* tool: a C# console app that parses a
file and prints a canonicalized tree (kind plus identifier/literal, trivia,
spans and punctuation dropped). That answers formally the questions stages 1-3
currently guess at (`looksLikeDecl`, `>>`, static dispatch, modifier legality)
and lets us assert `GetDiagnostics()` is empty across the suite. Later, in
stage 2/3, promote it to a conformance gate comparing our AST with Roslyn's. It
is not a substitute for stage 0a: Roslyn describes C# syntax, while 0a must pin
today's *lowered* output.

**Stage 1 - split by responsibility, behaviour preserving. DONE.**
The single 1642-line `parser.nim` became six single-purpose modules:

| module | lines | job |
|---|---|---|
| `ast.nim` | 220 | the N# syntax tree (`NsNode`), mirroring C# syntax |
| `parser.nim` | 949 | tokens -> `NsNode`; grammar only |
| `symbols.nim` | 105 | `NsNode` -> module scope; declaration collection |
| `sema.nim` | 111 | checks + name resolution over the tree |
| `bcl.nim` | 73 | the one C#-to-Nim name/namespace table |
| `desugar.nim` | 705 | `NsNode` -> Nim `PNode` (all lowering) |

`frontend.nim` is now the pipeline (parse, collect, check, lower).

What this bought, concretely:

* **The parser contains no C#-to-Nim knowledge.** Grepping `parser.nim` for
  `int32`, `len`, `msg`, `ns/system`, `CatchableError`, `RootObj`, `discardable`,
  `newSeq`, `nkProcDef` or `nkTypeSection` returns nothing. The parse output holds
  C# syntax as written (`nsnTypeName int`, `nsnUsing System`, `Length`), so there
  is finally a seam for Stage 2 to resolve against.
* **`prescanClasses` is gone.** The token-level member scanner (`prescanClass`,
  `skipParens`, `skipBraces`, `countParenArgs`) and the duplicated class grammar
  are deleted; declarations are collected from the parsed tree, and the class
  cycle guard is a visited set (`symbols.chain`) instead of `guard < 64`.
* **Access control and the base-constructor rule** moved from parse-time string
  checks to `sema.nim`, walking the tree, with real `TLineInfo` diagnostics.
* **`builtinTypeName`/`isExceptionBase`/the `using` table** collapsed into
  `bcl.nim`; there is one place to read the C#-to-Nim mapping.
* Tolerant skip sites dropped from 141 to 104.

Acceptance met: identical `.out` for all 17 tests, **byte-identical golden trees**
for all 18 `.ns` files, and the C# cross-check still passes.

Debt deliberately carried into later stages (all listed, none silent):

* `bcl.NsMemberRenames` is applied without the receiver's type, so a user property
  named `Length` is still rewritten to `len`. Stage 2 makes this type-directed.
* `desugar.callToNim` still uses the upper-case-receiver heuristic to drop a class
  qualifier. Stage 2 replaces it with resolution.
* `parser.nim` keeps `looksLikeDecl`, the `expectGt` token mutation and the 104
  skip sites. Stage 3.
* **Fidelity bug, not design:** methods get no `discardable` pragma while the
  generated `init`/`new` procs do, because that is what the old emitter did. It is
  confined to `desugar.procPragmas` so it can be fixed in one line later.

**Stage 2 - type-directed lowering. DONE.**
`sema.nim` now resolves names *and* attaches coarse type information
(`ast.NsTypeKind`) to expressions, and `desugar.nim` consults it. Concretely:

* `.Length`/`.Count` -> `len` and `.Message` -> `msg` happen only when the
  receiver's resolved type is an array, string, collection or exception. The
  previous rule applied them to every member access, so a user property named
  `Length` was rewritten to `len` and failed to compile. That is the bug this
  stage fixes, and `nsharp/tests/p3c/typed.ns` pins it: `xs.Length` is `len`
  while `t.Length` on a user class stays `Length`. The C# compiler agrees.
* Integer `/` -> `div` when both operands are integers, per SPEC section 7.3
  (Nim's `/` is floating point). Same test covers `7 / 2` -> `3` and
  `7.0 / 2` -> `3.5`.
* Dropping the qualifier in `Class.Method(...)`/`Console.WriteLine(...)` is now
  driven by the receiver resolving to `tkType` rather than by its capitalisation.
* A user class deriving (directly or transitively) from an exception base is
  classified as an exception type, so `.Message` works on it.

What is genuinely type-driven versus still conventional, stated plainly:

* Type classification is a **table lookup** (`bcl.NsIntTypeNames`,
  `NsSequenceTypeNames`, the `using`-gated namespace table) plus the module
  scope, not a guess. `List` is a sequence because `bcl.nim` says so.
* Telling a *value* from a *type* in `Console.WriteLine` versus `c.Value()`
  still relies on the capitalisation convention for names that are not in the
  local scope or the class table (for example a class defined in another `.ns`
  module, which needs a real module system to resolve). When the kind is
  unknown, lowering stays conservative and keeps the name the user wrote rather
  than renaming it.

Acceptance met: all 18 pre-existing golden trees byte-identical, the new test's
output matches the C# compiler, and the whole suite is green.

**Stage 3 - grammar and diagnostics hygiene.**

**Stage 3 - grammar and diagnostics hygiene. DONE.**

* **No more silent semantics.** `parseModifierList` reports any modifier N#
  recognises but does not implement (`virtual`, `override`, `readonly`,
  `unsafe`, `extern`, ...) instead of accepting and ignoring it, and
  `sema.checkSupported` rejects `interface`, static properties and field
  initialisers. Previously all of these compiled into something that looked
  right and behaved differently, which is worse than refusing to compile.
* **New `.unsupported` test category.** A `.unsupported` marker means "valid C#
  that N# deliberately rejects". `run.sh` requires the compile to fail, and
  `run_cs.sh` requires the C# compiler to *accept* it, so the marker cannot be
  used to hide a broken test. `p3c/virtual`, `p3c/interface` and
  `p3c/fieldinit` use it.
* **`looksLikeDecl` is a real rule.** It now recognises the shape of a type (a
  name, an optional generic argument list, any number of `[]` suffixes) and then
  requires an identifier followed by a declarator token, which is how C# tells a
  local declaration from an expression statement. The `k < 200` bound and the
  `k = 3` special case are gone; `skipBalancedGt` terminates on EOF instead of a
  magic constant.
* **`>>` splitting moved to the lexer** (`lexer.splitShr`, plus
  `lexer.atGtClose`), so all token surgery lives in one module.
* **Progress guard** in the module loop: a grammar bug now reports instead of
  spinning, and a token is always consumed.
* Remaining skips are error recovery only (`recoverToSemi`, the two recovery
  loops in `parseTypeDecl`), each preceded by a diagnostic and documented as
  such. `parseParams` no longer invents the name `arg`.
* The stale "Phase 0 scaffold / skipped tolerantly" header is replaced by what
  the module now is.

One deliberate non-change: diagnostics still go through Nim's `localError`
rather than a new structured error type. That machinery *is* the compiler's
error type, it already carries `TLineInfo`, and a parallel one would duplicate
it for no benefit. The plan said "a real error type"; this is the reasoned
alternative, recorded here rather than quietly skipped.

**Stage 4 - features, then libraries.**
`virtual`/`override`, interfaces as concepts, generics and constraints, then
`Func`/`Action` and collections (writable in N# once generics exist).

## 5. Notes

- Everything stays inside `compiler/nsharp/`, preserving the minimal-diff
  constraint (core Nim files remain only `syntaxes.nim`, `pipelines.nim`,
  `options.nim`, and additively `idents.nim`).
- Stages 1-3 are mechanical and gated by Stage 0a; Stage 2 carries the real
  design content.

- `guard < 64` in `chainMemberNames`/`findMember` hides base-class cycles.
- The "members must be defined in source order" rule is a lowering artefact
  leaking into user-visible semantics.
- No parser-level tests (only end-to-end stdout), now partly addressed by Stage 0a.
- Stale file header ("Phase 0 scaffold", "skipped tolerantly").

## 6. Debt paid after stage 4

* **"Members must be defined in source order" is gone.** `lowerModule` now emits
  imports, then every type, storage and accessor declaration, then a forward
  declaration of every routine, then the bodies in source order. A member may call
  one declared after it and a derived class may precede its base, as in C#. `nsgen`
  relied on its own forward declarations for the same reason; it now uses these.
* **`NsDiagText` is keyed by `NsDiag`.** The table was positional, so a code added
  out of order printed the wrong number; each entry now names its diagnostic.
* **Literals are lexed properly.** Hex/binary literals and suffixed ones used to
  parse as `0`, and `$`/unknown characters were skipped silently. Unknown
  characters are now NS1056.
