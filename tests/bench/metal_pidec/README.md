# Metal PiDEC replay experiment

This experiment batches the saved Nightstream PiDEC products on Metal. Lean still validates the input, splits the parent and generates the keys. Each GPU thread keeps one output coefficient in a register while it processes all selected blocks. Only the final sums return to Lean. There is one submission and one CPU wait for the saved range.

This is an explicit native benchmark connection. It does not add automatic compiler offload or change the Lean compiler, the Nightstream proof library, or the production replay executable. The original experiment in PR #6 remains parked.

On an Apple M1 Max with ten CPU workers, the saved 13,680-block replay gave these complete-command times:

| Order | Stock threaded CPU | Metal |
| --- | ---: | ---: |
| CPU, then Metal | 7.334 s | 5.314 s |
| Metal, then CPU | 7.311 s | 4.025 s |
| Median | 7.322 s | 4.670 s |

The median speedup is **1.568x**, with paired gains of 1.380x and 1.816x. All 191,678 output bytes match the stock output. The first final-binary Metal run had a longer interval before replay started; it remains in the result. These are fresh processes, but the system shader cache may already be warm. The two pairs establish the first win for this saved workload, not a universal performance result or the broader 2x target.

Peak RSS increased from 326 MB on stock CPU to 1,152 MB on Metal. The prototype retains prepared keys for the selected batch. The batch must fit Metal's buffer and recommended working-set limits. It is not the bounded streaming design needed for larger production ranges.

The Metal System Trace records one command-buffer submission. Command-buffer GPU timestamps report 284.9 ms of GPU execution in the separate profile, and the native call reports 334.2 ms including packing and result construction. The input buffers total 142,205,184 bytes. Timing includes process startup, key preparation, shader/pipeline setup, packing, synchronization and output; no precomputed key file is used. Profile times are separate from the unprofiled comparisons.

`Batch.lean` defines the original typed CPU calculation and the native boundary. `BatchTest.lean` compares every coefficient with that calculation, including nonzero initial sums, changed keys, zero children, empty input and fallback for a digit outside -1/0/1. `test_batch.cpp` independently checks monomial multiplication and Phi81 reduction, canonical arithmetic near the modulus, changed inputs and size bounds. Invalid parent coefficients, strict-bound violations and duplicate input blocks were rejected by both replay executables. The reference theorem uses only the existing allowed axioms: `propext`, `Classical.choice` and `Quot.sound`. These checks validate native execution; they are not a universal proof of the Metal implementation.

The CPU batch reference is deliberately simple and sequential. It took 23.569 s on the full fixture. It verifies the native result and supplies fallback, but it must not replace the existing threaded CPU replay. Unsupported digits, packing failures or GPU execution failures use that reference. The benchmark driver itself requires a suitable Metal device.

## Reproduce

Use macOS with Metal, Xcode, Python 3 and Homebrew GNU `timeout`. First prepare an unchanged Nightstream checkout at `7f51e1010ce382d15206d4d1fabcb27d88754cfe`, with the official Lean 4.32.2 toolchain, its checked dependency artifacts, and the built `replayPiDECCommitment` target. The recorded Lean base is `f3b06c705e6c85f5314019d5d3baab0fec5b580c`.

Set `PROJECT` to that checkout's `formal/nightstream-fprime` directory, `TOOLCHAIN` to the toolchain that built it, and `OUTPUT` to a new output directory. From this directory, build the new files:

```sh
/opt/homebrew/bin/timeout --signal=KILL 1500 python3 build.py "$PROJECT" "$TOOLCHAIN" "$OUTPUT"
```

This rebuilds all files in the experiment and reuses the unchanged checked project objects. It does not spoof compiler hashes or rebuild Mathlib. Each nested command also has an outer 300-second cap. The generated `bounded-tools/timeout` keeps `validate.sh` in the outer timeout's process group.

Run the independent kernel test and the typed Lean comparison:

```sh
/opt/homebrew/bin/timeout --signal=KILL 300 "$OUTPUT/kernelTest"
/opt/homebrew/bin/timeout --signal=KILL 300 env PATH="$OUTPUT/bounded-tools:$PATH" LEAN_ACCELERATOR=metal LEAN_ACCEL_TRACE_FILE="$OUTPUT/native-tests.jsonl" bash "$PROJECT/scripts/validate.sh" lean-executable "$OUTPUT/batchTest"
```

In a new `native-tests.jsonl`, the four native calls must report `metal` values `true, true, false, false` and submission counts `1, 1, 0, 0`. Correct output alone does not establish GPU use.

Set `PARENT` to the saved 13,680-block parent input. Its SHA-256 identifier is `e785a171e8ce63aa14feeccf7439ce638ddacce0646eae426079a7f1d2bd9418`. This identifies the fixture; correctness uses byte comparisons, not this digest. Run the complete commands, with new output names on each run:

```sh
/opt/homebrew/bin/timeout --signal=KILL 300 /usr/bin/time -l env PATH="$OUTPUT/bounded-tools:$PATH" LEAN_ACCELERATOR=cpu bash "$PROJECT/scripts/validate.sh" lean-executable "$PROJECT/.lake/build/bin/replayPiDECCommitment" "$PARENT" "$OUTPUT/cpu.json" 0 13680
/opt/homebrew/bin/timeout --signal=KILL 300 /usr/bin/time -l env PATH="$OUTPUT/bounded-tools:$PATH" LEAN_ACCELERATOR=metal bash "$PROJECT/scripts/validate.sh" lean-executable "$OUTPUT/replayPiDECCommitment" "$PARENT" "$OUTPUT/metal.json" 0 13680
cmp "$OUTPUT/cpu.json" "$OUTPUT/metal.json"
```

The recorded comparison also ran Metal then CPU to check ordering effects. Keep the worker count and input identical. Run with `LEAN_ACCELERATOR=cpu` on the experimental executable to check the sequential batch reference. Do not use that slower reference as the performance baseline.

For a local Metal System Trace, use the same executable and input, with `xcrun xctrace record --template 'Metal System Trace'` inside the validation wrapper and an outer 600-second timeout. Check the submission table and compare the profiled output bytes. `LEAN_ACCEL_TRACE_FILE` records the native call, GPU timestamp duration and submission count.

The rejected indexed CPU-loop trial took 13.063 s against a 7.355 s stock run. It was removed. It is not included in this branch or the Metal result. Clean-build speed and automatic native compiler integration remain open.

The design follows [NVIDIA's transfer and device-residency guidance](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html#data-transfer-between-host-and-device) and [Apple's command-buffer guidance](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html). CUDA execution is not implemented.
