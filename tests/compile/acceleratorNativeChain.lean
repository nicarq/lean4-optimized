module

/-! Test device-resident intermediate maps, changed inputs, and whole-chain fallback. -/

@[noinline] def chainMap (bias : UInt64) (n : Nat) : Array UInt64 :=
  let intermediate := Array.ofFn fun i : Fin n => (i.val.toUInt64 + bias) * 17
  Array.ofFn fun i : Fin n => intermediate[i.val]! + intermediate[(i.val + 1) % n]!

@[noinline] def chainNat (bias : Nat) (n : Nat) : Array Nat :=
  let intermediate := Array.ofFn fun i : Fin n => bias + i.val
  Array.ofFn fun i : Fin n => intermediate[i.val]! + 1

@[noinline] private def firstHelper (key digit : Array UInt64) : Array UInt64 :=
  Array.ofFn fun i : Fin 27 => key[i.val]! + digit[i.val]!

@[noinline] private def helperChain (key digit : Array UInt64) : Array UInt64 :=
  let intermediate := firstHelper key digit
  Array.ofFn fun i : Fin 54 => intermediate[i.val % 27]! + key[i.val]!

public def main : IO Unit := do
  let n := 65536
  for bias in [7, 18446744073709551600] do
    let result := chainMap bias n
    for i in [:n] do
      let expected := (i.toUInt64 + bias) * 17 + (((i + 1) % n).toUInt64 + bias) * 17
      unless result[i]! == expected do throw (IO.userError s!"native chain mismatch at {i}")
  unless (chainMap 7 0).isEmpty do throw (IO.userError "empty chain mismatch")
  let overflow := chainNat (2^64 - 1) 2
  unless overflow == #[2^64, 2^64 + 1] do throw (IO.userError "chain fallback mismatch")
  let key := (List.range 54).toArray.map (·.toUInt64)
  let digit := key.map (· * 3)
  let result := helperChain key digit
  for i in [:54] do
    unless result[i]! == (i % 27).toUInt64 * 4 + i.toUInt64 do
      throw (IO.userError s!"helper chain mismatch at {i}")
  IO.println "native chains passed"
