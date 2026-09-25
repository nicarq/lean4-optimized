# Metal PiDEC replay experiment

This experiment generates the indexed ChaCha keys and accumulates the saved Nightstream PiDEC products on Metal. Lean validates the parent input and prepares the signed digits. The native call uploads the seed, original block indices, digits and initial sums. A key kernel writes private GPU memory; the product kernel reads it and keeps each output sum in a register across the selected blocks. Only the final sums return to Lean. Both GPU stages use one command buffer and one final CPU wait.

This is an explicit native benchmark connection. It does not add automatic compiler offload or change the Lean compiler, Nightstream proof library, or production replay executable. The earlier broad compiler experiment in PR #6 remains parked.

On an Apple M1 Max with ten CPU workers, the saved 13,680-block replay gave these complete-command times:

| Order | Stock threaded CPU | Previous Metal | GPU keys + products |
| --- | ---: | ---: | ---: |
| CPU, previous, new | 7.424 s | 4.035 s | 2.070 s |
| New, previous, CPU | 7.473 s | 4.014 s | 2.071 s |
| Median | 7.449 s | 4.024 s | 2.071 s |

The current pipeline is **3.597x faster than stock CPU** and **1.944x faster than the prior Metal version** at commit `e3ebab8e6273c26d79fad302aabbd4ab391733ea`. All 191,678 output bytes match the stock result. These are fresh processes and include startup, input handling, shader/pipeline setup, packing, GPU execution, synchronization and writing. The system shader cache may already be warm. The first validation run of the new binary took 3.327 s, including a longer interval before replay started; it is retained separately in `results.json`. The 2x target is met for this saved workload, not established for arbitrary Lean programs or other hardware.

Peak process RSS fell from 1,152 MB in the prior Metal version to 473 MB, a 59% reduction. Stock CPU peak RSS was 326 MB. The generated 130,014,720-byte key matrix remains in private GPU memory and is not read back by the replay. Host input buffers shrink from 142,205,184 to 12,299,936 bytes. The selected batch must fit the device buffer and recommended working-set limits and the shader's 32-bit grid index. Larger streaming ranges remain future work.

A CPU profile of the prior Metal version attributed 50.29% of sampled CPU time to ChaCha key generation and 36.17% to splitting and digit preparation. These are sample shares across CPU workers, not wall-time fractions. The measured preparation phase fell from about 2.93 s to 1.15 s. Splitting remains on CPU.

A separate Metal System Trace confirms one command-buffer submission and byte-identical output. Command-buffer timestamps report 293.4 ms for the combined GPU work, and the native call reports 311.6 ms including packing and output construction. The code encodes two compute stages; the trace's submission table reports the driver-level command, not a per-kernel timing breakdown.

`Batch.lean` defines the typed CPU calculation and native boundary. `BatchTest.lean` compares generated keys with Lean's native ChaCha implementation for production and zero seeds, noncontiguous indices, 64-bit nonce values and all rows/lanes. It also checks complete products, nonzero initial sums, zero children, empty input and fallback for unsupported digits. `test_keys.cpp` uses an independent ChaCha implementation and 128-bit Horner reduction; its zero, maximum and mixed seeds test carry behavior and both halves of block indices. `test_batch.cpp` independently checks polynomial products, canonical arithmetic and bounds. Invalid parent coefficients, strict-bound violations and duplicate blocks remain rejected. The reference theorem uses only `propext`, `Classical.choice` and `Quot.sound`. Differential checks do not constitute a universal proof of the Metal implementation.

The CPU batch reference remains sequential. Its complete saved replay took 31.362 s and also matched every output byte. It is a correctness/fallback path, not a replacement for the stock threaded CPU replay. Unsupported digits, packing failures or GPU execution failures use that reference. The benchmark driver itself requires a suitable Metal device. An efficient production fallback remains part of later integration work.

## Reproduce

