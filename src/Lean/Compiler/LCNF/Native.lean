/-
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

prelude
public import Lean.Compiler.LCNF.PhaseExt
public import Lean.Compiler.LCNF.NativeType
public import Lean.Compiler.LCNF.NativeUniform
import Init.While

namespace Lean.Compiler.LCNF.Native

public structure Program where
  source : String
  captures : Array DataType
  uniforms : Array Uniform := #[]
  result : Nat
  deriving Inhabited

private def cast (k : Nat) (s : String) : String :=
  match k with
  | 2 => s!"uint({s})"
  | 4 => s!"uchar({s})"
  | 5 => s!"ushort({s})"
  | 6 => s!"ulong(bool({s}))"
  | _ => s!"ulong({s})"

private structure Value where
  text : String
  kind : DataType
  shape : String := ""
  packed : Bool := false
  deriving Inhabited

private abbrev Vars := Std.HashMap FVarId Value

private structure State where
  next : Nat := 0
  body : String := ""
  active : NameSet := {}
  captureCount : Nat := 0
  uniforms : Array Uniform := #[]
  returned : Std.HashSet String := {}

private abbrev M := StateRefT State CoreM

private def emit (text : String) : M Unit := modify fun s => { s with body := s.body ++ text ++ "\n" }

private def fallback : String :=
  "atomic_fetch_or_explicit(errors,1u,memory_order_relaxed); return;"

private def fresh (k : DataType) (shape : String := "") (packed : Bool := false) : M Value := do
  let n := (← get).next
  modify fun s => { s with next := n + 1 }
  let value := { text := s!"v{n}", kind := k, shape, packed }
  if k.wordArray && !packed then
    if shape.isEmpty then throwError "unknown native array extent"
    emit s!"Arr<{shape}_SIZE> {value.text};"
  else emit s!"ulong {value.text};"
  return value

private def arg (vars : Vars) : Arg .pure → M Value
  | .fvar id => match vars[id]? with
    | some value => pure value
    | none => throwError "unsupported native map variable"
  | _ => return { text := "0ul", kind := .scalar 7 }

private def scalarKind (type : Expr) : M Nat := do
  let some (.scalar k) := dataType type | throwError "native map result is not a scalar"
  return k

private def primitive (fn : Name) (args : Array Value) (type : DataType) : Option String := do
  let a := args[0]?.getD default |>.text
  let b := args[1]?.getD default |>.text
  let .str _ op := fn | none
  let ty := fn.getPrefix
  if ty == ``Nat || ty == ``UInt64 || ty == ``UInt32 || ty == ``UInt16 ||
      ty == ``UInt8 || ty == ``USize then
    guard (args.all fun a => match a.kind with | .scalar _ => true | _ => false)
    let .scalar k := type | none
    let bits := if ty == ``UInt32 then 32 else if ty == ``UInt16 then 16
      else if ty == ``UInt8 then 8 else 64
    let raw ← match op with
      | "ofNat" | "ofNatLT" | "toNat" | "toUInt64" | "toUInt32" | "toUInt16" | "toUInt8" | "toUSize" => some a
      | "add" => some <| if ty == ``Nat then s!"nat_add({a},{b},failed)" else s!"({a}+{b})"
      | "sub" => some <| if ty == ``Nat then s!"({a}>{b}?{a}-{b}:0ul)" else s!"({a}-{b})"
      | "mul" => some <| if ty == ``Nat then s!"nat_mul({a},{b},failed)" else s!"({a}*{b})"
      | "div" => some s!"({b}==0ul?0ul:{a}/{b})"
      | "mod" => some s!"({b}==0ul?{a}:{a}%{b})"
      | "land" => some s!"({a}&{b})"
      | "lor" => some s!"({a}|{b})"
      | "xor" => some s!"({a}^{b})"
      | "complement" => some s!"(~{a})"
      | "shiftLeft" => if ty == ``Nat then none else some s!"({a}<<({b}%{bits}ul))"
      | "shiftRight" => if ty == ``Nat then none else some s!"({a}>>({b}%{bits}ul))"
      | "decEq" | "beq" => some s!"({a}=={b})"
      | "decLt" | "lt" => some s!"({a}<{b})"
      | "decLe" | "le" => some s!"({a}<={b})"
      | _ => none
    return cast k raw
  else if fn == ``Bool.not then
    guard (args[0]!.kind == .scalar 6)
    return s!"ulong(!{a})"
  else if fn == ``Bool.true then return "1ul"
  else if fn == ``Bool.false then return "0ul"
  else if fn == ``PUnit.unit || fn == ``List.nil || fn == ``Option.none then return "0ul"
  else if fn == ``Array.size then
    let xs := args.back!
    let .array _ := xs.kind | none
    return if xs.kind.wordArray && !xs.packed then s!"{xs.text}.size()"
      else s!"packed_field(input,{xs.text},0ul,failed)"
  else none

