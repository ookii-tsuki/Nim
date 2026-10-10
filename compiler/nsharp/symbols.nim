# N# frontend - declaration collection
#
# Collects declarations from the parsed tree, so the class grammar exists exactly
# once. Deliberately small: only what the checks and the lowering need.

import std/[tables, sets, strutils]
import ../options
import ast, bcl

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
    isExtension*: bool        ## a static method whose first parameter is `this T`
    obsolete*: NsNode         ## its `[Obsolete]` attribute, if it has one
    isEvent*: bool            ## an `event`: its handlers are a list
    noSetter*: bool           ## a property with only a getter
    autoGetOnly*: bool        ## ... `{ get; }`, which its constructors may assign
    initOnly*: bool           ## a property whose setter is `init`
    isRequired*: bool         ## `required`: `new T { ... }` must set it
    hasBody*: bool            ## a method with a body: in an interface, a default
    owner*: string            ## the class that declares it
    typeParams*: seq[string]  ## a generic method's own `<T>`
    typ*: NsNode              ## declared type of a field, or a method's return type
    params*: seq[NsNode]      ## a method's declared parameter list

  NsClassSymbol* = object
    name*: string
    base*: string
    classKind*: NsClassKind
    isAbstract*: bool
    isSealed*: bool
    isStatic*: bool                ## a `static class`: no instances, no instance members
    enclosing*: string             ## the type a nested type is declared in
    obsolete*: NsNode              ## its `[Obsolete]` attribute, if it has one
    interfaces*: seq[string]       ## the interfaces it names directly
    typeParams*: seq[string]       ## a generic class's `<T, U>`
    written*: seq[string]          ## its base list as written, before resolution
    writtenTypes*: seq[NsNode]     ## ... and as types, generic arguments included
    ifaceTypes*: seq[NsNode]       ## the interfaces it names directly, as types
    libInterfaces*: seq[NsNode]    ## library interfaces it names (`IComparable<T>`)
    decl*: NsNode                  ## its declaration
    members*: seq[NsMemberSymbol]
    operators*: seq[NsNode]        ## its `operator` declarations, conversions included
    ctorArities*: seq[int]
    ctorParams*: seq[seq[NsNode]]  ## one parameter list per declared constructor

  NsModuleScope* = ref object
    classes*: Table[string, NsClassSymbol]
    delegates*: Table[string, NsNode]
    enums*: HashSet[string]
      ## The enums in scope. `Color.Green` is a qualifier over one of these, and
      ## the qualifier is what tells it from a member access on a value.
    usings*: seq[string]
    libIfaces*: HashSet[string]
      ## The interfaces the library declares (`{.nsInterface.}`): a class may name
      ## one, which N# lowers as a duck-typed contract rather than a table.
    staticUsings*: seq[string]
      ## The types a `using static` names: their statics are reachable bare.
    extensions*: Table[string, seq[NsMemberSymbol]]
      ## The extension methods in scope, by name: `x.M()` reaches one when `x`'s own
      ## type has no member `M`.
    namespaces*: HashSet[string]
      ## Every name that stands for a namespace in scope: `using A.B.C;` makes `A`,
      ## `A.B` and `A.B.C` all name it, and `using P = A.B.C;` adds `P`.

const NsIndexerName* = "this[]"
  ## The member name an indexer is recorded under; no C# identifier can collide.

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
    isExtension: m.kind == nsnMethodDecl and m.attrs.isStatic and m.params.len > 0 and
                 m.params[0].paramMod == "this",
    owner: c.name,
    obsolete: m.attributeNamed("Obsolete"),
    isEvent: m.attrs.isEvent,
    isRequired: m.attrs.isRequired,
    hasBody: m.kind == nsnMethodDecl and m.body != nil,
    noSetter: m.kind == nsnPropertyDecl and (m.params.len < 2 or m.params[1] == nil),
    autoGetOnly: m.kind == nsnPropertyDecl and m.params.len > 0 and m.params[0] != nil and
                 m.params[0].kind == nsnEmpty and (m.params.len < 2 or m.params[1] == nil),
    initOnly: m.kind == nsnPropertyDecl and m.params.len > 1 and m.params[1] != nil and
              m.params[1].name == "init",
    typeParams: (block:
      var tps: seq[string] = @[]
      for t in m.typeParams: tps.add t.name
      tps),
    typ: m.typ,              ## field/property type, or a method's return type
    params: (if m.kind == nsnMethodDecl: m.params else: @[]))

