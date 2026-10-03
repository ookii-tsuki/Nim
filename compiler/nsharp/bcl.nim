#
#           N# frontend - the C# to Nim name mapping, in one place
#
# Stage 1 of PARSER-CLEANUP.md. These mappings used to be string rewrites spread
# through `parser.nim`; they live here so there is exactly one table to read when
# asking "what does N# do with this C# name?".
#
# Note on `NsMemberRenames`: applying a member rename without knowing the
# receiver's type is unsound (a user class with its own `Length` property is
# silently rewritten). The table is kept here because Stage 1 must reproduce the
# pre-refactor behaviour exactly; Stage 2 makes the use of it type-directed and
# will shrink it to the receivers that really are arrays/strings/exceptions.

type
  NsRename* = tuple[cs: string, nim: string]

const
  ## C# built-in types to Nim equivalents. Only names whose Nim spelling differs
  ## appear here; everything else is passed through unchanged.
  NsPrimitiveTypes*: array[15, NsRename] = [
    ("int", "int32"), ("uint", "uint32"), ("long", "int64"),
    ("ulong", "uint64"), ("short", "int16"), ("ushort", "uint16"),
    ("byte", "uint8"), ("sbyte", "int8"), ("float", "float32"),
    ("double", "float64"), ("bool", "bool"), ("char", "char"),
    ("string", "string"), ("object", "RootRef"),
    ("Exception", "CatchableError"),
  ]

  ## Bases that mark a class as an exception class. Such a class is emitted as a
  ## value `object` (so `except T` can match it) but is raised as `ref T`,
  ## because Nim can only raise a reference.
  NsExceptionBases*: array[9, string] = [
    "Exception", "CatchableError", "SystemException", "ArgumentException",
    "InvalidOperationException", "NullReferenceException", "OverflowException",
    "IndexOutOfRangeException", "NotSupportedException",
  ]

  ## C# BCL namespace to N# shim module (SPEC section 5.1). A namespace is only
  ## in scope once its `using` appears, exactly as in C#.
  NsNamespaceModules*: array[2, NsRename] = [
    ("System", "ns/system"),
    ("System.Collections.Generic", "ns/collections"),
  ]

  ## Member renames applied by the desugar pass. The *set of names* lives here;
  ## which receiver kinds may be renamed is decided by `sema.nim` (`.Length` is
  ## `len` only on a sequence or string, `.Message` is `msg` only on an
  ## exception), and `desugar.nim` applies the table below.
  NsMemberRenames*: array[3, NsRename] = [
    ("Length", "len"), ("Count", "len"), ("Message", "msg"),
  ]
  NsLengthMembers*: array[2, string] = ["Length", "Count"]
  NsMessageMembers*: array[1, string] = ["Message"]

  ## Type names N# knows the shape of. Used by `sema.nim` when it classifies a
  ## declared type, so lowering can decide `.Length` -> `.len` by type instead of
  ## by member name alone (SPEC section 15).
  NsIntTypeNames*: array[8, string] = [
    "int", "uint", "long", "ulong", "short", "ushort", "byte", "sbyte",
  ]
  NsFloatTypeNames*: array[2, string] = ["float", "double"]
  NsSequenceTypeNames*: array[5, string] = [
    "List", "Dictionary", "HashSet", "Queue", "Stack",
  ]

proc nimTypeName*(s: string): string =
  ## Nim spelling of a C# type name, or `s` unchanged.
  for r in NsPrimitiveTypes:
    if r.cs == s: return r.nim
  s

proc isExceptionBase*(s: string): bool =
  for b in NsExceptionBases:
    if b == s: return true
  false

proc moduleForNamespace*(ns: string): string =
  ## The shim module for a C# BCL namespace, or "" when N# has no shim for it.
  for r in NsNamespaceModules:
    if r.cs == ns: return r.nim
  ""

proc renamedMember*(s: string; nimName: var string): bool =
  ## True (with `nimName` set) when `s` has a rename.
  for r in NsMemberRenames:
    if r.cs == s:
      nimName = r.nim
      return true
  false
