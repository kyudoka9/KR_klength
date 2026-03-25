// Copyright 2026 Kyudoka Research, H. Ismail
// KR 25632-125 — Programmable Delay Functional Unit for Routing Scheduler
//
// Replaces the 1-cycle pass-through FU with variable-latency support:
//   - ROUTE/RIPUP/BLOCK/FANOUT/NOP: 1-cycle pass-through (same as before)
//   - DEMAND: delay = imm[3:0] cycles (0-15 configurable stall)
//     Dependents of high-demand regions wait proportionally.
//
// Result data = zero-extended imm field (net_idx or demand_count).
// Opcode forwarded for host to distinguish completion types.
//
// Area cost vs pass-through: ~48 FFs per channel for delay state.
`default_nettype none

module kr_klength_fu_delay #(
    parameter TAG_BITS  = 5,
    parameter DATA_BITS = 32
) (
    input  wire                    clk,
    input  wire                    rst,

    // Issue interface (from RS table)
    input  wire                    fu_valid,
    input  wire [3:0]              fu_opcode,
    input  wire [DATA_BITS-1:0]    fu_src1,
    input  wire [DATA_BITS-1:0]    fu_src2,
    input  wire [TAG_BITS-1:0]     fu_tag,
    input  wire [4:0]              fu_dest_reg,
    input  wire [12:0]             fu_imm,

    // Result output (registered)
    output reg                     result_valid,
    output reg  [TAG_BITS-1:0]     result_tag,
    output reg  [DATA_BITS-1:0]    result_data,
    output reg  [4:0]              result_dest_reg,
    output reg  [3:0]              result_opcode,

    // Busy status — busy during DEMAND delay countdown
    output wire                    fu_busy
);

    // DEMAND opcode detection
    localparam [3:0] OP_DEMAND = 4'd4;

    wire is_demand    = (fu_opcode == OP_DEMAND);
    wire [3:0] delay  = fu_imm[3:0];
    wire needs_delay  = is_demand & (delay > 4'd0);

    // Delay state registers
    reg                    delay_active;
    reg  [3:0]             delay_counter;
    reg  [TAG_BITS-1:0]    delay_tag;
    reg  [DATA_BITS-1:0]   delay_data;
    reg  [4:0]             delay_dest_reg;
    reg  [3:0]             delay_opcode;

    // FU is busy while a DEMAND is counting down
    assign fu_busy = delay_active;

    always @(posedge clk) begin
        if (rst) begin
            result_valid    <= 1'b0;
            result_tag      <= {TAG_BITS{1'b0}};
            result_data     <= {DATA_BITS{1'b0}};
            result_dest_reg <= 5'b0;
            result_opcode   <= 4'b0;
            delay_active    <= 1'b0;
            delay_counter   <= 4'b0;
            delay_tag       <= {TAG_BITS{1'b0}};
            delay_data      <= {DATA_BITS{1'b0}};
            delay_dest_reg  <= 5'b0;
            delay_opcode    <= 4'b0;
        end else begin
            if (delay_active) begin
                // Counting down DEMAND delay
                if (delay_counter <= 4'd1) begin
                    // Delay complete — emit result
                    result_valid    <= 1'b1;
                    result_tag      <= delay_tag;
                    result_data     <= delay_data;
                    result_dest_reg <= delay_dest_reg;
                    result_opcode   <= delay_opcode;
                    delay_active    <= 1'b0;
                end else begin
                    result_valid    <= 1'b0;
                    delay_counter   <= delay_counter - 4'd1;
                end
            end else if (fu_valid) begin
                if (needs_delay) begin
                    // DEMAND with non-zero delay — enter delay mode
                    delay_active    <= 1'b1;
                    delay_counter   <= delay;
                    delay_tag       <= fu_tag;
                    delay_data      <= {{(DATA_BITS-13){1'b0}}, fu_imm};
                    delay_dest_reg  <= fu_dest_reg;
                    delay_opcode    <= fu_opcode;
                    result_valid    <= 1'b0;
                end else begin
                    // Immediate result (ROUTE/RIPUP/BLOCK/FANOUT or DEMAND delay=0)
                    result_valid    <= 1'b1;
                    result_tag      <= fu_tag;
                    result_data     <= {{(DATA_BITS-13){1'b0}}, fu_imm};
                    result_dest_reg <= fu_dest_reg;
                    result_opcode   <= fu_opcode;
                end
            end else begin
                result_valid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
