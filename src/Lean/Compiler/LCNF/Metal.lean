/-
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Nico Arqueros
-/
module

prelude
public import Lean.Compiler.LCNF.PassManager
import Lean.Compiler.Options
import Lean.Compiler.LCNF.PhaseExt
import Lean.Compiler.ExternAttr
import Init.Data.String.TakeDrop

namespace Lean.Compiler.LCNF.Metal

private partial def rewriteMaps (code : Code .pure) : Code .pure :=
  match code with
  | .let decl k =>
    let value := match decl.value with
      | .const ``Array.map _ #[.type a, .type b, f, xs] =>
        if a.isConstOf ``UInt64 && b.isConstOf ``UInt64 then
          .const ``Array.mapUInt64Metal [] #[f, xs]
        else decl.value
      | _ => decl.value
    .let { decl with value } (rewriteMaps k)
  | .fun (.mk id name ps ty body) k =>
    .fun (.mk id name ps ty (rewriteMaps body)) (rewriteMaps k)
  | .jp (.mk id name ps ty body) k =>
    .jp (.mk id name ps ty (rewriteMaps body)) (rewriteMaps k)
  | .cases c => .cases <| c.updateAlts <| c.alts.map fun
    | .alt name ps body => .alt name ps (rewriteMaps body)
    | .default body => .default (rewriteMaps body)
  | other => other

