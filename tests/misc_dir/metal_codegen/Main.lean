module

/-! Oversized Metal kernels fall back without duplicating joins exponentially or poisoning later kernels. -/

@[extern "lean_metal_available"] opaque metalAvailable : IO Bool
@[extern "lean_metal_dispatch_count"] opaque metalDispatchCount : IO UInt64

@[noinline] def branchy (x : UInt64) : UInt64 :=
  let x := if x < 10 then x + 2 else x * 3
  let x := if x < 11 then x + 3 else x * 4
  let x := if x < 12 then x + 4 else x * 5
  let x := if x < 13 then x + 5 else x * 6
  let x := if x < 14 then x + 6 else x * 7
  let x := if x < 15 then x + 7 else x * 8
  let x := if x < 16 then x + 8 else x * 9
  let x := if x < 17 then x + 9 else x * 10
  let x := if x < 18 then x + 10 else x * 11
  let x := if x < 19 then x + 11 else x * 12
  let x := if x < 20 then x + 12 else x * 13
  let x := if x < 21 then x + 13 else x * 14
  let x := if x < 22 then x + 14 else x * 15
  let x := if x < 23 then x + 15 else x * 16
  let x := if x < 24 then x + 16 else x * 17
  let x := if x < 25 then x + 17 else x * 18
  let x := if x < 26 then x + 18 else x * 19
  let x := if x < 27 then x + 19 else x * 20
  x

@[noinline] def small (x : UInt64) : UInt64 :=
  if x < 100 then x + 3 else x * 7

def checkMap (f : UInt64 → UInt64) (input : Array UInt64) : IO Unit := do
  let output := input.map f
  unless output.size == input.size do throw <| IO.userError "map size changed"
  for i in [:input.size] do
    unless output[i]! == f input[i]! do throw <| IO.userError "map result changed"

public def main : IO Unit := do
  let input := (Array.range 257).map fun i => UInt64.ofNat i * 0x9e3779b97f4a7c15
  let before ← metalDispatchCount
  checkMap branchy input
  unless (← metalDispatchCount) == before do
    throw <| IO.userError "oversized kernel should use CPU fallback"
  checkMap small input
  let enabled := (← IO.getEnv "LEAN_METAL") == some "1"
  if enabled && (← metalAvailable) then
    unless (← metalDispatchCount) == before + 1 do
      throw <| IO.userError "oversized kernel prevented a later supported dispatch"
  else
    unless (← metalDispatchCount) == before do
      throw <| IO.userError "unexpected GPU dispatch"
  IO.println "Metal code generation checks passed"
