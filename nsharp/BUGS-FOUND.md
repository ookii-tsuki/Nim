# N# bug hunt: findings (2026-10-21)

## Status (2026-10-22): every finding below is fixed

Each fix has a regression test under `nsharp/tests/ecma/`, whose expected output
Roslyn confirms (`run_cs.sh` now runs here: the .NET 10 SDK is installed from
Ubuntu's archive), and every gate passes: run, AST, C#, sema (goldens from
Roslyn), reorder, native and diagnostics.

| findings | commit |
|---|---|
| A1 narrowing, B1 `MinValue % -1`, A7 `uint` constants, C25 float `%`, C29 `>>>` (and shift-count masking, `Math.Abs(MinValue)`) | `6e54b32` |
| A2, A3 compound assignment order and single evaluation | `8de958c` |
| C1 value parameters, C2 generic `base.`, C6/C7 `params`, C22/C23 null strings, C24 boxing into `object` | `25cf31a` |
| A5 overrides of generic base members | `255d728` |
| A6 overload resolution, C8 user conversions from literals | `0c8455b` |
| A4 loop closures, C4, C5, C21, C27 lambdas and delegates | `4694523` |
| A9, A10, C11-C17, C19, C20 nullable values, boxing, `?.` values; `(int?)x` casts | `af198c1` |
| A8 iterator `finally`, C3 qualified library types, C9 enum `0`, C10 `new S()`, C18 `is int ?`, C28 `$"""`, D `newList` diagnostic; `as` with `string`/array/`T?` | `a361a31` |
| E static constructors on first use | `92e69aa` |
| D strict-defs build | `12aafd3` |
| C26 members named like types; types named like library members (`e.Message`) | `4f31745` |
| (found while fixing) exception-typed variables, fields and properties | `ba68d06` |

Still open, recorded rather than fixed:

* A local *function* (not a lambda) declared in a loop body that captures one of
  the body's variables still shares one copy across iterations (SPEC, closures).
* `System.Random` is not in the prelude (library work).
* The documented divergences stand: float and bool spelling, Nim's output for an
  unhandled exception, a null `string` being `""`, `decimal`, `goto`, LINQ.

The original report follows unchanged.

Found by compiling small C# programs with an N# compiler built from `3c21d35` and
comparing what they print with what ECMA-334 (and Roslyn/.NET) require. No .NET SDK
was available, so the "C#" column is the specified behaviour, not a Roslyn run.
Every snippet is the body of `static void Main()` in `class Prog` under
`using System; using System.Collections.Generic;`, unless it shows its own types.

Already-documented divergences are left out (float/bool spelling, `some(5)` for a
`T?`, a null `string` being `""`, `goto`, `decimal`, LINQ, missing BCL members),
except where noted.

Legend: **silent** = compiles and prints the wrong thing; **reject** = valid C#
that fails to compile; **crash** = runtime failure C# does not have.

## A. Silent wrong results (highest priority)

### A1. Explicit narrowing conversions throw instead of truncating (crash)
```csharp
int big = 70000;      Console.WriteLine((short)big);  // C#: 4464
long L = 5000000000;  Console.WriteLine((int)L);      // C#: 705032704
int i4 = 200;         Console.WriteLine((sbyte)i4);   // C#: -56
int c = 65601;        Console.WriteLine((int)(char)c); // C#: 65
short s = 32767; s += 1; Console.WriteLine(s);       // C#: -32768
short t = 1; t <<= 15;   Console.WriteLine(t);       // C#: -32768
```
N#: `RangeDefect` on each. In an unchecked context (the default), an integral
narrowing conversion discards the high bits (ECMA-334 §10.3.2, §12.8.20). The
module pushes `overflowChecks: off` but not `rangeChecks: off`, and the lowering
is a plain Nim conversion (`int16(big)`, `int16(int32(s) + 1)`), which Nim
range-checks. Unsigned targets happen to work (`byte b = 200; b += 100;` → 44).

### A2. Compound assignment reads its left operand after the right one
```csharp
static int g = 1;  static int Bump() { g = 100; return 1; }
g += Bump();                 // N#: 101   C#: 2
int[] arr = {10, 20};  arr[0] += Set0();   // Set0 writes arr[0] = 1000: N# 1001, C# 11
int x = 5; x += x++ * ++x;   // N#: 42    C#: 40
int u = 3; u *= (u = 10);    // N#: 100   C#: 30
```
§12.21.4: `x op= y` is `x = x op y` with `x` evaluated **once and first**. Fields
and properties are affected too. The plain form `t = t + (t = 10)` is already right
(`nsVal`); only the `op=` lowering misses it.

