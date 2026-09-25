/*
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
*/
#include <lean/lean.h>
#include "metal_batch.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

extern "C" lean_object * lean_pidec_batch_cpu(lean_object *, lean_object *);

namespace {
constexpr uint64_t modulus = 0xffffffff00000001ULL;
bool array(lean_object * value, size_t count) {
    return !lean_is_scalar(value) && lean_obj_tag(value) == LeanArray && lean_array_size(value) == count;
}
lean_object * at(lean_object * value, size_t index) { return lean_array_get_core(value, index); }

bool words(lean_object * value, uint64_t * output) {
    if (!array(value, 54)) return false;
    for (size_t i = 0; i < 54; ++i) {
        auto word = at(value, i);
        if (lean_is_scalar(word) || lean_obj_tag(word) != 0 || lean_ctor_num_objs(word) != 0) return false;
        uint64_t v = lean_unbox_uint64(word);
        if (v >= modulus) return false;
        output[i] = v;
    }
    return true;
}

lean_object * execute(lean_object * batch, lean_object * initial, metal_batch_stats & stats) {
    if (lean_is_scalar(batch) || lean_obj_tag(batch) != LeanArray ||
        lean_is_scalar(initial) || lean_obj_tag(initial) != LeanArray) return nullptr;
    size_t blocks = lean_array_size(batch), rows = lean_array_size(initial);
    if (!blocks || !rows) return nullptr;
    auto first = at(initial, 0);
    if (lean_is_scalar(first) || lean_obj_tag(first) != LeanArray) return nullptr;
    size_t children = lean_array_size(first);
    if (!metal_batch_fits(blocks, rows, children)) return nullptr;
    std::vector<uint64_t> keys(blocks * rows * 54), sums(rows * children * 54), output(sums.size());
    std::vector<int8_t> digits(blocks * children * 54);
    std::vector<uint8_t> active(blocks * children);
    for (size_t r = 0; r < rows; ++r) {
        if (!array(at(initial,r),children)) return nullptr;
        for (size_t c = 0; c < children; ++c)
            if (!words(at(at(initial,r),c),sums.data()+(r*children+c)*54)) return nullptr;
    }
    for (size_t b = 0; b < blocks; ++b) {
        auto pair = at(batch,b);
        if (lean_is_scalar(pair) || lean_obj_tag(pair) != 0 || lean_ctor_num_objs(pair) != 2) return nullptr;
        auto key_rows = lean_ctor_get(pair,0), child_rows = lean_ctor_get(pair,1);
        if (!array(key_rows,rows) || !array(child_rows,children)) return nullptr;
        for (size_t r = 0; r < rows; ++r)
            if (!words(at(key_rows,r),keys.data()+(b*rows+r)*54)) return nullptr;
        for (size_t c = 0; c < children; ++c) {
            auto option = at(child_rows,c);
            if (lean_is_scalar(option)) { if (lean_unbox(option) != 0) return nullptr; continue; }
            if (lean_obj_tag(option) != 1 || lean_ctor_num_objs(option) != 1) return nullptr;
            uint64_t values[54];
            if (!words(lean_ctor_get(option,0),values)) return nullptr;
            active[b*children+c] = 1;
            for (size_t i = 0; i < 54; ++i) {
                if (values[i] != 0 && values[i] != 1 && values[i] != modulus-1) return nullptr;
                digits[(b*children+c)*54+i] = values[i] == modulus-1 ? -1 : static_cast<int8_t>(values[i]);
            }
        }
    }
    if (!metal_batch_accumulate(keys.data(),digits.data(),active.data(),sums.data(),output.data(),
            blocks,rows,children,stats)) return nullptr;
    auto result = lean_alloc_array(rows,rows);
    for (size_t r = 0; r < rows; ++r) {
        auto child_rows = lean_alloc_array(children,children);
        for (size_t c = 0; c < children; ++c) {
            auto coeffs = lean_alloc_array(54,54);
            for (size_t i = 0; i < 54; ++i)
                lean_array_set_core(coeffs,i,lean_box_uint64(output[(r*children+c)*54+i]));
            lean_array_set_core(child_rows,c,coeffs);
        }
        lean_array_set_core(result,r,child_rows);
    }
    return result;
}
}

extern "C" LEAN_EXPORT lean_object * lean_pidec_metal_fits(lean_object * blocks,
    lean_object * rows, lean_object * children) {
    bool fits = lean_is_scalar(blocks) && lean_is_scalar(rows) && lean_is_scalar(children) &&
        metal_batch_fits(lean_unbox(blocks),lean_unbox(rows),lean_unbox(children));
    lean_dec(blocks); lean_dec(rows); lean_dec(children);
    return lean_io_result_mk_ok(lean_box(fits));
}

extern "C" LEAN_EXPORT lean_object * lean_pidec_metal_batch(lean_object * batch, lean_object * initial) {
    auto mode = std::getenv("LEAN_ACCELERATOR");
    if (!mode || std::strcmp(mode,"metal")) return lean_pidec_batch_cpu(batch,initial);
    auto started = std::chrono::steady_clock::now();
    metal_batch_stats stats;
    lean_object * result = nullptr;
    try { result = execute(batch,initial,stats); } catch (std::bad_alloc const &) {}
    if (auto path = std::getenv("LEAN_ACCEL_TRACE_FILE")) {
        if (auto file = std::fopen(path,"a")) {
            auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now()-started).count();
            std::fprintf(file,"{\"operation\":\"pidec_batch\",\"metal\":%s,\"submissions\":%u,"
                "\"input_bytes\":%zu,\"device_ns\":%llu,\"elapsed_ns\":%lld}\n",
                result ? "true" : "false", stats.submissions,stats.input_bytes,
                static_cast<unsigned long long>(stats.device_ns),static_cast<long long>(ns));
            std::fclose(file);
        }
    }
    if (!result) return lean_pidec_batch_cpu(batch,initial);
    lean_dec(batch); lean_dec(initial);
    return result;
}
