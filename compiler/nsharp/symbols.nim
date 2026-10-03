#
#           N# frontend - declaration collection
#
# Stage 1 of PARSER-CLEANUP.md. This replaces `prescanClasses`, which used to
# re-implement a member scanner over the *token stream* (skipParens, skipBraces,
# countParenArgs) before the real parse. Declarations are now collected from the
# parsed tree, so the class grammar exists exactly once.
#
# Scope of the collected information is deliberately small: only what the checks
# and the lowering actually need.

import std/[tables, sets]
import ../options
import ast

type
  NsMemberSymbol* = object
    name*: string
    access*: NsAccess
    isMethod*: bool
    isProperty*: bool
    isStatic*: bool
    typ*: NsNode              ## declared type of a field or property

  NsClassSymbol* = object
    name*: string
    base*: string
    classKind*: NsClassKind
    members*: seq[NsMemberSymbol]
    ctorArities*: seq[int]

  NsModuleScope* = ref object
    classes*: Table[string, NsClassSymbol]
    delegates*: Table[string, NsNode]
    usings*: seq[string]

proc addMember(c: var NsClassSymbol; m: NsNode) =
  ## Records a field, method or property. A redeclaration is ignored.
  for existing in c.members:
    if existing.name == m.name: return
  c.members.add NsMemberSymbol(
    name: m.name,
    access: m.attrs.access,
    isMethod: m.kind == nsnMethodDecl,
    isProperty: m.kind == nsnPropertyDecl,
    isStatic: m.attrs.isStatic,
    typ: m.typ)              ## field/property type, or a method's return type

proc collectClass(scope: NsModuleScope; cls: NsNode) =
  var sym = NsClassSymbol(name: cls.name, classKind: cls.classKind)
  if cls.typ != nil and cls.typ.kind == nsnTypeName:
    sym.base = cls.typ.name
  for m in cls.sons:
    case m.kind
    of nsnFieldDecl, nsnMethodDecl, nsnPropertyDecl:
      sym.addMember(m)
    of nsnCtorDecl:
      sym.ctorArities.add m.params.len
    else: discard
  scope.classes[cls.name] = sym

proc collect(decl: NsNode; scope: NsModuleScope) =
  case decl.kind
  of nsnClassDecl:
    scope.collectClass(decl)
  of nsnDelegateDecl:
    scope.delegates[decl.name] = decl
  of nsnUsing:
    scope.usings.add decl.name
  of nsnNamespace:
    if decl.body != nil:
      for d in decl.body.sons: collect(d, scope)
  else: discard

proc collectSymbols*(module: NsNode; config: ConfigRef): NsModuleScope =
  ## Builds the module scope from a parsed module.
  result = NsModuleScope(classes: initTable[string, NsClassSymbol](),
                         delegates: initTable[string, NsNode]())
  for d in module.sons: collect(d, result)

proc chain*(scope: NsModuleScope; clsName: string): seq[string] =
  ## `clsName` followed by its bases, nearest first. A visited set makes this
  ## cycle safe rather than relying on an arbitrary depth cap.
  result = @[]
  var seen = initHashSet[string]()
  var c = clsName
  while c.len > 0 and scope.classes.hasKey(c) and c notin seen:
    seen.incl c
    result.add c
    c = scope.classes[c].base

proc findMember*(scope: NsModuleScope; clsName, member: string):
    tuple[found: bool, access: NsAccess, decl: string] =
  ## Looks a member up along the class chain. `decl` is the declaring class.
  if clsName.len > 0:
    for c in scope.chain(clsName):
      for m in scope.classes[c].members:
        if m.name == member: return (true, m.access, c)
  (false, aPrivate, "")

proc accessibleFrom*(scope: NsModuleScope; curClass, member: string): bool =
  ## True when `member` may be named from within `curClass`. Unknown names are
  ## not this pass's business, so they are allowed.
  let (found, ac, decl) = scope.findMember(curClass, member)
  if not found: return true
  case ac
  of aPrivate: decl == curClass
  of aProtected, aInternal, aPublic: true

proc findMemberInfo*(scope: NsModuleScope; clsName, member: string): NsMemberSymbol =
  ## The member symbol along the class chain, or a zeroed symbol when absent
  ## (`name == ""`).
  result = NsMemberSymbol()
  if clsName.len > 0:
    for c in scope.chain(clsName):
      for m in scope.classes[c].members:
        if m.name == member: return m

proc memberNames*(scope: NsModuleScope; clsName: string): seq[string] =
  ## Every member name along the chain, for bare-name resolution.
  result = @[]
  if clsName.len > 0:
    for c in scope.chain(clsName):
      for m in scope.classes[c].members:
        if m.name notin result: result.add m.name
