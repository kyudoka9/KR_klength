// ================================================================================ //
// KR Bignum — Custom Instruction Intrinsics for NEORV32 CFU                        //
// -------------------------------------------------------------------------------- //
// Software-side intrinsics mapping to kr_bignum_cfu.vhd hardware.                  //
// These replace Pari/GP's kernel primitives (addll, mulll, divll, etc.)             //
// with single custom RISC-V instructions.                                          //
//                                                                                  //
// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>                    //
// License: BSD-3-Clause                                                            //
// ================================================================================ //

#ifndef KR_BIGNUM_H
#define KR_BIGNUM_H

#include <stdint.h>
#include <neorv32_cfu.h>

// ============================================================================
// Instruction encoding constants
// ============================================================================
//
// All instructions use R-type format via custom-0 opcode (0b0001011).
// funct3 selects the operation; funct7 distinguishes variants:
//
//   funct3  funct7     Mnemonic    Description
//   000     0000000    ADDWC       Add with carry
//   001     0000000    SUBWB       Subtract with borrow
//   010     0000000    MULFULL     Full-width multiply
//   011     0000000    ADDMUL      Multiply-accumulate
//   100     0000000    DIVDW       Double-width divide
//   101     0000000    CLZ         Count leading zeros
//   110     0000000    RDHIREG     Read HIREG
//   110     0000001    RDCARRY     Read carry flag
//   111     0000000    WRHIREG     Write HIREG
//   111     0000001    WRCARRY     Write carry flag

// ============================================================================
// Core bignum intrinsics
// ============================================================================

// ADDWC: rd = rs1 + rs2 + carry_in; carry_out updated internally
// Replaces Pari/GP's addll/addllx (2-5 RISC-V instructions -> 1)
// Single-cycle.
static inline uint32_t kr_addwc(uint32_t a, uint32_t b) {
  return neorv32_cfu_r_instr(0b0000000, 0b000, a, b);
}

// SUBWB: rd = rs1 - rs2 - borrow_in; borrow_out updated internally
// Replaces Pari/GP's subll/subllx
// Single-cycle.
static inline uint32_t kr_subwb(uint32_t a, uint32_t b) {
  return neorv32_cfu_r_instr(0b0000000, 0b001, a, b);
}

// MULFULL: {HIREG, rd} = rs1 * rs2
// HIREG receives the high 32 bits, rd receives the low 32 bits.
// Replaces Pari/GP's mulll (mul + mulhu = 2 instructions -> 1)
// 3-cycle latency (DSP48E1 pipeline).
static inline uint32_t kr_mulfull(uint32_t a, uint32_t b) {
  return neorv32_cfu_r_instr(0b0000000, 0b010, a, b);
}

// ADDMUL: {HIREG, rd} = rs1 * rs2 + HIREG
// The multiply-accumulate inner loop primitive.
// Replaces Pari/GP's addmul (5 instructions -> 1)
// 3-cycle latency (DSP48E1 pipeline).
static inline uint32_t kr_addmul(uint32_t a, uint32_t b) {
  return neorv32_cfu_r_instr(0b0000000, 0b011, a, b);
}

// DIVDW: rd = {HIREG, rs1} / rs2; HIREG = remainder
// Double-width dividend division.
// Replaces Pari/GP's divll (~40 instructions -> 1 hardware instruction)
// 34-cycle latency (iterative restoring division).
static inline uint32_t kr_divdw(uint32_t dividend_lo, uint32_t divisor) {
  return neorv32_cfu_r_instr(0b0000000, 0b100, dividend_lo, divisor);
}

// CLZ: rd = count_leading_zeros(rs1)
// Returns 0-32 (32 if input is zero).
// Replaces Pari/GP's bfffo.
// Single-cycle (combinational).
static inline uint32_t kr_clz(uint32_t x) {
  return neorv32_cfu_r_instr(0b0000000, 0b101, x, 0);
}

// RDHIREG: rd = HIREG
// Read the hi-remainder shadow register.
// Single-cycle.
static inline uint32_t kr_rdhireg(void) {
  return neorv32_cfu_r_instr(0b0000000, 0b110, 0, 0);
}

// WRHIREG: HIREG = rs1; rd = old HIREG
// Write to HIREG, returns previous value.
// Single-cycle.
static inline uint32_t kr_wrhireg(uint32_t val) {
  return neorv32_cfu_r_instr(0b0000000, 0b111, val, 0);
}

// RDCARRY: rd = carry flag (0 or 1).
// Reads the internal carry/overflow flag that is normally implicit.
// Single-cycle.
static inline uint32_t kr_rdcarry(void) {
  return neorv32_cfu_r_instr(0b0000001, 0b110, 0, 0);
}

// WRCARRY: carry = rs1[0]; rd = old carry (0 or 1).
// Writes the internal carry/overflow flag directly.
// Single-cycle.
static inline uint32_t kr_wrcarry(uint32_t val) {
  return neorv32_cfu_r_instr(0b0000001, 0b111, val, 0);
}


