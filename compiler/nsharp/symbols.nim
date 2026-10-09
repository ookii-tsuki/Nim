# N# frontend - declaration collection
#
# Collects declarations from the parsed tree, so the class grammar exists exactly
# once. Deliberately small: only what the checks and the lowering need.

import std/[tables, sets, strutils]
import ../options
import ast

type
  NsMemberSymbol* = object
    name*: string
    access*: NsAccess
    isMethod*: bool
    isProperty*: bool
    isStatic*: bool
    isConst*: bool
    isReadonly*: bool
    isVirtual*: bool          ## `virtual` or `abstract`: opens a slot
    isOverride*: bool
    isAbstract*: bool
    isSealed*: bool
    owner*: string            ## the class that declares it
    typ*: NsNode              ## declared type of a field, or a method's return type
    params*: seq[NsNode]      ## a method's declared parameter list

  NsClassSymbol* = object
    name*: string
    base*: string
    classKind*: NsClassKind
    isAbstract*: bool
    isSealed*: bool
    members*: seq[NsMemberSymbol]
    ctorArities*: seq[int]
    ctorParams*: seq[seq[NsNode]]  ## one parameter list per declared constructor

  NsModuleScope* = ref object
    classes*: Table[string, NsClassSymbol]
    delegates*: Table[string, NsNode]
    enums*: HashSet[string]
      ## The enums in scope. `Color.Green` is a qualifier over one of these, and
      ## the qualifier is what tells it from a member access on a value.
    usings*: seq[string]
    namespaces*: HashSet[string]
      ## Every name that stands for a namespace in scope: `using A.B.C;` makes `A`,
      ## `A.B` and `A.B.C` all name it, and `using P = A.B.C;` adds `P`.

proc addMember(c: var NsClassSymbol; m: NsNode) =
  ## Records a field, method or property. Every declaration is kept: C# lets a type
  ## declare overloads, which differ only in their parameter lists, and a call site
  ## has to be matched against all of them. Lookups still answer with the first
  ## declaration, which is the behaviour a single declaration had.
  c.members.add NsMemberSymbol(
    name: m.name,
    access: m.attrs.access,
    isMethod: m.kind == nsnMethodDecl,
    isProperty: m.kind == nsnPropertyDecl,
    isStatic: m.attrs.isStatic,
    isConst: m.attrs.isConst,
    isReadonly: m.attrs.isReadonly,
    isVirtual: m.attrs.isVirtual or m.attrs.isAbstract,
    isOverride: m.attrs.isOverride,
    isAbstract: m.attrs.isAbstract,
    isSealed: m.attrs.isSealed,
    owner: c.name,
    typ: m.typ,              ## field/property type, or a method's return type
    params: (if m.kind == nsnMethodDecl: m.params else: @[]))

proc collectClass(scope: NsModuleScope; cls: NsNode) =
  var sym = NsClassSymbol(name: cls.name, classKind: cls.classKind,
                          isAbstract: cls.attrs.isAbstract, isSealed: cls.attrs.isSealed)
  if cls.typ != nil and cls.typ.kind == nsnTypeName:
    sym.base = cls.typ.name
  for m in cls.sons:
    case m.kind
    of nsnFieldDecl, nsnMethodDecl, nsnPropertyDecl:
      sym.addMember(m)
    of nsnCtorDecl:
      if m.attrs.isStatic: continue   ## a static constructor is never called
      sym.ctorArities.add m.params.len
      sym.ctorParams.add m.params
    else: discard
  scope.classes[cls.name] = sym

proc noteNamespace(scope: NsModuleScope; ns: string) =
  ## Records a namespace and each of its prefixes: `using A.B.C;` means `A`, `A.B`
  ## and `A.B.C` all name the same declarations, so all three are qualifiers.
  var cur = ""
  for part in ns.split('.'):
    if part.len == 0: continue
    cur = if cur.len == 0: part else: cur & "." & part
    scope.namespaces.incl cur

proc collect(decl: NsNode; scope: NsModuleScope) =
  case decl.kind
  of nsnClassDecl:
    scope.collectClass(decl)
  of nsnDelegateDecl:
    scope.delegates[decl.name] = decl
  of nsnEnumDecl:
    scope.enums.incl decl.name
  of nsnUsing:
    scope.usings.add decl.name
    scope.noteNamespace(decl.name)
    if decl.alias.len > 0: scope.namespaces.incl decl.alias
  of nsnNamespace:
    if decl.body != nil:
      for d in decl.body.sons: collect(d, scope)
  else: discard

proc collectSymbols*(module: NsNode; config: ConfigRef): NsModuleScope =
  ## Builds the module scope from a parsed module.
  result = NsModuleScope(classes: initTable[string, NsClassSymbol](),
                         delegates: initTable[string, NsNode](),
                         enums: initHashSet[string](),
                         namespaces: initHashSet[string]())
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

proc baseChain*(scope: NsModuleScope; clsName: string): seq[string] =
  ## `clsName` followed by its bases, nearest first. Unlike `chain`, a base this
  ## module does not declare is kept: the library may declare it (`Exception`, a
  ## Nim defect), and that is what decides whether a class is an exception type.
  result = @[]
  var seen = initHashSet[string]()
  var c = clsName
  while c.len > 0 and c notin seen:
    seen.incl c
    result.add c
    c = if scope.classes.hasKey(c): scope.classes[c].base else: ""

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

proc memberOverloads*(scope: NsModuleScope; clsName, member: string): seq[seq[NsNode]] =
  ## Every declared parameter list for `member` along the class chain, nearest class
  ## first. `findMemberInfo` answers what the name *means*; this answers what each
  ## overload *takes*, which is what a call site has to be matched against. An empty
  ## result means the name is not a method of that class, so the call is not ours to
  ## judge (a library method, or a name the frontend cannot resolve).
  result = @[]
  if clsName.len == 0: return
  for c in scope.chain(clsName):
    for m in scope.classes[c].members:
      if m.name == member and m.isMethod: result.add m.params

proc ctorOverloads*(scope: NsModuleScope; clsName: string): seq[seq[NsNode]] =
  ## The declared constructors of `clsName`. A class that declares none has the
  ## implicit parameterless one, so `new C(1)` is CS1729 rather than unknown.
  result = @[]
  if not scope.classes.hasKey(clsName): return
  result = scope.classes[clsName].ctorParams
  if result.len == 0: result = @[@[]]

proc isDispatched*(scope: NsModuleScope; clsName, member: string): bool =
  ## True when `member` of `clsName` sits in a dispatch slot: declared `virtual`,
  ## `abstract` or `override` somewhere along the chain.
  for c in scope.chain(clsName):
    for m in scope.classes[c].members:
      if m.name == member and (m.isVirtual or m.isOverride): return true
  false

proc baseSlot*(scope: NsModuleScope; clsName, member: string): NsMemberSymbol =
  ## The nearest base member an `override` of `member` in `clsName` fills: one that
  ## is `virtual`, `abstract` or itself an `override`. Zeroed when there is none.
  result = NsMemberSymbol()
  let ch = scope.chain(clsName)
  for i in 1 ..< ch.len:
    for m in scope.classes[ch[i]].members:
      if m.name == member and (m.isVirtual or m.isOverride): return m
