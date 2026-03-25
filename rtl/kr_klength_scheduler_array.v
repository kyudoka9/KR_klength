// Copyright 2026 Kyudoka Research, H. Ismail
// KR 6404-125 — Routing Scheduler Array — Stripped for density
//
// Production variant: event mux, aggregate counters, and stat readout removed.
// Saves ~500 LUTs in array infrastructure + enables channel-level savings.
//
// Generates N_CHANNELS instances of kr_klength_channel with distributor
// for instruction routing and result collector for merging outputs.
`default_nettype none

module kr_klength_scheduler_array #(
    parameter N_CHANNELS  = 256,
    parameter N_RS_ENTRIES = 32,
    parameter TAG_BITS    = 5,
    parameter DATA_BITS   = 32,
    parameter QUEUE_DEPTH = 512
) (
    input  wire                    clk,
    input  wire                    rst,

    // Instruction input
    input  wire                    instr_valid,
    input  wire [31:0]             instr_data,
    output wire                    instr_ready,

    // Result output (merged from all channels)
    output wire                    result_valid,
    output wire [DATA_BITS-1:0]   result_data,
    output wire [7:0]              result_channel,
    output wire [4:0]              result_dest_reg,
    output wire [3:0]              result_opcode,

    // Per-channel status
    output wire [N_CHANNELS-1:0]   channel_busy
);

    // ---------------------------------------------------------------
    // Distributor -> per-channel instruction wires
    // ---------------------------------------------------------------
    wire [N_CHANNELS-1:0]   ch_instr_valid;
    wire [31:0]             ch_instr_data;
    wire [N_CHANNELS-1:0]   ch_instr_ready;

    kr_klength_distributor #(
        .N_CHANNELS(N_CHANNELS)
    ) u_distributor (
        .clk           (clk),
        .rst           (rst),
        .instr_valid   (instr_valid),
        .instr_data    (instr_data),
        .instr_ready   (instr_ready),
        .ch_instr_valid(ch_instr_valid),
        .ch_instr_data (ch_instr_data),
        .ch_instr_ready(ch_instr_ready)
    );

    // ---------------------------------------------------------------
    // Per-channel result wires (packed for result collector)
    // ---------------------------------------------------------------
    wire [N_CHANNELS-1:0]             ch_result_valid;
    wire [N_CHANNELS*DATA_BITS-1:0]   ch_result_data;
    wire [N_CHANNELS*5-1:0]           ch_result_dest_reg;
    wire [N_CHANNELS*TAG_BITS-1:0]    ch_result_tag;
    wire [N_CHANNELS*4-1:0]           ch_result_opcode;

    // ---------------------------------------------------------------
    // Generate block: N_CHANNELS instances of kr_klength_channel
    // ---------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < N_CHANNELS; gi = gi + 1) begin : gen_channel
            kr_klength_channel #(
                .N_RS_ENTRIES (N_RS_ENTRIES),
                .TAG_BITS     (TAG_BITS),
                .DATA_BITS    (DATA_BITS),
                .QUEUE_DEPTH  (QUEUE_DEPTH),
                .CHANNEL_ID   (gi)
            ) u_channel (
                .clk              (clk),
                .rst              (rst),
                .instr_valid      (ch_instr_valid[gi]),
                .instr_data       (ch_instr_data),
                .instr_ready      (ch_instr_ready[gi]),
                .result_valid     (ch_result_valid[gi]),
                .result_data      (ch_result_data[gi*DATA_BITS +: DATA_BITS]),
                .result_dest_reg  (ch_result_dest_reg[gi*5 +: 5]),
                .result_tag       (ch_result_tag[gi*TAG_BITS +: TAG_BITS]),
                .result_opcode    (ch_result_opcode[gi*4 +: 4]),
                .channel_busy     (channel_busy[gi])
            );
        end
    endgenerate

    // ---------------------------------------------------------------
    // Result collector: merge results from all channels
    // ---------------------------------------------------------------
    kr_klength_result_collector #(
        .N_CHANNELS(N_CHANNELS),
        .DATA_BITS (DATA_BITS),
        .TAG_BITS  (TAG_BITS)
    ) u_result_collector (
        .clk              (clk),
        .rst              (rst),
        .ch_result_valid   (ch_result_valid),
        .ch_result_data    (ch_result_data),
        .ch_result_dest_reg(ch_result_dest_reg),
        .ch_result_tag     (ch_result_tag),
        .ch_result_opcode  (ch_result_opcode),
        .result_valid      (result_valid),
        .result_data       (result_data),
        .result_channel    (result_channel),
        .result_dest_reg   (result_dest_reg),
        .result_opcode     (result_opcode)
    );

endmodule

`default_nettype wire
