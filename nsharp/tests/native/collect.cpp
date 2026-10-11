#include "toybox.hpp"
void NimMain();
extern "C" void nsStart();
int main() {
    NimMain();
    nsStart();
    Toybox::Director::Run(0);
    return 0;
}
