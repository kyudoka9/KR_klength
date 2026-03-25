// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
// KR k-Length Computing — Progress Reporting API
//
// Reads hardware instrumentation counters from the decomposition engine
// and scheduler to provide real-time progress, ETA, and throughput for
// k-length operations and multi-step algorithms.
//
// Two levels:
//   1. Operation-level: "this MPMUL is 75% done, 12ms remaining"
//   2. Algorithm-level: "ECM curve 47 of ~2200, 3m 12s remaining"
//
// The hardware already has the counters (uops_issued, uops_completed,
// cycle_count). This API just reads them and does the math.

#ifndef KR_PROGRESS_H
#define KR_PROGRESS_H

#include <stdint.h>
#include "kr_klength.h"

// ============================================================================
// Clock frequency (must match hardware)
// ============================================================================
#ifndef KR_CLOCK_HZ
#define KR_CLOCK_HZ 125000000  // 125 MHz (Mimas A7 scheduler clock)
#endif

// ============================================================================
// Operation-level progress (L1 — single k-length dispatch)
// ============================================================================

typedef struct {
    uint32_t uops_issued;      // total micro-ops for this operation
    uint32_t uops_completed;   // micro-ops finished so far
    uint32_t cycles_elapsed;   // cycles since dispatch
    uint32_t percent;          // 0-100
    uint32_t eta_ms;           // estimated time remaining (milliseconds)
    uint32_t throughput;       // micro-ops per second (actual measured)
    uint8_t  busy;             // 1 if operation in progress
    uint8_t  done;             // 1 if operation complete
} kr_op_progress_t;

// Snapshot current operation progress from hardware registers.
// Call this in a polling loop (does NOT block).
static inline kr_op_progress_t kr_op_progress(void) {
    kr_op_progress_t p;
    uint32_t status = REG_CMD_STATUS;
    uint32_t prog   = REG_CMD_PROGRESS;

    p.busy           = (status & KLENGTH_STATUS_BUSY) ? 1 : 0;
    p.done           = (status & KLENGTH_STATUS_DONE) ? 1 : 0;
    p.uops_issued    = prog >> 16;
    p.uops_completed = prog & 0xFFFF;
    p.cycles_elapsed = REG_CMD_CYCLES;

    if (p.uops_issued > 0) {
        p.percent = (p.uops_completed * 100) / p.uops_issued;
    } else {
        p.percent = p.done ? 100 : 0;
    }

    // Throughput: uops/sec based on elapsed cycles
    if (p.cycles_elapsed > 0 && p.uops_completed > 0) {
        // throughput = completed * clock_hz / elapsed_cycles
        // Avoid overflow: divide first
        p.throughput = (uint32_t)((uint64_t)p.uops_completed * KR_CLOCK_HZ
                                  / p.cycles_elapsed);
    } else {
        p.throughput = 0;
    }

    // ETA: remaining_uops / throughput
    if (p.throughput > 0 && p.uops_issued > p.uops_completed) {
        uint32_t remaining = p.uops_issued - p.uops_completed;
        p.eta_ms = (remaining * 1000) / p.throughput;
    } else {
        p.eta_ms = 0;
    }

    return p;
}

// ============================================================================
// Algorithm-level progress (L2 — multi-step algorithms like ECM, MPQS)
// ============================================================================

typedef struct {
    // Algorithm identification
    const char *algo_name;     // "ECM", "MPQS", "ECPP", "modexp", etc.

    // Step tracking
    uint32_t steps_done;       // iterations/curves/relations completed
    uint32_t steps_expected;   // estimated total (0 = unknown)

    // Timing
    uint32_t elapsed_ms;       // wall-clock time since algorithm start
    uint32_t avg_step_ms;      // running average of milliseconds per step
    uint32_t eta_ms;           // estimated time remaining

    // Derived
    uint32_t percent;          // 0-100 (0 if steps_expected unknown)

    // Sub-operation progress (current L1 operation within this step)
    kr_op_progress_t current_op;
} kr_algo_progress_t;

