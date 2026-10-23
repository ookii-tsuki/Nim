# N# standard library: the pragmas the prelude marks its declarations with.
#
# They carry no code; the frontend reads them from the prelude's source (see
# `compiler/nsharp/bcl.nim`). They live outside the namespaces because a cycle of
# modules checks its types before its templates, and the types use them.

template nsStatic*(typ: string) {.pragma.}
  ## `{.nsStatic: "T".}` marks a proc C# reaches through a type qualifier
  ## (`Console.WriteLine`, `String.Concat`) rather than a receiver; the frontend
  ## re-files it as a member of that type, marked `static`. A name the library
  ## cannot place is reported rather than skipped. Members over `typedesc` already
  ## name their type, so they carry no pragma.

template nsInterface*() {.pragma.}
  ## `{.nsInterface.}` marks a C# interface the library declares. One with no
  ## `nsObj`/`nsVt` fields is a contract: a class may name it in its base list
  ## and N# checks the members exist (Nim's generics call them by name). One with
  ## them is a value, as a user's interface lowers.

template nsHidden*() {.pragma.}
  ## `{.nsHidden.}` marks a helper the library exports for the code N# generates
  ## (`nsBox`, `newList`, `items`) but that is not a C# member: the frontend leaves
  ## it out of the surface, so N# source cannot name it. `{.push nsHidden.}` marks
  ## every declaration up to its `{.pop.}`.
