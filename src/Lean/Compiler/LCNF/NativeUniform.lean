/-
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

prelude
public import Lean.Compiler.LCNF.NativeType
import Lean.Compiler.LCNF.Types
import Lean.Compiler.InitAttr

namespace Lean.Compiler.LCNF.Native

open ImpureType

builtin_initialize registerTraceClass `Compiler.native

public structure Uniform where
  function : Name
  type : DataType
  deriving Inhabited

private def pureBuiltin (fn : Name) : Bool :=
  if [``Array.ofFn, `Array.ofFn._redArg, ``Array.mkEmpty, ``Array.empty,
      ``Array.push, ``Array.size, ``Array.toList, ``List.range].contains fn then true
  else if [``Nat, ``UInt8, ``UInt16, ``UInt32, ``UInt64, ``USize, ``Bool].contains fn.getPrefix then
    ["ofNat", "ofNatLT", "toNat", "toUInt8", "toUInt16", "toUInt32", "toUInt64", "toUSize",
      "add", "sub", "mul", "div", "mod", "land", "lor", "xor", "complement",
      "shiftLeft", "shiftRight", "decEq", "beq", "decLt", "decLe", "not"].contains fn.getString!
  else false

private abbrev CheckM := StateRefT NameSet CoreM

mutual
private partial def checkFunction (fn : Name) : CheckM Bool := do
  if (← get).contains fn || pureBuiltin fn then return true
  if (← getEnv).find? fn matches some (.ctorInfo _) then return true
  if hasInitAttr (← getEnv) fn then
    trace[Compiler.native] "uniform initializer {fn}"
    return false
  let some decl ← getMonoDecl? fn
    | trace[Compiler.native] "unknown uniform call {fn}"; return false
  unless decl.safe do
    trace[Compiler.native] "unsafe uniform call {fn}"
    return false
  let .code body := decl.value
    | trace[Compiler.native] "external uniform call {fn}"; return false
  modify (·.insert fn)
  checkCode body

private partial def checkCode (code : Code .pure) : CheckM Bool := do
  match code with
  | .let decl next =>
    let valid ← match decl.value with
      | .const fn .. => checkFunction fn
      | .lit .. | .erased | .fvar .. | .proj .. => pure true
    if !valid then return false
    checkCode next
  | .fun decl next | .jp decl next =>
    if !(← checkCode decl.value) then return false
    checkCode next
  | .cases cs => cs.alts.allM (fun alt => checkCode alt.getCode)
  | .return .. | .jmp .. => return true
  | .unreach .. => return false
end

/-- Only total data construction behind erased arguments may be prepared on the host.
Unknown extern calls, initializers, partial functions and unreachable code reject the plan. -/
public def uniform? (fn : Name) : CoreM (Option Uniform) := do
  let some decl ← getMonoDecl? fn | return none
  if decl.params.isEmpty then return none
  unless decl.params.all (fun p => dataType p.type == some (.scalar 7)) do return none
  let some type := dataType decl.type.getForallBody | return none
  if type matches .scalar _ | .unknown then return none
  unless ← (checkFunction fn).run' {} do return none
  let some sig ← getImpureSignature? fn | return none
  if sig.params.isEmpty || !sig.type.isObj then return none
  unless sig.params.all (fun p => p.type.isObj || p.type.isVoid || p.type.isErased) do return none
  return some { function := fn, type }

end Lean.Compiler.LCNF.Native
