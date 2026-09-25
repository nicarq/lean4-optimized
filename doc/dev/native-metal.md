# Native integer maps on Metal

The C backend can lower eligible `Array.ofFn` mappers to Metal. The recognizer
reads the saved monomorphic LCNF declaration. It matches integer operations and
control flow, not application declaration names. The generated C retains its
original CPU call.

This is a partial native backend. It supports word arithmetic, word array
updates, typed array/list/pair/option captures, list folds, branches, join points,
and tail calls. A mapper returns one scalar per index. Nested array results,
indirect calls, and arbitrary-precision arithmetic remain on CPU. There is no
CUDA backend.

An unsupported branch requests CPU fallback if a GPU thread reaches it. The
compiler rejects a function with no supported return. The runtime also falls back when
packing fails, a device operation overflows `Nat`, an array access is out of
bounds, or Metal cannot compile or execute the shader. Fixed-width arithmetic
wraps at its Lean width. Shifts mask their count, division by zero returns zero,
and remainder by zero returns the dividend.

The accelerator controls select execution:

```sh
LEAN_ACCELERATOR=cpu ./program
LEAN_ACCELERATOR=auto ./program
LEAN_ACCELERATOR=metal LEAN_ACCELERATOR_MIN_ITEMS=1 ./program
```

Native maps use the existing `LEAN_ACCELERATOR_MIN_ITEMS` threshold. Its current
default is 65,536 mapped elements. Reducing it is useful for conformance tests;
it can make small maps much slower. The native backend runs Metal in the caller
process. It is built by default on macOS and can be disabled with
`-DUSE_METAL_ACCELERATOR=OFF`. Other platforms retain the CPU path.

Captures are copied to dense integer buffers. Aggregate fields hold offsets;
their types come from the monomorphic input layout. Read-only word arrays stay
in that buffer. An update copies the array into thread-local storage. Nested arrays must have
consistent extents at each type path. Lean objects stay on the host.
Pure, closed data factories behind erased arguments can supply uniform tables.
The compiler checks their dependencies and rejects unknown external calls,
initializers, and unsafe functions. These factories run only when the runtime
selects a device attempt. Persistent, immutable tables are packed once and reuse
their Metal buffer. Other tables are packed for each attempt. Captured inputs are
always read again, so a changed input cannot reuse an old value.
Pipelines are cached by full shader source, including array extents. Each host
thread reuses its buffers after its preceding command completes. Independent
Lean workers can have commands in flight on one Metal queue.

Set `LEAN_ACCEL_TRACE_FILE` to record `native_map` attempts. Each record contains
the selected backend, result validity, mapped count, input and uniform bytes,
uniform cache hits, GPU duration,
and attempt duration. Attempt duration includes packing, shader compilation,
dispatch, synchronization, and result boxing. It excludes a subsequent CPU
fallback. Measure the complete executable separately when comparing speed.

`tests/compile/acceleratorNativeMap.lean` checks word arithmetic, captured arrays,
loop lowering, concurrent calls, empty maps, and `Nat` fallback against ordinary
compiled CPU computations. `acceleratorNativeProduct.lean` checks product folds
over captured and closed pair tables. `acceleratorNativeBranches.lean` checks a
supported device branch and a branch that returns to CPU. GPU checks run on a
Metal-enabled Mac.

The earlier Lean 4.30 Nightstream experiment lowered the native ChaCha key mapper from
unchanged Lean source. CPU and Metal produced byte-identical saved PiDEC replay
output. Small 54-element launches were slower than CPU. A shared batching queue
was slower again and was removed. A useful larger GPU region remains open;
this change does not establish a faster Nightstream build or replay.
That experiment also lowered native PiDEC product maps from unchanged source.
The Lean 4.32.2 port needs fresh build and replay measurements. The current target
is a 2× improvement over CPU for the clean build and saved replay; it has not been
established. Small calls still need to be combined into larger device work.

## Device residency

Two dependent maps can execute as one native chain, including a first map
behind a pure helper with object parameters. The intermediate
word array stays in a private Metal buffer. The host packs external inputs,
encodes both kernels in one command buffer, waits once, and boxes only the final
result. If either stage fails, the original CPU chain produces the result.
The compiler requires that the intermediate array does not escape; it preserves
reference-count operations with an empty ownership token. This token has no
intermediate elements. Lazy initializers and external calls cannot move into
the preparation phase. The chain test checks changed inputs, empty arrays, and
whole-chain fallback after overflow.

This follows NVIDIA's [CUDA transfer guidance](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html#data-transfer-between-host-and-device)
and [CUDA Graph guidance](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/cuda-graphs.html).
For Metal, use [few command buffers](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html)
and measure the complete command. Apple silicon shares physical memory, but
Lean object packing, host allocation, and synchronization still have costs.

The repeatable map benchmark is `tests/compile_bench/acceleratorNativeChain.lean`.
After compiling it with the test harness, compare complete processes:

```sh
timeout 300 env LEAN_ACCELERATOR=cpu tests/compile_bench/acceleratorNativeChain.lean.out 65536 13680 chain
timeout 300 env LEAN_ACCELERATOR=metal tests/compile_bench/acceleratorNativeChain.lean.out 65536 13680 split
timeout 300 env LEAN_ACCELERATOR=metal tests/compile_bench/acceleratorNativeChain.lean.out 65536 13680 chain
```

Both Metal paths include initial shader compilation and output conversion. The
map size comes from the conformance test; the repeat count matches the saved
replay's block count. This is a map benchmark, not a Nightstream replay.
