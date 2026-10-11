// Toybox: a tiny header-only C++20 engine for testing N#'s C++ interop. It has
// the shapes such engines have -- objects held by value in per-type pools that
// relocate them, generational references with operator-> and explicit operator
// bool, optional hooks detected with concepts, stages with virtual hooks -- and
// nothing else.
#pragma once
#include <concepts>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <utility>
#include <vector>

namespace Toybox {

namespace Console {
inline void Print(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    std::vprintf(fmt, ap);
    va_end(ap);
    std::printf("\n");
}
}

struct Vec2 {
    float x = 0, y = 0;
    Vec2() = default;
    Vec2(float x, float y) : x(x), y(y) {}
    Vec2 operator+(const Vec2& o) const { return {x + o.x, y + o.y}; }
    Vec2 operator*(float s) const { return {x * s, y * s}; }
    static const Vec2 Zero;
};
inline const Vec2 Vec2::Zero{0.0f, 0.0f};

class Node;
class Stage;

// --- node references ------------------------------------------------------------

template <typename T = Node>
    requires std::derived_from<T, Node>
struct NodeRef {
    std::uint32_t slot = 0;
    std::uint32_t version = 0;

    NodeRef() = default;
    NodeRef(std::uint32_t s, std::uint32_t v) : slot(s), version(v) {}
    template <typename U>
    NodeRef(const NodeRef<U>& o) : slot(o.slot), version(o.version) {}

    T* operator->() const;
    explicit operator bool() const;
};

// slot -> (version, address). A pool re-points a slot whenever it moves a node,
// which is why a reference resolves per use and `this` is never kept.
class Registry {
public:
    struct Entry { std::uint32_t version = 1; Node* node = nullptr; };
    std::vector<Entry> entries{Entry{}};   // slot 0 is the empty reference

    NodeRef<> Add() {
        entries.push_back(Entry{});
        return NodeRef<>(static_cast<std::uint32_t>(entries.size() - 1), entries.back().version);
    }
    void Point(NodeRef<> r, Node* n) { entries[r.slot].node = n; }
    void Drop(NodeRef<> r) { entries[r.slot].node = nullptr; entries[r.slot].version++; }
    Node* Find(NodeRef<> r) const {
        if (r.slot == 0 || r.slot >= entries.size()) return nullptr;
        const Entry& e = entries[r.slot];
        return e.version == r.version ? e.node : nullptr;
    }
    static Registry*& Current() { static Registry* current = nullptr; return current; }
};

// --- traits -----------------------------------------------------------------------

struct Trait {
    NodeRef<> owner;
    virtual ~Trait() = default;
};

template <typename T>
struct TraitRef {
    T* ptr = nullptr;
    TraitRef() = default;
    explicit TraitRef(T* p) : ptr(p) {}
    T* operator->() const {
        if (!ptr) { Console::Print("TraitRef: empty"); std::abort(); }
        return ptr;
    }
    explicit operator bool() const { return ptr != nullptr; }
};

struct Motion : Trait {
    Vec2 Pos;
    Vec2 Vel;
    void Push(Vec2 f) { Vel = Vel + f; }
};

struct Tag : Trait {
    int Value = 0;
};

// --- nodes ------------------------------------------------------------------------

template <typename T> concept HasOnBegin = requires(T t) { { t.OnBegin() } -> std::same_as<void>; };
template <typename T> concept HasOnTick = requires(T t, float dt) { { t.OnTick(dt) } -> std::same_as<void>; };

class Node {
    template <typename T> friend struct Pool;
protected:
    NodeRef<> me;          // reachable from derived classes, not from outside
public:
    Stage* stage = nullptr;
    NodeRef<> Self() const { return me; }

