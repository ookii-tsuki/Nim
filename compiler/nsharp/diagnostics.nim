# N# frontend - diagnostics
#
# Every N# diagnostic, with the code it reports. The digits are the code the C#
# compiler uses for the same condition, so an N# error can be looked up in the C#
# documentation: `NS0246` is `CS0246`. `NS9999` is the one code for every construct
# N# does not support yet, so a temporary gap occupies no code of its own, and the
# rest of the 9xxx band is reserved for conditions C# accepts.

import std/strutils
import ../lineinfos, ../msgs, ../options

type
  NsDiag* = enum
    ndNotAccessible
    ndNamespaceNotFound
    ndIdentifierExpected
    ndSemicolonExpected
    ndSyntaxErrorExpected
    ndCloseParenExpected
    ndCloseBraceExpected
    ndOpenBraceExpected
    ndOpenBraceExpectedBody
    ndForeachInExpected
    ndMemberDeclarationExpected
    ndInvalidExpressionTerm
    ndSourceFileNotFound
    ndBaseConstructorRequired
    ndConstructorRequired
    ndParserStalled
    ndNamespaceCycle
    ndUnsupported

  NsDiagInfo* = tuple[code, msg: string]

const
  NsDiagText*: array[NsDiag, NsDiagInfo] = [
    (code: "0122", msg: "'$1' is inaccessible due to its protection level"),
    (code: "0246", msg: "The type or namespace name '$1' could not be found" &
                        " (are you missing a using directive or an assembly" &
                        " reference?)"),
    (code: "1001", msg: "Identifier expected"),
    (code: "1002", msg: "';' expected"),
    (code: "1003", msg: "Syntax error, '$1' expected"),
    (code: "1026", msg: "')' expected"),
    (code: "1513", msg: "'}' expected"),
    (code: "1514", msg: "'{' expected"),
    (code: "1514", msg: "'{' expected to open the body of '$1'"),
    (code: "1515", msg: "'in' expected"),
    (code: "1519", msg: "Invalid token '$1' in class, record, struct, or" &
                        " interface member declaration"),
    (code: "1525", msg: "Invalid expression term '$1'"),
    (code: "2001", msg: "Source file '$1' could not be found"),
    (code: "7036", msg: "'$1' must call a base constructor: '$2' has no" &
                        " accessible parameterless constructor"),
    (code: "7036", msg: "'$1' must define a constructor: '$2' has no accessible" &
                        " parameterless constructor"),
    (code: "9001", msg: "the parser made no progress; skipping the token"),
    (code: "9002", msg: "'$1' and '$2' use each other; Nim cannot compile" &
                        " mutually dependent namespaces"),
    (code: "9999", msg: "$1 is currently unsupported"),
  ]

proc nsCode*(d: NsDiag): string =
  ## The code N# reports, such as `NS0246`.
  "NS" & NsDiagText[d].code

proc nsError*(conf: ConfigRef; info: TLineInfo; d: NsDiag;
              args: varargs[string]) =
  ## Reports `d` at `info`. The code leads the message, so the compiler's usual
  ## `file(line, col) Error:` prefix is unchanged and the error still counts
  ## towards `errorMax` and reaches the structured error hook.
  localError(conf, info, nsCode(d) & ": " & NsDiagText[d].msg % @args)
