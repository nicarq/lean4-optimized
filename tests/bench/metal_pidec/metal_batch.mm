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
inline uint rol(uint value,uint amount) { return (value<<amount)|(value>>(32u-amount)); }
inline void quarter(thread uint& a,thread uint& b,thread uint& c,thread uint& d) {
    a+=b;d=rol(d^a,16u);c+=d;b=rol(b^c,12u);
    a+=b;d=rol(d^a,8u);c+=d;b=rol(b^c,7u);
}
// Same canonicalize/foldHigh/add rule as NativePoseidon2.reduceWide64.
inline ulong reduce_wide(ulong low,ulong high) {
    ulong limb=high&0xfffffffful;
    return add(low<modulus ? low : low-modulus,sub((limb<<32)-limb,high>>32));
}
kernel void keys(device ulong* output [[buffer(0)]], constant uint* seed [[buffer(1)]],
    device const ulong* block_ids [[buffer(2)]], constant Shape& shape [[buffer(3)]],
    uint index [[thread_position_in_grid]]) {
    if(index>=shape.blocks*shape.rows*54u) return;
    uint lane=index%54u,row=(index/54u)%shape.rows;
    ulong block=block_ids[index/(shape.rows*54u)];
    uint initial[16]={0x61707865u,0x3320646eu,0x79622d32u,0x6b206574u,
        seed[0],seed[1],seed[2],seed[3],seed[4],seed[5],seed[6],seed[7],
        lane,row,uint(block),uint(block>>32)};
    uint x[16];for(uint i=0;i<16u;++i) x[i]=initial[i];
    for(uint round=0;round<10u;++round) {
        quarter(x[0],x[4],x[8],x[12]);quarter(x[1],x[5],x[9],x[13]);
        quarter(x[2],x[6],x[10],x[14]);quarter(x[3],x[7],x[11],x[15]);
        quarter(x[0],x[5],x[10],x[15]);quarter(x[1],x[6],x[11],x[12]);
        quarter(x[2],x[7],x[8],x[13]);quarter(x[3],x[4],x[9],x[14]);
    }
    for(uint i=0;i<8u;++i) x[i]+=initial[i];
    ulong a=ulong(x[0])|(ulong(x[1])<<32),b=ulong(x[2])|(ulong(x[3])<<32);
    ulong c=ulong(x[4])|(ulong(x[5])<<32),d=ulong(x[6])|(ulong(x[7])<<32);
    output[index]=reduce_wide(a,reduce_wide(b,reduce_wide(c,d)));
}
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
    id<MTLComputePipelineState> key_pipeline;
    device_state() {
        if (!device) return;
        NSError * error = nil;
        auto options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion3_0;
        auto library = [device newLibraryWithSource:[NSString stringWithUTF8String:source]
            options:options error:&error];
        auto function = [library newFunctionWithName:@"products"];
        pipeline = function ? [device newComputePipelineStateWithFunction:function error:&error] : nil;
        function = [library newFunctionWithName:@"keys"];
        key_pipeline = function ? [device newComputePipelineStateWithFunction:function error:&error] : nil;
        if (!pipeline || !key_pipeline) std::fprintf(stderr, "Metal batch: %s\n", error.localizedDescription.UTF8String);
    }
};

device_state & device() { static device_state state; return state; }

bool sizes(size_t blocks, size_t rows, size_t children, size_t & keys, size_t & digits,
    size_t & outputs) {
    if (blocks > UINT32_MAX || !rows || !children || rows > UINT32_MAX / 54 ||
        children > UINT32_MAX / (rows * 54)) return false;
    outputs = rows * children * 54 * sizeof(uint64_t);
    if (blocks > UINT32_MAX / (rows * 54) ||
        blocks > SIZE_MAX / (rows * 54 * sizeof(uint64_t)) ||
        blocks > SIZE_MAX / (children * 54)) return false;
    keys = blocks * rows * 54 * sizeof(uint64_t);
    digits = blocks * children * 54;
    return true;
}

bool encode_keys(id<MTLCommandBuffer> command, id<MTLBuffer> output,
    uint32_t const * seed, uint64_t const * block_ids, size_t blocks, size_t rows) {
    auto & state = device();
    auto indices = [state.device newBufferWithBytes:block_ids length:blocks*8 options:MTLResourceStorageModeShared];
    if (!indices) return false;
    auto encoder = [command computeCommandEncoder];
    if (!encoder) return false;
    [encoder setComputePipelineState:state.key_pipeline];
    [encoder setBuffer:output offset:0 atIndex:0];
    [encoder setBytes:seed length:32 atIndex:1];
    [encoder setBuffer:indices offset:0 atIndex:2];
    uint32_t shape[]={static_cast<uint32_t>(blocks),static_cast<uint32_t>(rows),1};
    [encoder setBytes:shape length:sizeof(shape) atIndex:3];
    [encoder dispatchThreads:MTLSizeMake(blocks*rows*54,1,1)
        threadsPerThreadgroup:MTLSizeMake(state.key_pipeline.threadExecutionWidth,1,1)];
    [encoder endEncoding];
    return true;
}
}

