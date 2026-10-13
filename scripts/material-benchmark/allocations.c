// Diagnostic-only interposer. Never linked into the iOS application.
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <malloc/malloc.h>

static _Atomic bool enabled = false;
static _Atomic uint64_t events = 0;
static _Thread_local unsigned depth = 0;
static void enter(void) {
    if (depth++ == 0 && atomic_load_explicit(&enabled, memory_order_relaxed))
        atomic_fetch_add_explicit(&events, 1, memory_order_relaxed);
}
static void leave(void) { --depth; }
void material_alloc_begin(void) {
    atomic_store(&events, 0);
    atomic_store(&enabled, true);
}
uint64_t material_alloc_end(void) {
    atomic_store(&enabled, false);
    return atomic_load(&events);
}
// Keep a positive-control Swift array observable without allocating here.
static volatile const void *observed;
void material_consume(const void *pointer) { observed = pointer; }

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static const struct { const void *new_fn; const void *old_fn; } \
    pair_##original __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)&replacement, (const void *)&original };

static void *count_malloc(size_t n) { enter(); void *p = malloc(n); leave(); return p; }
static void *count_calloc(size_t n, size_t s) { enter(); void *p = calloc(n, s); leave(); return p; }
static void *count_realloc(void *p, size_t n) { enter(); void *q = realloc(p, n); leave(); return q; }
static void *count_valloc(size_t n) { enter(); void *p = valloc(n); leave(); return p; }
static int count_posix(void **p, size_t a, size_t n) { enter(); int r = posix_memalign(p, a, n); leave(); return r; }
static void *count_zone_malloc(malloc_zone_t *z, size_t n) { enter(); void *p = malloc_zone_malloc(z, n); leave(); return p; }
static void *count_zone_calloc(malloc_zone_t *z, size_t n, size_t s) { enter(); void *p = malloc_zone_calloc(z, n, s); leave(); return p; }
static void *count_zone_realloc(malloc_zone_t *z, void *p, size_t n) { enter(); void *q = malloc_zone_realloc(z, p, n); leave(); return q; }
static void *count_zone_memalign(malloc_zone_t *z, size_t a, size_t n) { enter(); void *p = malloc_zone_memalign(z, a, n); leave(); return p; }
INTERPOSE(count_malloc, malloc)
INTERPOSE(count_calloc, calloc)
INTERPOSE(count_realloc, realloc)
INTERPOSE(count_valloc, valloc)
INTERPOSE(count_posix, posix_memalign)
INTERPOSE(count_zone_malloc, malloc_zone_malloc)
INTERPOSE(count_zone_calloc, malloc_zone_calloc)
INTERPOSE(count_zone_realloc, malloc_zone_realloc)
INTERPOSE(count_zone_memalign, malloc_zone_memalign)
