/*
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
*/
#pragma once
#include <cstddef>
#include <cstdint>

// Experimental Phi81 product batch. Keys and initial sums are canonical
// Goldilocks words. Digits are -1, 0, or 1. Arrays use block/row/lane and
// block/child/lane order. Only completed row/child/lane sums return to the host.
struct metal_batch_stats {
    uint64_t device_ns = 0;
    size_t input_bytes = 0;
    unsigned submissions = 0;
};

bool metal_batch_fits(size_t blocks, size_t rows, size_t children);
bool metal_batch_accumulate(uint64_t const * keys, int8_t const * digits,
    uint8_t const * active, uint64_t const * initial, uint64_t * output,
    size_t blocks, size_t rows, size_t children, metal_batch_stats & stats);
