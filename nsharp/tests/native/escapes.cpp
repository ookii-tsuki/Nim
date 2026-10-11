#include "toybox.hpp"
void NimMain();
extern "C" void nsStart();
extern "C" void nsFail();
// The engine's own report, replacing N#'s default (print and stop).
extern "C" void nsOnUnhandled(const char* where, const char* message, const char* type) {
    std::printf("engine: %s threw %s: %s\n", where, type, message);
}
int main() {
    NimMain();
    nsStart();
    Toybox::Director::Run(3);
    nsFail();
    std::printf("still running\n");
    return 0;
}