private structure Join where
  params : Array Value
  called : Value

private structure Frame where
  fn : Name
  params : Array Value
  again : Value
  shape : String

private def assign (dst src : Value) : M Unit := do
  unless dst.kind == src.kind do
    throwError "incompatible native map values"
  if dst.kind.wordArray && dst.packed && !src.packed then
    throwError "native array mutation changes its storage"
  if dst.kind.wordArray && !dst.packed && src.packed then
    emit s!"{dst.text} = load_array<{dst.shape}_SIZE>(input,{src.text},failed);"
  else if dst.kind.wordArray && !dst.packed && dst.shape != src.shape then
    emit s!"{dst.text} = copy_array<{dst.shape}_SIZE>({src.text},failed);"
  else emit s!"{dst.text} = {src.text};"

private def fromPacked (type : DataType) (shape text : String) : M Value := do
  let out ← fresh type shape type.wordArray
  emit s!"{out.text} = {text};"
  return out

private def assignParams (dst src : Array Value) : M Unit := do
  unless dst.size == src.size do throwError "native map arity mismatch"
  let temps ← src.mapM fun value => do
    let temp ← fresh value.kind value.shape value.packed
    assign temp value
    return temp
  for d in dst, s in temps do assign d s

mutual
private partial def call (fn : Name) (args : Array Value) (k : DataType) : M Value := do
  if fn == ``Array.getInternal || fn == ``Array.get!Internal || fn == ``Array.uget then
    let args := args.filter (! ·.kind.erased)
    let xs := args[args.size - 2]!
    let i := args.back!
    let .array element := xs.kind | throwError "unsupported native array input"
    unless k.accepts element do throwError "erased native array element"
    unless i.kind == .scalar 0 || i.kind == .scalar 3 do throwError "unsupported native array index"
    if xs.kind.wordArray && !xs.packed then
      let out ← fresh element
      emit s!"{out.text} = array_get({xs.text},{i.text},failed);"
      return out
    return ← fromPacked element (xs.shape ++ "_E") s!"packed_get(input,{xs.text},{i.text},failed)"
  if fn == ``Array.set! then
    let args := args.filter (! ·.kind.erased)
    let xs := args[0]!
    unless xs.kind.wordArray do throwError "unsupported native array update"
    let updated ← fresh xs.kind xs.shape
    assign updated xs
    emit s!"{updated.text} = array_set({updated.text},{args[1]!.text},{args[2]!.text},failed);"
    return updated
  if !args.isEmpty && args.all (·.kind.erased) then
    if let some uniform ← uniform? fn then
      let uniforms := (← get).uniforms
      let slot := (uniforms.findIdx? (·.function == fn)).getD uniforms.size
      if slot == uniforms.size then modify fun s => { s with uniforms := uniforms.push uniform }
      let index := (← get).captureCount + slot
      return ← fromPacked uniform.type s!"CAPTURE_{index}" s!"input[{index}]"
  let shape := (args.find? (! ·.shape.isEmpty)).map (·.shape) |>.getD ""
  let out ← fresh k shape
  if let some text := primitive fn args k then
    emit s!"{out.text} = {text};"
    return out
  if (← get).active.contains fn then throwError "recursive native map call {fn}"
  let some decl ← getMonoDecl? fn | throwError "unsupported native map call {fn}"
  unless decl.safe do throwError "unsafe native map call {fn}"
  let .code body := decl.value | throwError "unsupported native map extern {fn}"
  unless decl.params.size == args.size do throwError "partial native map call {fn}"
  let active := (← get).active
  modify fun s => { s with active := active.insert fn }
  emit "{"
  let params ← args.mapM fun a => do
    let value ← fresh a.kind a.shape (a.packed && !k.wordArray)
    assign value a
    return value
  let again ← fresh (.scalar 6)
  let mut vars : Vars := {}
  for p in decl.params, a in params do vars := vars.insert p.fvarId a
  emit s!"do \{ {again.text} = 0ul; do \{"
  code body vars {} out { fn, params, again, shape }
  unless (← get).returned.contains out.text do
    throwError "native call has no supported return {fn}"
  emit s!"} while(false); } while({again.text});"
  emit "}"
  modify fun s => { s with active }
  return out

