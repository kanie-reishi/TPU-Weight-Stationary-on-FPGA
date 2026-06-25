`timescale 1ns / 1ps

module global_arbiter #(
    parameter AXI_AWIDTH  = 40, 
    parameter AXI_DWIDTH  = 64,
    parameter SRAM_DWIDTH = 128,
    // [GIẢNG BÀI] Tối ưu hóa: Thu nhỏ Address Width xuống 11-bit (16KB)
    parameter SRAM_AWIDTH = 11 
)(
    input  logic clk,
    input  logic rst_n,

    // =========================================================
    // 1. GIAO DIỆN VỚI CPU HOST (AXI-Lite Slave)
    // =========================================================
    // (Lược giản các tín hiệu AXI-Lite để tập trung vào luồng logic)
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,
    input  logic [31:0]             s_axi_awaddr,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,
    input  logic [31:0]             s_axi_wdata,

    // =========================================================
    // 2. LUỒNG ĐI TỚI CONTROLLER (Instruction & Control)
    // =========================================================
    // Bơm lệnh cho Controller
    output logic [63:0]             ctrl_inst_data_o,
    output logic                    ctrl_inst_empty_o,
    input  logic                    ctrl_inst_read_i,
    
    // =========================================================
    // 3. LUỒNG ĐI TỚI CÁC BANK MEMORY (SRAM Interfaces)
    // =========================================================
    // --- Tới Weight & Bias Bank ---
    output logic                    wgt_we_o,
    output logic [SRAM_AWIDTH-1:0]  wgt_addr_o,
    output logic [SRAM_DWIDTH-1:0]  wgt_wdata_o,

    // --- Tới Ping Bank (IFM/OFM) ---
    output logic                    ping_we_o,
    output logic [SRAM_AWIDTH-1:0]  ping_addr_o,
    output logic [SRAM_DWIDTH-1:0]  ping_wdata_o,
    input  logic [SRAM_DWIDTH-1:0]  ping_rdata_i,

    // --- Tới Pong Bank (IFM/OFM) ---
    output logic                    pong_we_o,
    output logic [SRAM_AWIDTH-1:0]  pong_addr_o,
    output logic [SRAM_DWIDTH-1:0]  pong_wdata_o,
    input  logic [SRAM_DWIDTH-1:0]  pong_rdata_i
);

    // =========================================================
    // KHỐI 1: INSTRUCTION FIFO (Luồng từ CPU -> Controller)
    // =========================================================
    // Logic bắt dữ liệu từ AXI-Lite đẩy vào FIFO
    logic w_fifo_wr_en;
    logic [63:0] w_fifo_wr_data;
    
    // Thanh ghi tạm lưu 32-bit cao của lệnh
    logic [31:0] r_shadow_reg_high;
    logic        w_axi_write_fire;

    // Pulse only when the AXI-Lite write handshake completes (devmem2 can hold
    // AWVALID/WVALID high for multiple cycles — do not push the FIFO every cycle).
    assign w_axi_write_fire = s_axi_awvalid && s_axi_wvalid && s_axi_awready && s_axi_wready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_shadow_reg_high <= 32'd0;
        end else begin
            // Ghi 32-bit cao vào địa chỉ 0x04
            if (w_axi_write_fire && s_axi_awaddr == 32'h0000_0004) begin
                r_shadow_reg_high <= s_axi_wdata;
            end
        end
    end
    
    // Khi CPU ghi 32-bit thấp vào địa chỉ 0x00 (Thanh ghi nạp lệnh)
    assign w_fifo_wr_en   = w_axi_write_fire && (s_axi_awaddr == 32'h0000_0000);
    
    // Ghép 32-bit cao từ shadow_reg và 32-bit thấp từ wdata
    assign w_fifo_wr_data = {r_shadow_reg_high, s_axi_wdata};

    // Khởi tạo IP Instruction FIFO (First-In-First-Out)
    logic w_fifo_full;
    instruction_fifo u_inst_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en      (w_fifo_wr_en),
        .wr_data    (w_fifo_wr_data),
        .full       (w_fifo_full),
        .rd_en      (ctrl_inst_read_i),    // Controller xin đọc lệnh
        .rd_data    (ctrl_inst_data_o),    // Trả lệnh về Controller
        .empty      (ctrl_inst_empty_o)    // Báo Controller biết hết lệnh chưa
    );

    // Hardware Backpressure: Chặn AXI-Lite nếu FIFO đã đầy
    assign s_axi_awready = ~w_fifo_full;
    assign s_axi_wready  = ~w_fifo_full;
endmodule