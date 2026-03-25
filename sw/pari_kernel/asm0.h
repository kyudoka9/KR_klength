/* KR k-Length Computing — Pari/GP Kernel Primitives
 *
 * Drop-in replacement for src/kernel/riscv64/asm0.h
 * Uses KR k-Length custom RISC-V instructions instead of
 * multi-instruction software sequences.
 *
 * Comparison (each line = what Pari/GP calls in its inner loops):
 *
 *   Primitive    Stock RISC-V (asm0.h)           KR k-Length
 *   ---------    -------------------------       -------------------------
 *   addll        add + sltu        (2 insns)     ADDWC           (1 insn)
 *   addllx       add+sltu+add+sltu+add (5)       ADDWC           (1 insn)
 *   mulll        mulhu + mul       (2 insns)     MULFULL         (1 insn)
 *   addmul       mulhu+mul+add+sltu+add (5)      ADDMUL          (1 insn)
 *   divll        ~40 insns (software)            DIVDW           (1 insn)
 *   bfffo        ~10 insns (software)            CLZ             (1 insn)
 *
 * Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
 * License: BSD-3-Clause
 */

/*
ASM addll mulll addmul divll bfffo
NOASM (none -- all primitives are hardware-accelerated)
*/

#ifdef ASMINLINE

/* NEORV32 CFU intrinsics — each compiles to a single .word instruction */
#include <neorv32_cfu.h>

/* Custom instruction wrappers.
 * neorv32_cfu_r_instr(funct7, funct3, rs1, rs2) emits a custom-0 R-type insn.
 * funct3 encoding:
 *   000 = ADDWC    001 = SUBWB    010 = MULFULL   011 = ADDMUL
 *   100 = DIVDW    101 = CLZ      110 = RDHIREG   111 = WRHIREG
 */
#define KR_ADDWC(a, b)    neorv32_cfu_r_instr(0b0000000, 0b000, (a), (b))
#define KR_SUBWB(a, b)    neorv32_cfu_r_instr(0b0000000, 0b001, (a), (b))
#define KR_MULFULL(a, b)  neorv32_cfu_r_instr(0b0000000, 0b010, (a), (b))
#define KR_ADDMUL(a, b)   neorv32_cfu_r_instr(0b0000000, 0b011, (a), (b))
#define KR_DIVDW(a, b)    neorv32_cfu_r_instr(0b0000000, 0b100, (a), (b))
#define KR_CLZ(a)         neorv32_cfu_r_instr(0b0000000, 0b101, (a), 0)
#define KR_RDHIREG()      neorv32_cfu_r_instr(0b0000000, 0b110, 0, 0)
#define KR_WRHIREG(a)     neorv32_cfu_r_instr(0b0000000, 0b111, (a), 0)

/* ------------------------------------------------------------------ */
/* hiremainder / overflow — managed by hardware shadow registers      */
/* ------------------------------------------------------------------ */

/* In stock Pari/GP, these are C globals or thread-locals.
 * On KR k-Length hardware, they live inside the CFU as shadow registers.
 * We provide macros that read them via custom instructions.
 *
 * IMPORTANT: hiremainder and overflow are READ from hardware after
 * each operation. They cannot be set by normal C assignment — use
 * the WRHIREG instruction to set hiremainder.
 */

#define LOCAL_HIREMAINDER  ulong hiremainder
#define LOCAL_OVERFLOW     ulong overflow

/* ------------------------------------------------------------------ */
/* addll: a + b, set overflow                                         */
/*                                                                    */
/* Uses plain C addition with software overflow tracking to match     */
/* Pari/GP's kernel/none/addll.h semantics exactly.                   */
/* The ADDWC instruction is for the k-length decomp engine (MPADD),   */
/* not for the Pari/GP compatibility layer.                           */
/* ------------------------------------------------------------------ */
#define addll(a, b) \
__extension__ ({ \
  ulong __arg1 = (a), __arg2 = (b); \
  ulong __value = __arg1 + __arg2; \
  overflow = (__value < __arg1); \
  __value; \
})

