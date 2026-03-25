// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
// KR k-Length Computing — L1 Dispatch API
//
// Memory-mapped interface to the k-length decomposition engine.
// The RISC-V core writes operands to shared BRAM, configures the
// decomposition engine via registers, and waits for completion.

#ifndef KR_KLENGTH_H
#define KR_KLENGTH_H

#include <stdint.h>

// ============================================================================
// Register addresses (relative to KLENGTH_BASE)
// ============================================================================
#ifndef KLENGTH_BASE
#define KLENGTH_BASE   0xF0000000  // NEORV32 XBUS / CFS region
#endif

#ifndef KLENGTH_BRAM_BASE
#define KLENGTH_BRAM_BASE 0xF0010000  // Shared BRAM base address
#endif

#define KLENGTH_REG(off) (*(volatile uint32_t *)(KLENGTH_BASE + (off)))

#define REG_CMD_OPCODE    KLENGTH_REG(0x00)
#define REG_CMD_SRC_A     KLENGTH_REG(0x04)
#define REG_CMD_SRC_B     KLENGTH_REG(0x08)
#define REG_CMD_DST       KLENGTH_REG(0x0C)
#define REG_CMD_LEN_A     KLENGTH_REG(0x10)
#define REG_CMD_LEN_B     KLENGTH_REG(0x14)
#define REG_CMD_CONTROL   KLENGTH_REG(0x18)
#define REG_CMD_STATUS    KLENGTH_REG(0x1C)
#define REG_CMD_PROGRESS  KLENGTH_REG(0x20)
#define REG_CMD_CYCLES    KLENGTH_REG(0x24)
#define REG_CMD_MAGIC     KLENGTH_REG(0x28)

#define KLENGTH_MAGIC     0x4B4C454E  // "KLEN"

// Operation codes
#define KLENGTH_OP_MPADD  0
#define KLENGTH_OP_MPSUB  1
#define KLENGTH_OP_MPMUL  2

// Status bits
#define KLENGTH_STATUS_BUSY  (1 << 0)
#define KLENGTH_STATUS_DONE  (1 << 1)

// ============================================================================
// BRAM operand memory layout (word addresses, not byte)
// ============================================================================
// 0x0000 - 0x0FFF: Operand A (up to 4096 words = 131,072 bits)
// 0x1000 - 0x1FFF: Operand B
// 0x2000 - 0x3FFF: Result (up to 8192 words)

#define BRAM_OPERAND_A   0x0000
#define BRAM_OPERAND_B   0x1000
#define BRAM_RESULT      0x2000

// Access shared BRAM as an array of uint32_t
#define BRAM_WORD(addr) (*(volatile uint32_t *)(KLENGTH_BRAM_BASE + ((addr) << 2)))

// ============================================================================
// Core API
// ============================================================================

// Check if k-length hardware is present
static inline int klength_available(void) {
    return REG_CMD_MAGIC == KLENGTH_MAGIC;
}

// Wait for engine to finish
static inline void klength_wait(void) {
    while (REG_CMD_STATUS & KLENGTH_STATUS_BUSY)
        ;
}

// Get cycle count of last operation
static inline uint32_t klength_cycles(void) {
    return REG_CMD_CYCLES;
}

// Get progress (issued << 16 | completed)
static inline uint32_t klength_progress(void) {
    return REG_CMD_PROGRESS;
}

// ============================================================================
// Multi-precision operations
// ============================================================================

// Load an operand into BRAM
static inline void klength_load(uint32_t bram_offset, const uint32_t *data, int len) {
    for (int i = 0; i < len; i++)
        BRAM_WORD(bram_offset + i) = data[i];
}

// Read result from BRAM
static inline void klength_read(uint32_t bram_offset, uint32_t *data, int len) {
    for (int i = 0; i < len; i++)
        data[i] = BRAM_WORD(bram_offset + i);
}

// MPADD: result = a + b (k-length addition)
// a, b, result are arrays of len 32-bit words (little-endian)
static inline uint32_t klength_mpadd(uint32_t *result, const uint32_t *a,
                                      const uint32_t *b, int len) {
    klength_load(BRAM_OPERAND_A, a, len);
    klength_load(BRAM_OPERAND_B, b, len);

    REG_CMD_OPCODE  = KLENGTH_OP_MPADD;
    REG_CMD_SRC_A   = BRAM_OPERAND_A;
    REG_CMD_SRC_B   = BRAM_OPERAND_B;
    REG_CMD_DST     = BRAM_RESULT;
    REG_CMD_LEN_A   = len;
    REG_CMD_LEN_B   = len;
    REG_CMD_CONTROL = 1;  // START

    klength_wait();
    klength_read(BRAM_RESULT, result, len);
    return klength_cycles();
}

// MPSUB: result = a - b (k-length subtraction)
static inline uint32_t klength_mpsub(uint32_t *result, const uint32_t *a,
                                      const uint32_t *b, int len) {
    klength_load(BRAM_OPERAND_A, a, len);
    klength_load(BRAM_OPERAND_B, b, len);

    REG_CMD_OPCODE  = KLENGTH_OP_MPSUB;
    REG_CMD_SRC_A   = BRAM_OPERAND_A;
    REG_CMD_SRC_B   = BRAM_OPERAND_B;
    REG_CMD_DST     = BRAM_RESULT;
    REG_CMD_LEN_A   = len;
    REG_CMD_LEN_B   = len;
    REG_CMD_CONTROL = 1;

    klength_wait();
    klength_read(BRAM_RESULT, result, len);
    return klength_cycles();
}

// MPMUL: result = a * b (k-length multiplication)
// Result is len_a + len_b words long.
static inline uint32_t klength_mpmul(uint32_t *result, const uint32_t *a, int len_a,
                                      const uint32_t *b, int len_b) {
    klength_load(BRAM_OPERAND_A, a, len_a);
    klength_load(BRAM_OPERAND_B, b, len_b);

    // Clear result buffer (multiply accumulates into it)
    for (int i = 0; i < len_a + len_b; i++)
        BRAM_WORD(BRAM_RESULT + i) = 0;

    REG_CMD_OPCODE  = KLENGTH_OP_MPMUL;
    REG_CMD_SRC_A   = BRAM_OPERAND_A;
    REG_CMD_SRC_B   = BRAM_OPERAND_B;
    REG_CMD_DST     = BRAM_RESULT;
    REG_CMD_LEN_A   = len_a;
    REG_CMD_LEN_B   = len_b;
    REG_CMD_CONTROL = 1;

    klength_wait();
    klength_read(BRAM_RESULT, result, len_a + len_b);
    return klength_cycles();
}

#endif // KR_KLENGTH_H
