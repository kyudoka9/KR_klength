// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
// KR k-Length Computing — DSP48E1 Multiply-Accumulate Functional Unit
//
// Redesigned to fix audit bugs M1, M2c, M2d, M3, M4, M5.
//
// Pipeline (unified — all ops go through registered stages):
//   Stage 1: Capture inputs. ADDWC/SUBWB/CLZ compute result combinationally.
//   Stage 2: MULFULL/ADDMUL multiply (DSP48E1 inference). Add/sub/clz skip.
//   Stage 3: Final output register. Multiply accumulate (product + acc).
//
// Latency:  ADDWC/SUBWB/CLZ = 2 cycles (s1 → s3).
//           MULFULL/ADDMUL  = 3 cycles (s1 → s2 → s3).
//
// fu_busy is asserted whenever ANY stage holds valid data (fixes M5).
// All ops go through the pipeline — no bypass path (fixes M1).
// result_hi is full 32-bit high word, not 1-bit carry (fixes M4, M2c).
// ADDMUL computes src1*src2 + acc (fixes M2d).
// Multiply uses src1 * src2 directly for DSP48E1 inference (fixes M3).
//
`default_nettype none

module kr_klength_fu_mac #(
    parameter TAG_BITS  = 12,
    parameter DATA_BITS = 32
) (
    input  wire                    clk,
    input  wire                    rst,

    // Issue interface
    input  wire                    fu_valid,
    input  wire [3:0]              fu_opcode,
    input  wire [DATA_BITS-1:0]    fu_src1,
    input  wire [DATA_BITS-1:0]    fu_src2,
    input  wire [TAG_BITS-1:0]     fu_tag,
    input  wire [DATA_BITS-1:0]    fu_acc,       // accumulator / carry-in

    // Result output
    output reg                     result_valid,
    output reg  [TAG_BITS-1:0]     result_tag,
    output reg  [DATA_BITS-1:0]    result_data,  // low word
    output reg  [DATA_BITS-1:0]    result_hi,    // high word / carry
    output reg  [3:0]              result_opcode,

    // Busy
    output wire                    fu_busy
);

    // Operation codes (matching L0 CFU encoding)
    localparam OP_ADDWC   = 4'd0;
    localparam OP_SUBWB   = 4'd1;
    localparam OP_MULFULL = 4'd2;
    localparam OP_ADDMUL  = 4'd3;
    localparam OP_CLZ     = 4'd5;

    // -------------------------------------------------------------------
    // CLZ: count leading zeros (combinational)
    // -------------------------------------------------------------------
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

    // -------------------------------------------------------------------
    // Classify opcode: is it a multiply (3-stage) or simple (2-stage)?
    // -------------------------------------------------------------------
    wire fu_is_mul = (fu_opcode == OP_MULFULL) || (fu_opcode == OP_ADDMUL);

    // -------------------------------------------------------------------
    // Stage 1: Capture inputs. Compute add/sub/clz combinationally.
    // -------------------------------------------------------------------
    reg                    s1_valid;
    reg [3:0]              s1_opcode;
    reg [DATA_BITS-1:0]    s1_src1, s1_src2;
    reg [TAG_BITS-1:0]     s1_tag;
    reg [DATA_BITS-1:0]    s1_acc;
    reg                    s1_is_mul;

    // Pre-computed simple-op results (registered in s1)
    reg [DATA_BITS-1:0]    s1_simple_data;
    reg [DATA_BITS-1:0]    s1_simple_hi;

    // -------------------------------------------------------------------
    // Stage 2: Multiply (DSP48E1). Only valid for MULFULL/ADDMUL.
    // -------------------------------------------------------------------
    reg                    s2_valid;
    reg [3:0]              s2_opcode;
    reg [TAG_BITS-1:0]     s2_tag;
    reg [DATA_BITS-1:0]    s2_acc;
    reg [63:0]             s2_product;

    // For simple ops skipping s2: forwarded from s1
    reg                    s2_simple_valid;
    reg [3:0]              s2_simple_opcode;
    reg [TAG_BITS-1:0]     s2_simple_tag;
    reg [DATA_BITS-1:0]    s2_simple_data;
    reg [DATA_BITS-1:0]    s2_simple_hi;

    // -------------------------------------------------------------------
    // Busy: any stage has valid data (fixes M5)
    // -------------------------------------------------------------------
    assign fu_busy = s1_valid | s2_valid | s2_simple_valid | hold_valid;

    // -------------------------------------------------------------------
    // Stage 1: Capture
    // -------------------------------------------------------------------
    // Combinational add/sub/clz results (used for registering into s1)
    reg [DATA_BITS:0] add_result_wide;  // 33 bits for carry
    reg [DATA_BITS:0] sub_result_wide;  // 33 bits for borrow

    always @(*) begin
        // ADDWC: {carry, sum} = src1 + src2 + acc[0]
        add_result_wide = {1'b0, fu_src1} + {1'b0, fu_src2} + {32'd0, fu_acc[0]};
        // SUBWB: {borrow, diff} = src1 - src2 - acc[0]
        sub_result_wide = {1'b0, fu_src1} - {1'b0, fu_src2} - {32'd0, fu_acc[0]};
    end

    always @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
        end else begin
            if (fu_valid) begin
                s1_valid  <= 1'b1;
                s1_opcode <= fu_opcode;
                s1_src1   <= fu_src1;
                s1_src2   <= fu_src2;
                s1_tag    <= fu_tag;
                s1_acc    <= fu_acc;
                s1_is_mul <= fu_is_mul;

                // Pre-compute simple-op results
                case (fu_opcode)
                    OP_ADDWC: begin
                        s1_simple_data <= add_result_wide[DATA_BITS-1:0];
                        s1_simple_hi   <= {31'd0, add_result_wide[DATA_BITS]};
                    end
                    OP_SUBWB: begin
                        s1_simple_data <= sub_result_wide[DATA_BITS-1:0];
                        s1_simple_hi   <= {31'd0, sub_result_wide[DATA_BITS]};
                    end
                    OP_CLZ: begin
                        s1_simple_data <= {26'd0, clz32(fu_src1)};
                        s1_simple_hi   <= {DATA_BITS{1'b0}};
                    end
                    default: begin
                        // Multiply ops — simple results unused
                        s1_simple_data <= {DATA_BITS{1'b0}};
                        s1_simple_hi   <= {DATA_BITS{1'b0}};
                    end
                endcase
            end else begin
                s1_valid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------
    // Stage 2: Multiply (DSP48E1) / Simple-op forwarding
    // -------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            s2_valid        <= 1'b0;
            s2_simple_valid <= 1'b0;
        end else begin
            // Multiply path: s1 → s2 (only for mul ops)
            if (s1_valid && s1_is_mul) begin
                s2_valid   <= 1'b1;
                s2_opcode  <= s1_opcode;
                s2_tag     <= s1_tag;
                s2_acc     <= s1_acc;
                // M3 fix: let Verilog infer 32x32 → 64-bit multiply naturally.
                // Do NOT zero-extend to 64 bits before multiplying.
                s2_product <= s1_src1 * s1_src2;
            end else begin
                s2_valid <= 1'b0;
            end

            // Simple-op path: s1 → s2_simple (skip multiply, go to output)
            if (s1_valid && !s1_is_mul) begin
                s2_simple_valid  <= 1'b1;
                s2_simple_opcode <= s1_opcode;
                s2_simple_tag    <= s1_tag;
                s2_simple_data   <= s1_simple_data;
                s2_simple_hi     <= s1_simple_hi;
            end else begin
                s2_simple_valid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------
    // Stage 3 / Output: Final result register
    //
    // Multiply ops arrive from s2 (3-cycle latency).
    // Simple ops arrive from s2_simple (2-cycle latency).
    //
    // M1 fix: both paths produce output on different cycles because they
    // enter the pipeline on the same cycle but exit on different cycles.
    // However, if a simple op is dispatched while a multiply is in s2
    // (about to complete), both could try to output simultaneously.
    //
    // Resolution: multiply takes priority; simple result goes to a
    // 1-entry hold buffer and outputs the next cycle.
    // -------------------------------------------------------------------
    reg                    hold_valid;
    reg [3:0]              hold_opcode;
    reg [TAG_BITS-1:0]     hold_tag;
    reg [DATA_BITS-1:0]    hold_data;
    reg [DATA_BITS-1:0]    hold_hi;

    // Accumulate: product + acc. 65 bits to capture carry out of bit 63.
    // {acc_hi, acc_lo} = product[63:0] + {32'd0, acc[31:0]}
    wire [64:0] acc_sum = {1'b0, s2_product} + {33'd0, s2_acc};

    always @(posedge clk) begin
        if (rst) begin
            result_valid <= 1'b0;
            hold_valid   <= 1'b0;
        end else begin
            // Default: no output
            result_valid <= 1'b0;

            // Priority 1: Multiply result from s2
            if (s2_valid) begin
                result_valid  <= 1'b1;
                result_tag    <= s2_tag;
                result_opcode <= s2_opcode;

                if (s2_opcode == OP_ADDMUL) begin
                    // M2d fix: fused multiply-accumulate
                    // {hi, lo} = src1 * src2 + acc
                    result_data <= acc_sum[DATA_BITS-1:0];
                    result_hi   <= acc_sum[2*DATA_BITS-1:DATA_BITS];
                end else begin
                    // MULFULL: M2c fix — output full high word
                    result_data <= s2_product[DATA_BITS-1:0];
                    result_hi   <= s2_product[2*DATA_BITS-1:DATA_BITS];
                end

                // If a simple op also wants to output, hold it
                if (s2_simple_valid) begin
                    hold_valid  <= 1'b1;
                    hold_opcode <= s2_simple_opcode;
                    hold_tag    <= s2_simple_tag;
                    hold_data   <= s2_simple_data;
                    hold_hi     <= s2_simple_hi;
                end else begin
                    hold_valid <= 1'b0;
                end

            // Priority 2: Held simple result (from collision)
            end else if (hold_valid) begin
                result_valid  <= 1'b1;
                result_tag    <= hold_tag;
                result_opcode <= hold_opcode;
                result_data   <= hold_data;
                result_hi     <= hold_hi;
                hold_valid    <= 1'b0;

            // Priority 3: Simple op result from s2_simple
            end else if (s2_simple_valid) begin
                result_valid  <= 1'b1;
                result_tag    <= s2_simple_tag;
                result_opcode <= s2_simple_opcode;
                result_data   <= s2_simple_data;
                result_hi     <= s2_simple_hi;
                hold_valid    <= 1'b0;

            end else begin
                hold_valid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
