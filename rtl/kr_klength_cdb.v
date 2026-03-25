// Copyright 2026 Kyudoka Research, H. Ismail
// KR k-Length Computing — Common Data Bus with Carry Propagation
//
// Extended from KR-6404 CDB with carry bit for k-length arithmetic.
// The carry bit enables multi-precision carry chain tracking through
// the KR FPGA Scheduler's dependency resolution mechanism.
`default_nettype none

module kr_klength_cdb #(
    parameter TAG_BITS  = 5,
    parameter DATA_BITS = 32
) (
    input  wire                    clk,
    input  wire                    rst,

    // FU result input
    input  wire                    fu_valid,
    input  wire [TAG_BITS-1:0]     fu_tag,
    input  wire [DATA_BITS-1:0]    fu_data,
    input  wire [4:0]              fu_dest_reg,
    input  wire [3:0]              fu_opcode,
    input  wire                    fu_carry,      // carry/borrow output from MAC
    output wire                    fu_ack,

    // CDB output (registered)
    output reg                     cdb_valid,
    output reg  [TAG_BITS-1:0]     cdb_tag,
    output reg  [DATA_BITS-1:0]    cdb_data,
    output reg  [4:0]              cdb_dest_reg,
    output reg  [3:0]              cdb_opcode,
    output reg                     cdb_carry      // carry propagation for k-length
);

    // Single source — always acknowledge when valid
    assign fu_ack = fu_valid;

    // ---------------------------------------------------------------
    // Registered CDB output
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            cdb_valid    <= 1'b0;
            cdb_tag      <= {TAG_BITS{1'b0}};
            cdb_data     <= {DATA_BITS{1'b0}};
            cdb_dest_reg <= 5'b0;
            cdb_opcode   <= 4'b0;
            cdb_carry    <= 1'b0;
        end else begin
            if (fu_valid) begin
                cdb_valid    <= 1'b1;
                cdb_tag      <= fu_tag;
                cdb_data     <= fu_data;
                cdb_dest_reg <= fu_dest_reg;
                cdb_opcode   <= fu_opcode;
                cdb_carry    <= fu_carry;
            end else begin
                cdb_valid    <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
