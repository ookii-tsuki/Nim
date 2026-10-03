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

  ## Member renames applied by the desugar pass. Which receiver kinds may be
  ## renamed is decided by `sema.nim`; `desugar.nim` applies the table.
  NsMemberRenames*: array[2, NsRename] = [
    ("Count", "len"), ("Message", "msg"),
  ]
  NsLengthMembers*: array[1, string] = ["Count"]
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

proc namespaceModulePath*(ns: string): string =
  ## `A.B` as the module path `A/B`. `addFileExt` reads a trailing `.B` as a file
  ## extension, so the dots cannot be kept.
  result = newStringOfCap(ns.len)
  for c in ns:
    result.add(if c == '.': '/' else: c)

proc renamedMember*(s: string; nimName: var string): bool =
  ## True (with `nimName` set) when `s` has a rename.
  for r in NsMemberRenames:
    if r.cs == s:
      nimName = r.nim
      return true
  false
