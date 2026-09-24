module

/-!
Metal/CPU parity and timing for Nightstream F′ Goldilocks multiplication.
The word algorithm follows `Export/NativePoseidon2RoundCore.lean` in
nightstream-clean-up at 5d2d2a45b. An independent Nat modulus oracle checks
word boundaries. This is a primitive benchmark, not an end-to-end F′ build.
-/

private def modulus : UInt64 := 0xffffffff00000001

@[extern "lean_metal_available"] opaque metalAvailable : IO Bool
@[extern "lean_metal_dispatch_count"] opaque metalDispatchCount : IO UInt64

@[inline] private def add (a b : UInt64) : UInt64 :=
  if a < modulus - b then a + b else a - (modulus - b)

@[inline] private def sub (a b : UInt64) : UInt64 :=
  if b ≤ a then a - b else modulus - (b - a)

@[inline] private def lo (a : UInt64) : UInt64 := a.toUInt32.toUInt64
@[inline] private def hi (a : UInt64) : UInt64 := a >>> 32

@[noinline] def goldilocksMul (a b : UInt64) : UInt64 :=
  let p00 := lo a * lo b
  let t0 := hi a * lo b + hi p00
  let t1 := lo a * hi b + lo t0
  let low := (lo t1 <<< 32) + lo p00
  let high := hi a * hi b + hi t0 + hi t1
  let low := if low < modulus then low else low - modulus
  add low (sub ((lo high <<< 32) - lo high) (hi high))

@[noinline] def sbox (x : UInt64) : UInt64 :=
  let x2 := goldilocksMul x x
  let x4 := goldilocksMul x2 x2
  goldilocksMul (goldilocksMul x4 x2) x

@[noinline] def roundChain (x : UInt64) : UInt64 :=
  sbox (sbox (sbox (sbox (sbox (sbox (sbox (sbox x)))))))

public def main (args : List String) : IO Unit := do
  let boundary : Array UInt64 := #[0, 1, 7, 0xffffffff, 0x100000000,
    0x7fffffffffffffff, 0x8000000000000000, 0xfffffffeffffffff,
    0xffffffff00000000, 0xffffffffffffffff]
  for a in boundary do
    let actual := boundary.map (goldilocksMul a)
    for i in [:boundary.size] do
      let expected := (a.toNat * boundary[i]!.toNat) % modulus.toNat
      unless actual[i]!.toNat == expected do
        throw <| IO.userError s!"Goldilocks mismatch: {a}, {boundary[i]!}"
  let bench := (← IO.getEnv "TEST_BENCH") == some "1"
  let count := args.head?.bind String.toNat? |>.getD (if bench then 1048576 else 4096)
  let input := (Array.range count).map fun i => UInt64.ofNat i * 0x9e3779b97f4a7c15
  let warm := (input.extract 0 (min count 256)).map roundChain
  unless warm.size == min count 256 do throw <| IO.userError "warmup size mismatch"
  let before ← metalDispatchCount
  let started ← IO.monoNanosNow
  let output := input.map roundChain
  let checksum := output.foldl (init := 0) (· ^^^ ·)
  let elapsed := (← IO.monoNanosNow) - started
  let dispatched := (← metalDispatchCount) - before
  if count > 0 && (← IO.getEnv "LEAN_METAL") == some "1" && (← metalAvailable) then
    unless dispatched > 0 do throw <| IO.userError "timed map did not use Metal"
  IO.println s!"measurement: metal_goldilocks_ns {elapsed} ns"
  IO.println s!"words={count} checksum={checksum}"
  if let some path := args[1]? then
    let mut bytes := ByteArray.emptyWithCapacity (output.size * 8)
    for word in output do
      for byte in [:8] do
        bytes := bytes.push (word >>> (UInt64.ofNat byte * 8)).toUInt8
    IO.FS.writeBinFile ⟨path⟩ bytes
