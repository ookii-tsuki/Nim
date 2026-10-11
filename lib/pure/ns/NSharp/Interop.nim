# N# standard library: the NSharp.Interop namespace. Imported by
# `using NSharp.Interop;`.
#
# The attributes a binding to native C++ code is written with. As with
# `[Flags]` and `[Obsolete]`, the compiler reads them; nothing reads them at run
# time. A binding is a C# declaration whose members are `extern`:
#
#   [Native("Game::Node", Header = "game.hpp", Handle = "Game::NodeRef<{0}>",
#           SelfHandle = "me")]
#   public class Node { public extern T Attach<T>() where T : Trait; }

from ../System import Attribute

type
  NativeAttribute* = ref object of Attribute
    ## `[Native("Ns::Type", Header = "h.hpp")]` on a type: the C++ type it is.
    ## `Handle = "Ns::Id<{0}>"` makes a class a handle class: a variable of it, or
    ## of a class derived from it, holds that handle (with `{0}` the C++ class) and
    ## `null` is an invalid handle. `SelfHandle` is how a `this` pointer reaches its
    ## own handle: a C++ pattern over the object (`"#->GetId()"`), or a member name
    ## (`"id"`, short for `"#->id"`); it must be public or protected, since the code
    ## that uses it is the derived class's. A handle is valid when its
    ## `explicit operator bool` says so, unless `Valid` gives the test as a pattern
    ## over it (`"#.IsAlive()"`, `"Ns::World::Exists(#)"`); using an invalid one
    ## throws `NullReferenceException`. `null` is a default-constructed handle,
    ## unless `Null` names the invalid one (`"Ns::Id<{0}>::Invalid()"`). The object
    ## is the handle's `operator->`, unless `Deref` gives the pointer as a pattern
    ## over it (`"#.Get()"`, `"Ns::World::Find(#)"`). On an `extern` property,
    ## `Get = "GetPosition", Set = "SetPosition"` names the C++ accessors: a member
    ## function's name (`#->GetPosition()`, `#->SetPosition(value)`), or a pattern
    ## (`Get = "#->Children().size()"`). Nothing is guessed: an accessor with
    ## neither is an error, except that a static property with neither is the C++
    ## type's static member. On an `extern` method, `Qualifiers = "const noexcept"`
    ## gives its C++ qualifiers, which an N# override repeats so that it overrides,
    ## and which make a `const` one callable from a const member function.
    ## `Stable = true` on a class says its members (constructors and destructor
    ## included) create, destroy and move no engine object, so N# may keep the
    ## object a handle reaches across calls to them; a member that does is marked
    ## `[Moves]`. Without it, every call to the class's members may. On an `extern` member,
    ## `[Native("pattern")]` gives the C++ call as a Nim `importcpp` pattern.
  ExportAttribute* = ref object of Attribute
    ## `[Export("name")]` on a static method: C++ calls it by that name.
  ForwardAttribute* = ref object of Attribute
    ## `[Forward] params object[] args`, the last parameter of a generic `extern`
    ## factory (`T Spawn<T>([Forward] params object[] args) where T : Node`): the
    ## arguments reach the C++ call as they are, and are checked against the
    ## constructors of the type argument (the return type's, or the first one).
  BorrowedAttribute* = ref object of Attribute
    ## `[return: Borrowed]` on an `extern` returning a class with no handle: C++
    ## lends a pointer or reference to an object it keeps owning. Nothing keeps it
    ## alive; a copy N# owns is made by an `extern` returning one by value.
  OwnedAttribute* = ref object of Attribute
    ## `[return: Owned]` on an `extern` returning a class with no handle: C++ hands
    ## over a pointer it made with `new`, which N# deletes with the last reference.
    ## Without either, the class is returned by value and N# owns the result.
  OnHandleAttribute* = ref object of Attribute
    ## `[OnHandle]` on an `extern` instance member of a handle class: a member of the
    ## handle, not of the object -- called on the handle itself (`#.M(@)`), and not
    ## checked, so it works on an invalid one (`e.IsAlive()`, `e.Id`).
  CStringAttribute* = ref object of Attribute
    ## `[return: CString("#.c_str()")]` on an `extern` returning `string`: how to
    ## reach the characters of what C++ returns, `#` being the returned value
    ## (`"#.Data()"`, `"#.ptr"`); `Length = "#.size()"` gives the length too, so a
    ## string may hold a `'\0'`. Without it the C++ result is a `const char*`. The
    ## characters are copied into the N# string at once, so a temporary they live
    ## in is still alive; null is the empty string. On a `string` parameter,
    ## `[CString("Text::Str(#, #len)")]` builds the C++ argument from the N#
    ## string's characters (`#`) and length (`#len`), for a string type no
    ## `const char*` converts to implicitly; without it C++ gets a `const char*`.
    ## Either way the characters are valid only during the call.
  MovesAttribute* = ref object of Attribute
    ## `[Moves]` on an `extern` member of a `Stable` class: it may create, destroy
    ## or move engine objects, so a handle N# holds resolves afresh after it.
