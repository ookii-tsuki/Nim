#include <chrono>
#include "toybox.hpp"
void NimMain();
extern "C" void nsStart();
extern "C" double nsChecksum();
int main() {
    NimMain();
    nsStart();
    Toybox::Director::Run(20000);
    std::printf("%.3f\n", nsChecksum());
    return 0;
}
