// ================================================================================ //
// KR Bignum CFU — Validation Test Suite                                            //
// -------------------------------------------------------------------------------- //
// Tests all custom instructions against Pari/GP reference implementations.         //
// Runs on NEORV32 bare-metal. Output via UART0.                                    //
//                                                                                  //
// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>                    //
// ================================================================================ //

#include <neorv32.h>
#include "kr_bignum.h"

#define BAUD_RATE 19200

static int tests_run = 0;
static int tests_pass = 0;

// ============================================================================
// Test helpers
// ============================================================================
static void check(const char *name, uint32_t got, uint32_t expected) {
  tests_run++;
  if (got == expected) {
    tests_pass++;
  } else {
    neorv32_uart0_printf("  FAIL %s: got 0x%x, expected 0x%x\n", name, got, expected);
  }
}

// ============================================================================
// Reference implementations (from Pari/GP kernel/none/)
// ============================================================================

// Software addll: add with carry detection
static uint32_t ref_overflow;
static uint32_t ref_addll(uint32_t a, uint32_t b) {
  uint32_t r = a + b;
  ref_overflow = (r < a) ? 1 : 0;
  return r;
}

static uint32_t ref_addllx(uint32_t a, uint32_t b) {
  uint32_t tmp = a + ref_overflow;
  uint32_t ov1 = (tmp < a) ? 1 : 0;
  uint32_t r = tmp + b;
  uint32_t ov2 = (r < tmp) ? 1 : 0;
  ref_overflow = ov1 | ov2;
  return r;
}

// Software mulll: full multiply using half-word decomposition
static uint32_t ref_hiremainder;
static uint32_t ref_mulll(uint32_t x, uint32_t y) {
  uint32_t xlo = x & 0xFFFF, xhi = x >> 16;
  uint32_t ylo = y & 0xFFFF, yhi = y >> 16;
  uint32_t xylo = xlo * ylo;
  uint32_t xyhi = xhi * yhi;
  uint32_t xymid = (xhi + xlo) * (yhi + ylo) - xyhi - xylo;
  uint32_t xymidhi = xymid >> 16;
  uint32_t xymidlo = xymid << 16;
  xylo += xymidlo;
  ref_hiremainder = xyhi + xymidhi + (xylo < xymidlo ? 1 : 0)
    + ((((xhi + xlo + yhi + ylo) >> 1) - xymidhi) & 0xFFFF0000u);
  return xylo;
}

// Software addmul
static uint32_t ref_addmul(uint32_t x, uint32_t y) {
  uint32_t xlo = x & 0xFFFF, xhi = x >> 16;
  uint32_t ylo = y & 0xFFFF, yhi = y >> 16;
  uint32_t xylo = xlo * ylo;
  uint32_t xyhi = xhi * yhi;
  uint32_t xymid = (xhi + xlo) * (yhi + ylo) - xyhi - xylo;
  // Add hiremainder to xylo
  xylo += ref_hiremainder;
  xyhi += (xylo < ref_hiremainder ? 1 : 0);
  uint32_t xymidhi = xymid >> 16;
  uint32_t xymidlo = xymid << 16;
  xylo += xymidlo;
  ref_hiremainder = xyhi + xymidhi + (xylo < xymidlo ? 1 : 0)
    + ((((xhi + xlo + yhi + ylo) >> 1) - xymidhi) & 0xFFFF0000u);
  return xylo;
}

// Software CLZ
static uint32_t ref_clz(uint32_t x) {
  if (x == 0) return 32;
  uint32_t n = 0;
  if ((x & 0xFFFF0000u) == 0) { n += 16; x <<= 16; }
  if ((x & 0xFF000000u) == 0) { n += 8;  x <<= 8;  }
  if ((x & 0xF0000000u) == 0) { n += 4;  x <<= 4;  }
  if ((x & 0xC0000000u) == 0) { n += 2;  x <<= 2;  }
  if ((x & 0x80000000u) == 0) { n += 1;  }
  return n;
}

