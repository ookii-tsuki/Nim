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
    ## that uses it is the derived class's. On an `extern` member,
    ## `[Native("pattern")]` gives the C++ call as a Nim `importcpp` pattern.
  ExportAttribute* = ref object of Attribute
    ## `[Export("name")]` on a static method: C++ calls it by that name.
