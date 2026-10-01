# N# — Compiler Integration Architecture (minimal-diff plan)

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
  `app.ns` for the *main* module — **`modules.nim` needs no change.**
- **There is no "override a compiler file" hook.** `patchFile` is a nimscript
  stdlib API (`lib/system/nimscript.nim:82`); `-d:nimCustomAst` only swaps the
  AST *type* inside `parser.nim`. So a few core files must be edited — but very
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
| `compiler/syntaxes.nim` | `when defined(nsharp):` — `.ns` `parseFile` dispatch to `nsharp/frontend` | ✅ Phase 0 |
| `compiler/pipelines.nim` | guarded branch: one-shot N# module parse → `sem`, then fall through to the shared tail | ✅ Phase 0 |
| `compiler/options.nim` | `NsExt` + `findModule` also tries `.ns` (imports) | 🔜 Phase 1 |
| `compiler/idents.nim` | optional `caseSensitive` mode on `IdentCache` (SPEC §3.1) | 🔜 Phase 1 |

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

## 3.1 Phase 0 status — ✅ complete

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

(`dist/checksums` and `dist/nimony` must be present — `koch installdeps` caches them.)

## 4. Directory layout

```
compiler/nsharp/          # ALL compiler-integrated code (new → merge-safe)
  frontend.nim            # entry points the core edits call
  lexer.nim  parser.nim  keywords.nim
  # future: desugar.nim  diag.nim
lib/ns/                   # N# prelude (future; new files under lib/)
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
5. **Upstream the generic seams** when convenient — (a) extension-based parser
   dispatch in `syntaxes.nim`, (b) `IdentCache` case-sensitivity mode. Both are
   small and generally useful; if accepted, the fork diff shrinks to *just*
   `compiler/nsharp/`.
6. Separate CI job + separate test dir (`nsharp/tests`) so upstream test churn
   never conflicts.

## 6. The one risk, stated plainly

`compiler/idents.nim` is the only place we reach into behavior Nim relies on
(case-insensitive identifier identity — SPEC §3.1). It is ~8 lines, guarded by
a flag that defaults **off**, and changes nothing unless the N# lexer toggles it.
This is the single hunk to re-check on every upstream rebase.

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
this program, dispatched by extension, with no other compiler file touched
beyond the three listed in §3.

---

*Change log*
- **v1** — initial integration architecture: seam findings, the 3-file plan,
  directory layout, rebase/backport workflow, and the Phase 0 acceptance test.
