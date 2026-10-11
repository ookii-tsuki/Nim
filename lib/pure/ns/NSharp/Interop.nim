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
    ## unless `Null` names the invalid one (`"Ns::Id<{0}>::Invalid()"`). On an `extern` member,
    ## `[Native("pattern")]` gives the C++ call as a Nim `importcpp` pattern.
  ExportAttribute* = ref object of Attribute
    ## `[Export("name")]` on a static method: C++ calls it by that name.
  ForwardAttribute* = ref object of Attribute
    ## `[Forward] params object[] args`, the last parameter of a generic `extern`
    ## factory (`T Spawn<T>([Forward] params object[] args) where T : Node`): the
    ## arguments reach the C++ call as they are, and are checked against the
    ## constructors of the type argument (the return type's, or the first one).
