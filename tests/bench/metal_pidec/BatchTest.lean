import Batch

/-! Compare the complete native batch with its typed Lean reference, including
nonzero initial sums, zero children, changed keys, and unsupported-digit fallback.
The imported Nightstream modules require a legacy module header. -/

set_option autoImplicit false

open MetalReplay
open NightstreamFPrime.Spec
open NightstreamFPrime.Export.Stage1

private def block (bias : Nat) (unsupported : Bool) : PreparedBlock :=
  (⟨bias % Poseidon2HashChainV1Setup.messageColumns,
      Nat.mod_lt _ (by rw [Poseidon2HashChainV1Setup.messageColumns_eq]; decide)⟩,
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
  let zeroSeed : AjtaiSetupV1.Seed := ⟨List.replicate 32 0, by simp, by simp⟩
  for seed in [Poseidon2HashChainV1Setup.productionSeed, zeroSeed] do
    let indices : Array UInt64 := #[0, 1, 0x1234567800000001, 0xffffffffffffffff]
    unless keyValues seed indices Rows == keyValuesCPU seed indices Rows do
      throw (IO.userError "generated keys differ from Lean reference")
    let initial := batchCPU seed #[block 11 false] zero
    for blocks in [#[block 19 false, block 29 false], #[block 37 false],
        #[block 43 true], #[]] do
      unless same (batch seed blocks initial) (batchCPU seed blocks initial) do
        throw (IO.userError "native batch differs from Lean reference")
  IO.println "native keys and batches equal Lean reference; fallback and empty batch passed"
