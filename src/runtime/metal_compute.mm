/*
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Nico Arqueros
*/
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <cstring>
#include <limits>
#include <mutex>
#include <unordered_map>
#include "runtime/metal.h"

namespace lean {
struct metal_device {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    std::mutex mutex;
    std::unordered_map<std::string, id<MTLComputePipelineState>> pipelines;
};

static metal_device & device_state() {
    static metal_device state;
    return state;
}

bool metal_available() {
    @autoreleasepool {
        auto & s = device_state();
        return s.device != nil && s.queue != nil && [s.device supportsFamily:MTLGPUFamilyApple3];
    }
}

bool metal_map_u64(std::string const & source, std::vector<uint64_t> const & input,
                   std::vector<uint64_t> const & captures, std::vector<uint64_t> & output) {
    @autoreleasepool {
        @try {
            auto & s = device_state();
            if (!metal_available() || input.empty()) return false;
            if (input.size() > std::numeric_limits<uint32_t>::max() ||
                input.size() > s.device.maxBufferLength / sizeof(uint64_t)) return false;
            id<MTLComputePipelineState> pipeline;
            {
                std::lock_guard<std::mutex> lock(s.mutex);
                auto it = s.pipelines.find(source);
                if (it == s.pipelines.end()) {
                    NSError * error = nil;
                    NSString * text = [[NSString alloc] initWithBytes:source.data()
                        length:source.size() encoding:NSUTF8StringEncoding];
                    id<MTLLibrary> library = [s.device newLibraryWithSource:text options:nil error:&error];
                    id<MTLFunction> function = [library newFunctionWithName:@"lean_map"];
                    pipeline = function ? [s.device newComputePipelineStateWithFunction:function error:&error] : nil;
                    s.pipelines.emplace(source, pipeline);
                } else {
                    pipeline = it->second;
                }
            }
            if (!pipeline) return false;
            size_t bytes = input.size() * sizeof(uint64_t);
            id<MTLBuffer> inBuffer = [s.device newBufferWithBytes:input.data() length:bytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> outBuffer = [s.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            uint64_t zero = 0;
            id<MTLBuffer> captureBuffer = [s.device newBufferWithBytes:captures.empty() ? &zero : captures.data()
                length:std::max(size_t(1), captures.size()) * sizeof(uint64_t) options:MTLResourceStorageModeShared];
            if (!inBuffer || !outBuffer || !captureBuffer) return false;
            id<MTLCommandBuffer> command = [s.queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            if (!command || !encoder) return false;
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:inBuffer offset:0 atIndex:0];
            [encoder setBuffer:outBuffer offset:0 atIndex:1];
            [encoder setBuffer:captureBuffer offset:0 atIndex:2];
            uint64_t count = input.size();
            [encoder setBytes:&count length:sizeof(count) atIndex:3];
            NSUInteger width = std::min(pipeline.maxTotalThreadsPerThreadgroup, input.size());
            [encoder dispatchThreads:MTLSizeMake(input.size(), 1, 1) threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
            [encoder endEncoding];
            [command commit];
            [command waitUntilCompleted];
            if (command.status != MTLCommandBufferStatusCompleted || command.error) return false;
            output.resize(input.size());
            std::memcpy(output.data(), outBuffer.contents, bytes);
            return true;
        } @catch (NSException *) {
            return false;
        }
    }
}
}
