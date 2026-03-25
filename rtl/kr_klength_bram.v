// Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
// KR k-Length Computing — Dual-Port Shared Operand Memory
//
// True dual-port BRAM for operand storage shared between:
//   Port A: RISC-V core (read/write operands and results)
//   Port B: Decomposition engine (read operands) + scheduler (write results)
//
// Infers BRAM on Xilinx 7-series. 32 KB = 8192 x 32-bit = 8 x RAMB36E1.
//
`default_nettype none

module kr_klength_bram #(
    parameter ADDR_WIDTH = 13,          // 2^13 = 8192 words = 32 KB
    parameter DATA_WIDTH = 32
) (
    input  wire                    clk,

    // Port A: RISC-V side (Wishbone)
    input  wire                    a_en,
    input  wire                    a_we,
    input  wire [ADDR_WIDTH-1:0]   a_addr,
    input  wire [DATA_WIDTH-1:0]   a_din,
    output reg  [DATA_WIDTH-1:0]   a_dout,

    // Port B: Decomposition engine / scheduler side
    input  wire                    b_en,
    input  wire                    b_we,
    input  wire [ADDR_WIDTH-1:0]   b_addr,
    input  wire [DATA_WIDTH-1:0]   b_din,
    output reg  [DATA_WIDTH-1:0]   b_dout
);

    // BRAM storage — infers RAMB36E1 on Xilinx 7-series
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

    // Port A
    always @(posedge clk) begin
        if (a_en) begin
            if (a_we)
                mem[a_addr] <= a_din;
            a_dout <= mem[a_addr];
        end
    end

    // Port B
    always @(posedge clk) begin
        if (b_en) begin
            if (b_we)
                mem[b_addr] <= b_din;
            b_dout <= mem[b_addr];
        end
    end

endmodule

`default_nettype wire
