
`timescale 1 ns / 1 ps

// AXI4-Lite slave shell: forwards all channels to user logic (TPU).
// Register decode and handshaking are handled inside tensor_processing_unit_top.
module TPU16x16_slave_lite_v1_0_S00_AXI #(
	parameter integer C_S_AXI_DATA_WIDTH = 32,
	parameter integer C_S_AXI_ADDR_WIDTH = 12
)(
	// User logic AXI-Lite slave (connect to TPU)
	output wire [C_S_AXI_ADDR_WIDTH-1:0]     user_axi_awaddr,
	output wire                              user_axi_awvalid,
	input  wire                              user_axi_awready,
	output wire [C_S_AXI_DATA_WIDTH-1:0]     user_axi_wdata,
	output wire [(C_S_AXI_DATA_WIDTH/8)-1:0] user_axi_wstrb,
	output wire                              user_axi_wvalid,
	input  wire                              user_axi_wready,
	input  wire [1:0]                        user_axi_bresp,
	input  wire                              user_axi_bvalid,
	output wire                              user_axi_bready,
	output wire [C_S_AXI_ADDR_WIDTH-1:0]     user_axi_araddr,
	output wire                              user_axi_arvalid,
	input  wire                              user_axi_arready,
	input  wire [C_S_AXI_DATA_WIDTH-1:0]     user_axi_rdata,
	input  wire [1:0]                        user_axi_rresp,
	input  wire                              user_axi_rvalid,
	output wire                              user_axi_rready,

	// PS-facing AXI4-Lite slave
	input  wire                              S_AXI_ACLK,
	input  wire                              S_AXI_ARESETN,
	input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_AWADDR,
	input  wire [2:0]                        S_AXI_AWPROT,
	input  wire                              S_AXI_AWVALID,
	output wire                              S_AXI_AWREADY,
	input  wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_WDATA,
	input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB,
	input  wire                              S_AXI_WVALID,
	output wire                              S_AXI_WREADY,
	output wire [1:0]                        S_AXI_BRESP,
	output wire                              S_AXI_BVALID,
	input  wire                              S_AXI_BREADY,
	input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_ARADDR,
	input  wire [2:0]                        S_AXI_ARPROT,
	input  wire                              S_AXI_ARVALID,
	output wire                              S_AXI_ARREADY,
	output wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_RDATA,
	output wire [1:0]                        S_AXI_RRESP,
	output wire                              S_AXI_RVALID,
	input  wire                              S_AXI_RREADY
);

	// Write address channel
	assign user_axi_awaddr  = S_AXI_AWADDR;
	assign user_axi_awvalid = S_AXI_AWVALID;
	assign S_AXI_AWREADY    = user_axi_awready;

	// Write data channel
	assign user_axi_wdata  = S_AXI_WDATA;
	assign user_axi_wstrb  = S_AXI_WSTRB;
	assign user_axi_wvalid = S_AXI_WVALID;
	assign S_AXI_WREADY    = user_axi_wready;

	// Write response channel
	assign S_AXI_BRESP   = user_axi_bresp;
	assign S_AXI_BVALID  = user_axi_bvalid;
	assign user_axi_bready = S_AXI_BREADY;

	// Read address channel
	assign user_axi_araddr  = S_AXI_ARADDR;
	assign user_axi_arvalid = S_AXI_ARVALID;
	assign S_AXI_ARREADY    = user_axi_arready;

	// Read data channel
	assign S_AXI_RDATA   = user_axi_rdata;
	assign S_AXI_RRESP   = user_axi_rresp;
	assign S_AXI_RVALID  = user_axi_rvalid;
	assign user_axi_rready = S_AXI_RREADY;

endmodule