# N# frontend - diagnostics
#
# Every N# diagnostic, with the code it reports. The digits are the code the C#
# compiler uses for the same condition, so an N# error can be looked up in the C#
# documentation: `NS0246` is `CS0246`. `NS9999` is the one code for every construct
# N# does not support yet, so a temporary gap occupies no code of its own. Rules C#
# does not have -- those of N#'s own native interop -- take codes from `NS9901` up,
# which is clear of the `CS9xxx` codes the C# compiler keeps adding below it.

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
    ndUnaryOperand
    ndLambdaToValue
    ndStaticVariable
    ndNoStaticMember
    ndIterVarAssign
    ndNotConstant
    ndRefNotVariable
    ndDuplicateParam
    ndDuplicateType
    ndIfaceReturn
    ndStaticCtorParams
    ndMultipleBases
    ndNotInterface
    ndVoidProperty
    ndConstantExpected
    ndUsedBeforeDecl
    ndNoNamedParam
    ndLambdaArity
    ndMethodGroupMismatch
    ndRefTypeConstraint
    ndValueTypeConstraint
    ndUnassignedLocal
    ndOutUnassigned
    ndRefArgMissing
    ndNoGetter
    ndNotIndexable
    ndNotEnumerable
    ndTypeAsValue
    ndNotCallable
    ndDuplicateMember
    ndDuplicateMethod
    ndMethodGroupConv
    ndFloatLiteral
    ndTernaryTypes
    ndCannotCast
    ndOperatorTypes
    ndDuplicateLocal
    ndLocalShadows
    ndVarNeedsInit
    ndVarBadInit
    ndNotAStatement
    ndNoEnclosingLoop
    ndNotAllPathsReturn
    ndFallThrough
    ndFallOut
    ndDuplicateCase
    ndReturnInVoid
    ndReturnNeedsValue
    ndNoMember
    ndStaticViaInstance
    ndNameNotFound
    ndObjectRefRequired
    ndThisInStatic
    ndFinalizerName
    ndFinalizerInStruct
    ndFinalizerNeverRuns
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
    ndNativeNew
    ndNativeThisNoHandle
    ndNativeNoSelfHandle
    ndExternOutsideNative
    ndNativeCtor
    ndExportMisplaced
    ndNativeBaseNotNative
    ndNativeMemberNotExtern
    ndNativeFieldStatic
    ndNativeCtorEarly
    ndForwardMisplaced
    ndReturnOwnership
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
    ndUnaryOperand: (code: "0023", msg: "Operator '$1' cannot be applied to operand of type '$2'"),
    ndLambdaToValue: (code: "1660", msg: "Cannot convert lambda expression to type '$1' because it is" &
                    " not a delegate type"),
    ndStaticVariable: (code: "0723", msg: "Cannot declare a variable of static type '$1'"),
    ndNoStaticMember: (code: "0117", msg: "'$1' does not contain a definition for '$2'"),
    ndIterVarAssign: (code: "1656", msg: "Cannot assign to '$1' because it is a '$2'"),
    ndNotConstant: (code: "0133", msg: "The expression being assigned to '$1' must be constant"),
    ndRefNotVariable: (code: "1510", msg: "A ref or out value must be an assignable variable"),
    ndDuplicateParam: (code: "0100", msg: "The parameter name '$1' is a duplicate"),
    ndDuplicateType: (code: "0101", msg: "The namespace '$1' already contains a definition for '$2'"),
    ndIfaceReturn: (code: "0738", msg: "'$1' does not implement interface member '$2'. '$3'" &
      " cannot implement '$2' because it does not have the matching return type of '$4'."),
    ndStaticCtorParams: (code: "0132", msg: "'$1': a static constructor must be parameterless"),
    ndMultipleBases: (code: "1721", msg: "Class '$1' cannot have multiple base classes: '$2' and '$3'"),
    ndNotInterface: (code: "0527", msg: "Type '$1' in interface list is not an interface"),
    ndVoidProperty: (code: "0547", msg: "'$1': property or indexer cannot have void type"),
    ndConstantExpected: (code: "9135", msg: "A constant value of type '$1' is expected"),
    ndUsedBeforeDecl: (code: "0841", msg: "Cannot use local variable '$1' before it is declared"),
    ndNoNamedParam: (code: "1739", msg: "The best overload for '$1' does not have a parameter named" &
                   " '$2'"),
    ndLambdaArity: (code: "1593", msg: "Delegate '$1' does not take $2 arguments"),
    ndMethodGroupMismatch: (code: "0123", msg: "No overload for '$1' matches delegate '$2'"),
    ndRefTypeConstraint: (code: "0452", msg: "The type '$1' must be a reference type in order to use" &
                        " it as parameter '$2' in the generic type or method '$3'"),
    ndValueTypeConstraint: (code: "0453", msg: "The type '$1' must be a non-nullable value type in" &
                          " order to use it as parameter '$2' in the generic type or method '$3'"),
    ndUnassignedLocal: (code: "0165", msg: "Use of unassigned local variable '$1'"),
    ndOutUnassigned: (code: "0177", msg: "The out parameter '$1' must be assigned to before control" &
                    " leaves the current method"),
    ndRefArgMissing: (code: "1620", msg: "Argument $1 must be passed with the '$2' keyword"),
    ndNoGetter: (code: "0154", msg: "The property or indexer '$1' cannot be used in this context" &
               " because it lacks the get accessor"),
    ndNotIndexable: (code: "0021", msg: "Cannot apply indexing with [] to an expression of type '$1'"),
    ndNotEnumerable: (code: "1579", msg: "foreach statement cannot operate on variables of type '$1'" &
                    " because '$1' does not contain a public instance or extension definition for" &
                    " 'GetEnumerator'"),
    ndTypeAsValue: (code: "0119", msg: "'$1' is a type, which is not valid in the given context"),
    ndNotCallable: (code: "0149", msg: "Method name expected"),
    ndDuplicateMember: (code: "0102", msg: "The type '$1' already contains a definition for '$2'"),
    ndDuplicateMethod: (code: "0111", msg: "Type '$1' already defines a member called '$2' with the" &
                      " same parameter types"),
    ndMethodGroupConv: (code: "0428", msg: "Cannot convert method group '$1' to non-delegate type" &
                      " '$2'. Did you intend to invoke the method?"),
    ndFloatLiteral: (code: "0664", msg: "Literal of type double cannot be implicitly converted to" &
                   " type '$1'; use an '$2' suffix to create a literal of this type"),
    ndTernaryTypes: (code: "0173", msg: "Type of conditional expression cannot be determined because" &
                   " there is no implicit conversion between '$1' and '$2'"),
    ndCannotCast: (code: "0030", msg: "Cannot convert type '$1' to '$2'"),
    ndOperatorTypes: (code: "0019", msg: "Operator '$1' cannot be applied to operands of type '$2'" &
                    " and '$3'"),
    ndDuplicateLocal: (code: "0128", msg: "A local variable or function named '$1' is already defined" &
                     " in this scope"),
    ndLocalShadows: (code: "0136", msg: "A local or parameter named '$1' cannot be declared in this" &
                   " scope because that name is used in an enclosing local scope to define a local" &
                   " or parameter"),
    ndVarNeedsInit: (code: "0818", msg: "Implicitly-typed variables must be initialized"),
    ndVarBadInit: (code: "0815", msg: "Cannot assign $1 to an implicitly-typed variable"),
    ndNotAStatement: (code: "0201", msg: "Only assignment, call, increment, decrement, await, and new" &
                    " object expressions can be used as a statement"),
    ndNoEnclosingLoop: (code: "0139", msg: "No enclosing loop out of which to break or continue"),
    ndNotAllPathsReturn: (code: "0161", msg: "'$1': not all code paths return a value"),
    ndFallThrough: (code: "0163", msg: "Control cannot fall through from one case label ('$1') to" &
                  " another"),
    ndFallOut: (code: "8070", msg: "Control cannot fall out of switch from final case label ('$1')"),
    ndDuplicateCase: (code: "0152", msg: "The switch statement contains multiple cases with the label" &
                    " value '$1'"),
    ndReturnInVoid: (code: "0127", msg: "Since '$1' returns void, a return keyword must not be" &
                   " followed by an object expression"),
    ndReturnNeedsValue: (code: "0126", msg: "An object of a type convertible to '$1' is required"),
    ndNoMember: (code: "1061", msg: "'$1' does not contain a definition for '$2' and no accessible" &
               " extension method '$2' accepting a first argument of type '$1' could be found"),
    ndStaticViaInstance: (code: "0176", msg: "Member '$1' cannot be accessed with an instance" &
                        " reference; qualify it with a type name instead"),
    ndNameNotFound: (code: "0103", msg: "The name '$1' does not exist in the current context"),
    ndObjectRefRequired: (code: "0120", msg: "An object reference is required for the non-static" &
                        " field, method, or property '$1'"),
    ndThisInStatic: (code: "0026", msg: "Keyword 'this' is not valid in a static property, static" &
                   " method, or static field initializer"),
    ndFinalizerName: (code: "0574", msg: "Name of destructor must match name of type"),
    ndFinalizerInStruct: (code: "0575", msg: "Only class types can contain destructors"),
    ndFinalizerNeverRuns: (code: "9998", msg: "The finalizer of '$1' never runs: N# has no" &
                         " garbage collector to call it"),
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
    ndNativeNew: (code: "9901", msg: "Cannot create an instance of '$1' with 'new': it is" &
                        " a native class with a handle, which the engine creates and owns;" &
                        " use the engine's own factory"),
    ndNativeThisNoHandle: (code: "9902", msg: "'this' cannot be used as a value in '$1':" &
                        " its native base '$2' has no handle, and the engine may move the" &
                        " object; use 'this' only to reach members"),
    ndNativeNoSelfHandle: (code: "9903", msg: "'this' cannot be used as a value in '$1':" &
                        " the handle class '$2' names no 'SelfHandle' in its [Native]" &
                        " attribute"),
    ndExternOutsideNative: (code: "9904", msg: "'$1': an 'extern' member must belong to a" &
                        " type marked [Native]"),
    ndNativeCtor: (code: "9905", msg: "'$1': a [Native] class with a handle cannot" &
                        " declare a constructor; the engine constructs it"),
    ndExportMisplaced: (code: "9906", msg: "'$1': [Export] applies only to a non-generic" &
                        " static method"),
    ndNativeBaseNotNative: (code: "9907", msg: "'$1': a [Native] type cannot derive from" &
                        " '$2', which is not [Native]"),
    ndNativeMemberNotExtern: (code: "9908", msg: "'$1': a member of a [Native] type must be" &
                        " 'extern' and have no body"),
    ndNativeFieldStatic: (code: "9909", msg: "'$1': a field of a [Native] type is the C++" &
                        " type's, so it cannot be static or initialised"),
    ndNativeCtorEarly: (code: "9910", msg: "'$1' in a constructor of '$2': the engine" &
                        " may not have finished setting up the native object yet"),
    ndForwardMisplaced: (code: "9911", msg: "'$1': [Forward] applies only to the last" &
                        " parameter, 'params object[]', of a generic 'extern' method"),
    ndReturnOwnership: (code: "9912", msg: "'$1': [return: Borrowed] and [return: Owned]" &
                        " apply only to an 'extern' method returning a native class with no" &
                        " handle, and only one of them"),
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
