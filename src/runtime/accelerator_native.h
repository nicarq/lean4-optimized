/*
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
*/
#pragma once
#include <cstddef>
#include <cstdint>

// Dense captures, immutable tables, and ordered outputs. A non-null table identity
// denotes immutable data retained for the process lifetime. No Lean objects cross.
bool lean_native_metal_map(char const * source, uint64_t const * input, size_t words,
    uint64_t const * tables, size_t table_words, void const * table_identity,
    uint64_t * output, size_t count, uint64_t & device_ns, bool & table_cache_hit);
