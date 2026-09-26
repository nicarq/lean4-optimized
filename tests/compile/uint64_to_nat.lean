module

/-!
Check UInt64.toNat at the 32-bit split, tagged-Nat boundaries, the Goldilocks
modulus, and UInt64's maximum. Inputs and expected Nats use separate literals.
-/

@[noinline] private def convertUInt64 (value : UInt64) : Nat :=
  value.toNat

private def boundaryCases : Array (UInt64 × Nat) := #[
  (0x00000000_00000000, 0),
  (0x00000000_00000001, 1),
  (0x00000000_7fffffff, 2147483647),
  (0x00000000_80000000, 2147483648),
  (0x00000000_ffffffff, 4294967295),
  (0x00000001_00000000, 4294967296),
  (0x00000001_00000001, 4294967297),
  (0x7fffffff_ffffffff, 9223372036854775807),
  (0x80000000_00000000, 9223372036854775808),
  (0x80000000_00000001, 9223372036854775809),
  (0xffffffff_00000000, 18446744069414584320),
  (0xffffffff_00000001, 18446744069414584321),
  (0xffffffff_00000002, 18446744069414584322),
  (0xffffffff_ffffffff, 18446744073709551615)
]

public def main : IO Unit := do
  for (input, expected) in boundaryCases do
    -- Keep conversion in the runtime loop; do not round-trip the expected Nat.
    let actual := convertUInt64 input
    unless actual == expected do
      throw (IO.userError s!"UInt64.toNat: expected {expected}, got {actual}")
  IO.println "UInt64.toNat boundaries passed"
