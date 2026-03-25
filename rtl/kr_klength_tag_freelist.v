// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
// KR k-Length Computing — Tag Recycling Free-List
//
// BRAM-backed circular FIFO that manages tag allocation and recycling.
// Removes the fixed operand size limit from k-length computing —
// tags are reused after micro-op completion, enabling unlimited
// operand lengths bounded only by BRAM capacity.
//
// Reset: initializes FIFO with tags 0..INIT_COUNT-1 (takes INIT_COUNT cycles).
// Allocate: pop a free tag (1 cycle, prefetched).
// Free: push a tag back (1 cycle).
// Simultaneous alloc+free supported (independent read/write ports).
//
// Integration with kr_decomp_engine.v:
//   1. Replace `next_tag <= next_tag + 1` with alloc_req/alloc_tag
//   2. Stall micro-op generation when alloc_valid=0 (no free tags)
//   3. Free tags when a result is consumed and its carry resolved
//   4. Gate cmd_ready on !empty (don't start new ops with no tags)
//
`default_nettype none

module kr_klength_tag_freelist #(
    parameter TAG_BITS   = 12,
    parameter INIT_COUNT = 4096     // must be <= 2^TAG_BITS
) (
    input  wire                clk,
    input  wire                rst,

    // Allocate: pop a free tag
    input  wire                alloc_req,
    output wire                alloc_valid,
    output wire [TAG_BITS-1:0] alloc_tag,

    // Free: return a tag
    input  wire                free_req,
    input  wire [TAG_BITS-1:0] free_tag,

    // Status
    output wire                empty,
    output wire                full,
    output reg  [TAG_BITS:0]   free_count,  // 0..INIT_COUNT
    output wire                init_done     // high after initialization complete
);

    // ---------------------------------------------------------------
    // FIFO storage (BRAM-inferred circular buffer)
    // ---------------------------------------------------------------
    localparam DEPTH = INIT_COUNT;
    localparam PTR_BITS = TAG_BITS; // pointer width matches depth

    (* ram_style = "block" *)
    reg [TAG_BITS-1:0] fifo_mem [0:DEPTH-1];

    reg [PTR_BITS-1:0] rd_ptr;
    reg [PTR_BITS-1:0] wr_ptr;

    // ---------------------------------------------------------------
    // Prefetch register (hides BRAM read latency)
    // ---------------------------------------------------------------
    reg [TAG_BITS-1:0] prefetch_tag;
    reg                prefetch_valid;

    // ---------------------------------------------------------------
    // Initialization state
    // ---------------------------------------------------------------
    localparam S_INIT  = 1'b0;
    localparam S_READY = 1'b1;

    reg state;
    reg [PTR_BITS-1:0] init_idx;

    assign init_done = (state == S_READY);
    assign empty = (free_count == 0);
    assign full  = (free_count == INIT_COUNT);

    // ---------------------------------------------------------------
    // Allocate output
    // ---------------------------------------------------------------
    assign alloc_valid = prefetch_valid && (state == S_READY);
    assign alloc_tag   = prefetch_tag;

    // ---------------------------------------------------------------
    // Main logic
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state          <= S_INIT;
            init_idx       <= {PTR_BITS{1'b0}};
            rd_ptr         <= {PTR_BITS{1'b0}};
            wr_ptr         <= {PTR_BITS{1'b0}};
            free_count     <= {(TAG_BITS+1){1'b0}};
            prefetch_valid <= 1'b0;
        end else begin

            case (state)

            // ==========================================================
            // Initialization: fill FIFO with tags 0..INIT_COUNT-1
            // ==========================================================
            S_INIT: begin
                fifo_mem[init_idx] <= init_idx;
                if (init_idx == INIT_COUNT - 1) begin
                    state      <= S_READY;
                    wr_ptr     <= {PTR_BITS{1'b0}}; // wr_ptr wraps back to 0
                    rd_ptr     <= {PTR_BITS{1'b0}};
                    free_count <= INIT_COUNT;
                    // Prefetch first tag
                    prefetch_tag   <= {PTR_BITS{1'b0}}; // tag 0
                    prefetch_valid <= 1'b1;
                    rd_ptr         <= {{(PTR_BITS-1){1'b0}}, 1'b1}; // advance past tag 0
                end else begin
                    init_idx <= init_idx + 1;
                end
            end

            // ==========================================================
            // Normal operation
            // ==========================================================
            S_READY: begin
                // --- Allocate (pop) ---
                if (alloc_req && alloc_valid) begin
                    // Tag is served from prefetch register
                    free_count <= free_count - 1;

                    // Prefetch next tag from BRAM
                    if (free_count > 1) begin
                        prefetch_tag   <= fifo_mem[rd_ptr];
                        prefetch_valid <= 1'b1;
                        rd_ptr         <= (rd_ptr == DEPTH - 1) ? {PTR_BITS{1'b0}} : rd_ptr + 1;
                    end else begin
                        prefetch_valid <= 1'b0; // FIFO now empty after this alloc
                    end
                end

                // --- Free (push) ---
                if (free_req) begin
                    fifo_mem[wr_ptr] <= free_tag;
                    wr_ptr <= (wr_ptr == DEPTH - 1) ? {PTR_BITS{1'b0}} : wr_ptr + 1;
                    free_count <= free_count + 1;

                    // If FIFO was empty and we just freed a tag, prefetch it
                    if (!prefetch_valid && !alloc_req) begin
                        prefetch_tag   <= free_tag;
                        prefetch_valid <= 1'b1;
                        // Don't advance rd_ptr — the freed tag goes to wr_ptr,
                        // and we serve it directly from prefetch
                    end
                end

                // --- Simultaneous alloc + free ---
                // free_count adjustment: alloc decrements, free increments = net 0
                if (alloc_req && alloc_valid && free_req) begin
                    free_count <= free_count; // net zero change
                end
            end

            endcase
        end
    end

endmodule

`default_nettype wire
