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
| D4 | **Namespace ↔ module** | ✅ namespace = generated decl/impl/barrel (§5.1.1) | `front` |
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
| Integer literals `123`, `0xFF`, `0b1010`, `1_000` | dec/hex/bin, separators | ✅ v1 | front |
| Integer suffixes `u`, `l`, `ul` | unsigned/long | ✅ v1 | front |
| Real literals `1.5`, `1e10`, `.5` | floats | ✅ v1 | front |
| Real suffixes `f`, `d`, `m` | float/double/decimal | ✅ v1 (`f`,`d`); `m` 🔜 (D7) | front |
| Char literals + escapes `'\n'`, `'\u0041'` | char | ✅ v1 | front |
| String literals + escapes | `"..."` | ✅ v1 | front |
| Verbatim strings `@"..."` | no escaping, `""` = quote | ✅ v1 | front |
| Interpolated strings `$"...{x}..."` | format holes | ✅ v1 | front/desugar |
| Raw strings `"""..."""` (C# 11) | multiline raw | 🔜 later | front |
| UTF-8 strings `u8"..."` | byte spans | 🔜 later | front |
| Preprocessor `#if/#elif/#else/#endif/#define/#undef` | conditional compile | ✅ v1 (maps to Nim `when`) | front/desugar |
| `#region/#endregion` | folding only | 🚫 out (ignored) | front |
| `#error`, `#warning` | diagnostics | ✅ v1 | front |
| `#pragma`, `#line` | compiler hints | 🔜 later | front |
| `goto` + labels | jump | 🚫 out | - |
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
| `object` (universal base) | ✅ v1 (limited) | ref base `RootObj`; value boxing 🔜 (§4.4, §8) |
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
| Arrays `T[]` | 1-D array | ✅ v1 | front (→ `seq`/`array`) |
| Multi-dim arrays `T[,]` | rectangular | 🔜 later | lib |
| Jagged arrays `T[][]` | array of arrays | ✅ v1 | front/lib |
| `ValueTuple` `(int, string)` | tuples | ✅ v1 | desugar (→ Nim tuple) |
| `List<T>`, `Dictionary<K,V>`, `HashSet<T>`, `Queue<T>`, `Stack<T>` | collections | ✅ v1 | lib |
| `Span<T>`, `Memory<T>` | views | 🔜 later | lib |
| `Nullable<T>` / `int?` | nullable value | ✅ v1 | lib (→ `Option[T]`) |
| Nullable reference types `string?` | NRT annotations | 🔜 later | sem |
| `object`-typed boxes | boxing | 🔜 later | sem |
| `IEnumerable<T>` etc. | interfaces | ✅ v1 (static/concept) | sem/lib |
| Pointers `T*`, `&`, `*`, `cast` | unsafe | ✅ v1 | front (→ `ptr`/`addr`/`[]`/`cast`) |
| `Func<>`, `Action<>` | delegate types | ✅ v1 | lib (→ `proc` types) |
| Tuples as return values | multiple returns | ✅ v1 | free |
| `record` / `record struct` | value records | 🔜 later | desugar |
| `ref struct`, `stackalloc`, `fixed` | stack-only | 🚫 out | front |

### 4.3 User-defined types

| Feature | C# meaning | Disposition | Maps to |
|---|---|---|---|
| `class` | reference type | ✅ v1 | `ref object` |
| `struct` | value type | ✅ v1 | `object` |
| `interface` | contract | ✅ v1 (static) | `concept` (see §8) |
| `enum` | named int constants | ✅ v1 | Nim `enum` (int-backed 🟡) |
| `[Flags] enum` | bit flags | 🔜 later | `set` |
| `delegate` declaration | named function type | ✅ v1 | `proc` type alias |
| Generic types | `List<T>` | ✅ v1 | Nim generics |
| Nested types | inner class | 🔜 later | - |

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
Storing value types (`int`, `struct`) in an `object` - real boxing - is deferred.

---

## 5. Declarations & members

### 5.1 Compilation units, namespaces, `using`

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| Compilation unit = file | one file = one unit | ✅ v1 | front |
| `namespace X { ... }` | declaration space | ✅ v1 (→ module/scope) | front |
| File-scoped namespace `namespace X;` | C# 10 | 🔜 later | front |
| `using System;` | import namespace | ✅ v1 (becomes an `import`) | front |
| `using Alias = X.Y;` | namespace alias | ✅ v1 (imports the target) | front |
| `using Alias = SomeType;` | alias of a type | 🔜 later | front |
| `using static T;` | import members | 🔜 later | front |
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
namespace alias is only an import of its target, and why `using A = List<int>;` is
reported rather than lowered: a type alias has no qualifier to drop.

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

The frontend therefore emits each *used* namespace as three generated Nim
modules (`compiler/nsharp/nsgen.nim`). `<P>` is the namespace's path, so
`namespace UI` gives `UI` and `namespace A.B` gives `A/B`:

| Generated | Contents | Why |
|---|---|---|
| `<P>_decl.nim` | every type of the namespace, in **one** type section | Nim resolves mutually recursive types inside a single section |
| `<P>_impl.nim` | every proc, forward declared then defined | all implementations in one module, so a method in one file can call one in another |
| `<P>.nim` | barrel: `import`/`export` both | this is what `using P;` resolves to (`using A.B` -> `A/B`); a plain `.nim` consumer may import it too |

The decl/impl split additionally breaks a common cross-namespace cycle: if A's
methods use B's types and B's methods use A's types, `A_impl` imports only
`B_decl` and `B_impl` imports only `A_decl` - acyclic.

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
as `P.Gadget`. A sibling `<N>.ns` file takes precedence over the generated barrel.
Mutual references across two namespaces still cycle, because Nim has no
cross-module forward declaration for procs and resolves mutually recursive types
only within one section; such a cycle is reported as a recursive module dependency
and the namespaces must be merged or layered.

### 5.2 Type declarations

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| `class C : Base, IFoo { }` | class decl | ✅ v1 | front |
| `struct S { }` | value type | ✅ v1 | front |
| `interface I { }` | contract | ✅ v1 (static) | desugar → `concept` (see §8) |
| `enum E { A, B }` | enum | ✅ v1 | front |
| `delegate R D(args);` | func type | ✅ v1 | front |
| `record`, `record struct` | data classes | 🔜 later | desugar |
| `partial class` | split decl | 🚫 out (argue) | - |
| Nested types | inner | 🔜 later | - |
| `abstract class` | non-instantiable | ✅ v1 | front |
| `sealed class` | non-inheritable | ✅ v1 | front |
| `static class` | no instances | 🔜 later (→ module) | front |

### 5.3 Members

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| **Fields** `int x;` | data member | ✅ v1 | front (→ `nkIdentDefs`) |
| `const` fields | compile-time const | ✅ v1 | front (→ `const`) |
| `readonly` fields | assign-once | ✅ v1 | desugar (→ `let`/guard) |
| `static` fields | type-level | ✅ v1 | front (→ global/pragma) |
| `static readonly` | type-level const | ✅ v1 | desugar |
| **Methods** `R M(P a) { }` | method | ✅ v1 | front (→ `proc`) |
| Expression-bodied method `=> e;` | `R M() => e;` | ✅ v1 | desugar |
| `static` methods | type-level | ✅ v1 | front |
| `virtual` / `override` / `abstract` | dispatch | ✅ v1 | sem (`method`) |
| `sealed override` | stop override | 🔜 later | sem |
| `new` (hide) | shadow base | 🔜 later | sem |
| **Constructors** `C(a) { }` | init | ✅ v1 | desugar (→ `proc new`) |
| `this(...)` chaining | ctor call | ✅ v1 | desugar |
| `base(...)` in ctor | base ctor | ✅ v1 | desugar |
| Static constructor `static C() { }` | type init | 🔜 later | desugar |
| Primary constructors (C# 12) | `class C(int x)` | 🔜 later | desugar |
| **Destructor/Finalizer** `~C() { }` | cleanup | 🔜 later | sem (`=destroy`) |
| **Properties** (see §5.4) | accessors | ✅ v1 | desugar |
| `this[...]` indexer | indexer | ✅ v1 | desugar (→ `[]`) |
| Named indexers | C# 13 | ✅ v1 (ext) | desugar |
| **Events** `event D E;` | pub/sub | 🔜 later | lib |
| **Operators** `operator +` | overload | ✅ v1 | front (→ `proc \`+\``) |
| Conversion ops `implicit`/`explicit` | casts | ✅ v1 | front (→ converter/`)` proc) |
| `++`/`--` overloads | C# 11 | 🔜 later | front |
| Nested/partial members | - | 🚫 / 🔜 | - |

### 5.4 Properties (flagship C# feature)

> **Verified cheap.** Nim already implements C#-style read *and* write dispatch:
> a getter `proc P(x: T): R` and a setter ``proc `P=`(x: var T, v: R)``, wired by
> `propertyWriteAccess` and `dotTransformation` in `compiler/semexprs.nim`. We
> confirmed `obj.Prop = v` and `obj.Prop` work end-to-end. **No `sem` changes.**

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| Auto-property `R P { get; set; }` | backing field + accessors | ✅ v1 | desugar |
| Read-only `R P { get; }` | getter only | ✅ v1 | desugar |
| Computed `R P { get { .. } set { .. } }` | bodies | ✅ v1 | desugar |
| Expression-bodied `R P => e;` | single expr | ✅ v1 | desugar |
| Init-only `R P { get; init; }` | set in ctor only | 🔜 later | sem/desugar |
| `required` members | must-init | 🔜 later | sem |
| Static properties | type-level | ✅ v1 | desugar |
| Accessor visibility `{ get; private set; }` | per-accessor | ✅ v1 | desugar |
| Abstract/virtual properties | dispatch | ✅ v1 | sem |
| Interface properties | contract | ✅ v1 (static) | desugar → concept |

### 5.5 Access modifiers

| Modifier | C# meaning | Disposition | Maps to (Nim) |
|---|---|---|---|
| `public` | all | ✅ v1 | exported (`*`) |
| `private` | type/unit | ✅ v1 | module-private (default) |
| `protected` | type + derived | ✅ v1 (approx) | module-scoped in v1 (see note) |
| `internal` | assembly | ✅ v1 | module-private |
| `protected internal` | union | 🔜 later | - |
| `private protected` | intersection | 🔜 later | - |
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
| `switch` (statement) | multi-branch | ✅ v1 (basic); patterns 🔜 | desugar (→ `case`) |
| `switch` expression `x switch { ... }` | C# 8 | 🔜 later | desugar |
| `while` | loop | ✅ v1 | front |
| `do { } while (c);` | post-test loop | ✅ v1 | desugar (no Nim `do-while`) |
| `for (i = 0; i < n; i++)` | C-style for | ✅ v1 | desugar (→ `while`) |
| `foreach (var x in xs)` | iterate | ✅ v1 | desugar (→ `for`) |
| `break` / `continue` | loop control | ✅ v1 | front |
| `return` | return | ✅ v1 | front |
| `goto` / labels | jump | 🚫 out | - |
| `throw e;` | raise | ✅ v1 | front (→ `raise`) |
| `try { } catch (E e) { } finally { }` | EH | ✅ v1 | front (→ `try/except/finally`) |
| `catch when (cond)` | filter | 🔜 later | desugar |
| `using (var r = ...) { }` | dispose scope | ✅ v1 | desugar (→ `defer`) |
| `lock (o) { }` | mutual exclusion | 🔜 later | lib |
| `yield return e;` | iterator | ✅ v1 | front (→ Nim `yield`) |
| `yield break;` | end iterator | ✅ v1 | desugar |
| Iterator methods (`IEnumerable` return) | lazy seq | ✅ v1 | sem |
| `checked { }` / `unchecked { }` | ovf checks | ✅ v1 | desugar (→ `{.push overflowChecks.}`, §7.3) |
| `unsafe { }` blocks (pointers, `&`, `*`) | unsafe | ✅ v1 | front |
| `fixed`, `stackalloc` | stack-only | 🚫 out | front |
| Local functions | nested funcs | ✅ v1 | desugar (→ nested proc) |
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
| Arithmetic `+ - * / %` | ✅ | ✅ v1 | front |
| Integer `& | ^ << >> ~` | ✅ | ✅ v1 | front |
| Logical `&& || !` | ✅ | ✅ v1 | front |
| Comparison `== != < > <= >=` | ✅ | ✅ v1 | front |
| Assignment & compound `= += -= ...` | ✅ | ✅ v1 | front |
| `??` null-coalescing | ✅ | ✅ v1 | desugar |
| `??=` | ✅ | ✅ v1 | desugar |
| `?.` / `?[]` null-conditional | ✅ | ✅ v1 | desugar |
| `?:` ternary | ✅ | ✅ v1 | front (→ `nkIfExpr`) |
| `is` / `as` | type test/cast | ✅ v1 | front (→ Nim `of`/conv) |
| Pattern `is T x`, property patterns | C# 7+ | 🔜 later | desugar |
| Switch expressions | C# 8 | 🔜 later | desugar |
| `^` (index-from-end), `..` (range) | C# 8 | 🔜 later | desugar/lib |
| Null-forgiving `x!` | suppress NRT | 🔜 later | front |
| `checked`/`unchecked` expr | ovf | ✅ v1 (verify) | desugar (block + push/pop) |
| `stackalloc` | stack mem | 🚫 out | front |
| Precedence | C# table | ✅ v1 | front |

### 7.2 Expressions

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| Method call `f(a, b)` | call | ✅ v1 | front |
| Member access `a.b` | dot | ✅ v1 | front |
| `this`, `base` | self/base | ✅ v1 | desugar |
| Lambdas `x => e`, `(a,b) => e` | closures | ✅ v1 | front (→ Nim closure) |
| Anonymous methods `delegate { }` | older lambdas | 🔜 later | front |
| Object initializer `new T { A = 1 }` | init props | ✅ v1 | desugar |
| Collection initializer `new List<int>{1,2}` | init | 🔜 later | desugar |
| Anonymous types `new { A = 1 }` | inferred type | 🔜 later | desugar |
| `typeof(T)` | type object | ✅ v1 | desugar/`lib` |
| `nameof(x)` | name string | ✅ v1 | desugar |
| `sizeof`, `default(T)` | - | ✅ v1 | desugar/`lib` |
| String interpolation `$"{x}"` | format | ✅ v1 | desugar |
| `with` expression (records) | copy-update | 🔜 later | desugar |
| Target-typed `new()` (C# 9) | infer type | 🔜 later | front |
| LINQ *method* syntax `.Where().Select()` | query | 🔜 later | lib |
| LINQ *query* syntax `from..select` | query | 🚫 out (argue) | front |
| Expression trees | `Expression<T>` | 🚫 out | - |
| `await` expression | async | 🔜 later | sem |

**Notes**
- `?.`/`??`/`??=` are the main "null" desugars (null model: §4.4/§7.3).
- `nameof`, `default`, `sizeof`, `typeof` are trivial AST rewrites / lib helpers.

### 7.3 Semantic traps (must-pin C#↔Nim mismatches)

These look like trivial desugars but are not - each needs an explicit rule.

| Trap | C# | Nim | N# rule | Mechanism |
|---|---|---|---|---|
| Integer `/` | `7/2 == 3` (int div) | `7/2 == 3.5` (float!) | integer `/` → `div`; `/` only for floats | desugar |
| `%` | sign of dividend | `mod`: sign of dividend (matches) | map `%` → `mod` | front |
| Overflow default | unchecked (wraps) | checked (raises) | **unchecked by default** (module-level `{.push overflowChecks: off.}`) | desugar |
| `checked`/`unchecked` | ovf on/off | `{.push overflowChecks.}` | same mechanism, `push`/`pop` (deferred in 3a) | desugar |
| `==` / `Equals` | class = reference, struct = value | whatever is overloaded | class → reference `==`; struct/record → value `==`; `Equals`→`==` | desugar/sem |
| `ToString()` | virtual method | `$` proc | map `ToString` → `$` | desugar |
| Numeric conversions | implicit widening, explicit narrowing | stricter | implicit widening; explicit narrowing | desugar/sem |
| `using` keyword | directive **and** statement | - | disambiguate by context | front |
| `switch` fallthrough | forbidden (empty cases group) | no fallthrough | maps to Nim `case`; empty-case groups allowed; a trailing `break;` is dropped; a non-exhaustive switch gets `else: discard` | front |
| `Main` / `args` | `Main(string[])`, exit code | module top-level | support both (D5); `int` return → exit code | front |
| Interpolation format | `$"{x:F2}"` | `strformat`/`formatFloat` | map format specs to Nim format | desugar |
| `null` deref | `NullReferenceException` | `NilAccessDefect` | prelude aliases it to `NullReferenceException` | lib |
| Arrays | `T[]`, `new T[n]` | `seq[T]` | `T[]` → `seq[T]`; `new T[n]` → `newSeq[T](n)`; `new T[]{..}` → `@[..]`; `.Length`/`.Count` → `len` | front |
| Enum field scope | scoped to the enum type | unqualified globals | `E.A` resolves via Nim qualified access; two enums must not share a field name | front |
| Exceptions | all derive from `Exception` | `CatchableError`; raised as `ref T` | C# `Exception` → `CatchableError`; `throw` → `raise`; an exception class is a value `object` (so `except T` can match) but is raised as `ref T` (Nim only raises refs) | front |
| `e.Message` | property on every exception | `CatchableError.msg` field | map `.Message` → `.msg` | front |
| `WriteLine(bool)` | `True` / `False` | `$bool` gives `true` / `false` | prelude `bool` overloads of `WriteLine`/`Write` print `True`/`False` | lib |
| Discarding a result | any expression statement may drop a result | unused result is an error | every generated proc is `{.discardable.}` (and the collection shims `{.push discardable.}`) | front/lib |

> The overflow / `checked` / `unchecked` rows all ride on **one** mechanism:
> Nim's `{.push overflowChecks: on|off.}` / `{.pop.}`, handled by `genPragma` at
> `compiler/ccgstmts.nim:1839` and read by codegen at `compiler/ccgexprs.nim:678`,
> `:712`, `:2959`. Verified: `unchecked { … }` ⟹ `{.push overflowChecks: off.} … {.pop.}`.
> Always emit the matched `{.pop.}`.

---

## 8. Object model & polymorphism

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| Single inheritance `class C : B` | one base | ✅ v1 | front (→ Nim `object of`) |
| Multiple interfaces | many contracts | ✅ v1 (static concepts) | sem |
| `virtual` methods | overridable | ✅ v1 | sem (`method`) |
| `override` | replace base | ✅ v1 | sem (`{.override.}`) |
| `abstract` methods/classes | no impl | ✅ v1 | sem |
| `sealed` | stop inheritance | ✅ v1 | sem |
| `new` (hide) | shadow | 🔜 later | sem |
| Dynamic dispatch | via vtable | ✅ v1 | Nim `method` |
| `base.M()` calls | call base impl | ✅ v1 | desugar |
| `this` | self ref | ✅ v1 | desugar |
| `Object` base (`Equals`/`ToString`/`GetHashCode`) | universal methods | ✅ v1 | desugar (→ `==`, `$`, `hash`) |
| Boxing/unboxing (value↔`object`) | implicit | 🔜 later | sem |
| Operator overloading | `operator +` | ✅ v1 | front |
| Method overloading | same name, diff sig | ✅ v1 | sem (Nim overloads) |
| Named/optional/default args | `M(x: 1)` | ✅ v1 | free |
| `params` arrays | variadic | ✅ v1 | front (→ `varargs`) |
| `ref` / `out` / `in` params | by-ref | ✅ v1 | front (→ `var`/`lent`) |
| Extension methods | `static void M(this T)` | ✅ v1 (ext) | free (UFCS) |
| `IDisposable` / `using` | deterministic cleanup | ✅ v1 | desugar/lib |
| `IEnumerable<T>` / `foreach` | iteration protocol | ✅ v1 | sem/lib |
| Covariance/contravariance | `in`/`out` | 🔜 later | sem |
| `static class` | container | 🔜 later | front |
| Object/collection `ToString` | `$` | ✅ v1 | desugar |

**Interface model (D2, decided): static interfaces = concepts (v1).**
`interface I { R M(P); }` desugars to a Nim `concept`:

```nim
# N#:
#   interface IMovable { void Move(float dt); }
#
# desugars to:
type IMovable = concept e
  e.Move(float)

# so generic constraints read naturally (N#):
void Tick<T>(T e, float dt) where T : IMovable { e.Move(dt); }

# anonymous interfaces synthesize a concept (N#):
void Tick<T>(T e, float dt) where T : { void T.Move(float dt) } { e.Move(dt); }
```

A class `Foo : I` is *structural*: `Foo` satisfies `I` iff it defines the
methods. The nominal link is still recorded (for docs/LSP) and guarded with
`static: doAssert Foo is I`. **Ceiling:** concepts are compile-time only, so they
give `where T : I` but **not** interface-typed *values* (`I x = …`, `List<I>`,
heterogeneous dispatch). Dynamic interface dispatch is **staged to v2** (needs an
abstract-base + vtable scheme).

---

## 9. Generics

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| Generic classes `Box<T>` | parameterised type | ✅ v1 | free (Nim generics) |
| Generic methods `T F<T>(T x)` | - | ✅ v1 | free |
| Multiple type params `Map<K,V>` | - | ✅ v1 | free |
| Type inference at call site | - | ✅ v1 | free |
| `where T : class` / `struct` | constraint | ✅ v1 | sem (typeclass) |
| `where T : new()` | ctor constraint | ✅ v1 | sem |
| `where T : Base` | base constraint | ✅ v1 | sem (typeclass) |
| `where T : IComparable` | interface constraint | ✅ v1 (concept) | sem |
| `where K : notnull` | nullness constraint | 🔜 later | sem |
| Multiple constraints | `where T : A, B` | ✅ v1 | sem |
| Generic delegates | `Func<T,R>` | ✅ v1 | free |
| Generic interfaces | `IEnumerable<T>` | ✅ v1 (static) | sem |
| `default(T)` | default value | ✅ v1 | lib |
| Static members of generics | per-instantiation | 🔜 later | sem |
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
| `Func<...>` / `Action<...>` | built-in delegates | 🔜 3d (needs generics) | lib |
| Lambda expressions | `x => e` | ✅ v1 (3b) | front |
| Closures (capture) | - | ✅ v1 (3b) | free (Nim closures) |
| Method group → delegate | `D d = M;` | ✅ v1 (3b) | free |
| Multicas (combine) `+=` / `-=` | invocation list | 🔜 later | lib |
| `event D E;` | pub/sub member | 🔜 later | lib |
| `event` add/remove accessors | custom | 🔜 later | lib |
| Anonymous methods `delegate { }` | - | 🔜 later | front |
| Delegate variance | `Action<Base> = Action<Derived>` | 🔜 later | sem |
| Expression trees | `Expression<Func<>>` | 🚫 out | - |

**Note:** Nim closures (`{.closure.}` procs) cover the 95% case (single-target
delegates). Multicast delegates and `event` become a small `lib` library type.

---

## 11. Exceptions

| Feature | C# meaning | Disposition | Mechanism |
|---|---|---|---|
| `throw e;` | raise | ✅ v1 | front (→ `raise`) |
| `try` / `catch` / `finally` | EH | ✅ v1 | front |
| `catch (T e)` typed | filter by type | ✅ v1 | front (→ `except T as e`) |
| `catch { }` catch-all | - | ✅ v1 | front |
| Custom exceptions `class E : Exception` | user types | ✅ v1 | front |
| `when` catch filters | conditional | 🔜 later | desugar |
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
| `lock` statement | mutex | 🔜 later | lib |
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
| Custom attribute classes | metadata | ✅ v1 | desugar (→ `{.pragma.}`) |
| `[Obsolete("msg")]` | deprecation | ✅ v1 | desugar (→ `{.deprecated.}`) |
| `[DllImport("lib")]` | P/Invoke | ✅ v1 | desugar (→ `{.importc,dynlib.}`) |
| `[StructLayout(LayoutKind.Sequential)]` | ABI layout | 🔜 later | desugar (→ `{.packed.}`) |
| `[Conditional("X")]` | call-site strip | 🔜 later | desugar |
| `[Serializable]`, `[JsonProperty]` etc. | framework | 🚫 out | - |
| Attribute *reflection* at runtime | `GetCustomAttributes` | 🚫 out | - |
| Built-in `[Flags]` on enums | - | 🔜 later | desugar |

**Note:** Attributes map to Nim **pragmas** - a natural fit. The key restriction:
N# attributes are *compile-time* metadata only; no runtime reflection.

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

| Capability | C# analog | Disposition | Mechanism |
|---|---|---|---|
| `extern "C"` declaration | `[DllImport]`/`extern` | ✅ v1 | desugar (→ `{.importc.}`) |
| `extern "C" fn` body | `[UnmanagedCallersOnly]` | ✅ v1 | desugar (→ `{.exportc.}`) |
| C++ class binding (`extern "C++"`) | - | ✅ v1 | desugar (→ `{.importcpp.}`) |
| Export to C++ | - | ✅ v1 | desugar (→ `{.exportcpp.}`) |
| C++ member / constructor | - | ✅ v1 | desugar (→ `ccMember`/`constructor`) |
| `[StructLayout]` ABI match | - | 🔜 later | desugar |
| N# implementing a C++ abstract interface | - | ✅ v1 | desugar (`vtables`) |
| `cstring` conversions | `Marshal` | ✅ v1 | lib |
| Raw pointers `T*` | `unsafe` | ✅ v1 | front (→ `ptr`) |
| `IntPtr` | - | 🔜 later | lib |
| Function pointers | - | ✅ v1 | front/lib (→ `proc`) |

**Goal (from your brief): C++ bindings should be writable in N# itself.** §14.2
is therefore a **v1 priority**, not an afterthought - `extern "C"`/`extern "C++"`
blocks are the mechanism, desugaring to Nim's mature `importc`/`importcpp`.

---

## 15. Standard library surface (the "N# BCL-lite")

N# ships a **prelude** (`lib/pure/ns/…`) that maps common C# BCL types onto Nim
stdlib so C# idioms feel native. All ✅ rows are `lib` (no compiler change).

| C# type / API | Disposition | Maps to (Nim) |
|---|---|---|
| `Console.WriteLine/Write/ReadLine` | ✅ v1 | `stdout.writeLine`/`readLine` |
| `string` members `.Length`, `.Substring`, `.IndexOf`, `.ToUpper/Lower`, `.Split`, `.Trim`, `.Contains`, `.Replace`, `.StartsWith`… | ✅ v1 | `lib` wrappers on Nim `string` |
| `string.Format`, `Join`, `IsNullOrEmpty` | ✅ v1 | `lib` |
| `string.RuneCount` / `.Runes` (char count) | ✅ v1 | `lib` (N# helper; `.Length` is bytes, §4.4) |
| `int`/`double` `.ToString`, `.Parse`, `.TryParse` | ✅ v1 | `lib` (`parseInt`, `parseFloat`) |
| `Math.*` | ✅ v1 | `lib` (Nim `math`) |
| `List<T>` | ✅ v1 | `seq[T]` + N# procs (SS15.1) |
| `Dictionary<K,V>` | ✅ v1 | `Table[K,V]` + N# procs (SS15.1) |
| `HashSet<T>` | ✅ v1 | `HashSet[T]` + N# procs (SS15.1) |
| `Queue<T>`, `Stack<T>` | ✅ v1 | wrappers over `Deque[T]` (SS15.1) |
| `LinkedList<T>` | 🔜 later | `lib` |
| `Array` / `Sort` / `Reverse` | ✅ v1 | `lib` (`algorithm`) |
| `StringBuilder` | ✅ v1 | `lib` (`strutils`) |
| `Tuple<...>` | ✅ v1 | Nim tuple |
| `Nullable<T>` | ✅ v1 | `Option[T]` |
| `Exception` hierarchy | ✅ v1 | `lib` |
| `DateTime`, `TimeSpan` | 🔜 later | `std/times` |
| `Random` | ✅ v1 | `std/random` |
| `Convert.*` | ✅ v1 | `lib` |
| `IEnumerable<T>` / `ICollection<T>` / `IList<T>` | ✅ v1 (static) | concepts |
| LINQ (method syntax) | 🔜 later | iterator adapters |
| `File` / `Directory` / streams | 🔜 later | `std/os`, `std/streams` |
| `Regex` | 🔜 later | `std/re` |
| `GC.*` | 🚫 out | Nim manages memory |
| `Task`, `Thread`, `Interlocked` | 🔜 later | `std/*` |
| `Marshal`, `IntPtr` | 🔜 later | `lib` |
| `object` boxing helpers | 🔜 later | - |

**Naming:** do we keep C# names (`List`, `Count`, `Length`) or Nim names
(`seq`, `len`)? **Proposed:** keep **C# names at the source level** for
familiarity, implemented as `lib` wrappers. (Raise if you'd rather expose Nim
names.)

### 15.1 Collections - pinned member surface (3b)

`List<T>` is `seq[T]`, `Dictionary<K,V>` is `Table[K,V]`, `HashSet<T>` is
`HashSet[T]`; `Queue<T>`/`Stack<T>` are small wrappers over `Deque[T]`. `.Count`
is lowered to `.len` by the frontend. The shim re-exports `tables`/`sets`, since
Nim's `import` is not transitive and `Dictionary`/`HashSet` users need indexing,
`in`, `keys`, `values`, ... Only these members exist:

| Type | Members (3b) |
|---|---|
| `List<T>` | `Add` `AddRange` `Clear` `Contains` `IndexOf` `Insert` `Remove` `RemoveAt` `Reverse` `Sort` `ToArray`, `[]`, `[]=` |
| `Dictionary<K,V>` | `Add` `Clear` `ContainsKey` `ContainsValue` `Remove` `Keys` `Values`, `[]`, `[]=` |
| `HashSet<T>` | `Add` `Clear` `Contains` `Remove` `ToArray` `UnionWith` `IntersectWith` `ExceptWith` |
| `Queue<T>` | `Enqueue` `Dequeue` `Peek` `Contains` `Clear` `ToArray` |
| `Stack<T>` | `Push` `Pop` `Peek` `Contains` `Clear` `ToArray` |

Deliberately deferred, with the reason recorded:

* **Predicate members** (`Find`, `FindAll`, `Exists`, `RemoveAll`, `ForEach`,
  `Sort(comparison)`) need a lambda typed from a **method parameter**. 3b types
  lambdas only from a declared local of delegate type (`annotateLambda`), so this
  first needs method-signature plumbing.
* **`TryGetValue(k, out v)`** needs `out` parameters, which the parser does not
  parse yet.
* **LINQ**, `Capacity`, `TrimExcess`, `CopyTo`, `GetRange`, `LastIndexOf`,
  `InsertRange`, `RemoveRange`, `Keys`/`Values` as live views, `IComparer`
  overloads: see the deferred list in SS19.

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
| Error codes | mirror C# | ✅ v1 | the digits are C#'s code for the same condition (`NS0246` is `CS0246`); `NS9999` is the single code for a construct N# does not support yet, and the rest of the 9xxx band is reserved for conditions C# accepts, which have nothing to mirror. `compiler/nsharp/diagnostics.nim` owns the table, and `run_cs.sh` checks each `.fail` marker against the code Roslyn reports |
| Formatter | `nph`/custom | 🔜 later | Nim tooling is Nim-syntax |
| Debugger | native DWARF/PDB | ✅ v1 | Nim emits standard debug info |
| Package manager (Nimble) | `.ns` sources in packages | 🔜 later | - |
| REPL / scripting mode | interactive | 🔜 later | ties to execution model |
| Build system integration (CMake/engine) | generate libs/objects | 🔜 later | ties to execution model |

A diagnostic's digits are the C# code for the same condition. `NS9999` is the one
code for every construct N# does not support yet, so closing a gap retires no code,
and the rest of the 9xxx band covers the conditions C# accepts.
`compiler/nsharp/diagnostics.nim` is the source of truth for the text as well as the
code:

| N# | C# | Condition |
|---|---|---|
| `NS0122` | CS0122 | a member is inaccessible |
| `NS0246` | CS0246 | a `using` names no namespace or module |
| `NS1001` | CS1001 | identifier expected |
| `NS1002` | CS1002 | `;` expected |
| `NS1003` | CS1003 | syntax error, a token expected |
| `NS1026` | CS1026 | `)` expected |
| `NS1513` | CS1513 | `}` expected |
| `NS1514` | CS1514 | `{` expected |
| `NS1515` | CS1515 | `in` expected |
| `NS1519` | CS1519 | invalid token in a member declaration list |
| `NS1525` | CS1525 | invalid expression term |
| `NS2001` | CS2001 | source file could not be found |
| `NS7036` | CS7036 | a constructor requires base arguments |
| `NS9006` | - | the parser made no progress |
| `NS9007` | - | two namespaces use each other |
| `NS9999` | - | a construct N# does not support yet |

An error Nim raises on the lowered code (an undeclared name, a type mismatch, or a
bad arity) still prints Nim's own text and carries no `NS` code. Giving those codes
needs name resolution in the frontend, which is not in v1.

A `.fail` or `.unsupported` marker may name the code it expects:

```
This test must fail to compile: it accesses a private base-class member.
code: NS0122
```

`run.sh` then requires that code in the compiler output, and `run_cs.sh` requires
the digits to appear among the codes Roslyn reports for the same file, skipping the
reserved band.

---

## 18. Open decisions log

| # | Decision | Resolution | Blocking |
|---|---|---|---|
| **D1** | Case sensitivity | ✅ **Case-sensitive**; `IdentCache` mode + case-preserving hash (§3.1) | lexer, `idents` |
| **D2** | Interface model | ✅ **Static interfaces = concepts** (v1); dynamic values → v2 (§8) | sem |
| **D3** | Method resolution | ✅ member-first, then UFCS fallback | sem |
| **D4** | Namespace ↔ module | ✅ namespace = generated decl/impl/barrel (§5.1.1) | front |
| **D5** | Entry point | ✅ both top-level statements and `Main` | parser |
| **D6** | Null model | ✅ `nil`-able refs, `?` annotation; `Option[T]` for `T?`; `null` deref → `NullReferenceException` (§4.4) | lib |
| **D7** | `decimal` | ✅ later (lib), not core | lib |
| **D8** | Error codes/style | ✅ codes mirror C#'s digits, `NS9xxx` for the rest (§17) | tooling |

**Resolved this round:** `char` = 1 byte; `string` = Nim UTF-8 mutable (§4.4);
overflow default unchecked + `checked`/`unchecked` via `push`/`pop` (§7.3);
`unsafe` pointers in v1; `object` = reference base with boxing deferred;
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
`init`/`required`, events/multicast delegates, `decimal`, variance, dynamic
interface values, universal value boxing, `fixed`/`stackalloc`/`ref struct`,
reflection, `lock`/threads, nested/partial types, static constructors,
finalizers, `Span<T>`, `StringBuilder`-adjacent IO, `Result<T,E>`, formatter, REPL.

### 🚫 Out
`dynamic`, expression trees, `goto`, runtime attribute reflection, `GC.*`,
`#region`, .NET BCL, assemblies, `partial` types.

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
  1-byte `char` + Nim UTF-8 mutable strings (§4.4); `object` = reference base,
  boxing deferred (§4.4); interfaces = static concepts + anonymous concepts
  (§8); all generic constraints in v1 (§9); `checked`/`unchecked` promoted to v1
  via `{.push overflowChecks.}` (§6, §7.3); `unsafe` pointers in v1 (§14.2);
  `Nullable<T>` in v1; `Result<T,E>`/`#region`/`stackalloc`/`fixed`/`ref struct`
  out or later; ASCII-only identifiers; new §7.3 semantic-traps table.
- **v1 (first draft)** - initial catalog: lexical, types, declarations, statements,
  expressions, object model, generics, delegates, exceptions, async, attributes,
  interop, stdlib, extensions, tooling, open decisions, v1 scope.

*End of document.*

