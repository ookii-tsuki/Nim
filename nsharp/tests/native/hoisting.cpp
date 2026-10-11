#include "toybox.hpp"
void NimMain();
extern "C" void nsStart();
int main() {
    NimMain();
    nsStart();
    Toybox::Director::Run(1);
    return 0;
}
