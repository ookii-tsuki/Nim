/* The C side of pinvoke_across_files. */
typedef struct { int w, h; } size;
int size_area(size s) { return s.w * s.h; }
void size_grow(size* s, int by) { s->w += by; s->h += by; }
int unit_next(int u) { return u + 3; }