### A3. Compound assignment evaluates the target's sub-expressions twice
```csharp
int[] arr = {1, 2, 3}; int k = 0;
arr[k++] += 10;  Console.WriteLine(arr[0] + " " + arr[1] + " k=" + k);
// N#: "12 2 k=2" (read arr[1], wrote arr[0])   C#: "11 2 k=1"
Obj(c).P += 1;      // Obj runs twice (C#: once)
c[Ix()] += 2;       // Ix runs twice (C#: once); also c[Ix()]++
```
§12.21.4: the receiver and index expressions are evaluated only once.

### A4. Lambdas in loops share one variable across iterations
```csharp
var fs = new List<Func<int>>();
foreach (var i in new int[] {1, 2, 3}) fs.Add(() => i);
foreach (var f in fs) Console.Write(f());         // N#: 333   C#: 123
var ks = new List<Func<int>>();
for (int i = 0; i < 3; i++) { int copy = i; ks.Add(() => copy); }
foreach (var k in ks) Console.Write(k());         // N#: 222   C#: 012
```
§13.9.5 (since C# 5): each `foreach` iteration has a fresh iteration variable;
§7.7 / §12.19.6.2: a local declared in a loop body is a new variable each time the
body is entered. Nim lifts captured locals into one environment per routine, so
every closure sees the last value. The `int copy = i;` idiom, the usual fix in C#,
is broken too.

### A5. Overrides of a generic base class's virtual members never dispatch
```csharp
class Repo<T> { public virtual string Who(T x) => "base"; public virtual string Name() => "base"; }
class IntRepo : Repo<int> { public override string Who(int x) => "derived"; public override string Name() => "derived"; }
Repo<int> r = new IntRepo();
Console.WriteLine(r.Who(1) + " " + r.Name());  // N#: "base base"   C#: "derived derived"
```
An `abstract` member there crashes with `abstract member called: Pick [Defect]`.
The base lowers to `method Who*[T](self: Repo[T]...)`, the override to
`method Who*(self: IntRepo...)`, which Nim does not treat as an override.

### A6. Overload resolution takes the first applicable overload, not the best
```csharp
static string K(object o) => "object";  static string K(string s) => "string";
K("s");  K(null);            // N#: object object   C#: string string
static string Nu(int? x) => "int?";  static string Nu(object x) => "object";
Nu(1);  Nu(null);            // N#: object object   C#: int? int?
```
§12.6.4.4–.7 (better function member, better conversion target). `resolveOverload`
(`sema.nim:823`) scores only `T?` wrapping, `params` expansion and defaults, so an
identity match ties with boxing and the declaration order wins. Sema then records a
boxing conversion (`K(Prog, nsBox("s"))`), which forces Nim to the wrong overload.
Reversing the declarations changes the program's behaviour.

Related rejects from the same ranking gap:
```csharp
static string F(int x)…; F(long)…; F(double)…; F(object)…
F(1.0); F(1f);               // NS0266 "Cannot implicitly convert type 'double' to 'int'"
static string G(long x)…; G(double x)…;  G(1f);   // NS0266, C#: double
static string U(uint x)…; U(int x)…;     U(1);    // Nim "ambiguous call", C#: int
static string Ch(char c)…; Ch(int i)…;   Ch(97);  // NS0266, C#: int
static string By(byte b)…; By(short s)…; By(1);   // ambiguous, C#: byte
static string Q(int a, int b = 0)…; Q(int a)…; Q(1); // ambiguous, C#: Q(int) (§12.6.4.3 tie-break)
```

### A7. `uint` minus an `int` constant picks the wrong operator
```csharp
uint u = 5; Console.WriteLine(u - 6);   // N#: -1   C#: 4294967295
```
§12.4.7 / §10.2.11: the constant `6` converts to `uint`, so overload resolution
picks `uint operator -(uint, uint)`, which wraps. (`u + i` for an `int` variable `i`
is `long` and is already right.)

### A8. `foreach` that leaves an iterator early never runs its `finally`
```csharp
static IEnumerable<string> Fin() { try { yield return "a"; yield return "b"; } finally { Console.WriteLine("fin"); } }
foreach (var s in Fin()) { Console.WriteLine(s); break; }
// N#: "a"   C#: "a" then "fin"
```
§13.9.5: `foreach` disposes the enumerator, and §15.15.5: `Dispose` runs the
`finally` blocks of a suspended iterator.

### A9. Boxing a `T?`
```csharp
int? a = 5;    object o = a;  Console.WriteLine(o is int);     // N#: False  C#: True
int? n = null; object p = n;  Console.WriteLine(p == null);    // N#: False  C#: True
```
§10.6.4.4 / §8.3.12: boxing a nullable boxes its value, or yields `null`.

### A10. Identical string literals are not the same object
```csharp
object a = "x", b = "x"; Console.WriteLine(a == b);   // N#: False  C#: True
```
§6.4.5.6: identical string literals are the same instance (minor).

## B. Crashes C# does not have

### B1. `int.MinValue % -1` kills the process with SIGFPE
```csharp
int m = int.MinValue, d = -1;
try { Console.WriteLine(m % d); } catch (OverflowException) { Console.WriteLine("ovf"); }
// N#: "SIGFPE: Arithmetic error", exit 136   .NET: "ovf"
```
`nsMod` (`lib/pure/nsharp/intrinsics.nim:56`) checks for `0` only. `nsDiv` already
raises `OverflowDefect` for `int.MinValue / -1`.

## C. Valid C# that N# rejects (language, not library)

| # | snippet | N# | spec |
|---|---|---|---|
| C1 | `static int Inc(int n) { n = n + 1; return n; }`, any assignment, `++` or field write to a **by-value parameter** | `Error: 'n' cannot be assigned to` | §15.6.2.2: a value parameter is an ordinary local. Nim parameters are immutable; a `var n = n` shadow is needed when the body writes one |
| C2 | `class IntRepo : Repo<int> { … base.Add(x) … }` | `type mismatch: got 'IntRepo' for 'self' but expected 'Repo'` | `baseConv` (`desugar.nim:179`) spells `Repo(self)`: `curBase` keeps the bare name and drops the type arguments |
| C3 | `var list = new System.Collections.Generic.List<int>(); list[0]` with no `using` | Nim `type mismatch` on `[]` | the selective `from "System/Collections/Generic" import Add, Count, List, …` (`desugar.nim:5741`) never imports `[]`/`[]=` (or `items`, operators) |
| C4 | `Action a = () => cnt++;` (also `++cnt`) | `expression … has to be used (or discarded)` | §12.19.4: a statement expression body converts to a `void` delegate. `cnt += 1`, `cnt = 5` and a call already work |
| C5 | `Func<int, Func<int, int>> add = x => y => x + y;` | `A nested proc can have generic parameters only when …` | the inner lambda is typed from the outer delegate's return type |
| C6 | `static int Sum(params int[] xs)` called as `Sum(new[] {4, 5})` | type mismatch | normal-form call (§12.6.4.2) with an implicitly typed array. `new int[] {…}` works |
| C7 | `Sum(null)` for the same method | `NS1503: cannot convert from '<null>' to 'int'` | the normal form applies: `xs` is `null` |
| C8 | `struct V2 { public static implicit operator V2(int k) … }` then `V2 c = 5;` / `Take(5)` / `c = 5;` | type mismatch on `int literal(5)` | the converter takes `int32`, and Nim types the literal as `int`. `int k = 5; V2 c = k;` works |
| C9 | `[Flags] enum Perm {…}`: `Perm p = 0;`, `p == 0`, `(p & Perm.W) == 0` | type mismatch; the last says `Operator '==' cannot be applied to operands of type 'bool'` | §10.2.4: the literal `0` converts to every enum type |
| C10 | `struct Pt { public Pt(int x) {…} }` then `new Pt()` | `NS7036: There is no argument given …` | §16.4.9: every struct has the parameterless constructor |
| C11 | `int? a = 3; a == 3`, `a != 3` | Nim `==` mismatch | lifted equality with a non-nullable operand (§12.4.8) |
| C12 | `int? a, b; a + b == null`, `a * 2 != null`, `null == a - 1` | `undeclared identifier: ''` (lowers to `none()` with no type) | lifted result compared with `null` |
| C13 | `int? a = 3; long? l = a;` | type mismatch | implicit nullable conversion (§10.6.1) |
| C14 | `int? a; a++;` and `a += 2;` | type mismatch in `nsStepped` / `some[int32](a + 2)` | lifted `++` and compound assignment |
| C15 | `bool? t = true, u = null; t & u`, `t \| u` | no `and`/`or` for `Option[bool]` | §12.13.5 three-valued `bool?` logic |
| C16 | `int? a = 5; a is int x` | type mismatch on the subject | type pattern on a nullable |
| C17 | `struct Pt {…}  Pt? np = new Pt(3); np.Value` | `NS1061: 'Pt' does not contain a definition for 'Value'` | SPEC itself says a user struct's `?` is `Nullable<T>` |
| C18 | `object o = 3; o is int ? "int" : "other"` | `NS1026: ')' expected` | the `?` after a type in `is` must be re-read as the conditional when what follows cannot continue a type (§12.12.12, Roslyn does this) |
| C19 | `Console.WriteLine((int)(object)5);` | `type mismatch: got 'RootRef'` | unboxing an expression that is itself a cast |
| C20 | `var x = Mk()?.Name;` (a `string` result, no `??`) | `got 'typeof(nil)' … expected 'string'` | a reference-typed `?.` result needs no `??` (the value-typed case is a documented NS9999) |
| C21 | `Action ab = a + b;` (delegates) | `+` type mismatch | §12.10.5 delegate combination (`+=`/`-=` already work) |
| C22 | `Show<string>(null)` for `static void Show<T>(T x) where T : class` | type mismatch `Show[string](Prog, nil)` | `null` to a class-constrained type parameter |
| C23 | `string.IsNullOrEmpty(null)` | type mismatch `IsNullOrEmpty(nil)` | `null` for a library `string` parameter (the SPEC's null-string rule is not applied to library calls) |
| C24 | `new List<object> { 1, "two" }` | `Add` type mismatch | the collection initializer's `Add` arguments are not boxed |
| C25 | `-7.5 % 2` | Nim `mod` type mismatch | §12.10.4 floating-point remainder |
| C26 | `class Box { public int P { get; set; } }  class P { … }` | `redefinition of 'P'` | a member named like another type is legal: members are in their type's declaration space (§7.3) |
| C27 | `Func<int, bool> f = static x => x > 0;` | `NS1002: ';' expected` | C# 9 static lambdas |
| C28 | `$"""{1 + 1} braces"""` | `NS1002` | C# 11 interpolated raw strings (plain `"""…"""` works) |
| C29 | `-16 >>> 2` | `NS1525: Invalid expression term '>'` | C# 11 unsigned right shift |

## D. Diagnostics and build

* `new List<S>()` with no `using System.Collections.Generic;` reports Nim's
  `undeclared identifier: 'newList'` instead of CS0246.
* Building the compiler with a compiler built from this tree
  (`nim0 c -d:nsharp compiler/nim.nim`) stops at `bcl.nim(319, 26) Error: use explicit
  initialization of 'result' for clarity [Uninit]`, because `compiler/nim.cfg` turns
  `Uninit`/`ProveInit` into errors under `nimUseStrictDefs`. `overloads`
  (`bcl.nim:303`) and the procs reported at `bcl.nim:305`, `parser.nim:1372`,
  `symbols.nim:142`, `lambdas.nim:324` and `sema.nim:302` need `result = …` first.
  (Built here with `--warningAsError:Uninit:off --warningAsError:ProveInit:off`.)

## E. Documented divergences re-observed (not new)

* A static constructor runs when the program starts, not before first use
  (SPEC §5.3, ECMA §15.12).
* `Math.Abs(int.MinValue)` returns `int.MinValue` (.NET throws `OverflowException`).

## What was checked and found correct

Integer `/` and `%` signs, shifts masking the count, `int.MinValue / -1` raising,
`checked` blocks and expressions, short-circuiting, `x---1` and other increment
puzzles, binary operand order (`L R M`), constructor and field-initializer order
across a hierarchy (derived initializers, then base constructor, virtual call from
the base constructor seeing the derived field), `new` hiding vs `override`,
`sealed override`, `is`/`as`, struct copy semantics through locals, arrays, lists
and dictionaries, `ref` arguments including array elements, explicit interface
implementations, default interface methods, per-instantiation statics of generics,
exception filters, `finally` on `return`, rethrow, `using` declarations and
multi-resource `using` order, pattern `switch` with guards, relational and list
patterns, records with `with` and value equality, tuples and deconstruction,
anonymous types, object and collection initializers, nested and partial classes,
extension methods, `yield return`/`yield break`, `#if`/`#elif`/`#region`, escape
sequences and verbatim strings, interpolation alignment and format specifiers,
property and indexer getter/setter counts for `+=`, `++` and postfix values, and
event and delegate `+=`/`-=`.
