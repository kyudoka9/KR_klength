// Copyright 2026 Kyudoka Research, H. Ismail
// KR 25632-125 — Register Scoreboard for Routing Scheduler
//
// Tracks which registers (routing regions) are busy awaiting a CDB result.
// 32 registers represent 32 routing regions per channel.
// TAG_BITS=5 to index up to 32 RS entries.
//
// Identical structure to the 0806 scoreboard — the core dependency tracking
// mechanism is unchanged. Only parameterization differs (wider tags).
`default_nettype none

module kr_klength_scoreboard #(
    parameter N_REGS        = 32,
    parameter TAG_BITS      = 5,
    parameter REG_ADDR_BITS = 5
) (
    input  wire                    clk,
    input  wire                    rst,

    // Rename interface — mark register as busy with given tag
    input  wire                    rename_valid,
    input  wire [REG_ADDR_BITS-1:0] rename_rd,
    input  wire [TAG_BITS-1:0]     rename_tag,

    // CDB writeback — clear busy bit for matching tag
    input  wire                    cdb_valid,
    input  wire [TAG_BITS-1:0]     cdb_tag,

    // Read port 1 (combinational)
    input  wire [REG_ADDR_BITS-1:0] rd_addr1,
    output wire                    busy1,
    output wire [TAG_BITS-1:0]     tag1,

    // Read port 2 (combinational)
    input  wire [REG_ADDR_BITS-1:0] rd_addr2,
    output wire                    busy2,
    output wire [TAG_BITS-1:0]     tag2,

    // Flat outputs for decode stage
    output wire [N_REGS-1:0]       sb_busy_flat,
    output wire [TAG_BITS*N_REGS-1:0] sb_tag_flat
);

    // ---------------------------------------------------------------
    // Internal storage
    // ---------------------------------------------------------------
    reg              busy [0:N_REGS-1];
    reg [TAG_BITS-1:0] tag  [0:N_REGS-1];

    // ---------------------------------------------------------------
    // Flat output generation
    // ---------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < N_REGS; gi = gi + 1) begin : gen_flat
            assign sb_busy_flat[gi]                        = busy[gi];
            assign sb_tag_flat[gi * TAG_BITS +: TAG_BITS]  = tag[gi];
        end
    endgenerate

    // ---------------------------------------------------------------
    // Combinational read ports
    // ---------------------------------------------------------------
    assign busy1 = busy[rd_addr1];
    assign tag1  = tag[rd_addr1];
    assign busy2 = busy[rd_addr2];
    assign tag2  = tag[rd_addr2];

    // ---------------------------------------------------------------
    // Sequential update
    // ---------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < N_REGS; i = i + 1) begin
                busy[i] <= 1'b0;
                tag[i]  <= {TAG_BITS{1'b0}};
            end
        end else begin
            // CDB writeback: clear busy for any register whose tag matches
            if (cdb_valid) begin
                for (i = 0; i < N_REGS; i = i + 1) begin
                    if (busy[i] && (tag[i] == cdb_tag)) begin
                        busy[i] <= 1'b0;
                        tag[i]  <= {TAG_BITS{1'b0}};
                    end
                end
            end

            // Rename: mark register as busy (takes priority over CDB clear
            // for the same register in the same cycle)
            if (rename_valid) begin
                busy[rename_rd] <= 1'b1;
                tag[rename_rd]  <= rename_tag;
            end
        end
    end

endmodule

`default_nettype wire