// ============================================================================
// Test: ADDWC / SUBWB
// ============================================================================
static void test_addwc(void) {
  neorv32_uart0_printf("\n--- ADDWC / SUBWB ---\n");

  // Clear carry by subtracting 0-0 (sets carry=0)
  kr_subwb(0, 0);

  // Simple add, no carry in
  uint32_t r = kr_addwc(100, 200);
  check("addwc(100,200)", r, 300);

  // Add with overflow
  kr_subwb(0, 0); // clear carry
  r = kr_addwc(0xFFFFFFFF, 1);
  check("addwc(0xFFFFFFFF,1)=0", r, 0);

  // The carry should now be set; test addwc with carry
  r = kr_addwc(0, 0); // 0 + 0 + carry(1) = 1
  check("addwc(0,0)+carry=1", r, 1);

  // Carry should now be clear
  r = kr_addwc(0, 0); // 0 + 0 + carry(0) = 0
  check("addwc(0,0)+nocarry=0", r, 0);

  // Multi-word addition: 0xFFFFFFFF_FFFFFFFF + 1 = 0x00000001_00000000
  kr_subwb(0, 0); // clear carry
  uint32_t lo = kr_addwc(0xFFFFFFFF, 1); // lo = 0, carry = 1
  uint32_t hi = kr_addwc(0xFFFFFFFF, 0); // hi = 0xFFFFFFFF + 0 + 1 = 0, carry = 1
  check("64-bit add lo", lo, 0);
  check("64-bit add hi", hi, 0);

  // SUBWB test
  kr_subwb(0, 0); // clear borrow
  r = kr_subwb(100, 30);
  check("subwb(100,30)=70", r, 70);

  kr_subwb(0, 0); // clear borrow
  r = kr_subwb(0, 1); // underflow: 0 - 1 = 0xFFFFFFFF, borrow = 1
  check("subwb(0,1)=0xFFFFFFFF", r, 0xFFFFFFFF);
  r = kr_subwb(10, 0); // 10 - 0 - borrow(1) = 9
  check("subwb(10,0)-borrow=9", r, 9);
}

// ============================================================================
// Test: MULFULL
// ============================================================================
static void test_mulfull(void) {
  neorv32_uart0_printf("\n--- MULFULL ---\n");

  // Simple multiply
  uint32_t lo = kr_mulfull(6, 7);
  uint32_t hi = kr_rdhireg();
  check("mulfull(6,7) lo=42", lo, 42);
  check("mulfull(6,7) hi=0", hi, 0);

  // Multiply with overflow
  lo = kr_mulfull(0x10000, 0x10000); // 2^16 * 2^16 = 2^32
  hi = kr_rdhireg();
  check("mulfull(2^16,2^16) lo=0", lo, 0);
  check("mulfull(2^16,2^16) hi=1", hi, 1);

  // Large multiply
  lo = kr_mulfull(0xFFFFFFFF, 0xFFFFFFFF); // (2^32-1)^2 = 2^64 - 2^33 + 1
  hi = kr_rdhireg();
  check("mulfull(max,max) lo=1", lo, 1);
  check("mulfull(max,max) hi=0xFFFFFFFE", hi, 0xFFFFFFFE);

  // Compare against software reference
  uint32_t a = 0xDEADBEEF, b = 0xCAFEBABE;
  uint32_t ref_lo = ref_mulll(a, b);
  uint32_t ref_hi = ref_hiremainder;
  lo = kr_mulfull(a, b);
  hi = kr_rdhireg();
  check("mulfull(DEADBEEF,CAFEBABE) lo", lo, ref_lo);
  check("mulfull(DEADBEEF,CAFEBABE) hi", hi, ref_hi);
}

