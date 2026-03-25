// Copyright 2026 Kyudoka Research, H. Ismail
// KR 25632-125 — Instruction Decoder + Register Rename for Routing Scheduler
//
// Routing-specific opcode set:
//   ROUTE  (0): rd=output_region, rs1=dep_region1, rs2=dep_region2, imm=net_idx
//               Issues when both source regions are free.
//   RIPUP  (1): rd=region, rs1=dep_region, imm=net_idx
//               Same dependency tracking but signals rip-up intent. rs2 unused (=31).
//   BLOCK  (2): rd=region, imm=node_hash
//               Reserve a region, no source dependencies (rs1=rs2=31).
//   FANOUT (3): rd=hub_region, rs1=dep, rs2=dep2, imm=net_idx
//               Marks a high-fanout net. Same RS/CDB flow as ROUTE.
//   DEMAND (4): rd=region, rs1=31, rs2=31, imm=demand_count
//               Pre-register congestion demand. No dependencies (always-ready).
//               Delay FU stalls dependents by imm[3:0] cycles.
//   NOP   (15): No-op, used for polling results.
//
// Instruction format (32-bit):
//   [31:28] opcode
//   [27:23] rd    (destination register / region)
//   [22:18] rs1   (source 1 / dependency region 1)
//   [17:13] rs2   (source 2 / dependency region 2)
//   [12:0]  imm   (net_idx or node_hash)
`default_nettype none

module kr_klength_decode #(
    parameter N_RS_ENTRIES   = 32,
    parameter TAG_BITS       = 5,
    parameter REG_ADDR_BITS  = 5,
    parameter DATA_BITS      = 32
) (
    input  wire                    clk,
    input  wire                    rst,

    // Instruction input
    input  wire                    instr_valid,
    input  wire [31:0]             instr_data,
    input  wire                    stall,

    // Scoreboard read ports (combinational)
    input  wire [31:0]             sb_busy,
    input  wire [TAG_BITS*32-1:0]  sb_tag_flat,

    // Register file write port (from CDB/writeback)
    input  wire                    rf_wr_en,
    input  wire [REG_ADDR_BITS-1:0] rf_wr_addr,
    input  wire [DATA_BITS-1:0]    rf_wr_data,

    // Decoded output (registered)
    output reg                     decode_valid,
    output reg  [3:0]              decode_opcode,
    output reg  [REG_ADDR_BITS-1:0] decode_dest,
    output reg  [REG_ADDR_BITS-1:0] decode_src1,
    output reg  [REG_ADDR_BITS-1:0] decode_src2,
    output reg  [12:0]             decode_imm,
    output reg                     decode_src1_ready,
    output reg  [TAG_BITS-1:0]     decode_src1_tag,
    output reg  [DATA_BITS-1:0]    decode_src1_value,
    output reg                     decode_src2_ready,
    output reg  [TAG_BITS-1:0]     decode_src2_tag,
    output reg  [DATA_BITS-1:0]    decode_src2_value,
    output reg                     decode_uses_imm
);

    // ---------------------------------------------------------------
    // Routing opcodes
    // ---------------------------------------------------------------
    localparam [3:0] OP_ROUTE  = 4'd0;
    localparam [3:0] OP_RIPUP  = 4'd1;
    localparam [3:0] OP_BLOCK  = 4'd2;
    localparam [3:0] OP_FANOUT = 4'd3;
    localparam [3:0] OP_DEMAND = 4'd4;
    localparam [3:0] OP_NOP    = 4'd15;

    // ---------------------------------------------------------------
    // Instruction field extraction (combinational)
    // ---------------------------------------------------------------
    wire [3:0]              opcode_w   = instr_data[31:28];
    wire [REG_ADDR_BITS-1:0] dest_w   = instr_data[27:23];
    wire [REG_ADDR_BITS-1:0] src1_w   = instr_data[22:18];
    wire [REG_ADDR_BITS-1:0] src2_w   = instr_data[17:13];
    wire [12:0]             imm_w     = instr_data[12:0];

    // BLOCK uses imm (no source deps), RIPUP uses imm (one source dep)
    // ROUTE has two source deps, imm carries net_idx for all three
    // For the RS table, uses_imm means src2 slot carries the immediate
    // RIPUP: rs2=31 (hardwired free), so src2 is effectively imm
    // BLOCK: rs1=rs2=31 (hardwired free), both sources ready immediately
    wire uses_imm_w = (opcode_w == OP_RIPUP) || (opcode_w == OP_BLOCK) || (opcode_w == OP_DEMAND);

    // NOP detection
    wire is_nop = (opcode_w == OP_NOP);

    // ---------------------------------------------------------------
    // Internal register file  (32 x DATA_BITS)
    // Represents region state — values are net_idx results from CDB
    // ---------------------------------------------------------------
    reg [DATA_BITS-1:0] regfile [0:31];

    integer rf_i;
    always @(posedge clk) begin
        if (rst) begin
            for (rf_i = 0; rf_i < 32; rf_i = rf_i + 1)
                regfile[rf_i] <= {DATA_BITS{1'b0}};
        end else if (rf_wr_en) begin
            regfile[rf_wr_addr] <= rf_wr_data;
        end
    end

    // ---------------------------------------------------------------
    // Scoreboard look-up (combinational)
    // ---------------------------------------------------------------
    wire src1_busy_w = sb_busy[src1_w];
    wire src2_busy_w = sb_busy[src2_w];

    wire [TAG_BITS-1:0] src1_sb_tag_w;
    wire [TAG_BITS-1:0] src2_sb_tag_w;

    assign src1_sb_tag_w = sb_tag_flat[src1_w * TAG_BITS +: TAG_BITS];
    assign src2_sb_tag_w = sb_tag_flat[src2_w * TAG_BITS +: TAG_BITS];

    // Source ready if NOT busy in scoreboard
    // For uses_imm instructions, src2 is the immediate — always ready
    wire src1_ready_w = ~src1_busy_w;
    wire src2_ready_w = uses_imm_w ? 1'b1 : ~src2_busy_w;

    // Source values from register file (placeholder when not ready)
    wire [DATA_BITS-1:0] src1_value_w = regfile[src1_w];
    wire [DATA_BITS-1:0] src2_value_w = uses_imm_w ? {{(DATA_BITS-13){imm_w[12]}}, imm_w}
                                                    : regfile[src2_w];

    wire [TAG_BITS-1:0] src1_tag_w = src1_busy_w ? src1_sb_tag_w : {TAG_BITS{1'b0}};
    wire [TAG_BITS-1:0] src2_tag_w = src2_busy_w ? src2_sb_tag_w : {TAG_BITS{1'b0}};

    // ---------------------------------------------------------------
    // Pipeline register (single-cycle decode)
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            decode_valid      <= 1'b0;
            decode_opcode     <= 4'b0;
            decode_dest       <= {REG_ADDR_BITS{1'b0}};
            decode_src1       <= {REG_ADDR_BITS{1'b0}};
            decode_src2       <= {REG_ADDR_BITS{1'b0}};
            decode_imm        <= 13'b0;
            decode_src1_ready <= 1'b0;
            decode_src1_tag   <= {TAG_BITS{1'b0}};
            decode_src1_value <= {DATA_BITS{1'b0}};
            decode_src2_ready <= 1'b0;
            decode_src2_tag   <= {TAG_BITS{1'b0}};
            decode_src2_value <= {DATA_BITS{1'b0}};
            decode_uses_imm   <= 1'b0;
        end else if (!stall) begin
            if (instr_valid && !is_nop) begin
                decode_valid      <= 1'b1;
                decode_opcode     <= opcode_w;
                decode_dest       <= dest_w;
                decode_src1       <= src1_w;
                decode_src2       <= src2_w;
                decode_imm        <= imm_w;
                decode_src1_ready <= src1_ready_w;
                decode_src1_tag   <= src1_tag_w;
                decode_src1_value <= src1_ready_w ? src1_value_w : {DATA_BITS{1'b0}};
                decode_src2_ready <= src2_ready_w;
                decode_src2_tag   <= src2_tag_w;
                decode_src2_value <= src2_ready_w ? src2_value_w : {DATA_BITS{1'b0}};
                decode_uses_imm   <= uses_imm_w;
            end else begin
                decode_valid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