// ============================================================================
// Pari/GP-compatible wrappers
// ============================================================================
// These provide drop-in replacements for Pari/GP's kernel primitives.
// Usage: replace #include "kernel/riscv64/asm0.h" with #include "kr_bignum.h"

// Note: Pari/GP uses globals 'hiremainder' and 'overflow'. Our CFU keeps
// these as internal shadow registers. Use kr_rdhireg() to read hiremainder
// and the carry is implicit in ADDWC/SUBWB chains.

// addll: add two words, return result.
// Caller is responsible for tracking overflow in a software variable,
// matching Pari/GP's kernel/none/addll.h semantics.
// Uses plain C (not ADDWC) because the Pari/GP overflow variable is
// a separate software concept from the CFU's internal carry flag.
static inline uint32_t kr_addll(uint32_t a, uint32_t b) {
  return a + b;
  // Caller checks overflow: overflow = (result < a);
}

// addllx: add two words plus carry_in (from software overflow variable).
// Caller passes carry_in and receives the new carry out.
// This matches Pari/GP's kernel/none/addll.h exactly:
//   tmp = a + carry_in; ov1 = (tmp < a);
//   result = tmp + b;   ov2 = (result < tmp);
//   overflow = ov1 | ov2;
static inline uint32_t kr_addllx(uint32_t a, uint32_t b, uint32_t carry_in,
                                  uint32_t *overflow_out) {
  uint32_t tmp = a + carry_in;
  uint32_t ov1 = (tmp < a);
  uint32_t result = tmp + b;
  *overflow_out = ov1 | (result < tmp);
  return result;
}

// subll: subtract two words, return result.
// Caller checks overflow: overflow = (b > a);
static inline uint32_t kr_subll(uint32_t a, uint32_t b) {
  return a - b;
  // Caller checks overflow: overflow = (b > a);
}

// subllx: subtract two words minus borrow_in (from software overflow variable).
// Caller passes borrow_in and receives the new borrow out.
static inline uint32_t kr_subllx(uint32_t a, uint32_t b, uint32_t borrow_in,
                                  uint32_t *overflow_out) {
  uint32_t tmp = a - borrow_in;
  uint32_t ov1 = (a < borrow_in);
  uint32_t result = tmp - b;
  *overflow_out = ov1 | (b > tmp);
  return result;
}

// mulll: multiply two words, hiremainder = high word, returns low word
static inline uint32_t kr_mulll(uint32_t a, uint32_t b) {
  return kr_mulfull(a, b);
  // After this, kr_rdhireg() returns the high 32 bits
}

// addmul: multiply-accumulate: {hiremainder, result} = a * b + hiremainder
static inline uint32_t kr_addmul_pari(uint32_t a, uint32_t b) {
  return kr_addmul(a, b);
  // HIREG is updated with the new high word automatically
}

// divll: divide {hiremainder, n} by d. Returns quotient, hiremainder = remainder.
static inline uint32_t kr_divll(uint32_t n, uint32_t d) {
  return kr_divdw(n, d);
  // After this, kr_rdhireg() returns the remainder
}

// bfffo: bit-find-first-one (count leading zeros)
// Pari/GP's bfffo returns the number of leading zero bits.
static inline uint32_t kr_bfffo(uint32_t x) {
  return kr_clz(x);
}


// ============================================================================
// Multi-precision helper: multiply two multi-word numbers
// ============================================================================
// This demonstrates using the custom instructions in a multi-precision
// multiply loop — the exact pattern from Pari/GP's muliispec.
//
// Multiplies a[0..na-1] by b[0..nb-1], result in r[0..na+nb-1].
// Words are stored little-endian (least significant first).
static inline void kr_mpn_mul(uint32_t *r, const uint32_t *a, int na,
                               const uint32_t *b, int nb) {
  int i, j;

  // Clear result
  for (i = 0; i < na + nb; i++) r[i] = 0;

  // Schoolbook multiply using ADDMUL
  for (i = 0; i < na; i++) {
    kr_wrhireg(0); // clear accumulator for this row
    for (j = 0; j < nb; j++) {
      // ADDMUL: {hireg, lo} = a[i] * b[j] + hireg
      uint32_t lo = kr_addmul(a[i], b[j]);
      // Add lo to result[i+j] with carry propagation
      uint32_t old = r[i + j];
      uint32_t sum = old + lo;
      r[i + j] = sum;
      if (sum < old) {
        // Propagate carry into hireg
        uint32_t hi = kr_rdhireg();
        kr_wrhireg(hi + 1);
      }
    }
    // Store final hireg as carry into result[i + nb], propagate if overflow
    uint32_t hi = kr_rdhireg();
    uint32_t old = r[i + nb];
    r[i + nb] = old + hi;
    if (r[i + nb] < old) {
      // Propagate carry through remaining result words
      for (int k = i + nb + 1; k < na + nb; k++) {
        r[k]++;
        if (r[k] != 0) break;
      }
    }
  }
}


#endif // KR_BIGNUM_H
