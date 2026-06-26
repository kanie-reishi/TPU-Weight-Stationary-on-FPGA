
`timescale 1 ns / 1 ps

module TPU16x16 #(
	// AXI4-Lite slave (PS -> TPU control)
	parameter integer C_S00_AXI_DATA_WIDTH = 32,
	parameter integer C_S00_AXI_ADDR_WIDTH = 12,

	// TPU internal parameters
	parameter integer C_TPU_AXI_AWIDTH     = 40,
	parameter integer C_TPU_AXI_DWIDTH     = 64,
	parameter integer C_TPU_SRAM_DWIDTH    = 128,
	parameter integer C_TPU_SRAM_AWIDTH    = 11
)(
	// AXI4-Lite slave
	input  wire                              s00_axi_aclk,
	input  wire                              s00_axi_aresetn,
	input  wire [C_S00_AXI_ADDR_WIDTH-1:0]   s00_axi_awaddr,
	input  wire [2:0]                        s00_axi_awprot,
	input  wire                              s00_axi_awvalid,
	output wire                              s00_axi_awready,
	input  wire [C_S00_AXI_DATA_WIDTH-1:0]   s00_axi_wdata,
	input  wire [(C_S00_AXI_DATA_WIDTH/8)-1:0] s00_axi_wstrb,
	input  wire                              s00_axi_wvalid,
	output wire                              s00_axi_wready,
	output wire [1:0]                        s00_axi_bresp,
	output wire                              s00_axi_bvalid,
	input  wire                              s00_axi_bready,
	input  wire [C_S00_AXI_ADDR_WIDTH-1:0]   s00_axi_araddr,
	input  wire [2:0]                        s00_axi_arprot,
	input  wire                              s00_axi_arvalid,
	output wire                              s00_axi_arready,
	output wire [C_S00_AXI_DATA_WIDTH-1:0]   s00_axi_rdata,
	output wire [1:0]                        s00_axi_rresp,
	output wire                              s00_axi_rvalid,
	input  wire                              s00_axi_rready,

	// AXI4-Full master (TPU -> DDR)
	output wire [C_TPU_AXI_AWIDTH-1:0]       m00_axi_araddr,
	output wire [7:0]                        m00_axi_arlen,
	output wire [2:0]                        m00_axi_arsize,
	output wire [1:0]                        m00_axi_arburst,
	output wire                              m00_axi_arvalid,
	input  wire                              m00_axi_arready,
	input  wire [C_TPU_AXI_DWIDTH-1:0]       m00_axi_rdata,
	input  wire                              m00_axi_rlast,
	input  wire                              m00_axi_rvalid,
	output wire                              m00_axi_rready,
	output wire [C_TPU_AXI_AWIDTH-1:0]       m00_axi_awaddr,
	output wire [7:0]                        m00_axi_awlen,
	output wire [2:0]                        m00_axi_awsize,
	output wire [1:0]                        m00_axi_awburst,
	output wire                              m00_axi_awvalid,
	input  wire                              m00_axi_awready,
	output wire [C_TPU_AXI_DWIDTH-1:0]       m00_axi_wdata,
	output wire                              m00_axi_wlast,
	output wire                              m00_axi_wvalid,
	input  wire                              m00_axi_wready,
	input  wire [1:0]                        m00_axi_bresp,
	input  wire                              m00_axi_bvalid,
	output wire                              m00_axi_bready,

	// Interrupt to PS
	output wire                              finish_irq_o
);

	// Wrapper <-> TPU internal AXI-Lite
	wire [C_S00_AXI_ADDR_WIDTH-1:0]          w_axi_awaddr;
	wire                                     w_axi_awvalid;
	wire                                     w_axi_awready;
	wire [C_S00_AXI_DATA_WIDTH-1:0]        w_axi_wdata;
	wire [(C_S00_AXI_DATA_WIDTH/8)-1:0]    w_axi_wstrb;
	wire                                     w_axi_wvalid;
	wire                                     w_axi_wready;
	wire [1:0]                               w_axi_bresp;
	wire                                     w_axi_bvalid;
	wire                                     w_axi_bready;
	wire [C_S00_AXI_ADDR_WIDTH-1:0]        w_axi_araddr;
	wire                                     w_axi_arvalid;
	wire                                     w_axi_arready;
	wire [C_S00_AXI_DATA_WIDTH-1:0]        w_axi_rdata;
	wire [1:0]                               w_axi_rresp;
	wire                                     w_axi_rvalid;
	wire                                     w_axi_rready;

	// Zero-extend IP address to 32-bit TPU register map
	wire [31:0] w_tpu_awaddr = {{(32-C_S00_AXI_ADDR_WIDTH){1'b0}}, w_axi_awaddr};
	wire [31:0] w_tpu_araddr = {{(32-C_S00_AXI_ADDR_WIDTH){1'b0}}, w_axi_araddr};

	TPU16x16_slave_lite_v1_0_S00_AXI #(
		.C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
		.C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)
	) u_axi_slave (
		.user_axi_awaddr  (w_axi_awaddr),
		.user_axi_awvalid (w_axi_awvalid),
		.user_axi_awready (w_axi_awready),
		.user_axi_wdata   (w_axi_wdata),
		.user_axi_wstrb   (w_axi_wstrb),
		.user_axi_wvalid  (w_axi_wvalid),
		.user_axi_wready  (w_axi_wready),
		.user_axi_bresp   (w_axi_bresp),
		.user_axi_bvalid  (w_axi_bvalid),
		.user_axi_bready  (w_axi_bready),
		.user_axi_araddr  (w_axi_araddr),
		.user_axi_arvalid (w_axi_arvalid),
		.user_axi_arready (w_axi_arready),
		.user_axi_rdata   (w_axi_rdata),
		.user_axi_rresp   (w_axi_rresp),
		.user_axi_rvalid  (w_axi_rvalid),
		.user_axi_rready  (w_axi_rready),
		.S_AXI_ACLK       (s00_axi_aclk),
		.S_AXI_ARESETN    (s00_axi_aresetn),
		.S_AXI_AWADDR     (s00_axi_awaddr),
		.S_AXI_AWPROT     (s00_axi_awprot),
		.S_AXI_AWVALID    (s00_axi_awvalid),
		.S_AXI_AWREADY    (s00_axi_awready),
		.S_AXI_WDATA      (s00_axi_wdata),
		.S_AXI_WSTRB      (s00_axi_wstrb),
		.S_AXI_WVALID     (s00_axi_wvalid),
		.S_AXI_WREADY     (s00_axi_wready),
		.S_AXI_BRESP      (s00_axi_bresp),
		.S_AXI_BVALID     (s00_axi_bvalid),
		.S_AXI_BREADY     (s00_axi_bready),
		.S_AXI_ARADDR     (s00_axi_araddr),
		.S_AXI_ARPROT     (s00_axi_arprot),
		.S_AXI_ARVALID    (s00_axi_arvalid),
		.S_AXI_ARREADY    (s00_axi_arready),
		.S_AXI_RDATA      (s00_axi_rdata),
		.S_AXI_RRESP      (s00_axi_rresp),
		.S_AXI_RVALID     (s00_axi_rvalid),
		.S_AXI_RREADY     (s00_axi_rready)
	);

	tensor_processing_unit_top #(
		.AXI_AWIDTH (C_TPU_AXI_AWIDTH),
		.AXI_DWIDTH (C_TPU_AXI_DWIDTH),
		.SRAM_DWIDTH(C_TPU_SRAM_DWIDTH),
		.SRAM_AWIDTH(C_TPU_SRAM_AWIDTH)
	) u_tpu_top (
		.clk            (s00_axi_aclk),
		.rst_n          (s00_axi_aresetn),
		.s_axi_awvalid  (w_axi_awvalid),
		.s_axi_awready  (w_axi_awready),
		.s_axi_awaddr   (w_tpu_awaddr),
		.s_axi_wvalid   (w_axi_wvalid),
		.s_axi_wready   (w_axi_wready),
		.s_axi_wdata    (w_axi_wdata),
		.s_axi_arvalid  (w_axi_arvalid),
		.s_axi_arready  (w_axi_arready),
		.s_axi_araddr   (w_tpu_araddr),
		.s_axi_rvalid   (w_axi_rvalid),
		.s_axi_rready   (w_axi_rready),
		.s_axi_rdata    (w_axi_rdata),
		.s_axi_rresp    (w_axi_rresp),
		.s_axi_bready   (w_axi_bready),
		.s_axi_bvalid   (w_axi_bvalid),
		.s_axi_bresp    (w_axi_bresp),
		.m_axi_araddr   (m00_axi_araddr),
		.m_axi_arlen    (m00_axi_arlen),
		.m_axi_arsize   (m00_axi_arsize),
		.m_axi_arburst  (m00_axi_arburst),
		.m_axi_arvalid  (m00_axi_arvalid),
		.m_axi_arready  (m00_axi_arready),
		.m_axi_rdata    (m00_axi_rdata),
		.m_axi_rlast    (m00_axi_rlast),
		.m_axi_rvalid   (m00_axi_rvalid),
		.m_axi_rready   (m00_axi_rready),
		.m_axi_awaddr   (m00_axi_awaddr),
		.m_axi_awlen    (m00_axi_awlen),
		.m_axi_awsize   (m00_axi_awsize),
		.m_axi_awburst  (m00_axi_awburst),
		.m_axi_awvalid  (m00_axi_awvalid),
		.m_axi_awready  (m00_axi_awready),
		.m_axi_wdata    (m00_axi_wdata),
		.m_axi_wlast    (m00_axi_wlast),
		.m_axi_wvalid   (m00_axi_wvalid),
		.m_axi_wready   (m00_axi_wready),
		.m_axi_bresp    (m00_axi_bresp),
		.m_axi_bvalid   (m00_axi_bvalid),
		.m_axi_bready   (m00_axi_bready),
		.finish_irq_o   (finish_irq_o)
	);

endmodule
