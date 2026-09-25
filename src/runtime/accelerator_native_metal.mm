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
#include <vector>

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

    static id<MTLBuffer> reserve(id<MTLDevice> device, id<MTLBuffer> current, size_t bytes,
        bool intermediate = false) {
        auto mode = intermediate ? MTLStorageModePrivate : MTLStorageModeShared;
        if (!current || current.length < bytes || current.storageMode != mode)
            return [device newBufferWithLength:bytes options:intermediate ?
                MTLResourceStorageModePrivate : MTLResourceStorageModeShared];
        return current;
    }
};
}

bool lean_native_metal_execute(lean_native_step * steps, size_t stages,
    uint64_t * output, uint64_t & device_ns, unsigned & synchronizations) {
    @autoreleasepool {
        static native_device state;
        // A thread reuses its buffers only after its preceding command has completed.
        // Other Lean workers can keep their commands in flight on the shared queue.
        thread_local std::vector<native_buffers> buffers;
        if (!state.device || !state.queue || stages == 0) return false;
        if (buffers.size() < stages) buffers.resize(stages);
        buffers[0].error = native_buffers::reserve(state.device, buffers[0].error, sizeof(uint32_t));
        if (!buffers[0].error) return false;
        *static_cast<uint32_t *>(buffers[0].error.contents) = 0;
        id<MTLCommandBuffer> command = [state.queue commandBuffer];
        if (!command) return false;
        command.label = stages == 1 ? @"Lean native map" : @"Lean native chain";
        for (size_t i = 0; i < stages; ++i) {
            auto & step = steps[i];
            auto & b = buffers[i];
            if (step.words > state.device.maxBufferLength / 8 ||
                step.table_words > state.device.maxBufferLength / 8 ||
                step.count >= state.device.maxBufferLength / 8) return false;
            id<MTLComputePipelineState> pipeline = state.pipeline(step.source);
            if (!pipeline) return false;
            b.input = native_buffers::reserve(state.device, b.input, step.words * 8);
            b.output = native_buffers::reserve(state.device, b.output, (step.count + 1) * 8, i + 1 < stages);
            if (!b.input || !b.output) return false;
            id<MTLBuffer> table_buffer;
            if (step.table_identity) {
                table_buffer = state.table_buffer(step.table_identity, step.tables,
                    step.table_words, step.table_cache_hit);
            } else {
                b.tables = native_buffers::reserve(state.device, b.tables, step.table_words * 8);
                if (b.tables) std::memcpy(b.tables.contents, step.tables, step.table_words * 8);
                table_buffer = b.tables;
            }
            if (!table_buffer) return false;
            std::memcpy(b.input.contents, step.input, step.words * 8);
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            if (!encoder) return false;
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:b.input offset:0 atIndex:0];
            [encoder setBuffer:b.output offset:0 atIndex:1];
            [encoder setBuffer:buffers[0].error offset:0 atIndex:2];
            uint32_t n = static_cast<uint32_t>(step.count);
            [encoder setBytes:&n length:sizeof(n) atIndex:3];
            [encoder setBuffer:table_buffer offset:0 atIndex:4];
            [encoder setBuffer:(i ? buffers[i - 1].output : b.input) offset:0 atIndex:5];
            [encoder dispatchThreads:MTLSizeMake(step.count, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(
                    pipeline.maxTotalThreadsPerThreadgroup, step.count), 1, 1)];
            // Default resource tracking orders dependent encoders in this command.
            [encoder endEncoding];
        }
        [command commit];
        [command waitUntilCompleted];
        synchronizations = 1;
        device_ns = static_cast<uint64_t>((command.GPUEndTime - command.GPUStartTime) * 1e9);
        if (command.status != MTLCommandBufferStatusCompleted ||
            *static_cast<uint32_t *>(buffers[0].error.contents) != 0) return false;
        std::memcpy(output, static_cast<uint64_t *>(buffers[stages - 1].output.contents) + 1,
            steps[stages - 1].count * 8);
        return true;
    }
}
