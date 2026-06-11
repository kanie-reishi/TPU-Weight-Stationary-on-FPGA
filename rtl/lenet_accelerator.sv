`timescale 1ns / 1ps

module lenet_accelerator #(
    parameter AXI_AWIDTH  = 40, 
    parameter AXI_DWIDTH  = 64, // AXI Bus width
    parameter SRAM_DWIDTH = 128, // Internal SRAM width
    parameter SRAM_AWIDTH = 11   // 16KB per bank (2048 words * 16 bytes)
)(
    input  logic clk,
    input  logic rst_n,

    // =========================================================
    // 1. GIAO DIỆN AXI-LITE SLAVE (CPU -> FPGA)
    // =========================================================
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,
    input  logic [31:0]             s_axi_awaddr,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,
    input  logic [31:0]             s_axi_wdata,
    
    // Read channel
    input  logic                   s_axi_arvalid,
    output logic                   s_axi_arready,
    input  logic [31:0]            s_axi_araddr,
    output logic                   s_axi_rvalid,
    input  logic                   s_axi_rready,
    output logic [31:0]            s_axi_rdata,
    output logic [1:0]             s_axi_rresp,
    
    input  logic                    s_axi_bready,
    output logic                    s_axi_bvalid,
    output logic [1:0]              s_axi_bresp,

    // =========================================================
    // 2. GIAO DIỆN AXI-FULL MASTER (FPGA -> DDR)
    // =========================================================
    output logic [AXI_AWIDTH-1:0]   m_axi_araddr,
    output logic [7:0]              m_axi_arlen,
    output logic [2:0]              m_axi_arsize,
    output logic [1:0]              m_axi_arburst,
    output logic                    m_axi_arvalid,
    input  logic                    m_axi_arready,
    
    input  logic [AXI_DWIDTH-1:0]   m_axi_rdata,
    input  logic                    m_axi_rlast,
    input  logic                    m_axi_rvalid,
    output logic                    m_axi_rready,

    output logic [AXI_AWIDTH-1:0]   m_axi_awaddr,
    output logic [7:0]              m_axi_awlen,
    output logic [2:0]              m_axi_awsize,
    output logic [1:0]              m_axi_awburst,
    output logic                    m_axi_awvalid,
    input  logic                    m_axi_awready,

    output logic [AXI_DWIDTH-1:0]   m_axi_wdata,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  logic                    m_axi_wready,

    input  logic [1:0]              m_axi_bresp,
    input  logic                    m_axi_bvalid,
    output logic                    m_axi_bready,

    // =========================================================
    // 3. NGẮT (INTERRUPT TỚI CPU)
    // =========================================================
    output logic                    finish_irq_o
);

    // =========================================================
    // TÍN HIỆU KẾT NỐI NỘI BỘ
    // =========================================================
    // Instruction FIFO
    logic [63:0] w_inst_data;
    logic        w_inst_empty;
    logic        w_inst_read;

    // DMA Control
    logic                  w_dma_req;
    logic                  w_dma_dir;
    logic [AXI_AWIDTH-1:0] w_dma_addr;
    logic [31:0]           w_dma_bytes;
    logic [1:0]            w_dma_bank_sel;
    logic                  w_dma_busy;

    // PEA Control & Parameters
    logic        ctrl_mac_start;
    logic        ctrl_mac_done;
    logic        ctrl_pool_start;
    logic        ctrl_pool_done;
    
    logic [1:0]  w_src_bank;
    logic [1:0]  w_dst_bank;

    // PEA <-> SRAM Interfaces
    logic [SRAM_AWIDTH-1:0] w_pea_ifm_addr, w_pea_ofm_addr, w_pea_wgt_addr;
    logic                   w_pea_ifm_re, w_pea_ofm_we, w_pea_wgt_re;
    logic [SRAM_DWIDTH-1:0] w_pea_ifm_rdata, w_pea_ofm_wdata, w_pea_wgt_rdata;

    // SRAM Port A (DMA Access)
    logic                   w_wgt_we_a, w_ping_we_a, w_pong_we_a;
    logic [SRAM_AWIDTH-1:0] w_wgt_addr_a, w_ping_addr_a, w_pong_addr_a;
    logic [SRAM_DWIDTH-1:0] w_wgt_wdata_a, w_ping_wdata_a, w_pong_wdata_a;
    logic [SRAM_DWIDTH-1:0] w_wgt_rdata_a, w_ping_rdata_a, w_pong_rdata_a;

    // SRAM Port B (PEA Access)
    logic                   w_wgt_en_b, w_ping_en_b, w_pong_en_b;
    logic                   w_wgt_we_b, w_ping_we_b, w_pong_we_b;
    logic [SRAM_AWIDTH-1:0] w_wgt_addr_b, w_ping_addr_b, w_pong_addr_b;
    logic [SRAM_DWIDTH-1:0] w_wgt_wdata_b, w_ping_wdata_b, w_pong_wdata_b;
    logic [SRAM_DWIDTH-1:0] w_wgt_rdata_b, w_ping_rdata_b, w_pong_rdata_b;

    // Arbiter Outputs
    logic                   w_ifm_ping_en, w_ifm_pong_en;
    logic [SRAM_AWIDTH-1:0] w_ifm_ping_addr, w_ifm_pong_addr;
    
    logic                   w_ofm_ping_en, w_ofm_ping_we;
    logic [SRAM_AWIDTH-1:0] w_ofm_ping_addr;
    logic [SRAM_DWIDTH-1:0] w_ofm_ping_wdata;

    logic                   w_ofm_pong_en, w_ofm_pong_we;
    logic [SRAM_AWIDTH-1:0] w_ofm_pong_addr;
    logic [SRAM_DWIDTH-1:0] w_ofm_pong_wdata;

    // PEA Config
    logic [15:0] w_ifm_w, w_ifm_h, w_ifm_c, w_ofm_c;
    logic [7:0]  w_knl_size;
    logic [3:0]  w_stride, w_shift_amt;
    logic        w_relu_en;
    logic [1:0]  w_pool_type;

    // =========================================================
    // 1. GLOBAL ARBITER (AXI, DMA)
    // =========================================================
    global_arbiter #(
        .AXI_AWIDTH(AXI_AWIDTH),
        .AXI_DWIDTH(AXI_DWIDTH),
        .SRAM_DWIDTH(SRAM_DWIDTH),
        .SRAM_AWIDTH(SRAM_AWIDTH)
    ) u_global_arbiter (
        .clk(clk), .rst_n(rst_n),
        // AXI-Lite
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr),   .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),   .s_axi_wdata(s_axi_wdata),
        // AXI-Full
        .m_axi_araddr(m_axi_araddr),   .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),   .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),     .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),   .m_axi_rready(m_axi_rready),
        .m_axi_awaddr(m_axi_awaddr),   .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),   .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),     .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),   .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),     .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        // Instruction FIFO
        .ctrl_inst_data_o(w_inst_data), .ctrl_inst_empty_o(w_inst_empty), .ctrl_inst_read_i(w_inst_read),
        // DMA Control
        .ctrl_dma_req_i(w_dma_req), .ctrl_dma_dir_i(w_dma_dir), .ctrl_dma_addr_i(w_dma_addr),
        .ctrl_dma_bytes_i(w_dma_bytes), .ctrl_dma_bank_sel_i(w_dma_bank_sel), .ctrl_dma_busy_o(w_dma_busy),
        // SRAM Port A
        .wgt_we_o(w_wgt_we_a),   .wgt_addr_o(w_wgt_addr_a),   .wgt_wdata_o(w_wgt_wdata_a),
        .ping_we_o(w_ping_we_a), .ping_addr_o(w_ping_addr_a), .ping_wdata_o(w_ping_wdata_a), .ping_rdata_i(w_ping_rdata_a),
        .pong_we_o(w_pong_we_a), .pong_addr_o(w_pong_addr_a), .pong_wdata_o(w_pong_wdata_a), .pong_rdata_i(w_pong_rdata_a)
    );

    // =========================================================
    // LOGIC ĐIỀU KHIỂN AXI-LITE READ
    // =========================================================
    logic axi_arready_reg, axi_rvalid_reg;
    logic [31:0] axi_araddr_reg;
    logic [31:0] axi_rdata_reg;

    assign s_axi_arready = axi_arready_reg;
    assign s_axi_rvalid  = axi_rvalid_reg;
    assign s_axi_rdata   = axi_rdata_reg;
    assign s_axi_rresp   = 2'b00; // Luôn trả lời OKAY

    // 1. Chốt địa chỉ đọc (AR Channel)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_arready_reg <= 1'b0;
            axi_araddr_reg  <= 32'd0;
        end else begin
            if (~axi_arready_reg && s_axi_arvalid) begin
                axi_arready_reg <= 1'b1;
                axi_araddr_reg  <= s_axi_araddr;
            end else begin
                axi_arready_reg <= 1'b0;
            end
        end
    end

    // 2. Xung kích hoạt Read
    logic slv_reg_rden;
    assign slv_reg_rden = axi_arready_reg && s_axi_arvalid && ~axi_rvalid_reg;

    // 3. Gửi dữ liệu đọc về CPU (R Channel)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_rvalid_reg <= 1'b0;
            axi_rdata_reg  <= 32'd0;
        end else begin
            if (slv_reg_rden) begin
                axi_rvalid_reg <= 1'b1;
                
                // MUX BỘ NHỚ LƯU TRẠNG THÁI (STATUS REGISTERS)
                case (axi_araddr_reg[7:0])
                    8'h00: axi_rdata_reg <= {31'd0, ctrl_mac_done}; // CPU đọc 0x00 để biết tính xong chưa
                    8'h04: axi_rdata_reg <= {31'd0, finish_irq_o};  // Đọc cờ ngắt
                    // Bạn có thể map thêm các thanh ghi gỡ lỗi (debug) ở đây
                    default: axi_rdata_reg <= 32'hDEADBEEF; // Báo hiệu đọc sai địa chỉ
                endcase
            end else if (axi_rvalid_reg && s_axi_rready) begin
                // CPU đã nhận được dữ liệu, tắt cờ valid
                axi_rvalid_reg <= 1'b0;
            end
        end
    end

    // =========================================================
    // 2. CONTROLLER
    // =========================================================
    controller #(
        .AXI_AWIDTH(AXI_AWIDTH),
        .AXI_DWIDTH(AXI_DWIDTH)
    ) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .inst_data_i(w_inst_data), .inst_empty_i(w_inst_empty), .inst_read_o(w_inst_read),
        .dma_req_o(w_dma_req), .dma_dir_o(w_dma_dir), .dma_addr_o(w_dma_addr),
        .dma_bytes_o(w_dma_bytes), .dma_bank_sel_o(w_dma_bank_sel), .dma_busy_i(w_dma_busy),
        .mac_start_o(ctrl_mac_start), .mac_done_i(ctrl_mac_done),
        .pool_start_o(ctrl_pool_start), .pool_done_i(ctrl_pool_done),
        .src_bank_o(w_src_bank), .dst_bank_o(w_dst_bank),
        .ifm_w_o(w_ifm_w), .ifm_h_o(w_ifm_h), .ifm_c_o(w_ifm_c), .ofm_c_o(w_ofm_c),
        .knl_size_o(w_knl_size), .stride_o(w_stride), .shift_amt_o(w_shift_amt),
        .relu_en_o(w_relu_en), .pool_type_o(w_pool_type),
        .finish_irq_o(finish_irq_o)
    );

    // =========================================================
    // 3. IFM / OFM ARBITERS
    // =========================================================
    logic w_bank_sel_bit;
    assign w_bank_sel_bit = (w_src_bank == 2'b10) ? 1'b1 : 1'b0; // 0=Ping, 1=Pong

    ifm_arbiter #(
        .ADDR_WIDTH(SRAM_AWIDTH),
        .DATA_WIDTH(SRAM_DWIDTH)
    ) u_ifm_arbiter (
        .bank_sel(w_bank_sel_bit),
        .pea_ifm_addr(w_pea_ifm_addr[SRAM_AWIDTH-1:0]), .pea_ifm_re(w_pea_ifm_re), .pea_ifm_rdata(w_pea_ifm_rdata),
        .ping_en(w_ifm_ping_en), .ping_addr(w_ifm_ping_addr), .ping_rdata(w_ping_rdata_b),
        .pong_en(w_ifm_pong_en), .pong_addr(w_ifm_pong_addr), .pong_rdata(w_pong_rdata_b)
    );

    ofm_arbiter #(
        .ADDR_WIDTH(SRAM_AWIDTH),
        .DATA_WIDTH(SRAM_DWIDTH)
    ) u_ofm_arbiter (
        .bank_sel(w_bank_sel_bit),
        .pea_ofm_addr(w_pea_ofm_addr[SRAM_AWIDTH-1:0]), .pea_ofm_we(w_pea_ofm_we), .pea_ofm_wdata(w_pea_ofm_wdata),
        .ping_en(w_ofm_ping_en), .ping_we(w_ofm_ping_we), .ping_addr(w_ofm_ping_addr), .ping_wdata(w_ofm_ping_wdata),
        .pong_en(w_ofm_pong_en), .pong_we(w_ofm_pong_we), .pong_addr(w_ofm_pong_addr), .pong_wdata(w_ofm_pong_wdata)
    );

    // =========================================================
    // 4. MUXING TÍN HIỆU PORT B CHO PING / PONG BANK
    // =========================================================
    assign w_ping_en_b    = w_ifm_ping_en | w_ofm_ping_en;
    assign w_ping_we_b    = w_ofm_ping_we;
    assign w_ping_addr_b  = w_ifm_ping_en ? w_ifm_ping_addr : w_ofm_ping_addr;
    assign w_ping_wdata_b = w_ofm_ping_wdata;

    assign w_pong_en_b    = w_ifm_pong_en | w_ofm_pong_en;
    assign w_pong_we_b    = w_ofm_pong_we;
    assign w_pong_addr_b  = w_ifm_pong_en ? w_ifm_pong_addr : w_ofm_pong_addr;
    assign w_pong_wdata_b = w_ofm_pong_wdata;

    // =========================================================
    // 5. SRAM BANKS
    // =========================================================
    assign w_wgt_rdata_a = '0; // DMA không đọc từ Wgt Bank

    sram_tdp #(
        .DWIDTH(SRAM_DWIDTH), .AWIDTH(SRAM_AWIDTH)
    ) u_ping_bank (
        .clk(clk),
        .ena(1'b1), .wea(w_ping_we_a), .addra(w_ping_addr_a), .dina(w_ping_wdata_a), .douta(w_ping_rdata_a),
        .enb(w_ping_en_b), .web(w_ping_we_b), .addrb(w_ping_addr_b), .dinb(w_ping_wdata_b), .doutb(w_ping_rdata_b)
    );

    sram_tdp #(
        .DWIDTH(SRAM_DWIDTH), .AWIDTH(SRAM_AWIDTH)
    ) u_pong_bank (
        .clk(clk),
        .ena(1'b1), .wea(w_pong_we_a), .addra(w_pong_addr_a), .dina(w_pong_wdata_a), .douta(w_pong_rdata_a),
        .enb(w_pong_en_b), .web(w_pong_we_b), .addrb(w_pong_addr_b), .dinb(w_pong_wdata_b), .doutb(w_pong_rdata_b)
    );

    sram_tdp #(
        .DWIDTH(SRAM_DWIDTH), .AWIDTH(SRAM_AWIDTH)
    ) u_wgt_bank (
        .clk(clk),
        .ena(1'b1), .wea(w_wgt_we_a), .addra(w_wgt_addr_a), .dina(w_wgt_wdata_a), .douta(),
        .enb(w_pea_wgt_re), .web(1'b0), .addrb(w_pea_wgt_addr[SRAM_AWIDTH-1:0]), .dinb('0), .doutb(w_pea_wgt_rdata)
    );

    // =========================================================
    // 6. PROCESSING ELEMENT ARRAY (PEA)
    // =========================================================
    // Route AXI-Lite writes to PEA config if address is in 0x100 - 0x3FF
    logic slv_reg_wren;
    logic w_pea_cfg_we;
    
    assign slv_reg_wren = s_axi_wvalid && s_axi_awvalid;
    // Chỉ kích hoạt khi có xung Write và địa chỉ nằm trong dải 0x100 - 0x3FF
    assign w_pea_cfg_we = slv_reg_wren && (s_axi_awaddr >= 32'h0000_0100) && (s_axi_awaddr < 32'h0000_0600);

    pea_top #(
        .DATA_WIDTH(8),
        .PSUM_WIDTH(32),
        .ADDR_WIDTH(16) // Khớp với ADDR_WIDTH nội bộ của khối PEA
    ) u_pea_top (
        .clk(clk),
        .rst_n(rst_n),
        
        .ctrl_start(ctrl_mac_start),
        .ctrl_done(ctrl_mac_done),
        
        // Config interface mapped to AXI-Lite
        .cfg_addr(s_axi_awaddr[15:0]),
        .cfg_data(s_axi_wdata),
        .cfg_we(w_pea_cfg_we),
        
        // Memory interfaces
        .wb_read_addr(w_pea_wgt_addr),
        .wb_re(w_pea_wgt_re),
        .wb_read_data(w_pea_wgt_rdata),
        
        .ifm_read_addr(w_pea_ifm_addr),
        .ifm_re(w_pea_ifm_re),
        .ifm_read_data(w_pea_ifm_rdata),
        
        .ofm_write_addr(w_pea_ofm_addr),
        .ofm_we(w_pea_ofm_we),
        .ofm_write_data(w_pea_ofm_wdata)
    );

    // Pool done hardcoded to 1 for now (if Pool is not integrated)
    assign ctrl_pool_done = 1'b1;

endmodule
