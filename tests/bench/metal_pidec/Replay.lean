import Batch
import NightstreamFPrime.Export.Codec
import NightstreamFPrime.Export.Stage1.PiDECCommitmentFold
import NightstreamFPrime.Export.Stage1.Poseidon2HashChainV1Setup
import NightstreamFPrime.Spec.Phi81Relation.PiDECAlgebra.StoredSplit

/-!
The Nightstream imports use the legacy module system, so this driver must also.
Experimental saved PiDEC replay with one native product batch. Input validation,
key preparation and output encoding follow PiDECCommitmentReplayMain.lean at
Nightstream commit 7f51e1010ce382d15206d4d1fabcb27d88754cfe. The imported Lean
definitions remain the arithmetic authority. This is a benchmark driver, not
automatic compiler recognition or a replacement production proof module.
-/

set_option autoImplicit false

namespace MetalReplay

open NightstreamFPrime.Spec
open NightstreamFPrime.Spec.Phi81Relation.PiDECAlgebra
open NightstreamFPrime.Spec.Folding.Nifs.StoredAssignmentArithmetic (StoredAssignment)
open NightstreamFPrime.Export.Codec
open NightstreamFPrime.Export.Stage1

def checked {Alpha : Type} (value : Except String Alpha) : IO Alpha :=
  match value with
  | .ok result => pure result
  | .error error => throw (IO.userError error)

def decodeBlock (line : String) : Except String (Nat × StoredAssignment ringDegree) := do
  let fields ← (← Lean.Json.parse line).getArr?
  match fields.toList with
  | [block, values] =>
      let block ← block.getNat?
      let words ← values.getArr?
      let mut values : Array F := #[]
      for word in words do
        let value ← word.getNat?
        unless value < goldilocksModulus do throw "noncanonical parent coefficient"
        values := values.push (Radix.fieldOfNat value)
      if size : values.size = ringDegree then return (block, ⟨values, size⟩)
      else throw "expected 54 parent coefficients"
  | _ => throw "expected parent block and coefficient array"

def prepareBlock (block : Nat) (parent : StoredAssignment ringDegree) : IO PreparedBlock := do
  let some children := StoredSplit.splitChecked parent
    | throw (IO.userError s!"parent exceeds the strict B bound at block {block}")
  if live : block < Poseidon2HashChainV1Setup.messageColumns then
    return (Vector.ofFn (fun row => PiDECNativeProduct.prepareKey
      (PiDECCommitmentBlock.keyBlock Poseidon2HashChainV1Setup.productionSetup row ⟨block, live⟩)),
      children.map PiDECNativeProduct.prepareDigit)
  else throw (IO.userError "block is outside the selected fixed key")

def collect (initial : Array PreparedBlock)
    (tasks : Array (Task (Except IO.Error PreparedBlock))) : IO (Array PreparedBlock) := do
  let mut result := initial
  for task in tasks do
    match ← IO.wait task with
    | .ok value => result := result.push value
    | .error error => throw error
  return result

def writeResult (path : System.FilePath) (blocks start finish : Nat)
    (products : NativeProducts) : IO Unit := do
  let accumulated := products.map (fun row => row.map PiDECNativeProduct.Accumulator.finish)
  let value := Value.array [.atom 1, .atom blocks, .atom start, .atom finish,
    .array (List.ofFn fun row : Fin Rows =>
      .array (List.ofFn fun child : Fin Children =>
        .array (List.ofFn fun lane : Fin ringDegree =>
          .atom (((accumulated.get row).get child).get lane).val)))]
  IO.FS.writeFile path (value.render ++ "\n")

def replay (parentPath outputPath : System.FilePath) (start finish : Nat) : IO UInt32 := do
  unless !(← outputPath.pathExists) do throw (IO.userError "output already exists")
  let started ← IO.monoMsNow
  let input ← IO.FS.Handle.mk parentPath .read
  let headerLine ← input.getLine
  let header ← checked do
    (← (← Lean.Json.parse headerLine).getArr?).toList.mapM Lean.Json.getNat?
  let (blocks, parentStart, parentEnd) ← match header with
    | [1, blocks, first, last] => pure (blocks, first, last)
    | _ => throw (IO.userError "expected a Lean PiRLC range header")
  unless blocks = Poseidon2HashChainV1Setup.messageColumns &&
      parentStart ≤ start && start < finish && finish ≤ parentEnd && parentEnd ≤ blocks do
    throw (IO.userError "replay range is outside the selected parent range")
  -- Bound this initial experiment by the actual device buffer/working-set limits.
  unless ← fits (finish - start) Rows Children do
    throw (IO.userError "selected batch does not fit the Metal device")
  let workers := max 1 (((← IO.getEnv "LEAN_NUM_THREADS").bind String.toNat?).getD 1)
  let mut next := parentStart
  let mut complete := false
  let mut pending := #[]
  let mut prepared := #[]
  while !complete do
    let line ← input.getLine
    if line.isEmpty then throw (IO.userError "missing parent terminator")
    if line.trimAscii.toString == "[]" then complete := true
    else
      let (block, values) ← checked (decodeBlock line)
      unless next ≤ block && block < parentEnd do
        throw (IO.userError "duplicate or out-of-range parent block")
      next := block + 1
      if start ≤ block && block < finish then
        pending := pending.push (← IO.asTask (prepareBlock block values))
        if pending.size ≥ workers then
          prepared ← collect prepared pending
          pending := #[]
  unless (← input.getLine).isEmpty do throw (IO.userError "extra data after parent terminator")
  prepared ← collect prepared pending
  let count := prepared.size
  let preparedAt ← IO.monoMsNow
  let products := batch prepared zero
  writeResult outputPath blocks start finish products
  let finished ← IO.monoMsNow
  IO.println s!"pidec_Lean_commitment_range=passed start={start} end={finish} computed_blocks={count} workers={workers} prepare_ms={preparedAt-started} compute_read_write_ms={finished-started}"
  return 0

end MetalReplay

def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [parentPath, outputPath, start, finish] =>
      match start.toNat?, finish.toNat? with
      | some start, some finish => MetalReplay.replay parentPath outputPath start finish
      | _, _ => throw (IO.userError "range endpoints must be natural numbers")
  | _ =>
      IO.eprintln "usage: replay <Lean-parent-range> <new-output> <start-block> <end-block>"
      return 2
