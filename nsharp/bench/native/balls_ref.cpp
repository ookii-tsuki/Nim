// The same workload written in C++ against the engine, as an engine user would:
// the pointer is taken from the handle once per ball.
#include "toybox.hpp"
using namespace Toybox;

struct Ball : Node { float x = 0, y = 0, vx = 0, vy = 0; };

struct Court : Stage {
    std::vector<NodeRef<Ball>> balls;
    void Begin() override {
        for (int i = 0; i < 1000; i++) {
            NodeRef<Ball> r = Spawn<Ball>();
            Ball* b = r.operator->();
            b->x = (float)i; b->y = (float)(10 + i % 7); b->vx = (float)(1 + i % 3); b->vy = 0;
            balls.push_back(r);
        }
    }
    void Tick(float dt) override {
        for (auto& r : balls) {
            Ball* b = r.operator->();
            b->vy -= 9.8f * dt;
            b->x += b->vx * dt;
            b->y += b->vy * dt;
            if (b->y < 0) { b->y = 0; b->vy = -b->vy * 0.5f; }
        }
    }
};

int main() {
    Director::Play<Court>();
    Director::Run(20000);
    double s = 0;
    for (auto& r : static_cast<Court*>(Director::Current().get())->balls) s += r->x + r->y;
    std::printf("%.3f\n", s);
    return 0;
}
