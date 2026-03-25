# KR k-Length Computing — Codebase Audit Report
# 2026-03-25, Kyudoka Research

## Summary

4 parallel audit agents examined every RTL module, integration top, VHDL boundary,
and C software header. **13 CRITICAL bugs found**, plus 12 WARNINGs and 10 NOTEs.

No architectural flaws — all bugs are implementation errors fixable without redesign.

## Critical Bugs (must fix before hardware testing)

### RTL — Decomposition Engine (kr_decomp_engine.v)

**D4: MPMUL partial products overwrite instead of accumulate.**
The schoolbook multiply writes each `a[i]*b[j]` result to `result[i+j]` in BRAM.
When multiple partial products target the same result word (e.g., `a[0]*b[1]` and
`a[1]*b[0]` both target `result[1]`), the second write overwrites the first.
Correct behavior requires read-modify-write: load old value, add new partial
product, store updated value.
Fix: redesign MPMUL micro-op sequence to include explicit accumulation steps.

**D3: Stale results can corrupt next operation.**
When a new operation starts, `next_tag` resets to 0 but results from the previous
operation may still be in-flight. If a stale result arrives with tag T, it looks up
`tag_dst_addr[T]` which now maps to the NEW operation's destination, writing stale
data to the wrong location.
Fix: do not reset next_tag between operations (monotonic), or add a generation
counter that invalidates old tags.

**D5: Tag overflow aliases for ops > 1024 micro-ops.**
With TAG_BITS=10, tags wrap at 1024. For a 33×32 multiply (1056 micro-ops), tags
alias, causing tag_dst_addr corruption.
Fix: already addressed by tag recycling free-list (kr_klength_tag_freelist.v).

### RTL — MAC Functional Unit (kr_klength_fu_mac.v)

**M2d: ADDMUL doesn't accumulate — just multiplies.**
The MAC computes `src1 * src2` but NOT `src1 * src2 + accumulator`. There is no
hireg/accumulator input. The Pari/GP kernel's addmul requires fused multiply-add.
Fix: either add an accumulator input port to the MAC, or handle accumulation
externally via explicit load-add-store micro-ops in the decomp engine.

**M2c: MULFULL high word lost.**
`s2_product[63:32]` is computed but never output. Only the low 32 bits reach
`result_data`. The high word has no output path.
Fix: add a high-word output port, or store it in an internal register readable
via a separate micro-op.

**M4: 1-bit carry loses 31 bits of high product.**
`result_carry <= |s2_product[63:32]` reduces the 32-bit high word to a single bit.
For multi-precision multiply, the full 32-bit high word must propagate.
Fix: carry must be the full high word, not a single bit. This requires widening
the carry path throughout the design (CDB, carry table, result collector).

### RTL — Integration Top (kr_klength_top.v)

**D9: Carry table RAW hazard.**
The carry table is written 2+ cycles after a MAC completes (latch → drain → register).
But the decomp engine can dispatch a carry-dependent micro-op 1 cycle after its
predecessor. The carry read gets stale data.
Fix: either stall dispatch until carry is resolved, or add a forwarding bypass
from the result collector to the dispatch stage.

### Software — Pari/GP Kernel (asm0.h)

**S9a: SUBWB(0,0) doesn't clear carry when borrow is set.**
`0 - 0 - 1 = -1` in unsigned sets borrow=1. Carry remains set.
Fix: use `KR_ADDWC(0, 0)` to clear carry (always produces carry=0).

**S9b: addll overflow reads HIREG (unrelated to carry).**
The carry flag is CFU-internal, not readable via RDHIREG. The overflow check
`KR_RDHIREG() ? 0 : ...` reads a stale multiply result, not carry state.
Fix: compute overflow purely from result: `overflow = (result < a) ? 1 : 0`.

**S9c: addllx overflow wrong for carry_in=1, a=0.**
`result < a` doesn't detect carry when carry_in causes the overflow.
Fix: `overflow = (result < a) || (result == a && carry_in_was_set)`.
Since carry_in is not directly readable, track it in software or add RDCARRY.

**S9d: subllx overflow wrong for borrow_in=1, a==b.**
Same class of bug as S9c for subtraction.
Fix: same approach — need borrow_in visibility or software tracking.

### Software — C Headers (kr_bignum.h, kr_klength.h)

**S2a: kr_addll doesn't clear carry before first add.**
The function calls kr_addwc directly without clearing carry state.
Fix: add `(void)kr_addwc(0, 0);` before the main add (clears carry to 0).

**S5a: BRAM layout overflows on Artix-7.**
Result buffer at word 0x2000 exceeds 13-bit address space (8192 words).
Writes wrap and corrupt Operand A.
Fix: reduce BRAM layout for 13-bit: A=0x0000, B=0x0800, R=0x1000 (max 2048
words per operand on Artix-7). Or increase BRAM_ADDR_W to 14 on Artix-7.

## Warnings (should fix, edge-case risks)

- D1: Duplicate last-word capture in BRAM fetch (fragile but harmless)
- D2: Wasted cycle in BRAM fetch (S_IDLE pre-read discarded)
- D7: len_b=0 with len_a>0 on MPMUL deadlocks FSM
- D10: `>=` comparison in DRAIN fragile with stale results
- D15: No bounds check on cmd_len vs MAX_WORDS
- D16: MPADD assumes len_a == len_b
- M1: Single-cycle/multi-cycle collision in MAC (protected by dispatch but module unsafe in isolation)
- M3: DSP48E1 inference suboptimal (64x64 expression instead of 32x32)
- M5: fu_busy=0 during single-cycle ops
- I2: Non-power-of-2 modulo in dispatch loop (expensive for N=48)
- I3: Simultaneous latch set+clear drops result (mitigated by round-robin)
- S3b: kr_mpn_mul final carry can overflow without propagation

## Next Steps

1. Fix all CRITICAL bugs before any hardware testing
2. The two biggest redesign items are:
   a. MPMUL accumulation (D4 + M2d + M4): requires either widening carry to 32 bits
      or restructuring MPMUL as load-add-store micro-op sequences
   b. Carry visibility (S9a-d): add RDCARRY instruction to CFU, or redesign the
      software overflow tracking to not depend on reading carry state
3. All other fixes are localized and straightforward
