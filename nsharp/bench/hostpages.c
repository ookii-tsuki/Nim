/* A host for -d:nimAllocPagesViaHost, for timing it: Nim's allocator takes its
   pages from here instead of from the OS. Plain aligned malloc stands in for an
   engine's own allocator.
   NS_BENCH_FLAGS="-d:release -d:nimAllocPagesViaHost --compile:$PWD/hostpages.c" */
#include <stdlib.h>

void* nimHostAllocPages(size_t size, size_t alignment) {
  return aligned_alloc(alignment, (size + alignment - 1) / alignment * alignment);
}

void nimHostDeallocPages(void* p, size_t size) {
  (void)size;
  free(p);
}
