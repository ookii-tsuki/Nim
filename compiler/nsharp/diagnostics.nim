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
    ndCannotConvert
    ndCannotConvertNull
    ndArgumentNoOverload
    ndArgumentCannotConvert
    ndCtorNoOverload
    ndMissingArgument
    ndNotAnException
    ndNullableAnnotation
    ndUnexpectedCharacter
    ndIntegralConstantTooLarge
    ndCannotConvertExplicit
    ndDefineAfterToken
    ndNotAssignable
    ndReadonlyAssigned
    ndStaticReadonlyAssigned
    ndConstNeedsValue
    ndAbstractInstance
    ndSealedBase
    ndNoOverrideSlot
    ndOverrideNotVirtual
    ndOverrideSealed
    ndAbstractInConcrete
    ndAbstractHasBody
    ndMissingBody
    ndSealedNotOverride
    ndAbstractNotImplemented
    ndInterfaceNotImplemented
    ndNoCollectionTarget
    ndNestedFileType
    ndEventAccessors
    ndEventAccessorUse
    ndPartialNeedsImpl
    ndVarianceNotAllowed
    ndInvalidVariance
    ndArrayInitLength
    ndAnonDeclarator
    ndAnonDuplicate
    ndAnonBadValue
    ndCheckedNotAllowed
    ndCheckedImplicit
    ndCheckedNeedsUnchecked
    ndTypeArgCount
    ndNotGenericType
    ndPrimaryNotChained
    ndWithNotRecord
    ndRequiredMember
    ndReadOnlyProperty
    ndInitOnly
    ndEventOutside
    ndObsolete
    ndObsoleteNoMessage
    ndObsoleteError
    ndNotAttributeClass
    ndStaticClassInstance
    ndStaticClassMember
    ndExtensionNotStatic
    ndNotDisposable
    ndNotIteratorType
    ndYieldHere
    ndErrorDirective
    ndWarningDirective
    ndUnsupported

  NsDiagInfo* = tuple[code, msg: string]