// Algorithm progress tracker state (caller allocates, pass to update functions)
typedef struct {
    const char *name;
    uint32_t steps_done;
    uint32_t steps_expected;
    uint32_t start_cycles;     // cycle counter at algorithm start
    uint32_t last_step_cycles; // cycle counter at last step completion
    uint64_t total_step_cycles; // accumulated step durations for averaging
} kr_algo_tracker_t;

// Initialize tracker at algorithm start.
// expected = estimated total steps (0 if unknown, e.g. probabilistic ECM)
static inline void kr_algo_begin(kr_algo_tracker_t *t, const char *name,
                                  uint32_t expected) {
    t->name             = name;
    t->steps_done       = 0;
    t->steps_expected   = expected;
    t->start_cycles     = REG_CMD_CYCLES;  // snapshot cycle counter
    t->last_step_cycles = t->start_cycles;
    t->total_step_cycles = 0;
}

// Call after each algorithm step completes (e.g., after each ECM curve).
static inline void kr_algo_step(kr_algo_tracker_t *t) {
    uint32_t now = REG_CMD_CYCLES;
    uint32_t step_duration = now - t->last_step_cycles;
    t->total_step_cycles += step_duration;
    t->last_step_cycles = now;
    t->steps_done++;
}

// Update expected count (e.g., when ECM moves to larger B1 bound).
static inline void kr_algo_set_expected(kr_algo_tracker_t *t, uint32_t expected) {
    t->steps_expected = expected;
}

// Snapshot algorithm progress. Non-blocking.
static inline kr_algo_progress_t kr_algo_progress(const kr_algo_tracker_t *t) {
    kr_algo_progress_t p;
    uint32_t now = REG_CMD_CYCLES;

    p.algo_name = t->name;
    p.steps_done = t->steps_done;
    p.steps_expected = t->steps_expected;

    // Elapsed time
    uint32_t elapsed_cycles = now - t->start_cycles;
    p.elapsed_ms = elapsed_cycles / (KR_CLOCK_HZ / 1000);

    // Average step time
    if (t->steps_done > 0) {
        uint32_t avg_cycles = (uint32_t)(t->total_step_cycles / t->steps_done);
        p.avg_step_ms = avg_cycles / (KR_CLOCK_HZ / 1000);
    } else {
        p.avg_step_ms = 0;
    }

    // Percentage and ETA
    if (t->steps_expected > 0) {
        p.percent = (t->steps_done * 100) / t->steps_expected;
        if (p.avg_step_ms > 0 && t->steps_expected > t->steps_done) {
            p.eta_ms = (t->steps_expected - t->steps_done) * p.avg_step_ms;
        } else {
            p.eta_ms = 0;
        }
    } else {
        p.percent = 0;  // unknown total
        p.eta_ms  = 0;
    }

    // Current sub-operation
    p.current_op = kr_op_progress();

    return p;
}

// ============================================================================
// Display functions (UART terminal output)
// ============================================================================

// Format milliseconds as human-readable time string.
// Writes to caller's buffer. Returns pointer to buf.
static inline char *kr_format_eta(uint32_t ms, char *buf, int buflen) {
    if (ms == 0) {
        buf[0] = '-'; buf[1] = '\0';
        return buf;
    }
    uint32_t sec = ms / 1000;
    uint32_t min = sec / 60;
    uint32_t hr  = min / 60;
    sec %= 60;
    min %= 60;

    if (hr > 0) {
        // "2h 14m 30s"
        int i = 0;
        if (hr >= 10) buf[i++] = '0' + (hr / 10);
        buf[i++] = '0' + (hr % 10);
        buf[i++] = 'h'; buf[i++] = ' ';
        buf[i++] = '0' + (min / 10);
        buf[i++] = '0' + (min % 10);
        buf[i++] = 'm'; buf[i++] = ' ';
        buf[i++] = '0' + (sec / 10);
        buf[i++] = '0' + (sec % 10);
        buf[i++] = 's'; buf[i] = '\0';
    } else if (min > 0) {
        // "14m 30s"
        int i = 0;
        if (min >= 10) buf[i++] = '0' + (min / 10);
        buf[i++] = '0' + (min % 10);
        buf[i++] = 'm'; buf[i++] = ' ';
        buf[i++] = '0' + (sec / 10);
        buf[i++] = '0' + (sec % 10);
        buf[i++] = 's'; buf[i] = '\0';
    } else {
        // "30s"
        int i = 0;
        if (sec >= 10) buf[i++] = '0' + (sec / 10);
        buf[i++] = '0' + (sec % 10);
        buf[i++] = 's'; buf[i] = '\0';
    }
    return buf;
}

