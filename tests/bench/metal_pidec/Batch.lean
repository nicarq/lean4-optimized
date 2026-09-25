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
abbrev PreparedBlock := Fin Poseidon2HashChainV1Setup.messageColumns ×
  Vector PiDECNativeProduct.PreparedDigit Children

def zero : NativeProducts := Vector.replicate _
  (Vector.replicate _ PiDECNativeProduct.Accumulator.zero)

@[export lean_pidec_batch_cpu]
def batchCPU (seed : AjtaiSetupV1.Seed) (blocks : Array PreparedBlock)
    (initial : NativeProducts) : NativeProducts :=
  blocks.foldl (fun result block => Vector.ofFn fun row =>
    let key := PiDECNativeProduct.prepareKey
      (PiDECCommitmentBlock.keyBlock { seed := seed } row block.1)
    Vector.ofFn fun child =>
      ((result.get row).get child).addPreparedProduct key (block.2.get child)) initial

@[extern "lean_pidec_metal_batch"]
def batch (seed : AjtaiSetupV1.Seed) (blocks : Array PreparedBlock)
    (initial : NativeProducts) : NativeProducts := batchCPU seed blocks initial

theorem batch_eq_cpu (seed : AjtaiSetupV1.Seed) (blocks : Array PreparedBlock)
    (initial : NativeProducts) : batch seed blocks initial = batchCPU seed blocks initial := rfl

#print axioms batch_eq_cpu

@[export lean_pidec_keys_cpu]
def keyValuesCPU (seed : AjtaiSetupV1.Seed) (indices : Array UInt64) (rows : Nat) : Array UInt64 :=
  Array.ofFn fun index : Fin (indices.size * rows * ringDegree) =>
    UInt64.ofNat (NightstreamFPrime.Export.NativeAjtaiChaCha.wideCoefficientNat seed.bytes
      (index.val / ringDegree % rows) (indices[index.val / (rows * ringDegree)]!).toNat
      (index.val % ringDegree))

@[extern "lean_pidec_metal_keys"]
def keyValues (seed : AjtaiSetupV1.Seed) (indices : Array UInt64) (rows : Nat) : Array UInt64 :=
  keyValuesCPU seed indices rows

@[extern "lean_pidec_metal_fits"]
def fits (blocks rows children : Nat) : IO Bool := do
  return blocks == 0 && rows == 0 && children == 0

end MetalReplay
