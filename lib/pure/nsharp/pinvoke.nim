# N#'s P/Invoke from a shared library: the library is loaded, and the function
# found, when a `[DllImport("lib")]` method is first called, as .NET does, so a
# binding for another platform costs nothing until it is used and a missing one
# throws an exception the program can catch. A module imports this only when it
# has such a method; `"__Internal"` ones are linked in and need none of it.

import std/[dynlib, tables]
from ../ns/System import DllNotFoundException, EntryPointNotFoundException, nsNewException

var nsLibraries: Table[string, LibHandle]

proc nsLoadLibrary(name: string): LibHandle =
  ## The library as .NET probes for it: the name as written, then with the
  ## platform's prefix and suffix (`m` finds `libm.so`).
  result = nsLibraries.getOrDefault(name)
  if result != nil: return
  when defined(windows):
    let candidates = [name, name & ".dll"]
  elif defined(macosx):
    let candidates = [name, name & ".dylib", "lib" & name & ".dylib"]
  else:
    let candidates = [name, name & ".so", "lib" & name & ".so", "lib" & name]
  for c in candidates:
    result = loadLib(c)
    if result != nil: break
  if result == nil:
    raise nsNewException(DllNotFoundException, "Unable to load shared library '" & name &
                         "' or one of its dependencies.")
  nsLibraries[name] = result

proc nsPInvokeEntry*(library, entry: string): pointer =
  ## The C function `entry` of `library`, loaded on first use.
  result = symAddr(nsLoadLibrary(library), entry)
  if result == nil:
    raise nsNewException(EntryPointNotFoundException, "Unable to find an entry point named '" &
                         entry & "' in shared library '" & library & "'.")
