# N# frontend: semantic-projection dump tool.
#
# Prints the semantic facts the frontend resolved, one per line, in the form
# `tools/nsoracle` reproduces from Roslyn; `nsharp/tests/run_sema.sh` diffs them,
# so a name that resolves to a different type or namespace than C# does fails.
#
# Projected: `using` directives, and library member accesses -- the namespace the
# declaring module lives in, plus the member's return class. Only members of
# library types with a primitive/`void` result are projected for now. See
# `nsharp/CONFORMANCE.md` for the schema.
#
# Usage:
#   bin/nim1 c -o:/tmp/dumpsema compiler/nsharp/tools/dumpsema.nim
#   /tmp/dumpsema path/to/file.ns
#
# Normally exercised through nsharp/tests/run_sema.sh.

import std/[os, algorithm, strutils, syncio]
import ../../idents, ../../lineinfos, ../../msgs, ../../options, ../../pathutils
import ../ast as nsast, ../parser, ../bcl, ../sema, ../nsgen, ../symbols

# --- the shared vocabulary ---------------------------------------------------
#
# Both sides spell a result class the same way; anything outside this vocabulary
# is `other` and is not projected at all.

proc tokenOf(k: NsTypeKind): string =
  ## The shared token for a resolved type class: coarse on the numeric axis, exact
  ## on the axis that matters -- value, string, sequence, object.
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

proc retTokenFor(surface: NsBclSurface; m: NsBclMember;
                 recvKind: NsTypeKind): string =
  ## The token for a library member's declared result: "" is C#'s `void`, a result
  ## that is one of the declaration's own parameters is the *receiver's* type when
  ## static and `other` otherwise, and everything else is classified by name.
  if m.retIsParam:
    if m.isStatic: tokenOf(recvKind)
    else: "other"
  elif m.ret.len == 0: "void"
  else: tokenOf(surface.kindOfName(m.ret))

proc isValueKind(k: NsTypeKind): bool =
  ## The kinds a receiver has when it is a value rather than a type or a namespace,
  ## which is what names an instance member. A `T?` is left out: it lowers to an
  ## `Option` whose members live in the intrinsics, which is no C# namespace.
  k in {tkInt, tkFloat, tkBool, tkChar, tkString, tkSequence, tkClass,
        tkException}

proc recvSpelling(n: NsNode): string =
  ## How the receiver reads, in the shared vocabulary: the resolved type name when
  ## the frontend has one, otherwise the class of the resolved kind. "" means it
  ## could not be placed, and the access is not projected.
  if n == nil: return ""
  if n.typeKind == tkSequence and n.typeName.endsWith("[]"): return "array"
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

proc nsOf(path: string): string =
  ## The C# namespace of a declaring module. The intrinsics hold `System.Object`'s
  ## members (`ToString`), which every N# module sees without a `using`.
  if path == NsIntrinsicsPath: "System" else: path.replace('/', '.')

# --- walking ----------------------------------------------------------------

proc walk(n: NsNode; surface: NsBclSurface; scope: NsModuleScope;
          facts: var seq[string]; usings: var seq[string]) =
  ## Visits every node once, collecting the projected facts.
  if n == nil: return
  case n.kind
  of nsnUsing:
    if n.alias.len > 0: usings.add "using " & n.alias & " = " & n.name
    else: usings.add "using " & n.name
  of nsnMember:
    ## A library member access. The declaring module's namespace is the fact under
    ## test; a `Type.M` names a static member and is projected the same way.
    let rk = (if n.body != nil: n.body.typeKind else: tkUnknown)
    if rk == tkType:
      let recv = recvSpelling(n.body)
      let kind = surface.kindOfName(recv)
      let m = surface.member(recv, kind, n.name)
      if m.name.len > 0 and recv.len > 0 and m.isStatic:
        let tok = retTokenFor(surface, m, kind)
        if isProjected(tok):
          facts.add "member " & recv & "." & n.name & " = " &
                    nsOf(m.path) & " | " & tok
    elif isValueKind(rk) and n.body != nil and
         scope.findMemberInfo(n.body.typeName, n.name).name.len > 0:
      ## A member the program declares (an override of `ToString`) is not the
      ## library's, as Roslyn's side says too.
      discard
    elif isValueKind(rk):
      let recv = recvSpelling(n.body)
      let m = surface.member(recv, rk, n.name)
      if m.name.len > 0 and recv.len > 0 and not m.isStatic:
        let tok = retTokenFor(surface, m, rk)
        if isProjected(tok):
          facts.add "member " & recv & "." & n.name & " = " &
                    nsOf(m.path) & " | " & tok
  else: discard
  walk(n.typ, surface, scope, facts, usings)
  for p in n.params: walk(p, surface, scope, facts, usings)
  walk(n.body, surface, scope, facts, usings)
  for s in n.sons: walk(s, surface, scope, facts, usings)
  for a in n.initArgs: walk(a, surface, scope, facts, usings)

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
  ## The library a real build is handed (`--lib:<root>/lib`); without it the
  ## namespace scan cannot find the prelude's modules.
  conf.libpath = AbsoluteDir(
    currentSourcePath().parentDir.parentDir.parentDir.parentDir / "lib")
  ## As in `dumpast`: keep going past the first error.
  conf.errorMax = high(int)
  let fileIdx = conf.fileInfoIdx(AbsoluteFile(path))
  let cache = newIdentCache()
  ## Resolve the prelude's surface and the declared types the way a real build would.
  ensureNamespaces(conf, cache, AbsoluteFile(path))
  ## Registers the prelude's own namespaces before the first file is parsed, as a
  ## real build does.
  let surface = bclSurface(conf)
  let module = parseNsModule(source, fileIdx, conf)
  let scope = collectWithNamespaces(module, conf)
  checkModule(module, scope, conf)
  var facts: seq[string] = @[]
  var usings: seq[string] = @[]
  walk(module, surface, scope, facts, usings)
  ## Usings first, then the facts; each block sorted so the output is stable.
  usings.sort()
  facts.sort()
  for u in usings: stdout.write u & "\n"
  for f in facts: stdout.write f & "\n"

when isMainModule:
  main()