    template <typename C> TraitRef<C> Attach();
    template <typename C> TraitRef<C> Find();
};

template <typename T>
    requires std::derived_from<T, Node>
T* NodeRef<T>::operator->() const {
    Registry* reg = Registry::Current();
    Node* n = reg ? reg->Find(NodeRef<>(slot, version)) : nullptr;
    if (!n) { Console::Print("NodeRef: node %u is gone", static_cast<unsigned>(slot)); std::abort(); }
    return static_cast<T*>(n);
}

template <typename T>
    requires std::derived_from<T, Node>
NodeRef<T>::operator bool() const {
    Registry* reg = Registry::Current();
    return reg && reg->Find(NodeRef<>(slot, version)) != nullptr;
}

struct PoolBase {
    virtual ~PoolBase() = default;
    virtual void Tick(float dt) = 0;
    virtual void Remove(NodeRef<> r) = 0;
};

// Nodes live by value in a vector, which moves them as it grows.
template <typename T>
struct Pool : PoolBase {
    std::vector<T> items;

    NodeRef<T> Make(Registry& reg, Stage* stage) {
        NodeRef<> r = reg.Add();
        T node;
        node.me = r;
        node.stage = stage;
        items.push_back(std::move(node));
        for (auto& n : items) reg.Point(n.me, &n);
        if constexpr (HasOnBegin<T>) static_cast<T*>(reg.Find(r))->OnBegin();
        return NodeRef<T>(r);
    }
    void Tick(float dt) override {
        if constexpr (HasOnTick<T>) {
            for (size_t i = 0; i < items.size(); i++) items[i].OnTick(dt);
        }
    }
    void Remove(NodeRef<> r) override {
        Registry& reg = *Registry::Current();
        for (size_t i = 0; i < items.size(); i++) {
            if (items[i].me.slot == r.slot && items[i].me.version == r.version) {
                items.erase(items.begin() + i);
                reg.Drop(r);
                for (auto& n : items) reg.Point(n.me, &n);
                return;
            }
        }
    }
};

// --- stages -----------------------------------------------------------------------

class Stage {
public:
    Registry registry;
    std::vector<std::unique_ptr<PoolBase>> pools;
    std::vector<std::unique_ptr<Trait>> traits;

    virtual ~Stage() = default;
    virtual void Begin() {}
    virtual void Tick(float dt) {}

    template <typename T>
    Pool<T>& PoolOf() {
        static Pool<T>* pool = nullptr;
        if (!pool) {
            auto p = std::make_unique<Pool<T>>();
            pool = p.get();
            pools.push_back(std::move(p));
        }
        return *pool;
    }

    template <typename T = Node>
        requires std::derived_from<T, Node>
    NodeRef<T> Spawn() {
        Registry::Current() = &registry;
        return PoolOf<T>().Make(registry, this);
    }

    void Remove(NodeRef<> r) {
        for (auto& p : pools) p->Remove(r);
    }

    void TickAll(float dt) {
        for (size_t i = 0; i < pools.size(); i++) pools[i]->Tick(dt);
        Tick(dt);
    }
};

template <typename C>
TraitRef<C> Node::Attach() {
    auto c = std::make_unique<C>();
    c->owner = me;
    C* raw = c.get();
    stage->traits.push_back(std::move(c));
    return TraitRef<C>(raw);
}

template <typename C>
TraitRef<C> Node::Find() {
    for (auto& t : stage->traits) {
        if (t->owner.slot == me.slot && t->owner.version == me.version) {
            if (auto* typed = dynamic_cast<C*>(t.get())) return TraitRef<C>(typed);
        }
    }
    return TraitRef<C>();
}

class Director {
public:
    static std::unique_ptr<Stage>& Current() { static std::unique_ptr<Stage> s; return s; }
    template <typename T>
        requires std::derived_from<T, Stage>
    static void Play() {
        Current() = std::make_unique<T>();
        Registry::Current() = &Current()->registry;
        Current()->Begin();
    }
    // A fixed number of frames, so a test ends.
    static void Run(int frames) {
        for (int f = 0; f < frames; f++) {
            if (!Current()) return;
            Current()->TickAll(0.5f);
        }
    }
};

} // namespace Toybox