bool metal_batch_fits(size_t blocks, size_t rows, size_t children) {
    @autoreleasepool {
        size_t keys, digits, outputs;
        if (!sizes(blocks, rows, children, keys, digits, outputs)) return false;
        auto & state = device();
        if (!state.pipeline || !state.key_pipeline || !state.queue) return false;
        auto bound = state.device.maxBufferLength;
        if (keys > bound || digits > bound || outputs > bound) return false;
        size_t budget = state.device.recommendedMaxWorkingSetSize;
        for (size_t bytes : {keys, digits, outputs, blocks*children, blocks*8, size_t{32}}) {
            if (bytes > budget) return false;
            budget -= bytes;
        }
        return true;
    }
}

bool metal_batch_key_values(uint32_t const * seed, uint64_t const * block_ids,
    size_t blocks, size_t rows, uint64_t * output) {
    @autoreleasepool {
        if (!metal_batch_fits(blocks,rows,1)) return false;
        if (!blocks) return true;
        auto & state=device();
        auto buffer=[state.device newBufferWithLength:blocks*rows*54*8 options:MTLResourceStorageModeShared];
        auto command=[state.queue commandBuffer];
        if (!buffer || !command || !encode_keys(command,buffer,seed,block_ids,blocks,rows)) return false;
        [command commit];[command waitUntilCompleted];
        if (command.status!=MTLCommandBufferStatusCompleted) return false;
        std::memcpy(output,buffer.contents,blocks*rows*54*8);
        return true;
    }
}

static bool execute(uint64_t const * keys, uint32_t const * seed,
    uint64_t const * block_ids, int8_t const * digits,
    uint8_t const * active, uint64_t const * initial, uint64_t * output,
    size_t blocks, size_t rows, size_t children, metal_batch_stats & stats) {
    @autoreleasepool {
        size_t key_bytes, digit_bytes, output_bytes;
        if (!sizes(blocks, rows, children, key_bytes, digit_bytes, output_bytes)) return false;
        if (!blocks) { std::memcpy(output, initial, output_bytes); return true; }
        if (!metal_batch_fits(blocks, rows, children)) return false;
        auto & state = device();
        auto key_buffer = keys ? [state.device newBufferWithBytes:keys length:key_bytes options:MTLResourceStorageModeShared] :
            [state.device newBufferWithLength:key_bytes options:MTLResourceStorageModePrivate | MTLResourceHazardTrackingModeTracked];
        auto digit_buffer = [state.device newBufferWithBytes:digits length:digit_bytes options:MTLResourceStorageModeShared];
        auto active_buffer = [state.device newBufferWithBytes:active length:blocks*children options:MTLResourceStorageModeShared];
        auto sums = [state.device newBufferWithBytes:initial length:output_bytes options:MTLResourceStorageModeShared];
        if (!key_buffer || !digit_buffer || !active_buffer || !sums) return false;
        auto command = [state.queue commandBuffer];
        if (!command) return false;
        command.label = keys ? @"Lean PiDEC product batch" : @"Lean PiDEC keys and products";
        if (!keys && !encode_keys(command,key_buffer,seed,block_ids,blocks,rows)) return false;
        // Tracked resources order this consumer after the key encoder. The
        // command retains both buffers until its single final CPU wait.
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
        stats.stages = keys ? 1 : 2;
        stats.private_key_bytes = keys ? 0 : key_bytes;
        stats.device_ns = static_cast<uint64_t>((command.GPUEndTime-command.GPUStartTime)*1e9);
        stats.input_bytes = (keys ? key_bytes : blocks*8+32)+digit_bytes+blocks*children+output_bytes;
        if (command.status != MTLCommandBufferStatusCompleted) return false;
        std::memcpy(output, sums.contents, output_bytes);
        return true;
    }
}

bool metal_batch_accumulate(uint64_t const * keys, int8_t const * digits,
    uint8_t const * active, uint64_t const * initial, uint64_t * output,
    size_t blocks, size_t rows, size_t children, metal_batch_stats & stats) {
    return execute(keys,nullptr,nullptr,digits,active,initial,output,blocks,rows,children,stats);
}

bool metal_batch_seeded(uint32_t const * seed, uint64_t const * block_ids,
    int8_t const * digits, uint8_t const * active, uint64_t const * initial, uint64_t * output,
    size_t blocks, size_t rows, size_t children, metal_batch_stats & stats) {
    return execute(nullptr,seed,block_ids,digits,active,initial,output,blocks,rows,children,stats);
}
