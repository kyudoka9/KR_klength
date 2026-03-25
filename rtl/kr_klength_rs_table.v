// Copyright 2026 Kyudoka Research, H. Ismail
// KR 25632-125 — Reservation Station Table for Routing Scheduler
//
// 32 entries per channel (was 6 in 0806). With the pass-through FU draining
// at 1 entry/cycle, 32 entries gives substantial buffering for bursty
// instruction streams from the host.
//
// TAG_BITS=5 to address 32 entries. The RS table also stores and forwards
// the imm field to the FU, since the pass-through result is the imm value.
//
// Core scheduling mechanism is identical to the KR-0806:
//   allocate -> wait for operands (CDB snoop) -> issue -> CDB writeback -> free
`default_nettype none

module kr_klength_rs_table #(
    parameter N_ENTRIES   = 32,
    parameter TAG_BITS    = 5,
    parameter DATA_BITS   = 32,
    parameter OPCODE_BITS = 4
) (
    input  wire                    clk,
    input  wire                    rst,

    // ---------------------------------------------------------------
    // Allocate interface
    // ---------------------------------------------------------------
    input  wire                    alloc_valid,
    input  wire [OPCODE_BITS-1:0]  alloc_opcode,
    input  wire                    alloc_src1_ready,
    input  wire [TAG_BITS-1:0]     alloc_src1_tag,
    input  wire [DATA_BITS-1:0]    alloc_src1_value,
    input  wire                    alloc_src2_ready,
    input  wire [TAG_BITS-1:0]     alloc_src2_tag,
    input  wire [DATA_BITS-1:0]    alloc_src2_value,
    input  wire [TAG_BITS-1:0]     alloc_dest_tag,
    input  wire [4:0]              alloc_dest_reg,
    input  wire [12:0]             alloc_imm,
    input  wire                    alloc_uses_imm,
    output wire                    alloc_ack,
    output wire [TAG_BITS-1:0]     alloc_entry_idx,

    // ---------------------------------------------------------------
    // CDB snoop
    // ---------------------------------------------------------------
    input  wire                    cdb_valid,
    input  wire [TAG_BITS-1:0]     cdb_tag,
    input  wire [DATA_BITS-1:0]    cdb_data,

    // ---------------------------------------------------------------
    // Issue interface (to pass-through FU)
    // ---------------------------------------------------------------
    output wire                    issue_valid,
    output wire [TAG_BITS-1:0]     issue_entry,
    output wire [OPCODE_BITS-1:0]  issue_opcode,
    output wire [DATA_BITS-1:0]    issue_src1_value,
    output wire [DATA_BITS-1:0]    issue_src2_value,
    output wire [TAG_BITS-1:0]     issue_dest_tag,
    output wire [4:0]              issue_dest_reg,
    output wire [12:0]             issue_imm,
    input  wire                    issue_ack,

    // ---------------------------------------------------------------
    // Status
    // ---------------------------------------------------------------
    output wire                    rs_full,
    output wire [N_ENTRIES-1:0]    rs_occupancy
);

    // ---------------------------------------------------------------
    // RS entry storage
    // ---------------------------------------------------------------
    reg                    entry_busy      [0:N_ENTRIES-1];
    reg                    entry_dispatched[0:N_ENTRIES-1];  // issued to FU, awaiting CDB
    reg [OPCODE_BITS-1:0]  entry_opcode    [0:N_ENTRIES-1];
    reg                    entry_src1_rdy  [0:N_ENTRIES-1];
    reg [TAG_BITS-1:0]     entry_src1_tag  [0:N_ENTRIES-1];
    reg [DATA_BITS-1:0]    entry_src1_val  [0:N_ENTRIES-1];
    reg                    entry_src2_rdy  [0:N_ENTRIES-1];
    reg [TAG_BITS-1:0]     entry_src2_tag  [0:N_ENTRIES-1];
    reg [DATA_BITS-1:0]    entry_src2_val  [0:N_ENTRIES-1];
    reg [TAG_BITS-1:0]     entry_dest_tag  [0:N_ENTRIES-1];
    reg [4:0]              entry_dest_reg  [0:N_ENTRIES-1];
    reg [12:0]             entry_imm       [0:N_ENTRIES-1];
    reg                    entry_uses_imm  [0:N_ENTRIES-1];

    // ---------------------------------------------------------------
    // Occupancy bitmap
    // ---------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < N_ENTRIES; gi = gi + 1) begin : gen_occ
            assign rs_occupancy[gi] = entry_busy[gi];
        end
    endgenerate

    // ---------------------------------------------------------------
    // Priority encoder: find first free entry (allocation)
    // ---------------------------------------------------------------
    reg                   free_found;
    reg [TAG_BITS-1:0]    free_idx;

    integer fi;
    always @(*) begin
        free_found = 1'b0;
        free_idx   = {TAG_BITS{1'b0}};
        for (fi = N_ENTRIES - 1; fi >= 0; fi = fi - 1) begin
            if (!entry_busy[fi]) begin
                free_found = 1'b1;
                free_idx   = fi[TAG_BITS-1:0];
            end
        end
    end

    assign rs_full        = ~free_found;
    assign alloc_ack      = alloc_valid & free_found;
    assign alloc_entry_idx = free_idx;

    // ---------------------------------------------------------------
    // Priority encoder: find first ready-to-issue entry
    // Must be busy, NOT dispatched, and both operands ready
    // ---------------------------------------------------------------
    reg                   ready_found;
    reg [TAG_BITS-1:0]    ready_idx;

    integer ri;
    always @(*) begin
        ready_found = 1'b0;
        ready_idx   = {TAG_BITS{1'b0}};
        for (ri = N_ENTRIES - 1; ri >= 0; ri = ri - 1) begin
            if (entry_busy[ri] && !entry_dispatched[ri] &&
                entry_src1_rdy[ri] && entry_src2_rdy[ri]) begin
                ready_found = 1'b1;
                ready_idx   = ri[TAG_BITS-1:0];
            end
        end
    end

    assign issue_valid     = ready_found;
    assign issue_entry     = ready_idx;
    assign issue_opcode    = entry_opcode[ready_idx];
    assign issue_src1_value = entry_src1_val[ready_idx];
    assign issue_src2_value = entry_src2_val[ready_idx];
    assign issue_dest_tag  = entry_dest_tag[ready_idx];
    assign issue_dest_reg  = entry_dest_reg[ready_idx];
    assign issue_imm       = entry_imm[ready_idx];

    // ---------------------------------------------------------------
    // Sequential logic: allocate, CDB snoop, dispatch, CDB release
    // ---------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < N_ENTRIES; i = i + 1) begin
                entry_busy[i]       <= 1'b0;
                entry_dispatched[i] <= 1'b0;
                entry_opcode[i]     <= {OPCODE_BITS{1'b0}};
                entry_src1_rdy[i]   <= 1'b0;
                entry_src1_tag[i]   <= {TAG_BITS{1'b0}};
                entry_src1_val[i]   <= {DATA_BITS{1'b0}};
                entry_src2_rdy[i]   <= 1'b0;
                entry_src2_tag[i]   <= {TAG_BITS{1'b0}};
                entry_src2_val[i]   <= {DATA_BITS{1'b0}};
                entry_dest_tag[i]   <= {TAG_BITS{1'b0}};
                entry_dest_reg[i]   <= 5'b0;
                entry_imm[i]        <= 13'b0;
                entry_uses_imm[i]   <= 1'b0;
            end
        end else begin
            // CDB snoop: update matching source tags AND free completed entries
            if (cdb_valid) begin
                for (i = 0; i < N_ENTRIES; i = i + 1) begin
                    if (entry_busy[i]) begin
                        // Source operand wakeup
                        if (!entry_src1_rdy[i] && (entry_src1_tag[i] == cdb_tag)) begin
                            entry_src1_rdy[i] <= 1'b1;
                            entry_src1_val[i] <= cdb_data;
                        end
                        if (!entry_src2_rdy[i] && !entry_uses_imm[i] &&
                            (entry_src2_tag[i] == cdb_tag)) begin
                            entry_src2_rdy[i] <= 1'b1;
                            entry_src2_val[i] <= cdb_data;
                        end
                        // Free entry when CDB broadcasts its result
                        if (entry_dispatched[i] && (entry_dest_tag[i] == cdb_tag)) begin
                            entry_busy[i]       <= 1'b0;
                            entry_dispatched[i] <= 1'b0;
                        end
                    end
                end
            end

            // Dispatch: mark entry as dispatched when FU accepts it
            // Entry stays busy (prevents tag reuse) until CDB writeback
            if (issue_valid && issue_ack) begin
                entry_dispatched[ready_idx] <= 1'b1;
            end

            // Allocate: write new entry into first free slot
            if (alloc_valid && free_found) begin
                entry_busy[free_idx]       <= 1'b1;
                entry_dispatched[free_idx] <= 1'b0;
                entry_opcode[free_idx]     <= alloc_opcode;
                entry_src1_rdy[free_idx]   <= alloc_src1_ready;
                entry_src1_tag[free_idx]   <= alloc_src1_tag;
                entry_src1_val[free_idx]   <= alloc_src1_value;
                entry_src2_rdy[free_idx]   <= alloc_src2_ready;
                entry_src2_tag[free_idx]   <= alloc_src2_tag;
                entry_src2_val[free_idx]   <= alloc_src2_value;
                entry_dest_tag[free_idx]   <= alloc_dest_tag;
                entry_dest_reg[free_idx]   <= alloc_dest_reg;
                entry_imm[free_idx]        <= alloc_imm;
                entry_uses_imm[free_idx]   <= alloc_uses_imm;
            end
        end
    end

endmodule

`default_nettype wire
