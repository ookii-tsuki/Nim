#include "toybox.hpp"
void NimMain();
extern "C" void nsStart();
int main() {
    NimMain();
    nsStart();
    Toybox::Director::Run(3);
    return 0;
}
