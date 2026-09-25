/*
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
*/
#include <lean/lean.h>
#include "runtime/accelerator_native.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#ifndef LEAN_USE_METAL_ACCELERATOR
bool lean_native_metal_execute(lean_native_step *, size_t, uint64_t *, uint64_t &, unsigned &) { return false; }
#endif

namespace {
constexpr uint64_t table_bit = uint64_t{1} << 63;

bool native_enabled(size_t count) {
#ifndef LEAN_USE_METAL_ACCELERATOR
    return false;
#else
    char const * mode = std::getenv("LEAN_ACCELERATOR");
    if (!mode || (std::strcmp(mode, "metal") != 0 && std::strcmp(mode, "auto") != 0)) return false;
    size_t minimum = 65536; // Preserve the existing accelerator dispatch policy.
    if (char const * value = std::getenv("LEAN_ACCELERATOR_MIN_ITEMS")) {
        char * end = nullptr;
        unsigned long long parsed = std::strtoull(value, &end, 10);
        if (*value && end && *end == 0 && parsed <= std::numeric_limits<size_t>::max())
            minimum = static_cast<size_t>(parsed);
    }
    return count >= minimum;
#endif
}

bool read_word(lean_object * value, unsigned kind, uint64_t & result) {
    switch (kind) {
    case 0: {
        result = lean_uint64_of_nat(value);
        if (lean_is_scalar(value)) return true;
        lean_object * exact = lean_uint64_to_nat(result);
        bool fits = lean_nat_dec_eq(value, exact);
        lean_dec(exact);
        return fits;
    }
    case 1: result = lean_unbox_uint64(value); return true;
    case 2: result = lean_unbox_uint32(value); return true;
    case 3: result = lean_unbox_usize(value); return true;
    case 4: case 5: case 6: result = lean_unbox(value); return true;
    case 7: result = 0; return true;
    default: return false;
    }
}

lean_object * box_word(uint64_t value, unsigned kind) {
    switch (kind) {
    case 0: return lean_uint64_to_nat(value);
    case 1: return lean_box_uint64(value);
    case 2: return lean_box_uint32(static_cast<uint32_t>(value));
    case 3: return lean_box_usize(value);
    default: return lean_box(value);
    }
}

struct data_type {
    char kind;
    std::string path;
    std::unique_ptr<data_type> element;
    std::unique_ptr<data_type> right;
    bool seen{false};
    size_t extent{0};

    static std::unique_ptr<data_type> parse(char const * & code, std::string path) {
        if (!*code) return nullptr;
        auto type = std::make_unique<data_type>();
        type->kind = *code++;
        type->path = std::move(path);
        if (type->kind >= '0' && type->kind <= '7') return type;
        char const * suffix;
        switch (type->kind) {
        case 'a': case 'l': suffix = "_E"; break;
        case 'p': suffix = "_L"; break;
        case 'o': suffix = "_V"; break;
        default: return nullptr;
        }
        type->element = parse(code, type->path + suffix);
        if (!type->element) return nullptr;
        if (type->kind == 'p') {
            type->right = parse(code, type->path + "_R");
            if (!type->right) return nullptr;
        }
        return type;
    }

