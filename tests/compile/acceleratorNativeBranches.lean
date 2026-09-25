module

/-! Test supported Metal branches and fallback for unsupported computation. -/

@[noinline] def branchMap (bias : Nat) (n : Nat) : Array Nat :=
  Array.ofFn fun i : Fin n => if i.val == 0 then bias + 1 else bias ^ i.val

public def main : IO Unit := do
  unless branchMap 17 1 == #[18] do throw (IO.userError "supported branch mismatch")
  unless branchMap 17 2 == #[18, 17] do throw (IO.userError "branch fallback mismatch")
  IO.println "native branch fallback passed"
