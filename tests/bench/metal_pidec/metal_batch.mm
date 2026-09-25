/*
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
*/
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "metal_batch.h"
#include <cstdio>
#include <cstring>
#include <initializer_list>

namespace {
char const * source = R"metal(
#include <metal_stdlib>
using namespace metal;
constant ulong modulus = 0xffffffff00000001ul;
inline ulong add(ulong a, ulong b) { ulong gap=modulus-b; return a<gap ? a+b : a-gap; }
inline ulong sub(ulong a, ulong b) { return b<=a ? a-b : modulus-(b-a); }
inline ulong signed_add(ulong a, ulong b, char sign) { return sign>0 ? add(a,b) : sub(a,b); }
struct Shape { uint blocks, rows, children; };
kernel void products(device const ulong* keys [[buffer(0)]],
    device const char* digits [[buffer(1)]], device const uchar* active [[buffer(2)]],
    device ulong* sums [[buffer(3)]], constant Shape& shape [[buffer(4)]],
    uint index [[thread_position_in_grid]]) {
    if (index >= shape.rows*shape.children*54u) return;
    uint lane=index%54u, child=(index/54u)%shape.children, row=index/(54u*shape.children);
    uint folded=lane+(lane<27u ? 54u : 27u);
    ulong sum=sums[index];
    for(uint block=0;block<shape.blocks;++block) {
        if(!active[ulong(block)*shape.children+child]) continue;
        ulong keyBase=(ulong(block)*shape.rows+row)*54ul;
        ulong digitBase=(ulong(block)*shape.children+child)*54ul;
        for(uint j=0;j<54u;++j) {
            char digit=digits[digitBase+j];
            if(!digit) continue;
            if(j<=lane) sum=signed_add(sum,keys[keyBase+lane-j],digit);
            if(j<=folded && folded-j<54u)
                sum=signed_add(sum,keys[keyBase+folded-j],-digit);
            if(lane<26u && lane+81u-j<54u)
                sum=signed_add(sum,keys[keyBase+lane+81u-j],digit);
        }
    }
    sums[index]=sum;
}
)metal";

struct device_state {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLComputePipelineState> pipeline;
    device_state() {
        if (!device) return;
        NSError * error = nil;
        auto options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion3_0;
        auto library = [device newLibraryWithSource:[NSString stringWithUTF8String:source]
            options:options error:&error];
        auto function = [library newFunctionWithName:@"products"];
        pipeline = function ? [device newComputePipelineStateWithFunction:function error:&error] : nil;
        if (!pipeline) std::fprintf(stderr, "Metal batch: %s\n", error.localizedDescription.UTF8String);
    }
};

device_state & device() { static device_state state; return state; }

bool sizes(size_t blocks, size_t rows, size_t children, size_t & keys, size_t & digits,
    size_t & outputs) {
    if (blocks > UINT32_MAX || !rows || !children || rows > UINT32_MAX / 54 ||
        children > UINT32_MAX / (rows * 54)) return false;
    outputs = rows * children * 54 * sizeof(uint64_t);
    if (blocks > SIZE_MAX / (rows * 54 * sizeof(uint64_t)) ||
        blocks > SIZE_MAX / (children * 54)) return false;
    keys = blocks * rows * 54 * sizeof(uint64_t);
    digits = blocks * children * 54;
    return true;
}
}

bool metal_batch_fits(size_t blocks, size_t rows, size_t children) {
    @autoreleasepool {
        size_t keys, digits, outputs;
        if (!sizes(blocks, rows, children, keys, digits, outputs)) return false;
        auto & state = device();
        if (!state.pipeline || !state.queue) return false;
        auto bound = state.device.maxBufferLength;
        if (keys > bound || digits > bound || outputs > bound) return false;
        size_t budget = state.device.recommendedMaxWorkingSetSize;
        for (size_t bytes : {keys, digits, outputs, blocks*children}) {
            if (bytes > budget) return false;
            budget -= bytes;
        }
        return true;
    }
}

bool metal_batch_accumulate(uint64_t const * keys, int8_t const * digits,
    uint8_t const * active, uint64_t const * initial, uint64_t * output,
    size_t blocks, size_t rows, size_t children, metal_batch_stats & stats) {
    @autoreleasepool {
        size_t key_bytes, digit_bytes, output_bytes;
        if (!sizes(blocks, rows, children, key_bytes, digit_bytes, output_bytes)) return false;
        if (!blocks) { std::memcpy(output, initial, output_bytes); return true; }
        if (!metal_batch_fits(blocks, rows, children)) return false;
        auto & state = device();
        auto key_buffer = [state.device newBufferWithBytes:keys length:key_bytes options:MTLResourceStorageModeShared];
        auto digit_buffer = [state.device newBufferWithBytes:digits length:digit_bytes options:MTLResourceStorageModeShared];
        auto active_buffer = [state.device newBufferWithBytes:active length:blocks*children options:MTLResourceStorageModeShared];
        auto sums = [state.device newBufferWithBytes:initial length:output_bytes options:MTLResourceStorageModeShared];
        if (!key_buffer || !digit_buffer || !active_buffer || !sums) return false;
        auto command = [state.queue commandBuffer];
        command.label = @"Lean PiDEC product batch";
        auto encoder = [command computeCommandEncoder];
        if (!command || !encoder) return false;
        [encoder setComputePipelineState:state.pipeline];
        [encoder setBuffer:key_buffer offset:0 atIndex:0];
        [encoder setBuffer:digit_buffer offset:0 atIndex:1];
        [encoder setBuffer:active_buffer offset:0 atIndex:2];
        [encoder setBuffer:sums offset:0 atIndex:3];
        uint32_t shape[] = {static_cast<uint32_t>(blocks), static_cast<uint32_t>(rows),
            static_cast<uint32_t>(children)};
        [encoder setBytes:shape length:sizeof(shape) atIndex:4];
        // The first measured launch uses the pipeline's hardware SIMD width.
        [encoder dispatchThreads:MTLSizeMake(output_bytes/8,1,1)
            threadsPerThreadgroup:MTLSizeMake(state.pipeline.threadExecutionWidth,1,1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        stats.submissions = 1;
        stats.device_ns = static_cast<uint64_t>((command.GPUEndTime-command.GPUStartTime)*1e9);
        stats.input_bytes = key_bytes+digit_bytes+blocks*children+output_bytes;
        if (command.status != MTLCommandBufferStatusCompleted) return false;
        std::memcpy(output, sums.contents, output_bytes);
        return true;
    }
}
