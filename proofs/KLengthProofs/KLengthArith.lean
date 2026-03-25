/-
  KR k-Length Computing — Formal Verification of Word-Level Arithmetic
  Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>

  Proves correctness of the word-level arithmetic operations.
  No sorry. No Mathlib.
-/

abbrev MOD : Nat := 4294967296  -- 2^32

theorem mod_pos : (0 : Nat) < MOD := by decide

-- ============================================================================
-- Core identity: n % MOD + n / MOD * MOD = n
-- ============================================================================
theorem recombine (n : Nat) : n % MOD + n / MOD * MOD = n := by
  have h := Nat.div_add_mod n MOD
  rw [Nat.mul_comm] at h
  omega

-- ============================================================================
-- ADDWC: Add with carry
-- ============================================================================
def addwc (a b c : Nat) : Nat × Nat :=
  ((a + b + c) % MOD, (a + b + c) / MOD)

/-- The fundamental ADDWC correctness theorem:
    result + carry_out * 2^32 = a + b + carry_in -/
theorem addwc_spec (a b c : Nat) :
    (addwc a b c).1 + (addwc a b c).2 * MOD = a + b + c :=
  recombine (a + b + c)

/-- ADDWC result is always < 2^32 -/
theorem addwc_lo_lt (a b c : Nat) : (addwc a b c).1 < MOD :=
  Nat.mod_lt _ mod_pos

-- ============================================================================
-- SUBWB: Subtract with borrow
-- ============================================================================
def subwb (a b bi : Nat) : Nat × Nat :=
  if a ≥ b + bi then (a - b - bi, 0) else (a + MOD - b - bi, 1)

/-- SUBWB correctness: a + borrow_out * 2^32 = result + b + borrow_in -/
theorem subwb_spec (a b bi : Nat) (_ha : a < MOD) (hb : b < MOD) (hbi : bi ≤ 1) :
    a + (subwb a b bi).2 * MOD = (subwb a b bi).1 + b + bi := by
  unfold subwb; split <;> omega

/-- SUBWB result is always < 2^32 -/
theorem subwb_lo_lt (a b bi : Nat) (ha : a < MOD) (hb : b < MOD) (hbi : bi ≤ 1) :
    (subwb a b bi).1 < MOD := by
  unfold subwb; split <;> omega

-- ============================================================================
-- MULFULL: Full-width multiply
-- ============================================================================
def mulfull (a b : Nat) : Nat × Nat :=
  (a * b % MOD, a * b / MOD)

/-- MULFULL correctness: lo + hi * 2^32 = a * b -/
theorem mulfull_spec (a b : Nat) :
    (mulfull a b).1 + (mulfull a b).2 * MOD = a * b :=
  recombine (a * b)

/-- MULFULL lo is always < 2^32 -/
theorem mulfull_lo_lt (a b : Nat) : (mulfull a b).1 < MOD :=
  Nat.mod_lt _ mod_pos

-- ============================================================================
-- ADDMUL: Multiply-accumulate
-- ============================================================================
def addmul (a b acc : Nat) : Nat × Nat :=
  ((a * b + acc) % MOD, (a * b + acc) / MOD)

/-- ADDMUL correctness: lo + hi * 2^32 = a * b + acc -/
theorem addmul_spec (a b acc : Nat) :
    (addmul a b acc).1 + (addmul a b acc).2 * MOD = a * b + acc :=
  recombine (a * b + acc)

/-- ADDMUL lo is always < 2^32 -/
theorem addmul_lo_lt (a b acc : Nat) : (addmul a b acc).1 < MOD :=
  Nat.mod_lt _ mod_pos

-- ============================================================================
-- CLZ: Count leading zeros
-- ============================================================================
def clz (a : Nat) : Nat :=
  if a = 0 then 32 else 31 - Nat.log2 a

theorem clz_zero : clz 0 = 32 := by decide
