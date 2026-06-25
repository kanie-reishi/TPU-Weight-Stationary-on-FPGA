`timescale 1ns / 1ps

module ifm_arbiter #(
    parameter ADDR_WIDTH = 11,
    parameter DATA_WIDTH = 128
)(
    // Giao tiếp với PEA
    input  logic                  bank_sel, // 0: Ping là IFM, 1: Pong là IFM
    input  logic [ADDR_WIDTH-1:0] pea_ifm_addr,
    input  logic                  pea_ifm_re,
    output logic [DATA_WIDTH-1:0] pea_ifm_rdata,

    // Giao tiếp với Ping Bank (Port B)
    output logic                  ping_en,
    output logic [ADDR_WIDTH-1:0] ping_addr,
    input  logic [DATA_WIDTH-1:0] ping_rdata,

    // Giao tiếp với Pong Bank (Port B)
    output logic                  pong_en,
    output logic [ADDR_WIDTH-1:0] pong_addr,
    input  logic [DATA_WIDTH-1:0] pong_rdata
);

    always_comb begin
        // Mặc định tắt các cờ Enable
        ping_en = 1'b0;
        pong_en = 1'b0;
        ping_addr = '0;
        pong_addr = '0;
        pea_ifm_rdata = '0;

        if (bank_sel == 1'b0) begin
            // Ping là IFM
            ping_en = pea_ifm_re;
            ping_addr = pea_ifm_addr;
            pea_ifm_rdata = ping_rdata;
        end else begin
            // Pong là IFM
            pong_en = pea_ifm_re;
            pong_addr = pea_ifm_addr;
            pea_ifm_rdata = pong_rdata;
        end
    end

endmodule