// ============================================================================
// Test: ADDMUL
// ============================================================================
static void test_addmul(void) {
  neorv32_uart0_printf("\n--- ADDMUL ---\n");

  // ADDMUL: {hireg,rd} = rs1 * rs2 + hireg
  // Set HIREG to 100, then multiply 6*7+100 = 142
  kr_wrhireg(100);
  uint32_t lo = kr_addmul(6, 7);
  uint32_t hi = kr_rdhireg();
  check("addmul(6,7)+100 lo=142", lo, 142);
  check("addmul(6,7)+100 hi=0", hi, 0);

  // Chained addmul (the bignum inner loop pattern)
  // Compute 3 * 5 + 0 = 15, then 3 * 7 + hireg(0) = 21
  kr_wrhireg(0);
  lo = kr_addmul(3, 5); // {hi,lo} = 15
  check("addmul(3,5) lo=15", lo, 15);
  // hireg should be 0 (15 fits in 32 bits)
  lo = kr_addmul(3, 7); // {hi,lo} = 3*7 + 0 = 21
  check("addmul(3,7)+0 lo=21", lo, 21);

  // Compare against reference for large values
  uint32_t a = 0xDEADBEEF, b = 0xCAFEBABE;
  ref_hiremainder = 0x12345678;
  kr_wrhireg(0x12345678);

  uint32_t ref_lo = ref_addmul(a, b);
  uint32_t ref_hi = ref_hiremainder;
  lo = kr_addmul(a, b);
  hi = kr_rdhireg();
  check("addmul(DEADBEEF,CAFEBABE)+12345678 lo", lo, ref_lo);
  check("addmul(DEADBEEF,CAFEBABE)+12345678 hi", hi, ref_hi);
}

// ============================================================================
// Test: DIVDW
// ============================================================================
static void test_divdw(void) {
  neorv32_uart0_printf("\n--- DIVDW ---\n");

  // Simple division: 100 / 7 = 14 remainder 2
  kr_wrhireg(0);
  uint32_t q = kr_divdw(100, 7);
  uint32_t rem = kr_rdhireg();
  check("divdw(100,7) q=14", q, 14);
  check("divdw(100,7) rem=2", rem, 2);

  // Double-width division: {1, 0} / 3 = 0x55555555, remainder 1
  // {hireg=1, rs1=0} means dividend = 2^32, divisor = 3
  // 2^32 / 3 = 1431655765 = 0x55555555, remainder 1
  kr_wrhireg(1);
  q = kr_divdw(0, 3);
  rem = kr_rdhireg();
  check("divdw({1,0}/3) q=0x55555555", q, 0x55555555);
  check("divdw({1,0}/3) rem=1", rem, 1);

  // Exact division: 256 / 16 = 16, remainder 0
  kr_wrhireg(0);
  q = kr_divdw(256, 16);
  rem = kr_rdhireg();
  check("divdw(256,16) q=16", q, 16);
  check("divdw(256,16) rem=0", rem, 0);

  // Large division
  kr_wrhireg(0);
  q = kr_divdw(0xFFFFFFFF, 0xFFFFFFFF);
  rem = kr_rdhireg();
  check("divdw(max,max) q=1", q, 1);
  check("divdw(max,max) rem=0", rem, 0);
}

// ============================================================================
// Test: CLZ
// ============================================================================
static void test_clz(void) {
  neorv32_uart0_printf("\n--- CLZ ---\n");

  check("clz(0)=32", kr_clz(0), 32);
  check("clz(1)=31", kr_clz(1), 31);
  check("clz(2)=30", kr_clz(2), 30);
  check("clz(0x80000000)=0", kr_clz(0x80000000), 0);
  check("clz(0x7FFFFFFF)=1", kr_clz(0x7FFFFFFF), 1);
  check("clz(0x00010000)=15", kr_clz(0x00010000), 15);
  check("clz(0x000000FF)=24", kr_clz(0x000000FF), 24);

  // Compare against reference
  uint32_t vals[] = {0, 1, 0xFF, 0x100, 0xDEAD, 0xBEEF0000, 0xFFFFFFFF, 42};
  for (int i = 0; i < 8; i++) {
    uint32_t hw = kr_clz(vals[i]);
    uint32_t sw = ref_clz(vals[i]);
    check("clz_ref", hw, sw);
  }
}

// ============================================================================
// Test: HIREG read/write
// ============================================================================
static void test_hireg(void) {
  neorv32_uart0_printf("\n--- HIREG ---\n");

  // Write and read back
  kr_wrhireg(0xDEADBEEF);
  check("hireg write/read", kr_rdhireg(), 0xDEADBEEF);

  // WRHIREG returns old value
  uint32_t old = kr_wrhireg(0x12345678);
  check("wrhireg returns old", old, 0xDEADBEEF);
  check("hireg new value", kr_rdhireg(), 0x12345678);
}

