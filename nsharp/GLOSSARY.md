# N# - v1 Keyword Glossary

> Companion to [`SPEC.md`](SPEC.md). This is the **exact target for the lexer**:
> the reserved-word list, contextual keywords, literals, operators, and the
> reserved-for-future set that must not be used as identifiers.

## Conventions

- **Keywords are case-sensitive** (SPEC §3.1): `Class` is an identifier, `class`
  is the keyword.
- **Identifiers are ASCII:** `[A-Za-z_]` then `[A-Za-z0-9_]*`.
- N# keywords live in the **N# frontend only**; they never collide with Nim's
  keywords because N# has its own lexer.

---

## 1. Reserved keywords (v1)

| Keyword | Category | Maps to (Nim) |
|---|---|---|
| `class` `struct` `interface` `enum` `delegate` `namespace` | type / decl | `ref object` / `object` / `concept` / `enum` / `proc` type / module |
| `public` `private` `protected` `internal` `static` `abstract` `sealed` `virtual` `override` `new` | modifiers | visibility / `method` / pragmas |
| `const` `readonly` `ref` `out` `in` `params` `this` `base` | member / params | `const`/`let` / `var`/`lent`/`varargs` / self / base |
| `operator` `explicit` `implicit` `extern` `unsafe` | special members | `proc \`op\`` / converters / `importc`/`importcpp` |
| `if` `else` `switch` `case` `default` `while` `do` `for` `foreach` `in` | control | `if` / `case` / `while` / `for` |
| `break` `continue` `return` `throw` `try` `catch` `finally` | control | `break` / `continue` / `return` / `raise` / `try` |
| `checked` `unchecked` | overflow | `{.push overflowChecks.}` (SPEC §7.3) |
| `yield` | iterators | Nim `yield` |
| `is` `as` `typeof` `sizeof` | type ops | `of` / conv / `typeof` / `sizeof` |
| `where` | generic constraints | typeclass / concept |
| `void` `bool` `byte` `sbyte` `short` `ushort` `int` `uint` `long` `ulong` `char` `float` `double` `string` `object` | built-in types | (SPEC §4) |
| `true` `false` `null` | literals | `true` / `false` / `nil` |

## 2. Contextual keywords (v1) - usable as identifiers elsewhere

| Keyword | Context |
|---|---|
| `var` | local type inference (`var x = …`) and `ref`/`out` params |
| `nameof` | `nameof(x)` |
| `when` | `#if`-style conditional compilation (also an N# ext keyword) |
| `get` `set` `value` | property accessor bodies |
| `file` | access modifier (N# ext) |

## 3. N# extension keywords (beyond C#) - v1

| Keyword | Meaning | Maps to (Nim) |
|---|---|---|
| `when` | conditional compile | Nim `when` |
| `defer` | scope-exit cleanup | Nim `defer` |
| `distinct` | newtype / units | Nim `distinct` |
| `inline` / `noinline` | perf hints | call-convention pragmas |

## 4. Reserved for future (parse as **reserved**; error if used as identifiers)

Reserving these now prevents breaking user code when they land later.

```
async await record init required with partial notnull unmanaged scoped dynamic
add remove volatile event decimal nint nuint lock global alias
ascending descending from select group into join let orderby by on equals
and or not
```

## 5. Never keywords (always identifiers)

```
goto stackalloc fixed
```

(`select`/`from`/… are only reserved-for-future, not v1 - LINQ is 🚫 out of v1.
`unsafe` *is* a v1 keyword, so it is not listed here.)

## 6. Operators & punctuators (v1)

| Group | Tokens |
|---|---|
| Arithmetic | `+` `-` `*` `/` `%` |
| Bitwise / shifts | `&` `\|` `^` `~` `<<` `>>` |
| Logical | `&&` `\|\|` `!` |
| Comparison | `==` `!=` `<` `>` `<=` `>=` |
| Assignment / compound | `=` `+=` `-=` `*=` `/=` `%=` `&=` `\|=` `^=` `<<=` `>>=` `??=` |
| Null / conditional | `?` `:` `?.` `??` `?[` |
| Lambda | `=>` |
| Delimiters | `.` `,` `;` `:` `::` `(` `)` `[` `]` `{` `}` |
| Unsafe | `*` (pointer type, in `unsafe`) · `&` (address-of, in `unsafe`) |
| Deferred | `!` (null-forgiving, 🔜) · `\|` (pattern alt, 🔜) |

## 7. Lexical prefixes (not operators)

| Prefix | Meaning |
|---|---|
| `@"…"` | verbatim string (no escapes; `""` = quote) |
| `$"…"` | interpolated string |
| `#` | preprocessor directive start |

---

*Change log*
- **v1** - initial glossary derived from the C# reserved set, pruned to the N#
  v1 scope (see SPEC §19), plus N# extensions and the reserved-for-future set.
