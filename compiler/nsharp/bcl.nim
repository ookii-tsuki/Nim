# N# frontend - the C# to Nim name mapping
#
# The tables that map a C# name to its Nim spelling, in one place.

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

  ## C# BCL namespace to N# shim module. A namespace is only
  ## in scope once its `using` appears, exactly as in C#.
  NsNamespaceModules*: array[2, NsRename] = [
    ("System", "ns/system"),
    ("System.Collections.Generic", "ns/collections"),
  ]

  ## Member renames applied by the desugar pass. Which receiver kinds may be
  ## renamed is decided by `sema.nim`; `desugar.nim` applies the table.
  NsMemberRenames*: array[3, NsRename] = [
    ("Length", "len"), ("Count", "len"), ("Message", "msg"),
  ]
  NsLengthMembers*: array[2, string] = ["Length", "Count"]
  NsMessageMembers*: array[1, string] = ["Message"]

  ## Type names N# knows the shape of, for `sema.nim`'s type classification.
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
