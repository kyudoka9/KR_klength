// ================================================================================ //
// KR k-Length Computing -- L1 Validation Test Suite                                //
// -------------------------------------------------------------------------------- //
// Tests MPADD and MPMUL dispatched through the decomposition engine.               //
// Validates hardware results against software reference implementations.           //
// Runs on NEORV32 bare-metal. Output via UART0.                                    //
//                                                                                  //
// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>                    //
// ================================================================================ //

#include <neorv32.h>
#include "kr_bignum.h"
#include "kr_klength.h"
#include "kr_progress.h"

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
        neorv32_uart0_printf("  FAIL %s: got 0x%x, expected 0x%x\n",
                             name, got, expected);
    }
}

// Check an entire multi-word result buffer against expected values.
// Returns 1 if all words match, 0 otherwise.
static int check_array(const char *name, const uint32_t *got,
                        const uint32_t *expected, int len) {
    int ok = 1;
    for (int i = 0; i < len; i++) {
        tests_run++;
        if (got[i] == expected[i]) {
            tests_pass++;
        } else {
            neorv32_uart0_printf("  FAIL %s[%d]: got 0x%x, expected 0x%x\n",
                                 name, i, got[i], expected[i]);
            ok = 0;
        }
    }
    return ok;
}

// Software reference addition: r = a + b, returns carry.
// All arrays are 'len' words, little-endian.
static uint32_t sw_mpadd(uint32_t *r, const uint32_t *a,
                          const uint32_t *b, int len) {
    uint32_t carry = 0;
    for (int i = 0; i < len; i++) {
        uint64_t sum = (uint64_t)a[i] + (uint64_t)b[i] + carry;
        r[i] = (uint32_t)sum;
        carry = (uint32_t)(sum >> 32);
    }
    return carry;
}

// Software reference multiplication using kr_mpn_mul() from kr_bignum.h
// (already available via the include).

// Simple deterministic PRNG for generating test data.
// xorshift32 -- lightweight, no library dependency.
static uint32_t prng_state = 0x12345678;
static uint32_t prng_next(void) {
    uint32_t x = prng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    prng_state = x;
    return x;
}

static void prng_fill(uint32_t *buf, int len) {
    for (int i = 0; i < len; i++)
        buf[i] = prng_next();
}

// ============================================================================
// Test: MPADD
// ============================================================================
static void test_mpadd(void) {
    neorv32_uart0_printf("\n--- MPADD ---\n");

    // ---- Simple: {1, 0} + {1, 0} = {2, 0} (2-word addition, no carry) ----
    {
        uint32_t a[2] = {1, 0};
        uint32_t b[2] = {1, 0};
        uint32_t r[2] = {0};
        uint32_t exp[2] = {2, 0};

        klength_mpadd(r, a, b, 2);
        check_array("mpadd simple", r, exp, 2);
    }

    // ---- Carry: {0xFFFFFFFF} + {1} = {0, 1} (carry into word 1) ----
    {
        uint32_t a[2] = {0xFFFFFFFF, 0};
        uint32_t b[2] = {1, 0};
        uint32_t r[2] = {0};
        uint32_t exp[2] = {0, 1};

        klength_mpadd(r, a, b, 2);
        check_array("mpadd carry", r, exp, 2);
    }

    // ---- Multi-word: carry propagation through 2 words ----
    // {0xFFFFFFFF, 0xFFFFFFFF, 0, 0} + {1, 0, 0, 0} = {0, 0, 1, 0}
    {
        uint32_t a[4] = {0xFFFFFFFF, 0xFFFFFFFF, 0, 0};
        uint32_t b[4] = {1, 0, 0, 0};
        uint32_t r[4] = {0};
        uint32_t exp[4] = {0, 0, 1, 0};

        klength_mpadd(r, a, b, 4);
        check_array("mpadd carry propagation", r, exp, 4);
    }

    // ---- Large: 64-word addition, compare against software loop ----
    {
        uint32_t a[64], b[64], r_hw[64], r_sw[64];

        prng_state = 0xABCD1234;
        prng_fill(a, 64);
        prng_fill(b, 64);

        klength_mpadd(r_hw, a, b, 64);
        sw_mpadd(r_sw, a, b, 64);

        check_array("mpadd 64-word", r_hw, r_sw, 64);
    }

    neorv32_uart0_printf("  MPADD tests done\n");
}