proc collectClass(scope: NsModuleScope; cls: NsNode) =
  var sym = NsClassSymbol(name: cls.name, classKind: cls.classKind,
                          isAbstract: cls.attrs.isAbstract, isSealed: cls.attrs.isSealed,
                          isStatic: cls.attrs.isStatic, decl: cls,
                          obsolete: cls.attributeNamed("Obsolete"),
                          enclosing: (if cls.outer.len > 0: cls.outer.split('+')[^1]
                                      else: ""))
  for t in cls.typeParams: sym.typeParams.add t.name
  for b in cls.bases:
    if b.kind == nsnTypeName:
      sym.written.add b.name
      sym.writtenTypes.add b
  if cls.typ != nil and cls.typ.kind == nsnTypeName:
    sym.base = cls.typ.name
  for m in cls.sons:
    case m.kind
    of nsnFieldDecl, nsnMethodDecl, nsnPropertyDecl:
      sym.addMember(m)
    of nsnIndexerDecl:
      ## An indexer is the member `this[]`: its element type and index parameters.
      sym.members.add NsMemberSymbol(name: NsIndexerName, access: m.attrs.access,
                                     isProperty: true, typ: m.typ, params: m.params,
                                     owner: cls.name)
    of nsnOperatorDecl:
      sym.operators.add m
    of nsnCtorDecl:
      if m.attrs.isStatic: continue   ## a static constructor is never called
      sym.ctorArities.add m.params.len
      sym.ctorParams.add m.params
    else: discard
  for m in sym.members:
    if m.isExtension: scope.extensions.mgetOrPut(m.name, @[]).add m
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
    if decl.name.len > 0:
      scope.usings.add decl.name
      scope.noteNamespace(decl.name)
    if decl.alias.len > 0 and decl.strVal != "type": scope.namespaces.incl decl.alias
    if decl.strVal == "static" and decl.typ != nil:
      scope.staticUsings.add canonicalTypeName(decl.typ.name)
  of nsnNamespace:
    if decl.body != nil:
      for d in decl.body.sons: collect(d, scope)
  else: discard

proc isInterface*(scope: NsModuleScope; name: string): bool =
  scope.classes.hasKey(name) and scope.classes[name].classKind == ckInterface

proc resolveBases*(scope: NsModuleScope) =
  ## Splits each base list into the base class and the interfaces, which needs every
  ## type to be known: `class C : IShape` has no base class at all. The declaration
  ## is updated too, so lowering inherits from a class only.
  var names: seq[string] = @[]
  for k in scope.classes.keys: names.add k
  for k in names:
    var c = scope.classes[k]
    if c.written.len == 0: continue
    c.interfaces = @[]
    c.ifaceTypes = @[]
    c.libInterfaces = @[]
    var start = 0
    let first = canonicalTypeName(c.written[0])
    if c.classKind == ckInterface:
      c.base = ""
    elif scope.isInterface(first) or first in scope.libIfaces:
      c.base = ""
    else:
      c.base = c.written[0]
      start = 1
    for i in start ..< c.written.len:
      let nm = canonicalTypeName(c.written[i])
      if nm in scope.libIfaces and not scope.classes.hasKey(nm):
        c.libInterfaces.add c.writtenTypes[i]
      else:
        c.interfaces.add c.written[i]
        c.ifaceTypes.add c.writtenTypes[i]
    if c.decl != nil and c.base.len == 0: c.decl.typ = nil
    scope.classes[k] = c

