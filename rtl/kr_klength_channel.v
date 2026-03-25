// Copyright 2026 Kyudoka Research, H. Ismail
// KR k-Length Computing — Single Scheduler Channel (forked from KR-6404)
//
// Production variant: events, perf counters, and stat readout removed.
// Saves ~120 LUTs + 80 FFs per channel vs instrumented version.
//
// Pipeline: Queue -> Decode -> RS Table -> Delay FU -> CDB -> Result
// Issue-to-CDB latency: 1 cycle (ROUTE/RIPUP/BLOCK/FANOUT), variable (DEMAND)
`default_nettype none

module kr_klength_channel #(
    parameter CHANNEL_ID    = 0,
    parameter N_RS_ENTRIES  = 32,
    parameter TAG_BITS      = 5,
    parameter DATA_BITS     = 32,
    parameter REG_ADDR_BITS = 5,
    parameter QUEUE_DEPTH   = 512
) (
    input  wire                    clk,
    input  wire                    rst,

    // Instruction input
    input  wire                    instr_valid,
    input  wire [31:0]             instr_data,
    output wire                    instr_ready,

    // Result output
    output wire                    result_valid,
    output wire [DATA_BITS-1:0]    result_data,
    output wire [REG_ADDR_BITS-1:0] result_dest_reg,
    output wire [TAG_BITS-1:0]     result_tag,
    output wire [3:0]              result_opcode,

    // Status
    output wire                    channel_busy
);

    // ---------------------------------------------------------------
    // Internal wires
    // ---------------------------------------------------------------

    // Issue queue signals
    wire        queue_empty;
    wire        queue_full;
    wire [9:0]  queue_count;
    wire [31:0] queue_rd_data;
    wire        queue_rd_en;

    // Decode signals
    wire        decode_valid;
    wire [3:0]  decode_opcode;
    wire [REG_ADDR_BITS-1:0] decode_dest;
    wire [REG_ADDR_BITS-1:0] decode_src1;
    wire [REG_ADDR_BITS-1:0] decode_src2;
    wire [12:0] decode_imm;
    wire        decode_src1_ready;
    wire [TAG_BITS-1:0] decode_src1_tag;
    wire [DATA_BITS-1:0] decode_src1_value;
    wire        decode_src2_ready;
    wire [TAG_BITS-1:0] decode_src2_tag;
    wire [DATA_BITS-1:0] decode_src2_value;
    wire        decode_uses_imm;

    // Scoreboard signals
    wire [31:0]              sb_busy_flat;
    wire [TAG_BITS*32-1:0]   sb_tag_flat;

    // RS Table signals
    wire        rs_full;
    wire        alloc_ack;
    wire [TAG_BITS-1:0] alloc_entry_idx;
    wire        rs_issue_valid;
    wire [TAG_BITS-1:0] rs_issue_entry;
    wire [3:0]  rs_issue_opcode;
    wire [DATA_BITS-1:0] rs_issue_src1_value;
    wire [DATA_BITS-1:0] rs_issue_src2_value;
    wire [TAG_BITS-1:0] rs_issue_dest_tag;
    wire [4:0]  rs_issue_dest_reg;
    wire [12:0] rs_issue_imm;
    wire        rs_issue_ack;
    wire [N_RS_ENTRIES-1:0] rs_occupancy;

    // CDB signals
    wire        cdb_valid;
    wire [TAG_BITS-1:0] cdb_tag;
    wire [DATA_BITS-1:0] cdb_data;
    wire [4:0]  cdb_dest_reg;
    wire [3:0]  cdb_opcode;
    wire        cdb_carry;       // k-length carry propagation
    wire        fu_result_carry; // carry from FU

    // Delay FU signals
    wire        fu_result_valid;
    wire [TAG_BITS-1:0] fu_result_tag;
    wire [DATA_BITS-1:0] fu_result_data;
    wire [4:0]  fu_result_dest_reg;
    wire [3:0]  fu_result_opcode;
    wire        fu_busy;
    wire        fu_ack;

    // Single FU — issue ack when FU is not busy
    assign rs_issue_ack = rs_issue_valid & ~fu_busy;

    // Decode control: pop from queue when queue not empty and RS not full
    wire decode_input_valid = ~queue_empty & ~rs_full;

    // Queue read: registered to avoid combinational loop through BRAM
    reg queue_rd_en_r;
    always @(posedge clk) begin
        if (rst)
            queue_rd_en_r <= 1'b0;
        else
            queue_rd_en_r <= decode_input_valid & ~queue_empty;
    end

    // Pipeline stage for BRAM 1-cycle read latency
    reg        queue_data_valid;
    reg [31:0] queue_data_latched;

    always @(posedge clk) begin
        if (rst) begin
            queue_data_valid  <= 1'b0;
            queue_data_latched <= 32'b0;
        end else begin
            queue_data_valid <= queue_rd_en;
            queue_data_latched <= queue_rd_data;
        end
    end

    assign queue_rd_en = decode_input_valid & ~queue_empty & ~queue_data_valid;

    // Stall decode when RS is full
    wire decode_stall = rs_full;

    // ---------------------------------------------------------------
    // Output assignments
    // ---------------------------------------------------------------
    // Registered ready — breaks combinational path through distributor
    reg instr_ready_r;
    always @(posedge clk) begin
        if (rst)
            instr_ready_r <= 1'b0;
        else
            instr_ready_r <= ~queue_full;
    end
    assign instr_ready  = instr_ready_r;
    assign channel_busy = ~queue_empty | (|rs_occupancy) | fu_busy;

    assign result_valid    = cdb_valid;
    assign result_data     = cdb_data;
    assign result_dest_reg = cdb_dest_reg;
    assign result_tag      = cdb_tag;
    assign result_opcode   = cdb_opcode;

    // ---------------------------------------------------------------
    // Module instantiations
    // ---------------------------------------------------------------

    // Instruction queue FIFO
    kr_klength_issue_queue #(
        .DEPTH     (QUEUE_DEPTH),
        .DATA_BITS (32)
    ) u_issue_queue (
        .clk     (clk),
        .rst     (rst),
        .wr_en   (instr_valid & ~queue_full),
        .wr_data (instr_data),
        .rd_en   (queue_rd_en),
        .rd_data (queue_rd_data),
        .empty   (queue_empty),
        .full    (queue_full),
        .count   (queue_count)
    );

    // Instruction decoder + register rename (routing opcodes)
    kr_klength_decode #(
        .N_RS_ENTRIES  (N_RS_ENTRIES),
        .TAG_BITS      (TAG_BITS),
        .REG_ADDR_BITS (REG_ADDR_BITS),
        .DATA_BITS     (DATA_BITS)
    ) u_decode (
        .clk             (clk),
        .rst             (rst),
        .instr_valid     (queue_data_valid),
        .instr_data      (queue_data_latched),
        .stall           (decode_stall),
        .sb_busy         (sb_busy_flat),
        .sb_tag_flat     (sb_tag_flat),
        .rf_wr_en        (cdb_valid),
        .rf_wr_addr      (cdb_dest_reg),
        .rf_wr_data      (cdb_data),
        .decode_valid    (decode_valid),
        .decode_opcode   (decode_opcode),
        .decode_dest     (decode_dest),
        .decode_src1     (decode_src1),
        .decode_src2     (decode_src2),
        .decode_imm      (decode_imm),
        .decode_src1_ready (decode_src1_ready),
        .decode_src1_tag   (decode_src1_tag),
        .decode_src1_value (decode_src1_value),
        .decode_src2_ready (decode_src2_ready),
        .decode_src2_tag   (decode_src2_tag),
        .decode_src2_value (decode_src2_value),
        .decode_uses_imm   (decode_uses_imm)
    );

    // Register scoreboard
    kr_klength_scoreboard #(
        .N_REGS        (32),
        .TAG_BITS      (TAG_BITS),
        .REG_ADDR_BITS (REG_ADDR_BITS)
    ) u_scoreboard (
        .clk          (clk),
        .rst          (rst),
        .rename_valid (alloc_ack),
        .rename_rd    (decode_dest),
        .rename_tag   (alloc_entry_idx),
        .cdb_valid    (cdb_valid),
        .cdb_tag      (cdb_tag),
        .rd_addr1     (5'b0),
        .busy1        (),
        .tag1         (),
        .rd_addr2     (5'b0),
        .busy2        (),
        .tag2         (),
        .sb_busy_flat (sb_busy_flat),
        .sb_tag_flat  (sb_tag_flat)
    );

    // Reservation station table (with imm forwarding)
    kr_klength_rs_table #(
        .N_ENTRIES   (N_RS_ENTRIES),
        .TAG_BITS    (TAG_BITS),
        .DATA_BITS   (DATA_BITS),
        .OPCODE_BITS (4)
    ) u_rs_table (
        .clk              (clk),
        .rst              (rst),
        .alloc_valid      (decode_valid),
        .alloc_opcode     (decode_opcode),
        .alloc_src1_ready (decode_src1_ready),
        .alloc_src1_tag   (decode_src1_tag),
        .alloc_src1_value (decode_src1_value),
        .alloc_src2_ready (decode_src2_ready),
        .alloc_src2_tag   (decode_src2_tag),
        .alloc_src2_value (decode_src2_value),
        .alloc_dest_tag   (alloc_entry_idx),
        .alloc_dest_reg   (decode_dest),
        .alloc_imm        (decode_imm),
        .alloc_uses_imm   (decode_uses_imm),
        .alloc_ack        (alloc_ack),
        .alloc_entry_idx  (alloc_entry_idx),
        .cdb_valid        (cdb_valid),
        .cdb_tag          (cdb_tag),
        .cdb_data         (cdb_data),
        .issue_valid      (rs_issue_valid),
        .issue_entry      (rs_issue_entry),
        .issue_opcode     (rs_issue_opcode),
        .issue_src1_value (rs_issue_src1_value),
        .issue_src2_value (rs_issue_src2_value),
        .issue_dest_tag   (rs_issue_dest_tag),
        .issue_dest_reg   (rs_issue_dest_reg),
        .issue_imm        (rs_issue_imm),
        .issue_ack        (rs_issue_ack),
        .rs_full          (rs_full),
        .rs_occupancy     (rs_occupancy)
    );

    // Simplified CDB (single FU input, no arbitration)
    kr_klength_cdb #(
        .TAG_BITS  (TAG_BITS),
        .DATA_BITS (DATA_BITS)
    ) u_cdb (
        .clk          (clk),
        .rst          (rst),
        .fu_valid     (fu_result_valid),
        .fu_tag       (fu_result_tag),
        .fu_data      (fu_result_data),
        .fu_dest_reg  (fu_result_dest_reg),
        .fu_opcode    (fu_result_opcode),
        .fu_carry     (fu_result_carry),
        .fu_ack       (fu_ack),
        .cdb_valid    (cdb_valid),
        .cdb_tag      (cdb_tag),
        .cdb_data     (cdb_data),
        .cdb_dest_reg (cdb_dest_reg),
        .cdb_opcode   (cdb_opcode),
        .cdb_carry    (cdb_carry)
    );

    // Programmable delay FU (1-cycle for ROUTE/RIPUP/BLOCK/FANOUT, variable for DEMAND)
    kr_klength_fu_delay #(
        .TAG_BITS  (TAG_BITS),
        .DATA_BITS (DATA_BITS)
    ) u_fu_delay (
        .clk            (clk),
        .rst            (rst),
        .fu_valid       (rs_issue_valid & ~fu_busy),
        .fu_opcode      (rs_issue_opcode),
        .fu_src1        (rs_issue_src1_value),
        .fu_src2        (rs_issue_src2_value),
        .fu_tag         (rs_issue_dest_tag),
        .fu_dest_reg    (rs_issue_dest_reg),
        .fu_imm         (rs_issue_imm),
        .result_valid   (fu_result_valid),
        .result_tag     (fu_result_tag),
        .result_data    (fu_result_data),
        .result_dest_reg(fu_result_dest_reg),
        .result_opcode  (fu_result_opcode),
        .fu_busy        (fu_busy)
    );

endmodule

`default_nettype wire
