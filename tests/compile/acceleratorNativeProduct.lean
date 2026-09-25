module

/-! Test native product folds, immutable table reuse, and changing captured inputs. -/

private def degree := 54

private def pairs (output : Nat) : List (Nat × Nat) :=
  (List.range degree).filterMap fun i =>
    if i ≤ output && output - i < degree then some (i, output - i) else none

private def pairTable (_ : Unit) : Array (List (Nat × Nat)) :=
  Array.ofFn fun i : Fin (2 * degree - 1) => pairs i.val

private def weights (_ : Unit) : Array UInt64 :=
  Array.ofFn fun i : Fin degree => i.val.toUInt64 + 1

@[noinline] private def coefficient (key digit : Array UInt64)
    (pairs : List (Nat × Nat)) : UInt64 :=
  pairs.foldl (fun sum pair => sum + key[pair.1]! * digit[pair.2]!) 0

@[noinline] private def products (key digit : Array UInt64)
    (table : Array (List (Nat × Nat))) : Array UInt64 :=
  Array.ofFn fun i : Fin (2 * degree - 1) => coefficient key digit table[i.val]!

@[noinline] private def closedProducts (key digit : Array UInt64) : Array UInt64 :=
  Array.ofFn fun i : Fin (2 * degree - 1) => coefficient key digit (pairTable ())[i.val]!

@[noinline] private def twoTables (key digit : Array UInt64) : Array UInt64 :=
  Array.ofFn fun i : Fin (2 * degree - 1) =>
    coefficient key digit (pairTable ())[i.val]! + (weights ())[i.val % degree]!

public def main : IO Unit := do
  let key := (List.range degree).toArray.map (fun i => i.toUInt64 * 18446744073709551557)
  let digit := (List.range degree).toArray.map (fun i => i.toUInt64 ^^^ 7)
  let table := (List.range (2 * degree - 1)).toArray.map pairs
  let actual := products key digit table
  let closed := closedProducts key digit
  let nextKey := key.map (· + 1)
  let next := closedProducts nextKey digit
  let modified := products key digit (table.set! 0 [(1, 1)])
  let weighted := twoTables key digit
  for output in [:2 * degree - 1] do
    let mut expected : UInt64 := 0
    let mut expectedNext : UInt64 := 0
    for i in [:degree] do
      if i ≤ output && output - i < degree then
        expected := expected + key[i]! * digit[output - i]!
        expectedNext := expectedNext + nextKey[i]! * digit[output - i]!
    unless actual[output]! == expected && closed[output]! == expected do
      throw (IO.userError s!"native product mismatch at {output}")
    unless next[output]! == expectedNext && weighted[output]! == expected + (output % degree).toUInt64 + 1 do
      throw (IO.userError s!"cached native product mismatch at {output}")
    let expectedModified := if output == 0 then key[1]! * digit[1]! else expected
    unless modified[output]! == expectedModified do
      throw (IO.userError s!"captured table update mismatch at {output}")
  IO.println "native product maps passed"
