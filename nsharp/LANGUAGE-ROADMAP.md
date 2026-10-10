# N# language roadmap

The C# language features still to implement, in order. Library (BCL) work is out
of scope here: each item is a language feature, implemented through the
`nsharp-language-feature` workflow (parse, tree, symbols, sema, desugar; tests
with `.out`/`.csout`/`.fail`/`.unsupported`; all gates; SPEC rows, added where
SPEC has none), and committed on its own.

Tick an item when it is merged into `nsharp`.

## Batch 1: small, common syntax

- [x] `out var` / `out _` everywhere, typed from the parameter (generic methods too). A library method
      with an `out` parameter needs the library to declare one first, which is library work
- [x] Index-from-end and ranges: `a[^1]`, `a[1..^1]`, `s[..3]` (arrays, strings; `^` on lists).
      Ranges of lists and `Index`/`Range` values need library types
- [x] Null-forgiving `x!` (checked, no runtime effect)
- [x] Anonymous methods `delegate (int x) { ... }`
- [x] `protected internal`, `private protected`
- [x] Primary constructors (C# 12): `class C(int x) { ... }`, `x` captured in the body

## Batch 2: newer syntax SPEC does not list yet

- [x] Collection expressions (C# 12): `int[] a = [1, 2, 3];`, spreads `[..xs, 4]`
- [x] List patterns (C# 11): `x is [1, _, ..]`, `[var first, .., var last]`
- [x] Positional and tuple patterns: `p is Point(var x, 0)`, `(a, b) switch { (0, _) => ... }`
- [x] `ref` locals and `ref` returns: `ref int r = ref a[0];`, `ref T Find(...)`
- [x] Default interface methods; static abstract interface members
- [x] `file`-local types
- [x] generic attributes `[Attr<T>]`
- [x] user-defined `checked` operators

## Batch 3: deeper semantics

- [x] Anonymous types `new { Name = x, Age = 3 }`: value equality, `{ Name = ..., Age = ... }` printing, `with`
- [x] Boxing: `object o = 5; (int)o; o is int n` (value types as `object`)
- [x] Multi-dimensional arrays `int[,]`, `new int[3, 4]`, `a[i, j]`, `GetLength`
- [ ] Generic variance `in`/`out` on interfaces and delegates
- [ ] Clear the current NS9999 rejections:
  - [ ] type tests and casts to generic interfaces
  - [ ] static constructors in generic classes
  - [ ] `typeof` of generic types
  - [ ] `-=` on plain delegate variables
  - [ ] classes implementing `IEnumerable<T>`
  - [ ] iterator property getters
  - [ ] finalizers `~C()`
  - [ ] partial methods
  - [ ] `event` add/remove accessors

## Last: `async` / `await`

- [ ] `async`/`await` with the minimal `Task`/`Task<T>` runtime it needs, as compiler
      support in the intrinsics. Check the design (synchronous single-thread vs Nim's
      `asyncdispatch`) with the user before starting.

## Housekeeping

- [ ] Correct stale SPEC rows as they are met (§12 `lock` done)
