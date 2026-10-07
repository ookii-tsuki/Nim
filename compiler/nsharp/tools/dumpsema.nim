# N# frontend - semantic-projection dump tool
#
# Prints the semantic facts the frontend resolved, one per line, in a canonical
# form that `tools/nsoracle` reproduces from Roslyn. This is the N# half of the
# semantic conformance gate (PARSER-CLEANUP.md, "Stage 0b"): the gate in
# `nsharp/tests/run_sema.sh` diffs the two projections, so a change that
# resolves a name to a different type or namespace than C# does fails, instead
# of only being caught by reading the diff.
#
# What is projected, and why only that:
#
#   * `using` directives - the namespaces a program imports.
#   * library member accesses - for `x.M` where `M` is a member the *prelude*
#     declares, the namespace the declaring module lives in and the member's
#     return class. The namespace is the fact that tells resolution *through the
#     library* from a name hardcoded in the compiler: `List.Add` is
#     `System.Collections.Generic`, `Console.WriteLine` is `System`.
#
# Only members of library types, and only those with a primitive/`void` result,
# are projected in this first cut. A member of a type the program itself declares
# is the program's own business, and a result that needs a richer vocabulary
# (an array, a collection, an exception) is left for a later stage: a projection
# that is exact for a small surface is worth more than one that is approximate
# for a large one. See `nsharp/CONFORMANCE.md` for the schema and its growth.
#
# Usage:
#   bin/nim1 c -o:/tmp/dumpsema compiler/nsharp/tools/dumpsema.nim
#   /tmp/dumpsema path/to/file.ns
#
# Normally exercised through nsharp/tests/run_sema.sh.

import std/[os, algorithm, strutils, syncio]
import ../../idents, ../../lineinfos, ../../msgs, ../../options, ../../pathutils
import ../ast as nsast, ../parser, ../bcl, ../sema, ../nsgen

# --- the shared vocabulary ---------------------------------------------------
#
# Both sides of the gate spell a result class the same way. Only the classes this
# stage projects appear; anything else is `other` and never reaches the output,
# because a member with an `other` result is not projected at all.

proc tokenOf(k: NsTypeKind): string =
  ## The shared token for a resolved type class. Deliberately coarse on the
  ## *numeric* axis (every integer is `int`) but exact on the axis that matters:
  ## the difference between a value, a string, a sequence and an object.
  case k
  of tkInt: "int"
  of tkFloat: "float"
  of tkBool: "bool"
  of tkChar: "char"
  of tkString: "string"
  of tkSequence: "seq"
  else: "other"

proc isProjected(k: string): bool =
  ## The result classes this stage reports.
  k in ["void", "int", "float", "bool", "char", "string"]

proc retTokenFor(surface: NsBclSurface; m: NsBclMember): string =
  ## The token for a library member's declared result. An empty spelling is C#'s
  ## `void`; a result that is one of the declaration's own type parameters
  ## (`Dequeue`'s `T`) is `other`, because the declaration alone does not name it;
  ## everything else is classified the way the frontend classifies a type name
  ## (`int32` and `Int32` alike are `int`).
  if m.retIsParam: "other"
  elif m.ret.len == 0: "void"
  else: tokenOf(surface.kindOfName(m.ret))

proc isValueKind(k: NsTypeKind): bool =
  ## The kinds a receiver has when it is a *value* rather than a type or a
  ## namespace. Only a value receiver names an instance member; a type qualifier
  ## (`Console.WriteLine`, `String.Concat`, `Array.IndexOf`) is a static access,
  ## which names no library member through the prelude and is left out here.
  ## A `T?` is left out too: the frontend lowers it to an `Option` whose members
  ## live in the intrinsics, which is no C# namespace for the oracle to agree on.
  k in {tkInt, tkFloat, tkBool, tkChar, tkString, tkSequence, tkClass,
        tkException}