// ============================================================================
// Test: Multi-precision multiply
// ============================================================================
static void test_mpn_mul(void) {
  neorv32_uart0_printf("\n--- MPN MUL ---\n");

  // 64-bit * 64-bit = 128-bit
  // 0x00000001_00000000 * 0x00000001_00000000 = 0x00000000_00000001_00000000_00000000
  uint32_t a[2] = {0x00000000, 0x00000001}; // 2^32 (little-endian)
  uint32_t b[2] = {0x00000000, 0x00000001}; // 2^32
  uint32_t r[4] = {0};
  kr_mpn_mul(r, a, 2, b, 2);
  check("mpn_mul 2^32*2^32 [0]", r[0], 0);
  check("mpn_mul 2^32*2^32 [1]", r[1], 0);
  check("mpn_mul 2^32*2^32 [2]", r[2], 1); // 2^64
  check("mpn_mul 2^32*2^32 [3]", r[3], 0);

  // Small numbers: 0x12345678 * 0x9ABCDEF0
  uint32_t c[1] = {0x12345678};
  uint32_t d[1] = {0x9ABCDEF0};
  uint32_t e[2] = {0};
  kr_mpn_mul(e, c, 1, d, 1);
  // Reference: 0x12345678 * 0x9ABCDEF0
  uint32_t ref_lo = ref_mulll(0x12345678, 0x9ABCDEF0);
  uint32_t ref_hi = ref_hiremainder;
  check("mpn_mul single-word lo", e[0], ref_lo);
  check("mpn_mul single-word hi", e[1], ref_hi);
}

// ============================================================================
// Benchmark: compare CFU vs software multiply
// ============================================================================
static void bench_multiply(void) {
  neorv32_uart0_printf("\n--- BENCHMARK: 1000x mulll ---\n");
  uint32_t a = 0xDEADBEEF, b = 0xCAFEBABE;
  volatile uint32_t result;

  // Hardware (CFU)
  neorv32_cpu_csr_write(CSR_MCYCLE, 0);
  for (int i = 0; i < 1000; i++) {
    result = kr_mulfull(a, b);
    b = result ^ (uint32_t)i; // prevent optimization
  }
  uint32_t hw_cycles = neorv32_cpu_csr_read(CSR_MCYCLE);

  // Software reference
  a = 0xDEADBEEF; b = 0xCAFEBABE;
  neorv32_cpu_csr_write(CSR_MCYCLE, 0);
  for (int i = 0; i < 1000; i++) {
    result = ref_mulll(a, b);
    b = result ^ (uint32_t)i;
  }
  uint32_t sw_cycles = neorv32_cpu_csr_read(CSR_MCYCLE);

  neorv32_uart0_printf("  HW (CFU):  %u cycles for 1000 mulfull\n", hw_cycles);
  neorv32_uart0_printf("  SW (ref):  %u cycles for 1000 mulll\n", sw_cycles);
  if (sw_cycles > hw_cycles) {
    neorv32_uart0_printf("  Speedup:   %ux\n", sw_cycles / hw_cycles);
  }
}

// ============================================================================
// Main
// ============================================================================
int main(void) {
  neorv32_rte_setup();

  if (!neorv32_uart0_available()) return -1;
  neorv32_uart0_setup(BAUD_RATE, 0);

  if (!neorv32_cfu_available()) {
    neorv32_uart0_printf("ERROR: CFU not available!\n");
    return -1;
  }

  neorv32_uart0_printf("\n");
  neorv32_uart0_printf("============================================\n");
  neorv32_uart0_printf("  KR Bignum CFU — Validation Test Suite\n");
  neorv32_uart0_printf("  Kyudoka Research, 2026\n");
  neorv32_uart0_printf("============================================\n");

  test_hireg();
  test_addwc();
  test_mulfull();
  test_addmul();
  test_divdw();
  test_clz();
  test_mpn_mul();

  neorv32_uart0_printf("\n============================================\n");
  neorv32_uart0_printf("  Results: %u / %u tests passed\n", tests_pass, tests_run);
  neorv32_uart0_printf("============================================\n");

  if (tests_pass == tests_run) {
    neorv32_uart0_printf("  ALL TESTS PASSED\n\n");
  } else {
    neorv32_uart0_printf("  %u TESTS FAILED\n\n", tests_run - tests_pass);
  }

  bench_multiply();

  neorv32_uart0_printf("\nDone.\n");
  return 0;
}
