#
#           N# frontend — keyword table
#
# See ../nsharp/GLOSSARY.md (repo root) for the authoritative list.
# Phase 0: keywords are lexed as identifiers and compared by text; this module
# centralises the reserved-word set the parser cares about.

import std/strutils

const NsharpReserved* = [
  # declarations / types
  "class", "struct", "interface", "enum", "delegate", "namespace",
  # modifiers
  "public", "private", "protected", "internal", "static", "abstract",
  "sealed", "virtual", "override", "new", "readonly", "const",
  # members / params
  "ref", "out", "in", "params", "this", "base", "operator", "explicit",
  "implicit", "extern", "unsafe",
  # control flow
  "if", "else", "switch", "case", "default", "while", "do", "for", "foreach",
  "break", "continue", "return", "throw", "try", "catch", "finally",
  "checked", "unchecked", "yield",
  # operators-as-keywords
  "is", "as", "typeof", "sizeof", "where",
  # built-in types
  "void", "bool", "byte", "sbyte", "short", "ushort", "int", "uint", "long",
  "ulong", "char", "float", "double", "string", "object",
  # literals
  "true", "false", "null",
  # N# extensions
  "when", "defer", "distinct", "inline", "noinline",
  # contextual keywords
  "var", "nameof", "get", "set", "value", "file",
  # directives
  "using"
]

proc isNsharpReserved*(s: string): bool =
  ## True if `s` is a reserved word in N# (case-sensitive).
  for k in NsharpReserved:
    if k == s: return true
  false
