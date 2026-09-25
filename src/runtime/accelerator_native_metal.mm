/*
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
*/
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "runtime/accelerator_native.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>

namespace {
struct native_device {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    std::mutex mutex;
    std::unordered_map<std::string, id<MTLComputePipelineState>> pipelines;
    std::unordered_map<void const *, id<MTLBuffer>> tables;

    id<MTLBuffer> table_buffer(void const * identity, uint64_t const * data, size_t words, bool & hit) {
        std::lock_guard<std::mutex> lock(mutex);
        auto found = tables.find(identity);
        if (found != tables.end()) { hit = true; return found->second; }
        id<MTLBuffer> result = [device newBufferWithBytes:data length:words * 8
            options:MTLResourceStorageModeShared];
        if (result) tables.emplace(identity, result);
        return result;
    }

    id<MTLComputePipelineState> pipeline(char const * source) {
        std::lock_guard<std::mutex> lock(mutex);
        auto found = pipelines.find(source);
        if (found != pipelines.end()) return found->second;
        NSError * error = nil;
        MTLCompileOptions * options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion3_0;
        id<MTLLibrary> library = [device newLibraryWithSource:
            [NSString stringWithUTF8String:source] options:options error:&error];
        id<MTLFunction> function = [library newFunctionWithName:@"lean_native"];
        id<MTLComputePipelineState> result = function ?
            [device newComputePipelineStateWithFunction:function error:&error] : nil;
        if (!result && std::getenv("LEAN_ACCEL_TRACE_FILE"))
            std::fprintf(stderr, "Lean native Metal: %s\n", error.localizedDescription.UTF8String);
        pipelines.emplace(source, result);
        return result;
    }
};

struct native_buffers {
    id<MTLBuffer> input;
    id<MTLBuffer> output;
    id<MTLBuffer> error;
    id<MTLBuffer> tables;

    static id<MTLBuffer> reserve(id<MTLDevice> device, id<MTLBuffer> current, size_t bytes) {
        if (!current || current.length < bytes)
            return [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        return current;
    }
};
}

bool lean_native_metal_map(char const * source, uint64_t const * input, size_t words,
    uint64_t const * tables, size_t table_words, void const * table_identity,
    uint64_t * output, size_t count, uint64_t & device_ns, bool & table_cache_hit) {
    @autoreleasepool {
        static native_device state;
        // A thread reuses its buffers only after its preceding command has completed.
        // Other Lean workers can keep their commands in flight on the shared queue.
        thread_local native_buffers buffers;
        if (!state.device || !state.queue || words > state.device.maxBufferLength / 8 ||
            table_words > state.device.maxBufferLength / 8 ||
            count > state.device.maxBufferLength / 8) return false;
        id<MTLComputePipelineState> pipeline = state.pipeline(source);
        if (!pipeline) return false;
        buffers.input = native_buffers::reserve(state.device, buffers.input, words * 8);
        buffers.output = native_buffers::reserve(state.device, buffers.output, count * 8);
        buffers.error = native_buffers::reserve(state.device, buffers.error, sizeof(uint32_t));
        if (!buffers.input || !buffers.output || !buffers.error) return false;
        id<MTLBuffer> table_buffer;
        if (table_identity) {
            table_buffer = state.table_buffer(table_identity, tables, table_words, table_cache_hit);
        } else {
            buffers.tables = native_buffers::reserve(state.device, buffers.tables, table_words * 8);
            if (buffers.tables) std::memcpy(buffers.tables.contents, tables, table_words * 8);
            table_buffer = buffers.tables;
        }
        if (!table_buffer) return false;
        std::memcpy(buffers.input.contents, input, words * 8);
        *static_cast<uint32_t *>(buffers.error.contents) = 0;
        id<MTLCommandBuffer> command = [state.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        if (!command || !encoder) return false;
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:buffers.input offset:0 atIndex:0];
        [encoder setBuffer:buffers.output offset:0 atIndex:1];
        [encoder setBuffer:buffers.error offset:0 atIndex:2];
        uint32_t n = static_cast<uint32_t>(count);
        [encoder setBytes:&n length:sizeof(n) atIndex:3];
        [encoder setBuffer:table_buffer offset:0 atIndex:4];
        [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(
                pipeline.maxTotalThreadsPerThreadgroup, count), 1, 1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted ||
            *static_cast<uint32_t *>(buffers.error.contents) != 0) return false;
        device_ns = static_cast<uint64_t>((command.GPUEndTime - command.GPUStartTime) * 1e9);
        std::memcpy(output, buffers.output.contents, count * 8);
        return true;
    }
}
