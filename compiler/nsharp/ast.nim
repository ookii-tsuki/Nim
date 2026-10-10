# N# frontend - the N# syntax tree
#
# The parser's output and the input to sema and desugar. The tree mirrors C#
# syntax, not Nim's: a class is `nsnClassDecl`, `Console.WriteLine` stays a member
# access, `Length` stays `Length`, `int` stays `int`. The C#-to-Nim mapping
# happens later, in `bcl.nim` and `desugar.nim`.
#
# `NsNodeObj` is a flat record rather than Nim's tagged-variant `TNode`: reading
# the wrong branch of a variant raises `FieldDefect` at runtime, and these trees
# are small and short-lived, so safety of traversal is worth more than the bytes.
#
# Every node carries a `TLineInfo` so diagnostics from `sema` can point at the
# source. Names are stored as plain `string`; interning is `sema`'s job.

import std/strutils

import ../lineinfos

type
  NsAccess* = enum
    aPrivate, aProtected, aInternal, aPublic

  NsAttrs* = object
    ## Visibility and the one storage modifier that currently changes lowering.
    access*: NsAccess
    isStatic*: bool
    isConst*: bool          ## a `const` field: static, compile-time
    isReadonly*: bool       ## a `readonly` field: assigned only by an initializer or a ctor
    isVirtual*: bool        ## `virtual`: opens a dispatch slot
    isOverride*: bool       ## `override`: fills a base's slot
    isAbstract*: bool       ## `abstract`: a slot (or a class) with no implementation
    isSealed*: bool         ## `sealed`: closes a slot or a class
    isNew*: bool            ## `new`: hides a base member instead of overriding it

  NsDeclKind* = enum
    ## Storage class of a local declaration.
    dkVar, dkLet, dkConst

  NsClassKind* = enum
    ckClass, ckStruct, ckInterface

  NsArgConv* = enum
    ## The implicit conversion C# inserts for an argument, chosen by `sema.nim` from
    ## the parameter's declared type and applied by `desugar.nim`. `acNone` uses the
    ## argument as written; the other two are the two halves of `T?`.
    acNone
    acSome       ## a value into a `T?` parameter: `some[T](value)`
    acNoneOption ## `null` into a `T?` parameter: `none(T)`

  NsTypeKind* = enum
    ## Coarse type information attached to expressions by `sema.nim`; lowering
    ## consults it instead of guessing from names. Only the distinctions the
    ## lowering actually needs.
    tkUnknown      ## not resolved; lowering must stay conservative
    tkNullable     ## `T?` on a value type: a value that may be absent (`Option[T]`)
    tkInt          ## an integer type, so `/` means `div`
    tkFloat        ## a floating point type
    tkBool
    tkChar
    tkString       ## a string; `.Length` lowers to `len`
    tkSequence     ## array or collection; `.Length`/`.Count` lower to `len`
    tkException    ## an exception; `.Message` lowers to `msg`
    tkClass        ## a value of a user class
    tkType         ## a type or namespace name used as a receiver (`Console`)
    tkDelegate
    tkTuple        ## a value tuple; element names are aliases of `Item1..ItemN`

  NsNodeKind* = enum
    nsnEmpty
    # --- types ---
    nsnTypeName        # name, sons = generic arguments (may be empty)
    nsnArrayType       # typ = element type
    nsnNullableType    # typ = inner type                 (from `T?`)
    nsnVoidType
    # --- declarations ---
    nsnModule          # sons = top level declarations
    nsnUsing           # name (dotted, as written)
    nsnNamespace       # name, body (single statement)
    nsnClassDecl       # name, typ = base (or nil), sons = members
    nsnEnumDecl        # name, sons = nsnEnumField
    nsnEnumField       # name, body = value expression (or nil)
    nsnDelegateDecl    # name, typ = return type, params
    nsnMethodDecl      # name, typ = return type, params, body, attrs
    nsnCtorDecl        # name = init kind ("", "base", "this"), params, body,
                       #   sons = initializer arguments
    nsnPropertyDecl    # name, typ, params = [getBody, setBody], attrs
    nsnFieldDecl       # name, typ, body = initializer (or nil), attrs
    nsnOperatorDecl    # name = C# operator ("+", "==", "++", ...) or "implicit" /
                       #   "explicit" for a conversion; typ = result, params, body
    nsnIndexerDecl     # typ = element type, params = index parameters,
                       #   sons = [getter, setter] (either may be nil)
    nsnParam           # name, typ, body = default value (or nil), attrs
    nsnWhere           # name = type parameter, sons = constraints: types, or
                       #   nsnIdent "class" / "struct" / "new" / "notnull" / "unmanaged"
    # --- statements ---
    nsnBlock           # sons = statements
    nsnBlockStmt       # sons = statements; a braced block used as a statement
    nsnElseBranch      # body = statements
    nsnLocalDecl       # name, typ (or nil), body = initializer (or nil), attrs
    nsnExprStmt        # body = expression
    nsnAssign          # name = compound op ("" for plain), sons = [lhs, rhs]
    nsnIf              # sons = nsnIfBranch..., optionally trailing nsnBlock
    nsnIfBranch        # body = condition, sons = statements
    nsnWhile           # body = condition, sons = statements
    nsnFor             # body = nsnForHeader(sons = [init, cond, step]), sons = loop body
    nsnForHeader       # sons = [init, cond, step]
    nsnForeach         # name = loop variable, typ = declared type, body = iter,
                       #   sons = statements
    nsnSwitch          # body = subject, sons = nsnSwitchSection
    nsnSwitchSection   # name = "case" or "default", sons = labels, body = statements
    nsnTry             # sons = [body, nsnCatch..., optional nsnFinally]
    nsnCatch           # typ = exception type (or nil), name = variable, body
    nsnFinally         # body
    nsnReturn          # body = expression (or nil)
    nsnBreak
    nsnContinue
    nsnThrow           # body = expression
    nsnDoWhile         # body = condition, sons = statements
    nsnChecked         # sons = statements
    nsnUnchecked       # sons = statements
    # --- expressions ---
    nsnIdent           # name
    nsnIntLit          # intVal
    nsnFloatLit        # floatVal
    nsnStrLit          # strVal
    nsnCharLit         # intVal (codepoint)
    nsnBoolLit         # intVal (0/1)
    nsnThis
    nsnBase            # `base`, the receiver of `base.M()`
    nsnNull
    nsnCall            # body = callee, sons = arguments
    nsnMember          # body = receiver, name
    nsnIndex           # body = receiver, sons = indices
    nsnNew             # typ = constructed type, sons = arguments
    nsnNewArray        # typ = element type, sons = [size]      (from `new T[n]`)
    nsnArrayLit        # sons = elements                        (from `new T[] { .. }`)
    nsnUnary           # name = operator, body = operand
    nsnBinary          # name = operator, sons = [lhs, rhs]
    nsnNullDot         # name = marker name, body = guarded value, sons = [tail]
    nsnNullCoalesce    # name = "??", sons = [lhs, rhs]
    nsnTernary         # sons = [cond, ifTrue, ifFalse]
    nsnLambda          # params, body
    nsnIncDec          # name = "inc" or "dec", body = operand (from `++`/`--`)
    nsnCast            # typ = target type, body = operand    (from `(T)x`)
    nsnIs              # typ = type, body = operand           (from `x is T`)
    nsnAs              # typ = type, body = operand           (from `x as T`)
    nsnDefault         # typ = type                           (from `default(T)`)
    nsnNamedArg        # name, body = value                   (from `f(name: v)`)
    nsnRefArg          # name = "ref" / "out" / "in", body = the variable
    nsnOutDecl         # typ (nil for `var`), name            (from `f(out int x)`)
    nsnLocalFunc       # a nsnMethodDecl declared inside a body (C# 7 local function)
    nsnMultiDecl       # sons = nsnLocalDecl, one per declarator (`int a = 1, b = 2;`)
    nsnInitMember      # name, body = value or nsnInitList    (`new T { A = 1 }`)
    nsnInitIndex       # sons = indices, body = value         (`new T { [k] = v }`)
    nsnInitAdd         # sons = arguments of one `Add`        (`new T { 1, {k, v} }`)
    nsnInitList        # sons = nested initialisers           (`A = { 1, 2 }`)
    nsnTupleLit        # sons = elements (nsnNamedArg for a named one)
    nsnTupleType       # sons = nsnParam (name may be ""), one per element
    nsnDeconstruct     # sons = targets (nsnLocalDecl to declare, else an lvalue
                       #   or nsnPatDiscard), body = value     (`(a, b) = t`)
    nsnIsPattern       # body = subject, sons = [pattern]     (from `x is pattern`)
    nsnSwitchExpr      # body = subject, sons = nsnSwitchArm  (from `x switch { }`)
    nsnSwitchArm       # sons = [pattern, guard (or nil), value]
    nsnCaseLabel       # body = pattern, sons = [guard] when there is a `when`
    # --- patterns ---
    nsnPatType         # typ, name = designation ("" for none)   (`Circle c`)
    nsnPatConst        # body = constant expression              (`5`, `null`)
    nsnPatRel          # name = "<", "<=", ">", ">=", body = constant
    nsnPatAnd          # sons = patterns
    nsnPatOr           # sons = patterns
    nsnPatNot          # body = pattern
    nsnPatProp         # typ (or nil), name = designation, sons = nsnPatField
    nsnPatField        # name = member, body = pattern
    nsnPatVar          # name                                    (`var x`)
    nsnPatDiscard      #                                         (`_`)
    nsnInterpolated    # sons = nsnStrLit / nsnInterpHole parts  (from `$"..."`)
    nsnInterpHole      # body = value, sons = [alignment] (optional), strVal = format

  NsNode* = ref NsNodeObj
  NsNodeObj* = object
    kind*: NsNodeKind
    info*: TLineInfo
    name*: string
    intVal*: BiggestInt
    floatVal*: BiggestFloat
    strVal*: string
    typ*: NsNode              ## declared / return / base / element type
    attrs*: NsAttrs
    params*: seq[NsNode]      ## parameter list (methods, ctors, delegates, lambdas)
    sons*: seq[NsNode]
    body*: NsNode             ## primary body or expression (may be nil)
    declKind*: NsDeclKind     ## nsnLocalDecl only
    classKind*: NsClassKind   ## nsnClassDecl only
    alias*: string            ## nsnUsing only: the name an alias gives the target
    initKind*: string         ## nsnCtorDecl only: "", "base" or "this"
    initArgs*: seq[NsNode]    ## nsnCtorDecl only: initializer arguments
    bases*: seq[NsNode]       ## nsnClassDecl: every base type as written, in order
    typeParams*: seq[NsNode]  ## a generic declaration's `<T, U>`, as nsnTypeName
    constraints*: seq[NsNode] ## its `where` clauses, as nsnWhere
    typeArgs*: seq[NsNode]    ## nsnIdent / nsnMember: `M<int>` written at a call
    inits*: seq[NsNode]       ## nsnNew: its object/collection initialiser, and after
                              ## `sema.nim`, the statements that apply it
    explicitIface*: string    ## a member written `I.M`: the interface it implements
    paramMod*: string         ## nsnParam: "ref", "out", "in", "params", "this" or ""
    argParam*: NsNode         ## a call argument: the parameter it fills (set by sema)
    argElement*: bool         ## ... as one element of a `params` array
    typeKind*: NsTypeKind     ## set by `sema.nim` on expressions
    typeName*: string         ## the resolved type name behind `typeKind`
    argConv*: NsArgConv       ## `nsnCall`/`nsnNew` argument: C#'s implicit conversion
    argConvType*: string      ## ... and the element type name it is spelled with
    rtype*: NsNode            ## set by `sema.nim`: the value's full type as written
                              ## (`Stack2<string>`), when it is known
    conv*: string             ## set by `sema.nim`: the C# numeric type this value is
                              ## implicitly converted to where it is used ("" = none)