private partial def value (decl : LetDecl .pure) (vars : Vars) : M Value := do
  let some k := dataType decl.type | throwError "unsupported native map value type {decl.type}"
  match decl.value with
  | .lit lit =>
    let n ← match lit with
      | .nat n => pure n
      | .uint8 n => pure n.toNat
      | .uint16 n => pure n.toNat
      | .uint32 n => pure n.toNat
      | .uint64 n | .usize n => pure n.toNat
      | _ => throwError "unsupported native map literal"
    if n >= 2^64 then throwError "native map literal exceeds one word"
    return { text := s!"{n}ul", kind := k }
  | .erased => return { text := "0ul", kind := .scalar 7 }
  | .fvar id args =>
    unless args.isEmpty do throwError "indirect native map call"
    arg vars (.fvar id)
  | .const fn _ args => call fn (← args.mapM (arg vars)) k
  | .proj ``Prod index id =>
    let pair ← arg vars (.fvar id)
    let .pair left right := pair.kind | throwError "unsupported native pair input"
    let actual := if index == 0 then left else right
    unless k.accepts actual do throwError "erased native pair field"
    let field := if index == 0 then "_L" else "_R"
    fromPacked actual (pair.shape ++ field) s!"packed_field(input,{pair.text},{index}ul,failed)"
  | _ => throwError "unsupported native map expression"

private partial def code (body : Code .pure) (vars : Vars)
    (joins : Std.HashMap FVarId Join) (out : Value) (frame : Frame) : M Unit := do
  match body with
  | .let decl next =>
    if let .return id := next then
      if id == decl.fvarId then
        if let .const fn _ args := decl.value then
          if fn == frame.fn then
            assignParams frame.params (← args.mapM (arg vars))
            emit s!"{frame.again.text} = 1ul; break;"
            return
    code next (vars.insert decl.fvarId (← value decl vars)) joins out frame
  | .return id =>
    assign out (← arg vars (.fvar id))
    modify fun s => { s with returned := s.returned.insert out.text }
    emit "break;"
  | .jp decl next =>
    let params ← decl.params.mapM fun p => do
      let some k := dataType p.type | throwError "unsupported native join parameter"
      fresh k frame.shape
    let called ← fresh (.scalar 6)
    emit s!"{called.text} = 0ul;"
    let joins := joins.insert decl.fvarId { params, called }
    emit "do {"
    code next vars joins out frame
    emit "} while(false);"
    emit s!"while ({called.text}) \{ {called.text} = 0ul; do \{"
    let mut vars := vars
    for p in decl.params, a in params do vars := vars.insert p.fvarId a
    code decl.value vars joins out frame
    emit "} while(false); }"
  | .jmp id args =>
    let some jp := joins[id]? | throwError "unknown native map join point"
    assignParams jp.params (← args.mapM (arg vars))
    emit s!"{jp.called.text} = 1ul; break;"
  | .cases cs =>
    let discr ← arg vars (.fvar cs.discr)
    let supported := match cs.typeName, discr.kind with
      | ``Bool, .scalar 6 | ``List, .list _ | ``Option, .option _ | ``Prod, .pair .. => true
      | _, _ => false
    unless supported do throwError "unsupported native case input"
    for alt in cs.alts do
      match alt with
      | .alt ctor params branch =>
        let cond ← match cs.typeName, ctor with
          | ``Bool, ``Bool.false => pure s!"{discr.text} == 0ul"
          | ``Bool, ``Bool.true => pure s!"{discr.text} != 0ul"
          | ``List, ``List.nil | ``Option, ``Option.none => pure s!"{discr.text} == 0ul"
          | ``List, ``List.cons | ``Option, ``Option.some => pure s!"{discr.text} != 0ul"
          | ``Prod, ``Prod.mk => pure "true"
          | _, _ => throwError "unsupported native map case {cs.typeName}"
        emit s!"if ({cond}) \{"
        let mut vars := vars
        let fields := match discr.kind with
          | .list elem => if ctor == ``List.cons then #[elem, .list elem] else #[]
          | .option elem => if ctor == ``Option.some then #[elem] else #[]
          | .pair left right => #[left, right]
          | _ => #[]
        unless fields.size == params.size do throwError "unsupported native constructor layout"
        for h : i in [:params.size] do
          let p := params[i]
          let some type := dataType p.type | throwError "unsupported native case parameter"
          let actual := fields[i]!
          unless type.accepts actual do throwError "erased native constructor field"
          let suffix := if cs.typeName == ``Prod then (if i == 0 then "_L" else "_R")
            else if cs.typeName == ``Option then "_V" else if i == 0 then "_E" else ""
          let v ← fromPacked actual (discr.shape ++ suffix) s!"packed_field(input,{discr.text},{i}ul,failed)"
          vars := vars.insert p.fvarId v
        branchCode branch vars joins out frame
        emit "}"
      | .default branch =>
        emit "else {"
        branchCode branch vars joins out frame
        emit "}"
  | _ => throwError "unsupported native map control flow"