    void define_extents(std::string & source) const {
        if (kind == 'a') source += "#define " + path + "_SIZE " + std::to_string(extent) + "u\n";
        if (element) element->define_extents(source);
        if (right) right->define_extents(source);
    }
};

// Aggregate values are offsets in the packed buffer. Offset zero denotes an
// empty list or option; arrays store their length, and list cells store head/tail.
bool pack(data_type & type, lean_object * value, std::vector<uint64_t> & words,
    uint64_t & result, uint64_t region = 0) {
    if (type.kind >= '0' && type.kind <= '7') return read_word(value, type.kind - '0', result);
    if (type.kind == 'a') {
        if (lean_is_scalar(value) || lean_obj_tag(value) != LeanArray) return false;
        size_t size = lean_array_size(value);
        if (size > UINT32_MAX || (type.seen && type.extent != size)) return false;
        type.seen = true;
        type.extent = size;
        size_t start = words.size();
        if (size >= words.max_size() - start) return false;
        words.resize(start + size + 1);
        words[start] = size;
        for (size_t i = 0; i < size; ++i) {
            uint64_t item;
            if (!pack(*type.element, lean_array_get_core(value, i), words, item, region)) return false;
            words[start + i + 1] = item;
        }
        result = start | region;
        return true;
    }
    if (type.kind == 'l') {
        result = 0;
        size_t previous = 0;
        while (!lean_is_scalar(value)) {
            if (lean_obj_tag(value) != 1 || lean_ctor_num_objs(value) != 2) return false;
            size_t cell = words.size();
            words.resize(cell + 2);
            if (previous) words[previous + 1] = cell | region;
            else result = cell | region;
            uint64_t head;
            if (!pack(*type.element, lean_ctor_get(value, 0), words, head, region)) return false;
            words[cell] = head;
            previous = cell;
            value = lean_ctor_get(value, 1);
        }
        return lean_unbox(value) == 0;
    }
    if (type.kind == 'o' && lean_is_scalar(value)) {
        result = 0;
        return lean_unbox(value) == 0;
    }
    unsigned fields = type.kind == 'p' ? 2 : 1;
    unsigned tag = type.kind == 'p' ? 0 : 1;
    if (lean_is_scalar(value) || lean_obj_tag(value) != tag || lean_ctor_num_objs(value) != fields)
        return false;
    size_t start = words.size();
    words.resize(start + fields);
    uint64_t left;
    if (!pack(*type.element, lean_ctor_get(value, 0), words, left, region)) return false;
    words[start] = left;
    if (fields == 2) {
        uint64_t right;
        if (!pack(*type.right, lean_ctor_get(value, 1), words, right, region)) return false;
        words[start + 1] = right;
    }
    result = start | region;
    return true;
}

struct uniform_data {
    unsigned captures{0};
    bool persistent{true};
    std::vector<lean_object *> values;
    std::vector<std::string> kinds;
    std::vector<uint64_t> words{0};
    std::vector<uint64_t> roots;
    std::string extents;
};

// Only persistent Lean objects have stable identities here. Captures never use
// this cache, and nonpersistent uniform values are packed again for each call.
std::shared_ptr<uniform_data const> prepare_uniforms(unsigned captures, unsigned count,
    char const * const * kinds, lean_object * const * values, bool & hit) {
    static auto empty = std::make_shared<uniform_data const>();
    if (count == 0) return empty;
    bool persistent = true;
    for (unsigned i = 0; i < count; ++i)
        persistent &= lean_is_scalar(values[i]) || lean_is_persistent(values[i]);
    static std::mutex mutex;
    static std::unordered_multimap<lean_object *, std::shared_ptr<uniform_data const>> cache;
    std::unique_lock<std::mutex> lock(mutex, std::defer_lock);
    if (persistent) {
        lock.lock();
        auto range = cache.equal_range(values[0]);
        for (auto it = range.first; it != range.second; ++it) {
            auto const & entry = it->second;
            if (entry->captures != captures || entry->values.size() != count) continue;
            bool matches = true;
            for (unsigned i = 0; i < count; ++i)
                matches &= entry->values[i] == values[i] && entry->kinds[i] == kinds[i];
            if (matches) { hit = true; return entry; }
        }
    }
    auto entry = std::make_shared<uniform_data>();
    entry->captures = captures;
    entry->persistent = persistent;
    for (unsigned i = 0; i < count; ++i) {
        char const * code = kinds[i];
        auto type = data_type::parse(code, "CAPTURE_" + std::to_string(captures + i));
        uint64_t root;
        if (!type || *code || !pack(*type, values[i], entry->words, root, table_bit)) return nullptr;
        entry->values.push_back(values[i]);
        entry->kinds.emplace_back(kinds[i]);
        entry->roots.push_back(root);
        type->define_extents(entry->extents);
    }
    if (persistent) cache.emplace(values[0], entry);
    return entry;
}

struct prepared_step {
    std::string source;
    std::vector<uint64_t> input;
    std::shared_ptr<uniform_data const> tables;
    size_t count{0};
    bool uniform_pack_hit{false};