proc recvSpelling(n: NsNode): string =
  ## How the receiver reads, in the shared vocabulary: the resolved type name when
  ## the frontend has one, otherwise the class of the resolved kind. An array has
  ## no name the frontend tracks, so it is `array`; a value is its keyword. An
  ## empty answer means the receiver could not be placed, and the access is not
  ## projected.
  if n == nil: return ""
  if n.typeName.len > 0: return n.typeName
  case n.typeKind
  of tkInt: "int"
  of tkFloat: "float"
  of tkBool: "bool"
  of tkChar: "char"
  of tkString: "string"
  of tkSequence: "array"
  of tkType: canonicalTypeName(n.name)
  else: ""

# --- walking ----------------------------------------------------------------

proc walk(n: NsNode; surface: NsBclSurface; facts: var seq[string];
         usings: var seq[string]) =
  ## Visits every node once, collecting the projected facts. `sons`, `params`,
  ## `body`, `typ` and `initArgs` are all traversed: a member access can sit in
  ## any of them.
  if n == nil: return
  case n.kind
  of nsnUsing:
    if n.alias.len > 0: usings.add "using " & n.alias & " = " & n.name
    else: usings.add "using " & n.name
  of nsnMember:
    ## A library member access: `x.M` where the prelude declares `M` for the
    ## receiver's type. The declaring module's namespace is the fact under test.
    let rk = (if n.body != nil: n.body.typeKind else: tkUnknown)
    if isValueKind(rk):
      let recv = recvSpelling(n.body)
      let m = surface.member(recv, rk, n.name)
      if m.name.len > 0 and recv.len > 0 and not m.isStatic:
        let tok = retTokenFor(surface, m)
        if isProjected(tok):
          facts.add "member " & recv & "." & n.name & " = " &
                    m.path.replace('/', '.') & " | " & tok
  else: discard
  walk(n.typ, surface, facts, usings)
  for p in n.params: walk(p, surface, facts, usings)
  walk(n.body, surface, facts, usings)
  for s in n.sons: walk(s, surface, facts, usings)
  for a in n.initArgs: walk(a, surface, facts, usings)

proc main() =
  var path = ""
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if path.len == 0: path = a
  if path.len == 0:
    stderr.write("usage: dumpsema <file.ns>\n")
    quit(2)
  var source = ""
  try:
    source = readFile(path)
  except CatchableError:
    stderr.write("dumpsema: cannot read " & path & "\n")
    quit(2)
  let conf = newConfigRef()
  ## The library the compilation is built against, exactly as a real build is
  ## handed it (`--lib:<root>/lib`). Without it the namespace scan cannot find the
  ## prelude's own modules, and a `using System;` reads as a namespace that does
  ## not exist.
  conf.libpath = AbsoluteDir(
    currentSourcePath().parentDir.parentDir.parentDir.parentDir / "lib")
  ## As in `dumpast`: keep going past the first error, so a file the frontend
  ## diagnoses can still yield whatever it resolved.
  conf.errorMax = high(int)
  let fileIdx = conf.fileInfoIdx(AbsoluteFile(path))
  let cache = newIdentCache()
  ## The prelude's surface and the compilation's declared types are what the
  ## parser and `sema` consult; resolve them the way a real build would.
  ensureNamespaces(conf, cache, AbsoluteFile(path))
  ## The prelude's surface registers the namespaces the prelude is written in
  ## (`System`, `System.Collections.Generic`, ...), which is what lets a `using`
  ## naming one of them resolve at parse time rather than being reported unknown.
  ## A real build has them in place before the first file is parsed; so does this.
  let surface = bclSurface(conf)
  let module = parseNsModule(source, fileIdx, conf)
  let scope = collectWithNamespaces(module, conf)
  checkModule(module, scope, conf)
  var facts: seq[string] = @[]
  var usings: seq[string] = @[]
  walk(module, surface, facts, usings)
  ## Usings first, then the resolution facts; each block sorted, so the output is
  ## stable regardless of the order the tree happens to be walked in.
  usings.sort()
  facts.sort()
  for u in usings: stdout.write u & "\n"
  for f in facts: stdout.write f & "\n"

when isMainModule:
  main()
