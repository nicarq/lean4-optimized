import Init.Data.SInt.Basic

/-!
Check 64-bit conversion at the 32-bit split, tagged-Nat limits, Goldilocks
modulus, and wrap boundaries. Expected residues are separate decimal literals.
-/

@[noinline] private def unsignedOfNat (value : Nat) : UInt64 :=
  UInt64.ofNat value

@[noinline] private def signedOfNat (value : Nat) : Int64 :=
  Int64.ofNat value

@[noinline] private def signedOfInt (value : Int) : Int64 :=
  Int64.ofInt value

private def natCases : Array (Nat × Nat × Int) := #[
  (0, 0, 0),
  (1, 1, 1),
  (2147483647, 2147483647, 2147483647),
  (2147483648, 2147483648, 2147483648),
  (4294967295, 4294967295, 4294967295),
  (4294967296, 4294967296, 4294967296),
  (4294967297, 4294967297, 4294967297),
  (9223372036854775807, 9223372036854775807, 9223372036854775807),
  (9223372036854775808, 9223372036854775808, -9223372036854775808),
  (9223372036854775809, 9223372036854775809, -9223372036854775807),
  (18446744069414584320, 18446744069414584320, -4294967296),
  (18446744069414584321, 18446744069414584321, -4294967295),
  (18446744069414584322, 18446744069414584322, -4294967294),
  (18446744073709551615, 18446744073709551615, -1),
  (18446744073709551616, 0, 0),
  (18446744073709551617, 1, 1),
  (340282366920938463463374607431768211457, 1, 1)
]

private def negativeCases : Array (Int × Int) := #[
  (-1, -1),
  (-2147483647, -2147483647),
  (-2147483648, -2147483648),
  (-4294967295, -4294967295),
  (-4294967296, -4294967296),
  (-4294967297, -4294967297),
  (-9223372036854775807, -9223372036854775807),
  (-9223372036854775808, -9223372036854775808),
  (-9223372036854775809, 9223372036854775807),
  (-18446744069414584320, 4294967296),
  (-18446744069414584321, 4294967295),
  (-18446744069414584322, 4294967294),
  (-18446744073709551615, 1),
  (-18446744073709551616, 0),
  (-18446744073709551617, -1),
  (-340282366920938463463374607431768211457, -1)
]

def main : IO Unit := do
  for (input, expectedUnsigned, expectedSigned) in natCases do
    let actualUnsigned := (unsignedOfNat input).toNat
    unless actualUnsigned == expectedUnsigned do
      throw (IO.userError s!"UInt64.ofNat {input}: expected {expectedUnsigned}, got {actualUnsigned}")
    let actualSignedNat := (signedOfNat input).toInt
    unless actualSignedNat == expectedSigned do
      throw (IO.userError s!"Int64.ofNat {input}: expected {expectedSigned}, got {actualSignedNat}")
    let actualSignedInt := (signedOfInt (Int.ofNat input)).toInt
    unless actualSignedInt == expectedSigned do
      throw (IO.userError s!"Int64.ofInt {input}: expected {expectedSigned}, got {actualSignedInt}")
  for (input, expected) in negativeCases do
    let actual := (signedOfInt input).toInt
    unless actual == expected do
      throw (IO.userError s!"Int64.ofInt {input}: expected {expected}, got {actual}")
  IO.println "64-bit Nat and Int conversion boundaries passed"
