// Copyright 2026 Kyudoka Research, H. Ismail
// KR 25632-125 — Instruction Distributor for 256-Channel Routing Scheduler
//
// Pipelined round-robin distributor scaled to 256 channels.
// The combinational search loop over 256 channels is the timing-critical path.
// A 2-stage pipeline (search -> dispatch) breaks this off the instr_ready path,
// same architecture as the 0806 distributor but with wider parameters.
//
// At 256 channels, the priority encoder loop synthesizes into a tree structure
// in modern Vivado. With registered ch_instr_ready from each channel, this
// meets timing at 125 MHz on Artix-7.
`default_nettype none

module kr_klength_distributor #(
    parameter N_CHANNELS = 256
) (
    input  wire                    clk,
    input  wire                    rst,

    // Input instruction interface
    input  wire                    instr_valid,
    input  wire [31:0]             instr_data,
    output wire                    instr_ready,

    // Per-channel instruction interface
    output wire [N_CHANNELS-1:0]   ch_instr_valid,
    output wire [31:0]             ch_instr_data,
    input  wire [N_CHANNELS-1:0]   ch_instr_ready
);

    // ---------------------------------------------------------------
    // Channel select width
    // ---------------------------------------------------------------
    function integer clog2;
        input integer val;
        integer i;
        begin
            clog2 = 1;
            for (i = 0; (1 << i) < val; i = i + 1)
                clog2 = i + 1;
        end
    endfunction

    localparam CH_SEL_BITS = clog2(N_CHANNELS);  // 8 for 256 channels

    // ---------------------------------------------------------------
    // Round-robin pointer
    // ---------------------------------------------------------------
    reg [CH_SEL_BITS-1:0] rr_ptr;

    // ---------------------------------------------------------------
    // Stage 1 (combinational): find next ready channel from rr_ptr
    // Bitmask approach: no modular arithmetic per iteration.
    // Split ch_instr_ready into upper (>= rr_ptr) and lower (< rr_ptr).
    // Find-first-one on each; prefer upper for round-robin fairness.
    // ---------------------------------------------------------------
    // Registered mask: pre-computed from rr_ptr, available at cycle start.
    reg [N_CHANNELS-1:0] mask_upper_r;

    integer msk;
    always @(posedge clk) begin
        if (rst) begin
            mask_upper_r <= {N_CHANNELS{1'b1}};
        end else begin
            for (msk = 0; msk < N_CHANNELS; msk = msk + 1)
                mask_upper_r[msk] <= (msk[CH_SEL_BITS-1:0] >= rr_ptr);
        end
    end

    wire [N_CHANNELS-1:0] upper_req = ch_instr_ready & mask_upper_r;
    wire [N_CHANNELS-1:0] lower_req = ch_instr_ready & ~mask_upper_r;

    // Find-first-one: LUT priority scan (Vivado synthesizes as tree)
    reg                    upper_found;
    reg [CH_SEL_BITS-1:0]  upper_idx;
    reg                    lower_found;
    reg [CH_SEL_BITS-1:0]  lower_idx;

    integer ui, li;
    always @(*) begin
        upper_found = 1'b0;
        upper_idx   = {CH_SEL_BITS{1'b0}};
        for (ui = 0; ui < N_CHANNELS; ui = ui + 1) begin
            if (!upper_found && upper_req[ui]) begin
                upper_found = 1'b1;
                upper_idx   = ui[CH_SEL_BITS-1:0];
            end
        end

        lower_found = 1'b0;
        lower_idx   = {CH_SEL_BITS{1'b0}};
        for (li = 0; li < N_CHANNELS; li = li + 1) begin
            if (!lower_found && lower_req[li]) begin
                lower_found = 1'b1;
                lower_idx   = li[CH_SEL_BITS-1:0];
            end
        end
    end

    wire                   found     = upper_found | lower_found;
    wire [CH_SEL_BITS-1:0] found_idx = upper_found ? upper_idx : lower_idx;

    // ---------------------------------------------------------------
    // Stage 2 (registered): pipe register for dispatch
    // ---------------------------------------------------------------
    reg                    pipe_valid;
    reg [CH_SEL_BITS-1:0]  pipe_idx;
    reg [31:0]             pipe_data;

    // Dispatch succeeds when pipe is valid and target channel accepts
    wire pipe_accepted = pipe_valid & ch_instr_ready[pipe_idx];

    // Upstream ready: can accept when pipe is empty or draining this cycle
    assign instr_ready = !pipe_valid | pipe_accepted;

    // Data to channels comes from pipe register (stable, registered)
    assign ch_instr_data = pipe_data;

    // Per-channel valid: decode pipe_idx to one-hot
    genvar gi;
    generate
        for (gi = 0; gi < N_CHANNELS; gi = gi + 1) begin : gen_ch_valid
            assign ch_instr_valid[gi] = pipe_valid & (pipe_idx == gi[CH_SEL_BITS-1:0]);
        end
    endgenerate

    // ---------------------------------------------------------------
    // Pipe register and round-robin pointer update
    // ---------------------------------------------------------------
    wire pipe_load = instr_valid & instr_ready & found;

    always @(posedge clk) begin
        if (rst) begin
            pipe_valid <= 1'b0;
            pipe_idx   <= {CH_SEL_BITS{1'b0}};
            pipe_data  <= 32'b0;
            rr_ptr     <= {CH_SEL_BITS{1'b0}};
        end else begin
            // Load and drain can happen simultaneously (skid buffer)
            if (pipe_load && !pipe_accepted) begin
                pipe_valid <= 1'b1;
                pipe_idx   <= found_idx;
                pipe_data  <= instr_data;
            end else if (pipe_load && pipe_accepted) begin
                pipe_valid <= 1'b1;
                pipe_idx   <= found_idx;
                pipe_data  <= instr_data;
            end else if (pipe_accepted) begin
                pipe_valid <= 1'b0;
            end

            // Advance round-robin on successful dispatch
            if (pipe_accepted) begin
                if (pipe_idx == (N_CHANNELS[CH_SEL_BITS-1:0] - {{(CH_SEL_BITS-1){1'b0}}, 1'b1})) begin
                    rr_ptr <= {CH_SEL_BITS{1'b0}};
                end else begin
                    rr_ptr <= pipe_idx + {{(CH_SEL_BITS-1){1'b0}}, 1'b1};
                end
            end
        end
    end

endmodule

`default_nettype wire