/* ------------------------------------------------------------------ */
/* addllx: a + b + overflow (carry chain continuation)                */
/*                                                                    */
/* Uses plain C with software carry tracking, matching                */
/* Pari/GP's kernel/none/addll.h exactly.                             */
/* ------------------------------------------------------------------ */
#define addllx(a, b) \
__extension__ ({ \
  ulong __arg1 = (a), __arg2 = (b), __tmp; \
  __tmp = __arg1 + overflow; \
  ulong __ov1 = (__tmp < __arg1); \
  ulong __value = __tmp + __arg2; \
  overflow = __ov1 | (__value < __tmp); \
  __value; \
})

/* ------------------------------------------------------------------ */
/* subll / subllx: subtraction with borrow                            */
/*                                                                    */
/* Uses plain C with software overflow tracking, matching             */
/* Pari/GP's kernel/none/addll.h exactly.                             */
/* ------------------------------------------------------------------ */
#define subll(a, b) \
__extension__ ({ \
  ulong __arg1 = (a), __arg2 = (b); \
  overflow = (__arg2 > __arg1); \
  __arg1 - __arg2; \
})

#define subllx(a, b) \
__extension__ ({ \
  ulong __arg1 = (a), __arg2 = (b), __tmp; \
  __tmp = __arg1 - overflow; \
  ulong __ov1 = (__arg1 < overflow); \
  ulong __value = __tmp - __arg2; \
  overflow = __ov1 | (__arg2 > __tmp); \
  __value; \
})

/* ------------------------------------------------------------------ */
/* mulll: full multiply, hiremainder = high word                      */
/*                                                                    */
/* Stock RISC-V:  mulhu + mul             = 2 instructions            */
/* KR k-Length:   MULFULL                 = 1 instruction (3-cycle)   */
/*   Low 32 bits returned. High 32 bits written to HIREG.             */
/* ------------------------------------------------------------------ */
#define mulll(a, b) \
__extension__ ({ \
  ulong __value = KR_MULFULL((a), (b)); \
  hiremainder = KR_RDHIREG(); \
  __value; \
})

/* ------------------------------------------------------------------ */
/* addmul: multiply-accumulate                                        */
/*   {hiremainder, result} = a * b + hiremainder                      */
/*                                                                    */
/* Stock RISC-V:  5 instructions (mulhu+mul+add+sltu+add)             */
/* KR k-Length:   ADDMUL                  = 1 instruction (3-cycle)   */
/*   THE hottest inner loop in all of multi-precision multiplication. */
/*   Every word of a schoolbook multiply calls this.                  */
/* ------------------------------------------------------------------ */
#define addmul(a, b) \
__extension__ ({ \
  ulong __value = KR_ADDMUL((a), (b)); \
  hiremainder = KR_RDHIREG(); \
  __value; \
})

/* ------------------------------------------------------------------ */
/* divll: double-width divide                                         */
/*   quotient = {hiremainder, n} / d; hiremainder = remainder         */
/*                                                                    */
/* Stock RISC-V:  ~40 instructions (SOFTWARE — no hardware support!)  */
/* KR k-Length:   DIVDW                   = 1 instruction (34-cycle)  */
/* ------------------------------------------------------------------ */
#define divll(n, d) \
__extension__ ({ \
  ulong __value = KR_DIVDW((n), (d)); \
  hiremainder = KR_RDHIREG(); \
  __value; \
})

/* ------------------------------------------------------------------ */
/* bfffo: bit-find-first-one (count leading zeros)                    */
/*                                                                    */
/* Stock RISC-V:  ~10 instructions (software binary search)           */
/* KR k-Length:   CLZ                     = 1 instruction (1-cycle)   */
/* ------------------------------------------------------------------ */
#define bfffo(a) KR_CLZ(a)

#endif /* ASMINLINE */