    bool prepare(char const * shader, char const * const * kinds, unsigned captures,
        unsigned uniforms, lean_object * count_obj, lean_object * const * values,
        lean_object * const * uniform_values, size_t dependency = SIZE_MAX,
        size_t previous_count = 0, unsigned previous_kind = 0) {
        if (!lean_is_scalar(count_obj)) return false;
        count = lean_unbox(count_obj);
        if (count == 0 || count > UINT32_MAX || !native_enabled(count)) return false;
        input.resize(std::max<size_t>(1, static_cast<size_t>(captures) + uniforms));
        for (unsigned i = 0; i < captures; ++i) {
            std::string path = "CAPTURE_" + std::to_string(i);
            char const * code = kinds[i];
            auto type = data_type::parse(code, path);
            if (!type || *code) return false;
            if (i == dependency) {
                if (type->kind != 'a' || type->element->kind != static_cast<char>('0' + previous_kind)) return false;
                input[i] = uint64_t{1} << 62;
                type->extent = previous_count;
            } else {
                uint64_t root;
                if (!pack(*type, values[i], input, root)) return false;
                input[i] = root;
            }
            type->define_extents(source);
        }
        tables = prepare_uniforms(captures, uniforms, kinds + captures, uniform_values, uniform_pack_hit);
        if (!tables) return false;
        for (unsigned i = 0; i < uniforms; ++i) input[captures + i] = tables->roots[i];
        source += tables->extents;
        source += shader;
        return true;
    }

    lean_native_step dispatch() const {
        return {source.c_str(), input.data(), input.size(), tables->words.data(),
            tables->words.size(), tables->persistent ? tables.get() : nullptr, count};
    }
};

lean_object * box_output(std::vector<uint64_t> const & output, unsigned kind) {
    lean_object * result = lean_alloc_array(output.size(), output.size());
    for (size_t i = 0; i < output.size(); ++i)
        lean_array_set_core(result, i, box_word(output[i], kind));
    return result;
}
}

// Borrows all inputs. A null result asks the generated caller to run its original CPU code.
extern "C" LEAN_EXPORT uint8_t lean_accelerator_native_wanted(lean_object * count) {
    if (!lean_is_scalar(count)) return false;
    size_t n = lean_unbox(count);
    return n != 0 && n <= UINT32_MAX && native_enabled(n);
}

