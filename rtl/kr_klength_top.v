// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
// KR k-Length Computing — Integration Top
//
// Wires together all k-length components:
//   - Decomposition engine (L1 → L0 micro-op generation)
//   - MAC functional unit bank (DSP48E1 execution)
//   - Shared BRAM (operand/result storage)
//   - Register interface (Wishbone, for RISC-V control)
//
// Architecture:
//   The decomposition engine generates micro-ops with explicit dependency
//   tags and dispatches them round-robin to a bank of MAC functional units.
//   Results return via a shared result bus. The decomp engine resolves
//   carry dependencies and writes results to BRAM.
//
//   This is a direct-dispatch architecture — the decomp engine IS the
//   scheduler for k-length operations. It tracks all tags and dependencies
//   internally. The MAC bank is the compute fabric.
//
`default_nettype none

module kr_klength_top #(
    parameter N_CHANNELS  = 8,         // Number of parallel MAC units
    parameter TAG_BITS    = 10,        // 1024 in-flight operations
    parameter DATA_BITS   = 32,
    parameter BRAM_ADDR_W = 13,        // 2^13 = 8192 words = 32 KB
    parameter MAX_WORDS   = 256        // Max operand length
) (
    input  wire        clk,
    input  wire        rst,

    // ---------------------------------------------------------------
    // Wishbone slave: register interface (RISC-V control plane)
    // Address range: base + 0x00..0x3F
    // ---------------------------------------------------------------
    input  wire [31:0] wb_regs_adr_i,
    input  wire [31:0] wb_regs_dat_i,
    output wire [31:0] wb_regs_dat_o,
    input  wire        wb_regs_we_i,
    input  wire        wb_regs_stb_i,
    output wire        wb_regs_ack_o,

    // ---------------------------------------------------------------
    // Wishbone slave: BRAM port A (RISC-V read/write operands+results)
    // Address range: base + 0x10000..0x1FFFF (word-addressed internally)
    // ---------------------------------------------------------------
    input  wire [31:0] wb_bram_adr_i,
    input  wire [31:0] wb_bram_dat_i,
    output wire [31:0] wb_bram_dat_o,
    input  wire        wb_bram_we_i,
    input  wire        wb_bram_stb_i,
    output wire        wb_bram_ack_o,

    // ---------------------------------------------------------------
    // Status outputs
    // ---------------------------------------------------------------
    output wire        busy,
    output wire        done,
    output wire        irq
);

    // ===================================================================
    // Internal wires: Register interface ↔ Decomposition engine
    // ===================================================================
    wire                    cmd_valid;
    wire                    cmd_ready;
    wire [3:0]              cmd_opcode;
    wire [BRAM_ADDR_W-1:0]  cmd_src_a;
    wire [BRAM_ADDR_W-1:0]  cmd_src_b;
    wire [BRAM_ADDR_W-1:0]  cmd_dst;
    wire [15:0]             cmd_len_a;
    wire [15:0]             cmd_len_b;
    wire                    de_busy;
    wire                    de_done;
    wire                    de_irq;
    wire [31:0]             de_uops_issued;
    wire [31:0]             de_uops_completed;
    wire [31:0]             de_cycle_count;
    wire                    de_err_unsupported;

    // ===================================================================
    // Internal wires: Decomposition engine ↔ BRAM (port B)
    // ===================================================================
    wire                    de_bram_rd_en;
    wire [BRAM_ADDR_W-1:0]  de_bram_rd_addr;
    wire [DATA_BITS-1:0]    de_bram_rd_data;
    reg                     de_bram_rd_valid;  // 1-cycle BRAM read latency

    wire                    de_bram_wr_en;
    wire [BRAM_ADDR_W-1:0]  de_bram_wr_addr;
    wire [DATA_BITS-1:0]    de_bram_wr_data;

    // ===================================================================
    // Internal wires: Decomposition engine ↔ MAC bank
    // ===================================================================
    wire                    uop_valid;
    wire                    uop_ready;
    wire [3:0]              uop_opcode;
    wire [DATA_BITS-1:0]    uop_src1;
    wire [DATA_BITS-1:0]    uop_src2;
    wire [TAG_BITS-1:0]     uop_tag;
    wire                    uop_dep_valid;
    wire [TAG_BITS-1:0]     uop_dep_tag;

    // ===================================================================
    // Internal wires: MAC bank → result collector → decomp engine
    // ===================================================================
    wire                    result_valid;
    wire [TAG_BITS-1:0]     result_tag;
    wire [DATA_BITS-1:0]    result_data;
    wire [DATA_BITS-1:0]    result_hi;  // full 32-bit high word (was 1-bit carry)

    // ===================================================================
    // Per-MAC-unit wires
    // ===================================================================
    wire [N_CHANNELS-1:0]   mac_fu_valid;
    wire [N_CHANNELS-1:0]   mac_result_valid;
    wire [N_CHANNELS-1:0]   mac_fu_busy;
    wire [N_CHANNELS*DATA_BITS-1:0] mac_result_hi;   // 32-bit high word per MAC
    wire [N_CHANNELS*DATA_BITS-1:0] mac_result_data;
    wire [N_CHANNELS*TAG_BITS-1:0]  mac_result_tag;

    // ===================================================================
    // High-Word Resolution Table (was carry table)
    // ===================================================================
    // Stores the full 32-bit high word from each completed micro-op.
    // For ADDWC/SUBWB: only bit 0 is meaningful (carry/borrow).
    // For MULFULL/ADDMUL: full 32-bit high word (accumulator for next op).
    //
    // Size: 2^TAG_BITS entries × 32 bits. For TAG_BITS=10: 32 KB (BRAM).
    (* ram_style = "block" *)
    reg [DATA_BITS-1:0] hi_table [0:(1<<TAG_BITS)-1];

    // Update table when results arrive
    always @(posedge clk) begin
        if (result_valid_r) begin
            hi_table[result_tag_r] <= result_hi_r;
        end
    end

    // Resolved accumulator/carry-in for the current micro-op being dispatched
    wire [DATA_BITS-1:0] resolved_acc = (uop_dep_valid && uop_valid)
                                        ? hi_table[uop_dep_tag]
                                        : {DATA_BITS{1'b0}};

    // ===================================================================
    // BRAM port A: Wishbone adapter (RISC-V side)
    // ===================================================================
    // Convert byte-addressed Wishbone to word-addressed BRAM
    wire [BRAM_ADDR_W-1:0] bram_a_addr = wb_bram_adr_i[BRAM_ADDR_W+1:2]; // byte→word
    wire [DATA_BITS-1:0]   bram_a_dout;
    reg                    bram_a_ack;

    always @(posedge clk) begin
        if (rst)
            bram_a_ack <= 1'b0;
        else
            bram_a_ack <= wb_bram_stb_i && !bram_a_ack;
    end

    assign wb_bram_dat_o = bram_a_dout;
    assign wb_bram_ack_o = bram_a_ack;

    // ===================================================================
    // BRAM port B: mux between decomp engine read and result write
    // ===================================================================
    // Priority: result writes take precedence (they're time-critical)
    wire                    bram_b_en = de_bram_rd_en | de_bram_wr_en;
    wire                    bram_b_we = de_bram_wr_en;
    wire [BRAM_ADDR_W-1:0]  bram_b_addr = de_bram_wr_en ? de_bram_wr_addr : de_bram_rd_addr;
    wire [DATA_BITS-1:0]    bram_b_din  = de_bram_wr_data;
    wire [DATA_BITS-1:0]    bram_b_dout;

    // BRAM read valid: 1-cycle latency after read enable (when not writing)
    always @(posedge clk) begin
        if (rst)
            de_bram_rd_valid <= 1'b0;
        else
            de_bram_rd_valid <= de_bram_rd_en && !de_bram_wr_en;
    end

    assign de_bram_rd_data = bram_b_dout;

    // ===================================================================
    // Module: Shared BRAM
    // ===================================================================
    kr_klength_bram #(
        .ADDR_WIDTH (BRAM_ADDR_W),
        .DATA_WIDTH (DATA_BITS)
    ) u_bram (
        .clk    (clk),
        // Port A: RISC-V (Wishbone)
        .a_en   (wb_bram_stb_i),
        .a_we   (wb_bram_we_i && wb_bram_stb_i),
        .a_addr (bram_a_addr),
        .a_din  (wb_bram_dat_i),
        .a_dout (bram_a_dout),
        // Port B: Decomp engine + result writeback
        .b_en   (bram_b_en),
        .b_we   (bram_b_we),
        .b_addr (bram_b_addr),
        .b_din  (bram_b_din),
        .b_dout (bram_b_dout)
    );

    // ===================================================================
    // Module: Register interface (Wishbone → decomp engine commands)
    // ===================================================================
    kr_klength_regs #(
        .BRAM_ADDR_W (BRAM_ADDR_W)
    ) u_regs (
        .clk              (clk),
        .rst              (rst),
        // Wishbone
        .wb_adr_i         (wb_regs_adr_i),
        .wb_dat_i         (wb_regs_dat_i),
        .wb_dat_o         (wb_regs_dat_o),
        .wb_we_i          (wb_regs_we_i),
        .wb_stb_i         (wb_regs_stb_i),
        .wb_ack_o         (wb_regs_ack_o),
        // Command interface → decomp engine
        .cmd_valid        (cmd_valid),
        .cmd_ready        (cmd_ready),
        .cmd_opcode       (cmd_opcode),
        .cmd_src_a        (cmd_src_a),
        .cmd_src_b        (cmd_src_b),
        .cmd_dst          (cmd_dst),
        .cmd_len_a        (cmd_len_a),
        .cmd_len_b        (cmd_len_b),
        // Status from decomp engine
        .de_busy           (de_busy),
        .de_done           (de_done),
        .de_uops_issued    (de_uops_issued),
        .de_uops_completed (de_uops_completed),
        .de_cycle_count    (de_cycle_count)
    );

    // ===================================================================
    // Module: Decomposition engine
    // ===================================================================
    kr_decomp_engine #(
        .TAG_BITS    (TAG_BITS),
        .DATA_BITS   (DATA_BITS),
        .MAX_WORDS   (MAX_WORDS),
        .BRAM_ADDR_W (BRAM_ADDR_W)
    ) u_decomp (
        .clk              (clk),
        .rst              (rst),
        // Command input (from registers)
        .cmd_valid        (cmd_valid),
        .cmd_ready        (cmd_ready),
        .cmd_opcode       (cmd_opcode),
        .cmd_src_a        (cmd_src_a),
        .cmd_src_b        (cmd_src_b),
        .cmd_dst          (cmd_dst),
        .cmd_len_a        (cmd_len_a),
        .cmd_len_b        (cmd_len_b),
        // BRAM read port
        .bram_rd_en       (de_bram_rd_en),
        .bram_rd_addr     (de_bram_rd_addr),
        .bram_rd_data     (de_bram_rd_data),
        .bram_rd_valid    (de_bram_rd_valid),
        // BRAM write port (result writeback)
        .bram_wr_en       (de_bram_wr_en),
        .bram_wr_addr     (de_bram_wr_addr),
        .bram_wr_data     (de_bram_wr_data),
        // Micro-op output → MAC bank
        .uop_valid        (uop_valid),
        .uop_ready        (uop_ready),
        .uop_opcode       (uop_opcode),
        .uop_src1         (uop_src1),
        .uop_src2         (uop_src2),
        .uop_tag          (uop_tag),
        .uop_dep_valid    (uop_dep_valid),
        .uop_dep_tag      (uop_dep_tag),
        // Result collection (from MAC bank)
        .result_valid     (result_valid),
        .result_tag       (result_tag),
        .result_data      (result_data),
        .result_carry     (result_hi[0]),  // MPADD uses bit 0 as carry flag
        // Status
        .busy             (de_busy),
        .done             (de_done),
        .irq              (de_irq),
        .uops_issued      (de_uops_issued),
        .uops_completed   (de_uops_completed),
        .cycle_count      (de_cycle_count),
        .err_unsupported  (de_err_unsupported)
    );

    // ===================================================================
    // MAC Functional Unit Bank: Round-Robin Dispatch
    // ===================================================================
    // The decomp engine emits one micro-op at a time (uop_valid/uop_ready).
    // We dispatch round-robin to whichever MAC unit is free.
    //
    // This is simpler than the full channel pipeline (no decode, no
    // scoreboard, no register file) because the decomp engine already
    // provides resolved operand values and explicit dependency tags.

    reg [$clog2(N_CHANNELS)-1:0] dispatch_rr; // round-robin pointer
    wire [N_CHANNELS-1:0] mac_free = ~mac_fu_busy;

    // Find next free MAC unit (starting from round-robin pointer)
    reg [$clog2(N_CHANNELS)-1:0] dispatch_target;
    reg                          dispatch_found;

    always @(*) begin
        dispatch_found  = 1'b0;
        dispatch_target = dispatch_rr;
        begin : find_free
            integer k;
            for (k = 0; k < N_CHANNELS; k = k + 1) begin
                if (mac_free[(dispatch_rr + k) % N_CHANNELS] && !dispatch_found) begin
                    dispatch_target = (dispatch_rr + k) % N_CHANNELS;
                    dispatch_found  = 1'b1;
                end
            end
        end
    end

    // Micro-op is accepted when we find a free MAC
    assign uop_ready = dispatch_found;

    // Generate per-MAC valid signals
    genvar gi;
    generate
        for (gi = 0; gi < N_CHANNELS; gi = gi + 1) begin : gen_dispatch
            assign mac_fu_valid[gi] = uop_valid && dispatch_found &&
                                       (dispatch_target == gi);
        end
    endgenerate

    // Advance round-robin pointer on dispatch
    always @(posedge clk) begin
        if (rst)
            dispatch_rr <= 0;
        else if (uop_valid && uop_ready)
            dispatch_rr <= (dispatch_target + 1) % N_CHANNELS;
    end

    // ===================================================================
    // MAC Functional Unit Bank: Instantiation
    // ===================================================================
    generate
        for (gi = 0; gi < N_CHANNELS; gi = gi + 1) begin : gen_mac
            kr_klength_fu_mac #(
                .TAG_BITS  (TAG_BITS),
                .DATA_BITS (DATA_BITS)
            ) u_mac (
                .clk            (clk),
                .rst            (rst),
                // Issue interface
                .fu_valid       (mac_fu_valid[gi]),
                .fu_opcode      (uop_opcode),
                .fu_src1        (uop_src1),
                .fu_src2        (uop_src2),
                .fu_tag         (uop_tag),
                .fu_acc         (resolved_acc),
                // Result output
                .result_valid   (mac_result_valid[gi]),
                .result_tag     (mac_result_tag[gi*TAG_BITS +: TAG_BITS]),
                .result_data    (mac_result_data[gi*DATA_BITS +: DATA_BITS]),
                .result_hi      (mac_result_hi[gi*DATA_BITS +: DATA_BITS]),
                .result_opcode  (),  // unused in k-length, left open
                // Busy status
                .fu_busy        (mac_fu_busy[gi])
            );
        end
    endgenerate

    // ===================================================================
    // Result Collector: Latched per-MAC results with round-robin drain
    // ===================================================================
    // Each MAC result is latched when it completes. A round-robin arbiter
    // drains one latched result per cycle to the decomp engine. This
    // ensures no results are dropped when multiple MACs complete
    // simultaneously.
    //
    // Latching is safe because: a MAC that just completed cannot produce
    // another result for at least 1 cycle (single-cycle ops) or 3 cycles
    // (multiply). The arbiter drains at 1/cycle, so with N_CHANNELS=8,
    // worst case is 8 simultaneous completions drained in 8 cycles —
    // well before any MAC can produce a new result.

    // Per-MAC result latches (32-bit hi per channel)
    reg [N_CHANNELS-1:0]   mac_latch_valid;
    reg [TAG_BITS-1:0]     mac_latch_tag   [0:N_CHANNELS-1];
    reg [DATA_BITS-1:0]    mac_latch_data  [0:N_CHANNELS-1];
    reg [DATA_BITS-1:0]    mac_latch_hi    [0:N_CHANNELS-1];

    // Latch incoming results
    always @(posedge clk) begin : latch_results
        integer k;
        if (rst) begin
            mac_latch_valid <= {N_CHANNELS{1'b0}};
        end else begin
            for (k = 0; k < N_CHANNELS; k = k + 1) begin
                if (mac_result_valid[k]) begin
                    mac_latch_valid[k] <= 1'b1;
                    mac_latch_tag[k]   <= mac_result_tag[k*TAG_BITS +: TAG_BITS];
                    mac_latch_data[k]  <= mac_result_data[k*DATA_BITS +: DATA_BITS];
                    mac_latch_hi[k]    <= mac_result_hi[k*DATA_BITS +: DATA_BITS];
                end
                // Clear latch when drained by arbiter
                if (drain_valid && drain_sel == k) begin
                    mac_latch_valid[k] <= 1'b0;
                end
            end
        end
    end

    // Round-robin drain arbiter
    reg [$clog2(N_CHANNELS)-1:0] drain_rr;
    reg [$clog2(N_CHANNELS)-1:0] drain_sel;
    reg                          drain_valid;

    always @(*) begin
        drain_valid = 1'b0;
        drain_sel   = drain_rr;
        begin : find_latch
            integer k;
            for (k = 0; k < N_CHANNELS; k = k + 1) begin
                if (mac_latch_valid[(drain_rr + k) % N_CHANNELS] && !drain_valid) begin
                    drain_sel   = (drain_rr + k) % N_CHANNELS;
                    drain_valid = 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst)
            drain_rr <= 0;
        else if (drain_valid)
            drain_rr <= (drain_sel + 1) % N_CHANNELS;
    end

    // Register the drained result for clean timing
    reg                    result_valid_r;
    reg [TAG_BITS-1:0]     result_tag_r;
    reg [DATA_BITS-1:0]    result_data_r;
    reg [DATA_BITS-1:0]    result_hi_r;

    always @(posedge clk) begin
        if (rst) begin
            result_valid_r <= 1'b0;
        end else begin
            result_valid_r <= drain_valid;
            if (drain_valid) begin
                result_tag_r   <= mac_latch_tag[drain_sel];
                result_data_r  <= mac_latch_data[drain_sel];
                result_hi_r    <= mac_latch_hi[drain_sel];
            end
        end
    end

    assign result_valid = result_valid_r;
    assign result_tag   = result_tag_r;
    assign result_data  = result_data_r;
    assign result_hi    = result_hi_r;

    // ===================================================================
    // Status outputs
    // ===================================================================
    assign busy = de_busy;
    assign done = de_done;
    assign irq  = de_irq;

endmodule

`default_nettype wire
