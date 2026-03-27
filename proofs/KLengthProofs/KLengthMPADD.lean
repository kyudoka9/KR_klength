/-
  KR k-Length Computing — Formal Verification of Multi-Precision Addition
  Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>

  Proves correctness of multi-precision addition (MPADD) built on
  word-level ADDWC from KLengthArith. Uses Mathlib's nlinarith for
  nonlinear arithmetic involving MOD^(n+1) = MOD * MOD^n.

  No sorry.
-/

import KLengthProofs.KLengthArith
import Mathlib.Tactic

-- ============================================================================
-- Multi-precision number representation
-- ============================================================================

/-- Value of a multi-precision number stored as a little-endian word list.
    mpn_value [w0, w1, ..., wn] = w0 + w1 * MOD + w2 * MOD^2 + ... -/
def mpn_value : List Nat → Nat
  | [] => 0
  | w :: ws => w + MOD * mpn_value ws

-- ============================================================================
-- Multi-precision addition with carry chain
-- ============================================================================

/-- Add two equal-length multi-precision numbers with carry propagation.
    Returns (result_words, final_carry). -/
def mpadd : List Nat → List Nat → Nat → List Nat × Nat
  | [], [], c => ([], c)
  | a :: as, b :: bs, c =>
    let p := addwc a b c
    let q := mpadd as bs p.2
    (p.1 :: q.1, q.2)
  | _, _, c => ([], c)

-- ============================================================================
-- MPADD correctness: the key theorem
-- ============================================================================

/-- Multi-precision addition is correct:
    mpn_value(result) + final_carry * MOD^n = mpn_value(a) + mpn_value(b) + carry_in
    where n = a.length. -/
theorem mpadd_correct (a b : List Nat) (c : Nat) (h : a.length = b.length) :
    mpn_value (mpadd a b c).1 + (mpadd a b c).2 * MOD ^ a.length =
      mpn_value a + mpn_value b + c := by
  induction a, b, c using mpadd.induct with
  | case1 c => simp [mpadd, mpn_value]
  | case2 a as b bs c p_eq ih =>
    simp only [mpadd, mpn_value, List.length_cons]
    have hlen : as.length = bs.length := by simpa using h
    -- Introduce names for the key subexpressions
    set lo := (addwc a b c).1
    set hi := (addwc a b c).2
    set rv := mpn_value (mpadd as bs hi).1
    set rc := (mpadd as bs hi).2
    -- Inductive hypothesis: tail addition is correct
    have hih : rv + rc * MOD ^ as.length =
      mpn_value as + mpn_value bs + hi := ih hlen
    -- Word-level spec: lo + hi * MOD = a + b + c
    have hspec : lo + hi * MOD = a + b + c := addwc_spec a b c
    -- Rewrite MOD^(n+1) = MOD^n * MOD for nlinarith
    have hpow : MOD ^ (as.length + 1) = MOD ^ as.length * MOD :=
      Nat.pow_succ MOD as.length
    nlinarith
  | case3 t x c hn hc =>
    -- Catch-all: mismatched list shapes are impossible given h
    cases t with
    | nil =>
      cases x with
      | nil => exact absurd rfl (hn rfl)
      | cons b bs => simp [List.length_cons] at h
    | cons a as =>
      cases x with
      | nil => simp [List.length_cons] at h
      | cons b bs => exact absurd rfl (hc a as b bs rfl)

-- ============================================================================
-- MPADD preserves length
-- ============================================================================

/-- The result of mpadd has the same length as the inputs. -/
theorem mpadd_length (a b : List Nat) (c : Nat) (h : a.length = b.length) :
    (mpadd a b c).1.length = a.length := by
  induction a, b, c using mpadd.induct with
  | case1 c => simp [mpadd]
  | case2 a as b bs c p_eq ih =>
    simp only [mpadd, List.length_cons]
    have hlen : as.length = bs.length := by simpa using h
    exact congrArg (· + 1) (ih hlen)
  | case3 t x c hn hc =>
    cases t with
    | nil =>
      cases x with
      | nil => exact absurd rfl (hn rfl)
      | cons b bs => simp [List.length_cons] at h
    | cons a as =>
      cases x with
      | nil => simp [List.length_cons] at h
      | cons b bs => exact absurd rfl (hc a as b bs rfl)

-- ============================================================================
-- MPADD result words are valid (each < MOD)
-- ============================================================================

/-- All words in the input list are valid (< MOD). -/
def all_valid : List Nat → Prop
  | [] => True
  | w :: ws => w < MOD ∧ all_valid ws

/-- Each word in the mpadd result is < MOD, provided the inputs are valid. -/
theorem mpadd_result_valid (a b : List Nat) (c : Nat)
    (h : a.length = b.length) (ha : all_valid a) (hb : all_valid b) :
    all_valid (mpadd a b c).1 := by
  induction a, b, c using mpadd.induct with
  | case1 c => simp [mpadd, all_valid]
  | case2 a as b bs c p_eq ih =>
    simp only [mpadd, all_valid]
    have hlen : as.length = bs.length := by simpa using h
    constructor
    · exact addwc_lo_lt a b c
    · exact ih hlen ha.2 hb.2
  | case3 t x c hn hc =>
    cases t with
    | nil =>
      cases x with
      | nil => exact absurd rfl (hn rfl)
      | cons b bs => simp [List.length_cons] at h
    | cons a as =>
      cases x with
      | nil => simp [List.length_cons] at h
      | cons b bs => exact absurd rfl (hc a as b bs rfl)
