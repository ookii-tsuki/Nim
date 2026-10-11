#include "toybox.hpp"
void NimMain();
extern "C" void nsStart();
int main() {
    NimMain();
    nsStart();
    Toybox::Director::Current().reset();   // the stage, its pools and their nodes
    std::printf("at exit: live %d\n", Toybox::Palette::Live());
    return 0;
}