public def pass : Pass where
  name := `metalMaps
  phase := .base
  run decls := do
    if !compiler.metal.get (← getOptions) then return decls
    return decls.map fun decl =>
      match decl.value with
      | .code code => { decl with value := .code (rewriteMaps code) }
      | _ => decl

private def scalarType (ty : Expr) : Option String :=
  if ty == ImpureType.uint64 then some "ulong"
  else if ty == ImpureType.uint32 then some "uint"
  else if ty == ImpureType.uint16 then some "ushort"
  else if ty == ImpureType.uint8 then some "uchar"
  else if ty == ImpureType.tagged then some "ulong"
  else none

private structure SourceState where
  next : Nat := 0
  -- Bound duplicated continuations and helper emission independently of Lean's heartbeats.
  remaining : Nat := 4096
  names : Std.HashMap Name String := {}
  source : String := ""
  deriving Inhabited

private abbrev M := OptionT (StateRefT SourceState CoreM)
private abbrev Vars := Std.HashMap FVarId String
private abbrev Jumps := Std.HashMap FVarId (FunDecl .impure)

private def step : M Unit := do
  let remaining := (← get).remaining
  guard (remaining > 0)
  modify fun s => { s with remaining := remaining - 1 }

private def fresh : M String := do
  step
  let n := (← get).next
  modify fun s => { s with next := n + 1 }
  return s!"v{n}"

private def arg (vars : Vars) (a : Arg .impure) : M String := do
  step
  match a with
  | .fvar id => OptionT.mk <| pure (vars[id]?)
  | _ => failure

private def builtin (name : Name) (args : Array String) : Option String := do
  let family := name.getPrefix
  let width ← if family == ``UInt64 then some 64
    else if family == ``UInt32 then some 32
    else if family == ``UInt16 then some 16
    else if family == ``UInt8 then some 8 else none
  let op := name.getString!
  let a ← args[0]?
  if op == "toUInt64" then return s!"ulong({a})"
  if op == "toUInt32" then return s!"uint({a})"
  if op == "toUInt16" then return s!"ushort({a})"
  if op == "toUInt8" then return s!"uchar({a})"
  if op == "complement" then return s!"(~({a}))"
  let b ← args[1]?
  match op with
  | "add" => return s!"({a} + {b})"
  | "sub" => return s!"({a} - {b})"
  | "mul" => return s!"(ulong({a}) * ulong({b}))"
  | "div" => return s!"({b} == 0 ? 0 : {a} / {b})"
  | "mod" => return s!"({b} == 0 ? {a} : {a} % {b})"
  | "land" => return s!"({a} & {b})"
  | "lor" => return s!"({a} | {b})"
  | "xor" => return s!"({a} ^ {b})"
  | "shiftLeft" => return s!"({a} << ({b} % {width}))"
  | "shiftRight" => return s!"({a} >> ({b} % {width}))"
  | "decEq" | "beq" => return s!"({a} == {b})"
  | "decLt" => return s!"({a} < {b})"
  | "decLe" => return s!"({a} <= {b})"
  | _ => none

private def builtinExtern (name : Name) : String :=
  let family := name.getPrefix
  let cPrefix := if family == ``UInt64 then "lean_uint64_"
    else if family == ``UInt32 then "lean_uint32_"
    else if family == ``UInt16 then "lean_uint16_" else "lean_uint8_"
  let suffix := match name.getString! with
    | "shiftLeft" => "shift_left"
    | "shiftRight" => "shift_right"
    | "decEq" | "beq" => "dec_eq"
    | "decLt" => "dec_lt"
    | "decLe" => "dec_le"
    | "toUInt64" => "to_uint64"
    | "toUInt32" => "to_uint32"
    | "toUInt16" => "to_uint16"
    | "toUInt8" => "to_uint8"
    | other => other
  cPrefix ++ suffix

private partial def compileFn (decls : Array (Decl .impure)) (active : List Name)
    (name : Name) : M String := do
  step
  guard (!active.contains name)
  if let some name := (← get).names[name]? then return name
  let some decl := decls.find? (·.name == name) | failure
  guard (decl.safe && !decl.recursive)
  let .code body := decl.value | failure
  let ret ← OptionT.mk <| pure (scalarType decl.type)
  let fname ← fresh
  let mut vars : Vars := {}
  let mut params : Array String := #[]
  for p in decl.params do
    let ty ← OptionT.mk <| pure (scalarType p.type)
    let v ← fresh
    vars := vars.insert p.fvarId v
    params := params.push s!"{ty} {v}"
  let body ← compileCode (name :: active) vars {} [] body
  modify fun s => { s with
    names := s.names.insert name fname
    source := s.source ++ s!"{ret} {fname}({String.intercalate "," params.toList}) \{\n{body}}\n" }
  return fname
where
  compileCode (active : List Name) (vars : Vars) (jumps : Jumps)
      (jumpStack : List FVarId) (code : Code .impure) : M String := do
    step
    checkSystem "Metal code generation"
    match code with
    | .return id => return s!"return {← arg vars (.fvar id)};\n"
    | .let decl k =>
      let ty ← OptionT.mk <| pure (scalarType decl.type)
      let value ← match decl.value with
        | .lit (.nat n) => pure s!"{n}UL"
        | .lit (.uint8 n) => pure s!"{n}UL"
        | .lit (.uint16 n) => pure s!"{n}UL"
        | .lit (.uint32 n) => pure s!"{n}UL"
        | .lit (.uint64 n) => pure s!"{n}UL"
        | .fvar id #[] => arg vars (.fvar id)
        | .ctor info #[] => do
          guard info.isScalar
          pure s!"{info.cidx}UL"
        | .fap fn args => do
          let args ← args.mapM (arg vars)
          if let some expression := builtin fn args then
            guard (getExternNameFor (← getEnv) `c fn == some (builtinExtern fn))
            pure expression
          else
            let fn ← compileFn decls active fn
            pure s!"{fn}({String.intercalate "," args.toList})"
        | _ => failure
      let v ← fresh
      return s!"{ty} {v} = {ty}({value});\n" ++
        (← compileCode active (vars.insert decl.fvarId v) jumps jumpStack k)
    | .jp decl k => compileCode active vars (jumps.insert decl.fvarId decl) jumpStack k
    | .jmp id args =>
      guard (!jumpStack.contains id)
      let some decl := jumps[id]? | failure
      guard (decl.params.size == args.size)
      let values ← args.mapM (arg vars)
      let vars := decl.params.zip values |>.foldl (fun vars (p, v) => vars.insert p.fvarId v) vars
      compileCode active vars jumps (id :: jumpStack) decl.value
    | .cases c =>
      let discr ← arg vars (.fvar c.discr)
      let mut result := s!"switch ({discr}) \{\n"
      for alt in c.alts do
        let (label, body) ← match alt with
          | .ctorAlt info body => do
            guard info.isScalar
            pure (s!"case {info.cidx}:", body)
          | .default body => pure ("default:", body)
        result := result ++ label ++ " {\n" ++
          (← compileCode active vars jumps jumpStack body) ++ "}\n"
      return result ++ "}\nreturn 0;\n"
    | _ => failure

/-- Reject everything outside the finite scalar subset before producing a kernel. -/
public def source? (decls : Array (Decl .impure)) (decl : Decl .impure) : CoreM (Option String) := do
  if decl.type != ImpureType.uint64 || decl.params.isEmpty ||
      !decl.params.all (·.type == ImpureType.uint64) then return none
  let (result, s) ← (compileFn decls [] decl.name).run |>.run {}
  let some fn := result | return none
  let captures := (List.range (decl.params.size - 1)).map fun i => s!"captured[{i}]"
  let args := String.intercalate "," (captures ++ ["input[i]"])
  return some <| "#include <metal_stdlib>\nusing namespace metal;\n" ++ s.source ++
    "kernel void lean_map(device const ulong *input [[buffer(0)]], " ++
    "device ulong *output [[buffer(1)]], constant ulong *captured [[buffer(2)]], " ++
    "constant ulong &count [[buffer(3)]], uint i [[thread_position_in_grid]]) {\n" ++
    s!"if (ulong(i) < count) output[i] = {fn}({args});\n}\n"

end Lean.Compiler.LCNF.Metal
