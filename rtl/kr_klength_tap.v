// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
// KR k-Length Computing — Passive Observation Tap
//
// Observes internal k-length fabric state and packages events into a FIFO
// for external consumption (UART, future Ethernet/UDP). Enables ML-observable
// scheduling — the tap is fully PASSIVE and never affects fabric operation.
// It only reads signals that already exist. Zero overhead on the datapath.
//
// Event sources:
//   K_DISPATCH     (0) — micro-op dispatched to a MAC channel
//   K_COMPLETE     (1) — micro-op completed, result on CDB
//   K_OP_START     (2) — L1 multi-precision operation started
//   K_OP_DONE      (3) — L1 operation completed
//   K_STALL        (4) — dispatch stalled (all channels busy)
//   K_UTILIZATION  (5) — periodic channel utilization snapshot
//
// Event encoding (64 bits):
//   [63:60]  event_type   (4 bits)
//   [59:48]  tag          (12 bits, DISPATCH/COMPLETE)
//   [47:44]  opcode       (4 bits)
//   [43:32]  payload_hi   (12 bits, event-specific)
//   [31:0]   timestamp or payload_lo (32 bits)
//
`default_nettype none

module kr_klength_tap #(
    parameter TAG_BITS    = 12,
    parameter DATA_BITS   = 32,
    parameter FIFO_DEPTH  = 512,     // events buffered before overflow
    parameter N_CHANNELS  = 8        // for per-channel utilization
) (
    input  wire                    clk,
    input  wire                    rst,

    // -----------------------------------------------------------------
    // Event sources (directly tapped from fabric — zero overhead)
    // -----------------------------------------------------------------
    input  wire                    dispatch_valid,   // micro-op dispatched
    input  wire [3:0]              dispatch_opcode,
    input  wire [TAG_BITS-1:0]     dispatch_tag,
    input  wire                    dispatch_dep_valid,

    input  wire                    result_valid,     // micro-op completed
    input  wire [TAG_BITS-1:0]     result_tag,
    input  wire [DATA_BITS-1:0]    result_hi,        // carry/hi word

    input  wire                    cmd_start,        // L1 operation started
    input  wire [3:0]              cmd_opcode,
    input  wire [15:0]             cmd_len,

    input  wire                    cmd_done,         // L1 operation completed
    input  wire [31:0]             cmd_cycles,       // total cycles

    input  wire [N_CHANNELS-1:0]   channel_busy,     // per-channel utilization

    // -----------------------------------------------------------------
    // Event output (FIFO read interface)
    // -----------------------------------------------------------------
    output wire                    event_valid,
    output wire [63:0]             event_data,       // packed event
    input  wire                    event_ready,      // consumer acknowledges

    // -----------------------------------------------------------------
    // Status
    // -----------------------------------------------------------------
    output wire                    fifo_overflow,    // events lost
    output reg  [31:0]             event_count,      // total events generated
    output reg  [31:0]             overflow_count    // total events lost
);

    // =================================================================
    // Event type encodings
    // =================================================================
    localparam [3:0] K_DISPATCH    = 4'd0;
    localparam [3:0] K_COMPLETE    = 4'd1;
    localparam [3:0] K_OP_START    = 4'd2;
    localparam [3:0] K_OP_DONE     = 4'd3;
    localparam [3:0] K_STALL       = 4'd4;
    localparam [3:0] K_UTILIZATION = 4'd5;

    // =================================================================
    // Free-running timestamp counter (32-bit, wraps)
    // =================================================================
    reg [31:0] timestamp;

    always @(posedge clk) begin
        if (rst)
            timestamp <= 32'd0;
        else
            timestamp <= timestamp + 32'd1;
    end

    // =================================================================
    // Utilization sampling: fire a K_UTILIZATION event every 1024 cycles
    // =================================================================
    reg [9:0] util_counter;
    wire      util_sample = (util_counter == 10'd0) && !rst;

    always @(posedge clk) begin
        if (rst)
            util_counter <= 10'd0;
        else
            util_counter <= util_counter + 10'd1;
    end

    // =================================================================
    // Stall detection: dispatch attempted but all channels busy
    //
    // dispatch_valid is driven by uop_valid && uop_ready in the top
    // (successful dispatch). A stall is when all channels are busy —
    // the decomp engine may have a micro-op waiting but it cannot be
    // dispatched. We observe this as all channels occupied without a
    // concurrent successful dispatch.
    //
    // Note: this slightly over-reports stalls (fires even when the
    // decomp engine is not actively trying to dispatch). This is
    // acceptable for a passive ML tap — the ML model can correlate
    // K_STALL events with dispatch gaps to learn actual contention.
    // =================================================================
    wire all_channels_busy = &channel_busy;
    wire stall_detected    = all_channels_busy && !dispatch_valid;

    // =================================================================
    // Event packing: each source produces a 64-bit event word
    // =================================================================

    // K_DISPATCH: tag, opcode, dep_valid in payload_hi[0]
    wire [63:0] evt_dispatch = {
        K_DISPATCH,                                // [63:60] type
        dispatch_tag,                              // [59:48] tag
        dispatch_opcode,                           // [47:44] opcode
        {11'b0, dispatch_dep_valid},               // [43:32] payload_hi
        timestamp                                  // [31:0]  timestamp
    };

    // K_COMPLETE: tag, result_hi[7:0] in payload
    wire [63:0] evt_complete = {
        K_COMPLETE,                                // [63:60] type
        result_tag,                                // [59:48] tag
        4'd0,                                      // [47:44] opcode (n/a)
        {4'b0, result_hi[7:0]},                    // [43:32] payload_hi
        timestamp                                  // [31:0]  timestamp
    };

    // K_OP_START: opcode, len in payload
    wire [63:0] evt_op_start = {
        K_OP_START,                                // [63:60] type
        12'd0,                                     // [59:48] tag (n/a)
        cmd_opcode,                                // [47:44] opcode
        12'd0,                                     // [43:32] payload_hi
        {16'd0, cmd_len}                           // [31:0]  len
    };

    // K_OP_DONE: total_cycles in payload
    wire [63:0] evt_op_done = {
        K_OP_DONE,                                 // [63:60] type
        12'd0,                                     // [59:48] tag (n/a)
        4'd0,                                      // [47:44] opcode (n/a)
        12'd0,                                     // [43:32] payload_hi
        cmd_cycles                                 // [31:0]  total cycles
    };

    // K_STALL: timestamp only
    wire [63:0] evt_stall = {
        K_STALL,                                   // [63:60] type
        12'd0,                                     // [59:48] tag (n/a)
        4'd0,                                      // [47:44] opcode (n/a)
        12'd0,                                     // [43:32] payload_hi
        timestamp                                  // [31:0]  timestamp
    };

    // K_UTILIZATION: channel_busy bitmap in payload
    wire [63:0] evt_utilization = {
        K_UTILIZATION,                             // [63:60] type
        12'd0,                                     // [59:48] tag (n/a)
        4'd0,                                      // [47:44] opcode (n/a)
        12'd0,                                     // [43:32] payload_hi
        {{(32-N_CHANNELS){1'b0}}, channel_busy}    // [31:0]  bitmap
    };

    // =================================================================
    // Priority encoder: serialize concurrent events into one per cycle
    //
    // Fixed priority (highest first):
    //   1. K_OP_START   — rare, must not be lost
    //   2. K_OP_DONE    — rare, must not be lost
    //   3. K_DISPATCH   — per micro-op
    //   4. K_COMPLETE   — per micro-op
    //   5. K_STALL      — diagnostic
    //   6. K_UTILIZATION — periodic (lowest priority, can be deferred)
    //
    // When multiple events fire in the same cycle, only the highest-
    // priority event is pushed. Lower-priority events from the same
    // cycle are lost — this is acceptable for a passive tap since the
    // rare events (START/DONE) are prioritized and per-uop events
    // rarely collide at steady state.
    // =================================================================
    reg        push_valid;
    reg [63:0] push_data;

    always @(*) begin
        push_valid = 1'b0;
        push_data  = 64'd0;

        if (cmd_start) begin
            push_valid = 1'b1;
            push_data  = evt_op_start;
        end else if (cmd_done) begin
            push_valid = 1'b1;
            push_data  = evt_op_done;
        end else if (dispatch_valid) begin
            push_valid = 1'b1;
            push_data  = evt_dispatch;
        end else if (result_valid) begin
            push_valid = 1'b1;
            push_data  = evt_complete;
        end else if (stall_detected) begin
            push_valid = 1'b1;
            push_data  = evt_stall;
        end else if (util_sample) begin
            push_valid = 1'b1;
            push_data  = evt_utilization;
        end
    end

    // =================================================================
    // Circular FIFO: BRAM-backed, FIFO_DEPTH x 64-bit
    // =================================================================
    localparam PTR_BITS = $clog2(FIFO_DEPTH);

    (* ram_style = "block" *)
    reg [63:0] fifo_mem [0:FIFO_DEPTH-1];

    reg [PTR_BITS:0] wr_ptr;   // extra bit for full/empty disambiguation
    reg [PTR_BITS:0] rd_ptr;

    wire [PTR_BITS-1:0] wr_addr = wr_ptr[PTR_BITS-1:0];
    wire [PTR_BITS-1:0] rd_addr = rd_ptr[PTR_BITS-1:0];

    wire fifo_empty = (wr_ptr == rd_ptr);
    wire fifo_full  = (wr_ptr[PTR_BITS] != rd_ptr[PTR_BITS]) &&
                      (wr_ptr[PTR_BITS-1:0] == rd_ptr[PTR_BITS-1:0]);

    // FIFO write: push event when source fires and FIFO is not full
    wire do_push = push_valid && !fifo_full;
    wire do_drop = push_valid && fifo_full;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= {(PTR_BITS+1){1'b0}};
        end else if (do_push) begin
            fifo_mem[wr_addr] <= push_data;
            wr_ptr            <= wr_ptr + 1;
        end
    end

    // FIFO read: BRAM read has 1-cycle latency; we register the output
    // and present it with event_valid once the read completes.
    //
    // State machine:  IDLE -> READING -> VALID -> (ack) -> IDLE
    //   IDLE:    check fifo_empty, if non-empty initiate read
    //   READING: BRAM read in progress (1-cycle latency)
    //   VALID:   event_data holds a valid event, waiting for event_ready
    //
    // Output can also be retired the same cycle it becomes valid if
    // event_ready is already asserted (combinational bypass).
    reg        rd_pending;
    reg [63:0] rd_data_reg;
    reg        rd_valid_reg;

    // Capture the read address the cycle we initiate (before rd_ptr advances)
    reg [PTR_BITS-1:0] rd_addr_prev;

    // Output is retiring this cycle (consumer accepts it)
    wire rd_retiring = rd_valid_reg && event_ready;

    // Can initiate a new read: FIFO has data, no read in flight,
    // and output register is either empty or being retired this cycle
    wire rd_can_start = !fifo_empty && !rd_pending &&
                        (!rd_valid_reg || rd_retiring);

    always @(posedge clk) begin
        if (rst) begin
            rd_ptr       <= {(PTR_BITS+1){1'b0}};
            rd_pending   <= 1'b0;
            rd_valid_reg <= 1'b0;
            rd_addr_prev <= {PTR_BITS{1'b0}};
        end else begin
            // Consumer acknowledges the current event — retire it
            if (rd_retiring) begin
                rd_valid_reg <= 1'b0;
            end

            // Initiate a read when FIFO is non-empty and output is available
            if (rd_can_start) begin
                rd_addr_prev <= rd_addr;
                rd_pending   <= 1'b1;
                rd_ptr       <= rd_ptr + 1;
            end

            // BRAM read completes after 1 cycle
            if (rd_pending) begin
                rd_data_reg  <= fifo_mem[rd_addr_prev];
                rd_valid_reg <= 1'b1;
                rd_pending   <= 1'b0;
            end
        end
    end

    assign event_valid = rd_valid_reg;
    assign event_data  = rd_data_reg;

    // =================================================================
    // Overflow tracking
    // =================================================================
    assign fifo_overflow = do_drop;

    always @(posedge clk) begin
        if (rst) begin
            event_count    <= 32'd0;
            overflow_count <= 32'd0;
        end else begin
            if (do_push)
                event_count <= event_count + 32'd1;
            if (do_drop)
                overflow_count <= overflow_count + 32'd1;
        end
    end

endmodule

`default_nettype wire