private partial def branchCode (body : Code .pure) (vars : Vars)
    (joins : Std.HashMap FVarId Join) (out : Value) (frame : Frame) : M Unit := do
  let saved ← get
  try
    code body vars joins out frame
  catch error =>
    set saved
    trace[Compiler.native] "branch fallback in {frame.fn}: {error.toMessageData}"
    emit fallback
end

private def preamble : String := "#include <metal_stdlib>\nusing namespace metal;\n\
struct Inputs { device const ulong* values; device const ulong* tables;\n\
  ulong operator[](ulong address) const { return address >> 63 ?\n\
    tables[address & 0x7ffffffffffffffful] : values[address]; } };\n\
inline ulong nat_add(ulong a,ulong b,thread bool* failed) {\n\
  ulong r=a+b; if(r<a) *failed=true; return r; }\n\
inline ulong nat_mul(ulong a,ulong b,thread bool* failed) {\n\
  if(mulhi(a,b)) *failed=true; return a*b; }\n\
template<uint N> struct Arr { ulong values[N?N:1]; constexpr ulong size() const { return N; } };\n\
template<uint N> Arr<N> load_array(Inputs input,ulong base,thread bool* failed) {\n\
  Arr<N> a{}; if(*failed) return a;\n\
  if(input[base]!=N) { *failed=true; return a; }\n\
  for(uint i=0;i<N;++i) a.values[i]=input[base+1+i]; return a; }\n\
template<uint N,uint M> Arr<N> copy_array(Arr<M> a,thread bool* failed) {\n\
  Arr<N> b{}; if(N!=M) { *failed=true; return b; }\n\
  for(uint i=0;i<N;++i) b.values[i]=a.values[i]; return b; }\n\
inline ulong packed_field(Inputs input,ulong base,ulong i,thread bool* failed) { return *failed ? 0ul : input[base+i]; }\n\
inline ulong packed_get(Inputs input,ulong base,ulong i,thread bool* failed) {\n\
  if(*failed) return 0ul;\n\
  if(i>=input[base]) { *failed=true; return 0ul; }\n\
  return input[base+1+i]; }\n\
template<uint N> ulong array_get(Arr<N> a,ulong i,thread bool* failed) {\n\
  if(i>=N) { *failed=true; return 0ul; }\n\
  return a.values[i]; }\n\
template<uint N> Arr<N> array_set(Arr<N> a,ulong i,ulong v,thread bool* failed) {\n\
  if(i>=N) { *failed=true; return a; }\n\
  a.values[i]=v; return a; }\n"

public def compile? (fn : Name) : CoreM (Option Program) := do
  try
    let fn := if isBoxedName fn then fn.getPrefix else fn
    let some decl ← getMonoDecl? fn | return none
    if decl.params.isEmpty then return none
    let result ← (scalarKind decl.type.getForallBody).run' {}
    let kinds ← decl.params.mapM fun p => do
      let some k := dataType p.type | throwError "unsupported native map parameter {p.type}"
      return k
    unless kinds.back! == .scalar 0 do return none
    let captures := kinds.pop
    let (out, state) ← (do
      let args ← captures.mapIdxM fun i k => do
        fromPacked k s!"CAPTURE_{i}" s!"input[{i}]"
      call fn (args.push { text := "ulong(index)", kind := .scalar 0 }) (.scalar result)).run { captureCount := captures.size }
    let source := preamble ++ "kernel void lean_native(device const ulong* values [[buffer(0)]],\n\
      device ulong* output [[buffer(1)]],device atomic_uint* errors [[buffer(2)]],\n\
      constant uint& count [[buffer(3)]],device const ulong* tables [[buffer(4)]],\n\
      uint index [[thread_position_in_grid]]) {\n\
      if(index>=count) return; Inputs input{values,tables};\n\
      bool fault=false; thread bool* failed=&fault;\n" ++ state.body ++ s!"if(fault) atomic_fetch_or_explicit(errors,1u,memory_order_relaxed); else output[index] = {out.text};\n}\n"
    return some { source, captures, result, uniforms := state.uniforms }
  catch error =>
    trace[Compiler.native] "{fn}: {error.toMessageData}"
    return none

end Lean.Compiler.LCNF.Native
