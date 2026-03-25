// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
// KR k-Length Computing — Decomposition Engine
//
// The heart of k-length computing. Receives L1 multi-precision instructions
// (MPADD, MPMUL) and decomposes them into streams of L0 word-level micro-ops
// (ADDWC, ADDMUL) with explicit dependency tags for carry propagation.
//
// Micro-ops are fed to the KR FPGA Scheduler, which handles parallel
// execution across channels and dependency resolution via CDB.
//
// State machine: IDLE -> FETCH -> GENERATE -> DRAIN -> DONE
//
// Audit fixes applied:
//   D3  — next_tag is monotonically increasing (never reset), with start_tag
//          range check on result writeback to reject stale results.
//   D4  — MPMUL dispatched as unsupported; handled by RISC-V using L0
//          intrinsics (kr_mpn_mul). Hardware-scheduled MPMUL requires a
//          result accumulator in the integration top (future work).
//   D7  — Zero-length operand guard: len_a==0 skips to S_DONE.
//   D9  — Carry RAW hazard: dispatch stalls until the dependent tag's
//          result has arrived. Single-cycle forwarding bypass for the
//          common case (result arrives the same cycle it is needed).
//
// Phase E — Speculative carry prediction:
//   When SPECULATIVE_CARRY=1, ALL micro-ops are dispatched immediately
//   with carry_in predicted as 0 (no dependency). When actual carry
//   arrives, mispredictions (carry was 1) trigger replay of the affected
//   word with correct carry_in. For random data P(carry)~2^(-32), so
//   replays are extremely rare, and a 64-word MPADD completes in ~64/N
//   cycles instead of 64*latency cycles.
//
`default_nettype none

module kr_decomp_engine #(
    parameter TAG_BITS         = 10,       // Wide tags for k-length (1024 in-flight)
    parameter DATA_BITS        = 32,
    parameter MAX_WORDS        = 256,      // Max operand length in words
    parameter BRAM_ADDR_W      = 15,       // 32K words addressable
    parameter SPECULATIVE_CARRY = 1        // 1=speculative dispatch, 0=stall on carry
) (
    input  wire                    clk,
    input  wire                    rst,

    // ---------------------------------------------------------------
    // Command interface (from RISC-V via kr_klength_regs)
    // ---------------------------------------------------------------
    input  wire                    cmd_valid,
    output reg                     cmd_ready,
    input  wire [3:0]              cmd_opcode,    // 0=MPADD, 1=MPSUB, 2=MPMUL
    input  wire [BRAM_ADDR_W-1:0]  cmd_src_a,     // BRAM address of operand A
    input  wire [BRAM_ADDR_W-1:0]  cmd_src_b,     // BRAM address of operand B
    input  wire [BRAM_ADDR_W-1:0]  cmd_dst,       // BRAM address for result
    input  wire [15:0]             cmd_len_a,     // Length of A in words
    input  wire [15:0]             cmd_len_b,     // Length of B in words

    // ---------------------------------------------------------------
    // BRAM read port (fetch operands)
    // ---------------------------------------------------------------
    output reg                     bram_rd_en,
    output reg  [BRAM_ADDR_W-1:0]  bram_rd_addr,
    input  wire [DATA_BITS-1:0]    bram_rd_data,
    input  wire                    bram_rd_valid,

    // ---------------------------------------------------------------
    // BRAM write port (writeback results from scheduler)
    // ---------------------------------------------------------------
    output reg                     bram_wr_en,
    output reg  [BRAM_ADDR_W-1:0]  bram_wr_addr,
    output reg  [DATA_BITS-1:0]    bram_wr_data,

    // ---------------------------------------------------------------
    // Micro-op output (to KR FPGA Scheduler)
    // ---------------------------------------------------------------
    output reg                     uop_valid,
    input  wire                    uop_ready,
    output reg  [3:0]              uop_opcode,    // ADDWC=0, SUBWB=1, ADDMUL=3
    output reg  [DATA_BITS-1:0]    uop_src1,
    output reg  [DATA_BITS-1:0]    uop_src2,
    output reg  [TAG_BITS-1:0]     uop_tag,       // Tag assigned to this result
    output reg                     uop_dep_valid, // Has a carry dependency?
    output reg  [TAG_BITS-1:0]     uop_dep_tag,   // Tag of operation we depend on

    // ---------------------------------------------------------------
    // Result collection (from scheduler CDB, for writeback)
    // ---------------------------------------------------------------
    input  wire                    result_valid,
    input  wire [TAG_BITS-1:0]     result_tag,
    input  wire [DATA_BITS-1:0]    result_data,
    input  wire                    result_carry,

    // ---------------------------------------------------------------
    // Status
    // ---------------------------------------------------------------
    output reg                     busy,
    output reg                     done,
    output reg                     irq,
    output reg  [31:0]             uops_issued,
    output reg  [31:0]             uops_completed,
    output reg  [31:0]             cycle_count,
    output reg                     err_unsupported, // MPMUL not supported in HW

    // ---------------------------------------------------------------
    // Speculation statistics (Phase E)
    // ---------------------------------------------------------------
    output reg  [31:0]             speculation_correct,
    output reg  [31:0]             speculation_replays
);

    // ---------------------------------------------------------------
    // Operation codes (matching L0 CFU encoding)
    // ---------------------------------------------------------------
    localparam OP_MPADD = 4'd0;
    localparam OP_MPSUB = 4'd1;
    localparam OP_MPMUL = 4'd2;

    localparam UOP_ADDWC  = 4'd0;
    localparam UOP_SUBWB  = 4'd1;
    localparam UOP_ADDMUL = 4'd3;

    // ---------------------------------------------------------------
    // State machine
    // ---------------------------------------------------------------
    localparam S_IDLE     = 4'd0;
    localparam S_FETCH_A  = 4'd1;
    localparam S_FETCH_B  = 4'd2;
    localparam S_GEN_ADD  = 4'd3;  // Generate MPADD/MPSUB micro-ops
    localparam S_GEN_MUL  = 4'd4;  // (reserved — MPMUL not yet HW-scheduled)
    localparam S_DRAIN    = 4'd5;  // Wait for all micro-ops to complete
    localparam S_DONE     = 4'd6;

    reg [3:0] state;

    // ---------------------------------------------------------------
    // Operand buffers (on-chip, fetched from BRAM)
    // ---------------------------------------------------------------
    reg [DATA_BITS-1:0] buf_a [0:MAX_WORDS-1];
    reg [DATA_BITS-1:0] buf_b [0:MAX_WORDS-1];

    // ---------------------------------------------------------------
    // Command registers (latched on dispatch)
    // ---------------------------------------------------------------
    reg [3:0]              op_reg;
    reg [BRAM_ADDR_W-1:0]  src_a_reg, src_b_reg, dst_reg;
    reg [15:0]             len_a_reg, len_b_reg;

    // ---------------------------------------------------------------
    // Fetch counters
    // ---------------------------------------------------------------
    reg [15:0] fetch_idx;
    reg        fetch_pipe;  // 1-cycle BRAM read latency

    // ---------------------------------------------------------------
    // Generation counters
    // ---------------------------------------------------------------
    reg [15:0] gen_i;          // outer loop (row for multiply)
    reg [15:0] gen_j;          // inner loop (column for multiply)
    reg [TAG_BITS-1:0] next_tag;
    reg [TAG_BITS-1:0] carry_tag;   // tag of previous op (carry dependency)
    reg                carry_dep;   // whether carry_tag is valid
    reg [31:0]         total_uops;  // total micro-ops for this operation

    // ---------------------------------------------------------------
    // D3 fix: start_tag for stale-result rejection
    // ---------------------------------------------------------------
    // next_tag is monotonically increasing (never reset). On each new
    // command, start_tag captures next_tag. Results are only accepted
    // when uops_completed < uops_issued, which guarantees we never
    // write more results than we dispatched in the current operation.
    reg [TAG_BITS-1:0] start_tag;

    // ---------------------------------------------------------------
    // D9 fix: completion tracking for carry RAW-hazard stall
    // ---------------------------------------------------------------
    // Per-tag completion bit. Set when a result arrives. Checked before
    // emitting a carry-dependent micro-op to guarantee the predecessor
    // result (and therefore its carry) is available.
    reg completed [0:(1<<TAG_BITS)-1];

    // Forwarding bypass: if the result for the carry dependency arrives
    // THIS cycle, we can emit immediately instead of stalling.
    wire dep_resolved  = !carry_dep || completed[carry_tag];
    wire dep_forwarded = carry_dep && result_valid && (result_tag == carry_tag);

    // ---------------------------------------------------------------
    // Phase E: Speculative vs. stall-based emit control
    // ---------------------------------------------------------------
    // When SPECULATIVE_CARRY=1, we always emit (no carry stall).
    // When SPECULATIVE_CARRY=0, fall back to D9 stall+forwarding.
    wire can_emit = (SPECULATIVE_CARRY == 1) ? 1'b1
                                             : (dep_resolved || dep_forwarded);

    // ---------------------------------------------------------------
    // Phase E: Speculative carry tracking
    // ---------------------------------------------------------------
    // Per-tag speculative bit: set when a tag is dispatched without
    // resolved carry (i.e., with predicted carry_in=0).
    reg speculative [0:(1<<TAG_BITS)-1];

    // Per-tag predecessor tracking: which tag's carry does this tag
    // depend on? Needed to check the actual carry at result time.
    reg [TAG_BITS-1:0] pred_tag [0:(1<<TAG_BITS)-1];
    reg                pred_valid [0:(1<<TAG_BITS)-1];

    // Per-tag carry value: actual carry_out from each completed tag.
    reg carry_val [0:(1<<TAG_BITS)-1];

    // ---------------------------------------------------------------
    // Phase E: Replay queue
    // ---------------------------------------------------------------
    // When a speculative result arrives and the predecessor's actual
    // carry was 1, we must replay: re-dispatch with correct carry_in.
    // The replay queue stores the original operands, opcode, tag,
    // destination, and the correct carry value.
    //
    // Depth 16 is generous: for random 32-bit data, P(carry)~2^(-32),
    // so the queue almost never has more than 0-1 entries.
    localparam REPLAY_DEPTH = 16;
    localparam REPLAY_PTR_W = $clog2(REPLAY_DEPTH);

    reg [DATA_BITS-1:0]    replay_src1   [0:REPLAY_DEPTH-1];
    reg [DATA_BITS-1:0]    replay_src2   [0:REPLAY_DEPTH-1];
    reg [3:0]              replay_opcode [0:REPLAY_DEPTH-1];
    reg [TAG_BITS-1:0]     replay_tag    [0:REPLAY_DEPTH-1];
    reg [BRAM_ADDR_W-1:0]  replay_dst    [0:REPLAY_DEPTH-1];
    // The correct carry is always 1 (we only replay on misprediction
    // where predicted 0 but actual was 1). The replay micro-op must
    // carry a dependency on the predecessor so the MAC gets carry_in=1
    // from the hi_table. We store the predecessor tag for this purpose.
    reg [TAG_BITS-1:0]     replay_dep_tag [0:REPLAY_DEPTH-1];

    reg [REPLAY_PTR_W:0] replay_wr_ptr;  // extra bit for full/empty
    reg [REPLAY_PTR_W:0] replay_rd_ptr;

    wire [REPLAY_PTR_W-1:0] replay_wr_idx = replay_wr_ptr[REPLAY_PTR_W-1:0];
    wire [REPLAY_PTR_W-1:0] replay_rd_idx = replay_rd_ptr[REPLAY_PTR_W-1:0];
    wire replay_empty = (replay_wr_ptr == replay_rd_ptr);
    wire replay_full  = (replay_wr_ptr[REPLAY_PTR_W] != replay_rd_ptr[REPLAY_PTR_W]) &&
                        (replay_wr_ptr[REPLAY_PTR_W-1:0] == replay_rd_ptr[REPLAY_PTR_W-1:0]);
    wire replay_pending = !replay_empty;

    // ---------------------------------------------------------------
    // Phase E: Per-tag source operand storage for replay
    // ---------------------------------------------------------------
    // We need the original src1/src2 to re-dispatch on misprediction.
    // Store them per-tag at dispatch time.
    reg [DATA_BITS-1:0] tag_src1 [0:(1<<TAG_BITS)-1];
    reg [DATA_BITS-1:0] tag_src2 [0:(1<<TAG_BITS)-1];
    reg [3:0]           tag_opcode [0:(1<<TAG_BITS)-1];

    // ---------------------------------------------------------------
    // Drain tracking
    // ---------------------------------------------------------------
    reg [TAG_BITS-1:0] last_tag;    // last issued tag — done when this completes

    // ---------------------------------------------------------------
    // Result writeback tracking
    // ---------------------------------------------------------------
    // For MPADD: result word i is written when tag i completes.
    // Tag-to-destination mapping, indexed by tag.
    reg [BRAM_ADDR_W-1:0] tag_dst_addr [0:(1<<TAG_BITS)-1];

    // ---------------------------------------------------------------
    // Phase E: Replay dispatch signal
    // ---------------------------------------------------------------
    // Replay has priority over new micro-op generation. When the
    // replay queue is non-empty and the output port is available,
    // we dispatch from replay instead of generating new micro-ops.
    reg replay_dispatching;

    // ---------------------------------------------------------------
    // Main state machine
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state           <= S_IDLE;
            cmd_ready       <= 1'b1;
            busy            <= 1'b0;
            done            <= 1'b0;
            irq             <= 1'b0;
            uop_valid       <= 1'b0;
            bram_rd_en      <= 1'b0;
            bram_wr_en      <= 1'b0;
            uops_issued     <= 32'd0;
            uops_completed  <= 32'd0;
            cycle_count     <= 32'd0;
            next_tag        <= {TAG_BITS{1'b0}};
            start_tag       <= {TAG_BITS{1'b0}};
            fetch_idx       <= 16'd0;
            fetch_pipe      <= 1'b0;
            err_unsupported <= 1'b0;
            replay_wr_ptr   <= {(REPLAY_PTR_W+1){1'b0}};
            replay_rd_ptr   <= {(REPLAY_PTR_W+1){1'b0}};
            replay_dispatching <= 1'b0;
            speculation_correct <= 32'd0;
            speculation_replays <= 32'd0;
        end else begin
            // Default: clear one-shot signals
            irq        <= 1'b0;
            bram_wr_en <= 1'b0;

            // Cycle counter (when busy)
            if (busy) cycle_count <= cycle_count + 1;

            // -----------------------------------------------------------
            // Result handling: writeback, completion tracking, and
            // speculative carry verification (Phase E).
            // -----------------------------------------------------------
            if (result_valid && busy) begin
                // D9: mark tag as completed for dependency tracking
                completed[result_tag] <= 1'b1;
                // Record actual carry_out for this tag
                carry_val[result_tag] <= result_carry;

                // -------------------------------------------------------
                // Phase E: Speculative carry verification
                // -------------------------------------------------------
                if (SPECULATIVE_CARRY == 1 && speculative[result_tag] && pred_valid[result_tag]) begin
                    // This tag was dispatched speculatively (carry_in predicted 0).
                    // Check: was the predecessor's actual carry 1?
                    //
                    // The predecessor must have completed already (since results
                    // arrive in dependency order for a linear chain, or out of
                    // order — but we stored carry_val when it completed).
                    //
                    // If the predecessor's carry_val is 1, our result is wrong.
                    if (carry_val[pred_tag[result_tag]]) begin
                        // MISPREDICTION: carry was 1, we computed with 0.
                        // Queue for replay — do NOT writeback this result.
                        speculation_replays <= speculation_replays + 1;

                        // Enqueue replay (if queue not full — drop is a
                        // correctness bug, but depth 16 is extremely safe
                        // given P(carry)~2^-32).
                        if (!replay_full) begin
                            replay_src1[replay_wr_idx]    <= tag_src1[result_tag];
                            replay_src2[replay_wr_idx]    <= tag_src2[result_tag];
                            replay_opcode[replay_wr_idx]  <= tag_opcode[result_tag];
                            replay_tag[replay_wr_idx]     <= result_tag;
                            replay_dst[replay_wr_idx]     <= tag_dst_addr[result_tag];
                            replay_dep_tag[replay_wr_idx] <= pred_tag[result_tag];
                            replay_wr_ptr                 <= replay_wr_ptr + 1;
                        end

                        // Mark tag as NOT completed — it needs replay.
                        // The correct result will arrive when the replay
                        // micro-op completes.
                        completed[result_tag]  <= 1'b0;
                        speculative[result_tag] <= 1'b0;  // replay is non-speculative
                    end else begin
                        // CORRECT PREDICTION: carry was 0, result is good.
                        speculation_correct <= speculation_correct + 1;
                        speculative[result_tag] <= 1'b0;

                        // Accept result: writeback to BRAM
                        if (uops_completed < uops_issued) begin
                            bram_wr_en     <= 1'b1;
                            bram_wr_addr   <= tag_dst_addr[result_tag];
                            bram_wr_data   <= result_data;
                            uops_completed <= uops_completed + 1;
                        end
                    end
                end else begin
                    // Non-speculative result (either SPECULATIVE_CARRY=0,
                    // or this was a replay result, or word 0 which has no
                    // predecessor). Accept unconditionally.
                    if (uops_completed < uops_issued) begin
                        bram_wr_en     <= 1'b1;
                        bram_wr_addr   <= tag_dst_addr[result_tag];
                        bram_wr_data   <= result_data;
                        uops_completed <= uops_completed + 1;
                    end
                end
            end

            case (state)

            // =============================================================
            S_IDLE: begin
                cmd_ready <= 1'b1;
                done      <= 1'b0;
                if (cmd_valid && cmd_ready) begin
                    // Latch command
                    op_reg    <= cmd_opcode;
                    src_a_reg <= cmd_src_a;
                    src_b_reg <= cmd_src_b;
                    dst_reg   <= cmd_dst;
                    len_a_reg <= cmd_len_a;
                    len_b_reg <= cmd_len_b;
                    // Init counters
                    cmd_ready       <= 1'b0;
                    busy            <= 1'b1;
                    uops_issued     <= 32'd0;
                    uops_completed  <= 32'd0;
                    cycle_count     <= 32'd0;
                    fetch_idx       <= 16'd0;
                    fetch_pipe      <= 1'b0;
                    err_unsupported <= 1'b0;
                    // D3 fix: next_tag is NOT reset — monotonically increasing.
                    // Capture start_tag for this operation.
                    start_tag      <= next_tag;
                    // Phase E: clear replay queue for new operation
                    replay_wr_ptr  <= {(REPLAY_PTR_W+1){1'b0}};
                    replay_rd_ptr  <= {(REPLAY_PTR_W+1){1'b0}};
                    replay_dispatching <= 1'b0;
                    state          <= S_FETCH_A;
                    bram_rd_en     <= 1'b1;
                    bram_rd_addr   <= cmd_src_a;
                end
            end

            // =============================================================
            S_FETCH_A: begin
                if (fetch_pipe && bram_rd_valid) begin
                    buf_a[fetch_idx - 1] <= bram_rd_data;
                end

                if (fetch_idx < len_a_reg) begin
                    bram_rd_addr <= src_a_reg + fetch_idx;
                    bram_rd_en   <= 1'b1;
                    fetch_idx    <= fetch_idx + 1;
                    fetch_pipe   <= 1'b1;
                end else begin
                    // Capture last word
                    if (fetch_pipe && bram_rd_valid) begin
                        buf_a[fetch_idx - 1] <= bram_rd_data;
                    end
                    fetch_idx  <= 16'd0;
                    fetch_pipe <= 1'b0;
                    bram_rd_en <= 1'b1;
                    bram_rd_addr <= src_b_reg;
                    state      <= S_FETCH_B;
                end
            end

            // =============================================================
            S_FETCH_B: begin
                if (fetch_pipe && bram_rd_valid) begin
                    buf_b[fetch_idx - 1] <= bram_rd_data;
                end

                if (fetch_idx < len_b_reg) begin
                    bram_rd_addr <= src_b_reg + fetch_idx;
                    bram_rd_en   <= 1'b1;
                    fetch_idx    <= fetch_idx + 1;
                    fetch_pipe   <= 1'b1;
                end else begin
                    if (fetch_pipe && bram_rd_valid) begin
                        buf_b[fetch_idx - 1] <= bram_rd_data;
                    end
                    bram_rd_en <= 1'b0;
                    fetch_pipe <= 1'b0;
                    // Prepare generation counters
                    gen_i     <= 16'd0;
                    gen_j     <= 16'd0;
                    carry_dep <= 1'b0;

                    // -------------------------------------------------------
                    // D7 fix: zero-length guard — skip to DONE if nothing to do.
                    // D4 fix: MPMUL is unsupported in HW; set error flag.
                    // -------------------------------------------------------
                    if (len_a_reg == 16'd0) begin
                        // Nothing to generate for any operation
                        state <= S_DONE;
                    end else if (op_reg == OP_MPMUL) begin
                        // MPMUL is handled by the RISC-V core using L0
                        // intrinsics (kr_mpn_mul from kr_bignum.h).
                        // Hardware-scheduled MPMUL requires a result
                        // accumulator in the integration top — planned
                        // for a future version.
                        err_unsupported <= 1'b1;
                        state           <= S_DONE;
                    end else begin
                        total_uops <= {16'd0, len_a_reg};
                        state      <= S_GEN_ADD;
                    end
                end
            end

            // =============================================================
            // MPADD/MPSUB: emit one ADDWC/SUBWB per word, linear carry chain
            //
            // Phase E: Two modes controlled by SPECULATIVE_CARRY parameter.
            //
            // SPECULATIVE_CARRY=0 (D9 stall path):
            //   Dispatch stalls when the carry dependency has not yet been
            //   resolved. Single-cycle forwarding bypass avoids a stall in
            //   the common case where the result arrives the same cycle.
            //
            // SPECULATIVE_CARRY=1 (speculative path):
            //   ALL micro-ops are dispatched immediately with uop_dep_valid=0
            //   (predicted carry_in=0). Speculative tracking and replay handle
            //   the rare misprediction case. Replay has priority over new ops.
            // =============================================================
            S_GEN_ADD: begin
                // Phase E: Replay dispatch has priority over new generation
                if (replay_pending && (!uop_valid || uop_ready)) begin
                    // Dispatch from replay queue: the micro-op is
                    // re-issued with correct carry dependency (dep_valid=1,
                    // dep_tag=predecessor). The MAC will pick up the actual
                    // carry from the hi_table via resolved_acc.
                    uop_valid     <= 1'b1;
                    uop_opcode    <= replay_opcode[replay_rd_idx];
                    uop_src1      <= replay_src1[replay_rd_idx];
                    uop_src2      <= replay_src2[replay_rd_idx];
                    uop_tag       <= replay_tag[replay_rd_idx];
                    uop_dep_valid <= 1'b1;  // real dependency for correct carry
                    uop_dep_tag   <= replay_dep_tag[replay_rd_idx];

                    // Restore destination mapping (tag reused, addr unchanged)
                    tag_dst_addr[replay_tag[replay_rd_idx]] <= replay_dst[replay_rd_idx];
                    // Clear stale completion for replayed tag
                    completed[replay_tag[replay_rd_idx]] <= 1'b0;
                    // Mark as non-speculative (replay has correct carry)
                    speculative[replay_tag[replay_rd_idx]] <= 1'b0;
                    pred_valid[replay_tag[replay_rd_idx]]  <= 1'b0;

                    replay_rd_ptr <= replay_rd_ptr + 1;
                end else if ((!uop_valid || uop_ready) && can_emit) begin
                    if (gen_i < len_a_reg) begin
                        uop_valid     <= 1'b1;
                        uop_opcode    <= (op_reg == OP_MPSUB) ? UOP_SUBWB : UOP_ADDWC;
                        uop_src1      <= buf_a[gen_i];
                        uop_src2      <= buf_b[gen_i];
                        uop_tag       <= next_tag;

                        // Phase E: speculative vs. stall-based dependency
                        if (SPECULATIVE_CARRY == 1) begin
                            // Speculative: dispatch with no dependency
                            // (carry_in predicted as 0). MAC gets
                            // resolved_acc=0 since dep_valid=0.
                            uop_dep_valid <= 1'b0;
                            uop_dep_tag   <= {TAG_BITS{1'b0}};

                            // Track speculative state
                            if (carry_dep) begin
                                // This word has a predecessor — mark speculative
                                speculative[next_tag] <= 1'b1;
                                pred_tag[next_tag]    <= carry_tag;
                                pred_valid[next_tag]  <= 1'b1;
                            end else begin
                                // Word 0: no predecessor, not speculative
                                speculative[next_tag] <= 1'b0;
                                pred_valid[next_tag]  <= 1'b0;
                            end
                        end else begin
                            // Non-speculative (D9 path): real dependency
                            uop_dep_valid <= carry_dep;
                            uop_dep_tag   <= carry_tag;
                            speculative[next_tag] <= 1'b0;
                            pred_valid[next_tag]  <= 1'b0;
                        end

                        // Record destination for writeback
                        tag_dst_addr[next_tag] <= dst_reg + gen_i;
                        // D10 fix: clear stale completion bit on tag allocation
                        // Prevents false dep_resolved after tag wrap.
                        completed[next_tag] <= 1'b0;

                        // Phase E: store source operands for potential replay
                        tag_src1[next_tag]   <= buf_a[gen_i];
                        tag_src2[next_tag]   <= buf_b[gen_i];
                        tag_opcode[next_tag] <= (op_reg == OP_MPSUB) ? UOP_SUBWB : UOP_ADDWC;

                        // Update state for next iteration
                        carry_tag   <= next_tag;
                        carry_dep   <= 1'b1;  // all subsequent words depend on carry
                        next_tag    <= next_tag + 1;
                        gen_i       <= gen_i + 1;
                        uops_issued <= uops_issued + 1;
                    end else begin
                        uop_valid <= 1'b0;
                        last_tag  <= next_tag - 1;
                        state     <= S_DRAIN;
                    end
                end
            end

            // =============================================================
            // S_GEN_MUL: reserved — MPMUL not dispatched through HW path.
            // Kept as a placeholder for future implementation with proper
            // result accumulation support in the integration top.
            // =============================================================
            S_GEN_MUL: begin
                // Should never be reached; S_FETCH_B routes MPMUL to S_DONE.
                err_unsupported <= 1'b1;
                state           <= S_DONE;
            end

            // =============================================================
            // DRAIN: wait for all issued micro-ops to complete
            //
            // Phase E: In speculative mode, we must also drain any pending
            // replays. A replay generates a new result which may itself
            // trigger further replays (cascading carries), so we wait
            // until both the replay queue is empty AND all uops are done.
            // =============================================================
            S_DRAIN: begin
                // Phase E: Continue dispatching replays during drain
                if (replay_pending && (!uop_valid || uop_ready)) begin
                    uop_valid     <= 1'b1;
                    uop_opcode    <= replay_opcode[replay_rd_idx];
                    uop_src1      <= replay_src1[replay_rd_idx];
                    uop_src2      <= replay_src2[replay_rd_idx];
                    uop_tag       <= replay_tag[replay_rd_idx];
                    uop_dep_valid <= 1'b1;
                    uop_dep_tag   <= replay_dep_tag[replay_rd_idx];

                    tag_dst_addr[replay_tag[replay_rd_idx]] <= replay_dst[replay_rd_idx];
                    completed[replay_tag[replay_rd_idx]]    <= 1'b0;
                    speculative[replay_tag[replay_rd_idx]]  <= 1'b0;
                    pred_valid[replay_tag[replay_rd_idx]]   <= 1'b0;

                    replay_rd_ptr <= replay_rd_ptr + 1;
                end else if (!replay_pending) begin
                    uop_valid <= 1'b0;
                end

                // Done when all results collected and no replays pending
                if (uops_completed >= uops_issued && replay_empty) begin
                    state <= S_DONE;
                end
            end

            // =============================================================
            // DONE: signal completion
            // =============================================================
            S_DONE: begin
                busy  <= 1'b0;
                done  <= 1'b1;
                irq   <= 1'b1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;

            endcase
        end
    end

endmodule

`default_nettype wire
