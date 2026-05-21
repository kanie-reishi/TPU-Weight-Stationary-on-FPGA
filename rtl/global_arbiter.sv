`timescale 1ns / 1ps

module global_arbiter #(
    parameter AXI_AWIDTH  = 40, 
    parameter AXI_DWIDTH  = 64,
    parameter SRAM_AWIDTH = 16 
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
    // ... các tín hiệu AXI-Lite khác

    // =========================================================
    // 2. GIAO DIỆN VỚI DDR (AXI4-Full Master)
    // =========================================================
    // --- Kênh Read Address (AR) ---
    output logic [AXI_AWIDTH-1:0]   m_axi_araddr,
    output logic [7:0]              m_axi_arlen,
    output logic [2:0]              m_axi_arsize,
    output logic [1:0]              m_axi_arburst,
    output logic                    m_axi_arvalid,
    input  logic                    m_axi_arready,
    
    // --- Kênh Read Data (R) ---
    input  logic [AXI_DWIDTH-1:0]   m_axi_rdata,
    input  logic                    m_axi_rlast,
    input  logic                    m_axi_rvalid,
    output logic                    m_axi_rready,

    // --- Kênh Write Address (AW) ---
    output logic [AXI_AWIDTH-1:0]   m_axi_awaddr,
    output logic [7:0]              m_axi_awlen,
    output logic [2:0]              m_axi_awsize,
    output logic [1:0]              m_axi_awburst,
    output logic                    m_axi_awvalid,
    input  logic                    m_axi_awready,

    // --- Kênh Write Data (W) ---
    output logic [AXI_DWIDTH-1:0]   m_axi_wdata,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  logic                    m_axi_wready,

    // --- Kênh Write Response (B) ---
    input  logic [1:0]              m_axi_bresp,
    input  logic                    m_axi_bvalid,
    output logic                    m_axi_bready,

    // =========================================================
    // 3. LUỒNG ĐI TỚI CONTROLLER (Instruction & Control)
    // =========================================================
    // Bơm lệnh cho Controller
    output logic [63:0]             ctrl_inst_data_o,
    output logic                    ctrl_inst_empty_o,
    input  logic                    ctrl_inst_read_i,
    
    // Nhận cấu hình DMA từ Controller
    input  logic                    ctrl_dma_req_i,
    input  logic                    ctrl_dma_dir_i,      // 0=READ(DDR->SRAM), 1=WRITE(SRAM->DDR)
    input  logic [AXI_AWIDTH-1:0]   ctrl_dma_addr_i,
    input  logic [31:0]             ctrl_dma_bytes_i,
    input  logic [1:0]              ctrl_dma_bank_sel_i, // 00=WGT, 01=PING, 10=PONG
    output logic                    ctrl_dma_busy_o,

    // =========================================================
    // 4. LUỒNG ĐI TỚI CÁC BANK MEMORY (SRAM Interfaces)
    // =========================================================
    // --- Tới Weight & Bias Bank ---
    output logic                    wgt_we_o,
    output logic [SRAM_AWIDTH-1:0]  wgt_addr_o,
    output logic [AXI_DWIDTH-1:0]   wgt_wdata_o,

    // --- Tới Ping Bank (IFM/OFM) ---
    output logic                    ping_we_o,
    output logic [SRAM_AWIDTH-1:0]  ping_addr_o,
    output logic [AXI_DWIDTH-1:0]   ping_wdata_o,
    input  logic [AXI_DWIDTH-1:0]   ping_rdata_i,

    // --- Tới Pong Bank (IFM/OFM) ---
    output logic                    pong_we_o,
    output logic [SRAM_AWIDTH-1:0]  pong_addr_o,
    output logic [AXI_DWIDTH-1:0]   pong_wdata_o,
    input  logic [AXI_DWIDTH-1:0]   pong_rdata_i
);

    // =========================================================
    // KHỐI 1: INSTRUCTION FIFO (Luồng từ CPU -> Controller)
    // =========================================================
    // Logic bắt dữ liệu từ AXI-Lite đẩy vào FIFO
    logic fifo_wr_en;
    logic [63:0] fifo_wr_data;
    
    // Thanh ghi tạm lưu 32-bit cao của lệnh
    logic [31:0] shadow_reg_high;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shadow_reg_high <= 32'd0;
        end else begin
            // Ghi 32-bit cao vào địa chỉ 0x04
            if (s_axi_awvalid && s_axi_wvalid && s_axi_awaddr == 32'h0000_0004) begin
                shadow_reg_high <= s_axi_wdata;
            end
        end
    end
    
    // Khi CPU ghi 32-bit thấp vào địa chỉ 0x00 (Thanh ghi nạp lệnh)
    assign fifo_wr_en   = (s_axi_awvalid && s_axi_wvalid && s_axi_awaddr == 32'h0000_0000);
    
    // Ghép 32-bit cao từ shadow_reg và 32-bit thấp từ wdata
    assign fifo_wr_data = {shadow_reg_high, s_axi_wdata};

    // Khởi tạo IP Instruction FIFO (First-In-First-Out)
    logic fifo_full;
    instruction_fifo u_inst_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en      (fifo_wr_en),
        .wr_data    (fifo_wr_data),
        .full       (fifo_full),
        .rd_en      (ctrl_inst_read_i),    // Controller xin đọc lệnh
        .rd_data    (ctrl_inst_data_o),    // Trả lệnh về Controller
        .empty      (ctrl_inst_empty_o)    // Báo Controller biết hết lệnh chưa
    );

    // Hardware Backpressure: Chặn AXI-Lite nếu FIFO đã đầy
    assign s_axi_awready = ~fifo_full;
    assign s_axi_wready  = ~fifo_full;

    // =========================================================
    // KHỐI 2: DMA ENGINE (Luồng kéo/đẩy DDR)
    // =========================================================
    logic                   dma_internal_we;
    logic [SRAM_AWIDTH-1:0] dma_internal_addr;
    logic [AXI_DWIDTH-1:0]  dma_internal_wdata;
    logic [AXI_DWIDTH-1:0]  dma_internal_rdata;
    logic [1:0]             dma_internal_bank_sel;

    // Tái sử dụng module DMA FSM chúng ta đã viết ở bước trước
    axi_full_dma_engine u_dma_engine (
        .clk            (clk),
        .rst_n          (rst_n),
        
        // Giao tiếp Controller
        .dma_req_i      (ctrl_dma_req_i),
        .dma_dir_i      (ctrl_dma_dir_i),
        .dma_addr_i     (ctrl_dma_addr_i),
        .dma_bytes_i    (ctrl_dma_bytes_i),
        .dma_bank_sel_i (ctrl_dma_bank_sel_i),
        .dma_busy_o     (ctrl_dma_busy_o),
        
        // Kênh AXI (Nối thẳng ra Port ngoài)
        .m_axi_araddr   (m_axi_araddr),
        .m_axi_arlen    (m_axi_arlen),
        .m_axi_arsize   (m_axi_arsize),
        .m_axi_arburst  (m_axi_arburst),
        .m_axi_arvalid  (m_axi_arvalid),
        .m_axi_arready  (m_axi_arready),
        .m_axi_rdata    (m_axi_rdata),
        .m_axi_rlast    (m_axi_rlast),
        .m_axi_rvalid   (m_axi_rvalid),
        .m_axi_rready   (m_axi_rready),
        .m_axi_awaddr   (m_axi_awaddr),
        .m_axi_awlen    (m_axi_awlen),
        .m_axi_awsize   (m_axi_awsize),
        .m_axi_awburst  (m_axi_awburst),
        .m_axi_awvalid  (m_axi_awvalid),
        .m_axi_awready  (m_axi_awready),
        .m_axi_wdata    (m_axi_wdata),
        .m_axi_wlast    (m_axi_wlast),
        .m_axi_wvalid   (m_axi_wvalid),
        .m_axi_wready   (m_axi_wready),
        .m_axi_bresp    (m_axi_bresp),
        .m_axi_bvalid   (m_axi_bvalid),
        .m_axi_bready   (m_axi_bready),
        
        // Cổng Memory chung (Sẽ được Demux ở dưới)
        .sram_we_o      (dma_internal_we),
        .sram_bank_o    (dma_internal_bank_sel),
        .sram_addr_o    (dma_internal_addr),
        .sram_wdata_o   (dma_internal_wdata),
        .sram_rdata_i   (dma_internal_rdata)
    );

    // =========================================================
    // KHỐI 3: ROUTER & DEMUX (Phân luồng Memory)
    // =========================================================
    // 3.1. Luồng Ghi (Demultiplexer: Từ DMA vào các Bank)
    // DMA chỉ có 1 cổng ra, ta dùng dma_bank_sel_i để bẻ lái tín hiệu Write Enable (WE).
    
    always_comb begin
        // Mặc định khóa tất cả các cổng Ghi
        wgt_we_o  = 1'b0;
        ping_we_o = 1'b0;
        pong_we_o = 1'b0;

        // Bẻ lái theo cấu hình từ Controller
        if (dma_internal_we) begin
            case (dma_internal_bank_sel)
                2'b00: wgt_we_o  = 1'b1;  // Đẩy vào Weight Bank
                2'b01: ping_we_o = 1'b1;  // Đẩy vào Ping Bank
                2'b10: pong_we_o = 1'b1;  // Đẩy vào Pong Bank
            endcase
        end
    end

    // Dây Address và Data Write được nối song song tới tất cả các Bank.
    // Bank nào có tín hiệu WE (ở trên) bật lên thì bank đó mới nhận dữ liệu.
    assign wgt_addr_o   = dma_internal_addr;
    assign ping_addr_o  = dma_internal_addr;
    assign pong_addr_o  = dma_internal_addr;

    assign wgt_wdata_o  = dma_internal_wdata;
    assign ping_wdata_o = dma_internal_wdata;
    assign pong_wdata_o = dma_internal_wdata;

    // 3.2. Luồng Đọc (Multiplexer: Từ Ping/Pong Bank ra DMA để STORE_OFM)
    // Khi STORE_OFM, DMA Engine cần dữ liệu từ Ping hoặc Pong. Ta dùng Mux để chọn.
    
    always_comb begin
        case (dma_internal_bank_sel)
            2'b01: dma_internal_rdata = ping_rdata_i; // Đọc từ Ping Bank ra DDR
            2'b10: dma_internal_rdata = pong_rdata_i; // Đọc từ Pong Bank ra DDR
            default: dma_internal_rdata = '0;
        endcase
    end

endmodule