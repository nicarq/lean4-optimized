/*
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Nico Arqueros
*/
#include <atomic>
#include <cstdlib>
#include <mutex>
#include <unordered_map>
#include "lean/lean.h"
#include "runtime/metal.h"

namespace lean {
#ifndef LEAN_METAL
bool metal_available() { return false; }
bool metal_map_u64(std::string const &, std::vector<uint64_t> const &,
                   std::vector<uint64_t> const &, std::vector<uint64_t> &) { return false; }
#endif

struct metal_kernel {
    std::string source;
    unsigned arity;
};

struct metal_registry {
    std::mutex mutex;
    std::unordered_map<void *, metal_kernel> kernels;
    std::atomic<uint64_t> dispatches{0};
};

static metal_registry & registry() {
    static metal_registry r;
    return r;
}

static bool try_map(lean_object * f, lean_object * a, std::vector<uint64_t> & output) {
    char const * enabled = std::getenv("LEAN_METAL");
    // Explicit opt-in until the end-to-end crossover is measured for each workload.
    if (!enabled || std::string(enabled) != "1" || lean_array_size(a) == 0) return false;
    if (lean_is_scalar(f) || !lean_is_closure(f)) return false;
    metal_kernel kernel;
    {
        auto & r = registry();
        std::lock_guard<std::mutex> lock(r.mutex);
        auto it = r.kernels.find(lean_closure_fun(f));
        if (it == r.kernels.end()) return false;
        kernel = it->second;
    }
    unsigned fixed = lean_closure_num_fixed(f);
    if (kernel.arity != fixed + 1 || lean_closure_arity(f) != kernel.arity) return false;
    if (!metal_available()) return false;
    std::vector<uint64_t> captures;
    for (unsigned i = 0; i < fixed; ++i)
        captures.push_back(lean_unbox_uint64(lean_closure_get(f, i)));
    std::vector<uint64_t> input(lean_array_size(a));
    for (size_t i = 0; i < input.size(); ++i)
        input[i] = lean_unbox_uint64(lean_array_get_core(a, i));
    if (!metal_map_u64(kernel.source, input, captures, output)) return false;
    registry().dispatches.fetch_add(1, std::memory_order_relaxed);
    return true;
}
}

extern "C" LEAN_EXPORT void lean_metal_register_u64(void * fn, char const * source, unsigned arity) {
    auto & r = lean::registry();
    std::lock_guard<std::mutex> lock(r.mutex);
    r.kernels.emplace(fn, lean::metal_kernel{source, arity});
}

extern "C" LEAN_EXPORT lean_object * lean_metal_map_u64(lean_object * f, lean_object * a) {
    std::vector<uint64_t> output;
    bool accelerated = false;
    try {
        accelerated = lean::try_map(f, a, output);
    } catch (std::bad_alloc const &) {
        // Allocation failure in the optional accelerator leaves both Lean arguments untouched.
    }
    if (accelerated) {
        for (size_t i = 0; i < output.size(); ++i)
            a = lean_array_uset(a, i, lean_box_uint64(output[i]));
    } else {
        size_t size = lean_array_size(a);
        for (size_t i = 0; i < size; ++i) {
            lean_object * value = lean_array_get_core(a, i);
            lean_inc(value);
            a = lean_array_uset(a, i, lean_box(0));
            lean_inc(f);
            a = lean_array_uset(a, i, lean_apply_1(f, value));
        }
    }
    lean_dec(f);
    return a;
}

extern "C" LEAN_EXPORT lean_object * lean_metal_available() {
    return lean_io_result_mk_ok(lean_box(lean::metal_available()));
}

extern "C" LEAN_EXPORT lean_object * lean_metal_dispatch_count() {
    return lean_io_result_mk_ok(lean_box_uint64(lean::registry().dispatches.load(std::memory_order_relaxed)));
}
