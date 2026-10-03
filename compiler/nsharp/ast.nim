#
#           N# frontend - the N# syntax tree
#
# The parser's output and the input to `sema` and `desugar`. Introducing it is
# Stage 1 of PARSER-CLEANUP.md: the frontend previously emitted Nim `PNode`s
# straight from the parser, which left no seam for name resolution (Stage 2) and
# forced every semantic rule to be a name rewrite performed while parsing.
#
# Design notes
# ------------
# * The tree mirrors **C# syntax**, not Nim's. A class is `nsnClassDecl`, not a
#   `nkTypeSection`; `Console.WriteLine` stays a member access on an identifier
#   named `Console`; `Length` stays `Length`; `int` stays `int`. All of the
#   C#-to-Nim mapping happens later, in one place (`bcl.nim` + `desugar.nim`).
# * `NsNodeObj` is a **flat record** rather than Nim's tagged-variant `TNode`.
#   Variants make illegal states unrepresentable, but reading the wrong branch
#   raises `FieldDefect` at runtime (that exact footgun bit the Stage 0a dump
#   tool through `PNode.sons`). These trees are small and short-lived, so
#   safety of traversal is worth more here than the bytes. The constructor procs
#   below are what keep construction honest.
# * Every node carries a `TLineInfo` so diagnostics from `sema` can point at the
#   source, which the old parse-time checks could not do properly.
# * Names are stored as plain `string`. Interning/lookup is `sema`'s job, not the
#   parser's.

import std/strutils

import ../lineinfos

type
  NsAccess* = enum
    aPrivate, aProtected, aInternal, aPublic

  NsAttrs* = object
    ## Visibility and the one storage modifier that currently changes lowering.
    access*: NsAccess
    isStatic*: bool

  NsDeclKind* = enum
    ## Storage class of a local declaration.
    dkVar, dkLet, dkConst

  NsClassKind* = enum
    ckClass, ckStruct, ckInterface

  NsTypeKind* = enum
    ## Coarse type information attached to expressions by `sema.nim`. Lowering
    ## consults it instead of guessing from names, which is what Stage 2 of
    ## PARSER-CLEANUP.md is about. It is deliberately coarse: only the
    ## distinctions the lowering actually needs.
    tkUnknown      ## not resolved; lowering must stay conservative
    tkInt          ## an integer type, so `/` means `div`
    tkFloat        ## a floating point type
    tkBool
    tkChar
    tkString       ## `.Length` is `len`
    tkSequence     ## array or collection: `.Length`/`.Count` are `len`
    tkException    ## `.Message` is `msg`
    tkClass        ## a value of a user class
    tkType         ## a type or namespace name used as a receiver (`Console`)
    tkDelegate

  NsNodeKind* = enum
    nsnEmpty
    # --- types ---
    nsnTypeName        # name, sons = generic arguments (may be empty)
    nsnArrayType       # typ = element type
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
    nsnParam           # name, typ, body = default value (or nil), attrs
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
    # --- expressions ---
    nsnIdent           # name
    nsnIntLit          # intVal
    nsnFloatLit        # floatVal
    nsnStrLit          # strVal
    nsnCharLit         # intVal (codepoint)
    nsnBoolLit         # intVal (0/1)
    nsnThis
    nsnNull
    nsnCall            # body = callee, sons = arguments
    nsnMember          # body = receiver, name
    nsnIndex           # body = receiver, sons = indices
    nsnNew             # typ = constructed type, sons = arguments
    nsnNewArray        # typ = element type, sons = [size]      (from `new T[n]`)
    nsnArrayLit        # sons = elements                        (from `new T[] { .. }`)
    nsnUnary           # name = operator, body = operand
    nsnBinary          # name = operator, sons = [lhs, rhs]
    nsnTernary         # sons = [cond, ifTrue, ifFalse]
    nsnLambda          # params, body
    nsnIncDec          # name = "inc" or "dec", body = operand (from `++`/`--`)

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
    initKind*: string         ## nsnCtorDecl only: "", "base" or "this"
    initArgs*: seq[NsNode]    ## nsnCtorDecl only: initializer arguments
    typeKind*: NsTypeKind     ## set by `sema.nim` on expressions
    typeName*: string         ## the resolved type name behind `typeKind`

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
  of nsnIntLit, nsnCharLit, nsnBoolLit: result.add " " & $n.intVal
  of nsnFloatLit:
    result.add " " & formatFloat(float(n.floatVal), ffDefault, 0)
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

