// N#: native objects N# owns. A class of a [Native] family with no handle is a
// plain C++ class, and `new C(...)` in N# makes one in a Nim-managed box: the
// object is constructed in the box's storage with placement new and destroyed
// with its destructor when the last N# reference goes. See SPEC 14.2.
#pragma once
#include <cstdio>
#include <cstdlib>
#include <new>
#include <type_traits>

// Room for a T, constructed and destroyed by hand. A T member would need a
// default constructor in the Nim-generated struct around it.
template <typename T>
struct NsStorage {
    alignas(T) unsigned char bytes[sizeof(T)];
    T* get() const { return reinterpret_cast<T*>(const_cast<unsigned char*>(bytes)); }
};

template <typename T>
void nsDestroyAt(T* p) { p->~T(); }

// The box an object of an N# class deriving a native one lives in, when N# made
// it, which `this` as a value keeps alive. A copy C++ makes is not in that box,
// so it starts with none.
struct NsOwner {
    void* box = nullptr;
    NsOwner() = default;
    NsOwner(const NsOwner&) {}
    NsOwner& operator=(const NsOwner&) { return *this; }
};

// An N# reference passed to C++: a pointer to the family's root class, which
// becomes whatever the parameter is -- `X*`, or `X&` / `const X&` / `X` for a
// class `X` of the family.
[[noreturn]] inline void nsPassNull() {
    std::fprintf(stderr, "N#: null passed where C++ takes a reference\n");
    std::abort();
}

template <typename R>
struct NsPass {
    R* p;
    template <typename X> operator X*() const { return static_cast<X*>(p); }
    template <typename X, typename = std::enable_if_t<!std::is_pointer_v<X>>>
    operator X&() const {
        if (!p) nsPassNull();
        return *static_cast<X*>(p);
    }
};

// A pointer or a reference C++ returns, as a pointer.
template <typename T> T* nsAddr(T* p) { return p; }
template <typename T> T* nsAddr(T& r) { return &r; }
