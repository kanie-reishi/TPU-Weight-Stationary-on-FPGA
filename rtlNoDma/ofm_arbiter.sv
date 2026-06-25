`timescale 1ns / 1ps

module ofm_arbiter #(
    parameter ADDR_WIDTH = 11,
    parameter DATA_WIDTH = 128
)(
    // Giao tiếp với PEA
    input  logic                  bank_sel, // 0: Ping là IFM -> Pong là OFM, 1: Pong là IFM -> Ping là OFM
    input  logic [ADDR_WIDTH-1:0] pea_ofm_addr,
    input  logic                  pea_ofm_we,
    input  logic [DATA_WIDTH-1:0] pea_ofm_wdata,

    // Giao tiếp với Ping Bank (Port B)
    output logic                  ping_en,
    output logic                  ping_we,
    output logic [ADDR_WIDTH-1:0] ping_addr,
    output logic [DATA_WIDTH-1:0] ping_wdata,

    // Giao tiếp với Pong Bank (Port B)
    output logic                  pong_en,
    output logic                  pong_we,
    output logic [ADDR_WIDTH-1:0] pong_addr,
    output logic [DATA_WIDTH-1:0] pong_wdata
);

    always_comb begin
        // Mặc định tắt các cờ
        ping_en = 1'b0;
        ping_we = 1'b0;
        ping_addr = '0;
        ping_wdata = '0;
        
        pong_en = 1'b0;
        pong_we = 1'b0;
        pong_addr = '0;
        pong_wdata = '0;

        if (bank_sel == 1'b0) begin
            // Ping là IFM -> Pong là OFM
            pong_en = pea_ofm_we;
            pong_we = pea_ofm_we;
            pong_addr = pea_ofm_addr;
            pong_wdata = pea_ofm_wdata;
        end else begin
            // Pong là IFM -> Ping là OFM
            ping_en = pea_ofm_we;
            ping_we = pea_ofm_we;
            ping_addr = pea_ofm_addr;
            ping_wdata = pea_ofm_wdata;
        end
    end

endmodule
