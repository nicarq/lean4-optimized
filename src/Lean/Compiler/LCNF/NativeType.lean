/-
Copyright (c) 2026 Nico Arqueros. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
module

prelude
public import Lean.Compiler.LCNF.PhaseExt

namespace Lean.Compiler.LCNF.Native

public inductive DataType where
  | unknown
  | scalar (kind : Nat)
  | array (element : DataType)
  | list (element : DataType)
  | pair (left right : DataType)
  | option (element : DataType)
  deriving Inhabited, BEq

public def DataType.wordArray : DataType → Bool
  | .array (.scalar _) => true
  | _ => false

public def DataType.erased : DataType → Bool
  | .scalar 7 => true
  | _ => false

/-- Refine erased LCNF fields only with types already known from the input layout. -/
public def DataType.accepts : DataType → DataType → Bool
  | .unknown, _ => true
  | .scalar a, .scalar b => a == b
  | .array a, .array b | .list a, .list b | .option a, .option b => a.accepts b
  | .pair a b, .pair c d => a.accepts c && b.accepts d
  | _, _ => false

public def DataType.encode : DataType → String
  | .unknown => "7"
  | .scalar k => toString k
  | .array t => "a" ++ t.encode
  | .list t => "l" ++ t.encode
  | .pair a b => "p" ++ a.encode ++ b.encode
  | .option t => "o" ++ t.encode

public partial def dataType (type : Expr) : Option DataType := do
  match type.getAppFn.constName?.getD .anonymous with
  | ``lcAny => return .unknown
  | ``Nat => return .scalar 0
  | ``UInt64 => return .scalar 1
  | ``UInt32 => return .scalar 2
  | ``USize => return .scalar 3
  | ``UInt8 => return .scalar 4
  | ``UInt16 => return .scalar 5
  | ``Bool => return .scalar 6
  | ``PUnit => return .scalar 7
  | ``Array => return .array (← dataType type.appArg!)
  | ``List => return .list (← dataType type.appArg!)
  | ``Option => return .option (← dataType type.appArg!)
  | ``Prod =>
    let args := type.getAppArgs
    guard (args.size == 2)
    return .pair (← dataType args[0]!) (← dataType args[1]!)
  | _ => if type == erasedExpr then some (.scalar 7) else none

end Lean.Compiler.LCNF.Native
