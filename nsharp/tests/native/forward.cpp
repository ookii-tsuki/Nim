#include "toybox.hpp"
void NimMain();
extern "C" void nsStart();
int main() {
    NimMain();
    nsStart();
    Toybox::Director::Run(2);
    return 0;
}
