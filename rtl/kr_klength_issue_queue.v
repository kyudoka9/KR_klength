// Copyright 2026 Kyudoka Research, H. Ismail
// Instruction Queue (FIFO) for Tomasulo Scheduler
// Shallow depths (<=64): distributed RAM — co-located with logic, no skew.
// Deep FIFOs (>64): block RAM in dedicated columns.
`default_nettype none
`timescale 1ns / 1ps

module kr_klength_issue_queue #(
    parameter DEPTH     = 512,
    parameter DATA_BITS = 32
) (
    input  wire                    clk,
    input  wire                    rst,

    // Write port
    input  wire                    wr_en,
    input  wire [DATA_BITS-1:0]    wr_data,

    // Read port
    input  wire                    rd_en,
    output wire [DATA_BITS-1:0]    rd_data,

    // Status
    output wire                    empty,
    output wire                    full,
    output wire [9:0]              count
);

    // ---------------------------------------------------------------
    // Address width calculation from DEPTH parameter
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

    localparam ADDR_BITS = clog2(DEPTH);

    // ---------------------------------------------------------------
    // Pointers and count
    // ---------------------------------------------------------------
    reg [ADDR_BITS-1:0] wr_ptr;
    reg [ADDR_BITS-1:0] rd_ptr;
    reg [ADDR_BITS:0]   fifo_count;

    assign count = fifo_count;
    assign empty = (fifo_count == 0);
    assign full  = (fifo_count == DEPTH[ADDR_BITS:0]);

    // ---------------------------------------------------------------
    // Read data (synchronous read)
    // ---------------------------------------------------------------
    reg [DATA_BITS-1:0] rd_data_reg;
    assign rd_data = rd_data_reg;

    wire do_write = wr_en & ~full;
    wire do_read  = rd_en & ~empty;

    // ---------------------------------------------------------------
    // Memory and control — split by depth for optimal RAM inference
    // ---------------------------------------------------------------
    generate
        if (DEPTH <= 64) begin : gen_shallow
            // Distributed RAM: co-located with controlling FFs in slices.
            // Eliminates BRAM-to-slice clock skew at high frequencies.
            (* ram_style = "distributed" *)
            reg [DATA_BITS-1:0] mem [0:DEPTH-1];

            always @(posedge clk) begin
                if (rst) begin
                    wr_ptr      <= {ADDR_BITS{1'b0}};
                    rd_ptr      <= {ADDR_BITS{1'b0}};
                    fifo_count  <= {(ADDR_BITS+1){1'b0}};
                    rd_data_reg <= {DATA_BITS{1'b0}};
                end else begin
                    if (do_write) begin
                        mem[wr_ptr] <= wr_data;
                        if (wr_ptr == DEPTH[ADDR_BITS-1:0] - 1)
                            wr_ptr <= {ADDR_BITS{1'b0}};
                        else
                            wr_ptr <= wr_ptr + {{(ADDR_BITS-1){1'b0}}, 1'b1};
                    end
                    if (do_read) begin
                        rd_data_reg <= mem[rd_ptr];
                        if (rd_ptr == DEPTH[ADDR_BITS-1:0] - 1)
                            rd_ptr <= {ADDR_BITS{1'b0}};
                        else
                            rd_ptr <= rd_ptr + {{(ADDR_BITS-1){1'b0}}, 1'b1};
                    end
                    case ({do_write, do_read})
                        2'b10:   fifo_count <= fifo_count + {{ADDR_BITS{1'b0}}, 1'b1};
                        2'b01:   fifo_count <= fifo_count - {{ADDR_BITS{1'b0}}, 1'b1};
                        default: ;
                    endcase
                end
            end
        end else begin : gen_deep
            // Block RAM: efficient for large FIFOs in dedicated columns.
            (* ram_style = "block" *)
            reg [DATA_BITS-1:0] mem [0:DEPTH-1];

            always @(posedge clk) begin
                if (rst) begin
                    wr_ptr      <= {ADDR_BITS{1'b0}};
                    rd_ptr      <= {ADDR_BITS{1'b0}};
                    fifo_count  <= {(ADDR_BITS+1){1'b0}};
                    rd_data_reg <= {DATA_BITS{1'b0}};
                end else begin
                    if (do_write) begin
                        mem[wr_ptr] <= wr_data;
                        if (wr_ptr == DEPTH[ADDR_BITS-1:0] - 1)
                            wr_ptr <= {ADDR_BITS{1'b0}};
                        else
                            wr_ptr <= wr_ptr + {{(ADDR_BITS-1){1'b0}}, 1'b1};
                    end
                    if (do_read) begin
                        rd_data_reg <= mem[rd_ptr];
                        if (rd_ptr == DEPTH[ADDR_BITS-1:0] - 1)
                            rd_ptr <= {ADDR_BITS{1'b0}};
                        else
                            rd_ptr <= rd_ptr + {{(ADDR_BITS-1){1'b0}}, 1'b1};
                    end
                    case ({do_write, do_read})
                        2'b10:   fifo_count <= fifo_count + {{ADDR_BITS{1'b0}}, 1'b1};
                        2'b01:   fifo_count <= fifo_count - {{ADDR_BITS{1'b0}}, 1'b1};
                        default: ;
                    endcase
                end
            end
        end
    endgenerate

endmodule

`default_nettype wire
