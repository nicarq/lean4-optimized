/-
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

prelude
public import Lean.Compiler.LCNF.CompilerM
import Lean.Compiler.LCNF.PhaseExt
import Lean.Compiler.LCNF.NativeType
import Lean.Compiler.LCNF.FVarUtil
import Lean.Compiler.LCNF.SimpleGroundExpr
import Lean.Compiler.ClosedTermCache
import Lean.Compiler.ExternAttr

namespace Lean.Compiler.LCNF.Native

open ImpureType

public inductive MapArg where
  | actual (arg : Arg .impure)
  | nat (value : Nat)
  | global (name : Name) (type : Expr)
  deriving BEq, Inhabited

public structure MapSite where
  decl : LetDecl .impure
  function : Name
  args : Array (Arg .impure)
  mapper : Name
  captures : Array MapArg
  count : MapArg

public def mapSite? (decl : LetDecl .impure) : CompilerM (Option MapSite) := do
  let .fap fn args := decl.value | return none
  unless (fn == `Array.ofFn._redArg || fn == ``Array.ofFn) && args.size >= 2 do return none
  let .fvar closure := args.back! | return none
  let some closure ← findLetDecl? (pu := .impure) closure | return none
  let .pap mapper captures := closure.value | return none
  return some {
    decl, function := fn, args, mapper
    captures := captures.map MapArg.actual
    count := .actual args[args.size - 2]! }

private inductive WrapperValue where
  | input (value : MapArg)
  | mapper (name : Name) (captures : Array MapArg)

private def wrapperArg (values : Std.HashMap FVarId WrapperValue) : Arg .pure → Option MapArg
  | .fvar id => match values[id]? with
    | some (.input value) => some value
    | _ => none
  | _ => some (.actual .erased)

/-- Look through a pure helper that only constructs a mapper and returns its map.
The wrapper's original signature still controls ownership at the call site. -/
private partial def wrapperSite? (site : LetDecl .impure) : CompilerM (Option MapSite) := do
  let .fap fn args := site.value | return none
  let some decl ← getMonoDecl? fn | return none
  let some sig ← getImpureSignature? fn | return none
  unless decl.safe && decl.params.size == args.size && sig.params.size == args.size do return none
  unless sig.params.all (fun p => p.type.isObj || p.type.isErased || p.type.isVoid) do return none
  let .code body := decl.value | return none
  let mut values : Std.HashMap FVarId WrapperValue := {}
  for param in decl.params, arg in args do
    values := values.insert param.fvarId (.input (.actual arg))
  (scan body values).run
where
  scan (body : Code .pure) (values : Std.HashMap FVarId WrapperValue) : OptionT CompilerM MapSite := do
    let .let decl next := body | failure
    match decl.value with
    | .lit (.nat n) =>
      guard (n < 2^31)
      scan next (values.insert decl.fvarId (.input (.nat n)))
    | .erased => scan next (values.insert decl.fvarId (.input (.actual .erased)))
    | .const fn _ args =>
      if (fn == `Array.ofFn._redArg || fn == ``Array.ofFn) && args.size >= 2 then
        let .return id := next | failure
        guard (id == decl.fvarId)
        let some count := wrapperArg values args[args.size - 2]! | failure
        let .fvar closure := args.back! | failure
        let some (.mapper mapper captures) := values[closure]? | failure
        let .fap function callerArgs := site.value | failure
        return { decl := site, function, args := callerArgs, mapper, captures, count }
      else if args.isEmpty && !decl.type.isForall then
        let some (.scalar _) := dataType decl.type | failure
        let env ← getEnv
        guard ((getExternAttrData? env fn).isNone && !isClosedTermName env fn)
        let some sig ← getImpureSignature? fn | failure
        guard sig.params.isEmpty
        scan next (values.insert decl.fvarId (.input (.global fn sig.type)))
      else
        guard decl.type.isForall
        let some captures := args.mapM (wrapperArg values) | failure
        scan next (values.insert decl.fvarId (.mapper fn captures))
    | _ => failure

public structure Chain where
  first : MapSite
  last : MapSite
  dependency : Nat
  /-- These reads can run before the first map without consuming any object. -/
  prepare : Array (LetDecl .impure)
  continuation : Code .impure

/-- Match two dependent maps whose intermediate array does not escape.
Only immediate constants, persistent ground values and borrowed projections may
be prepared early. Reference counts stay in their original order on both paths. -/
public partial def chain? (firstDecl : LetDecl .impure) (next : Code .impure) :
    CompilerM (Option Chain) := do
  let .fap _ args := firstDecl.value | return none
  if args.isEmpty then return none
  scan next #[] none
where
  scan (code : Code .impure) (prepare : Array (LetDecl .impure))
      (closure : Option FVarId) : CompilerM (Option Chain) := do
    match code with
    | .inc _ _ _ _ next | .dec _ _ _ _ _ next => scan next prepare closure
    | .let decl next =>
      if let some last ← mapSite? decl then
        let some closure := closure | return none
        unless last.args.back! == .fvar closure do return none
        let input := MapArg.actual (.fvar firstDecl.fvarId)
        let some dependency := last.captures.findIdx? (· == input) | return none
        unless (last.captures.filter (· == input)).size == 1 do return none
        if anyFVar (fun id => id == firstDecl.fvarId || id == closure) next then return none
        let some first ← do
          if let some first ← mapSite? firstDecl then pure (some first) else wrapperSite? firstDecl
          | return none
        return some { first, last, dependency, prepare, continuation := next }
      if let .pap _ args := decl.value then
        if closure.isSome || !args.contains (.fvar firstDecl.fvarId) then return none
        return ← scan next prepare (some decl.fvarId)
      if anyFVar (fun id => id == firstDecl.fvarId || closure == some id) decl.value then return none
      let safe : Bool ← match decl.value with
        -- Nat values below 2^31 are tagged immediates on both 32-bit and 64-bit hosts.
        | .lit (.nat n) => pure (n < 2^31)
        | .erased | .oproj .. => pure true
        | .fap fn args =>
          let env ← getEnv
          -- Eager globals are already initialized; lazy initializers and externs
          -- must not be moved across a computation.
          pure (args.isEmpty && (getExternAttrData? env fn).isNone &&
            (isSimpleGroundDecl env fn || !isClosedTermName env fn))
        | _ => pure false
      if !safe then return none
      scan next (prepare.push decl) closure
    | _ => return none

end Lean.Compiler.LCNF.Native