proc iteratorElement*(t: NsNode): NsNode =
  ## The `T` of an iterator's `IEnumerable<T>` / `IEnumerator<T>` return type, nil
  ## for any other type. C# gives `yield` meaning only in a member returning one.
  if t != nil and t.kind == nsnTypeName and t.sons.len == 1 and
     canonicalTypeName(t.name) in ["IEnumerable", "IEnumerator"]:
    return t.sons[0]
  nil

proc mergePartials(module: NsNode) =
  ## C# merges the `partial` declarations of a type -- in one file or several,
  ## in any namespace block of the same name -- into one type: the members and the
  ## base list of all of them. The first declaration keeps them, the rest leave the
  ## tree, so every later stage sees one class.
  var first = initTable[string, NsNode]()
  proc visit(list: var seq[NsNode]; ns: string) =
    var kept: seq[NsNode] = @[]
    for d in list:
      if d.kind == nsnNamespace and d.body != nil:
        visit(d.body.sons, d.name)
        kept.add d
      elif d.kind == nsnClassDecl and d.attrs.isPartial:
        let key = ns & "." & d.name
        if first.hasKey(key):
          let f = first[key]
          for m in d.sons: f.add m
          for b in d.bases:
            var dup = false
            for x in f.bases:
              if x.kind == nsnTypeName and b.kind == nsnTypeName and x.name == b.name:
                dup = true
            if not dup: f.bases.add b
          if f.typ == nil and d.typ != nil: f.typ = d.typ
          f.attrs.isAbstract = f.attrs.isAbstract or d.attrs.isAbstract
          f.attrs.isSealed = f.attrs.isSealed or d.attrs.isSealed
          f.attrs.isStatic = f.attrs.isStatic or d.attrs.isStatic
          if d.attrs.access != aInternal: f.attrs.access = d.attrs.access
        else:
          first[key] = d
          kept.add d
      else: kept.add d
    list = kept
  visit(module.sons, "")

proc synthesizeRecord(cls: NsNode) =
  ## What C# generates for `record R(T1 A, T2 B)`: a public property per
  ## positional parameter the body does not declare itself (`{ get; init; }`, or
  ## `{ get; set; }` in a record struct), a constructor assigning them -- passing
  ## the base list's arguments to the base record -- and `Deconstruct(out A, out
  ## B)`. Equality, printing and `with` are lowered from the `isRecord` flag. Runs
  ## once: the parameters are consumed.
  if cls.params.len == 0: return
  let info = cls.info
  var declared: seq[string] = @[]
  for m in cls.sons: declared.add m.name
  var props: seq[NsNode] = @[]
  for p in cls.params:
    if p.name in declared: continue
    let prop = nsn(nsnPropertyDecl, p.info)
    prop.name = p.name
    prop.typ = p.typ
    prop.attrs = NsAttrs(access: aPublic)
    let setter = nsn(nsnEmpty, p.info)
    if cls.classKind != ckStruct: setter.name = "init"
    prop.params = @[nsn(nsnEmpty, p.info), setter]
    props.add prop
  ## The positional properties come first, as C# declares them.
  cls.sons = props & cls.sons
  let ctor = nsn(nsnCtorDecl, info)
  ctor.name = cls.name
  ctor.attrs = NsAttrs(access: aPublic, isPrimary: true)
  ctor.body = nsn(nsnBlock, info)
  for p in cls.params:
    ctor.params.add nsnParam(p.name, p.typ, p.info)
    let a = nsn(nsnAssign, p.info)
    a.sons = @[nsnMember(nsn(nsnThis, p.info), p.name, p.info), nsnIdent(p.name, p.info)]
    ctor.body.add a
  if cls.initArgs.len > 0:
    ## Moved, not shared: the tree has one copy of each expression.
    ctor.initKind = "base"
    ctor.initArgs = cls.initArgs
    cls.initArgs = @[]
  cls.add ctor
  let dec = nsn(nsnMethodDecl, info)
  dec.name = "Deconstruct"
  dec.typ = nsn(nsnVoidType, info)
  dec.attrs = NsAttrs(access: aPublic)
  dec.body = nsn(nsnBlock, info)
  for p in cls.params:
    let op = nsnParam(p.name, p.typ, p.info)
    op.paramMod = "out"
    dec.params.add op
    let a = nsn(nsnAssign, p.info)
    a.sons = @[nsnIdent(p.name, p.info), nsnMember(nsn(nsnThis, p.info), p.name, p.info)]
    dec.body.add a
  cls.add dec
  cls.primary = cls.params
  cls.params = @[]

