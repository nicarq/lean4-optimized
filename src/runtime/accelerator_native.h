/*
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
*/
#pragma once
#include <cstddef>
#include <cstdint>

// Dense captures, immutable tables, and ordered outputs. A non-null table identity
// denotes immutable data retained for the process lifetime. No Lean objects cross.
struct lean_native_step {
    char const * source;
    uint64_t const * input;
    size_t words;
    uint64_t const * tables;
    size_t table_words;
    void const * table_identity;
    size_t count;
    bool table_cache_hit{false};
};

// Each step can read the preceding output. Only the last output reaches the host.
bool lean_native_metal_execute(lean_native_step * steps, size_t stages,
    uint64_t * output, uint64_t & device_ns, unsigned & synchronizations);
