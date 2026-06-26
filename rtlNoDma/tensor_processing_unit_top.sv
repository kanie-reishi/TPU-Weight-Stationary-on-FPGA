`timescale 1ns / 1ps

module tensor_processing_unit_top #(
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
    // 2. GIAO DIỆN AXI STREAM SLAVE & MASTER (DMA <-> FPGA)
    // =========================================================
    // S_AXIS
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    input  logic [127:0]            s_axis_tdata,
    input  logic                    s_axis_tlast,
    input  logic [3:0]              s_axis_tdest,

    // M_AXIS
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic [127:0]            m_axis_tdata,
    output logic                    m_axis_tlast,

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

    // SRAM Port A 
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
    logic        w_engine_busy;
    logic        w_m_axis_busy;

    // =========================================================
    // 1. GLOBAL ARBITER (AXI)
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
        
        // AXI Stream
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tdata(s_axis_tdata),   .s_axis_tlast(s_axis_tlast),
        .s_axis_tdest(s_axis_tdest),
        
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .m_axis_tdata(m_axis_tdata),   .m_axis_tlast(m_axis_tlast),

        .engine_busy_i(w_engine_busy),
        .src_bank_i(w_src_bank),
        .dst_bank_i(w_dst_bank),
        .m_axis_busy_o(w_m_axis_busy),

        // Instruction FIFO
        .ctrl_inst_data_o(w_inst_data), .ctrl_inst_empty_o(w_inst_empty), .ctrl_inst_read_i(w_inst_read),
        // SRAM Port A
        .wgt_we_o(w_wgt_we_a),   .wgt_addr_o(w_wgt_addr_a),   .wgt_wdata_o(w_wgt_wdata_a),
        .ping_we_o(w_ping_we_a), .ping_addr_o(w_ping_addr_a), .ping_wdata_o(w_ping_wdata_a), .ping_rdata_i(w_ping_rdata_a),
        .pong_we_o(w_pong_we_a), .pong_addr_o(w_pong_addr_a), .pong_wdata_o(w_pong_wdata_a), .pong_rdata_i(w_pong_rdata_a)
    );

    // =========================================================
    // LOGIC ĐIỀU KHIỂN AXI-LITE READ / WRITE RESPONSE
    // =========================================================
    logic axi_arready_reg, axi_rvalid_reg;
    logic [31:0] axi_araddr_reg;
    logic [31:0] axi_rdata_reg;
    logic        axi_bvalid_reg;

    assign s_axi_arready = axi_arready_reg;
    assign s_axi_rvalid  = axi_rvalid_reg;
    assign s_axi_rdata   = axi_rdata_reg;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_bvalid  = axi_bvalid_reg;
    assign s_axi_bresp   = 2'b00;

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
                
                if (axi_araddr_reg >= 32'h0000_0100) begin
                    axi_rdata_reg <= 32'hDEADBEEF;
                end else begin
                    unique case (axi_araddr_reg[11:0])
                        12'h000: axi_rdata_reg <= {31'd0, ctrl_mac_done};
                        12'h004: axi_rdata_reg <= {31'd0, finish_irq_o};
                        12'h008: axi_rdata_reg <= 32'hDEADBEEF;
                        12'h02C: axi_rdata_reg <= {31'd0, w_m_axis_busy};
                        12'h02D: axi_rdata_reg <= {30'd0, w_src_bank};
                        12'h02E: axi_rdata_reg <= {30'd0, w_dst_bank};
                        default: axi_rdata_reg <= 32'hDEADBEEF;
                    endcase
                end
            end else if (axi_rvalid_reg && s_axi_rready) begin
                // CPU đã nhận được dữ liệu, tắt cờ valid
                axi_rvalid_reg <= 1'b0;
            end
        end
    end

    // 4. Write response (B channel)
    logic write_accept;
    assign write_accept = s_axi_awvalid && s_axi_wvalid && s_axi_awready && s_axi_wready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_bvalid_reg <= 1'b0;
        end else begin
            if (write_accept)
                axi_bvalid_reg <= 1'b1;
            else if (axi_bvalid_reg && s_axi_bready)
                axi_bvalid_reg <= 1'b0;
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
        .mac_start_o(ctrl_mac_start), .mac_done_i(ctrl_mac_done),
        .pool_start_o(ctrl_pool_start), .pool_done_i(ctrl_pool_done),
        .src_bank_o(w_src_bank), .dst_bank_o(w_dst_bank),
        .ifm_w_o(w_ifm_w), .ifm_h_o(w_ifm_h), .ifm_c_o(w_ifm_c), .ofm_c_o(w_ofm_c),
        .knl_size_o(w_knl_size), .stride_o(w_stride), .shift_amt_o(w_shift_amt),
        .relu_en_o(w_relu_en), .pool_type_o(w_pool_type),
        .engine_busy_o(w_engine_busy),
        .finish_irq_o(finish_irq_o)
    );

    // =========================================================
    // 3. IFM / OFM ARBITERS
    // =========================================================
    logic w_bank_sel_bit;
    assign w_bank_sel_bit = (w_src_bank == 2'b10) ? 1'b1 : 1'b0; // 0=Ping, 1=Pong

    logic pool_busy;
    logic [SRAM_AWIDTH-1:0] w_pool_ifm_addr, w_pool_ofm_addr;
    logic                   w_pool_ifm_re, w_pool_ofm_we;
    logic [SRAM_DWIDTH-1:0] w_pool_ifm_rdata, w_pool_ofm_wdata;

    logic [SRAM_AWIDTH-1:0] w_mux_ifm_addr;
    logic                   w_mux_ifm_re;
    
    assign w_mux_ifm_addr = pool_busy ? w_pool_ifm_addr : w_pea_ifm_addr[SRAM_AWIDTH-1:0];
    assign w_mux_ifm_re   = pool_busy ? w_pool_ifm_re   : w_pea_ifm_re;
    assign w_pool_ifm_rdata = w_pea_ifm_rdata; // Shared read data bus

    ifm_arbiter #(
        .ADDR_WIDTH(SRAM_AWIDTH),
        .DATA_WIDTH(SRAM_DWIDTH)
    ) u_ifm_arbiter (
        .bank_sel(w_bank_sel_bit),
        .pea_ifm_addr(w_mux_ifm_addr), .pea_ifm_re(w_mux_ifm_re), .pea_ifm_rdata(w_pea_ifm_rdata),
        .ping_en(w_ifm_ping_en), .ping_addr(w_ifm_ping_addr), .ping_rdata(w_ping_rdata_b),
        .pong_en(w_ifm_pong_en), .pong_addr(w_ifm_pong_addr), .pong_rdata(w_pong_rdata_b)
    );

    logic [SRAM_AWIDTH-1:0] w_mux_ofm_addr;
    logic                   w_mux_ofm_we;
    logic [SRAM_DWIDTH-1:0] w_mux_ofm_wdata;
    
    assign w_mux_ofm_addr  = pool_busy ? w_pool_ofm_addr  : w_pea_ofm_addr[SRAM_AWIDTH-1:0];
    assign w_mux_ofm_we    = pool_busy ? w_pool_ofm_we    : w_pea_ofm_we;
    assign w_mux_ofm_wdata = pool_busy ? w_pool_ofm_wdata : w_pea_ofm_wdata;

    ofm_arbiter #(
        .ADDR_WIDTH(SRAM_AWIDTH),
        .DATA_WIDTH(SRAM_DWIDTH)
    ) u_ofm_arbiter (
        .bank_sel(w_bank_sel_bit),
        .pea_ofm_addr(w_mux_ofm_addr), .pea_ofm_we(w_mux_ofm_we), .pea_ofm_wdata(w_mux_ofm_wdata),
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
    assign w_wgt_rdata_a = '0;

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
    logic w_pea_cfg_we;

    assign w_pea_cfg_we = write_accept
                       && (s_axi_awaddr >= 32'h0000_0100)
                       && (s_axi_awaddr < 32'h0000_0600);

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

    // =========================================================
    // 7. POOLING ENGINE
    // =========================================================
    pool_engine #(
        .SRAM_AWIDTH(SRAM_AWIDTH),
        .SRAM_DWIDTH(SRAM_DWIDTH)
    ) u_pool_engine (
        .clk(clk),
        .rst_n(rst_n),
        .ctrl_pool_start(ctrl_pool_start),
        .ctrl_pool_done(ctrl_pool_done),
        .pool_busy_o(pool_busy),
        .w_ifm_w(w_ifm_w),
        .w_ifm_h(w_ifm_h),
        .w_ifm_c(w_ifm_c),
        .pool_ifm_addr(w_pool_ifm_addr),
        .pool_ifm_re(w_pool_ifm_re),
        .pool_ifm_rdata(w_pool_ifm_rdata),
        .pool_ofm_addr(w_pool_ofm_addr),
        .pool_ofm_we(w_pool_ofm_we),
        .pool_ofm_wdata(w_pool_ofm_wdata)
    );

endmodule