// ============================================================================
// Test: MPMUL
// ============================================================================
static void test_mpmul(void) {
    neorv32_uart0_printf("\n--- MPMUL ---\n");

    // ---- Simple: {6} x {7} = {42, 0} (1-word multiply) ----
    {
        uint32_t a[1] = {6};
        uint32_t b[1] = {7};
        uint32_t r[2] = {0};
        uint32_t exp[2] = {42, 0};

        klength_mpmul(r, a, 1, b, 1);
        check_array("mpmul 6*7", r, exp, 2);
    }

    // ---- 2-word: {0, 1} x {0, 1} = {0, 0, 0, 1} ----
    // 2^32 x 2^32 = 2^64
    {
        uint32_t a[2] = {0, 1};
        uint32_t b[2] = {0, 1};
        uint32_t r[4] = {0};
        uint32_t exp[4] = {0, 0, 0, 1};

        klength_mpmul(r, a, 2, b, 2);
        check_array("mpmul 2^32*2^32", r, exp, 4);
    }

    // ---- Known: {0xDEADBEEF} x {0xCAFEBABE} ----
    // Compute the reference value in software first.
    {
        uint32_t a[1] = {0xDEADBEEF};
        uint32_t b[1] = {0xCAFEBABE};
        uint32_t r_hw[2] = {0};
        uint32_t r_sw[2] = {0};

        kr_mpn_mul(r_sw, a, 1, b, 1);
        klength_mpmul(r_hw, a, 1, b, 1);

        check_array("mpmul DEADBEEF*CAFEBABE", r_hw, r_sw, 2);
    }

    // ---- Multi-word: 4-word x 4-word, compare against kr_mpn_mul() ----
    {
        uint32_t a[4] = {0x11111111, 0x22222222, 0x33333333, 0x44444444};
        uint32_t b[4] = {0x55555555, 0x66666666, 0x77777777, 0x88888888};
        uint32_t r_hw[8] = {0};
        uint32_t r_sw[8] = {0};

        kr_mpn_mul(r_sw, a, 4, b, 4);
        klength_mpmul(r_hw, a, 4, b, 4);

        check_array("mpmul 4x4 word", r_hw, r_sw, 8);
    }

    // ---- Large: 16-word x 16-word, compare against kr_mpn_mul() ----
    {
        uint32_t a[16], b[16], r_hw[32], r_sw[32];

        prng_state = 0xFEEDFACE;
        prng_fill(a, 16);
        prng_fill(b, 16);

        kr_mpn_mul(r_sw, a, 16, b, 16);
        klength_mpmul(r_hw, a, 16, b, 16);

        check_array("mpmul 16x16 word", r_hw, r_sw, 32);
    }

    neorv32_uart0_printf("  MPMUL tests done\n");
}

// ============================================================================
// Benchmark: klength_mpmul vs kr_mpn_mul (16 words)
// ============================================================================
static void bench_mpmul(void) {
    neorv32_uart0_printf("\n--- BENCHMARK: 100x mpmul(16 words) ---\n");

    uint32_t a[16], b[16], r[32];

    prng_state = 0xBAADF00D;
    prng_fill(a, 16);
    prng_fill(b, 16);

    // Hardware (k-length engine)
    neorv32_cpu_csr_write(CSR_MCYCLE, 0);
    for (int i = 0; i < 100; i++) {
        klength_mpmul(r, a, 16, b, 16);
        a[0] ^= r[0]; // vary input slightly to prevent any caching
    }
    uint32_t hw_cycles = neorv32_cpu_csr_read(CSR_MCYCLE);

    // Reset operands
    prng_state = 0xBAADF00D;
    prng_fill(a, 16);
    prng_fill(b, 16);

    // Software (kr_mpn_mul using CFU instructions)
    neorv32_cpu_csr_write(CSR_MCYCLE, 0);
    for (int i = 0; i < 100; i++) {
        kr_mpn_mul(r, a, 16, b, 16);
        a[0] ^= r[0];
    }
    uint32_t sw_cycles = neorv32_cpu_csr_read(CSR_MCYCLE);

    neorv32_uart0_printf("  HW (k-length): %u cycles for 100 x mpmul(16)\n",
                         hw_cycles);
    neorv32_uart0_printf("  SW (mpn_mul):   %u cycles for 100 x mpn_mul(16)\n",
                         sw_cycles);
    if (hw_cycles > 0) {
        uint32_t ratio = sw_cycles / hw_cycles;
        uint32_t frac  = ((sw_cycles % hw_cycles) * 10) / hw_cycles;
        neorv32_uart0_printf("  Speedup:        %u.%ux\n", ratio, frac);
    }
}

