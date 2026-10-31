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
#include <string>
#include <cstring>
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

namespace Text {
struct Str {                       // an engine's own string: data, length, no '\0' promise
    char buf[32];
    int n;
    Str() : buf{}, n(0) {}
    Str(const char* p, int len) : buf{}, n(len < 32 ? len : 32) { std::memcpy(buf, p, n); }
    static Str From(const char* p) { return Str(p, static_cast<int>(std::strlen(p))); }
    const char* Data() const { return buf; }
    int Size() const { return n; }
};
}

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
    std::uint32_t Slot() const { return slot; }   // the handle's own, not the node's
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
    // Accessors in the styles engines use.
    Vec2 GetPosition() const { return Pos; }
    void SetPosition(Vec2 p) { Pos = p; }
    std::string Describe() const { return "motion at " + std::to_string((int)Pos.x); }
    float get_spin() const { return spin; }
    void set_spin(float s) { spin = s; }
private:
    float spin = 0;
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
    template <typename C> int Weigh(const Text::Str& tag) const;

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

    // The node is constructed first and registered after, as engines often do.
    template <typename... Args>
    NodeRef<T> Make(Registry& reg, Stage* stage, Args&&... args) {
        NodeRef<> r = reg.Add();
        T node(std::forward<Args>(args)...);
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

// A node with no default constructor: a class deriving it must pass the arguments.
class Plaque : public Node {
public:
    std::string text;
    int size;
    Plaque(const char* t, int s) : text(t), size(s) {}
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

    template <typename T = Node, typename... Args>
        requires std::derived_from<T, Node>
    NodeRef<T> Spawn(Args&&... args) {
        Registry::Current() = &registry;
        return PoolOf<T>().Make(registry, this, std::forward<Args>(args)...);
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
    static float& Scale() { static float scale = 1; return scale; }
    static float GetTimeScale() { return Scale(); }
    static void SetTimeScale(float s) { Scale() = s; }
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

// --- timers -------------------------------------------------------------------------
//
// A handle with no `operator bool` and no `operator->`: whether it is alive is the
// timer table's to say, the empty one is `TimerId<T>::None()`, and `Get()` gives
// the timer.

struct Timer {
    float left = 0;
    int fired = 0;
};

template <typename T>
struct TimerId {
    std::uint32_t id = 0;
    static TimerId None() { return TimerId{}; }
    T* Get() const;
    std::uint32_t Id() const { return id; }
};

class Timers {
public:
    static std::vector<std::unique_ptr<Timer>>& Table() {
        static std::vector<std::unique_ptr<Timer>> table(1);   // id 0 is no timer
        return table;
    }
    static TimerId<Timer> Start(float seconds) {
        auto t = std::make_unique<Timer>();
        t->left = seconds;
        Table().push_back(std::move(t));
        return TimerId<Timer>{static_cast<std::uint32_t>(Table().size() - 1)};
    }
    static void Stop(TimerId<Timer> t) { if (Alive(t)) Table()[t.id].reset(); }
    template <typename T>
    static bool Alive(TimerId<T> t) { return t.id != 0 && t.id < Table().size() && Table()[t.id]; }
};

template <typename T>
T* TimerId<T>::Get() const { return static_cast<T*>(Timers::Table()[id].get()); }

// --- labels -------------------------------------------------------------------------
//
// Strings in the shapes engines return them: a C string, a std::string by value (a
// temporary), and the engine's own string class.


struct Labels {
    static const char* Plain() { return "plain"; }
    static const char* Nothing() { return nullptr; }
    static std::string Built(int k) { return "built-" + std::to_string(k); }
    static Text::Str Custom() {
        return Text::Str("ab\0cd", 5);   // an embedded '\0', so only the length tells
    }
    // Taking the engine's string, which no const char* converts to implicitly.
    static int Measure(const Text::Str& s) { return s.n; }
    static std::string Join(const Text::Str& a, int sep, const Text::Str& b) {
        return std::string(a.buf, a.n) + static_cast<char>(sep) + std::string(b.buf, b.n);
    }
};

// --- grids ---------------------------------------------------------------------------
//
// Indexed two ways: accessor functions taking the indices, and a vector's operator[].

class Grid {
public:
    int w, h;
    std::vector<float> cells;
    Grid(int w, int h) : w(w), h(h), cells(w * h) {}
    float GetCell(int x, int y) const { return cells[y * w + x]; }
    void SetCell(int x, int y, float v) { cells[y * w + x] = v; }
};

template <typename C>
int Node::Weigh(const Text::Str& tag) const { return tag.n * 10 + (std::is_same_v<C, Motion> ? 1 : 2); }

// --- palettes --------------------------------------------------------------------------
//
// A plain class the engine keeps none of: whoever makes one owns it. It cannot be
// copied, and counts the live ones so a test can see each destroyed.

class Palette {
public:
    static int& Live() { static int n = 0; return n; }
    std::string name;
    int colors = 1;
    Palette() : name("plain") { Live()++; }
    Palette(const char* n, int c) : name(n), colors(c) { Live()++; }
    Palette(const Palette&) = delete;
    Palette& operator=(const Palette&) = delete;
    virtual ~Palette() { Live()--; }
    virtual int Weight() { return colors; }
    // Qualified virtuals: an override must repeat `const` and `noexcept`.
    virtual int Shade() const { return colors * 2; }
    virtual void Touch() noexcept { touched++; }
    int Hue() const { return colors + 1; }
    void Fade() { colors--; }
    int touched = 0;
};

// Takes them as a pointer (null allowed) or as a reference.
struct Painter {
    static int Count(Palette* p) { return p ? p->colors : -1; }
    static int Weigh(const Palette& p) { return const_cast<Palette&>(p).Weight(); }
    static int Live() { return Palette::Live(); }
    static int ShadeOf(const Palette& p) { return p.Shade(); }
    static void TouchOf(Palette& p) { p.Touch(); }

    // Hands one out by value, lends one (by reference, or by pointer that may be
    // null), or hands one over that the caller must delete.
    static Palette Make(const char* n, int c) { return Palette(n, c); }
    static Palette Copy(const Palette& p) { return Palette((p.name + "'").c_str(), p.colors); }
    static Palette& Shared() { static Palette shared("shared", 9); return shared; }
    static Palette* Find(int colors) { return colors == Shared().colors ? &Shared() : nullptr; }
    static Palette* Create(const char* n, int c) { return new Palette(n, c); }
    // A factory of any palette class, forwarding the constructor's arguments.
    template <typename T, typename... A>
    static T* Build(A&&... a) { return new T(std::forward<A>(a)...); }
};

// Fields of every kind, for bindings that expose some of them: a value, a
// pointer to one, a reference, a pointer to an object, a constant, one the binding
// leaves out and a private one.
#define TOYBOX_GAUGE_UNITS 12
struct Dial { float x = 3, y = 4; };
struct Gauge {
    int level = 100;
    int* counter = nullptr;
    int& tally;
    Dial* dial = nullptr;
    Dial* spare = nullptr;
    Dial home{1, 2};
    static constexpr int Max = 250;
    static constexpr int Min = 5;
    static constexpr double Scale = 1.5;
    int unbound = 42;
    explicit Gauge(int& t) : tally(t) {}
    int Hidden() const { return hidden; }
    static Gauge* Instance() {
        static int count = 5;
        static Dial d;
        static Gauge g(count);
        g.counter = &count;
        g.dial = &d;
        return &g;
    }
    static void Report() {
        Gauge* g = Instance();
        Console::Print("C++: level %d, unbound %d, count %d, tally %d, dial.x %g, hidden %d",
                       g->level, g->unbound, *g->counter, g->tally, g->dial->x, g->Hidden());
        Console::Print("C++: home (%g, %g), spare %s", g->home.x, g->home.y,
                       g->spare ? "set" : "null");
    }
private:
    int hidden = 7;
};

// Class templates: one with a virtual a binding's class may override, one of two
// parameters, a value type, and functions over one instance.
template <typename T> struct Cell {
    T value{};
    Cell() = default;
    explicit Cell(T v) : value(v) {}
    T Get() const { return value; }
    void Put(T v) { value = v; }
    Cell<T> Doubled() const { return Cell<T>(value * 2); }
    virtual T Scaled() const { return value * 2; }
    virtual ~Cell() = default;
    static int Width() { return static_cast<int>(sizeof(T)); }
    static Cell<T>& Shared() { static Cell<T> s(T(42)); return s; }
    template <typename U> U As() const { return static_cast<U>(value); }
    Cell<int64_t> Widened() const { return Cell<int64_t>(static_cast<int64_t>(value) * 1000000000); }
};
struct Shelf { Cell<int> slot{3}; Cell<int>* spare = nullptr; static Shelf& Main() { static Shelf s; return s; } };
template <typename K, typename V> struct KeyVal { K key{}; V val{}; V Value() const { return val; } };
template <typename T> struct Duo { T x{}, y{}; T Dot(const Duo<T>& o) const { return x * o.x + y * o.y; } };
inline int ScaledPlus(const Cell<int>& c, int k) { return c.Scaled() + k; }

} // namespace Toybox
