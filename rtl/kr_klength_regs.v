// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
// KR k-Length Computing — Memory-Mapped Register Interface
//
// Exposes the decomposition engine to the RISC-V core via Wishbone bus.
// Compatible with NEORV32 CFS (Custom Functions Subsystem) or XBUS interface.
//
// Register map:
//   0x00: CMD_OPCODE    [RW]  Operation (0=MPADD, 1=MPSUB, 2=MPMUL)
//   0x04: CMD_SRC_A     [RW]  BRAM word address of operand A
//   0x08: CMD_SRC_B     [RW]  BRAM word address of operand B
//   0x0C: CMD_DST       [RW]  BRAM word address for result
//   0x10: CMD_LEN_A     [RW]  Length of A in 32-bit words
//   0x14: CMD_LEN_B     [RW]  Length of B in 32-bit words
//   0x18: CMD_CONTROL   [RW]  Bit 0: START (auto-clears)
//   0x1C: CMD_STATUS    [RO]  Bit 0: BUSY, Bit 1: DONE
//   0x20: CMD_PROGRESS  [RO]  uops_completed (low 16) | uops_issued (high 16)
//   0x24: CMD_CYCLES    [RO]  Cycle count for last/current operation
//   0x28: CMD_MAGIC     [RO]  Magic number: 0x4B4C454E ("KLEN")
//   0x2C: WATCHDOG_STATUS [RO]  Bit 0: timeout_alert, Bit 1: all_complete
//   0x30: MISSING_COUNT   [RO]  Number of incomplete micro-ops
//   0x34: TIMEOUT_TAG     [RO]  Tag that timed out
//
`default_nettype none

module kr_klength_regs #(
    parameter BRAM_ADDR_W = 15
) (
    input  wire        clk,
    input  wire        rst,

    // ---------------------------------------------------------------
    // Wishbone slave interface (from NEORV32 XBUS or CFS)
    // ---------------------------------------------------------------
    input  wire [31:0] wb_adr_i,     // address (byte-addressed, [6:2] selects register)
    input  wire [31:0] wb_dat_i,     // write data
    output reg  [31:0] wb_dat_o,     // read data
    input  wire        wb_we_i,      // write enable
    input  wire        wb_stb_i,     // strobe (valid cycle)
    output reg         wb_ack_o,     // acknowledge

    // ---------------------------------------------------------------
    // Decomposition engine command interface
    // ---------------------------------------------------------------
    output reg                     cmd_valid,
    input  wire                    cmd_ready,
    output reg  [3:0]              cmd_opcode,
    output reg  [BRAM_ADDR_W-1:0]  cmd_src_a,
    output reg  [BRAM_ADDR_W-1:0]  cmd_src_b,
    output reg  [BRAM_ADDR_W-1:0]  cmd_dst,
    output reg  [15:0]             cmd_len_a,
    output reg  [15:0]             cmd_len_b,

    // ---------------------------------------------------------------
    // Decomposition engine status
    // ---------------------------------------------------------------
    input  wire                    de_busy,
    input  wire                    de_done,
    input  wire [31:0]             de_uops_issued,
    input  wire [31:0]             de_uops_completed,
    input  wire [31:0]             de_cycle_count,

    // ---------------------------------------------------------------
    // Watchdog status (from kr_klength_watchdog)
    // ---------------------------------------------------------------
    input  wire                    wd_timeout_alert,
    input  wire                    wd_all_complete,
    input  wire [31:0]             wd_missing_count,
    input  wire [11:0]             wd_timeout_tag
);

    localparam MAGIC = 32'h4B4C454E;  // "KLEN"

    // Register select from address bits [6:2]
    wire [4:0] reg_sel = wb_adr_i[6:2];

    // ---------------------------------------------------------------
    // Write logic
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            cmd_opcode <= 4'd0;
            cmd_src_a  <= {BRAM_ADDR_W{1'b0}};
            cmd_src_b  <= {BRAM_ADDR_W{1'b0}};
            cmd_dst    <= {BRAM_ADDR_W{1'b0}};
            cmd_len_a  <= 16'd0;
            cmd_len_b  <= 16'd0;
            cmd_valid  <= 1'b0;
        end else begin
            // Auto-clear START after accepted
            if (cmd_valid && cmd_ready)
                cmd_valid <= 1'b0;

            if (wb_stb_i && wb_we_i) begin
                case (reg_sel)
                    5'd0: cmd_opcode <= wb_dat_i[3:0];
                    5'd1: cmd_src_a  <= wb_dat_i[BRAM_ADDR_W-1:0];
                    5'd2: cmd_src_b  <= wb_dat_i[BRAM_ADDR_W-1:0];
                    5'd3: cmd_dst    <= wb_dat_i[BRAM_ADDR_W-1:0];
                    5'd4: cmd_len_a  <= wb_dat_i[15:0];
                    5'd5: cmd_len_b  <= wb_dat_i[15:0];
                    5'd6: begin  // CMD_CONTROL
                        if (wb_dat_i[0] && !de_busy)
                            cmd_valid <= 1'b1;  // START
                    end
                    default: ;
                endcase
            end
        end
    end

    // ---------------------------------------------------------------
    // Read logic
    // ---------------------------------------------------------------
    always @(*) begin
        wb_dat_o = 32'd0;
        case (reg_sel)
            5'd0: wb_dat_o = {28'd0, cmd_opcode};
            5'd1: wb_dat_o = {{(32-BRAM_ADDR_W){1'b0}}, cmd_src_a};
            5'd2: wb_dat_o = {{(32-BRAM_ADDR_W){1'b0}}, cmd_src_b};
            5'd3: wb_dat_o = {{(32-BRAM_ADDR_W){1'b0}}, cmd_dst};
            5'd4: wb_dat_o = {16'd0, cmd_len_a};
            5'd5: wb_dat_o = {16'd0, cmd_len_b};
            5'd6: wb_dat_o = {31'd0, cmd_valid};
            5'd7: wb_dat_o = {30'd0, de_done, de_busy};  // STATUS
            5'd8: wb_dat_o = {de_uops_issued[15:0], de_uops_completed[15:0]};  // PROGRESS
            5'd9: wb_dat_o = de_cycle_count;
            5'd10: wb_dat_o = MAGIC;
            5'd11: wb_dat_o = {30'd0, wd_all_complete, wd_timeout_alert};  // WATCHDOG_STATUS
            5'd12: wb_dat_o = wd_missing_count;                             // MISSING_COUNT
            5'd13: wb_dat_o = {20'd0, wd_timeout_tag};                      // TIMEOUT_TAG
            default: wb_dat_o = 32'd0;
        endcase
    end

    // ---------------------------------------------------------------
    // Acknowledge: single-cycle response
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        if (rst)
            wb_ack_o <= 1'b0;
        else
            wb_ack_o <= wb_stb_i && !wb_ack_o;  // ack on next cycle after strobe
    end

endmodule

`default_nettype wire
