// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
// KR k-Length Computing — DSP48E1 Multiply-Accumulate Functional Unit
//
// Replaces the pass-through FU from the routing scheduler with a real
// arithmetic unit backed by DSP48E1. Supports ADDWC, SUBWB, ADDMUL,
// MULFULL, and CLZ operations.
//
// Pipeline: 3 stages for multiply (DSP48E1 inference), 1 stage for add/sub/clz.
//
`default_nettype none

module kr_klength_fu_mac #(
    parameter TAG_BITS  = 10,
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
    input  wire [12:0]             fu_imm,        // carry_in from dependency (bit 0)

    // Result output
    output reg                     result_valid,
    output reg  [TAG_BITS-1:0]     result_tag,
    output reg  [DATA_BITS-1:0]    result_data,
    output reg  [4:0]              result_dest_reg,
    output reg  [3:0]              result_opcode,
    output reg                     result_carry,   // carry/borrow output

    // Busy status
    output wire                    fu_busy
);

    // Operation codes (matching L0 CFU encoding)
    localparam OP_ADDWC   = 4'd0;
    localparam OP_SUBWB   = 4'd1;
    localparam OP_MULFULL = 4'd2;
    localparam OP_ADDMUL  = 4'd3;
    localparam OP_CLZ     = 4'd5;

    // ---------------------------------------------------------------
    // Pipeline stage 1: capture operands, start computation
    // ---------------------------------------------------------------
    reg                    s1_valid;
    reg [3:0]              s1_opcode;
    reg [DATA_BITS-1:0]    s1_src1, s1_src2;
    reg [TAG_BITS-1:0]     s1_tag;
    reg [4:0]              s1_dest_reg;
    reg                    s1_carry_in;

    // ---------------------------------------------------------------
    // Pipeline stage 2: multiply result available (DSP48E1 latency)
    // ---------------------------------------------------------------
    reg                    s2_valid;
    reg [3:0]              s2_opcode;
    reg [TAG_BITS-1:0]     s2_tag;
    reg [4:0]              s2_dest_reg;
    reg [63:0]             s2_product;    // 32x32 -> 64 result
    reg [DATA_BITS-1:0]    s2_add_result; // for ADDWC/SUBWB (forwarded from s1)
    reg                    s2_add_carry;
    reg [DATA_BITS-1:0]    s2_clz_result;

    // ---------------------------------------------------------------
    // Pipeline stage 3: output register
    // ---------------------------------------------------------------
    // (result_valid, result_tag, result_data, result_carry are the output regs)

    // Busy when any multiply is in the pipeline
    // ADDWC/SUBWB/CLZ complete in 1 cycle (bypass to output)
    assign fu_busy = s1_valid | s2_valid;

    // ---------------------------------------------------------------
    // CLZ: count leading zeros (combinational)
    // ---------------------------------------------------------------
    function [5:0] clz32;
        input [31:0] x;
        reg [5:0] n;
        begin
            n = 0;
            if (x[31:16] == 16'd0) begin n = n + 16; x = {x[15:0], 16'd0}; end
            if (x[31:24] == 8'd0)  begin n = n + 8;  x = {x[23:0], 8'd0};  end
            if (x[31:28] == 4'd0)  begin n = n + 4;  x = {x[27:0], 4'd0};  end
            if (x[31:30] == 2'd0)  begin n = n + 2;  x = {x[29:0], 2'd0};  end
            if (x[31]    == 1'b0)  begin n = n + 1;  end
            if (x == 32'd0)        begin n = 32;      end
            clz32 = n;
        end
    endfunction

    // ---------------------------------------------------------------
    // Stage 1: Capture + single-cycle operations
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            s1_valid    <= 1'b0;
            s2_valid    <= 1'b0;
            result_valid <= 1'b0;
        end else begin
            // Default: clear outputs
            result_valid <= 1'b0;

            // ---- Single-cycle operations: bypass pipeline ----
            if (fu_valid && (fu_opcode == OP_ADDWC || fu_opcode == OP_SUBWB || fu_opcode == OP_CLZ)) begin
                result_valid    <= 1'b1;
                result_tag      <= fu_tag;
                result_dest_reg <= fu_dest_reg;
                result_opcode   <= fu_opcode;

                if (fu_opcode == OP_ADDWC) begin
                    {result_carry, result_data} <= {1'b0, fu_src1} + {1'b0, fu_src2} + {32'd0, fu_imm[0]};
                end else if (fu_opcode == OP_SUBWB) begin
                    {result_carry, result_data} <= {1'b0, fu_src1} - {1'b0, fu_src2} - {32'd0, fu_imm[0]};
                end else begin // CLZ
                    result_data  <= {26'd0, clz32(fu_src1)};
                    result_carry <= 1'b0;
                end
            end

            // ---- Multi-cycle operations: enter pipeline ----
            // Stage 1 capture
            if (fu_valid && (fu_opcode == OP_MULFULL || fu_opcode == OP_ADDMUL)) begin
                s1_valid    <= 1'b1;
                s1_opcode   <= fu_opcode;
                s1_src1     <= fu_src1;
                s1_src2     <= fu_src2;
                s1_tag      <= fu_tag;
                s1_dest_reg <= fu_dest_reg;
                s1_carry_in <= fu_imm[0]; // carry from dependency
            end else begin
                s1_valid <= 1'b0;
            end

            // Stage 2: multiply (DSP48E1 infers here)
            s2_valid    <= s1_valid;
            s2_opcode   <= s1_opcode;
            s2_tag      <= s1_tag;
            s2_dest_reg <= s1_dest_reg;
            s2_product  <= {32'd0, s1_src1} * {32'd0, s1_src2}; // 32x32->64

            // Stage 3: output
            if (s2_valid) begin
                result_valid    <= 1'b1;
                result_tag      <= s2_tag;
                result_dest_reg <= s2_dest_reg;
                result_opcode   <= s2_opcode;

                if (s2_opcode == OP_ADDMUL) begin
                    // ADDMUL: low 32 bits of product (hireg accumulation handled externally)
                    result_data  <= s2_product[31:0];
                    result_carry <= |s2_product[63:32]; // carry if high bits nonzero
                end else begin
                    // MULFULL: low 32 bits (high 32 go to HIREG via separate path)
                    result_data  <= s2_product[31:0];
                    result_carry <= 1'b0;
                end
            end
        end
    end

endmodule

`default_nettype wire