# --- constructors -----------------------------------------------------------
#
# These are the only sanctioned way to build nodes; they keep the "which fields
# mean something for this kind" convention in one place.

proc nsn*(kind: NsNodeKind; info: TLineInfo): NsNode =
  NsNode(kind: kind, info: info)

proc nsnIdent*(name: string; info: TLineInfo): NsNode =
  NsNode(kind: nsnIdent, info: info, name: name)

proc nsnIntLit*(v: BiggestInt; info: TLineInfo): NsNode =
  NsNode(kind: nsnIntLit, info: info, intVal: v)

proc nsnFloatLit*(v: BiggestFloat; info: TLineInfo): NsNode =
  NsNode(kind: nsnFloatLit, info: info, floatVal: v)

proc nsnStrLit*(v: string; info: TLineInfo): NsNode =
  NsNode(kind: nsnStrLit, info: info, strVal: v)

proc nsnCharLit*(v: BiggestInt; info: TLineInfo): NsNode =
  NsNode(kind: nsnCharLit, info: info, intVal: v)

proc nsnBoolLit*(v: bool; info: TLineInfo): NsNode =
  NsNode(kind: nsnBoolLit, info: info, intVal: (if v: 1 else: 0))

proc nsnTypeName*(name: string; info: TLineInfo): NsNode =
  NsNode(kind: nsnTypeName, info: info, name: name)

