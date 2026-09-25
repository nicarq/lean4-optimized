#include "metal_batch.h"
#include <algorithm>
#include <cstdio>
#include <vector>

namespace {
constexpr uint64_t p = 0xffffffff00000001ULL;
uint64_t add(uint64_t a, uint64_t b) { return static_cast<__uint128_t>(a) + b >= p ?
    static_cast<__uint128_t>(a) + b - p : a + b; }
uint64_t sub(uint64_t a, uint64_t b) { return (static_cast<__uint128_t>(a) + p - b) % p; }
}

int main() {
    // Three blocks exercise empty, positive and negative contributions. Multiple
    // rows and children check indexing; 54 lanes also give a partial SIMD group.
    size_t const blocks = 3, rows = 2, children = 3, degree = 54;
    std::vector<uint64_t> keys(blocks * rows * degree);
    std::vector<int8_t> digits(blocks * children * degree);
    std::vector<uint8_t> active(blocks * children, 1);
    std::vector<uint64_t> initial(rows * children * degree), expected, output(initial.size());
    for (size_t i = 0; i < keys.size(); ++i) keys[i] = i % 2 ? p - 1 - i : i * i;
    for (size_t i = 0; i < digits.size(); ++i) digits[i] = static_cast<int>(i % 3) - 1;
    for (size_t i = 0; i < initial.size(); ++i) initial[i] = p - 1 - i;
    active[0] = 0;
    std::fill(digits.begin(), digits.begin() + degree, 0);
    expected = initial;
    for (size_t b = 0; b < blocks; ++b) for (size_t r = 0; r < rows; ++r)
        for (size_t c = 0; c < children; ++c) for (size_t i = 0; i < degree; ++i)
            for (size_t j = 0; j < degree; ++j) {
                auto k = keys[(b * rows + r) * degree + i];
                auto d = digits[(b * children + c) * degree + j];
                auto accumulate = [&](size_t lane, int sign) {
                    auto & value = expected[(r * children + c) * degree + lane];
                    if (sign > 0) value = add(value, k);
                    if (sign < 0) value = sub(value, k);
                };
                size_t power = i + j;
                if (power < degree) accumulate(power, d);
                else if (power < 81) { accumulate(power - 54, -d); accumulate(power - 27, -d); }
                else accumulate(power - 81, d);
            }
    metal_batch_stats stats;
    if (!metal_batch_accumulate(keys.data(), digits.data(), active.data(), initial.data(),
            output.data(), blocks, rows, children, stats)) {
        std::fprintf(stderr, "Metal batch did not execute\n"); return 1;
    }
    if (output != expected || stats.submissions != 1) {
        std::fprintf(stderr, "Metal batch result differs\n"); return 1;
    }
    std::fill(digits.begin(), digits.end(), 0);
    stats = {};
    if (!metal_batch_accumulate(keys.data(), digits.data(), active.data(), initial.data(),
            output.data(), blocks, rows, children, stats) || output != initial) return 1;
    stats = {};
    if (!metal_batch_accumulate(nullptr, nullptr, nullptr, initial.data(), output.data(),
            0, rows, children, stats) || output != initial || stats.submissions != 0) return 1;
    if (metal_batch_fits(SIZE_MAX, rows, children)) return 1;
    std::puts("Metal batch: all coefficients, changed inputs, empty batch, and bounds passed");
}
