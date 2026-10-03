# N# frontend - the C# to Nim name mapping
#
# The tables that map a C# name to its Nim spelling, in one place.

import std/strutils

type
  NsRename* = tuple[cs: string, nim: string]

const
  ## C# built-in types to Nim equivalents. Only names whose Nim spelling differs
  ## appear here; everything else is passed through unchanged.
  NsPrimitiveTypes*: array[16, NsRename] = [
    ("int", "int32"), ("uint", "uint32"), ("long", "int64"),
    ("ulong", "uint64"), ("short", "int16"), ("ushort", "uint16"),
    ("byte", "uint8"), ("sbyte", "int8"), ("float", "float32"),
    ("double", "float64"), ("bool", "bool"), ("char", "char"),
    ("string", "string"), ("object", "RootRef"),
    ("nint", "int"), ("nuint", "uint"),
  ]

  ## The BCL class name of a C# built-in type, which C# accepts in place of the
  ## keyword. Mapping to the keyword keeps one Nim spelling per type.
  NsBclTypeNames*: array[16, NsRename] = [
    ("Int32", "int"), ("UInt32", "uint"), ("Int64", "long"), ("UInt64", "ulong"),
    ("Int16", "short"), ("UInt16", "ushort"), ("Byte", "byte"),
    ("SByte", "sbyte"), ("Single", "float"), ("Double", "double"),
    ("Boolean", "bool"), ("Char", "char"), ("String", "string"),
    ("Object", "object"), ("IntPtr", "nint"), ("UIntPtr", "nuint"),
  ]

  ## Bases that mark a class as an exception class. Such a class is emitted as a
  ## value `object` (so `except T` can match it) but is raised as `ref T`,
  ## because Nim can only raise a reference. `Exception` itself is left alone: it
  ## is Nim's exception root, which every `Defect` and `CatchableError` derives
  ## from, so `catch (Exception)` catches what C# would catch.
  NsExceptionBases*: array[17, string] = [
    "Exception", "CatchableError", "SystemException", "ApplicationException",
    "ArgumentException", "ArgumentNullException", "ArgumentOutOfRangeException",
    "InvalidOperationException", "ObjectDisposedException",
    "NotSupportedException", "NotImplementedException",
    "NullReferenceException", "OverflowException", "IndexOutOfRangeException",
    "DivideByZeroException", "InvalidCastException", "KeyNotFoundException",
  ]

  ## Member renames applied by the desugar pass. Which receiver kinds may be
  ## renamed is decided by `sema.nim`; `desugar.nim` applies the table.
  NsMemberRenames*: array[2, NsRename] = [
    ("Count", "len"), ("Message", "msg"),
  ]
  NsLengthMembers*: array[1, string] = ["Count"]
  NsMessageMembers*: array[1, string] = ["Message"]

  ## Type names N# knows the shape of, for `sema.nim`'s type classification.
  NsIntTypeNames*: array[10, string] = [
    "int", "uint", "long", "ulong", "short", "ushort", "byte", "sbyte",
    "nint", "nuint",
  ]
  NsFloatTypeNames*: array[2, string] = ["float", "double"]
  NsSequenceTypeNames*: array[5, string] = [
    "List", "Dictionary", "HashSet", "Queue", "Stack",
  ]

proc unqualified*(s: string): string =
  ## Drops the namespace qualifier from a type name: `A.B.C` becomes `C`. Imported
  ## symbols are flat, so the qualifier is decorative.
  let dot = s.rfind('.')
  if dot >= 0: s[dot + 1 .. ^1] else: s

proc canonicalTypeName*(s: string): string =
  ## The C# keyword spelling of a type name, without its qualifier:
  ## `System.Int32` and `Int32` both become `int`.
  result = unqualified(s)
  for r in NsBclTypeNames:
    if r.cs == result: return r.nim

proc nimTypeName*(s: string): string =
  ## Nim spelling of a C# type name, or its canonical form unchanged.
  result = canonicalTypeName(s)
  for r in NsPrimitiveTypes:
    if r.cs == result: return r.nim

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

proc isTypeName*(s: string): bool =
  ## True when `s` is spelled like a type: a C# built-in name, or anything starting
  ## uppercase, which is the convention `sema` also uses to spot a qualifier. A cast
  ## is told from a parenthesised expression by this test, since C# needs a symbol
  ## table to do it properly.
  if s.len == 0: return false
  if s[0] in {'A'..'Z'}: return true
  for r in NsPrimitiveTypes:
    if r.cs == s: return true
  false

proc knownTypeSpelling*(s: string): string =
  ## The Nim spelling of a built-in or tabulated type name, or "" when `s` is not
  ## one. A member access on such a receiver keeps it, so `int.MaxValue` reaches
  ## the library's declaration for `int32` through Nim's own dot-call.
  let canon = canonicalTypeName(s)
  for r in NsPrimitiveTypes:
    if r.cs == canon: return r.nim
  for n in NsSequenceTypeNames:
    if n == canon: return n
  ""

proc renamedMember*(s: string; nimName: var string): bool =
  ## True (with `nimName` set) when `s` has a rename.
  for r in NsMemberRenames:
    if r.cs == s:
      nimName = r.nim
      return true
  false
