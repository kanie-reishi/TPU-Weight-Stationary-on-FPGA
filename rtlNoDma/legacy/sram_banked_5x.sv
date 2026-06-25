`timescale 1ns / 1ps

module sram_banked_5x #(
    parameter DWIDTH = 128,
    parameter AWIDTH = 11
)(
    input  logic clk,
    
    //======================================
    // Port A (Array size 5)
    // Dành cho: DMA Ghi/Đọc tuần tự
    //======================================
    input  logic [4:0]              ena_i,
    input  logic [4:0]              wea_i,
    input  logic [AWIDTH-1:0]       addra_i [0:4],
    input  logic [DWIDTH-1:0]       dina_i [0:4],
    output logic [DWIDTH-1:0]       douta_o [0:4],
    
    //======================================
    // Port B (Array size 5)
    // Dành cho: Mảng PEA Đọc 5 hàng song song
    //======================================
    input  logic [4:0]              enb_i,
    input  logic [4:0]              web_i,
    input  logic [AWIDTH-1:0]       addrb_i [0:4],
    input  logic [DWIDTH-1:0]       dinb_i [0:4],
    output logic [DWIDTH-1:0]       doutb_o [0:4]
);

    genvar i;
    generate
        for (i = 0; i < 5; i++) begin : gen_banks
            sram_tdp #(
                .DWIDTH(DWIDTH),
                .AWIDTH(AWIDTH)
            ) u_sram_bank (
                .clk(clk),
                
                // Port A
                .ena(ena_i[i]),
                .wea(wea_i[i]),
                .addra(addra_i[i]),
                .dina(dina_i[i]),
                .douta(douta_o[i]),
                
                // Port B
                .enb(enb_i[i]),
                .web(web_i[i]),
                .addrb(addrb_i[i]),
                .dinb(dinb_i[i]),
                .doutb(doutb_o[i])
            );
        end
    endgenerate

endmodule