const
  NsDiagText*: array[NsDiag, NsDiagInfo] = [
    ndNotAccessible: (code: "0122", msg: "'$1' is inaccessible due to its protection level"),
    ndNamespaceNotFound: (code: "0246", msg: "The type or namespace name '$1' could not be found" &
                        " (are you missing a using directive or an assembly" &
                        " reference?)"),
    ndIdentifierExpected: (code: "1001", msg: "Identifier expected"),
    ndSemicolonExpected: (code: "1002", msg: "';' expected"),
    ndSyntaxErrorExpected: (code: "1003", msg: "Syntax error, '$1' expected"),
    ndCloseParenExpected: (code: "1026", msg: "')' expected"),
    ndCloseBraceExpected: (code: "1513", msg: "'}' expected"),
    ndOpenBraceExpected: (code: "1514", msg: "'{' expected"),
    ndOpenBraceExpectedBody: (code: "1514", msg: "'{' expected to open the body of '$1'"),
    ndForeachInExpected: (code: "1515", msg: "'in' expected"),
    ndMemberDeclarationExpected: (code: "1519", msg: "Invalid token '$1' in class, record, struct, or" &
                        " interface member declaration"),
    ndInvalidExpressionTerm: (code: "1525", msg: "Invalid expression term '$1'"),
    ndSourceFileNotFound: (code: "2001", msg: "Source file '$1' could not be found"),
    ndBaseConstructorRequired: (code: "7036", msg: "'$1' must call a base constructor: '$2' has no" &
                        " accessible parameterless constructor"),
    ndConstructorRequired: (code: "7036", msg: "'$1' must define a constructor: '$2' has no accessible" &
                        " parameterless constructor"),
    ndParserStalled: (code: "9001", msg: "the parser made no progress; skipping the token"),
    ndNamespaceCycle: (code: "9002", msg: "'$1' and '$2' use each other; Nim cannot compile" &
                        " mutually dependent namespaces"),
    ndCannotConvert: (code: "0029", msg: "Cannot implicitly convert type '$1' to '$2'"),
    ndCannotConvertNull: (code: "0037", msg: "Cannot convert null to '$1' because it is a" &
                        " non-nullable value type"),
    ndArgumentNoOverload: (code: "1501", msg: "No overload for method '$1' takes $2 arguments"),
    ndArgumentCannotConvert: (code: "1503", msg: "Argument $1: cannot convert from '$2' to '$3'"),
    ndCtorNoOverload: (code: "1729", msg: "'$1' does not contain a constructor that takes $2" &
                        " arguments"),
    ndMissingArgument: (code: "7036", msg: "There is no argument given that corresponds to the" &
                        " required parameter '$1' of '$2'"),
    ndNotAnException: (code: "0155", msg: "The type caught or thrown must be derived from" &
                        " System.Exception"),
    ndNullableAnnotation: (code: "8632", msg: "The annotation for nullable reference types should only" &
                        " be used in code within a '#nullable' annotations context."),
    ndUnexpectedCharacter: (code: "1056", msg: "Unexpected character '$1'"),
    ndIntegralConstantTooLarge: (code: "1021", msg: "Integral constant is too large"),
    ndCannotConvertExplicit: (code: "0266", msg: "Cannot implicitly convert type '$1' to '$2'. An explicit" &
                        " conversion exists (are you missing a cast?)"),
    ndDefineAfterToken: (code: "1032", msg: "Cannot define/undefine preprocessor symbols after first" &
                        " token in file"),
    ndNotAssignable: (code: "0131", msg: "The left-hand side of an assignment must be a variable," &
                        " property or indexer"),
    ndReadonlyAssigned: (code: "0191", msg: "A readonly field cannot be assigned to (except in a" &
                        " constructor or init-only setter of the type in which the" &
                        " field is defined or a variable initializer)"),
    ndStaticReadonlyAssigned: (code: "0198", msg: "A static readonly field cannot be assigned to (except in a" &
                        " static constructor or a variable initializer)"),
    ndConstNeedsValue: (code: "0145", msg: "A const field requires a value to be provided"),
    ndAbstractInstance: (code: "0144", msg: "Cannot create an instance of the abstract type or interface" &
                        " '$1'"),
    ndSealedBase: (code: "0509", msg: "'$1': cannot derive from sealed type '$2'"),
    ndNoOverrideSlot: (code: "0115", msg: "'$1': no suitable method found to override"),
    ndOverrideNotVirtual: (code: "0506", msg: "'$1': cannot override inherited member" &
                        " '$2' because it is not marked virtual, abstract, or override"),
    ndOverrideSealed: (code: "0239", msg: "'$1': cannot override inherited member '$2' because it is" &
                        " sealed"),
    ndAbstractInConcrete: (code: "0513", msg: "'$1' is abstract but it is contained in non-abstract type" &
                        " '$2'"),
    ndAbstractHasBody: (code: "0500", msg: "'$1' cannot declare a body because it is marked abstract"),
    ndMissingBody: (code: "0501", msg: "'$1' must declare a body because it is not marked abstract," &
                        " extern, or partial"),
    ndSealedNotOverride: (code: "0238", msg: "'$1' cannot be sealed because it is not an override"),
    ndAbstractNotImplemented: (code: "0534", msg: "'$1' does not implement inherited abstract member '$2'"),
    ndInterfaceNotImplemented: (code: "0535", msg: "'$1' does not implement interface" &
                        " member '$2'"),
    ndNoCollectionTarget: (code: "9176", msg: "There is no target type for the collection expression."),
    ndNestedFileType: (code: "9054", msg: "File-local type '$1' must be defined in a top level type;" &
                     " '$1' is a nested type."),
    ndEventAccessors: (code: "0065", msg: "'$1': event property must have both add and remove accessors"),
    ndEventAccessorUse: (code: "0079", msg: "The event '$1' can only appear on the left hand side of" &
                       " += or -="),
    ndPartialNeedsImpl: (code: "8795", msg: "Partial method '$1' must have an implementation part" &
                       " because it has accessibility modifiers."),
    ndVarianceNotAllowed: (code: "1960", msg: "Invalid variance modifier. Only interface and" &
                         " delegate type parameters can be specified as variant."),
    ndInvalidVariance: (code: "1961", msg: "Invalid variance: The type parameter '$1' must be" &
                      " $2 valid on '$3'. '$1' is $4."),
    ndArrayInitLength: (code: "0847", msg: "An array initializer of length '$1' is expected"),
    ndAnonDeclarator: (code: "0746", msg: "Invalid anonymous type member declarator. Anonymous type" &
                     " members must be declared with a member assignment, simple name or member access."),
    ndAnonDuplicate: (code: "0833", msg: "An anonymous type cannot have multiple properties with the" &
                    " same name"),
    ndAnonBadValue: (code: "0828", msg: "Cannot assign '$1' to anonymous type property"),
    ndCheckedNotAllowed: (code: "9023", msg: "User-defined operator '$1' cannot be declared checked"),
    ndCheckedImplicit: (code: "9024", msg: "An 'implicit' user-defined conversion operator cannot" &
                      " be declared checked"),
    ndCheckedNeedsUnchecked: (code: "9025", msg: "The operator '$1' requires a matching non-checked" &
                            " version of the operator to also be defined"),
    ndTypeArgCount: (code: "0305", msg: "Using the generic type '$1' requires $2 type arguments"),
    ndNotGenericType: (code: "0308", msg: "The non-generic type '$1' cannot be used with type arguments"),
    ndPrimaryNotChained: (code: "8862", msg: "A constructor declared in a type with parameter list must" &
                        " have 'this' constructor initializer."),
    ndWithNotRecord: (code: "8858", msg: "The receiver type '$1' is not a valid record type and is not" &
                        " a struct type."),
    ndRequiredMember: (code: "9035", msg: "Required member '$1' must be set in the object initializer or" &
                        " attribute constructor."),
    ndReadOnlyProperty: (code: "0200", msg: "Property or indexer '$1' cannot be assigned to -- it is" &
                        " read only"),
    ndInitOnly: (code: "8852", msg: "Init-only property or indexer '$1' can only be assigned in an" &
                        " object initializer, or on 'this' or 'base' in an instance" &
                        " constructor or an 'init' accessor."),
    ndEventOutside: (code: "0070", msg: "The event '$1' can only appear on the left hand side of +=" &
                        " or -= (except when used from within the type '$2')"),
    ndObsolete: (code: "0618", msg: "'$1' is obsolete: '$2'"),
    ndObsoleteNoMessage: (code: "0612", msg: "'$1' is obsolete"),
    ndObsoleteError: (code: "0619", msg: "'$1' is obsolete: '$2'"),
    ndNotAttributeClass: (code: "0616", msg: "'$1' is not an attribute class"),
    ndStaticClassInstance: (code: "0712", msg: "Cannot create an instance of the static class '$1'"),
    ndStaticClassMember: (code: "0708", msg: "'$1': cannot declare instance members in a static class"),
    ndExtensionNotStatic: (code: "1106", msg: "Extension method must be defined in a non-generic static" &
                        " class"),
    ndNotDisposable: (code: "1674", msg: "'$1': type used in a using statement must implement" &
                        " 'System.IDisposable'"),
    ndNotIteratorType: (code: "1624", msg: "The body cannot be an iterator block because" &
                        " '$1' is not an iterator interface type"),
    ndYieldHere: (code: "1621", msg: "The yield statement cannot be used inside an anonymous" &
                        " method or lambda expression"),
    ndErrorDirective: (code: "1029", msg: "#error: '$1'"),
    ndWarningDirective: (code: "1030", msg: "#warning: '$1'"),
    ndUnsupported: (code: "9999", msg: "$1 is currently unsupported"),
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

proc nsWarn*(conf: ConfigRef; info: TLineInfo; d: NsDiag;
             args: varargs[string]) =
  ## Reports `d` at `info` as a warning, with the same code-led text an error would
  ## carry. `warnUser` is the compiler's door for a message of its own, so
  ## `--warnings:off` silences it exactly as it silences Nim's own warnings, and
  ## `--warningAsError` promotes it.
  message(conf, info, warnUser, nsCode(d) & ": " & NsDiagText[d].msg % @args)
