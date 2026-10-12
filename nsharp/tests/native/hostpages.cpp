// The host's side of -d:nimAllocPagesViaHost: a stand-in for an engine's own
// allocator (plain aligned malloc here) that counts what Nim asks it for.
#include <cstdio>
#include <cstdlib>
#include <cstdint>

static long regions = 0, live = 0, misaligned = 0;
static size_t liveBytes = 0, peakBytes = 0;

extern "C" void* nimHostAllocPages(size_t size, size_t alignment) {
    void* p = std::aligned_alloc(alignment, (size + alignment - 1) / alignment * alignment);
    if (!p) return nullptr;
    if (reinterpret_cast<uintptr_t>(p) % alignment != 0) misaligned++;
    regions++; live++;
    liveBytes += size;
    if (liveBytes > peakBytes) peakBytes = liveBytes;
    return p;
}

extern "C" void nimHostDeallocPages(void* p, size_t size) {
    live--;
    liveBytes -= size;
    std::free(p);
}

void NimMain();
extern "C" long long nsChurn(int rounds);

int main() {
    NimMain();
    bool early = regions > 0;            // Nim's own start-up already came here
    long long sum = nsChurn(5);
    std::printf("checksum: %lld\n", sum);
    std::printf("regions from the host during start-up: %s\n", early ? "yes" : "no");
    std::printf("regions from the host: %s\n", regions > 1 ? "yes" : "no");
    std::printf("all page-aligned: %s\n", misaligned == 0 ? "yes" : "no");
    std::printf("peak above 1 MB: %s\n", peakBytes > (1u << 20) ? "yes" : "no");
    return 0;
}
