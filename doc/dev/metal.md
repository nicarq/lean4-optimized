<!-- Copyright (c) 2026 Nico Arqueros. Released under Apache 2.0. -->

# Experimental Metal array maps

This Lean 4.30 backend accelerates supported `Array UInt64` maps without
changing the input program. It is opt-in and uses the CPU for unsupported
functions, missing devices, allocation failures, and shader compilation or
execution failures.

Build with the normal release instructions. `USE_METAL` defaults to on for
Apple platforms using AppleClang or Clang, and off for other configurations
(including macOS GCC); `-DUSE_METAL=OFF` builds the CPU fallback without linking
Apple frameworks. The Metal implementation requires Clang and an Apple GPU
with 64-bit integer support.

With the rebuilt `build/release/stage1/bin` directory on `PATH`, compile and
run a program with:

```sh
lean -Dcompiler.metal=true -c program.c program.lean
leanc -O3 -o program program.c
LEAN_METAL=1 ./program
```

No new import or tactic is required. The normal compiler and runtime paths
remain the defaults. Generated C and native binaries can differ; supported
map values must be identical. The proof kernel is unchanged.

## Supported computations

The compiler recognizes direct `Array.map` calls with `UInt64` input and
output types. It registers native callbacks whose scalar code can be
translated completely, including `UInt64` captures, integer arithmetic,
bit operations, comparisons, casts, conditionals, and calls to supported
functions in the same compilation unit. Integer division and remainder by
zero and shifts by amounts greater than the word width follow Lean's rules.

Recursive calls, loops, heap operations, arbitrary `Nat` arithmetic, IO,
and functions without a supported native callback use the CPU. Interpreted
callbacks also use the CPU. Shader generation has a per-kernel work budget;
callbacks that exceed it, including branching code whose shared continuations
would expand exponentially, use the CPU without emitting a partial shader.
This does not yet accelerate arbitrary vector
folds, ring products, complete Poseidon permutations, or symbolic proofs.

The runtime caches compiled pipelines, packs input words and captures into
Metal buffers, waits for completion, and updates the output array using the
normal reference-counting operations. Shared inputs remain unchanged. No
partially computed GPU result is exposed after a failed dispatch.

## Validation and measurements

`tests/compile/metal_map.lean` checks captures, word boundaries, shifts,
zero divisors, shared inputs, unsupported callbacks, and actual GPU dispatch
when a supported device is available. Its post-test also runs the CPU
fallback.

`tests/misc_dir/metal_codegen` bounds generated source for a branch-heavy
callback, checks its CPU fallback, and verifies that a subsequent small
callback still dispatches on supported hardware. `tests/misc_dir/metal_config`
checks Metal defaults, explicit overrides, and framework flags for Apple and
non-Apple compiler combinations.

`tests/compile_bench/metal_goldilocks.lean` uses the multiplication algorithm
from Nightstream F′'s `NativePoseidon2RoundCore.lean`. It checks boundary
values against independent arbitrary-precision modular arithmetic, then
times a batch of chained seventh powers. This is a primitive experiment,
not a measurement of a Nightstream build or exporter.

Measure both a separately compiled ordinary CPU executable
(`compiler.metal=false`) and the accelerated executable. Setting
`LEAN_METAL=0` measures the fallback dispatcher, which is not the same
baseline as the ordinary compiler's inlined map loop. Include shader setup,
packing, synchronization, and output allocation in end-to-end results.

There is deliberately no automatic size threshold yet. Enabling Metal for
small or cheap maps can be slower, and no project-wide speedup is implied.

## Initial measurements

Measured on 2026-09-24 on an Apple M5 Max (40 GPU cores), using a release
build based on Lean 4.30.0 plus the three existing `nico/lean-performance`
commits through `a6f4723408`. The input contains 1,048,576 words; each word
passes through eight seventh powers in the Goldilocks field. The CPU
executable is compiled separately with `compiler.metal=false`, at `-O3`.

Three interleaved CPU/Metal trials gave these medians:

| Measurement | CPU | Metal | Ratio |
| --- | ---: | ---: | ---: |
| Warm batch, including packing, result allocation and checksum | 183.09 ms | 13.36 ms | 13.7× |
| Whole fresh process, including setup, boundary checks and warmup | 249.62 ms | 87.73 ms | 2.85× |

System caches were already warm. These are primitive benchmark results,
not cold-install numbers or a speedup for the complete Nightstream package.
Writing every result as a little-endian word and running `cmp` confirmed
that all 8,388,608 output bytes matched.

The eight focused compiler/runtime tests passed, including the existing
integer conversion and persistent closure regressions. Using the modified
Lean executable with the unchanged `formal/nightstream-fprime` package also
passed its 19,683 PiCCS dot-product comparisons. Its binding-parity emitter
matched the existing executable on all 957 bytes for component inputs
0 through 19. These last two checks exercise CPU compatibility; they do not
establish Metal acceleration of the F′ exporter or full-package parity.

Follow-up validation exercised all 3,686 default CTest cases with Metal
enabled. All passed after rerunning the FFI example with Lean 4.30's bundled
LLVM archiver (`LEAN_AR`) instead of the macOS system archiver, which does not
accept the test's response file. A separate `USE_METAL=OFF` build passed all
11 focused Metal, array, integer, persistent-closure, and FFI tests; its
runtime did not link Metal or Foundation. The 18-conditional code-generation
reproducer shrank from 67,685,524 to 29,318 generated C bytes by selecting
CPU fallback for the oversized kernel.