proc nsnArrayType*(elem: NsNode; info: TLineInfo): NsNode =
  NsNode(kind: nsnArrayType, info: info, typ: elem)

proc nsnNullableType*(inner: NsNode; info: TLineInfo): NsNode =
  ## `T?`: a nullable value type (`Option[T]` in Nim), or for a reference type just
  ## the reference, which C# reads as a nullability annotation.
  NsNode(kind: nsnNullableType, info: info, typ: inner)

proc nsnVoidType*(info: TLineInfo): NsNode =
  NsNode(kind: nsnVoidType, info: info)

proc nsnParam*(name: string; typ: NsNode; info: TLineInfo): NsNode =
  NsNode(kind: nsnParam, info: info, name: name, typ: typ)

proc nsnMember*(recv: NsNode; name: string; info: TLineInfo): NsNode =
  NsNode(kind: nsnMember, info: info, name: name, body: recv)

proc nsnBinary*(op: string; lhs, rhs: NsNode; info: TLineInfo): NsNode =
  result = NsNode(kind: nsnBinary, info: info, name: op)
  result.sons = @[lhs, rhs]

proc nsnUnary*(op: string; operand: NsNode; info: TLineInfo): NsNode =
  NsNode(kind: nsnUnary, info: info, name: op, body: operand)