// ============================================================================
// Progress API test: poll progress during a large MPMUL
// ============================================================================
static void test_progress(void) {
    neorv32_uart0_printf("\n--- PROGRESS API ---\n");

    uint32_t a[32], b[32];

    prng_state = 0xCAFED00D;
    prng_fill(a, 32);
    prng_fill(b, 32);

    // Load operands and dispatch manually (non-blocking) so we can poll
    klength_load(BRAM_OPERAND_A, a, 32);
    klength_load(BRAM_OPERAND_B, b, 32);

    for (int i = 0; i < 64; i++)
        BRAM_WORD(BRAM_RESULT + i) = 0;

    REG_CMD_OPCODE  = KLENGTH_OP_MPMUL;
    REG_CMD_SRC_A   = BRAM_OPERAND_A;
    REG_CMD_SRC_B   = BRAM_OPERAND_B;
    REG_CMD_DST     = BRAM_RESULT;
    REG_CMD_LEN_A   = 32;
    REG_CMD_LEN_B   = 32;
    REG_CMD_CONTROL = 1; // START

    // Poll progress several times while the operation runs
    uint32_t prev_percent = 0;
    int monotonic = 1;
    int samples = 0;

    neorv32_uart0_printf("  Polling 32x32 MPMUL progress:\n");

    for (int poll = 0; poll < 20; poll++) {
        kr_op_progress_t p = kr_op_progress();

        neorv32_uart0_printf("    poll %d: %u%% (%u/%u uops) busy=%u done=%u\n",
                             poll, p.percent,
                             p.uops_completed, p.uops_issued,
                             p.busy, p.done);
        samples++;

        // Check monotonicity
        if (p.percent < prev_percent) {
            neorv32_uart0_printf("  FAIL: progress decreased from %u to %u%%\n",
                                 prev_percent, p.percent);
            monotonic = 0;
        }
        prev_percent = p.percent;

        if (p.done)
            break;

        // Small busy-wait between polls so we don't just blast the register
        for (volatile int d = 0; d < 200; d++) {}
    }

    // Ensure engine is finished
    klength_wait();

    // Read back result and verify against software
    uint32_t r_hw[64], r_sw[64];
    klength_read(BRAM_RESULT, r_hw, 64);
    kr_mpn_mul(r_sw, a, 32, b, 32);

    int result_ok = check_array("progress mpmul 32x32", r_hw, r_sw, 64);

    tests_run++;
    if (monotonic) {
        tests_pass++;
    } else {
        neorv32_uart0_printf("  FAIL progress monotonicity\n");
    }

    neorv32_uart0_printf("  Progress polling: %d samples, monotonic=%s, result=%s\n",
                         samples,
                         monotonic ? "yes" : "NO",
                         result_ok ? "correct" : "MISMATCH");
}

// ============================================================================
// Main
// ============================================================================
int main(void) {
    neorv32_rte_setup();

    if (!neorv32_uart0_available()) return -1;
    neorv32_uart0_setup(BAUD_RATE, 0);

    neorv32_uart0_printf("\n");
    neorv32_uart0_printf("============================================\n");
    neorv32_uart0_printf("  KR k-Length Computing\n");
    neorv32_uart0_printf("  L1 Validation Test Suite\n");
    neorv32_uart0_printf("  Kyudoka Research, 2026\n");
    neorv32_uart0_printf("============================================\n");

    // Check hardware presence
    if (!klength_available()) {
        neorv32_uart0_printf("ERROR: k-length engine not detected!\n");
        neorv32_uart0_printf("  (REG_CMD_MAGIC = 0x%x, expected 0x%x)\n",
                             REG_CMD_MAGIC, KLENGTH_MAGIC);
        return -1;
    }
    neorv32_uart0_printf("  k-length engine detected (magic OK)\n");

    // Functional tests
    test_mpadd();
    test_mpmul();

    // Summary
    neorv32_uart0_printf("\n============================================\n");
    neorv32_uart0_printf("  Results: %u / %u tests passed\n",
                         tests_pass, tests_run);
    neorv32_uart0_printf("============================================\n");

    if (tests_pass == tests_run) {
        neorv32_uart0_printf("  ALL TESTS PASSED\n");
    } else {
        neorv32_uart0_printf("  %u TESTS FAILED\n", tests_run - tests_pass);
    }

    // Benchmark
    bench_mpmul();

    // Progress API
    test_progress();

    neorv32_uart0_printf("\nDone.\n");
    return 0;
}
