#include "metal_batch.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace {
uint32_t rotate(uint32_t x, unsigned n) { return (x << n) | (x >> (32-n)); }
uint64_t coefficient(uint32_t const * seed, uint32_t row, uint64_t block, uint32_t lane) {
    uint32_t initial[] = {0x61707865,0x3320646e,0x79622d32,0x6b206574,
        seed[0],seed[1],seed[2],seed[3],seed[4],seed[5],seed[6],seed[7],
        lane,row,static_cast<uint32_t>(block),static_cast<uint32_t>(block >> 32)};
    std::array<uint32_t,16> x;
    for (unsigned i=0;i<16;++i) x[i]=initial[i];
    auto quarter = [&](unsigned a, unsigned b, unsigned c, unsigned d) {
        x[a]+=x[b];x[d]=rotate(x[d]^x[a],16);
        x[c]+=x[d];x[b]=rotate(x[b]^x[c],12);
        x[a]+=x[b];x[d]=rotate(x[d]^x[a],8);
        x[c]+=x[d];x[b]=rotate(x[b]^x[c],7);
    };
    for (unsigned round=0;round<10;++round) {
        quarter(0,4,8,12);quarter(1,5,9,13);quarter(2,6,10,14);quarter(3,7,11,15);
        quarter(0,5,10,15);quarter(1,6,11,12);quarter(2,7,8,13);quarter(3,4,9,14);
    }
    // Independent 128-bit Horner reduction, not the GPU's wide-word reduction.
    uint64_t value=0;
    for (int i=7;i>=0;--i)
        value=((static_cast<__uint128_t>(value)<<32)+static_cast<uint32_t>(x[i]+initial[i])) % 0xffffffff00000001ULL;
    return value;
}
}

int main() {
    std::array<uint64_t,4> blocks = {0,1,0x1234567800000001ULL,UINT64_MAX};
    std::array<std::array<uint32_t,8>,3> seeds = {{
        {0,0,0,0,0,0,0,0},
        {UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT32_MAX},
        {0,1,0x80000000,0x12345678,0xabcdef01,UINT32_MAX,7,13}}};
    size_t const rows=22, lanes=54;
    std::vector<uint64_t> output(blocks.size()*rows*lanes);
    for (auto const & seed : seeds) {
        if (!metal_batch_key_values(seed.data(),blocks.data(),blocks.size(),rows,output.data())) {
            std::fprintf(stderr,"Metal key generation did not execute\n");return 1;
        }
        for (size_t b=0;b<blocks.size();++b) for (size_t row=0;row<rows;++row)
            for (size_t lane=0;lane<lanes;++lane)
                if (output[(b*rows+row)*lanes+lane] != coefficient(seed.data(),row,blocks[b],lane)) {
                    std::fprintf(stderr,"Key mismatch: block=%zu row=%zu lane=%zu\n",b,row,lane);return 1;
                }
    }
    std::puts("Metal keys: seed, nonce, lane and wide-reduction checks passed");
}
