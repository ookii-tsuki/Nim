// N#: a Nim-managed value (a reference, a string, a seq) held by a C++ object.
//
// A class deriving a native C++ class is a C++ struct the engine copies, moves
// and destroys with C++ semantics, which know nothing of Nim's reference counts.
// Each field whose type Nim manages is therefore an `NsField<T>`: its copy, move
// and destruction run Nim's hooks for `T`, so the struct holding it needs no
// special members of its own (the rule of zero), and its moves stay `noexcept`.
//
// The hooks are function pointers each N# module registers for the field types
// it uses, when the program starts (`NimMain`, which a host calls first).
#pragma once

template <typename T>
struct NsHooks {
    static inline void (*destroy)(T*) = nullptr;
    static inline void (*copy)(T*, T*) = nullptr;   // the source is only read
    static void Set(void (*d)(T*), void (*c)(T*, T*)) { destroy = d; copy = c; }
};

template <typename T>
struct NsField {
    T v{};   // the only member: Nim's `nsVal` reads it at the field's own address
    NsField() = default;
    NsField(const NsField& o) : v{} { if (NsHooks<T>::copy) NsHooks<T>::copy(&v, const_cast<T*>(&o.v)); }
    NsField(NsField&& o) noexcept : v(o.v) { o.v = T{}; }
    NsField& operator=(const NsField& o) {
        if (this != &o && NsHooks<T>::copy) NsHooks<T>::copy(&v, const_cast<T*>(&o.v));
        return *this;
    }
    NsField& operator=(NsField&& o) noexcept {
        if (this != &o) {
            if (NsHooks<T>::destroy) NsHooks<T>::destroy(&v);
            v = o.v;
            o.v = T{};
        }
        return *this;
    }
    ~NsField() { if (NsHooks<T>::destroy) NsHooks<T>::destroy(&v); }
};
