# N# - Language Specification (v1 draft)

> **Status:** DRAFT for discussion. Nothing here is frozen. Every row carries a
> *proposed* disposition that you are expected to accept, downgrade, or reject.
> The goal of this document is to agree on scope **before** any compiler work.

N# ("N-sharp") is a **C#-flavoured, C#-subset language that compiles through the
Nim compiler** to native code (C/C++), fully interoperable with Nim and C++.

- **File extension:** `.ns`
- **Compiler:** a second frontend inside the Nim compiler (new lexer + parser
  producing Nim's `PNode` AST, dispatched by file extension)
- **Runtime model:** no VM, no .NET, no BCL - Nim's memory model (ORC/ARC) and
  Nim's standard library
- **Tagline:** *C# you already know, compiled by a Nim backend you can trust.*

---

## 0. How to read this document

Each feature is a row with:

| Column | Meaning |
|---|---|
| **Feature** | The C# construct (or N# addition) |
| **C# meaning** | Short reminder of what it does in C# |
| **Disposition** | Proposed fate: `v1` / `later` / `out` / `decide` / `ext` |
| **Mechanism** | Cheapest place to implement: `front` (lexer/parser), `desugar` (AST→AST), `sem` (semantic analysis), `lib` (prelude/stdlib) |

**Disposition legend**

| Tag | Meaning |
|---|---|
| ✅ **v1** | In scope for the first usable release |
| 🔜 **later** | Wanted, but deliberately after v1 |
| 🚫 **out** | Not part of N# (please argue if you disagree) |
| ❓ **decide** | Genuinely unresolved - needs a call (default proposed) |
| ➕ **ext** | An N# feature that goes *beyond* C# |

**Mechanism legend**

| Tag | Meaning | Cost profile |
|---|---|---|
| `front` | Handled in the N# lexer/parser | medium |
| `desugar` | Rewritten to existing Nim constructs before `sem` | small–medium |
| `sem` | Needs changes/awareness in the semantic checker | large |
| `lib` | Pure N# prelude/library, no compiler change | small |

> **Rule of thumb we established:** anything that maps onto existing Nim
> semantics is cheap. `desugar` + `lib` features are the bulk of a C#-lite.
> `sem`-tagged features are where budgets explode.

---

## 1. Purpose, goals, non-goals

### 1.1 Goals
1. **Familiar C# surface.** A C# developer should be productive on day one.
2. **Native, not managed.** Compiles to native code via Nim. No VM, no GC VM.
3. **Bidirectional interop** with Nim and C++ (call and be called, either side).
4. **Statically typed** with real generics; `var` inference where natural.
5. **Embeddable** in a C++ engine (scripting + systems use cases).
6. **Good tooling:** LSP (completion, goto-def, refs, outline), C#-style errors.

### 1.2 Non-goals (v1)
- Binary/source compatibility with C# or the .NET runtime.
- The .NET Base Class Library, assemblies, reflection-heavy frameworks.
- `async`/`await`, LINQ query syntax, `dynamic`, expression trees.
- The full `unsafe`/pointer surface. N# v1 **does** include pointers,
  address-of, dereference, `cast`, and function pointers (see §4.2, §6, §14.2),
  but not `fixed`, `stackalloc`, or `ref struct`.

### 1.3 Design principles
- **Subset, not parody.** If we support a C# feature, it should behave the way a
  C# developer expects; when it can't, prefer a *loud compile error* over a
  silent surprise.
- **Desugar first, extend the compiler last.** Reach for `lib`/`desugar` before
  `sem`.
- **Interop is not a feature, it's the foundation.** Every design choice is
  checked against "can C++ and Nim still talk to this?"
- **One IR.** Both `.nim` and `.ns` produce the same AST, so a `.nim` module can
  `import` a `.ns` module and vice-versa with zero glue.

---

## 2. Open decisions (read this first)

Status of the blocking decisions (full log in §18). ✅ = resolved, 🟡 = still open.

| # | Decision | Resolution | Impact |
|---|---|---|---|
| D1 | **Case sensitivity** | ✅ **Case-sensitive**, C#-faithful (§3.1) | `front` + `idents` mode |
| D2 | **Interface model** | ✅ **Static interfaces = concepts** (v1); dynamic interface values → v2 (§8) | `sem` |
| D3 | **Method resolution** | ✅ member-first, then UFCS fallback | `sem` |
| D4 | **Namespace ↔ module** | ✅ namespace = one generated module; namespaces that use each other are a `{.cyclic.}` import cycle (§5.1.1) | `front` |
| D5 | **Entry point** | ✅ both top-level statements and `Main` | `front` |
| D6 | **Null model** | ✅ `nil`-able refs, `?` annotation; `Option[T]` for `T?` (§4.4/§7.3) | `lib` |
| D7 | **Numeric model** | ✅ drop `decimal` from core (later via lib) | `lib` |
| D8 | **Error codes** | ✅ own `NSxxxx` scheme + C#-phrased text (§17) | tooling |

---

## 3. Lexical structure

> N# is **brace + semicolon** based and **whitespace-insensitive** - no
> significant indentation. This makes the N# lexer *simpler* than Nim's (no
> IND/DED tokens), but it must be written from scratch.

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| `.ns` source files, UTF-8, optional BOM | - | ✅ v1 | front |
| Line comment `//` | ignore to EOL | ✅ v1 | front |
| Block comment `/* ... */` | ignore | ✅ v1 | front |
| XML doc comment `///` | structured docs | ✅ v1 (→ Nim `##`) | front/desugar |
| Identifiers | ASCII letters, `_`, digits | ✅ v1 (ASCII-only; Unicode deferred) | front |
| **Case sensitivity** | `Foo` ≠ `foo` | ✅ **v1: case-sensitive** | front + `idents` mode (§3.1) |
| Keywords | reserved words | ✅ v1 | front |
| Contextual keywords (`var`, `async`, `record`, `init`, `required`, `nameof`…) | usable as identifiers | ✅ v1 | front |
| Integer literals `123`, `0xFF`, `0b1010`, `1_000` | dec/hex/bin, separators | ✅ v1 (typed as C# types them: int, uint, long, ulong) | front/sem |
| Integer suffixes `u`, `l`, `ul` | unsigned/long | ✅ v1 | front |
| Real literals `1.5`, `1e10`, `.5` | floats | ✅ v1 | front |
| Real suffixes `f`, `d`, `m` | float/double/decimal | ✅ v1 (`f`,`d`); `m` 🔜 (D7) | front |
| Char literals + escapes `'\n'`, `'\u0041'` | char | ✅ v1 | front |
| String literals + escapes | `"..."` | ✅ v1 | front |
| Verbatim strings `@"..."`, verbatim identifiers `@class` | no escaping, `""` = quote | ✅ v1 | front |
| Interpolated strings `$"...{x,align:fmt}..."`, `$@"..."` | format holes | ✅ v1 | front (holes lexed as expressions) + desugar (→ `nsFmt`/`nsAlign`, `lib/pure/nsharp/format.nim`) |
| Raw strings `"""..."""` (C# 11) | multiline raw | ✅ v1 | front (closing-line indentation stripped, as C# does) |
| Interpolated raw strings `$"""...{x}..."""`, `$$"""...{{x}}..."""` (C# 11) | raw text with holes | ✅ v1 | front: the raw text trimmed as a raw string's, holes opened by as many braces as there are `$` (more braces are text) |
| UTF-8 strings `u8"..."` | byte spans | 🔜 later | front |
| Preprocessor `#if/#elif/#else/#endif/#define/#undef` | conditional compile | ✅ v1 (lexical, as in C#; an undefined symbol is asked of `-d:`) | front |
| `#region/#endregion`, `#nullable` | folding / NRT context | ✅ v1 (accepted and ignored) | front |
| `#error`, `#warning` | diagnostics | ✅ v1 (NS1029 / NS1030) | front |
| `#pragma`, `#line` | compiler hints | ✅ v1 (accepted and ignored) | front |
| `goto` + labels | jump | 🚫 out (NS9999, `goto case`/`goto default` too) | - |
| `;` terminators, `{ }` blocks | structure | ✅ v1 | front |

**Notes**
- C# preprocessor is a *real* preprocessor (can remove code before parsing). N#
  will treat `#if` as a **conditional compilation directive** mapped to Nim's
  `when defined(...)`, **not** an arbitrary text-level macro. This keeps the
  parser a normal parser and the semantics analyzable. (See §16 ➕ `when`.)
- Because N# is whitespace-insensitive, porting C# snippets "just works".

### 3.1 Case sensitivity - implementation note (D1)

Nim bakes *style-insensitivity* into identifier **identity**, not just lookup:

- `compiler/lexer.nim:906` lowercases `A–Z` and skips `_` when hashing an identifier;
- `compiler/idents.nim:82` interns style-equivalent spellings (`Foo`, `foo`,
  `f_o_o`) to the **same `PIdent` id**;
- the symbol table keys slots on that `name.id` (`compiler/astdef.nim:1330`).

So `Foo` and `foo` are currently *the same symbol*, and you cannot even declare
both. Making N# case-sensitive therefore requires a small, contained change to
Nim's core: add a `caseSensitive` mode to `IdentCache` (`getIdent` skips the
`cmpIgnoreStyle` merge), have the **N# lexer compute a case-preserving hash**, and
toggle the mode while lexing/sem-ing `.ns` modules.

**Mixed-project policy:** Nim modules stay case-insensitive, so a `.nim` file may
still reach an N# symbol through a differently-cased spelling (Nim *is*
case-insensitive by design). A collision where a `.nim` and a `.ns` declaration
differ only by case is a **hard error**.

---

## 4. Type system

### 4.1 Built-in types

| C# type | Disposition | Maps to (Nim) |
|---|---|---|
| `bool` | ✅ v1 | `bool` |
| `byte`, `sbyte` | ✅ v1 | `uint8`, `int8` |
| `short`, `ushort` | ✅ v1 | `int16`, `uint16` |
| `int`, `uint` | ✅ v1 | `int32`, `uint32` |
| `long`, `ulong` | ✅ v1 | `int64`, `uint64` |
| `nint`, `nuint` | ✅ v1 | `int`, `uint` |
| `char` | ✅ v1 | Nim `char` (1 byte; see §4.4) |
| `float` | ✅ v1 | `float32` |
| `double` | ✅ v1 | `float64` |
| `decimal` | 🔜 later (D7) | `decimal` lib |
| `string` | ✅ v1 | Nim `string` (UTF-8, mutable; see §4.4) |
| `object` (universal base) | ✅ v1 | ref base `RootObj`; a value is boxed (§4.4) |
| `void` | ✅ v1 | return type omitted/`void` |
| `null` | ✅ v1 | `nil` (see §4.4/§7.3) |
| `var` (local inference) | ✅ v1 | `var x = expr` |
| `dynamic` | 🚫 out | - |

A type is also accepted under its BCL class name, which C# allows in place of the
keyword: `Int32` for `int`, `String` for `string`, `Boolean` for `bool`, and so on
down the table. `IntPtr` and `UIntPtr` are the class names of `nint` and `nuint`,
which are the same types. Both spellings produce the same Nim type, so
`Int32 x = 7; x / 2` truncates exactly as `int x = 7;` does. `Void` and `Decimal`
are excluded: N# has no `void` type and no decimal.

### 4.2 Composite & reference types

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| Arrays `T[]` | 1-D array | ✅ v1 | front + lib: the intrinsics' `NsArray[T]`, a reference over a `seq[T]`, so assignment and passing share the array and `null` is one (indexing or `Length` on it throws `NullReferenceException`); `==` is identity, `Clone()` and a range `a[1..]` copy, and it prints and `GetType()`s as `System.Int32[]` |
| Multi-dim arrays `T[,]` | rectangular | ✅ v1 | front + lib: the library's `NsMdArray[T]`, a reference holding the lengths and the elements in row-major order (`foreach` order); `new T[n, m]`, `{ {..}, {..} }` initialisers (a ragged one is NS0847), `a[i, j]` up to rank 3, `Length`, `Rank`, `GetLength`, `GetUpper/LowerBound`, and it prints `System.Int32[,]`. Like `T[]`, it is shared by assignment, as in C#. Mixing `T[,]` with another array (`int[,][]`, `int[][,]`) is NS9999 |
| Jagged arrays `T[][]` | array of arrays | ✅ v1 | front/lib: `new T[n][]` (n null rows) and `new T[][] { .. }` |
| `ValueTuple` `(int, string)`, named elements, deconstruction | tuples | ✅ v1 | desugar (→ a Nim tuple with fields `Item1..ItemN`; element names are aliases sema resolves; `(a, b) = v` reads `v` once; a class's `Deconstruct` is called). A whole tuple prints as Nim's `(Item1: 1, Item2: "z")`, not C#'s `(1, z)` |
| `List<T>`, `Dictionary<K,V>`, `HashSet<T>`, `Queue<T>`, `Stack<T>` | collections | ✅ v1 | lib |
| `Span<T>`, `Memory<T>` | views | 🔜 later | lib |
| `Nullable<T>` / `int?` | nullable value | ✅ v1 | lib (→ `Option[T]`) |
| Nullable reference types `string?` | NRT annotations | ✅ v1 (no-op, §7.3) | front (reported as the CS8632-style warning) |
| `object`-typed boxes | boxing | ✅ v1 | sem + lib (§4.4) |
| `IEnumerable<T>` etc. | interfaces | ✅ v1 (static/concept) | sem/lib |
| Pointers `T*`, `&`, `*`, `cast` | unsafe | ✅ v1 | front (→ `ptr`/`addr`/`[]`/`cast`) |
| `Func<>`, `Action<>` | delegate types | ✅ v1 | lib (→ `proc` types) |
| Tuples as return values | multiple returns | ✅ v1 | free |
| `record` / `record struct` | value records | ✅ v1 | symbols + desugar: a positional record gets a public property per parameter (`{ get; init; }`, `{ get; set; }` for a `record struct`), placed first, a constructor (passing `: Base(args)` on) and `Deconstruct`; lowering adds `==`/`Equals`/`hash` over its fields and auto-properties (a class record equal to itself, unequal to null), `nsClone` (a `method`, so a copy keeps the dynamic type) and `ToString` as `R { A = 1, B = x }` over the public members, base first, unless it declares one. Equality does not compare the dynamic type (C#'s `EqualityContract`) |
| `ref struct`, `stackalloc`, `fixed` | stack-only | 🚫 out | front |

### 4.3 User-defined types

| Feature | C# meaning | Disposition | Maps to |
|---|---|---|---|
| `class` | reference type | ✅ v1 | `ref object` |
| `struct` | value type | ✅ v1 | `object`; `new S()` on one declaring only other constructors is its default, every field zero (ECMA 16.4.9) |
| `interface` | contract | ✅ v1 (values and dispatch) | fat value: object + static table (see §8) |
| `enum` | named int constants | ✅ v1 | `distinct` underlying integer (`int` unless `: byte` etc.), each member a template over the enum's `typedesc` (`Color.Red`), `nsEnum` for `== < <= \| & ^ ~`, `HasFlag`, `hash` and printing; so `(Color)7` and combinations are values, members may repeat or skip values, and an unnamed value prints as its number |
| `[Flags] enum` | bit flags | ✅ v1 | as `enum`; a value prints as the names of its set bits (`Read, Write`) as .NET does |
| `delegate` declaration | named function type | ✅ v1 | `proc` type alias |
| Generic types | `List<T>` | ✅ v1 | Nim generics |
| Nested types | inner class | ✅ v1 | front (hoisted beside the enclosing type, which C#'s `Outer.Inner` already resolves by its last name; the runtime name stays `Ns.Outer+Inner`, and the enclosing type's statics are reachable bare). A type nested in a generic type is NS9999; a nested type's name must not collide with a top-level one of its namespace |

### 4.4 Strings, `char`, and `object`

**`char` is 1 byte and `string` is Nim's byte string** (decided). To stay
Nim-compatible with *no* conversion hacks, N# uses Nim's model directly:

| Aspect | C# | N# |
|---|---|---|
| `char` size | 2 bytes (UTF-16 unit) | **1 byte** (Nim `char`) |
| `string` encoding | UTF-16 | **UTF-8** |
| `string` mutability | immutable | **mutable** (Nim `string`) |
| `s.Length` | count of UTF-16 units | **byte count** |
| `s[i]` | UTF-16 unit | byte |

**Accepted divergences:** `s.Length` and `s[i]` are byte-oriented, so they differ
from C# for non-ASCII text. The prelude adds `s.RuneCount` (and `.Runes`) for
character semantics, while `.Length` stays the fast byte count. Strings are
mutable like Nim's - we do **not** fake C# immutability.

**`object` (universal base).** C#'s `object` is the root of all types and value
types are *boxed* into it. Nim has no universal value boxing and we will not add
a managed one, so v1 scopes `object` as a **reference base** (a `RootObj`-rooted
hierarchy) with `ToString()`/`Equals()`/`GetHashCode()` mapped to `$`/`==`/`hash`.
A value type (`int`, a `struct`, a `string`, which Nim holds by value) stored in
an `object` is **boxed**: sema marks the conversion wherever a value meets an
`object` target (a declaration, an assignment, an argument, a return, an array
element, `(object)v`), and the library's `nsBox` wraps it in an `NsBox[T]`, a
`RootObj` whose `ToString`, `Equals`, `GetHashCode` and `GetType` answer for the
value. `(T)o` unboxes through `nsUnbox`, which throws `InvalidCastException` unless
the box holds exactly a `T`; `o is T`, `o is T x` and type patterns ask `nsIsType`.
`==` on two `object`s compares references, so two boxes of `5` are `Equals` but not
`==`, as in C#. An untyped integer literal boxes as `int`.

---

## 5. Declarations & members

### 5.1 Compilation units, namespaces, `using`

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| Compilation unit = file | one file = one unit | ✅ v1 | front |
| `namespace X { ... }` | declaration space | ✅ v1 (→ module/scope) | front |
| File-scoped namespace `namespace X;` | C# 10 | ✅ v1 | front (the rest of the file is the namespace's body) |
| `using System;` | import namespace | ✅ v1 (becomes an `import`) | front |
| `using Alias = X.Y;` | namespace alias | ✅ v1 (imports the target) | front |
| `using Alias = SomeType;` | alias of a type | ✅ v1 | front (the parser writes the target wherever the alias names a type, `new Alias()` included, and the target's namespace is imported; `A = X.Y` is a type alias when `X.Y` is not a namespace and `Y` is a declared or library type). The import makes the namespace's other names visible too, which C# would not |
| `using static T;` | import members | ✅ v1 | sem (a bare name no local, member or enclosing type answers is looked up among the statics of each `using static` type, and resolved as `T.name`; `T`'s namespace is imported) |
| Global `using` | project-wide imports | 🔜 later | front |
| Nested namespaces | dotted or nested blocks | ✅ v1 (both give one path) | front |
| **File ↔ module mapping** | - | ✅ **D4** (§5.1) | front |

**A namespace name is a module path (D4).** The dots become slashes, so
`using X.Y;` lowers to `import "X/Y"` and `namespace X.Y { ... }` declares into the
same place: a `using` and a `namespace` always name one thing. Nested blocks
compose, because `namespace A { namespace B { } }` is that same declaration in C#.
One `.ns` file is one compilation unit; imports resolve across `.ns` and `.nim`.

**Qualifiers are dropped.** A namespace or type qualifier is decorative once the
name is lowered, because imported symbols are flat: `System.Console.WriteLine`,
`Company.Products.Gadget` and `P.Gadget` all lower to the bare name. That is why a
namespace alias is only an import of its target. A *type* written with its
namespace is the exception: `System.ArgumentException`, `Toybox.Console` lower to
`System.ArgumentException`, the namespace's module naming it, with that module
imported for qualified access only (`from "System" import nil`), so the type is
reachable with no `using` and two namespaces' `Console`s stay apart; one written
with another namespace than the compilation's own type of that name is the other
namespace's, not the compilation's. A type alias has no qualifier to
drop, so the parser substitutes its target instead.

**...but a namespace the library declares is global.** C# has no `using` in the
reachability rule for a fully qualified name, so `System.Console.WriteLine("hi")`
must compile with no `using` at all, and a qualifier that starts at a namespace the
*library* is written in (`System`, `System.Collections.Generic`) says which module
declares the name -- the qualifier C# drops has to be replaced by an import of that
module (`from "System" import WriteLine`), since Nim resolves a proc where it is
*used*. Namespaces are recorded compilation-wide for exactly this reason, and the
same lookup is what makes `(Demo.Gadget)g` parse as a cast. A namespace the
*compilation* declares is not replaced this way: `P.Gadget` and `Demo.Gadget.Make()`
resolve in the file that declares or imports them, which is where a `using` or a
`namespace` block put them.

**The frontend keeps no namespace to module table.** The N# standard library is the
root of the same tree, at `lib/pure/ns/`, which the frontend puts on the module
search path (`nsgen.nim`), so a BCL namespace is an ordinary module:

| C# namespace | file under `lib/pure/ns/` | Provides |
|---|---|---|
| `System` | `System.nim` | `Console`, exception hierarchy |
| `System.Collections.Generic` | `System/Collections/Generic.nim` | collection types (SS15.1) |

Nothing is implicit: `Console.WriteLine` without `using System;`, or `List<T>`
without `using System.Collections.Generic;`, fails to compile, which
`nsharp/tests/p3b/nousing.ns` pins. A namespace with no module is a "cannot open
file" error.

#### 5.1.1 User namespaces span files (D4, revised)

A C# namespace is **not** a file. Any number of `.ns` files may declare
`namespace UI`, and code in one of them may freely name another's types and
members. Nim has one module per file, so compiling each file as its own module
cannot express that: a method in `Widget.ns` calling one in `Button.ns` makes the
two modules import each other, which Nim rejects.

The frontend therefore emits each *used* namespace as one generated Nim module,
`<P>.nim` (`compiler/nsharp/nsgen.nim`), which `using P;` imports. `<P>` is the
namespace's path, so `namespace UI` gives `UI` and `namespace A.B` gives `A/B`. All
of the namespace's files are lowered together: every type in **one** type section,
so they may reference each other, and every routine forward declared, so a method
in one file may call one in another, in any order.

Namespaces may use each other, as in C#. Two namespaces that reach each other
through `using`s are an import cycle, which the generated modules declare with
Nim's `import "P" {.cyclic.}`: Nim checks the types, then the routine declarations
of every module of the cycle, before any body, so types, inheritance, generics and
calls go both ways (`p4b`).

Resolution: a token-level scan (no parsing, so an unrelated malformed `.ns` in the
tree cannot break a build) finds `namespace X` / `using X` under the main file's
directory; the generated modules go in `<nimcache>/.nsgen`, which is placed in
front of the module search path. Generation happens once, when the main module is
parsed, before its imports resolve.

**Limits.** A file is merged with a namespace's other files only when all of its
declarations land in that one namespace; a file that also declares outside one, or
spans two, is compiled on its own. A `using` is emitted as written rather than
resolved relative to the enclosing namespace, so `using Company.Shared;` inside
`namespace Company` works and `using Shared;` does not. A namespace alias is an
import of its target, so it also puts the target's names in unqualified scope,
which C# does not: after `using P = Company.Products;`, `Gadget` resolves as well
as `P.Gadget`. A sibling `<N>.ns` file takes precedence over the generated module.
Only a `using` joins a cycle: namespaces that name each other's types only
qualified (`Beta.B`, no `using Beta;`) do not.

### 5.2 Type declarations

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| `class C : Base, IFoo { }` | class decl | ✅ v1 | front |
| `struct S { }` | value type | ✅ v1 | front |
| `interface I { }` | contract | ✅ v1 | desugar → fat interface value (see §8) |
| Default interface methods (C# 8) | `interface I { void M() { ... } }` | ✅ v1 | desugar (see §8); in a generic interface NS9999 |
| Static abstract interface members (C# 11) | `static abstract T Zero { get; }`, `static abstract T operator +(T a, T b);`, `T.Zero` in `where T : I<T>` | ✅ v1 | sema checks the implementation (NS0535); a generic call `T.M()` resolves statically (see §8); a static member with a body NS9999 |
| `enum E { A, B }` | enum | ✅ v1 | front |
| `delegate R D(args);` | func type | ✅ v1 | front |
| `record`, `record struct` | data classes | ✅ v1 | see §4 |
| `partial class` | split decl | ✅ v1 | symbols (the declarations, in any file or namespace block of the namespace, merge into one: members and base lists) |
| Nested types | inner | ✅ v1 | see §4.3 |
| `abstract class` | non-instantiable | ✅ v1 | sem (`new` is NS0144; an unfilled abstract slot NS0534) |
| `sealed class` | non-inheritable | ✅ v1 | sem (deriving is NS0509) |
| `static class` | no instances | ✅ v1 | sem (a class like any other whose members are static; `new` of one is NS0712, an instance member NS0708) |

### 5.3 Members

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| **Fields** `int x;` | data member | ✅ v1 | front (→ `nkIdentDefs`) |
| `const` fields | compile-time const | ✅ v1 | desugar (→ Nim `const` + accessor template; assigning one is NS0131) |
| `readonly` fields | assign-once | ✅ v1 | sem (assignment outside a ctor of the class is NS0191 / NS0198) |
| `static` fields | type-level | ✅ v1 | desugar (→ module global `nsC_x` + `template x(t: typedesc[C])`, so `C.x = 1` and `C.x += 1` are Nim's dot-call) |
| `static readonly` | type-level const | ✅ v1 | desugar |
| **Methods** `R M(P a) { }` | method | ✅ v1 | front (→ `proc`) |
| Expression-bodied method `=> e;` | `R M() => e;` | ✅ v1 | desugar |
| `static` methods | type-level | ✅ v1 | desugar (`proc M(t: typedesc[C], ...)`, called `M(C, ...)`, so a static method never competes with an instance member through Nim's dot-call) |
| `virtual` / `override` / `abstract` | dispatch | ✅ v1 | desugar (`virtual`/`abstract` → `method {.base.}`, `override` → `method`; an override without a slot is NS0115). An N# program is built with Nim's vtables (`compiler/main.nim` turns the feature on when the main file is `.ns`), so a virtual call is one indirect call, as in .NET; a hierarchy with a generic class in it (`Pet<T> : Animal`) dispatches through Nim's classic dispatchers instead, since an instance of a generic type has no vtable of its own (`compiler/vtables.nim`, `sempass2.nim`). Nim attaches an override to a generic base method's *instance*, which must exist first: an override in a class deriving an instance (`IntRepo : Repo<int>`) is declared after every generic routine is defined and the base method is instantiated for those arguments (`static: discard compiles(M(Repo[int32](nil), ...))`), and for each instance of a generic class the module names (`Wrapper<string>`), the methods of it and its generic bases are instantiated, base first (`instantiateBase` in `desugar.nim`) |
| `sealed override` | stop override | ✅ v1 | sem (overriding it again is NS0239) |
| `new` (hide) | shadow base | ✅ v1 | desugar (a plain proc beside the base's `method`, so static type decides, as in C#) |
| **Constructors** `C(a) { }` | init | ✅ v1 | desugar (→ `proc new`) |
| `this(...)` chaining | ctor call | ✅ v1 | desugar |
| `base(...)` in ctor | base ctor | ✅ v1 | desugar |
| Static constructor `static C() { }` | type init | ✅ v1 | desugar: `nsStaticCtor_C()`, run once on first use, as C# does (ECMA 15.12): the static field initialisers in order, then the body. Every static method and instance constructor calls it first, and a static field (an auto-property's backing one too) is reached through `nsStaticRef_nsC_x()`, which does; a `const` is not. A class without one initialises its statics when the program starts (`nsStaticInitC`), which `beforefieldinit` allows; a native class keeps that too |
| Primary constructors (C# 12) | `class C(int x)` | ✅ v1 | symbols + sema: a constructor of the parameters (passing `: Base(args)` on), each parameter a member does not declare itself captured in a private field of its name, initialised from it; instance initialisers see the parameters themselves, as a record's do. Another constructor must chain to it (NS8862) |
| **Destructor/Finalizer** `~C() { }` | cleanup | ⚠️ v1 (never runs) | sem: the body is checked as a method, but N# has no collector to call it, so it never runs, and NS9998 warns. .NET runs a finalizer only when the collector reclaims the object, which in a short program is typically never, so the observable output usually agrees; a Nim `=destroy` was ruled out because ORC cannot bind one to a type whose destructor an upcast of `this` has already required. Only a class has one (NS0575), named after it (NS0574) |
| **Properties** (see §5.4) | accessors | ✅ v1 | desugar |
| `this[...]` indexer | indexer | ✅ v1 | desugar (→ `[]`/`[]=` over the receiver and the index parameters; several indices allowed) |
| Named indexers | C# 13 | ✅ v1 (ext) | desugar |
| **Events** `event D E;` | pub/sub | ✅ v1 | see §10 |
| **Operators** `operator +` | overload | ✅ v1 | desugar (→ the Nim proc of that operator; `%`/`&`/`\|`/`^`/`<<`/`>>`/`!` are `mod`/`and`/`or`/`xor`/`shl`/`shr`/`not`); `operator true/false` is NS9999 |
| Conversion ops `implicit`/`explicit` | casts | ✅ v1 | desugar (implicit → `converter nsImplicit_T`, explicit → a proc a cast calls; using an explicit one implicitly is NS0266) |
| `++`/`--` overloads | `operator ++` | ✅ v1 | desugar (→ `inc`/`dec` over a `var` operand) |
| `checked` operators (C# 11) | `operator checked +`, `explicit operator checked int` | ✅ v1 | sem + desugar: inside `checked(...)`/`checked { }` a `+`, `-`, `*`, `/`, unary `-`, compound assignment or explicit cast on a type that declares the checked version calls it (`nsCheckedAdd`, `nsExplicitChecked_T`); elsewhere the unchecked one. Only those operators may be checked (NS9023), never an implicit conversion (NS9024), and only beside the unchecked version (NS9025); a checked `++`/`--` is NS9999 |
| Partial methods | `partial void OnX();` + `partial void OnX() { ... }` | ✅ v1 | symbols: the implementing declaration (with a body) is the method and the defining one leaves the tree. A `partial void` with no implementation is an empty method; C# removes the calls as well, arguments included, so a call's arguments are still evaluated in N#. One with an access modifier, a result or an `out` parameter must be implemented (NS8795) |

### 5.4 Properties (flagship C# feature)

> **Verified cheap.** Nim already implements C#-style read *and* write dispatch:
> a getter `proc P(x: T): R` and a setter ``proc `P=`(x: var T, v: R)``, wired by
> `propertyWriteAccess` and `dotTransformation` in `compiler/semexprs.nim`. We
> confirmed `obj.Prop = v` and `obj.Prop` work end-to-end. **No `sem` changes.**

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| Auto-property `R P { get; set; }` | backing field + accessors | ✅ v1 | desugar |
| Read-only `R P { get; }` | getter only | ✅ v1 | desugar (its constructors assign it through a setter private to the module; any other assignment is NS0200) |
| Computed `R P { get { .. } set { .. } }` | bodies | ✅ v1 | desugar |
| Expression-bodied `R P => e;` | single expr | ✅ v1 | desugar |
| Init-only `R P { get; init; }` | set in ctor only | ✅ v1 | sem (an ordinary setter; assigning it outside an object initialiser or its own constructor is NS8852) |
| `required` members | must-init | ✅ v1 | sem (`new T { ... }` without one of them is NS9035; `[SetsRequiredMembers]` is not recognised) |
| Static properties | type-level | ✅ v1 | desugar (getter/setter over `typedesc[C]`, backing in a module global) |
| Accessor visibility `{ get; private set; }` | per-accessor | ✅ v1 | front (accessors may also be `=> e`); a `private set` is not exported from its module |
| Abstract/virtual properties | dispatch | ✅ v1 | sem |
| Interface properties | contract | ✅ v1 | desugar (getter/setter table entries) |

### 5.5 Access modifiers

| Modifier | C# meaning | Disposition | Maps to (Nim) |
|---|---|---|---|
| `public` | all | ✅ v1 | exported (`*`) |
| `private` | type/unit | ✅ v1 | module-private (default) |
| `protected` | type + derived | ✅ v1 (approx) | module-scoped in v1 (see note) |
| `internal` | assembly | ✅ v1 | module-private |
| `protected internal` | union | ✅ v1 | front (one compilation is one assembly, so it is `internal`) |
| `file` types (C# 11) | `file class Helper { }` | ✅ v1 | front + sem (a top-level class, struct, record, interface, enum or delegate only its own file may name: a use from another file of the namespace is NS0246; nested NS9054; two file types of one name in one namespace NS9999, since a namespace's files lower as one module) |
| `private protected` | intersection | ✅ v1 | front (within one assembly, `protected`) |
| `file` | file-only | ➕ ext | Nim module-private |

**Note on `protected` (resolved):** Nim's visibility is module-based, not
inheritance-based. **v1 approximates `protected` as module-scoped** (visible
within the declaring `.ns` module) - a documented divergence from C#'s
inheritance-scoped rule. Inheritance-scoped checking is a `sem` change staged to
v2.

---

## 6. Statements

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| Block `{ ... }` | scope | ✅ v1 | front |
| `if` / `else if` / `else` | branching | ✅ v1 | front (→ `nkIfStmt`) |
| `switch` (statement) | multi-branch | ✅ v1 (patterns and `when` guards included) | desugar (a labeled block, so `break` leaves the switch; Nim `case` when every label is a constant, otherwise a chain of pattern tests over the subject read once) |
| `switch` expression `x switch { ... }` | C# 8 | ✅ v1 | desugar (a chain of arms, each in its own block; no match throws `SwitchExpressionException`) |
| `while` | loop | ✅ v1 | front |
| `do { } while (c);` | post-test loop | ✅ v1 | desugar (flag-guarded `while`, §7.3) |
| `for (i = 0; i < n; i++)` | C-style for | ✅ v1 | desugar (→ `while`) |
| `foreach (var x in xs)` | iterate | ✅ v1 | desugar (→ `for` over the collection's `items`; over a class with a `GetEnumerator` method, C#'s own expansion: `let e = c.GetEnumerator(); while e.MoveNext(): let x = e.Current`) |
| `break` / `continue` | loop control | ✅ v1 | front |
| `return` | return | ✅ v1 | front |
| `goto` / labels | jump | 🚫 out (NS9999) | - |
| `throw e;` | raise | ✅ v1 | front (→ `raise`) |
| `try { } catch (E e) { } finally { }` | EH | ✅ v1 | front (→ `try/except/finally`) |
| `catch when (cond)` | filter | ✅ v1 | desugar (one `except` takes every exception, picks the first clause whose type matches and whose filter holds, re-raises when none does; the filter runs after unwinding, so an inner `finally` runs before it, unlike C#) |
| `using (var r = ...) { }` | dispose scope | ✅ v1 | desugar (a block: each resource declared, then `defer: nsDispose(r)`, which skips a null one; several resources dispose in reverse) |
| `using var r = ...;` | dispose at block end | ✅ v1 | desugar (the same `defer`, in the enclosing block) |
| `lock (o) { }` | mutual exclusion | ✅ v1 | desugar (a block that evaluates `o`; a program has one thread, so the lock is always free) |
| `yield return e;` | iterator | ✅ v1 | desugar (→ Nim `yield` inside the closure iterator below) |
| `yield break;` | end iterator | ✅ v1 | desugar (→ `return` from the closure iterator) |
| Disposing an iterator's enumerator | runs the `finally` blocks it is suspended in (15.15.5); `foreach` disposes however it is left (13.9.5) | ✅ v1 | desugar + lib: in an iterator block a `try` holding a `yield` registers its `finally` as a closure on the enumeration's `nsDisp` stack while its body runs; `Dispose` runs what is registered, innermost first, and ends the enumeration; `items` over an `IEnumerable<T>` disposes in a `finally` |
| Iterator methods (`IEnumerable` return) | lazy seq | ✅ v1 | sem + desugar: a method or local function returning `IEnumerable<T>`/`IEnumerator<T>` whose body yields becomes `result = nsEnumerable(T): body` -- a closure iterator started afresh per enumeration, so the body runs lazily as C#'s does. A property's or indexer's getter may be an iterator the same way; an iterator operator is NS9999; `yield` in a lambda is NS1621, in a non-iterator member NS1624. A class may implement `IEnumerable<T>` or `IEnumerator<T>`: they are library types rather than tables, so they leave its base list (with the non-generic members implemented explicitly beside the generic ones), `foreach` uses its `GetEnumerator`, and where an `IEnumerable<T>`/`IEnumerator<T>` is expected sema converts it through the library's `nsToIEnumerable`/`nsToIEnumerator`, a view that asks the class for each enumeration |
| `checked { }` / `unchecked { }` | ovf checks | ✅ v1 | desugar (→ `{.push overflowChecks.}`, §7.3) |
| `unsafe { }` blocks (pointers, `&`, `*`) | unsafe | ✅ v1 | front |
| `fixed`, `stackalloc` | stack-only | 🚫 out | front |
| Local functions | nested funcs | ✅ v1 | desugar (→ nested proc, a closure over what it names, declared forward at the top of its block so a call may precede its declaration) |
| `defer { }` | - | ➕ ext | front |
| Statements as expressions (`if`/`switch` value) | C# 8 | 🔜 later | desugar |

**Notes**
- C-style `for` and `do-while` are pure desugar to Nim `while`; trivial but must
  be handled so C# code ports unchanged.
- `switch` maps to Nim `case` for constant patterns; type/property patterns need
  lowering (later).

---

## 7. Expressions & operators

### 7.1 Operators

| Group | C# | Disposition | Mechanism |
|---|---|---|---|
| Arithmetic `+ - * / %` | ✅ | ✅ v1 | front; `%` on `float`/`double` is the truncated remainder (`fmod`), the intrinsics' `nsFmod`. An integer constant beside a `uint`/`ulong` operand takes that type when it fits (ECMA 10.2.11), so `u - 6` is a `uint` and wraps |
| Integer `& | ^ << >> >>> ~` | ✅ (`>>>` C# 11) | ✅ v1 | front; a shift count is masked to the operand's width (`1 << 33 == 2`) by the intrinsics' `nsShl`/`nsShr` unless it is a constant below 32, and `>>>` (`nsUShr`) shifts zeros in. The lexer keeps `>>` whole; the parser reads `>>>` as a `>>` with an adjacent `>`, and `>>>=` as one with an adjacent `>=` |
| Logical `&& || !` | ✅ | ✅ v1 | front |
| Comparison `== != < > <= >=` | ✅ | ✅ v1 | front |
| String `+` | concatenation | ✅ v1 (Nim spelling) | `nsharp/intrinsics`, imported into every module |
| `ToString` / `$` | stringify a value | ✅ v1 (Nim spelling) | Nim's `$`; an object prints as its fields |
| Assignment & compound `= += -= ...` | ✅ | ✅ v1 | front |
| `??` null-coalescing | ✅ | ✅ v1 | desugar (`nsCond` temporary) |
| `??=` | ✅ | ✅ v1 | desugar (`x = x ?? b`, re-wrapped for a `T?` target) |
| `?.` / `?[]` null-conditional | ✅ | ✅ v1 | front + desugar (`nsCond` per link) |
| A library type named with its namespace and no `using` | `new System.Collections.Generic.List<int>()` | ✅ v1 | desugar: the type is imported by name with the operators and iterators its module declares (`[]`, `items`, ...), which no C# name can clash with; a library type in `new` whose namespace the file does not import is NS0246 |
| `?:` ternary | ✅ | ✅ v1 | front (→ `nkIfExpr`) |
| `is` / `as` | type test/cast | ✅ v1 | front (→ Nim `of`/conv). In the type after `is`/`as`, a `?` followed by what starts an expression is the conditional operator (`o is int ? a : b`). `as` takes `string`, array and `T?` targets too (from an `object`, `nsAsValue`) |
| `(T)x` explicit cast | conversion | ✅ v1 | front (→ Nim `T(x)`) |
| Patterns: type `T x`, constant, `null`, relational `> 5`, `and`/`or`/`not`, property `{ P: pat }`, `var x`, `_` | C# 7-9 | ✅ v1 | desugar (a boolean test assigning the pattern's variables, which are declared where C# scopes them); positional patterns: see below |
| Positional and tuple patterns `Point(var x, 0)`, `(0, _)` | deconstruction | ✅ v1 | sem + desugar: of the type (or not null), then the parts -- a tuple's elements, or the `out` values of the `Deconstruct` with as many parameters -- each against its pattern; a designation binds the whole |
| List patterns `[1, _, ..]`, `[var a, .. var rest, var z]` (C# 11) | sequence shape | ✅ v1 | sem + desugar: the length (exactly, or at least the elements beside a slice), then each element pattern against `x[i]`, those after the slice counted from the end, and the slice's pattern against `x[i ..< len - j]`. Arrays and strings, and for element patterns any type with `Count`/`Length` and an indexer; a slice pattern of anything else is NS9999 |
| Switch expressions | C# 8 | ✅ v1 | desugar |
| `^` (index-from-end), `..` (range) | C# 8 | ✅ v1 in element access | desugar: on an array or a string Nim's own `^k` and slices (`a..b` excludes `b`, so it is `a ..< b`; an open end is `.. ^1`); `x[^k]` on a type with an indexer and `Count`/`Length` is `x[x.Count - k]`, `x` read once. A range of anything else (a `List<T>`'s `Slice`) and an `Index`/`Range` value outside `[...]` are NS9999 |

**Stringification of primitives is Nim's.** `$` and `ToString` are the same thing.
Two consequences are deliberate: a bool reads `true` where C# writes `True`, and a
whole float reads `3.0` where C# writes `3` (a format spec, `{x:G}`, gives C#'s
form). An object prints the way C# prints it: `ToString` is a dispatched `method`,
so a class shows its override, or its namespace-qualified name, for its *dynamic*
type; a struct likewise through a generated `$`. String `+` accepts
any operand type, as C#'s `(string, object)` overloads do, so `"n=" + 3` and
`"obj=" + obj` both work.
| Null-forgiving `x!` | suppress NRT | ✅ v1 | front (a postfix with no effect: it only silences nullable warnings, which N# does not issue) |
| `checked`/`unchecked` expr | ovf | ✅ v1 | desugar (a block expression: `push overflowChecks, rangeChecks`, the operand into a temporary, `pop`) |
| Throw expression `x ?? throw e` | raise as a value | ✅ v1 | desugar (`raise` is `noreturn`, so it stands where a value is expected); `=> throw e` as a member body is the statement, whatever the member returns) |
| `stackalloc` | stack mem | 🚫 out | front |
| Precedence | C# table | ✅ v1 | front |

### 7.2 Expressions

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| Method call `f(a, b)` | call | ✅ v1 | front |
| Member access `a.b` | dot | ✅ v1 | front |
| `this`, `base` | self/base | ✅ v1 | desugar |
| Lambdas `x => e`, `(a,b) => e` | closures | ✅ v1 | front (→ Nim closure) |
| Anonymous methods `delegate { }` | older lambdas | ✅ v1 | front (a lambda with typed parameters and a block body; `delegate { }` without a list takes its delegate's parameters, unnamed) |
| Object initializer `new T { A = 1 }` | init props | ✅ v1 | sem (rewritten into assignments over a temporary, checked as such) + desugar (a block expression) |
| Collection initializer `new List<int>{1,2}`, index initializer `{ [k] = v }`, nested `A = { ... }` | init | ✅ v1 | sem (`Add` calls / indexer assignments) + desugar |
| Collection expressions `[a, b, ..xs]` (C# 12) | target-typed collection | ✅ v1 | sem: into an array (or `IEnumerable<T>`, `IList<T>`, `IReadOnlyList<T>`...) an array literal, or with spreads a sequence built element by element; into a collection type `new C { a, b }`, or with spreads `new C(array)`. Without a target type NS9176 |
| Anonymous types `new { A = 1 }` | inferred type | ✅ v1 | sem + desugar: one sealed record-like class per shape (member names and types, in order), synthesized once the values are typed; `new { x, p.Name }` takes the value's name (else NS0746). It prints `{ A = 1 }`, `Equals` compares members while `==` compares references, and `with` copies. A duplicate name is NS0833, a `null` or lambda member NS0828; no `Deconstruct`. Its properties are `init`, so assigning one outside `with` reports NS8852 where C# reports CS0200 |
| `typeof(T)` | type object | ✅ v1 | lib + desugar: `nsTypeOf(T)`, declared by the library for the built-in types and by lowering for each class, struct and enum, yields a `System.Type` that knows the type's name (`Name`, `FullName`, `Namespace`, `==`); `x.GetType()` asks a class value through a `method` every class overrides, and a value its static type. A constructed generic type is named as .NET names it (``Demo.Box`1[System.Int32]``, `Name` ``Box`1``), by a generic `nsTypeOf` lowering emits for each generic class and the library declares for its collections; an array is `System.Int32[]`. No reflection beyond the name; a tuple or nullable type is NS9999. `GetType()` on an instance of a generic class still names the class without its arguments |
| `nameof(x)` | name string | ✅ v1 | front, a literal of the written name |
| `default(T)` | default value | ✅ v1 | desugar (→ Nim `default`) |
| `default` literal, `int[] a = { 1, 2 }`, `new[] { 1, 2 }` | target-typed / inferred | ✅ v1 | sem (from the target; an implicitly typed array from its elements) |
| `T.MaxValue` etc. | `static` field | ✅ v1 | lib (`lib/pure/ns/System.nim`) |
| `sizeof(T)` | byte size | ✅ v1 for the built-in value types (C#'s sizes: `char` is 2) | lib (`nsSizeOf`); any other type needs an unsafe context and is NS9999 |
| String interpolation `$"{x}"` | format | ✅ v1 | desugar |
| `with` expression (records) | copy-update | ✅ v1 | sem + desugar (a copy -- `nsClone` for a class record, the value for a struct -- with the initialiser applied as to a temporary; on a non-record class NS8858) |
| Target-typed `new()` (C# 9) | infer type | ✅ v1 | sem (typed by the declaration, assignment, field, `return` or parameter it converts to) |
| LINQ *method* syntax `.Where().Select()` | query | 🔜 later | lib |
| LINQ *query* syntax `from..select` | query | 🚫 out (argue) | front |
| Expression trees | `Expression<T>` | 🚫 out | - |
| `await` expression | async | 🔜 later | sem |

**Notes**
- `?.`/`??`/`??=` are the main "null" desugars (null model: §4.4/§7.3).
- `nameof` and `default(T)` are trivial rewrites; `typeof` and `sizeof` are calls the
  library answers.

### 7.3 Semantic traps (must-pin C#↔Nim mismatches)

These look like trivial desugars but are not - each needs an explicit rule.

| Trap | C# | Nim | N# rule | Mechanism |
|---|---|---|---|---|
| Integer `/` | `7/2 == 3` (int div) | `7/2 == 3.5` (float!) | integer `/` goes to the intrinsics' `nsDiv`; `/` stays floating point. `nsDiv`, `nsMod` and the shifts are generic, which an untyped literal on the left would bind to Nim's `int` (`5 / z`), so such a literal takes the other operand's type (`typeof(z)(5)`), or for a shift C#'s `int` | front/lib |
| `%` | sign of dividend | `mod`: sign of dividend (matches) | map `%` → `nsMod` | front/lib |
| Division by zero | always `DivideByZeroException` | `overflowChecks` also governs Nim's zero check for `div`/`mod` | checked in `nsDiv`/`nsMod`, so it throws whether or not `checked` is in force | lib |
| Overflow default | unchecked (wraps) | checked (raises) | **unchecked by default**: every generated module opens with `{.push overflowChecks: off, rangeChecks: off.}`, so arithmetic wraps and an explicit narrowing conversion keeps the low bits (`(short)70000` is 4464, `short s = 32767; s += 1;` is -32768) | desugar |
| Unhandled exception | `Unhandled exception. T: msg`, its inner exceptions (` ---> T: msg`) and stack trace on stderr, then an abort (exit 134) | `Error: unhandled exception: msg [T]` after a traceback, exit 1 | `System` sets Nim's `unhandledExceptionHook` to print .NET's report -- the .NET type name and `Message`, the inner exceptions, and the program's own frames as `   at Main in File.ns:line 6` when the build keeps stack traces -- and abort as .NET's runtime does | lib |
| `checked`/`unchecked` | ovf on/off | `{.push overflowChecks.}` | same mechanism, `push`/`pop`, emitted around the block's statements | desugar |
| `checked` and conversions | covers overflow **and** conversions | `overflowChecks` and `rangeChecks` are separate switches | both are switched together; inside `checked` a conversion that is out of range raises `RangeDefect` (aliased `ArgumentOutOfRangeException`) where C# raises `OverflowException` | desugar |
| `MinValue / -1`, `MinValue % -1` | `OverflowException` (.NET, checked or not) | `%` traps (SIGFPE) | `nsDiv`/`nsMod` raise `OverflowDefect` (aliased `OverflowException`) | lib |
| `==` / `Equals` | class = reference, struct = value | whatever is overloaded | class → reference `==`; struct/record → value `==`; `Equals`→`==` | desugar/sem |
| `ToString()` | virtual method | `$` proc | satisfied by a `ToString` proc in the intrinsics (`$x[]`), which Nim's dot-call reaches; no member name is mapped by the compiler | lib |
| Numeric conversions | implicit widening, explicit narrowing; binary numeric promotion (`byte + byte` is `int`, `int * double` is `double`) | stricter: no implicit `int`→`float`, no `char` arithmetic, `uint8 + uint8` stays `uint8` | `compiler/nsharp/numeric.nim` holds C#'s promotion and implicit-conversion tables; `sema.nim` records the conversion an operand or a value needs (`conv`) wherever both types are known exactly, and `desugar.nim` spells it `T(x)`. A compound `x op= y` promotes and casts back, as C# does. Implicit narrowing of a non-constant is NS0266. Elsewhere implicit widening; explicit narrowing. The refusals the frontend can *see* are diagnosed with C#'s own code (CS0029, CS0037, CS1503) before anything is lowered; what it cannot see -- an unresolved name, an enum, a type from a module it does not cover -- counts as compatible, so Nim keeps the last word | front/sem |
| `(T)x` vs `(x)` | the symbol table decides | - | the parenthesised name must resolve as a type -- C#'s vocabulary, the library's declarations, a type this compilation declares, an enum, or a namespace it imports -- **and** be followed by a value, so `(x) - 1` is a subtraction while `(Foo) - 1` is a cast | front |
| `for` and `continue` | `continue` runs the step | a `while`'s `continue` skips what follows in the body | the loop's own `continue`s leave a labeled block around the body, so the step still runs | desugar |
| `do-while` and `continue` | the check runs *after* the body, so `continue` re-tests it | `while` tests before | one body copy under a first-pass flag (`while first or c`, cleared before the body), leaving `break` and `continue` to Nim's own loop | desugar |
| `using` keyword | directive **and** statement | - | disambiguate by context | front |
| `switch` fallthrough | forbidden (empty cases group) | no fallthrough | maps to Nim `case`; empty-case groups allowed; a trailing `break;` is dropped; a non-exhaustive switch gets `else: discard` | front |
| `Main` / `args` | `Main(string[])`, exit code | module top-level | support both (D5); `int` return → exit code | front |
| Interpolation format | `$"{x:F2}"` | `strformat`/`formatFloat` | a hole lowers to `nsFmt(x, spec)`, which renders .NET's standard numeric specs (`C D E F G N P R X` with precision) and custom ones (`0 # . , %`) as .NET's en-US culture does; a hole without a spec is the value's `$`, so N#'s float rendering applies there | desugar/lib |
| `null` deref | `NullReferenceException` | no runtime check | `desugar.nim` wraps the receiver of a field access or dot-called method on a class reference in the intrinsics' `nsCheckNil`, so null raises `NullAccessDefect` -- aliased to `NullReferenceException` -- instead of faulting; off under `-d:danger` / `--nilChecks:off`. A receiver that is a variable or a field of one is tested in place (`nsCheckNilVar`), costing no reference count; the throw is out of line; any other receiver (`list[i].M()`) is read once into a variable that owns nothing, so it costs none either | front/lib |
| Arrays | `T[]`, `new T[n]` | `NsArray[T]` | `T[]` → `NsArray[T]` (a `ref` over a `seq[T]`); `new T[n]` → `nsNewArray(T, n)`; `new T[]{..}` → `nsArrayFrom[T]([..])`; `.Length` is the library's proc, reached by Nim's dot-call | front/lib |
| Bounds checks in counted loops | the JIT drops the check on `a[i]` in `for (int i = 0; i < a.Length; i++)` | - | the same loop -- a counter starting at a non-negative constant (or an enclosing such counter plus one) and stepped only by its `++`, an array the body never replaces -- reads `a[i]` unchecked (`nsAtUnchecked`), when both are the routine's own locals or parameters, no closure captures them and the array is not a `ref` parameter. Any other index keeps its check | front/lib |
| Enum field scope | scoped to the enum type | unqualified globals | `E.A` resolves via Nim qualified access; two enums must not share a field name | front |
| The literal `0` and enums | `0` converts to every enum type (10.2.4); `&`, `|`, `^` of an enum are of it | - | sema: a `0` literal where an enum is expected, or beside one in a binary, is converted to it; the bitwise operators keep the enum type | sem |
| Exceptions | all derive from `Exception` | `Exception` is the root of both `CatchableError` and `Defect` | C# `Exception` → Nim's exception root, so `catch (Exception)`, and a catch-all `catch`, catch runtime errors too; the .NET names are declared by the library, aliasing the defect Nim raises where one exists (`OverflowException` → `OverflowDefect`); `throw` → `raise`; an exception class is a value `object` (so `except T` can match) but is raised as `ref T`, and a local, field, property, parameter, result or type argument of an exception type is that `ref T` (so it may be null and keeps the dynamic type), while `except`, `of` and a base clause name the object type; `new T(msg)` of a library exception is `newException(T, msg)` wherever it is written | front/lib |
| `e.Message` | property on every exception | an ordinary proc over `Exception` (`e.msg`) | the library declares `Message` for the exception root; Nim's dot-call reaches it, and the compiler knows no member name. A runtime check's defect carries Nim's text (`index 5 not in 0 .. 1`, `over- or underflow`), which `Message` puts in .NET's words: by the static type where it names the defect, otherwise by one `of` test when the message is read. N#'s own throws use .NET's text from the start (a failed cast names both types) | lib |
| `new E(...)` of a library exception | the constructor makes the message: a parameterless one the type's default (`Operation is not valid due to the current state of the object.`), `ArgumentNullException(paramName)` `Value cannot be null. (Parameter 'p')`, an inner exception kept | `newException(T, msg)` | `nsNewException(T, args)` in `System`, one overload per constructor shape; `InnerException` reads Nim's `parent`. A user exception class starts with the default of its nearest library base, or `Exception of type 'Demo.E' was thrown.` | desugar/lib |
| `e.GetType()` of an exception | the dynamic type | a method cannot be attached to the defects .NET's exceptions alias: they are declared in Nim's `system`, whose type information exists before any method (with vtables, a dispatch on one is wild) | an exception's `name` (Nim's `cstring` field) holds its .NET name: its constructor sets it (`nsNewException`, an exception class's allocator), and one Nim's runtime raised carries Nim's type name, which `System` maps (`IndexDefect` → `System.IndexOutOfRangeException`) | desugar/lib |
| Bool/float spelling | `True`, `NaN`, `∞` | `true`, `nan`, `inf` | Nim's rendering stands; where C# differs the test carries a `.csout` beside its `.out` | lib |
| `T?` / `Nullable<T>` | `struct Nullable<T> { T value; bool hasValue; }` | `Option[T]` has the same shape: a value plus a flag, and a bare pointer for a reference type | `T?` → `Option[T]` for a value type, a struct's included (`Pt?`); a reference is nullable already, so `Node?` is just `Node`. `int?` converts to `long?` lifted (`nsOptAs`), and a cast `(int?)x` from a `T?` or a value too | front |
| `MyObj?` / `string?` | an annotation on a type that is nullable already; C# warns CS8632 while the `#nullable` annotations context is off, which is the default | a reference type has no `Option`, so the `?` is nothing to lower | accepted as a no-op and reported as NS8632 -- the same digits. N# has no `#nullable` context, so the warning is unconditional. A `struct` is exempt: C# really does make that `Nullable<T>` | front |
| Lifted operators on `T?` | `a + b` is absent when either operand is; `a > b` is a plain `bool`, false then | none | ordinary procs over `Option` in the intrinsics, so no member name is known to the compiler; `/` and `%` reuse the `nsDiv`/`nsMod` check. The bare operand may stand on either side, and sema gives it the element type (`1 + a`, `3 == a`); `==` against a bare value is false when absent; `bool?`'s `&`, `|`, `^`, `!` are three-valued (`false & null` is `false`); a lifted result keeps its element type, so `a + b == null` compares with `none(T)`; `x++` and `x += 1` step a present value | lib/sem |
| Printing a `T?` | its value, and nothing when absent (`$"{x:D3}"` formats the value) | `Option`'s `$` is `some(2)` / `none(int32)` | the intrinsics export `std/options` without its `$` and declare their own; `nsFmt` formats a present number with the spec | lib |
| `.Value` / `.HasValue` / `GetValueOrDefault()` / `x == null` | members of `Nullable<T>` | `get` / `isSome`, structural `==` | ordinary procs over `Option` reached by Nim's own dot-call, the way `int.high` reaches `high(int32)`; `== null` lowers to a comparison against `none(T)` | lib |
| `(T)x` on a `T?` | unwraps, throwing `InvalidOperationException` when absent | `get` raises `UnpackDefect` | unwrapped in lowering; `.Value` and the cast throw `InvalidOperationException` through the intrinsics' `nsNoValue` hook, which `System` sets (without `System` in scope it is `UnpackDefect`) | front/lib |
| `x is T v` on a `T?` | true when it has a value | - | `isSome`, binding the value | desugar |
| `a?.M()` of a value type, without `??` | a `T?` | - | the absent value `none(T)`, the present one wrapped in `some`; a `string` result is the empty string when absent | sem/desugar |
| A bare value or `null` for a `T?` target | implicit conversion wherever a value is bound: an argument, an initialiser, an assignment, a `return` | - | `sema.nim` matches a call against the *declared* parameter lists (every overload, not just the first declaration) and records the conversion the winning one needs on the argument node; `desugar.nim` spells it as `some(T)(v)` or `none(T)`. An argument the scope cannot match is left to Nim, so a library method or a type from a module the frontend does not cover is never a false refusal | front |
| Mutating a struct | a struct method may assign to `this`'s fields; the caller's variable changes | a parameter is immutable | a struct member that assigns to `this` (sema marks it) takes `var self`, as do struct constructors, setters and indexer setters; a read-only member keeps `self` by value, so it can be called on an rvalue | sem/desugar |
| `x++` as a value | the old value; `++x` the new one | `inc` is a statement | a statement increment of an integer variable, field or array element is `inc`/`dec`; of a property, an indexer or a float, `nsInc`/`nsDec`, which assign the stepped value (so the setter runs); in an expression the intrinsics' `nsPostInc`/`nsPreInc` (and `Dec`) | desugar/lib |
| Evaluation order | operands and arguments left to right: `x + F()` reads `x` before `F` runs | a variable operand is read when the operation happens, after the calls in it | an operand that is a variable, field or element, followed by one that may call, assign or step, is read first through `nsVal(x)`; so is the target of `x op= e` (`g += Bump()` adds to the old `g`) | desugar/lib |
| Compound targets evaluated once | `x op= y`, `x++`, `x ??= y`: the receiver and indices of `x` are evaluated once (12.21.4) | the lowering names the target twice, to read and to write | a receiver that calls or steps something, or is a property's value, and an index that does (or that the right side may change), is bound to a `let` first (`stabilize` in `desugar.nim`), so `a[k++] += 1` steps `k` once and `Obj().P++` calls `Obj` once; a struct receiver is never copied, its own parts are bound instead | desugar |
| Assignment as a value | `(x = e)` has the assigned value | an assignment is a statement | a parenthesised assignment lowers to a block expression that assigns and reads `x` back; an unparenthesised one in an expression is still a parse error | front/desugar |
| Multiple declarators | `int a = 1, b;` (locals and fields) | one name per `var` | one declaration per declarator, same type and modifiers | front |
| Discarding a result | any expression statement may drop a result | unused result is an error | every value-returning method, local function and generated proc is `{.discardable.}` (and the collection shims `{.push discardable.}`) | front/lib |
| `null` string | a string may be null | a Nim string cannot be nil | **divergence**: `null` converted to `string` is `""`, so `s == null` is `s == ""`, `s ?? b` is `b` for an empty `s`, and `s.Length` on a null string is 0 rather than a `NullReferenceException` | sem/desugar |

> The overflow / `checked` / `unchecked` rows all ride on **one** mechanism:
> Nim's `{.push overflowChecks: on|off.}` / `{.pop.}`, handled by `genPragma` at
> `compiler/ccgstmts.nim:1839` and read by codegen at `compiler/ccgexprs.nim:678`,
> `:712`, `:2959`. Verified: `unchecked { … }` ⟹ `{.push overflowChecks: off.} … {.pop.}`.
> Always emit the matched `{.pop.}`.

> What the nil check does *not* buy, because raising on a dereference is not the
> same as being null-safe: it stays silent when the null is only stored, passed or
> returned (the fault, if there is one, is later and somewhere else), when the
> receiver is non-nil but invalid -- `cast`, C interop, an uninitialised `alloc`, a
> data race -- and when a method reached as `this` never touches `self`. The build
> flag matters too: `-d:danger` and `--nilChecks:off` remove every check, so what a
> debug run catches can still crash in release. The compile-time counterpart,
> `--experimental:strictNotNil` (`compiler/nilcheck.nim`), catches null *flow*
> rather than the dereference, and is worth enabling on top.

---

## 8. Object model & polymorphism

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| Single inheritance `class C : B` | one base | ✅ v1 | front (→ Nim `object of`) |
| Multiple interfaces | many contracts | ✅ v1 | desugar (one table, converter and `nsAs<I>` override per class and interface; NS0535 for a missing member) |
| `virtual` methods | overridable | ✅ v1 | sem (`method`) |
| `override` | replace base | ✅ v1 | sem (`{.override.}`) |
| `abstract` methods/classes | no impl | ✅ v1 | sem |
| `sealed` | stop inheritance | ✅ v1 | sem |
| `new` (hide) | shadow | ✅ v1 | desugar (plain proc) |
| Dynamic dispatch | via vtable | ✅ v1 | Nim `method` |
| `base.M()` calls | call base impl | ✅ v1 | desugar (→ `procCall M(Base(self), ...)`; `base.P` likewise for a property) |
| `this` | self ref | ✅ v1 | desugar |
| `Object` base (`Equals`/`ToString`/`GetHashCode`) | universal methods | ✅ v1 | `ToString` is a base `method` in the intrinsics; every class N# compiles overrides it with its namespace-qualified name unless it (or a base) overrides it, and `$` calls it, so `Console.WriteLine(obj)` prints what C# prints |
| Boxing/unboxing (value↔`object`) | implicit | ✅ v1 | sem + lib (§4.4). Boxing a `T?` boxes its value, or is null when absent; `(int?)o` unboxes to a `T?`; a string literal's box is shared, so identical literals are one instance (ECMA 6.4.5.6) |
| Operator overloading | `operator +` | ✅ v1 | front |
| A member named like a type | `public Color Color { get; set; }`, a method `Item()` beside a class `Item` (members are in their type's declaration space, ECMA 7.3) | ✅ v1 | desugar: Nim allows no proc and type of one name in a module, so such a property, method or event (and a field of that name) is `nsM_Color` (`memberIdent`, and `renameMemberDecls` for the declarations); a library member named like a type of the compilation (`e.Message` beside a class `Message`) is called through its module (`System.Message(e)`), since `x.Message` would convert to the type |
| Method overloading | same name, diff sig | ✅ v1 | sem picks C#'s better function member (ECMA 12.6.4: an exact match, then the better conversion target -- the more specific type, signed over unsigned, `T?` over `object` -- then the normal form over the expanded `params` one, then the one that omits no default), and spells each numeric argument as the chosen parameter's type, so Nim's own overloading agrees; an overload whose defaults would take an argument count a sibling takes is declared without them, and each call sema resolves to it passes them by name (`noDefault`). A numeric argument applies to a numeric parameter only by an implicit conversion or as a constant in range |
| User-defined implicit conversions from a literal | `V2 c = 5;`, `Meters m = 3;` with `implicit operator Meters(double)` | ✅ v1 | sem: a numeric literal headed for a user type takes the operand type of the conversion C# uses, after a standard widening when needed (10.5.4), so the Nim converter applies |
| Named/optional/default args | `M(x: 1)` | ✅ v1 | sem (arguments mapped to parameters for overload matching, NS7036 for a missing one) + desugar (Nim's own named and default arguments) |
| `params` arrays | variadic | ✅ v1 | desugar: the parameter is an array (empty by default); the caller packs expanded arguments into a new one, or passes its own array, which the callee then shares. A lone last argument that is an array, `new[] { .. }` or `null` is the array itself (the normal form, ECMA 12.6.4.2) |
| Value parameters assigned | a value parameter is a local (ECMA 15.6.2.2) | a parameter is immutable | a parameter the body assigns, steps, passes by `ref`/`out`, deconstructs into, or (for a struct, tuple or `T?`) writes a field of or calls a method on, is shadowed by a local copy at the top of the body (`var p = p`): methods, constructors, operators, accessors, local functions, lambdas, and inside an iterator's closure | desugar |
| `ref` / `out` / `in` params | by-ref | ✅ v1 | desugar (`ref`/`out` → `var T`, `in` → a plain parameter; `out T x` at a call is declared before the statement; `out var x` takes the parameter's type -- for a generic method's type parameter, the type another argument of that parameter type gives it -- and is NS9999 when the method is the library's, which declares no `out` parameters yet) |
| `ref` locals and `ref` returns | `ref int r = ref a[i];`, `ref T F()` | ✅ v1 | desugar: a `ref` local is a pointer (`addr x`) every use dereferences, `r = ref y;` repoints it; a `ref` return is a `var T` result, which a caller may assign (`F() = 5`) or take by `ref`. A reference into an array element is a pointer into the array's elements |
| Discards `_` | `out _`, `_ = e;`, `(a, _) =>`, `var (x, _) = t` | ✅ v1 | sem + desugar (`out _` is a temporary of the parameter's type; `_ = e;` is `discard e`; both only while no variable `_` is in scope) |
| Extension methods | `static void M(this T)` | ✅ v1 | sem + desugar: declared in a non-generic static class (else NS1106), lowered as a plain proc over its `this` parameter (no typedesc), so `x.M(a)` is `M(x, a)` -- reached when `x`'s own type has no `M`, as C# prefers -- and `C.M(x, a)` names the same proc. A null receiver is not checked |
| `IDisposable` / `using` | deterministic cleanup | ✅ v1 | desugar/lib |
| `IEnumerable<T>` / `foreach` | iteration protocol | ✅ v1 | sem/lib |
| Covariance/contravariance | `in`/`out` | ✅ v1 | sem + lib: `interface I<out T>`/`delegate R D<in T>(T x)` record the variance; `IProducer<Cat>` converts to `IProducer<Animal>` (and `Func<Cat>` to `Func<Animal>`, `Action<Animal>` to `Action<Cat>`) through `nsVariant`, which rereads the value as the other instantiation, since C# allows variance only over reference type arguments and Nim represents those alike. Variance on a class, struct or method is NS1960; an `out T` taken as a parameter or an `in T` given back NS1961 (checked for `T` itself, not `T` inside another type). A variant conversion over an interface, `string` or array type argument, which Nim holds differently, is NS9999 |
| `static class` | container | ✅ v1 | see §4 |
| Object/collection `ToString` | `$` | ✅ v1 | desugar |

**Interface model (D2, revised): interface values with dynamic dispatch.**
The first plan made an interface a Nim `concept`, which gives `where T : I` but no
interface-typed values -- and `IShape s = ...`, `List<IShape>` and casting to an
interface are what C# code mostly does with one. Nim's single inheritance cannot
make an interface a second base type, so an interface value is a fat pointer:

```nim
type
  nsVT_IShape = object                  # one entry per member, over a RootRef
    nsReady*: bool
    f0*: proc (self: RootRef): float64 {.nimcall.}
  IShape = object
    nsObj*: RootRef                     # the object
    nsVt*: ptr nsVT_IShape              # its class's table for IShape
proc Area*(self: IShape): float64 = (self.nsVt.f0)(nsCheckNil(self.nsObj))
method nsAsIShape*(x: RootRef): IShape {.base.} = default(IShape)
```

A plain class has a table of its own for each interface it implements, inherited
ones included, and converting an object to the interface takes the table of the
object's own class (`method nsVtOf_IShape`, one dispatch per conversion). An entry
then calls that class's implementation directly, so an interface call is one
indirect call, as in .NET -- unless a generic class derives the class, whose objects
use the base's table, whose entries then dispatch again.

Each class naming `IShape` gets a lazily filled table whose entries call its own
members (so a `virtual` member dispatches further), a `converter nsToIShape`, which
is what lets a class value be passed, assigned, added to a `List<IShape>` or put in
an `IShape[]`, and an override of `nsAsIShape`, which is how `is`, `as` and casts
ask the *dynamic* type. An interface value converts to the interfaces it extends the
same way. A struct is boxed into `nsBox_S` (a copy, as C#'s box is), and
`(S)iface` unboxes. `null` is the empty value; `==` compares the objects. `R I.M()`
explicit implementations are reachable only through the table.

Generic interfaces (`IRepo<T>`) lower to generic tables and values; a class
implementing `IRepo<int>` gets `nsVtGet_C_IRepo_int` and `nsTo_IRepo_int`, so one
class may implement several instantiations. An interface value converts to an
interface it extends through the pointers its table keeps (`up0`, ...). A library
interface (`IComparable<T>`, `IEquatable<T>`, `IDisposable`, declared
`{.nsInterface.}` in the prelude) may be named in a base list; it is a contract the
generic code calls by name, not a value type (NS9999 if a value is declared with
one). A default interface method (C# 8) is `nsDefault_I_M(self: I, ...)`, whose
`this` is the interface value; a class that does not implement the member gets a
table entry calling it, and needs no implementation of its own. Static abstract
members (C# 11) are a contract only: an implementing type must declare a static
member of the name (NS0535), and `T.Zero`/`T.Combine(a, b)`/`a + b` in a method
constrained `where T : I<T>` bind statically when the generic is instantiated, so
they need no table slot. `is`, `as`, casts and type patterns against a generic interface
(`o is IBox<int>`) ask the object's class through `nsVtByKey`, a method every class
implementing an instantiation of a generic interface overrides: it answers that
instantiation's table by the type's name and passes any other name to its base.
An explicit implementation of one instantiation's member (`int IBox<int>.Get()`) is
filed under the instantiation's mangled name (`nsIBox_int_Get`), so a class may
implement `IBox<int>` and `IBox<string>` each its own way; explicit properties are
named the same way (`nsI_P`). Deferred: default methods in a generic interface and
static interface members with a body (NS9999).

---

## 9. Generics

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| Generic classes `Box<T>` | parameterised type | ✅ v1 | desugar (Nim generic object; members take the class's parameters first) |
| Generic methods `T F<T>(T x)` | - | ✅ v1 | desugar (explicit `F<int>(x)` parsed by C#'s type-argument rule; on an instance of a generic class the receiver's arguments are written too, since Nim infers none once any is given) |
| Multiple type params `Map<K,V>` | - | ✅ v1 | free |
| Type inference at call site | - | ✅ v1 | free |
| `where T : class` / `struct` | constraint | ✅ v1 (parsed; checked per instantiation by Nim) | desugar |
| `where T : new()` | ctor constraint | ✅ v1 | desugar (`new T()` → `nsCreate(T)`, which every class with a parameterless constructor declares) |
| `where T : Base` | base constraint | ✅ v1 | sem (typeclass) |
| `where T : IComparable` | interface constraint | ✅ v1 (parsed; members called by name per instantiation) | desugar |
| `where K : notnull` | nullness constraint | 🔜 later | sem |
| Multiple constraints | `where T : A, B` | ✅ v1 | sem |
| Generic delegates | `Func<T,R>` | ✅ v1 | lib + desugar (C# overloads `Func`/`Action` by arity; the library declares `Func2[T, R]` etc. and lowering picks the suffix matching the argument count) |
| Generic interfaces | `IEnumerable<T>` | ✅ v1 | desugar (generic tables, §8) |
| `default(T)` | default value | ✅ v1 | lib |
| Static members of generics | per-instantiation | ✅ v1 | desugar (a `{.global.}` inside a generic storage proc, initialised on first use); a static constructor is `nsStaticCtor_C[T]()`, run once per instantiation the first time its statics, static methods or constructors are used, as C# runs it |
| Variance `in`/`out` | - | 🔜 later | sem |
| Generic nested types | - | 🔜 later | sem |

**Note:** Nim generics are string/interning-based and powerful; most C# generics
map directly. The cost is in **constraints**, which map to Nim
`typeclass`/`concept` and need `sem` support.

---

## 10. Delegates, lambdas, events

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| `delegate R D(args);` | named type | ✅ v1 (3b) | front (→ `proc` type, `{.closure.}`) |
| `Func<...>` / `Action<...>` | built-in delegates | ✅ v1 | lib (`Func2[T, R]` ... `Action4`, picked by arity) |
| Lambda expressions | `x => e` | ✅ v1 | desugar (typed from the delegate it converts to: a declared local's type, or the parameter it is passed for, with the method's and class's type arguments substituted; for a library member the declaration's Nim parameter types, bound by the receiver's) |
| Closures (capture) | - | ✅ v1 (3b) | Nim closures. Each loop iteration has its own copy of the variables its body declares and of a `foreach` variable (ECMA 13.9.5), where Nim shares one environment per routine: such a variable a lambda captures is kept in a cell (`nsCellOf`, used as `x[]`), and the lambda is made by a factory taking the cells (`(proc (x: typeof(x)): auto = <lambda>)(x)`), so each closure keeps its iteration's and still sees later writes (`markLoopCells` in `desugar.nim`). A `for` variable stays shared, as in C#. A local function capturing such a cell takes it as a parameter after its own: a call passes the caller's, and the function as a delegate is made by the same factory a lambda is (`cellFuncDelegate`); its forward declaration goes after the last of those cells its block declares, which C# requires a call to follow |
| Lambda returning a lambda | `x => y => x + y` | ✅ v1 | sema: the inner lambda is typed from the delegate the outer one's result is, also through `return` |
| Statement-expression lambda for a `void` delegate | `Action a = () => cnt++;` | ✅ v1 | desugar: the body is a statement, its value dropped |
| `static` lambdas and anonymous methods (C# 9) | cannot capture | ✅ v1 | front: the modifier is read and changes nothing |
| Delegate `+` / `-` | combine / remove invocation lists | ✅ v1 | desugar: `nsCombine` / `nsRemove`, as `+=` / `-=` |
| Method group → delegate | `D d = M;` | ✅ v1 | desugar (a closure: `M(C, ...)` for a static method, the receiver read once for an instance one) |
| Multicast (combine) `+=` / `-=` | invocation list | ✅ v1 | lib: `nsCombine` makes a closure over the flattened invocation list of both sides, calling each in order and answering the last one's result (a null side is the other); `nsRemove` (`d -= h`) takes out the last run of delegates equal to `h`'s list, giving null when none remain, as `Delegate.Remove` does. A combined closure hands its list back when called in query mode, and only closures `nsCombine` made are asked. Two delegates are equal when they are the same closure, so a lambda or method group written again is a different delegate |
| `d.Invoke(args)`, `d?.Invoke(args)` | call | ✅ v1 | lib (`Invoke` calls the delegate, or each handler of an event); `x?.M()` as a statement does nothing for a null `x` |
| `event D E;` | pub/sub member | ✅ v1 | desugar + lib: the field holds `seq[D]`, its handlers; `E += h` / `E -= h` are `nsSubscribe`/`nsUnsubscribe` (the last equal handler leaves), raising it calls each in order, and with none it is null. Outside its type only `+=`/`-=` (NS0070). `EventHandler`, `EventHandler<T>`, `EventArgs` are declared |
| `event` add/remove accessors | custom | ✅ v1 | desugar: `event D E { add { ... } remove { ... } }` lowers to procs `nsAdd_E`/`nsRemove_E` over the receiver (a `typedesc` for a static event) and `value`, which `x.E += h` / `x.E -= h` call. It has no handlers of its own, so any other use, a call included, is NS0079; it declares both accessors (NS0065) |
| Anonymous methods `delegate { }` | - | ✅ v1 | see §7 |
| Delegate variance | `Action<Derived> = Action<Base>` | ✅ v1 | sem + lib (see §8 variance) |
| Expression trees | `Expression<Func<>>` | 🚫 out | - |

**Note:** Nim closures (`{.closure.}` procs) cover single-target delegates; a
combined delegate is another closure, and an event is the list of its handlers.

A lambda passed directly as an argument is typed from the parameter it is passed
for (`xs.Find(x => x > 4)`, `Apply(x => x * 3, 5)`); a delegate call used as a
statement drops its result through the intrinsics' `nsStmt`.

---

## 11. Exceptions

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| `throw e;` | raise | ✅ v1 | front (→ `raise`) |
| `try` / `catch` / `finally` | EH | ✅ v1 | front |
| `catch (T e)` typed | filter by type | ✅ v1 | front (→ `except T as e`) |
| `catch { }` catch-all | - | ✅ v1 | front |
| Custom exceptions `class E : Exception` | user types | ✅ v1 | front |
| `when` catch filters | conditional | ✅ v1 | desugar (see §7) |
| `InnerException`, `Message` | std props | 🔜 later | lib |
| Stack traces | - | ✅ v1 | free (Nim) |
| `try`/`finally` only | - | ✅ v1 | front |
| Re-throw `throw;` | rethrow | ✅ v1 | front |
| No checked exceptions | - | ✅ v1 | free |

**Note:** Nim exceptions are object hierarchies with a base type, so C#'s
`Exception`-derived hierarchy maps directly. Nim's exception handling is already
refined (the `cnif`/cgen machinery is exception-aware), so this is cheap.

---

## 12. Async & concurrency

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| `async` / `await` / `Task` / `Task<T>` | async model | 🔜 later | sem |
| `await foreach` | async streams | 🔜 later | sem |
| `Task.Run` | thread-pool | 🔜 later | lib |
| `lock` statement | mutex | ✅ v1 (single-threaded: the lock is always free; see §7) | desugar |
| `[ThreadStatic]` | TLS | 🔜 later | lib |
| `Interlocked` | atomics | 🔜 later | lib |
| Channels / actors | - | ➕ ext (later) | lib |
| Parallel `for` | `Parallel.For` | 🔜 later | lib |
| `async` methods returning `ValueTask` | - | 🔜 later | sem |

**Note:** Nim's concurrency model (`asyncdispatch`, threads, channels) differs
from C#'s `Task`-based model. Rather than fake it, N# v1 keeps **generators
(`yield`)** and defers `async/await` to a later designed mapping. This is a
deliberate scope cut.

---

## 13. Attributes

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| Custom attribute classes | metadata | ✅ v1 | a class deriving from `System.Attribute`; `[A]` resolves `AAttribute` then `A` (else NS0246) and must name an attribute class (NS0616). Without reflection an attribute has no effect, so its arguments are not evaluated, and `AttributeUsage` is not enforced. `[assembly: X]` is dropped |
| `[Obsolete("msg")]` | deprecation | ✅ v1 | sem: a call of an obsolete member or `new` of an obsolete class warns NS0618 (NS0612 without a message), and is the error NS0619 with `true` |
| Generic attributes (C# 11) | `[Tag<int>("x")]` on `class TagAttribute<T> : Attribute` | ✅ v1 | sem: the type arguments must match the class's parameters (NS0305; on a non-generic attribute NS0308); like any attribute, no runtime effect |
| `[DllImport("lib")]` | P/Invoke | 🔜 later (NS0246: the library declares no such attribute) | desugar (→ `{.importc,dynlib.}`) |
| `[StructLayout(LayoutKind.Sequential)]` | ABI layout | 🔜 later | desugar (→ `{.packed.}`) |
| `[Conditional("X")]` | call-site strip | 🔜 later | desugar |
| `[Serializable]`, `[STAThread]` | framework | ✅ v1 (accepted, no effect) | lib |
| Attribute *reflection* at runtime | `GetCustomAttributes` | 🚫 out | - |
| Built-in `[Flags]` on enums | - | ✅ v1 | desugar (see §4) |

**Note:** N# attributes are *compile-time* metadata only; no runtime reflection.
The compiler reads the ones that change what it does (`[Flags]`, `[Obsolete]`).

---

## 14. Interop (the foundation)

### 14.1 N# ↔ Nim

| Capability | Disposition | Mechanism |
|---|---|---|
| `using` a Nim module from N# | ✅ v1 | shared module graph |
| Nim `import`ing an N# module | ✅ v1 | shared module graph |
| Calling Nim procs from N# | ✅ v1 | free |
| Calling N# procs from Nim | ✅ v1 | free |
| Using Nim generics/macros from N# | ✅ v1 | free |
| Using Nim `template`s as functions | ✅ v1 | free |

### 14.2 N# ↔ C / C++

C++ is bound in N# itself, with ordinary C# declarations: a type marked
`[Native("Ns::Type", Header = "h.hpp")]` (from `NSharp.Interop`) is that C++ type,
and its members are `extern`. A program using a binding is built with the C++
backend (`nim cpp --exceptions:goto`, so the engine may build with
`-fno-exceptions`); `nsharp/tests/native/` holds a small test engine (`toybox/`), its
binding (`Toybox.ns`) and C++-driven tests (`run_native.sh`).

| Capability | Disposition | Mechanism |
|---|---|---|
| `[Native]` struct: fields, `extern` constructors, operators, `static extern` properties | ✅ v1 | desugar: an `importcpp` object; members are `importcpp` procs (`Ns::T(@)`, `(# + #)`, `Ns::T::P`) |
| `[Native]` class: fields, `extern` instance/static/generic methods | ✅ v1 | desugar: `importcpp` procs over `ptr T` (`#->M(@)`); a generic method takes one `typedesc` per type parameter, named in the pattern (`#->template M<'**2>(@)`); a result may be dropped |
| `[Native("pattern")]` on an `extern` member | ✅ v1 | the C++ call as an `importcpp` pattern (`Ns::Print("%s", @)`) |
| Handle classes: `Handle = "Ns::Id<{0}>"`, `SelfHandle = "id"` or `"#->GetId()"` | ✅ v1 | a variable of the class (or of an N# class deriving it) is the handle `NsH_<Class>[T]`; member access dereferences it, `null`/`== null`/`?.` mean "invalid", using an invalid one throws `NullReferenceException` (not under `-d:danger`); a handle is valid when its `explicit operator bool` says so, or when the binding's `Valid` pattern does (`Valid = "#.IsAlive()"`, `"Ns::World::Exists(#)"`), so a handle to an object the engine has destroyed reads as `null` if the test can tell; `null` is a default-constructed handle, or the binding's `Null` (`"Ns::Id<{0}>::Invalid()"`); the object is reached through the handle's `operator->`, or the binding's `Deref` (`"#.Get()"`, `"Ns::World::Find(#)"`); casts and upcasts convert between handles of one family; `this` as a value is its own handle through `SelfHandle`, since the engine may move the object; `SelfHandle` is a C++ pattern over the object (`#->GetId()`), or a member name standing for `#->name`, and since the generated code is the derived class's, what it names must be public or protected (without `SelfHandle`, `this` is only a receiver: NS9903 as a value). `new` of a class of a handle family is NS9901: the engine creates and owns it |
| Native classes with no handle | ✅ v1 | a plain C++ class, which N# owns when it makes one: a variable of it, or of an N# class deriving it, is an N# reference `NsH_<Root>[T]` (a pointer, and the box keeping the object alive; `lib/pure/nsharp/nsobj.hpp`), with C#'s class semantics (`a = b` shares, `==` is identity, `null`, `NullReferenceException`). `new C(args)` runs C++'s constructor (an `extern C(...)` in the binding, or the default one when it declares none) in a Nim-managed box with placement new, so neither a default nor a copy constructor is needed, and the last reference going runs its destructor. An N# class deriving one is made the same way with its own constructors, and `this` as a value keeps it alive through the box it records (`NsOwner`, which a C++ copy does not inherit); `this` of one the engine made (a `Stage`) is lent: a pointer with nothing keeping it alive. Passed to an `extern`, it becomes what the C++ parameter is -- `X*` (null allowed), or `X&`/`const X&`/`X` (null aborts) -- through a proxy with both conversions; a C++ template parameter cannot deduce through it. C++ keeping the pointer past the call is the binding's to avoid. Returned by an `extern`: by value (the default) it is constructed straight into a box N# owns (`new (box) T(call)`, elided in C++17, so a non-copyable class works); `[return: Borrowed]` takes a `T*` or `T&` C++ keeps owning, which nothing keeps alive (a copy N# owns is an `extern` returning one by value); `[return: Owned]` takes a `T*` C++ made with `new`, which N# deletes with the last reference (NS9912 elsewhere). Held in a field of a class the engine stores by value, it is an `NsField`. A base class without a default constructor is derived with `: base(args)` |
| Kept objects: `Stable = true`, `[Moves]` | ✅ v1 | a handle local (a local, or a `foreach` variable, of a class the engine owns) keeps the pointer its handle resolves to, in a hidden `nsP_x` beside it, from its first dereference until anything may have created, destroyed or moved an engine object: `a.x += a.vx` resolves once, not three times. It is dropped by a statement that may (resolving afresh inside it), by assigning the local or passing it `ref`/`out`, on entering a `catch` or `finally`, after a `yield`, and after a `using` disposal. What may: a call to a member of a native class, unless its binding says `Stable = true` (its members, constructors and destructor included, touch no engine object) and the member is not marked `[Moves]`; `new` of a native-derived class that is not `Stable`; an N# method, constructor or property whose body does (found by reading it, with every override of a `virtual` and every interface member taken to); a delegate, lambda or local function call; storing over an owned native object whose destructor is not `Stable`. Parameters and lambda bodies keep nothing; `-d:nsNoHandleCache` turns it off. A binding that says `Stable` of a class that does move objects is wrong in the way a wrong `Qualifiers` is: the compiler takes its word |
| `[OnHandle]` members | ✅ v1 | an `extern` instance method or property of a handle class marked `[OnHandle]` is the handle's, not the object's: called on the handle itself (`#.M(@)`, or its pattern), unchecked, so it works on an invalid handle (`e.IsAlive()`, `e.Id`); every class of the family has it, and on `this` it goes through `SelfHandle` (NS9903 without). NS9913 elsewhere |
| `extern` properties | ✅ v1 | `[Native(Get = "GetPosition", Set = "SetPosition")] public extern Vec3 Position { get; set; }`: each accessor is the C++ it names -- a member function's name (`#->GetPosition()`, `#->SetPosition(value)`; on a static property `Ns::T::GetX()`) or a pattern (`Get = "#->Children().size()"`). A plain identifier is a function's name; anything else is a pattern. Nothing is guessed: an accessor naming nothing is NS9914, except that a static property naming neither is the type's static member. An accessor takes its own `[return: Borrowed]`, `[return: Owned]` or `[return: CString(...)]` (`public extern Palette Featured { [return: Borrowed] get; }`), as a method returning the type does. `t.Position += v` gets and sets; `t.Position.x = 5` on a struct property is CS1612, as in C#. |
| `extern` indexers | ✅ v1 | `[Native(Get = "GetCell", Set = "SetCell")] public extern float this[int x, int y] { get; set; }`: Nim's `[]`/`[]=` over the C++ named -- a function taking the indices (and, setting, the value after them: `#->SetCell(x, y, value)`), or a pattern (`Get = "#->cells[#]", Set = "#->cells[#] = #"`); NS9914 for an accessor naming nothing |
| `string` results | ✅ v1 | an `extern` returning `string` gets a `const char*` from C++, or whatever `[return: CString("#.c_str()")]` reaches from what it returns (`"#.Data()"`, with `Length = "#.Size()"` for one that may hold a `'\0'`): no string class is special. The characters are copied into the N# string within the C++ expression that produced them (`nsCopyCStr`, nsobj.hpp), so a temporary they live in is still alive; null is `""`. A property's `Get` pattern may do the same (`"#->Describe().c_str()"`). NS9915 for the attribute elsewhere. A `string` argument reaches C++ as `const char*`, which `std::string`, `std::string_view` and most string classes take implicitly; for one that does not, `[CString("Text::Str(#, #len)")] string s` builds the C++ argument from the characters (`#`) and the length (`#len`), in place in the call (an immediately called lambda), so it lives exactly as long as the call. The characters are valid only during the call |
| N# class deriving a native class | ✅ v1 | desugar: a C++ struct deriving it (`object of T`, `exportc`); a method is a C++ member function (`{.member.}`), which a concept-checking engine finds by name; an `override` of a native `virtual` is a C++ override (`{.virtual.}`) |
| ... its fields | ✅ v1 | any type, with initializers. Plain data (numbers, `bool`, `char`, enums, native structs, handles) is a plain C++ member; a type Nim manages (`string`, an array, a `List<T>`, an N# class) is an `NsField<T>` (`lib/pure/nsharp/nsfield.hpp`), whose copy, move (`noexcept`) and destructor run Nim's hooks, so the engine's own copies, moves and destruction keep Nim's reference counts right while the class itself needs no special members (the rule of zero). Each module registers the hooks for its field types when it starts (the host calls `NimMain()` first). Initializers run in a generated C++ default constructor, which the engine's `T obj;` calls. Properties and generic instance methods are NS9999 |
| ... its constructors | ✅ v1 | C++ constructors (`{.constructor.}`), each starting with the field initializers; the engine runs one when its factory creates the object. A generic `extern` factory whose last parameter is `[Forward] params object[] args` (`T Spawn<T>([Forward] params object[] args) where T : Node`) passes the rest of its arguments to the C++ call as they are (a `varargs` `importcpp` proc), where the engine forwards them to `T`'s constructor (`T node(std::forward<Args>(args)...)`); they are checked against the constructors of the type argument for the result type (else the first), so a mismatch is CS1729/CS1503 at the call. A constructor body sees `this` as a member function's does, but the engine may set the object up only after constructing it, so `this` as a value or a native member there is a warning (NS9910); an exception that leaves one stops the program, since C++ cannot see it and the object would be half made. `: base(args)` is the C++ initializer list, so a native base needing arguments can be derived: a parameter passes as it is, any other argument is an exported function of the constructor's parameters the list calls (a computed string for a `const char*` base parameter is NS9999, its temporary would be gone); a binding may declare constructors on a handle class for this, which only `: base(...)` reaches. A static constructor runs after the static fields' initializers, when the module starts. `: this(...)` is NS9999; `[Forward]` anywhere else is NS9911. A `[Forward]` factory may return a class with no handle, `[return: Owned]` or `[return: Borrowed]` (a template passes the arguments on); by value it is NS9999, since its class is a type parameter |
| ... its interfaces | ✅ v1 | an interface value holds the object's handle (or N# reference) boxed, as it holds a struct, and each table entry calls the member on what the handle reaches, so a call on a destroyed engine object throws `NullReferenceException`; `is`, `as` and casts unbox it |
| ... `const`/`noexcept` overrides, `readonly` | ✅ v1 | a native method's C++ qualifiers are the binding's: `[Native(Qualifiers = "const noexcept")] public virtual extern int Score();`. An override repeats them itself, so C++ dispatches to it (`noexcept` too: the compiler keeps it in the member's signature). A `readonly` N# method is a `const` member function. In a const one, `this` cannot be changed: assigning its fields is NS9916, calling a member that is not const NS9917; the N# body runs through `const_cast`, so its managed fields are read as usual |
| ... generic classes | ❌ | C++ finds a concept's members and dispatches virtuals by a struct's name, one per instantiation, which a generic Nim type cannot be exported under, and Nim's C++ backend has no member or virtual functions on generic types: NS9999 |
| Exceptions where C++ calls N# | ✅ v1 | every place C++ enters N# -- a member function found by a concept, the override of a native virtual, an `[Export]` function, a constructor -- stops an exception there: C++ cannot see one (with goto exceptions it would stay pending through the engine's own code, failing the next N# call it makes). It goes to `nsOnUnhandled(where, message, type)`, a weak symbol whose default prints it and stops the program; an engine defining its own logs it its way, and if it returns, the entry point returns its default result and nothing is left pending. Each member function is two: the N# body (a member function C++ does not know, `nsM_M`), which N# calls, so its exceptions reach an N# `catch` as in C#, and the C++ one, which runs it behind the boundary |
| `[Export("name")]` on a static method | ✅ v1 | desugar: an `exportc` wrapper C++ calls; the host calls `NimMain()` first (`--noMain`) |
| `base.M()` on a native `virtual` | ✅ v1 | in an override, the C++ class's own function called without dispatch (`#->Ns::Base::M(@)`, a companion `nsBaseCall_C_M` of each native virtual), or an N# base's override |
| The host's memory: `-d:nimAllocPagesViaHost` | ✅ v1 | Nim's allocator takes its memory from the program embedding it instead of from the OS, which defines `void* nimHostAllocPages(size_t size, size_t alignment)` (page-aligned, `NULL` when out of memory) and `void nimHostDeallocPages(void* p, size_t size)` with C linkage. Nim asks for regions of 16 KB and more, growing with its use, and gives each back whole with the size it got; objects of up to a page are cut from them by Nim's own size classes, so the host sees few, large requests and allocation keeps its speed (binary trees: the same as from the OS, where `-d:useMalloc`, every object from `malloc`, is 40% slower). They are called from every thread that allocates, and before `NimMain` returns, so the host's allocator is ready before it. A plain Nim option (`lib/system/osalloc.nim`), for ARC/ORC |
| `extern "C"` functions, raw pointers, function pointers | 🔜 later | |
| C bindings (`[Native]` over a C struct and its functions) | 🔜 later | a C struct is a Nim `importc` object (`{.inheritable, pure.}` to derive it as a plain struct: no `of`, no methods, so no native virtuals); functions are `importc` procs, and handles are whatever the C API uses (an id, a pointer). An N# type deriving a C struct would hold Nim-managed fields as in C++, but C has no destructor to run them, so the binding names the C call that frees one (`Free = "ns_free"`) |
| `[StructLayout]` ABI match, `IntPtr` | 🔜 later | |

---

## 15. Standard library surface (the "N# BCL-lite")

N# ships a **prelude** (`lib/pure/ns/…`) that maps common C# BCL types onto Nim
stdlib so C# idioms feel native. All ✅ rows are `lib` (no compiler change).

| C# type / API | Disposition | Maps to (Nim) |
|---|---|---|
| `Console.WriteLine/Write/ReadLine` | ✅ v1 | `stdout.writeLine`/`readLine` |
| `string` members `.Length`, `.Substring`, `.IndexOf`, `.ToUpper/Lower`, `.Split`, `.Trim`, `.Contains`, `.Replace`, `.StartsWith`… | ✅ v1 | `lib` wrappers on Nim `string` |
| `string.Format`, `Join`, `IsNullOrEmpty` | ✅ v1 | `lib`; `Join` over an array, any collection or a dictionary's `Keys`/`Values`, with a `string` or `char` separator, each element as string concatenation renders it |
| `string.RuneCount` / `.Runes` (char count) | ✅ v1 | `lib` (N# helper; `.Length` is bytes, §4.4) |
| `T.Parse(s)`, `T.TryParse(s, out x)` on every integer type, `float`/`double`, `bool`, `char`; `double.IsNaN`/`IsInfinity`/`IsPositiveInfinity`/`IsNegativeInfinity`/`IsFinite` | ✅ v1 | `lib/pure/ns/System.nim`, over `typedesc[T]`; .NET's rules under en-US, the culture N# follows: an integer is white space, a sign and digits, a floating-point number also takes a point, an exponent, `,` group separators and `NaN`/`∞`, one too large becoming an infinity; `FormatException` / `OverflowException` with .NET's messages. A library member over a `typedesc` keeps its qualifier (`Parse(int32, s)`), and a member the library does not declare on a built-in type is CS0117 |
| `Math.*` | ✅ v1 | `lib` (Nim `math`) |
| `List<T>` | ✅ v1 | class over `seq[T]` (SS15.1) |
| `Dictionary<K,V>`, `KeyValuePair<K,V>` | ✅ v1 | class over `NsHashMap[K,V]` (`lib/pure/nsharp/hashmap.nim`, .NET's own hash table: entries in an array with a free list, prime-sized buckets, `FastMod`, an integer key its own hash); struct (SS15.1) |
| `HashSet<T>` | ✅ v1 | class over `NsHashMap[T, bool]`, the table `Dictionary` uses (SS15.1) |
| `SortedSet<T>`, `SortedDictionary<K,V>`, `SortedList<K,V>` | ✅ v1 | classes over sorted `seq`s (SS15.1) |
| `Queue<T>`, `Stack<T>` | ✅ v1 | classes over `Deque[T]` / `seq[T]` (SS15.1) |
| `LinkedList<T>`, `LinkedListNode<T>` | ✅ v1 | doubly-linked `ref object` nodes (SS15.1) |
| `PriorityQueue<TElement,TPriority>` | ✅ v1 | .NET's 4-ary min-heap (SS15.1) |
| `Predicate<T>`, `Comparison<T>`, `Converter<T,U>`, `Action<T>` | ✅ v1 | `proc` types in `System` |
| `Array` / `Sort` / `Reverse` | ✅ v1 | `lib` (`algorithm`) |
| `StringBuilder` | ✅ v1 | `lib` (`strutils`) |
| `Tuple<...>` | ✅ v1 | Nim tuple |
| `Nullable<T>` | ✅ v1 | `Option[T]` |
| `Exception` hierarchy | ✅ v1 | `lib` |
| `DateTime`, `TimeSpan` | 🔜 later | `std/times` |
| `Random` | ✅ v1 | `std/random` |
| `Convert.*` | ✅ v1 | `lib` |
| `IEnumerable<T>` / `ICollection<T>` / `IList<T>` / `IReadOnlyCollection<T>` / `IReadOnlyList<T>` / `ISet<T>` / `IReadOnlySet<T>` / `IDictionary<K,V>` / `IReadOnlyDictionary<K,V>` | ✅ v1 | values (SS15.1): `List`, arrays, `Dictionary`, `HashSet`, `Queue`, `Stack`, `LinkedList` and a dictionary's `Keys`/`Values` implement the ones .NET's do |
| LINQ (method syntax) | 🔜 later | iterator adapters |
| `File` / `Directory` / streams | 🔜 later | `std/os`, `std/streams` |
| `Regex` | 🔜 later | `std/re` |
| `GC.*` | 🚫 out | Nim manages memory |
| `Task`, `Thread`, `Interlocked` | 🔜 later | `std/*` |
| `Marshal`, `IntPtr` | 🔜 later | `lib` |
| `object` boxing helpers | ✅ v1 | `NsBox[T]`, `nsBox`, `nsUnbox`, `nsIsType` in the intrinsics |

**Naming:** do we keep C# names (`List`, `Count`, `Length`) or Nim names
(`seq`, `len`)? **Proposed:** keep **C# names at the source level** for
familiarity, implemented as `lib` wrappers. (Raise if you'd rather expose Nim
names.)

Members are resolved from those declarations, not from a table of names: the
frontend reads the prelude's own Nim sources (`bcl.nim`'s *surface*), so
`x.Length`, `.Count`, `.Message`, `int.MaxValue` and `String.Concat` are answered
by the proc the prelude declares, and lowering reaches it through Nim's dot-call.

### 15.1 Collections - pinned member surface (3b)

Every collection is a **class**, as in .NET: a `ref object` that owns its storage
(`seq`, `NsHashMap`, `Deque`) as a private field. So `var b = a;`
aliases one collection, `null` is a valid value, and the prelude type is exactly
what a user's own `class List<T>` would lower to. `KeyValuePair<K,V>` is the one
struct. C# properties (`Count`, `First`, `Keys`) are procs taking only the
receiver; the frontend resolves every member from these declarations, and nothing
in it names a collection.

Behaviour follows .NET where it is observable: `Dictionary` and `HashSet` enumerate
in .NET's order (insertion order, an entry added after a removal taking the place of
the last removed, the set operations removing in .NET's order); `Stack` enumerates and `ToArray`s top first; mutating a collection
inside its own `foreach` throws `InvalidOperationException`; a bad index throws
`ArgumentOutOfRangeException`, a missing key `KeyNotFoundException`, an empty
`Queue`/`Stack`/`LinkedList`/`PriorityQueue` `InvalidOperationException`, with
.NET's messages; `PriorityQueue` is .NET's own 4-ary heap, so equal priorities
leave in .NET's order. A parameter C# types as `IEnumerable<T>` takes an array or
any of these collections. Only these members exist:

| Type | Members (3b) |
|---|---|
| `List<T>` | `Add` `AddRange` `BinarySearch` `Clear` `Contains` `ConvertAll` `CopyTo` `Count` `Exists` `Find` `FindAll` `FindIndex` `FindLast` `FindLastIndex` `ForEach` `GetRange` `IndexOf` `Insert` `InsertRange` `LastIndexOf` `Remove` `RemoveAll` `RemoveAt` `RemoveRange` `Reverse` `Sort` `ToArray` `TrimExcess` `TrueForAll`, `[]`, `[]=` |
| `Dictionary<K,V>` | `Add` `Clear` `ContainsKey` `ContainsValue` `Count` `GetValueOrDefault` `Keys` `Remove` `TryAdd` `Values`, `[]`, `[]=`, `foreach` over `KeyValuePair<K,V>` |
| `KeyValuePair<K,V>` | `Key` `Value` |
| `KeyCollection`, `ValueCollection` (from `Keys`/`Values`) | `Count` `CopyTo`, `foreach`; live views of the dictionary |
| `HashSet<T>` | `Add` `Clear` `Contains` `Count` `ExceptWith` `IntersectWith` `IsProperSubsetOf` `IsProperSupersetOf` `IsSubsetOf` `IsSupersetOf` `Overlaps` `Remove` `RemoveWhere` `SetEquals` `SymmetricExceptWith` `ToArray` `UnionWith` |
| `SortedSet<T>` | the `HashSet<T>` members, plus `Max` `Min` `Reverse` |
| `SortedDictionary<K,V>` | the `Dictionary<K,V>` members, in key order |
| `SortedList<K,V>` | the `SortedDictionary<K,V>` members, plus `GetKeyAtIndex` `GetValueAtIndex` `IndexOfKey` `IndexOfValue` `RemoveAt` |
| `Queue<T>` | `Clear` `Contains` `CopyTo` `Count` `Dequeue` `Enqueue` `Peek` `ToArray` `TrimExcess` |
| `Stack<T>` | `Clear` `Contains` `CopyTo` `Count` `Peek` `Pop` `Push` `ToArray` `TrimExcess` |
| `LinkedList<T>` | `AddAfter` `AddBefore` `AddFirst` `AddLast` `Clear` `Contains` `CopyTo` `Count` `Find` `FindLast` `First` `Last` `Remove` `RemoveFirst` `RemoveLast` |
| `LinkedListNode<T>` | `Next` `Previous` `Value` |
| `PriorityQueue<E,P>` | `Clear` `Count` `Dequeue` `Enqueue` `EnqueueDequeue` `Peek` |

Deliberately deferred, with the reason recorded:

* **Overloads that differ only in argument type** are told apart by Nim, not by
  the frontend, which reads the first declaration of a name. The sema gate would
  therefore see `LinkedList<T>.Remove(node)` as returning `bool`, like
  `Remove(value)`; it runs correctly.
* **`LinkedListNode<T>.List`**: a Nim proc cannot share the name of the `List`
  type.
* **`TryDequeue`, `TryPeek`, `TryPop`, `Remove(k, out v)`**: not yet written
  (`Dictionary.TryGetValue` is).
* **`IComparer<T>`, `IEqualityComparer<T>`** are values like the collection
  interfaces below. `Comparer<T>.Default`/`Create`, `EqualityComparer<T>.Default`
  and `StringComparer.Ordinal`/`OrdinalIgnoreCase` implement them, and so may a
  user's class. They are taken by `List.Sort`, `List.BinarySearch`, `Array.Sort`
  and the `Dictionary`/`HashSet` constructors. Strings compare by Unicode code point
  and change case by Unicode's simple case mapping (`OrdinalIgnoreCase`, `ToUpper`,
  `ToLower`): .NET's ordinal comparison, over code points rather than UTF-16 code
  units. N# has no culture, so the default comparison (`string.Compare`,
  `CompareTo`, `Comparer<string>.Default`, `List<string>.Sort()`) is that one too,
  answering -1, 0 or 1; .NET's follows the current culture (`"apple"` before
  `"Banana"`), which `p3d/unicodecompare.csout` records.
* **A user's class implementing a library interface** (`IReadOnlyList<int>`,
  `IComparer<string>`) converts to it through the library's generic
  `nsTo<Interface>`. That builder calls the class's own members by name, and the
  class answers `is`/`as` for it through `nsKeysOf<Interface>`.
* **Keys** are hashed and compared as .NET does: an integer is its own hash, a
  class key uses its `GetHashCode`/`Equals` (the members' hash for a record), an
  interface value uses the object behind it, and a comparer replaces both.
* **The collection interfaces** (`IList<T>`, `ICollection<T>`, `IReadOnlyList<T>`,
  `IReadOnlyCollection<T>`, `ISet<T>`, `IReadOnlySet<T>`, `IDictionary<K,V>`,
  `IReadOnlyDictionary<K,V>`) are values, declared in the library the way a user
  interface lowers: an object holding the instance (`nsObj`) and a table of its
  members (`nsVt`), marked `{.nsInterface.}`. A table is built once per
  implementing type by a generic builder calling that type's own members by name;
  what the type cannot do throws what .NET throws (`Collection was of a fixed
  size.` for an array, `Mutating a key collection derived from a dictionary is not
  allowed.` for `Keys`). The compiler converts a collection to one through the
  library's `nsTo<Interface>` (as to `IEnumerable<T>`), and from an interface to one
  it extends (`IList<T>` to `ICollection<T>`); `is`/`as` ask the object through
  `nsVtByKey`, and for an array, whose type is the runtime's, the library answers by
  the element type the interface names (`nsLibAs`). A library interface declared
  without those fields (`IComparable<T>`) stays a contract a class is checked
  against by name.
* **LINQ**, `Capacity`, `AsReadOnly`, collection initialisers, constructing a
  collection from `Keys`/`Values`: see the deferred list in
  SS19.

---

## 16. N# extensions (beyond C#)

The "subset of C# **with cool extensions**" part. These are things Nim offers
that C# lacks, exposed deliberately.

| Extension | What it gives you | Disposition | Mechanism |
|---|---|---|---|
| **UFCS** `x.f(y)` ≡ `f(x, y)` | Free functions read like methods (also power extension methods) | ✅ v1 | free |
| **Tuples + multiple returns** | `(int, string) F()` | ✅ v1 | free |
| **Discriminated/variant types** | Sum types via Nim `object` variants + `case` | ✅ v1 | front/desugar |
| **`defer`** | Scope-exit cleanup (C# has only `using`) | ✅ v1 | front |
| **Compile-time functions** | `static`/`const` evaluated at CT | ✅ v1 | free (Nim `static`) |
| **`when defined(...)`** | Language-level conditional compilation | ✅ v1 | front (extends `#if`) |
| **Distinct types / units** | `type Meters = distinct float` | ✅ v1 | front |
| **Slices / views / ranges** | Zero-copy `openArray`, `toOpenArray` | 🔜 later | lib |
| **Iterators as first-class** | Generators inline + closure | ✅ v1 | free |
| **Named/default/optional args** | (also in modern C#) | ✅ v1 | free |
| **Operator overloading (full set)** | `..`, `[]`, `{}`, `in`, custom | ✅ v1 | front |
| **`inline` / `noinline`** | Perf hints for a game engine | ✅ v1 | free (nimcall) |
| **Memory hints `ref`/`ptr`/`sink`/`owned`** | Manual control at the C++ boundary | 🔜 later | front |
| **`Result<T,E>`-style error handling** | Exceptions-free path for game code | 🔜 later | lib |
| **Macros / templates** | Metaprogramming (advanced, opt-in) | 🔜 later | free (Nim) |
| **String interpolation with format spec** | `$"{x:F2}"` | ✅ v1 | desugar |
| **Pattern matching on variants** | `case` over tagged objects | ✅ v1 | desugar |
| **`borrow` / delegation** | Forward fields cheaply | 🔜 later | free |
| **Custom numeric literals** | units, fixed-point | 🔜 later | front/lib |

**Philosophy:** extensions should feel *C#-adjacent* (familiar), not alien. E.g.
`defer` and variant types are natural extensions of C# that a C# dev will grok.

---

## 17. Tooling & diagnostics

| Area | Goal | Disposition | Notes |
|---|---|---|---|
| Compiler invocation | `nim c app.ns` / `nim cpp app.ns` | ✅ v1 | extension dispatch in `syntaxes.nim` |
| Mixed projects | `.nim` importing `.ns` and vice-versa | ✅ v1 | shared module graph |
| **LSP** (completion, hover, goto-def, refs, outline, rename) | full support for `.ns` | ✅ v1 | via `nimsuggest`/`nimlangserver`; requires extension-aware parse |
| Syntax highlighting | `.ns` grammar for VS Code et al. | ✅ v1 | TextMate/Tree-sitter (client side) |
| Error style | mirror C# compiler message *text* | ✅ v1 | code leads the message: `app.ns(15, 13) Error: NS0246: The type or namespace name 'X' could not be found` |
| Error codes | mirror C# | ✅ v1 | the digits are C#'s code for the same condition (`NS0246` is `CS0246`); `NS9999` is the single code for a construct N# does not support yet, and a rule C# does not have (native interop's) takes a code from `NS9901` up, clear of the `CS9xxx` codes C# keeps adding. `compiler/nsharp/diagnostics.nim` owns the table, and `run_cs.sh` checks each `.fail` marker against the code Roslyn reports |
| Formatter | `nph`/custom | 🔜 later | Nim tooling is Nim-syntax |
| Debugger | native DWARF/PDB | ✅ v1 | Nim emits standard debug info |
| Package manager (Nimble) | `.ns` sources in packages | 🔜 later | - |
| REPL / scripting mode | interactive | 🔜 later | ties to execution model |
| Build system integration (CMake/engine) | generate libs/objects | 🔜 later | ties to execution model |

A diagnostic's digits are the C# code for the same condition. `NS9999` is the one
code for every construct N# does not support yet, so closing a gap retires no code,
and a rule of N#'s own, which C# does not have, takes a code from `NS9901` up: the `CS9xxx` band below it is the C# compiler's, and it keeps growing.
`compiler/nsharp/diagnostics.nim` is the source of truth for the text as well as the
code:

| N# | C# | Condition |
|---|---|---|
| `NS0029` | CS0029 | a value cannot be converted to the type expected of it (an initialiser, an assignment, a `return`, a condition, or `throw`) |
| `NS0037` | CS0037 | `null` for a non-nullable value type |
| `NS0122` | CS0122 | a member is inaccessible |
| `NS0155` | CS0155 | a `catch` names something that is not an `Exception` |
| `NS0115` | CS0115 | `override` with no virtual member to override |
| `NS0131` | CS0131 | assigning a `const` |
| `NS0144` | CS0144 | `new` on an abstract class |
| `NS0145` | CS0145 | a `const` field without a value |
| `NS0191` | CS0191 | assigning a `readonly` field outside a constructor |
| `NS0198` | CS0198 | assigning a `static readonly` field outside the static constructor |
| `NS0238` | CS0238 | `sealed` on a member that is not an override |
| `NS0239` | CS0239 | overriding a `sealed` override |
| `NS0246` | CS0246 | a `using` names no namespace or module |
| `NS0500` | CS0500 | an abstract member with a body |
| `NS0501` | CS0501 | a non-abstract method without a body |
| `NS0509` | CS0509 | deriving from a `sealed` class |
| `NS0535` | CS0535 | a class leaves an interface member unimplemented |
| `NS0506` | CS0506 | `override` of a member that is not virtual |
| `NS0513` | CS0513 | an abstract member in a non-abstract class |
| `NS0534` | CS0534 | a concrete class leaves an inherited abstract member unimplemented |
| `NS0266` | CS0266 | a numeric value would narrow implicitly; a cast is needed |
| `NS0305`/`NS0308` | CS0305/CS0308 | an attribute's type arguments do not match its class |
| `NS9054` | CS9054 | a `file` type nested in another type |
| `NS9023`/`NS9024`/`NS9025` | CS9023/CS9024/CS9025 | a `checked` operator that cannot be checked, or has no unchecked version |
| `NS0746`/`NS0828`/`NS0833` | CS0746/CS0828/CS0833 | an anonymous type member with no name, no type, or a repeated name |
| `NS0847` | CS0847 | a multi-dimensional initializer whose rows differ in length |
| `NS1960`/`NS1961` | CS1960/CS1961 | variance where it may not stand, or a variant parameter used against its variance |
| `NS8795` | CS8795 | a partial method that must be implemented has no implementation |
| `NS0065`/`NS0079` | CS0065/CS0079 | an event with accessors that lacks one, or is used other than by `+=`/`-=` |
| `NS0574`/`NS0575` | CS0574/CS0575 | a finalizer not named after its class, or in a struct |
| `NS9998` | - | warning: a finalizer, which never runs in N# |
| `NS9901` | - | `new` of a class of a native handle family: the engine creates it |
| `NS9902` | - | retired: `this` in a family with no handle is now an N# reference |
| `NS9903` | - | `this` as a value when the handle class names no `SelfHandle` |
| `NS9904` | - | an `extern` member outside a `[Native]` type |
| `NS9905` | - | retired: a binding may declare constructors on a handle class, for `: base(...)` |
| `NS9906` | - | `[Export]` on anything but a non-generic static method |
| `NS9907` | - | a `[Native]` type deriving a type that is not `[Native]` |
| `NS9908` | - | a member of a `[Native]` type that is not `extern`, or has a body |
| `NS9909` | - | a static or initialised field in a `[Native]` type |
| `NS9910` | - | warning: `this` as a value, or a native member, in a constructor of a class deriving a native one, which the engine may not have set up yet |
| `NS9913` | - | `[OnHandle]` on anything but an `extern` instance member of a handle class, or on only some overloads of a name |
| `NS9914` | - | an `extern` property accessor that names no C++ function (`[Native(Get = .., Set = ..)]`) |
| `NS1612` | CS1612 | assigning to a field of the struct value a property returns |
| `NS9915` | - | `[CString]` on anything but the `string` result or a `string` parameter of an `extern` method, or without its pattern |
| `NS9916`/`NS9917` | - | in a const member function (the override of a const C++ function, or `readonly`): assigning a field, or calling a member that is not const |
| `NS9912` | - | `[return: Borrowed]`/`[return: Owned]` on anything but an `extern` method returning a native class with no handle, or both |
| `NS9911` | - | `[Forward]` on anything but the last, `params object[]`, parameter of a generic `extern` method |
| `NS0019`/`NS0023` | CS0019/CS0023 | an operator applied to operands it does not take (`&&` on ints, `-` on a string) |
| `NS0021`/`NS1579` | CS0021/CS1579 | indexing or `foreach` over a value that has neither |
| `NS0026`/`NS0120` | CS0026/CS0120 | `this` or an instance member used in a static context |
| `NS0030`/`NS0173` | CS0030/CS0173 | a cast with no conversion; a `?:` whose branches share no type |
| `NS0100`/`NS0101`/`NS0102`/`NS0111` | CS0100/CS0101/CS0102/CS0111 | a parameter, type, member or signature declared twice |
| `NS0103`/`NS0841` | CS0103/CS0841 | a name that is not declared, or used before its declaration |
| `NS0117`/`NS1061` | CS0117/CS1061 | a type or value with no member of that name |
| `NS0119`/`NS0201` | CS0119/CS0201 | a type used as a value; an expression that is not a statement |
| `NS0123`/`NS0428`/`NS1593`/`NS1660` | CS0123/CS0428/CS1593/CS1660 | a method group or lambda that does not fit the delegate or value it is converted to |
| `NS0126`/`NS0127`/`NS0161` | CS0126/CS0127/CS0161 | a `return` with or without a value against the method's type; a path that returns nothing |
| `NS0128`/`NS0136` | CS0128/CS0136 | a local declared twice, or shadowing an enclosing one |
| `NS0132` | CS0132 | a static constructor with parameters |
| `NS0133` | CS0133 | a `const` local initialised by something not constant |
| `NS0139` | CS0139 | `break`/`continue` outside a loop (a lambda body included) |
| `NS0149`/`NS0154` | CS0149/CS0154 | calling a value that is no delegate; reading a set-only property |
| `NS0152`/`NS0163`/`NS8070`/`NS9135` | CS0152/CS0163/CS8070/CS9135 | a repeated or non-constant `case` label; a section that falls through |
| `NS0165`/`NS0177` | CS0165/CS0177 | a local read, or a method left, before definite assignment (`compiler/nsharp/flow.nim`) |
| `NS0176` | CS0176 | a static member reached through an instance |
| `NS0452`/`NS0453` | CS0452/CS0453 | a type argument that breaks a `class`/`struct` constraint |
| `NS0547` | CS0547 | a `void` property |
| `NS0664` | CS0664 | a double literal where a `float` or `decimal` is wanted |
| `NS0723` | CS0723 | a variable of a static class |
| `NS0738` | CS0738 | an implicit interface implementation with another return type |
| `NS0815`/`NS0818` | CS0815/CS0818 | `var` with no value, or with `null`/`void` |
| `NS1002` | CS1002 | a missing `;` |
| `NS1501`/`NS1503` | CS1501/CS1503 | no overload takes this many arguments, or an argument does not convert (library methods and explicit type arguments included) |
| `NS1510`/`NS1620` | CS1510/CS1620 | `ref`/`out` on a non-variable, or missing where the parameter needs it |
| `NS1656` | CS1656 | assigning a `foreach` variable |
| `NS1721`/`NS0527` | CS1721/CS0527 | two base classes, or a class in a struct's or interface's base list |
| `NS1739` | CS1739 | a named argument no overload has |

Every check reports only when it is certain; what N# cannot classify is left to Nim.
`run_diag.sh` compares the code N# reports on each wrong program in
`tests/diag/cases` with Roslyn's, including a held-out set (`h_*`) written apart
from the checks, so a regression from a matching code fails the gate.
| `NS0616` | CS0616 | an attribute names a class that does not derive from `Attribute` |
| `NS0618`/`NS0612`/`NS0619` | CS0618/CS0612/CS0619 | a use of an `[Obsolete]` member or class |
| `NS0070` | CS0070 | an event used outside its type other than by `+=`/`-=` |
| `NS0200` | CS0200 | a get-only property assigned outside its constructors |
| `NS8852` | CS8852 | an `init` property assigned outside an initialiser or constructor |
| `NS9035` | CS9035 | an object initialiser omits a `required` member |
| `NS8858` | CS8858 | `with` on a class that is not a record |
| `NS8862` | CS8862 | a constructor of a type with a primary constructor that does not chain to it |
| `NS9176` | CS9176 | a collection expression without a target type |
| `NS1674` | CS1674 | what `using` disposes does not implement `IDisposable` |
| `NS1621` | CS1621 | `yield` inside a lambda |
| `NS1624` | CS1624 | `yield` in a member whose return type is not `IEnumerable<T>`/`IEnumerator<T>` |
| `NS1021` | CS1021 | an integer literal is too large |
| `NS1029` | CS1029 | `#error` |
| `NS1030` | CS1030 | `#warning` (a warning) |
| `NS1032` | CS1032 | `#define`/`#undef` after the file's first token |
| `NS1056` | CS1056 | a character C# has no token for |
| `NS1001` | CS1001 | identifier expected |
| `NS1002` | CS1002 | `;` expected |
| `NS1003` | CS1003 | syntax error, a token expected |
| `NS1026` | CS1026 | `)` expected |
| `NS1501` | CS1501 | no overload takes this many arguments |
| `NS1503` | CS1503 | an argument cannot be converted to what the overload's parameter takes |
| `NS1513` | CS1513 | `}` expected |
| `NS1514` | CS1514 | `{` expected |
| `NS1515` | CS1515 | `in` expected |
| `NS1519` | CS1519 | invalid token in a member declaration list |
| `NS1525` | CS1525 | invalid expression term |
| `NS1729` | CS1729 | a type has no constructor that takes this many arguments |
| `NS2001` | CS2001 | source file could not be found |
| `NS7036` | CS7036 | an argument list fell short of the one candidate's parameters, naming the first parameter it left out; also a constructor that must call a base constructor |
| `NS8632` | CS8632 | a `?` was written on a type that is nullable already (a warning) |
| `NS9001` | - | the parser made no progress |
| `NS9999` | - | a construct N# does not support yet |

`NS7036` is one code for both conditions because Roslyn gives one code for both:
which candidate an argument list fell short of is what the message names.

An error Nim raises on the lowered code (an undeclared name, a type mismatch, a bad
arity the frontend could not see) still prints Nim's own text and carries no `NS`
code. What the frontend *can* see it now reports first, with C#'s code: the type of
an argument, an initialiser, an assignment, a `return`, a condition and a `throw`;
the arity of a call and of a `new`; and the type a `catch` names.

A `.fail`, `.unsupported` or `.warn` marker may name the code it expects:

```
This test must fail to compile: it accesses a private base-class member.
code: NS0122
```

`run.sh` then requires that code in the compiler output, and `run_cs.sh` requires
the digits to appear among the codes Roslyn reports for the same file, skipping the
reserved band.

A `.warn` marker is the same contract for a diagnostic that must *not* be fatal: the
test compiles and its stdout is compared as usual, and the compile is repeated with
warnings enabled to require the code.

```
This test must compile and run, but its compilation must report a warning.
code: NS8632
```

When N# deliberately renders something differently, the test carries a `.csout` file
holding what C# produces, and `run_cs.sh` requires that instead of the `.out`:

```
flag=true       # the .out, since N# writes a bool the way Nim does
flag=True       # the .csout, which is what C# prints
```

---

## 18. Open decisions log

| # | Decision | Resolution | Blocking |
|---|---|---|---|
| **D1** | Case sensitivity | ✅ **Case-sensitive**; `IdentCache` mode + case-preserving hash (§3.1) | lexer, `idents` |
| **D2** | Interface model | ✅ **Static interfaces = concepts** (v1); dynamic values → v2 (§8) | sem |
| **D3** | Method resolution | ✅ member-first, then UFCS fallback | sem |
| **D4** | Namespace ↔ module | ✅ namespace = one generated module, cycles via `{.cyclic.}` (§5.1.1) | front |
| **D5** | Entry point | ✅ both top-level statements and `Main` | parser (top-level statements become `static void Main(string[] args)` of a synthesized `Program` in the global namespace, as C# defines them; their local functions are `Main`'s, declared forward so a call may precede them) |
| **D6** | Null model | ✅ `nil`-able refs, `?` annotation; `Option[T]` for `T?`; `null` deref → `NullReferenceException` (§4.4) | lib |
| **D7** | `decimal` | ✅ later (lib), not core | lib |
| **D8** | Error codes/style | ✅ codes mirror C#'s digits; `NS9999` for what is not supported yet, `NS99xx` for N#'s own rules (§17) | tooling |

**Resolved this round:** `char` = 1 byte; `string` = Nim UTF-8 mutable (§4.4);
overflow default unchecked + `checked`/`unchecked` via `push`/`pop` (§7.3);
`unsafe` pointers in v1; `object` = reference base with boxing, values boxed;
interfaces = static concepts; identifiers ASCII-only; `#region` ignored;
`stackalloc`/`fixed`/`ref struct` out; `Nullable<T>` → `Option[T]` (v1);
`Result<T,E>` later. **All of D1–D8 are resolved.** Remaining *non-blocking*
follow-ups: inheritance-scoped `protected` (v2) and the depth of `sem`-error
remapping (D8).

---

## 19. Proposed v1 scope summary

### ✅ In v1 - "N# you can ship a game script in"
- Lexer/parser: braces, semicolons, full C# operator set, comments, literals,
  verbatim + interpolated strings, `#if` → `when`, **case-sensitive identifiers**.
- Types: built-ins, `char` (1 byte), `string` (Nim UTF-8), `class`/`struct`,
  `enum`, tuples, arrays, generics (incl. constraints), `delegate`/lambdas/
  `Func`/`Action`, `Nullable<T>` → `Option[T]`.
- Declarations: namespaces, `using`, fields, `const`/`readonly`/`static`,
  methods, constructors, **properties (auto/computed/expression-bodied)**,
  operators, access modifiers (public/private/internal/protected).
- Object model: single inheritance, virtual/override/abstract/sealed, `base`,
  dispatch, `ToString`/`Equals`; **static interfaces (concepts)**.
- Statements: if/switch/while/do-while/for/foreach, break/continue/return,
  try/catch/finally/throw, `using`, `yield`/iterators, local functions,
  `checked`/`unchecked`.
- Expressions: full operators, `?:`, `?.`/`??`/`??=`, `is`/`as`, object
  initializers, `typeof`/`nameof`/`sizeof`/`default`, string interpolation.
- Exceptions: C#-style hierarchy.
- **Unsafe/pointers:** `T*`, `&`, `*` deref, `cast`, function pointers.
- **Interop: Nim ↔ N# and C ↔ C++ ↔ N# as a first-class v1 feature.**
- Prelude library: Console, string/math helpers, List/Dictionary/HashSet/Queue/
  Stack, Exception hierarchy.
- Tooling: `.ns` LSP support, `.ns` highlighting, C#-style diagnostics.

### 🌱 Extensions landing in v1
UFCS, tuples/multiple returns, variant types, `defer`, compile-time functions,
`when defined(...)`, distinct types, full operator overloading, `inline`.

### 🔜 Deliberately deferred
`async`/`await`, LINQ (query + method), records, advanced pattern matching,
`decimal`, variance, dynamic
interface values, universal value boxing, `fixed`/`stackalloc`/`ref struct`,
reflection, threads, static constructors,
finalizers, `Span<T>`, `StringBuilder`-adjacent IO, `Result<T,E>`, formatter, REPL.

### 🚫 Out
`dynamic`, expression trees, `goto`, runtime attribute reflection, `GC.*`,
`#region`, .NET BCL, assemblies.

---

## 20. Next steps

1. **Decisions frozen:** D1–D8 resolved (see §18).
2. **Glossary frozen:** see [`GLOSSARY.md`](GLOSSARY.md) - the lexer target.
3. **Architecture frozen:** see [`ARCHITECTURE.md`](ARCHITECTURE.md) - the
   minimal-diff plan for trivially backporting upstream changes.
4. Phase 0 - extension plumbing in `compiler/{syntaxes,options,idents}.nim` +
   `compiler/nsharp/` scaffolds, so `nim c hello.ns` compiles a trivial `Main`.
5. Then grow the grammar in the order the phases were costed.

---

*Change log*
- **v1.2** - resolved D6 (null model), D8 (error codes), `protected`
  (module-scoped approximation), and `.Length` = bytes + `RuneCount`; added
  [`GLOSSARY.md`](GLOSSARY.md) and [`ARCHITECTURE.md`](ARCHITECTURE.md); updated
  §2/§4/§5.5/§7.3/§17/§18/§20. All D1–D8 now resolved.
- **v1.1** - applied review decisions: case-sensitive identifiers (§3.1);
  1-byte `char` + Nim UTF-8 mutable strings (§4.4); `object` = reference base with boxing,
  boxing deferred (§4.4); interfaces = static concepts + anonymous concepts
  (§8); all generic constraints in v1 (§9); `checked`/`unchecked` promoted to v1
  via `{.push overflowChecks.}` (§6, §7.3); `unsafe` pointers in v1 (§14.2);
  `Nullable<T>` in v1; `Result<T,E>`/`#region`/`stackalloc`/`fixed`/`ref struct`
  out or later; ASCII-only identifiers; new §7.3 semantic-traps table.
- **v1 (first draft)** - initial catalog: lexical, types, declarations, statements,
  expressions, object model, generics, delegates, exceptions, async, attributes,
  interop, stdlib, extensions, tooling, open decisions, v1 scope.

*End of document.*

