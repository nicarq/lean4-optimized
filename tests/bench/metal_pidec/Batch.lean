import NightstreamFPrime.Export.Stage1.PiDECCommitmentBlock
import NightstreamFPrime.Export.Stage1.Poseidon2HashChainV1Setup

/-! Typed reference calculation and the experimental native batch boundary.
The external implementation must return exactly `batchCPU`; it adds no proof
axiom. Nightstream uses legacy modules, which require this legacy header. -/

set_option autoImplicit false

namespace MetalReplay
open NightstreamFPrime.Spec
open NightstreamFPrime.Export.Stage1

abbrev Rows := Poseidon2HashChainV1Setup.verifierRows
abbrev Children := productionGlobalParams.k
abbrev NativeProducts := Vector (Vector PiDECNativeProduct.Accumulator Children) Rows
abbrev PreparedBlock := Vector PiDECNativeProduct.PreparedKey Rows ×
  Vector PiDECNativeProduct.PreparedDigit Children

def zero : NativeProducts := Vector.replicate _
  (Vector.replicate _ PiDECNativeProduct.Accumulator.zero)

@[export lean_pidec_batch_cpu]
def batchCPU (blocks : Array PreparedBlock) (initial : NativeProducts) : NativeProducts :=
  blocks.foldl (fun result block => Vector.ofFn fun row => Vector.ofFn fun child =>
    ((result.get row).get child).addPreparedProduct (block.1.get row) (block.2.get child)) initial

@[extern "lean_pidec_metal_batch"]
def batch (blocks : Array PreparedBlock) (initial : NativeProducts) : NativeProducts :=
  batchCPU blocks initial

theorem batch_eq_cpu (blocks : Array PreparedBlock) (initial : NativeProducts) :
    batch blocks initial = batchCPU blocks initial := rfl

#print axioms batch_eq_cpu

@[extern "lean_pidec_metal_fits"]
def fits (blocks rows children : Nat) : IO Bool := do
  return blocks == 0 && rows == 0 && children == 0

end MetalReplay