# --- construction helpers ---------------------------------------------------

proc add*(n: NsNode; child: NsNode) =
  ## Appends `child`, ignoring nil so callers can pass optional sub-nodes.
  if child != nil: n.sons.add child

proc addParam*(n: NsNode; p: NsNode) =
  if p != nil: n.params.add p

proc isExported*(a: NsAttrs): bool =
  ## C# default member access is private; anything else is exported to Nim.
  a.access != aPrivate

proc describe*(n: NsNode): string =
  ## Short human-readable payload, used by `repr` and by diagnostics.
  if n == nil: return "<nil>"
  result = $n.kind
  case n.kind
  of nsnIdent, nsnTypeName, nsnMember, nsnUsing, nsnNamespace, nsnClassDecl,
     nsnEnumDecl, nsnEnumField, nsnDelegateDecl, nsnMethodDecl, nsnCtorDecl,
     nsnPropertyDecl, nsnFieldDecl, nsnParam, nsnLocalDecl, nsnForeach,
     nsnUnary, nsnBinary, nsnIncDec:
    if n.name.len > 0: result.add " " & n.name
    if n.kind == nsnUsing and n.alias.len > 0:
      ## `using P = A.B;`, spelled the way it was written.
      result.add " (as " & n.alias & ")"
  of nsnIntLit, nsnCharLit, nsnBoolLit:
    result.add " " & $n.intVal
    if n.strVal.len > 0: result.add " " & n.strVal
  of nsnFloatLit:
    result.add " " & formatFloat(float(n.floatVal), ffDefault, 0)
    if n.strVal.len > 0: result.add " " & n.strVal
  of nsnInterpHole:
    if n.strVal.len > 0: result.add " :" & n.strVal
  of nsnStrLit: result.add " " & escape(n.strVal)
  else: discard

proc repr*(n: NsNode; indent = 0): string =
  ## Deterministic tree dump for debugging the frontend itself. Not used by the
  ## golden tests: those pin the *desugared* Nim tree, which is the contract that
  ## matters to the rest of the compiler.
  result = repeat("  ", indent) & describe(n) & "\n"
  if n == nil: return
  let pad = repeat("  ", indent + 1)
  if n.typ != nil:
    result.add pad & "typ:\n" & repr(n.typ, indent + 2)
  for p in n.params:
    result.add pad & "param:\n" & repr(p, indent + 2)
  if n.body != nil:
    result.add pad & "body:\n" & repr(n.body, indent + 2)
  for s in n.sons:
    result.add repr(s, indent + 1)

proc replaceMarked*(n: NsNode; marker: string; repl: NsNode): NsNode =
  ## Every node named `marker` becomes `repl`, `n` itself included, and the result is
  ## returned. `sema.nim` uses this to put the guarded value back where a `?.` tail
  ## refers to it, so the tail is checked like any other expression.
  if n == nil: return nil
  if n.kind == nsnIdent and n.name == marker: return repl
  for i in 0 ..< n.sons.len:
    n.sons[i] = replaceMarked(n.sons[i], marker, repl)
  if n.body != nil:
    n.body = replaceMarked(n.body, marker, repl)
  n

proc replaceIdentical*(n: NsNode; target: NsNode; repl: NsNode): NsNode =
  ## Every child that *is* `target` becomes `repl`, returned for the same reason.
  ## `desugar.nim` uses this to read a guarded value once, binding it to a temporary
  ## wherever it appears.
  if n == nil: return nil
  if n == target: return repl
  for i in 0 ..< n.sons.len:
    n.sons[i] = replaceIdentical(n.sons[i], target, repl)
  if n.body != nil:
    n.body = replaceIdentical(n.body, target, repl)
  n

proc substitute*(t: NsNode; params: seq[string]; args: seq[NsNode]): NsNode =
  ## `t` with each type parameter replaced by its argument: a member of
  ## `Stack2<string>` declared `T` is a `string`.
  if t == nil or params.len == 0 or params.len != args.len: return t
  case t.kind
  of nsnTypeName:
    if t.sons.len == 0:
      let k = params.find(t.name)
      if k >= 0: return args[k]
      return t
    result = nsnTypeName(t.name, t.info)
    for a in t.sons: result.add substitute(a, params, args)
  of nsnArrayType: result = nsnArrayType(substitute(t.typ, params, args), t.info)
  of nsnNullableType: result = nsnNullableType(substitute(t.typ, params, args), t.info)
  else: result = t
