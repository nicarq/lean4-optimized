module

/-! Test native Metal word operations, arrays, loops, concurrent calls, and CPU fallback. -/

@[noinline] def wordMap (bias : UInt64) (n : Nat) : Array UInt64 :=
  Array.ofFn fun i : Fin n =>
    let x := i.val.toUInt64 + bias
    if x % 3 == 0 then (x <<< 64) ^^^ (x / 0) else x * x + 17

@[noinline] def arrayMap (xs : Array UInt64) (n : Nat) : Array UInt64 :=
  Array.ofFn fun i : Fin n => xs[i.val % xs.size]! + i.val.toUInt64

@[noinline] def narrowMap (bias : UInt32) (n : Nat) : Array UInt32 :=
  Array.ofFn fun i : Fin n =>
    let x := i.val.toUInt32 + bias
    ((x <<< 32) ||| (x >>> 33)) + 4294967295

def rounds : Nat → Array UInt32 → Array UInt32
  | 0, state => state
  | n+1, state =>
    let a := state.getD 0 0 + state.getD 1 0
    let b := (state.getD 1 0 ^^^ a) <<< 7
    rounds n ((state.set! 0 a).set! 1 b)

@[noinline] def roundMap (state : Array UInt32) (n : Nat) : Array UInt64 :=
  Array.ofFn fun i : Fin n =>
    let result := rounds 10 (state.set! 0 i.val.toUInt32)
    (result.getD 0 0).toUInt64 ||| ((result.getD 1 0).toUInt64 <<< 32)

@[noinline] def natMap (bias : Nat) (n : Nat) : Array Nat :=
  Array.ofFn fun i : Fin n => bias + i.val

public def main : IO Unit := do
  let n := 65536
  let bias : UInt64 := 18446744073709551600
  let a := wordMap bias n
  let xs : Array UInt64 := #[0, 1, 18446744073709551615, 17]
  let b := arrayMap xs n
  let c := narrowMap 4294967200 n
  let state : Array UInt32 := #[17, 31]
  let d := roundMap state n
  for i in [:n] do
    let x := i.toUInt64 + bias
    let expected := if x % 3 == 0 then (x <<< 64) ^^^ (x / 0) else x * x + 17
    unless a[i]! == expected && b[i]! == xs[i % xs.size]! + i.toUInt64 do
      throw (IO.userError s!"native map mismatch at {i}")
    let y := i.toUInt32 + 4294967200
    unless c[i]! == ((y <<< 32) ||| (y >>> 33)) + 4294967295 do
      throw (IO.userError s!"native UInt32 map mismatch at {i}")
    let expected := rounds 10 (state.set! 0 i.toUInt32)
    unless d[i]! == (expected.getD 0 0).toUInt64 ||| ((expected.getD 1 0).toUInt64 <<< 32) do
      throw (IO.userError s!"native round map mismatch at {i}")
  unless (wordMap 0 0).isEmpty do throw (IO.userError "empty map mismatch")
  -- The first map overflows on the device. The second cannot be packed in one word.
  for bias in [2^64 - 1, 2^80] do
    let values := natMap bias 3
    for i in [:3] do
      unless values[i]! == bias + i do throw (IO.userError "Nat fallback mismatch")
  let workers := ((← IO.getEnv "LEAN_NUM_THREADS").bind String.toNat?).getD 1
  let mut tasks := #[]
  for worker in [:workers] do
    tasks := tasks.push (← IO.asTask do
      pure ((roundMap #[17, worker.toUInt32 + 31] n)[0]!))
  for worker in [:workers] do
    let .ok actual ← IO.wait tasks[worker]!
      | throw (IO.userError "native map task failed")
    let expected := rounds 10 #[0, worker.toUInt32 + 31]
    unless actual == (expected.getD 0 0).toUInt64 ||| ((expected.getD 1 0).toUInt64 <<< 32) do
      throw (IO.userError s!"concurrent native map mismatch at {worker}")
  IO.println "native accelerator maps passed"
