/* The C side of pinvoke_internal.ns, linked into the program. */
#include <stddef.h>
#include <string.h>

typedef struct { float x, y; } vec2;
typedef struct { vec2 min, max; int tag; } box;

float vec2_dot(vec2 a, vec2 b) { return a.x * b.x + a.y * b.y; }
void vec2_scale(vec2* v, float s) { v->x *= s; v->y *= s; }
box box_grow(box b, float by) {
  b.min.x -= by; b.min.y -= by; b.max.x += by; b.max.y += by; b.tag++;
  return b;
}
int is_odd(int x) { return x & 1; }                 /* a BOOL */
unsigned char is_even(int x) { return !(x & 1); }    /* a one-byte bool */
int any_set(int flag) { return flag != 0; }
void fill(int* xs, int n, int v) { for (int i = 0; i < n; i++) xs[i] = v + i; }
size_t name_len(const char* s) { return strlen(s); }
int sum_and_count(const int* xs, int n, int* count) {
  int s = 0;
  for (int i = 0; i < n; i++) s += xs[i];
  *count = n;
  return s;
}
