// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
// KR k-Length Computing — 384-Channel Banked Integration Top
//
// 8 banks × 48 MAC channels = 384 parallel multiply-accumulate units.
// 2-stage registered dispatch and collection for timing closure at 200 MHz.
// Tag recycling via BRAM-backed free-list — unlimited operand lengths.
//
// Architecture:
//   Decomp Engine → Tag Alloc → Bank Select (reg) → MAC Select (reg) → 384 MACs
//   384 MACs → Per-Bank Latch+Drain (reg) → Inter-Bank Merge (reg) → Hi Table
//   Hi Table → Decomp Engine (result writeback + accumulator resolution)
//
`default_nettype none

module kr_klength_banked_top #(
    parameter N_BANKS     = 8,
    parameter CH_PER_BANK = 48,
    parameter TAG_BITS    = 12,
    parameter DATA_BITS   = 32,
    parameter BRAM_ADDR_W = 15,
    parameter MAX_WORDS   = 256
) (
    input  wire        clk,
    input  wire        rst,

    // Wishbone slave: register interface
    input  wire [31:0] wb_regs_adr_i,
    input  wire [31:0] wb_regs_dat_i,
    output wire [31:0] wb_regs_dat_o,
    input  wire        wb_regs_we_i,
    input  wire        wb_regs_stb_i,
    output wire        wb_regs_ack_o,

    // Wishbone slave: BRAM port A (RISC-V side)
    input  wire [31:0] wb_bram_adr_i,
    input  wire [31:0] wb_bram_dat_i,
    output wire [31:0] wb_bram_dat_o,
    input  wire        wb_bram_we_i,
    input  wire        wb_bram_stb_i,
    output wire        wb_bram_ack_o,

    // Status
    output wire        busy,
    output wire        done,
    output wire        irq
);

    localparam N_TOTAL = N_BANKS * CH_PER_BANK; // 384
    localparam BANK_BITS = $clog2(N_BANKS);     // 3
    localparam CH_BITS   = $clog2(CH_PER_BANK); // 6

    // ===================================================================
    // Command interface: Regs ↔ Decomp Engine
    // ===================================================================
    wire                    cmd_valid, cmd_ready;
    wire [3:0]              cmd_opcode;
    wire [BRAM_ADDR_W-1:0]  cmd_src_a, cmd_src_b, cmd_dst;
    wire [15:0]             cmd_len_a, cmd_len_b;
    wire                    de_busy, de_done, de_irq;
    wire [31:0]             de_uops_issued, de_uops_completed, de_cycle_count;
    wire                    de_err_unsupported;
    // Phase E: Speculation statistics from decomp engine
    wire [31:0]             de_speculation_correct, de_speculation_replays;

    // ===================================================================
    // BRAM interface
    // ===================================================================
    wire                    de_bram_rd_en;
    wire [BRAM_ADDR_W-1:0]  de_bram_rd_addr;
    wire [DATA_BITS-1:0]    de_bram_rd_data;
    reg                     de_bram_rd_valid;
    wire                    de_bram_wr_en;
    wire [BRAM_ADDR_W-1:0]  de_bram_wr_addr;
    wire [DATA_BITS-1:0]    de_bram_wr_data;

    // ===================================================================
    // Micro-op interface: Decomp Engine ↔ Dispatch
    // ===================================================================
    wire                    uop_valid, uop_ready;
    wire [3:0]              uop_opcode;
    wire [DATA_BITS-1:0]    uop_src1, uop_src2;
    wire [TAG_BITS-1:0]     uop_tag;
    wire                    uop_dep_valid;
    wire [TAG_BITS-1:0]     uop_dep_tag;

    // ===================================================================
    // Result bus (from inter-bank merge → decomp engine)
    // N2 fix: result_hi is full 32-bit high word, not 1-bit
    // ===================================================================
    wire                    result_valid;
    wire [TAG_BITS-1:0]     result_tag;
    wire [DATA_BITS-1:0]    result_data;
    wire [DATA_BITS-1:0]    result_hi;

    // ===================================================================
    // Per-bank signals
    // N2 fix: mac_result_hi widened to 32 bits per MAC
    // ===================================================================
    // MAC busy (flat across all banks)
    wire [N_TOTAL-1:0]                      mac_fu_busy;
    wire [N_TOTAL-1:0]                      mac_fu_valid;
    wire [N_TOTAL-1:0]                      mac_result_valid;
    wire [N_TOTAL*DATA_BITS-1:0]            mac_result_hi;
    wire [N_TOTAL*DATA_BITS-1:0]            mac_result_data;
    wire [N_TOTAL*TAG_BITS-1:0]             mac_result_tag;

    // Per-bank "has a free MAC" signal
    wire [N_BANKS-1:0] bank_has_free;

    genvar bi, ci;
    generate
        for (bi = 0; bi < N_BANKS; bi = bi + 1) begin : gen_bank_free
            assign bank_has_free[bi] = |(~mac_fu_busy[bi*CH_PER_BANK +: CH_PER_BANK]);
        end
    endgenerate

    // ===================================================================
    // High-Word Resolution Table (N3 fix: was carry_table, now hi_table)
    // ===================================================================
    // Stores the full 32-bit high word from each completed micro-op.
    // For ADDWC/SUBWB: only bit 0 is meaningful (carry/borrow).
    // For MULFULL/ADDMUL: full 32-bit high word (accumulator for next op).
    //
    // Size: 2^TAG_BITS entries × 32 bits. For TAG_BITS=12: 128 KB (BRAM).
    (* ram_style = "block" *)
    reg [DATA_BITS-1:0] hi_table [0:(1<<TAG_BITS)-1];

    // Updated from registered result output (inter-bank merge)
    always @(posedge clk) begin
        if (result_valid)
            hi_table[result_tag] <= result_hi;
    end

    // N3 fix: resolved_acc is full 32-bit, not 1-bit carry
    wire [DATA_BITS-1:0] resolved_acc = (uop_dep_valid && uop_valid)
                                        ? hi_table[uop_dep_tag]
                                        : {DATA_BITS{1'b0}};

    // ===================================================================
    // BRAM Port A: Wishbone adapter (RISC-V side)
    // ===================================================================
    wire [BRAM_ADDR_W-1:0] bram_a_addr = wb_bram_adr_i[BRAM_ADDR_W+1:2];
    wire [DATA_BITS-1:0]   bram_a_dout;
    reg                    bram_a_ack;

    always @(posedge clk) begin
        if (rst) bram_a_ack <= 1'b0;
        else     bram_a_ack <= wb_bram_stb_i && !bram_a_ack;
    end

    assign wb_bram_dat_o = bram_a_dout;
    assign wb_bram_ack_o = bram_a_ack;

    // ===================================================================
    // BRAM Port B: decomp read + result writeback (write priority)
    // ===================================================================
    wire bram_b_en   = de_bram_rd_en | de_bram_wr_en;
    wire bram_b_we   = de_bram_wr_en;
    wire [BRAM_ADDR_W-1:0] bram_b_addr = de_bram_wr_en ? de_bram_wr_addr : de_bram_rd_addr;
    wire [DATA_BITS-1:0]   bram_b_din  = de_bram_wr_data;
    wire [DATA_BITS-1:0]   bram_b_dout;

    always @(posedge clk) begin
        if (rst) de_bram_rd_valid <= 1'b0;
        else     de_bram_rd_valid <= de_bram_rd_en && !de_bram_wr_en;
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
        .a_en   (wb_bram_stb_i),
        .a_we   (wb_bram_we_i && wb_bram_stb_i),
        .a_addr (bram_a_addr),
        .a_din  (wb_bram_dat_i),
        .a_dout (bram_a_dout),
        .b_en   (bram_b_en),
        .b_we   (bram_b_we),
        .b_addr (bram_b_addr),
        .b_din  (bram_b_din),
        .b_dout (bram_b_dout)
    );

    // ===================================================================
    // Module: Register Interface
    // ===================================================================
    kr_klength_regs #(
        .BRAM_ADDR_W (BRAM_ADDR_W)
    ) u_regs (
        .clk (clk), .rst (rst),
        .wb_adr_i (wb_regs_adr_i), .wb_dat_i (wb_regs_dat_i),
        .wb_dat_o (wb_regs_dat_o), .wb_we_i (wb_regs_we_i),
        .wb_stb_i (wb_regs_stb_i), .wb_ack_o (wb_regs_ack_o),
        .cmd_valid (cmd_valid), .cmd_ready (cmd_ready),
        .cmd_opcode (cmd_opcode),
        .cmd_src_a (cmd_src_a), .cmd_src_b (cmd_src_b), .cmd_dst (cmd_dst),
        .cmd_len_a (cmd_len_a), .cmd_len_b (cmd_len_b),
        .de_busy (de_busy), .de_done (de_done),
        .de_uops_issued (de_uops_issued), .de_uops_completed (de_uops_completed),
        .de_cycle_count (de_cycle_count),
        // Watchdog status (tied off — instantiate separately if needed)
        .wd_timeout_alert (1'b0), .wd_all_complete (1'b0),
        .wd_missing_count (32'd0), .wd_timeout_tag (12'd0),
        // Phase E: Speculation statistics
        .de_speculation_correct (de_speculation_correct),
        .de_speculation_replays (de_speculation_replays)
    );

    // ===================================================================
    // Module: Decomposition Engine
    // N4 fix: .result_carry(result_hi[0]) — decomp expects 1-bit carry
    // ===================================================================
    kr_decomp_engine #(
        .TAG_BITS (TAG_BITS), .DATA_BITS (DATA_BITS),
        .MAX_WORDS (MAX_WORDS), .BRAM_ADDR_W (BRAM_ADDR_W),
        .SPECULATIVE_CARRY(1)  // Phase E: speculative carry prediction
    ) u_decomp (
        .clk (clk), .rst (rst),
        .cmd_valid (cmd_valid), .cmd_ready (cmd_ready),
        .cmd_opcode (cmd_opcode),
        .cmd_src_a (cmd_src_a), .cmd_src_b (cmd_src_b), .cmd_dst (cmd_dst),
        .cmd_len_a (cmd_len_a), .cmd_len_b (cmd_len_b),
        .bram_rd_en (de_bram_rd_en), .bram_rd_addr (de_bram_rd_addr),
        .bram_rd_data (de_bram_rd_data), .bram_rd_valid (de_bram_rd_valid),
        .bram_wr_en (de_bram_wr_en), .bram_wr_addr (de_bram_wr_addr),
        .bram_wr_data (de_bram_wr_data),
        .uop_valid (uop_valid), .uop_ready (uop_ready),
        .uop_opcode (uop_opcode), .uop_src1 (uop_src1), .uop_src2 (uop_src2),
        .uop_tag (uop_tag), .uop_dep_valid (uop_dep_valid), .uop_dep_tag (uop_dep_tag),
        .result_valid (result_valid), .result_tag (result_tag),
        .result_data (result_data), .result_carry (result_hi[0]),
        .busy (de_busy), .done (de_done), .irq (de_irq),
        .uops_issued (de_uops_issued), .uops_completed (de_uops_completed),
        .cycle_count (de_cycle_count),
        .err_unsupported (de_err_unsupported),
        // Phase E: Speculation statistics
        .speculation_correct (de_speculation_correct),
        .speculation_replays (de_speculation_replays)
    );

    // ===================================================================
    // Stage 1: Bank Selection (registered)
    // N3 fix: s1_acc is full 32-bit accumulator (was 1-bit s1_carry_in)
    // ===================================================================
    reg [BANK_BITS-1:0]    s1_bank_rr;     // round-robin bank pointer
    reg [BANK_BITS-1:0]    s1_bank_sel;     // selected bank
    reg                    s1_valid;        // stage 1 has a valid micro-op
    reg [3:0]              s1_opcode;
    reg [DATA_BITS-1:0]    s1_src1, s1_src2;
    reg [TAG_BITS-1:0]     s1_tag;
    reg [DATA_BITS-1:0]    s1_acc;

    // Find a free bank (combinational, starting from round-robin pointer)
    reg [BANK_BITS-1:0]    s1_bank_found;
    reg                    s1_found;

    always @(*) begin
        s1_found      = 1'b0;
        s1_bank_found = s1_bank_rr;
        begin : find_bank
            integer k;
            for (k = 0; k < N_BANKS; k = k + 1) begin
                if (bank_has_free[(s1_bank_rr + k) % N_BANKS] && !s1_found) begin
                    s1_bank_found = (s1_bank_rr + k) % N_BANKS;
                    s1_found      = 1'b1;
                end
            end
        end
    end

    // Accept micro-op from decomp when stage 1 is empty and a bank is free
    wire s1_accept = !s1_valid && s1_found;
    assign uop_ready = s1_accept;

    always @(posedge clk) begin
        if (rst) begin
            s1_valid    <= 1'b0;
            s1_bank_rr  <= {BANK_BITS{1'b0}};
        end else begin
            // Drain stage 1 when stage 2 accepts
            if (s1_valid && s2_accept)
                s1_valid <= 1'b0;

            // Fill stage 1 from decomp engine
            if (uop_valid && s1_accept) begin
                s1_valid    <= 1'b1;
                s1_bank_sel <= s1_bank_found;
                s1_opcode   <= uop_opcode;
                s1_src1     <= uop_src1;
                s1_src2     <= uop_src2;
                s1_tag      <= uop_tag;
                s1_acc      <= resolved_acc;
                s1_bank_rr  <= (s1_bank_found + 1) % N_BANKS;
            end
        end
    end

    // ===================================================================
    // Stage 2: Intra-Bank MAC Selection (registered)
    // N3 fix: s2_acc is full 32-bit accumulator (was 1-bit s2_carry_in)
    // ===================================================================
    reg [BANK_BITS-1:0]    s2_bank;
    reg [CH_BITS-1:0]      s2_mac;
    reg                    s2_valid;
    reg [3:0]              s2_opcode;
    reg [DATA_BITS-1:0]    s2_src1, s2_src2;
    reg [TAG_BITS-1:0]     s2_tag;
    reg [DATA_BITS-1:0]    s2_acc;

    // Per-bank round-robin MAC pointers
    reg [CH_BITS-1:0] mac_rr [0:N_BANKS-1];

    // Find free MAC within selected bank (combinational)
    reg [CH_BITS-1:0] s2_mac_found;
    reg               s2_found;

    always @(*) begin
        s2_found     = 1'b0;
        s2_mac_found = mac_rr[s1_bank_sel];
        begin : find_mac
            integer k;
            for (k = 0; k < CH_PER_BANK; k = k + 1) begin
                if (!mac_fu_busy[s1_bank_sel * CH_PER_BANK +
                     ((mac_rr[s1_bank_sel] + k) % CH_PER_BANK)] && !s2_found) begin
                    s2_mac_found = (mac_rr[s1_bank_sel] + k) % CH_PER_BANK;
                    s2_found     = 1'b1;
                end
            end
        end
    end

    wire s2_accept = !s2_valid || s2_dispatch_done;
    wire s2_dispatch_done = s2_valid; // stage 2 always dispatches in 1 cycle

    always @(posedge clk) begin : stage2_reg
        integer k;
        if (rst) begin
            s2_valid <= 1'b0;
            for (k = 0; k < N_BANKS; k = k + 1)
                mac_rr[k] <= {CH_BITS{1'b0}};
        end else begin
            s2_valid <= 1'b0; // default: stage 2 consumed

            if (s1_valid && s2_accept && s2_found) begin
                s2_valid    <= 1'b1;
                s2_bank     <= s1_bank_sel;
                s2_mac      <= s2_mac_found;
                s2_opcode   <= s1_opcode;
                s2_src1     <= s1_src1;
                s2_src2     <= s1_src2;
                s2_tag      <= s1_tag;
                s2_acc      <= s1_acc;
                mac_rr[s1_bank_sel] <= (s2_mac_found + 1) % CH_PER_BANK;
            end
        end
    end

    // ===================================================================
    // MAC Functional Unit Bank: 384 instances
    // N1 fix: ports match redesigned kr_klength_fu_mac
    //   - Removed fu_dest_reg, fu_imm, result_dest_reg (don't exist)
    //   - Added fu_acc (32-bit accumulator)
    //   - result_hi uses 32-bit slice, not 1-bit index
    //   - result_opcode left open (unused)
    // ===================================================================
    // Drive fu_valid to exactly one MAC based on stage 2 selection
    generate
        for (bi = 0; bi < N_BANKS; bi = bi + 1) begin : gen_bank
            for (ci = 0; ci < CH_PER_BANK; ci = ci + 1) begin : gen_mac
                localparam integer IDX = bi * CH_PER_BANK + ci;

                wire this_mac_valid = s2_valid &&
                                      (s2_bank == bi) &&
                                      (s2_mac == ci);

                assign mac_fu_valid[IDX] = this_mac_valid;

                kr_klength_fu_mac #(
                    .TAG_BITS  (TAG_BITS),
                    .DATA_BITS (DATA_BITS)
                ) u_mac (
                    .clk            (clk),
                    .rst            (rst),
                    .fu_valid       (this_mac_valid),
                    .fu_opcode      (s2_opcode),
                    .fu_src1        (s2_src1),
                    .fu_src2        (s2_src2),
                    .fu_tag         (s2_tag),
                    .fu_acc         (s2_acc),
                    .result_valid   (mac_result_valid[IDX]),
                    .result_tag     (mac_result_tag[IDX*TAG_BITS +: TAG_BITS]),
                    .result_data    (mac_result_data[IDX*DATA_BITS +: DATA_BITS]),
                    .result_hi      (mac_result_hi[IDX*DATA_BITS +: DATA_BITS]),
                    .result_opcode  (),
                    .fu_busy        (mac_fu_busy[IDX])
                );
            end
        end
    endgenerate

    // ===================================================================
    // Per-Bank Result Latch + Drain
    // N2 fix: all hi signals widened to 32 bits
    // ===================================================================
    // Each bank latches its 48 MAC results independently.
    // Per-bank round-robin drain produces 1 result/cycle per bank.

    wire [N_BANKS-1:0]                 bank_drain_valid;
    wire [N_BANKS*TAG_BITS-1:0]        bank_drain_tag;
    wire [N_BANKS*DATA_BITS-1:0]       bank_drain_data;
    wire [N_BANKS*DATA_BITS-1:0]       bank_drain_hi;

    generate
        for (bi = 0; bi < N_BANKS; bi = bi + 1) begin : gen_bank_collect

            // Per-MAC result latches within this bank
            // N2 fix: latch_hi is an array of DATA_BITS-wide regs
            reg [CH_PER_BANK-1:0]   latch_valid;
            reg [TAG_BITS-1:0]      latch_tag   [0:CH_PER_BANK-1];
            reg [DATA_BITS-1:0]     latch_data  [0:CH_PER_BANK-1];
            reg [DATA_BITS-1:0]     latch_hi    [0:CH_PER_BANK-1];

            reg [CH_BITS-1:0]       drain_rr;
            reg [CH_BITS-1:0]       drain_sel;
            reg                     drain_found;

            // Latch MAC results
            always @(posedge clk) begin : latch_block
                integer k;
                if (rst) begin
                    latch_valid <= {CH_PER_BANK{1'b0}};
                end else begin
                    for (k = 0; k < CH_PER_BANK; k = k + 1) begin
                        if (mac_result_valid[bi*CH_PER_BANK + k]) begin
                            latch_valid[k] <= 1'b1;
                            latch_tag[k]   <= mac_result_tag[(bi*CH_PER_BANK+k)*TAG_BITS +: TAG_BITS];
                            latch_data[k]  <= mac_result_data[(bi*CH_PER_BANK+k)*DATA_BITS +: DATA_BITS];
                            latch_hi[k]    <= mac_result_hi[(bi*CH_PER_BANK+k)*DATA_BITS +: DATA_BITS];
                        end
                        // Clear when drained
                        if (drain_found && drain_sel == k)
                            latch_valid[k] <= 1'b0;
                    end
                end
            end

            // Round-robin drain within bank
            always @(*) begin
                drain_found = 1'b0;
                drain_sel   = drain_rr;
                begin : find_latch
                    integer k;
                    for (k = 0; k < CH_PER_BANK; k = k + 1) begin
                        if (latch_valid[(drain_rr + k) % CH_PER_BANK] && !drain_found) begin
                            drain_sel   = (drain_rr + k) % CH_PER_BANK;
                            drain_found = 1'b1;
                        end
                    end
                end
            end

            always @(posedge clk) begin
                if (rst) drain_rr <= {CH_BITS{1'b0}};
                else if (drain_found)
                    drain_rr <= (drain_sel + 1) % CH_PER_BANK;
            end

            // Registered bank drain output
            // N2 fix: bank_drain_hi_r widened to DATA_BITS
            reg                    bank_drain_valid_r;
            reg [TAG_BITS-1:0]     bank_drain_tag_r;
            reg [DATA_BITS-1:0]    bank_drain_data_r;
            reg [DATA_BITS-1:0]    bank_drain_hi_r;

            always @(posedge clk) begin
                if (rst) bank_drain_valid_r <= 1'b0;
                else begin
                    bank_drain_valid_r <= drain_found;
                    if (drain_found) begin
                        bank_drain_tag_r   <= latch_tag[drain_sel];
                        bank_drain_data_r  <= latch_data[drain_sel];
                        bank_drain_hi_r    <= latch_hi[drain_sel];
                    end
                end
            end

            assign bank_drain_valid[bi]                          = bank_drain_valid_r;
            assign bank_drain_tag[bi*TAG_BITS +: TAG_BITS]       = bank_drain_tag_r;
            assign bank_drain_data[bi*DATA_BITS +: DATA_BITS]    = bank_drain_data_r;
            assign bank_drain_hi[bi*DATA_BITS +: DATA_BITS]      = bank_drain_hi_r;

        end
    endgenerate

    // ===================================================================
    // Inter-Bank Result Merge (round-robin, registered)
    // ===================================================================
    reg [BANK_BITS-1:0] merge_rr;
    reg [BANK_BITS-1:0] merge_sel;
    reg                 merge_found;

    always @(*) begin
        merge_found = 1'b0;
        merge_sel   = merge_rr;
        begin : find_bank_result
            integer k;
            for (k = 0; k < N_BANKS; k = k + 1) begin
                if (bank_drain_valid[(merge_rr + k) % N_BANKS] && !merge_found) begin
                    merge_sel   = (merge_rr + k) % N_BANKS;
                    merge_found = 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst) merge_rr <= {BANK_BITS{1'b0}};
        else if (merge_found)
            merge_rr <= (merge_sel + 1) % N_BANKS;
    end

    // Final registered result output
    // N2 fix: result_hi_r widened to DATA_BITS
    reg                    result_valid_r;
    reg [TAG_BITS-1:0]     result_tag_r;
    reg [DATA_BITS-1:0]    result_data_r;
    reg [DATA_BITS-1:0]    result_hi_r;

    always @(posedge clk) begin
        if (rst) result_valid_r <= 1'b0;
        else begin
            result_valid_r <= merge_found;
            if (merge_found) begin
                result_tag_r   <= bank_drain_tag[merge_sel*TAG_BITS +: TAG_BITS];
                result_data_r  <= bank_drain_data[merge_sel*DATA_BITS +: DATA_BITS];
                result_hi_r    <= bank_drain_hi[merge_sel*DATA_BITS +: DATA_BITS];
            end
        end
    end

    assign result_valid = result_valid_r;
    assign result_tag   = result_tag_r;
    assign result_data  = result_data_r;
    assign result_hi    = result_hi_r;

    // ===================================================================
    // Status
    // ===================================================================
    assign busy = de_busy;
    assign done = de_done;
    assign irq  = de_irq;

endmodule

`default_nettype wire
