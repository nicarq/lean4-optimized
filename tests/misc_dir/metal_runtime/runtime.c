/* Check that failed GPU setup leaves inputs intact and runs the CPU callback. */
#include <lean/lean.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void lean_initialize_runtime_module(void);

static void check(bool value, char const * message) {
    if (!value) { fprintf(stderr, "%s\n", message); exit(1); }
}

static lean_object * square(lean_object * x) {
    uint64_t n = lean_unbox_uint64(x);
    lean_dec(x);
    return lean_box_uint64(n * n);
}

static lean_object * increment(lean_object * x) {
    uint64_t n = lean_unbox_uint64(x);
    lean_dec(x);
    return lean_box_uint64(n + 1);
}

static uint64_t count(void) {
    lean_object * r = lean_metal_dispatch_count();
    uint64_t n = lean_unbox_uint64(lean_io_result_get_value(r));
    lean_dec(r);
    return n;
}

int main(void) {
    lean_initialize_runtime_module();
    lean_metal_register_u64((void *)square, "this is not a Metal program", 1);
    lean_object * input = lean_mk_empty_array_with_capacity(lean_box(257));
    for (size_t i = 0; i < 257; ++i)
        input = lean_array_push(input, lean_box_uint64(UINT64_MAX - i));
    lean_inc(input);
    lean_object * output = lean_metal_map_u64(lean_alloc_closure((void *)square, 1, 0), input);
    for (size_t i = 0; i < 257; ++i) {
        uint64_t n = UINT64_MAX - i;
        check(lean_unbox_uint64(lean_array_get_core(input, i)) == n, "fallback mutated shared input");
        check(lean_unbox_uint64(lean_array_get_core(output, i)) == n * n, "shader failure changed result");
    }
    check(count() == 0, "failed shader counted as a dispatch");
    lean_dec(output);

    char const * source =
        "#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void lean_map(device const ulong *a [[buffer(0)]],"
        "device ulong *b [[buffer(1)]], constant ulong *c [[buffer(2)]],"
        "constant ulong &n [[buffer(3)]], uint i [[thread_position_in_grid]]) {"
        "if (ulong(i)<n) b[i]=a[i]+1UL;}";
    lean_metal_register_u64((void *)increment, source, 1);
    output = lean_metal_map_u64(lean_alloc_closure((void *)increment, 1, 0), input);
    for (size_t i = 0; i < 257; ++i)
        check(lean_unbox_uint64(lean_array_get_core(output, i)) == UINT64_MAX - i + 1,
              "valid shader changed result");
    lean_dec(output);
    lean_object * available = lean_metal_available();
    bool has_metal = lean_unbox(lean_io_result_get_value(available));
    lean_dec(available);
    char const * enabled = getenv("LEAN_METAL");
    if (has_metal && enabled && strcmp(enabled, "1") == 0)
        check(count() == 1, "valid shader did not run");
    puts("Metal runtime checks passed");
    return 0;
}
