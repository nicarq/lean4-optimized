/* Ownership checks for persistent closure application and its fallback paths. */
#include <lean/lean.h>
#include <stdio.h>
#include <stdlib.h>

extern void lean_initialize_runtime_module(void);

static unsigned finalized;
static lean_external_class * tracked_class;

static void check(bool condition, const char * message) {
    if (!condition) {
        fprintf(stderr, "%s\n", message);
        exit(1);
    }
}

static void finalize(void * data) { ++*(unsigned *)data; }
static void foreach(void * data, b_lean_obj_arg visit) { (void)data; (void)visit; }
static lean_object * tracked(void) { return lean_alloc_external(tracked_class, &finalized); }
static lean_object * identity(lean_object * value) { return value; }
static lean_object * consume(lean_object * value) { lean_dec(value); return lean_box(42); }
static lean_object * replace(lean_object * value) { lean_dec(value); return tracked(); }
static lean_object * captured(lean_object * capture, lean_object * value) {
    lean_dec(capture);
    return value;
}

int main(void) {
    lean_initialize_runtime_module();
    tracked_class = lean_register_external_class(finalize, foreach);
    lean_object * same = lean_alloc_closure((void *)identity, 1, 0);
    lean_mark_persistent(same);
    for (unsigned i = 0; i < 3; ++i) {
        lean_object * value = tracked();
        lean_object * result = lean_apply_1(same, value);
        check(result == value && finalized == i, "identity changed or released its argument");
        lean_dec(result);
        check(lean_is_persistent(same), "persistent closure changed reference count");
    }
    lean_object * drop = lean_alloc_closure((void *)consume, 1, 0);
    lean_mark_persistent(drop);
    check(lean_apply_1(drop, tracked()) == lean_box(42) && finalized == 4,
          "consuming persistent closure did not release its argument once");
    lean_object * make = lean_alloc_closure((void *)replace, 1, 0);
    lean_mark_persistent(make);
    lean_object * result = lean_apply_1(make, tracked());
    check(finalized == 5, "replacement did not consume its argument");
    lean_dec(result);
    check(finalized == 6, "replacement result lost ownership");

    lean_object * exclusive = lean_alloc_closure((void *)identity, 1, 0);
    lean_dec(lean_apply_1(exclusive, tracked()));
    check(finalized == 7, "exclusive fallback changed argument ownership");
    lean_object * shared = lean_alloc_closure((void *)consume, 1, 0);
    lean_inc(shared);
    check(lean_apply_1(shared, tracked()) == lean_box(42) && shared->m_rc == 1,
          "shared fallback did not consume one closure reference");
    lean_dec(shared);
    lean_object * mt = lean_alloc_closure((void *)consume, 1, 0);
    lean_mark_mt(mt);
    lean_inc(mt);
    check(lean_apply_1(mt, tracked()) == lean_box(42) && mt->m_rc == -1,
          "multithreaded fallback did not consume one closure reference");
    lean_dec(mt);
    check(finalized == 9, "fallback argument release count differs");

    lean_object * closed = lean_alloc_closure((void *)captured, 2, 1);
    lean_closure_set(closed, 0, tracked());
    lean_inc(closed);
    check(lean_apply_1(closed, lean_box(10)) == lean_box(10) && finalized == 9,
          "shared captured closure released a live capture");
    lean_dec(closed);
    check(finalized == 10, "captured fallback did not release its capture");
    lean_object * partial = lean_alloc_closure((void *)captured, 2, 0);
    partial = lean_apply_1(partial, tracked());
    check(lean_closure_num_fixed(partial) == 1 && finalized == 10,
          "partial application lost its capture");
    check(lean_apply_1(partial, lean_box(11)) == lean_box(11) && finalized == 11,
          "partial application did not consume its capture");
    check(lean_apply_1(lean_box(7), tracked()) == lean_box(7) && finalized == 12,
          "erased-proof application did not release its argument");
    lean_object * persistent_capture = lean_alloc_closure((void *)captured, 2, 1);
    lean_closure_set(persistent_capture, 0, lean_box(99));
    lean_mark_persistent(persistent_capture);
    lean_object * value = tracked();
    result = lean_apply_1(persistent_capture, value);
    check(result == value && finalized == 12,
          "persistent captured closure used the unary fast path");
    lean_dec(result);
    check(finalized == 13 && lean_is_persistent(persistent_capture),
          "persistent captured closure changed ownership");
    puts("persistent application ownership checks passed");
    return 0;
}
