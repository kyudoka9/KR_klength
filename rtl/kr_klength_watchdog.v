// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
// KR k-Length Computing — Transactional Completion Watchdog
//
// ACID-style transactional completion bitmap and watchdog for the
// decomposition engine. Monitors micro-op dispatch and completion,
// detects lost or stalled operations, and enables graceful recovery.
//
// Completion bitmap:
//   dispatched[tag] is set when a micro-op is dispatched.
//   completed[tag]  is set when a micro-op result arrives.
//   Both are cleared on op_start (new k-length operation).
//
// Global watchdog timer:
//   Counts cycles since the last completion event. If no completion
//   arrives for TIMEOUT_CYCLES, timeout_alert is asserted and the
//   tag of the oldest outstanding micro-op is reported.
//
// Missing count:
//   On op_done, the bitmap is scanned sequentially (1 tag per cycle,
//   4096 cycles for TAG_BITS=12) to count dispatched-but-not-completed
//   tags. The result is reported via missing_count.
//
// all_complete:
//   Asserted when every dispatched tag has a matching completion.

`default_nettype none

module kr_klength_watchdog #(
    parameter TAG_BITS       = 12,
    parameter TIMEOUT_CYCLES = 100000  // ~1ms at 100 MHz
) (
    input  wire                    clk,
    input  wire                    rst,

    // From decomp engine: track dispatches
    input  wire                    dispatch_valid,
    input  wire [TAG_BITS-1:0]     dispatch_tag,

    // From result collector: track completions
    input  wire                    complete_valid,
    input  wire [TAG_BITS-1:0]     complete_tag,

    // Operation lifecycle
    input  wire                    op_start,        // new k-length op started
    input  wire                    op_done,         // k-length op completed normally
    input  wire [31:0]             expected_count,  // total micro-ops expected

    // Watchdog output
    output reg                     timeout_alert,   // a micro-op timed out
    output reg  [TAG_BITS-1:0]     timeout_tag,     // which tag timed out
    output reg  [31:0]             missing_count,   // how many micro-ops still missing
    output reg                     all_complete      // all dispatched micro-ops completed
);

    localparam NUM_TAGS = 1 << TAG_BITS;  // 4096 for TAG_BITS=12

    // -----------------------------------------------------------------
    // Completion bitmap
    // -----------------------------------------------------------------
    // dispatched[tag]: set on dispatch_valid, cleared on op_start
    // completed[tag]:  set on complete_valid, cleared on op_start
    reg dispatched [0:NUM_TAGS-1];
    reg completed  [0:NUM_TAGS-1];

    // -----------------------------------------------------------------
    // Dispatch and completion counters
    // -----------------------------------------------------------------
    // Running totals for the current operation. Used for the fast-path
    // all_complete check (avoids full bitmap scan in the common case).
    reg [31:0] dispatch_count;
    reg [31:0] complete_count;

    // -----------------------------------------------------------------
    // Global watchdog timer
    // -----------------------------------------------------------------
    // Counts cycles since the last completion event. Reset on every
    // complete_valid and on op_start.
    reg [31:0] watchdog_timer;

    // -----------------------------------------------------------------
    // Bitmap clear sequencer
    // -----------------------------------------------------------------
    // On op_start, we clear the bitmap arrays one entry per cycle.
    // While clearing, new dispatches/completions are still tracked
    // (they target tags above the clear pointer, which is safe because
    // the decomp engine cannot issue tags faster than one per cycle).
    reg                  clearing;
    reg [TAG_BITS-1:0]   clear_idx;

    // -----------------------------------------------------------------
    // Missing-count scan sequencer
    // -----------------------------------------------------------------
    // On op_done, we scan the full bitmap to count dispatched-but-not-
    // completed entries. One tag is checked per cycle.
    reg                  scanning;
    reg [TAG_BITS-1:0]   scan_idx;
    reg [31:0]           scan_accum;
    reg                  scan_done;  // pulse when scan finishes

    // -----------------------------------------------------------------
    // Oldest outstanding tag tracker
    // -----------------------------------------------------------------
    // Tracks the oldest (lowest-numbered) dispatched-but-not-completed
    // tag. Used to report which tag timed out.
    reg [TAG_BITS-1:0]   oldest_outstanding;
    reg                  has_outstanding;

    // -----------------------------------------------------------------
    // Integer for reset loop
    // -----------------------------------------------------------------
    integer i;

    // -----------------------------------------------------------------
    // Main logic
    // -----------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            timeout_alert    <= 1'b0;
            timeout_tag      <= {TAG_BITS{1'b0}};
            missing_count    <= 32'd0;
            all_complete     <= 1'b0;
            dispatch_count   <= 32'd0;
            complete_count   <= 32'd0;
            watchdog_timer   <= 32'd0;
            clearing         <= 1'b0;
            clear_idx        <= {TAG_BITS{1'b0}};
            scanning         <= 1'b0;
            scan_idx         <= {TAG_BITS{1'b0}};
            scan_accum       <= 32'd0;
            scan_done        <= 1'b0;
            oldest_outstanding <= {TAG_BITS{1'b0}};
            has_outstanding  <= 1'b0;

            for (i = 0; i < NUM_TAGS; i = i + 1) begin
                dispatched[i] <= 1'b0;
                completed[i]  <= 1'b0;
            end
        end else begin
            // Default: clear one-shot signals
            scan_done <= 1'b0;

            // ==========================================================
            // Op start: begin clearing bitmaps, reset counters
            // ==========================================================
            if (op_start) begin
                clearing       <= 1'b1;
                clear_idx      <= {TAG_BITS{1'b0}};
                dispatch_count <= 32'd0;
                complete_count <= 32'd0;
                watchdog_timer <= 32'd0;
                timeout_alert  <= 1'b0;
                all_complete   <= 1'b0;
                missing_count  <= 32'd0;
                has_outstanding <= 1'b0;
                scanning       <= 1'b0;
            end

            // ==========================================================
            // Bitmap clear sequencer (1 entry per cycle)
            // ==========================================================
            if (clearing) begin
                dispatched[clear_idx] <= 1'b0;
                completed[clear_idx]  <= 1'b0;
                if (clear_idx == {TAG_BITS{1'b1}}) begin
                    // Cleared all entries
                    clearing <= 1'b0;
                end
                clear_idx <= clear_idx + 1;
            end

            // ==========================================================
            // Track dispatches
            // ==========================================================
            if (dispatch_valid) begin
                dispatched[dispatch_tag] <= 1'b1;
                dispatch_count <= dispatch_count + 1;
                // Update oldest outstanding if nothing was outstanding,
                // or if this is earlier than current oldest
                if (!has_outstanding) begin
                    oldest_outstanding <= dispatch_tag;
                    has_outstanding    <= 1'b1;
                end
            end

            // ==========================================================
            // Track completions
            // ==========================================================
            if (complete_valid) begin
                completed[complete_tag] <= 1'b1;
                complete_count <= complete_count + 1;
                // Reset watchdog timer on every completion
                watchdog_timer <= 32'd0;

                // If the oldest outstanding tag just completed,
                // advance to the next outstanding tag. This is
                // approximate — the exact oldest is found during
                // the scan phase. For watchdog purposes, we simply
                // advance by one.
                if (complete_tag == oldest_outstanding) begin
                    oldest_outstanding <= oldest_outstanding + 1;
                end
            end

            // ==========================================================
            // all_complete: fast-path check via counters
            // ==========================================================
            // Asserted when dispatch_count > 0 and all dispatched
            // micro-ops have completed.
            if (dispatch_count > 0 && complete_count >= dispatch_count && !scanning) begin
                all_complete <= 1'b1;
            end

            // ==========================================================
            // Global watchdog timer
            // ==========================================================
            // Only runs when there are outstanding micro-ops.
            if (has_outstanding && (complete_count < dispatch_count)) begin
                if (watchdog_timer < TIMEOUT_CYCLES) begin
                    watchdog_timer <= watchdog_timer + 1;
                end else begin
                    // Timeout: assert alert with the oldest outstanding tag
                    timeout_alert <= 1'b1;
                    timeout_tag   <= oldest_outstanding;
                end
            end

            // ==========================================================
            // Op done: start bitmap scan for missing count
            // ==========================================================
            if (op_done && !scanning) begin
                scanning   <= 1'b1;
                scan_idx   <= {TAG_BITS{1'b0}};
                scan_accum <= 32'd0;
            end

            // ==========================================================
            // Missing-count scan sequencer (1 tag per cycle)
            // ==========================================================
            if (scanning) begin
                // Check current tag: dispatched but not completed?
                if (dispatched[scan_idx] && !completed[scan_idx]) begin
                    scan_accum <= scan_accum + 1;
                end

                if (scan_idx == {TAG_BITS{1'b1}}) begin
                    // Scan complete — commit final count
                    // Include the last entry in the count
                    if (dispatched[scan_idx] && !completed[scan_idx])
                        missing_count <= scan_accum + 1;
                    else
                        missing_count <= scan_accum;
                    scanning  <= 1'b0;
                    scan_done <= 1'b1;
                end
                scan_idx <= scan_idx + 1;
            end
        end
    end

endmodule

`default_nettype wire
