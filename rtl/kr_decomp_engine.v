// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
// KR k-Length Computing — Decomposition Engine
//
// The heart of k-length computing. Receives L1 multi-precision instructions
// (MPADD, MPMUL) and decomposes them into streams of L0 word-level micro-ops
// (ADDWC, ADDMUL) with explicit dependency tags for carry propagation.
//
// Micro-ops are fed to the KR FPGA Scheduler, which handles parallel
// execution across channels and dependency resolution via CDB.
//
// State machine: IDLE → FETCH → GENERATE → DRAIN → DONE
//
`default_nettype none

module kr_decomp_engine #(
    parameter TAG_BITS    = 10,       // Wide tags for k-length (1024 in-flight)
    parameter DATA_BITS   = 32,
    parameter MAX_WORDS   = 256,      // Max operand length in words
    parameter BRAM_ADDR_W = 15        // 32K words addressable
) (
    input  wire                    clk,
    input  wire                    rst,

    // ---------------------------------------------------------------
    // Command interface (from RISC-V via kr_klength_regs)
    // ---------------------------------------------------------------
    input  wire                    cmd_valid,
    output reg                     cmd_ready,
    input  wire [3:0]              cmd_opcode,    // 0=MPADD, 1=MPSUB, 2=MPMUL
    input  wire [BRAM_ADDR_W-1:0]  cmd_src_a,     // BRAM address of operand A
    input  wire [BRAM_ADDR_W-1:0]  cmd_src_b,     // BRAM address of operand B
    input  wire [BRAM_ADDR_W-1:0]  cmd_dst,       // BRAM address for result
    input  wire [15:0]             cmd_len_a,     // Length of A in words
    input  wire [15:0]             cmd_len_b,     // Length of B in words

    // ---------------------------------------------------------------
    // BRAM read port (fetch operands)
    // ---------------------------------------------------------------
    output reg                     bram_rd_en,
    output reg  [BRAM_ADDR_W-1:0]  bram_rd_addr,
    input  wire [DATA_BITS-1:0]    bram_rd_data,
    input  wire                    bram_rd_valid,

    // ---------------------------------------------------------------
    // BRAM write port (writeback results from scheduler)
    // ---------------------------------------------------------------
    output reg                     bram_wr_en,
    output reg  [BRAM_ADDR_W-1:0]  bram_wr_addr,
    output reg  [DATA_BITS-1:0]    bram_wr_data,

    // ---------------------------------------------------------------
    // Micro-op output (to KR FPGA Scheduler)
    // ---------------------------------------------------------------
    output reg                     uop_valid,
    input  wire                    uop_ready,
    output reg  [3:0]              uop_opcode,    // ADDWC=0, SUBWB=1, ADDMUL=3
    output reg  [DATA_BITS-1:0]    uop_src1,
    output reg  [DATA_BITS-1:0]    uop_src2,
    output reg  [TAG_BITS-1:0]     uop_tag,       // Tag assigned to this result
    output reg                     uop_dep_valid, // Has a carry dependency?
    output reg  [TAG_BITS-1:0]     uop_dep_tag,   // Tag of operation we depend on

    // ---------------------------------------------------------------
    // Result collection (from scheduler CDB, for writeback)
    // ---------------------------------------------------------------
    input  wire                    result_valid,
    input  wire [TAG_BITS-1:0]     result_tag,
    input  wire [DATA_BITS-1:0]    result_data,
    input  wire                    result_carry,

    // ---------------------------------------------------------------
    // Status
    // ---------------------------------------------------------------
    output reg                     busy,
    output reg                     done,
    output reg                     irq,
    output reg  [31:0]             uops_issued,
    output reg  [31:0]             uops_completed,
    output reg  [31:0]             cycle_count
);

    // ---------------------------------------------------------------
    // Operation codes (matching L0 CFU encoding)
    // ---------------------------------------------------------------
    localparam OP_MPADD = 4'd0;
    localparam OP_MPSUB = 4'd1;
    localparam OP_MPMUL = 4'd2;

    localparam UOP_ADDWC  = 4'd0;
    localparam UOP_SUBWB  = 4'd1;
    localparam UOP_ADDMUL = 4'd3;

    // ---------------------------------------------------------------
    // State machine
    // ---------------------------------------------------------------
    localparam S_IDLE     = 4'd0;
    localparam S_FETCH_A  = 4'd1;
    localparam S_FETCH_B  = 4'd2;
    localparam S_GEN_ADD  = 4'd3;  // Generate MPADD/MPSUB micro-ops
    localparam S_GEN_MUL  = 4'd4;  // Generate MPMUL micro-ops
    localparam S_DRAIN    = 4'd5;  // Wait for all micro-ops to complete
    localparam S_DONE     = 4'd6;

    reg [3:0] state;

    // ---------------------------------------------------------------
    // Operand buffers (on-chip, fetched from BRAM)
    // ---------------------------------------------------------------
    reg [DATA_BITS-1:0] buf_a [0:MAX_WORDS-1];
    reg [DATA_BITS-1:0] buf_b [0:MAX_WORDS-1];

    // ---------------------------------------------------------------
    // Command registers (latched on dispatch)
    // ---------------------------------------------------------------
    reg [3:0]              op_reg;
    reg [BRAM_ADDR_W-1:0]  src_a_reg, src_b_reg, dst_reg;
    reg [15:0]             len_a_reg, len_b_reg;

    // ---------------------------------------------------------------
    // Fetch counters
    // ---------------------------------------------------------------
    reg [15:0] fetch_idx;
    reg        fetch_pipe;  // 1-cycle BRAM read latency

    // ---------------------------------------------------------------
    // Generation counters
    // ---------------------------------------------------------------
    reg [15:0] gen_i;          // outer loop (row for multiply)
    reg [15:0] gen_j;          // inner loop (column for multiply)
    reg [TAG_BITS-1:0] next_tag;
    reg [TAG_BITS-1:0] carry_tag;   // tag of previous op (carry dependency)
    reg                carry_dep;   // whether carry_tag is valid
    reg [31:0]         total_uops;  // total micro-ops for this operation

    // ---------------------------------------------------------------
    // Drain tracking
    // ---------------------------------------------------------------
    reg [TAG_BITS-1:0] last_tag;    // last issued tag — done when this completes

    // ---------------------------------------------------------------
    // Result writeback tracking
    // ---------------------------------------------------------------
    // For MPADD: result word i is written when tag i completes
    // For MPMUL: result words accumulate (handled by result accumulator externally)
    // Simple approach: track tag→destination address mapping
    reg [BRAM_ADDR_W-1:0] tag_dst_addr [0:(1<<TAG_BITS)-1];

    // ---------------------------------------------------------------
    // Main state machine
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state          <= S_IDLE;
            cmd_ready      <= 1'b1;
            busy           <= 1'b0;
            done           <= 1'b0;
            irq            <= 1'b0;
            uop_valid      <= 1'b0;
            bram_rd_en     <= 1'b0;
            bram_wr_en     <= 1'b0;
            uops_issued    <= 32'd0;
            uops_completed <= 32'd0;
            cycle_count    <= 32'd0;
            next_tag       <= {TAG_BITS{1'b0}};
            fetch_idx      <= 16'd0;
            fetch_pipe     <= 1'b0;
        end else begin
            // Default: clear one-shot signals
            irq        <= 1'b0;
            bram_wr_en <= 1'b0;

            // Cycle counter (when busy)
            if (busy) cycle_count <= cycle_count + 1;

            // Result writeback: when scheduler CDB delivers a result, write to BRAM
            if (result_valid && busy) begin
                bram_wr_en   <= 1'b1;
                bram_wr_addr <= tag_dst_addr[result_tag];
                bram_wr_data <= result_data;
                uops_completed <= uops_completed + 1;
            end

            case (state)

            // =============================================================
            S_IDLE: begin
                cmd_ready <= 1'b1;
                done      <= 1'b0;
                if (cmd_valid && cmd_ready) begin
                    // Latch command
                    op_reg    <= cmd_opcode;
                    src_a_reg <= cmd_src_a;
                    src_b_reg <= cmd_src_b;
                    dst_reg   <= cmd_dst;
                    len_a_reg <= cmd_len_a;
                    len_b_reg <= cmd_len_b;
                    // Init counters
                    cmd_ready      <= 1'b0;
                    busy           <= 1'b1;
                    uops_issued    <= 32'd0;
                    uops_completed <= 32'd0;
                    cycle_count    <= 32'd0;
                    fetch_idx      <= 16'd0;
                    fetch_pipe     <= 1'b0;
                    next_tag       <= {TAG_BITS{1'b0}};
                    state          <= S_FETCH_A;
                    bram_rd_en     <= 1'b1;
                    bram_rd_addr   <= cmd_src_a;
                end
            end

            // =============================================================
            S_FETCH_A: begin
                if (fetch_pipe && bram_rd_valid) begin
                    buf_a[fetch_idx - 1] <= bram_rd_data;
                end

                if (fetch_idx < len_a_reg) begin
                    bram_rd_addr <= src_a_reg + fetch_idx;
                    bram_rd_en   <= 1'b1;
                    fetch_idx    <= fetch_idx + 1;
                    fetch_pipe   <= 1'b1;
                end else begin
                    // Capture last word
                    if (fetch_pipe && bram_rd_valid) begin
                        buf_a[fetch_idx - 1] <= bram_rd_data;
                    end
                    fetch_idx  <= 16'd0;
                    fetch_pipe <= 1'b0;
                    bram_rd_en <= 1'b1;
                    bram_rd_addr <= src_b_reg;
                    state      <= S_FETCH_B;
                end
            end

            // =============================================================
            S_FETCH_B: begin
                if (fetch_pipe && bram_rd_valid) begin
                    buf_b[fetch_idx - 1] <= bram_rd_data;
                end

                if (fetch_idx < len_b_reg) begin
                    bram_rd_addr <= src_b_reg + fetch_idx;
                    bram_rd_en   <= 1'b1;
                    fetch_idx    <= fetch_idx + 1;
                    fetch_pipe   <= 1'b1;
                end else begin
                    if (fetch_pipe && bram_rd_valid) begin
                        buf_b[fetch_idx - 1] <= bram_rd_data;
                    end
                    bram_rd_en <= 1'b0;
                    fetch_pipe <= 1'b0;
                    // Select generation mode based on operation
                    gen_i     <= 16'd0;
                    gen_j     <= 16'd0;
                    carry_dep <= 1'b0;
                    if (op_reg == OP_MPMUL) begin
                        total_uops <= {16'd0, len_a_reg} * {16'd0, len_b_reg};
                        state      <= S_GEN_MUL;
                    end else begin
                        total_uops <= {16'd0, len_a_reg};  // MPADD: one op per word
                        state      <= S_GEN_ADD;
                    end
                end
            end

            // =============================================================
            // MPADD/MPSUB: emit one ADDWC/SUBWB per word, linear carry chain
            // =============================================================
            S_GEN_ADD: begin
                if (!uop_valid || uop_ready) begin
                    if (gen_i < len_a_reg) begin
                        uop_valid     <= 1'b1;
                        uop_opcode    <= (op_reg == OP_MPSUB) ? UOP_SUBWB : UOP_ADDWC;
                        uop_src1      <= buf_a[gen_i];
                        uop_src2      <= buf_b[gen_i];
                        uop_tag       <= next_tag;
                        uop_dep_valid <= carry_dep;
                        uop_dep_tag   <= carry_tag;

                        // Record destination for writeback
                        tag_dst_addr[next_tag] <= dst_reg + gen_i;

                        // Update state for next iteration
                        carry_tag  <= next_tag;
                        carry_dep  <= 1'b1;  // all subsequent words depend on carry
                        next_tag   <= next_tag + 1;
                        gen_i      <= gen_i + 1;
                        uops_issued <= uops_issued + 1;
                    end else begin
                        uop_valid <= 1'b0;
                        last_tag  <= next_tag - 1;
                        state     <= S_DRAIN;
                    end
                end
            end

            // =============================================================
            // MPMUL: nested loop of ADDMUL micro-ops (schoolbook)
            //   for i = 0 to len_a-1:
            //     carry_dep = false (fresh row)
            //     for j = 0 to len_b-1:
            //       emit ADDMUL(a[i], b[j]) with carry dep on previous in row
            //       result accumulates into result[i+j]
            // =============================================================
            S_GEN_MUL: begin
                if (!uop_valid || uop_ready) begin
                    if (gen_i < len_a_reg) begin
                        uop_valid     <= 1'b1;
                        uop_opcode    <= UOP_ADDMUL;
                        uop_src1      <= buf_a[gen_i];
                        uop_src2      <= buf_b[gen_j];
                        uop_tag       <= next_tag;
                        uop_dep_valid <= carry_dep;
                        uop_dep_tag   <= carry_tag;

                        // Result destination: result[i+j]
                        tag_dst_addr[next_tag] <= dst_reg + gen_i + gen_j;

                        // Update carry chain (within this row)
                        carry_tag  <= next_tag;
                        carry_dep  <= 1'b1;
                        next_tag   <= next_tag + 1;
                        uops_issued <= uops_issued + 1;

                        // Advance loop counters
                        if (gen_j == len_b_reg - 1) begin
                            // End of inner loop: advance outer, reset inner
                            gen_j     <= 16'd0;
                            gen_i     <= gen_i + 1;
                            carry_dep <= 1'b0;  // new row: no carry dependency
                        end else begin
                            gen_j <= gen_j + 1;
                        end
                    end else begin
                        uop_valid <= 1'b0;
                        last_tag  <= next_tag - 1;
                        state     <= S_DRAIN;
                    end
                end
            end

            // =============================================================
            // DRAIN: wait for all issued micro-ops to complete
            // =============================================================
            S_DRAIN: begin
                uop_valid <= 1'b0;
                if (uops_completed >= uops_issued) begin
                    state <= S_DONE;
                end
            end

            // =============================================================
            // DONE: signal completion
            // =============================================================
            S_DONE: begin
                busy  <= 1'b0;
                done  <= 1'b1;
                irq   <= 1'b1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;

            endcase
        end
    end

endmodule

`default_nettype wire