Use macOS with Metal, Xcode, Python 3 and Homebrew GNU `timeout`. First prepare an unchanged Nightstream checkout at `7f51e1010ce382d15206d4d1fabcb27d88754cfe`, with the official Lean 4.32.2 toolchain, its checked dependency artifacts, and the built `replayPiDECCommitment` target. The recorded Lean base is `f3b06c705e6c85f5314019d5d3baab0fec5b580c`.

Set `PROJECT` to that checkout's `formal/nightstream-fprime` directory, `TOOLCHAIN` to the toolchain that built it, and `OUTPUT` to a new output directory. From this directory, build the new files:

```sh
/opt/homebrew/bin/timeout --signal=KILL 1500 python3 build.py "$PROJECT" "$TOOLCHAIN" "$OUTPUT"
```

This rebuilds all files in the experiment and reuses the unchanged checked project objects. It does not spoof compiler hashes or rebuild Mathlib. Each nested command also has an outer 300-second cap. The generated `bounded-tools/timeout` keeps `validate.sh` in the outer timeout's process group.

Run the independent product and key tests, then the typed Lean comparison:

```sh
/opt/homebrew/bin/timeout --signal=KILL 300 "$OUTPUT/kernelTest"
/opt/homebrew/bin/timeout --signal=KILL 300 "$OUTPUT/keyTest"
/opt/homebrew/bin/timeout --signal=KILL 300 env PATH="$OUTPUT/bounded-tools:$PATH" LEAN_ACCELERATOR=metal LEAN_ACCEL_TRACE_FILE="$OUTPUT/native-tests.jsonl" bash "$PROJECT/scripts/validate.sh" lean-executable "$OUTPUT/batchTest"
```

In a new `native-tests.jsonl`, the eight batch calls must report `metal` values `true, true, false, false` twice, once per seed. Successful batches report two stages, one submission, private key bytes and zero host key bytes. The separate key-comparison entry point reads keys back only for tests; production replay never uses it. Correct output alone does not establish GPU use.

Set `PARENT` to the saved 13,680-block parent input. Its SHA-256 identifier is `e785a171e8ce63aa14feeccf7439ce638ddacce0646eae426079a7f1d2bd9418`. This identifies the fixture; correctness uses byte comparisons, not this digest. Run the complete commands, with new output names on each run:

```sh
/opt/homebrew/bin/timeout --signal=KILL 300 /usr/bin/time -l env PATH="$OUTPUT/bounded-tools:$PATH" LEAN_ACCELERATOR=cpu bash "$PROJECT/scripts/validate.sh" lean-executable "$PROJECT/.lake/build/bin/replayPiDECCommitment" "$PARENT" "$OUTPUT/cpu.json" 0 13680
/opt/homebrew/bin/timeout --signal=KILL 300 /usr/bin/time -l env PATH="$OUTPUT/bounded-tools:$PATH" LEAN_ACCELERATOR=metal bash "$PROJECT/scripts/validate.sh" lean-executable "$OUTPUT/replayPiDECCommitment" "$PARENT" "$OUTPUT/metal.json" 0 13680
cmp "$OUTPUT/cpu.json" "$OUTPUT/metal.json"
```

The recorded comparison also ran Metal then CPU to check ordering effects. Keep the worker count and input identical. Run with `LEAN_ACCELERATOR=cpu` on the experimental executable to check the sequential batch reference. Do not use that slower reference as the performance baseline.

For a local Metal System Trace, use the same executable and input, with `xcrun xctrace record --template 'Metal System Trace'` inside the validation wrapper and an outer 600-second timeout. Check the submission table and compare the profiled output bytes. `LEAN_ACCEL_TRACE_FILE` records the native call, GPU timestamp duration and submission count.

The rejected indexed CPU-loop trial took 13.063 s against a 7.355 s stock run. It was removed. It is not included in this branch or the Metal result. Clean-build speed and automatic native compiler integration remain open.

The design follows [NVIDIA's transfer and device-residency guidance](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html#data-transfer-between-host-and-device) and [Apple's command-buffer guidance](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html). Explicit [tracked resources](https://developer.apple.com/documentation/metal/mtlhazardtrackingmode) order the key producer and product consumer. CUDA execution is not implemented.