// Print a progress bar to UART. Width = number of bar characters.
// Uses \r to overwrite the same line.
//
// Output example:
//   ECM (B1=1e6): curve 47/~2200 (2%)  eta: 3m 12s
//   ████░░░░░░░░░░░░░░░░░░░░░░░░░░  2%  [multiply 3102/4096 75%]
//
// Call this in a polling loop. Non-blocking.
#ifdef NEORV32_UART_AVAILABLE
#include <neorv32.h>

static inline void kr_progress_display(const kr_algo_progress_t *p, int bar_width) {
    char eta_buf[16];
    char op_eta_buf[16];

    kr_format_eta(p->eta_ms, eta_buf, sizeof(eta_buf));

    // Line 1: algorithm status
    neorv32_uart0_printf("\r\033[K");  // clear line
    neorv32_uart0_printf("  %s: ", p->algo_name);

    if (p->steps_expected > 0) {
        neorv32_uart0_printf("step %u/~%u (%u%%)  eta: %s",
            p->steps_done, p->steps_expected, p->percent, eta_buf);
    } else {
        neorv32_uart0_printf("step %u (total unknown)  elapsed: %s",
            p->steps_done, eta_buf);
    }

    // Line 2: progress bar + sub-operation
    neorv32_uart0_printf("\n\r\033[K  ");

    // Bar
    int filled = (p->percent * bar_width) / 100;
    for (int i = 0; i < bar_width; i++) {
        neorv32_uart0_putc(i < filled ? '#' : '.');
    }

    neorv32_uart0_printf(" %u%%", p->percent);

    // Sub-operation (current L1 dispatch)
    if (p->current_op.busy) {
        neorv32_uart0_printf("  [uop %u/%u %u%%]",
            p->current_op.uops_completed,
            p->current_op.uops_issued,
            p->current_op.percent);
    }

    // Move cursor back up one line for next update
    neorv32_uart0_printf("\033[A");
}

#endif // NEORV32_UART_AVAILABLE

// ============================================================================
// Convenience: ECM expected curve count
// ============================================================================
// Rough estimate for ECM: expected number of curves to find a factor
// of d digits using smoothness bound B1.
// Based on L(d) = exp(sqrt(2 * ln(10^d) * ln(ln(10^d))))
// This is approximate but gives a useful progress bar.
//
// Precomputed for common digit ranges (avoids floating point):
static inline uint32_t kr_ecm_expected_curves(int factor_digits, uint32_t B1) {
    // Very rough table: expected curves for given factor size
    // Source: GMP-ECM recommended parameters
    if (factor_digits <= 15) return 25;
    if (factor_digits <= 20) return 90;
    if (factor_digits <= 25) return 300;
    if (factor_digits <= 30) return 700;
    if (factor_digits <= 35) return 1800;
    if (factor_digits <= 40) return 5100;
    if (factor_digits <= 45) return 10600;
    if (factor_digits <= 50) return 19300;
    if (factor_digits <= 55) return 49000;
    if (factor_digits <= 60) return 124000;
    if (factor_digits <= 65) return 210000;
    return 500000; // > 65 digits: a lot of curves
}

#endif // KR_PROGRESS_H