extern "C" LEAN_EXPORT lean_object * lean_accelerator_native_map(
    char const * source, char const * const * kinds, unsigned captures, unsigned uniforms,
    unsigned result_kind, lean_object * count_obj, lean_object * closure, lean_object * const * values) {
    if (!lean_is_scalar(count_obj) || lean_is_scalar(closure) ||
        lean_obj_tag(closure) != LeanClosure || lean_closure_num_fixed(closure) != captures)
        return nullptr;
    size_t count = lean_unbox(count_obj);
    if (count == 0 || count > UINT32_MAX || count > SIZE_MAX / sizeof(uint64_t)) return nullptr;
    if (!native_enabled(count)) return nullptr;
    auto started = std::chrono::steady_clock::now();
    std::vector<lean_object *> captured(captures);
    for (unsigned i = 0; i < captures; ++i) captured[i] = lean_closure_get(closure, i);
    prepared_step prepared;
    if (!prepared.prepare(source, kinds, captures, uniforms, count_obj, captured.data(), values)) return nullptr;
    std::vector<uint64_t> output(count);
    uint64_t device_ns = 0;
    unsigned synchronizations = 0;
    auto step = prepared.dispatch();
    bool valid = lean_native_metal_execute(&step, 1, output.data(), device_ns, synchronizations);
    lean_object * result = valid ? box_output(output, result_kind) : nullptr;
    if (char const * path = std::getenv("LEAN_ACCEL_TRACE_FILE")) {
        static std::mutex trace_mutex;
        std::lock_guard<std::mutex> lock(trace_mutex);
        if (FILE * trace = std::fopen(path, "a")) {
            auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - started).count();
            std::fprintf(trace, "{\"operation\":\"native_map\",\"backend\":\"%s\","
                "\"result_valid\":%s,\"count\":%zu,\"input_bytes\":%zu,"
                "\"uniform_bytes\":%zu,\"uniform_pack_cache_hit\":%s,\"uniform_device_cache_hit\":%s,"
                "\"device_time_ns\":%llu,\"elapsed_ns\":%lld}\n",
                valid ? "metal" : "cpu", valid ? "true" : "false", count,
                prepared.input.size() * sizeof(uint64_t), uniforms ? prepared.tables->words.size() * sizeof(uint64_t) : 0,
                prepared.uniform_pack_hit ? "true" : "false", step.table_cache_hit ? "true" : "false",
                static_cast<unsigned long long>(device_ns),
                static_cast<long long>(elapsed));
            std::fclose(trace);
        }
    }
    return result;
}

// Borrows both maps' inputs. The caller retains the original CPU chain on failure.
extern "C" LEAN_EXPORT lean_object * lean_accelerator_native_chain(
    char const * first_source, char const * const * first_kinds, unsigned first_captures,
    unsigned first_uniforms, unsigned first_kind, lean_object * first_count,
    lean_object * const * first_captured, lean_object * const * first_values,
    char const * last_source, char const * const * last_kinds, unsigned last_captures,
    unsigned last_uniforms, unsigned last_kind, lean_object * last_count,
    lean_object * const * last_values, lean_object * const * last_uniform_values, unsigned dependency) {
    if (dependency >= last_captures) return nullptr;
    auto started = std::chrono::steady_clock::now();
    prepared_step first, last;
    if (!first.prepare(first_source, first_kinds, first_captures, first_uniforms,
            first_count, first_captured, first_values) ||
        !last.prepare(last_source, last_kinds, last_captures, last_uniforms,
            last_count, last_values, last_uniform_values, dependency, first.count, first_kind)) return nullptr;
    lean_native_step steps[] = {first.dispatch(), last.dispatch()};
    std::vector<uint64_t> output(last.count);
    uint64_t device_ns = 0;
    unsigned synchronizations = 0;
    bool valid = lean_native_metal_execute(steps, 2, output.data(), device_ns, synchronizations);
    lean_object * result = valid ? box_output(output, last_kind) : nullptr;
    if (char const * path = std::getenv("LEAN_ACCEL_TRACE_FILE")) {
        static std::mutex trace_mutex;
        std::lock_guard<std::mutex> lock(trace_mutex);
        if (FILE * trace = std::fopen(path, "a")) {
            auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - started).count();
            std::fprintf(trace, "{\"operation\":\"native_chain\",\"stages\":2,\"backend\":\"%s\","
                "\"result_valid\":%s,\"count\":%zu,\"input_bytes\":%zu,"
                "\"intermediate_device_bytes\":%zu,\"host_intermediate_bytes\":0,"
                "\"synchronizations\":%u,\"device_time_ns\":%llu,\"elapsed_ns\":%lld}\n",
                valid ? "metal" : "cpu", valid ? "true" : "false", last.count,
                (first.input.size() + last.input.size()) * sizeof(uint64_t),
                (first.count + 1) * sizeof(uint64_t), synchronizations,
                static_cast<unsigned long long>(device_ns), static_cast<long long>(elapsed));
            std::fclose(trace);
        }
    }
    return result;
}