proc synthesizePrimary(cls: NsNode) =
  ## A class's or struct's primary constructor (C# 12): its parameters are in scope
  ## in the whole body. Each one a member does not declare itself is captured in a
  ## private field of its name, initialised from it -- an initialiser runs inside
  ## the constructor, where the parameters are -- and the constructor passes the
  ## base list's arguments on. Any other constructor must chain to it (CS8862).
  if cls.params.len == 0: return
  let info = cls.info
  var declared: seq[string] = @[]
  for m in cls.sons: declared.add m.name
  var fields: seq[NsNode] = @[]
  for p in cls.params:
    if p.name in declared: continue
    let f = nsn(nsnFieldDecl, p.info)
    f.name = p.name
    f.typ = p.typ
    f.attrs = NsAttrs(access: aPrivate)
    f.body = nsnIdent(p.name, p.info)
    fields.add f
  cls.sons = fields & cls.sons
  let ctor = nsn(nsnCtorDecl, info)
  ctor.name = cls.name
  ctor.attrs = NsAttrs(access: aPublic, isPrimary: true)
  ctor.body = nsn(nsnBlock, info)
  for p in cls.params: ctor.params.add nsnParam(p.name, p.typ, p.info)
  if cls.initArgs.len > 0:
    ## Moved, not shared: the tree has one copy of each expression.
    ctor.initKind = "base"
    ctor.initArgs = cls.initArgs
    cls.initArgs = @[]
  cls.add ctor
  cls.primary = cls.params
  cls.params = @[]

proc synthesizeRecords(list: seq[NsNode]) =
  for d in list:
    if d.kind == nsnNamespace and d.body != nil: synthesizeRecords(d.body.sons)
    elif d.kind == nsnClassDecl and d.attrs.isRecord: synthesizeRecord(d)
    elif d.kind == nsnClassDecl: synthesizePrimary(d)

proc collectSymbols*(module: NsNode; config: ConfigRef): NsModuleScope =
  ## Builds the module scope from a parsed module.
  mergePartials(module)
  synthesizeRecords(module.sons)
  result = NsModuleScope(classes: initTable[string, NsClassSymbol](),
                         delegates: initTable[string, NsNode](),
                         extensions: initTable[string, seq[NsMemberSymbol]](),
                         enums: initHashSet[string](),
                         namespaces: initHashSet[string](),
                         libIfaces: bclSurface(config).libraryInterfaces())
  for d in module.sons: collect(d, result)
  result.resolveBases()

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

proc interfaceClosure*(scope: NsModuleScope; clsName: string): seq[string] =
  ## Every interface `clsName` implements: the ones it and its bases name, and the
  ## ones those extend, nearest first, each once.
  result = @[]
  var work: seq[string] = @[]
  for c in scope.chain(clsName):
    for i in scope.classes[c].interfaces: work.add i
  var k = 0
  while k < work.len:
    let i = work[k]
    inc k
    if i in result: continue
    result.add i
    if scope.classes.hasKey(i):
      for j in scope.classes[i].interfaces: work.add j

proc directInterfaces*(scope: NsModuleScope; clsName: string): seq[string] =
  ## The interfaces `clsName` itself names, with the ones they extend; a base class's
  ## interfaces are reached through the base's own conversions.
  result = @[]
  if not scope.classes.hasKey(clsName): return
  var work = scope.classes[clsName].interfaces
  var k = 0
  while k < work.len:
    let i = work[k]
    inc k
    if i in result: continue
    result.add i
    if scope.classes.hasKey(i):
      for j in scope.classes[i].interfaces: work.add j

