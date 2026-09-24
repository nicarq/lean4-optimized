module

/-! Metal array maps preserve word arithmetic, captures, aliases and CPU fallback. -/

set_option compiler.metal true

@[extern "lean_metal_available"] opaque metalAvailable : IO Bool
@[extern "lean_metal_dispatch_count"] opaque metalDispatchCount : IO UInt64

@[noinline] def wordKernel (salt x : UInt64) : UInt64 :=
  let x := x + salt
  let x := (x ^^^ (x >>> 32)) * 0xffffffff00000001
  if x < salt then (x <<< salt) / (salt - salt)
  else ((x >>> salt) % (salt - salt)) + (x.toUInt32.toUInt64)

@[noinline] def unsupportedKernel (x : UInt64) : UInt64 :=
  UInt64.ofNat (x.toNat + 3)

@[noinline] def narrowKernel (x : UInt64) : UInt64 :=
  let a := x.toUInt16
  let b := x.toUInt32
  let c := x.toUInt8
  ((a * a + a).toUInt64 ^^^ ((b <<< b) + b).toUInt64) + (c * c).toUInt64

def checkMap (f : UInt64 → UInt64) (input : Array UInt64) (requireGPU := false) : IO Unit := do
  let before ← metalDispatchCount
  let actual := input.map f
  unless actual.size == input.size do throw <| IO.userError "map size changed"
  for i in [:input.size] do
    unless actual[i]! == f input[i]! do
      throw <| IO.userError s!"map mismatch at {i}"
  if requireGPU && !input.isEmpty && (← IO.getEnv "LEAN_METAL") == some "1" && (← metalAvailable) then
    unless (← metalDispatchCount) > before do
      throw <| IO.userError "supported callback did not run on the GPU"

public def main : IO Unit := do
  let before ← metalDispatchCount
  for size in [0, 1, 31, 32, 33, 255, 256, 257, 4097] do
    let input := (Array.range size).map fun i =>
      UInt64.ofNat i * 0x9e3779b97f4a7c15
    for salt in [0, 1, 32, 63, 64, 65, 0xffffffffffffffff] do
      checkMap (wordKernel salt) input true
    checkMap narrowKernel input true
    checkMap unsupportedKernel input
    let alias := input
    let mapped := input.map (wordKernel 7)
    unless mapped.size == alias.size do throw <| IO.userError "alias size changed"
    for i in [:alias.size] do
      unless alias[i]! == UInt64.ofNat i * 0x9e3779b97f4a7c15 do
        throw <| IO.userError "shared input was mutated"
  let enabled := (← IO.getEnv "LEAN_METAL") == some "1"
  if enabled && (← metalAvailable) then
    unless (← metalDispatchCount) > before do
      throw <| IO.userError "Metal was available but no kernel ran"
  IO.println "Metal map checks passed"
