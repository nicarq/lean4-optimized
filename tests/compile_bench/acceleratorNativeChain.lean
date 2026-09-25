module

/-! Compare repeated dependent maps on CPU, separate GPU calls, and a native GPU chain. -/

@[noinline] def chainMap (bias : UInt64) (n : Nat) : Array UInt64 :=
  let intermediate := Array.ofFn fun i : Fin n => (i.val.toUInt64 + bias) * 17
  Array.ofFn fun i : Fin n => intermediate[i.val]! + intermediate[(i.val + 1) % n]!

@[noinline] def splitFirst (bias : UInt64) (n : Nat) : Array UInt64 :=
  Array.ofFn fun i : Fin n => (i.val.toUInt64 + bias) * 17

@[noinline] def splitMap (bias : UInt64) (n : Nat) : Array UInt64 :=
  let intermediate := splitFirst bias n
  Array.ofFn fun i : Fin n => intermediate[i.val]! + intermediate[(i.val + 1) % n]!

public def main (args : List String) : IO Unit := do
  let n := (args[0]?.bind String.toNat?).getD 65536
  let repeats := (args[1]?.bind String.toNat?).getD 1
  let mut checksum : UInt64 := 0
  for round in [:repeats] do
    let values := if args[2]? == some "split" then splitMap round.toUInt64 n else chainMap round.toUInt64 n
    checksum := checksum + values[(round % n)]!
  IO.println s!"{checksum}"