proc conversionOp*(scope: NsModuleScope; src, dst: string;
                   implicitOnly: bool; checked = false): NsNode =
  ## A user-defined conversion from `src` to `dst`, declared in either type: the
  ## `operator` declaration, or nil. `implicitOnly` leaves explicit ones out.
  for owner in [src, dst]:
    if not scope.classes.hasKey(owner): continue
    for op in scope.classes[owner].operators:
      if op.name notin ["implicit", "explicit"]: continue
      if implicitOnly and op.name != "implicit": continue
      if op.attrs.isChecked != checked: continue
      if op.params.len != 1 or op.params[0].typ == nil or op.typ == nil: continue
      if canonicalTypeName(op.params[0].typ.name) == src and
         canonicalTypeName(op.typ.name) == dst:
        return op
  nil

proc userOperator*(scope: NsModuleScope; cls, op: string; arity: int;
                   checked = false): NsNode =
  ## The `operator op` with `arity` operands that class `cls` declares, or nil;
  ## `checked` asks for its `operator checked op` instead.
  if not scope.classes.hasKey(cls): return nil
  for o in scope.classes[cls].operators:
    if o.name == op and o.params.len == arity and o.attrs.isChecked == checked:
      return o
  nil

proc mangleType*(t: NsNode): string =
  ## A type as part of an identifier: `IRepo<int>` is `IRepo_int`.
  if t == nil: return ""
  case t.kind
  of nsnTypeName:
    result = unqualified(t.name)
    for a in t.sons: result.add "_" & mangleType(a)
  of nsnArrayType: result = mangleType(t.typ) & "Arr"
  of nsnNullableType: result = mangleType(t.typ) & "Opt"
  else: result = "x"

proc directInterfaceTypes*(scope: NsModuleScope; clsName: string): seq[NsNode] =
  ## The interfaces `clsName` itself names, with the ones they extend, as types:
  ## `class R : INamedRepo<int>` implements `INamedRepo<int>` and `IRepo<int>`.
  result = @[]
  if not scope.classes.hasKey(clsName): return
  var work = scope.classes[clsName].ifaceTypes
  var seen: seq[string] = @[]
  var k = 0
  while k < work.len:
    let t = work[k]
    inc k
    let key = mangleType(t)
    if key in seen: continue
    seen.add key
    result.add t
    let nm = canonicalTypeName(t.name)
    if scope.classes.hasKey(nm):
      let ic = scope.classes[nm]
      for b in ic.ifaceTypes: work.add substitute(b, ic.typeParams, t.sons)

proc lookupChain*(scope: NsModuleScope; clsName: string): seq[string] =
  ## Where a member of `clsName` may be declared: its class chain, then the
  ## interfaces it implements (all an interface type has).
  result = scope.chain(clsName)
  for i in scope.interfaceClosure(clsName):
    if scope.classes.hasKey(i) and i notin result: result.add i

proc implements*(scope: NsModuleScope; a, b: string): bool =
  ## Whether a value of `a` converts implicitly to `b`: a base class or an interface.
  b in scope.chain(a) or b in scope.interfaceClosure(a)

proc findMember*(scope: NsModuleScope; clsName, member: string):
    tuple[found: bool, access: NsAccess, decl: string] =
  ## Looks a member up along the class chain. `decl` is the declaring class.
  if clsName.len > 0:
    for c in scope.lookupChain(clsName):
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
    for c in scope.lookupChain(clsName):
      for m in scope.classes[c].members:
        if m.name == member: return m

proc enclosingStatic*(scope: NsModuleScope; clsName, member: string): NsMemberSymbol =
  ## A static member of a type enclosing `clsName`, which a nested type names bare.
  result = NsMemberSymbol()
  var c = (if scope.classes.hasKey(clsName): scope.classes[clsName].enclosing else: "")
  var hops = 0
  while c.len > 0 and scope.classes.hasKey(c) and hops < 32:
    let m = scope.findMemberInfo(c, member)
    if m.name.len > 0 and (m.isStatic or m.isConst): return m
    c = scope.classes[c].enclosing
    inc hops

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
  for c in scope.lookupChain(clsName):
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
