import Batch

/-! Compare the complete native batch with its typed Lean reference, including
nonzero initial sums, zero children, changed keys, and unsupported-digit fallback.
The imported Nightstream modules require a legacy module header. -/

set_option autoImplicit false

open MetalReplay
open NightstreamFPrime.Spec
open NightstreamFPrime.Export.Stage1

private def ring (bias : Nat) := Vector.ofFn fun i : Fin ringDegree =>
  Poseidon2.ofNat (if i.val % 2 == 0 then bias + i.val else goldilocksModulus - 1 - i.val)

private def block (bias : Nat) (unsupported : Bool) : PreparedBlock :=
  (Vector.ofFn (fun row => PiDECNativeProduct.prepareKey (ring (bias + row.val))),
   Vector.ofFn (fun child => PiDECNativeProduct.prepareDigit
     (Vector.ofFn (fun i : Fin ringDegree => Poseidon2.ofNat
       (if child.val == 0 then 0
        else if unsupported && i.val == 0 then 2
        else if (i.val + child.val) % 3 == 0 then 0
        else if (i.val + child.val) % 3 == 1 then 1 else goldilocksModulus - 1)))))

private def same (a b : NativeProducts) : Bool :=
  (List.finRange Rows).all fun r => (List.finRange Children).all fun c =>
    ((a.get r).get c).finish == ((b.get r).get c).finish

def main : IO Unit := do
  let initial := batchCPU #[block 11 false] zero
  for blocks in [#[block 19 false, block 29 false], #[block 37 false],
      #[block 43 true], #[]] do
    unless same (batch blocks initial) (batchCPU blocks initial) do
      throw (IO.userError "native batch differs from Lean reference")
  IO.println "native batch equals Lean reference; fallback and empty batch passed"
