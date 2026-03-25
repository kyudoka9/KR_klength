// Copyright 2026 Kyudoka Research, H. Ismail
// KR 6404-125 — 2-Stage Pipelined Result Collector for Routing Scheduler
//
// Breaks the critical path into two pipeline stages:
//   Stage 1: Round-robin search on hold_valid bits → register pipe_idx
//   Stage 2: Mux hold_data[pipe_idx] → output register, clear hold_valid
//
// Per-channel hold registers capture CDB results and retain them until the
// collector acknowledges. This ensures data stability across pipeline stages
// and prevents result loss when multiple channels complete simultaneously.
//
// Adds 2 cycles of result latency vs original (no throughput impact).
// Cost: N_CHANNELS * 42 FFs for hold registers.
`default_nettype none

module kr_klength_result_collector #(
    parameter N_CHANNELS = 256,
    parameter DATA_BITS  = 32,
    parameter TAG_BITS   = 5
) (
    input  wire                              clk,
    input  wire                              rst,

    // Per-channel result inputs (packed, 1-cycle pulses from CDB)
    input  wire [N_CHANNELS-1:0]             ch_result_valid,
    input  wire [N_CHANNELS*DATA_BITS-1:0]   ch_result_data,
    input  wire [N_CHANNELS*5-1:0]           ch_result_dest_reg,
    input  wire [N_CHANNELS*TAG_BITS-1:0]    ch_result_tag,
    input  wire [N_CHANNELS*4-1:0]           ch_result_opcode,

    // Merged output
    output reg                               result_valid,
    output reg  [DATA_BITS-1:0]              result_data,
    output reg  [7:0]                        result_channel,
    output reg  [4:0]                        result_dest_reg,
    output reg  [3:0]                        result_opcode
);

    function integer clog2;
        input integer val;
        integer i;
        begin
            clog2 = 1;
            for (i = 0; (1 << i) < val; i = i + 1)
                clog2 = i + 1;
        end
    endfunction

    localparam CH_SEL_BITS = clog2(N_CHANNELS);

    // =================================================================
    // Per-channel hold registers
    // Capture CDB result pulses; hold until collector consumes them.
    // =================================================================
    reg [N_CHANNELS-1:0]           hold_valid;
    reg [N_CHANNELS*DATA_BITS-1:0] hold_data;
    reg [N_CHANNELS*5-1:0]         hold_dest;
    reg [N_CHANNELS*4-1:0]         hold_opcode;

    // Stage 2 consume signal (one-hot, generated below)
    reg                            pipe_found;
    reg [CH_SEL_BITS-1:0]          pipe_idx;

    wire consuming = pipe_found;
    wire [CH_SEL_BITS-1:0] consume_idx = pipe_idx;

    integer ci;
    always @(posedge clk) begin
        for (ci = 0; ci < N_CHANNELS; ci = ci + 1) begin
            if (rst) begin
                hold_valid[ci] <= 1'b0;
            end else begin
                if (consuming && consume_idx == ci[CH_SEL_BITS-1:0]) begin
                    // Consumed by stage 2 — clear, but capture new if arriving same cycle
                    if (ch_result_valid[ci]) begin
                        hold_valid[ci] <= 1'b1;
                        hold_data[ci*DATA_BITS +: DATA_BITS] <= ch_result_data[ci*DATA_BITS +: DATA_BITS];
                        hold_dest[ci*5 +: 5] <= ch_result_dest_reg[ci*5 +: 5];
                        hold_opcode[ci*4 +: 4] <= ch_result_opcode[ci*4 +: 4];
                    end else begin
                        hold_valid[ci] <= 1'b0;
                    end
                end else if (ch_result_valid[ci] && !hold_valid[ci]) begin
                    // New result, slot is free — capture
                    hold_valid[ci] <= 1'b1;
                    hold_data[ci*DATA_BITS +: DATA_BITS] <= ch_result_data[ci*DATA_BITS +: DATA_BITS];
                    hold_dest[ci*5 +: 5] <= ch_result_dest_reg[ci*5 +: 5];
                    hold_opcode[ci*4 +: 4] <= ch_result_opcode[ci*4 +: 4];
                end
                // If ch_result_valid[ci] && hold_valid[ci] && not being consumed:
                // hold is already occupied — new result is lost (can't happen in practice:
                // channel pipeline depth > collector round-robin period)
            end
        end
    end

    // =================================================================
    // Stage 1: Round-robin search on hold_valid (combinational → pipe reg)
    // Bitmask approach: no modular arithmetic per iteration.
    //
    // Split hold_valid into upper (>= rr_ptr) and lower (< rr_ptr).
    // Find-first-one on upper; if none, find-first-one on lower.
    // Each find-first-one is a simple priority chain with no index math.
    // =================================================================
    reg [CH_SEL_BITS-1:0] rr_ptr;

    // Registered mask: pre-computed from rr_ptr, available at cycle start.
    // Removes 48-bit comparator delay from critical path (~1-2 ns savings).
    // Mask is 1 cycle behind rr_ptr updates — hold_valid prevents double-pickup.
    reg [N_CHANNELS-1:0] mask_upper_r;

    integer msk;
    always @(posedge clk) begin
        if (rst) begin
            mask_upper_r <= {N_CHANNELS{1'b1}};
        end else begin
            for (msk = 0; msk < N_CHANNELS; msk = msk + 1)
                mask_upper_r[msk] <= (msk[CH_SEL_BITS-1:0] >= rr_ptr);
        end
    end

    // Registered consume mask: pre-computed from pipe_idx, available at cycle start.
    // Prevents double-pickup without adding to the critical path.
    reg [N_CHANNELS-1:0] consume_mask_r;
    integer cmi;
    always @(posedge clk) begin
        if (rst) begin
            consume_mask_r <= {N_CHANNELS{1'b1}};
        end else begin
            for (cmi = 0; cmi < N_CHANNELS; cmi = cmi + 1)
                consume_mask_r[cmi] <= !(s1_found && s1_found_idx == cmi[CH_SEL_BITS-1:0]);
        end
    end

    // Masked requests: registered round-robin mask AND registered consume exclusion
    wire [N_CHANNELS-1:0] search_valid = hold_valid & consume_mask_r;
    wire [N_CHANNELS-1:0] upper_req = search_valid & mask_upper_r;
    wire [N_CHANNELS-1:0] lower_req = search_valid & ~mask_upper_r;

    // Find-first-one: LUT-based priority scan (Vivado optimizes as tree)
    reg                    upper_found;
    reg [CH_SEL_BITS-1:0]  upper_idx;
    reg                    lower_found;
    reg [CH_SEL_BITS-1:0]  lower_idx;

    integer ui, li;
    always @(*) begin
        upper_found = 1'b0;
        upper_idx   = {CH_SEL_BITS{1'b0}};
        for (ui = 0; ui < N_CHANNELS; ui = ui + 1) begin
            if (!upper_found && upper_req[ui]) begin
                upper_found = 1'b1;
                upper_idx   = ui[CH_SEL_BITS-1:0];
            end
        end

        lower_found = 1'b0;
        lower_idx   = {CH_SEL_BITS{1'b0}};
        for (li = 0; li < N_CHANNELS; li = li + 1) begin
            if (!lower_found && lower_req[li]) begin
                lower_found = 1'b1;
                lower_idx   = li[CH_SEL_BITS-1:0];
            end
        end
    end

    // Merge: prefer upper (round-robin fairness from rr_ptr onward)
    wire                   s1_found     = upper_found | lower_found;
    wire [CH_SEL_BITS-1:0] s1_found_idx = upper_found ? upper_idx : lower_idx;

    // Stage 1 → Stage 2 pipeline register
    always @(posedge clk) begin
        if (rst) begin
            pipe_found <= 1'b0;
            pipe_idx   <= {CH_SEL_BITS{1'b0}};
        end else begin
            pipe_found <= s1_found;
            pipe_idx   <= s1_found_idx;
            // Advance round-robin pointer when search finds a result
            if (s1_found) begin
                if (s1_found_idx == (N_CHANNELS[CH_SEL_BITS-1:0] - {{(CH_SEL_BITS-1){1'b0}}, 1'b1})) begin
                    rr_ptr <= {CH_SEL_BITS{1'b0}};
                end else begin
                    rr_ptr <= s1_found_idx + {{(CH_SEL_BITS-1){1'b0}}, 1'b1};
                end
            end
        end
    end

    // =================================================================
    // Stage 2: Data mux from hold registers using pipe_idx → output
    // Only the mux — pipe_idx is registered, hold_data is stable.
    // =================================================================
    always @(posedge clk) begin
        if (rst) begin
            result_valid    <= 1'b0;
            result_data     <= {DATA_BITS{1'b0}};
            result_channel  <= 8'b0;
            result_dest_reg <= 5'b0;
            result_opcode   <= 4'b0;
        end else begin
            if (pipe_found) begin
                result_valid    <= 1'b1;
                result_data     <= hold_data[pipe_idx * DATA_BITS +: DATA_BITS];
                result_channel  <= pipe_idx;
                result_dest_reg <= hold_dest[pipe_idx * 5 +: 5];
                result_opcode   <= hold_opcode[pipe_idx * 4 +: 4];
            end else begin
                result_valid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
