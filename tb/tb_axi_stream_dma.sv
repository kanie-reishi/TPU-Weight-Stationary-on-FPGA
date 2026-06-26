`timescale 1ns / 1ps

module tb_axi_stream_dma();

    // Parameters
    parameter AXI_AWIDTH  = 40;
    parameter AXI_DWIDTH  = 64;
    parameter SRAM_DWIDTH = 128;
    parameter SRAM_AWIDTH = 11;

    // Clock and Reset
    logic clk;
    logic rst_n;

    // AXI-Lite Slave
    logic                    s_axi_awvalid;
    logic                    s_axi_awready;
    logic [31:0]             s_axi_awaddr;
    logic                    s_axi_wvalid;
    logic                    s_axi_wready;
    logic [31:0]             s_axi_wdata;

    logic                   s_axi_arvalid;
    logic                   s_axi_arready;
    logic [31:0]            s_axi_araddr;
    logic                   s_axi_rvalid;
    logic                   s_axi_rready;
    logic [31:0]            s_axi_rdata;
    logic [1:0]             s_axi_rresp;
    
    logic                    s_axi_bready;
    logic                    s_axi_bvalid;
    logic [1:0]              s_axi_bresp;

    // AXI Stream S_AXIS
    logic                    s_axis_tvalid;
    logic                    s_axis_tready;
    logic [127:0]            s_axis_tdata;
    logic                    s_axis_tlast;
    logic [3:0]              s_axis_tdest;

    // AXI Stream M_AXIS
    logic                    m_axis_tvalid;
    logic                    m_axis_tready;
    logic [127:0]            m_axis_tdata;
    logic                    m_axis_tlast;

    // IRQ
    logic                    finish_irq_o;

    // DUT
    tensor_processing_unit_top #(
        .AXI_AWIDTH(AXI_AWIDTH),
        .AXI_DWIDTH(AXI_DWIDTH),
        .SRAM_DWIDTH(SRAM_DWIDTH),
        .SRAM_AWIDTH(SRAM_AWIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_wdata(s_axi_wdata),
        
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        
        .s_axi_bready(s_axi_bready),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bresp(s_axi_bresp),

        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tdest(s_axis_tdest),

        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tlast(m_axis_tlast),

        .finish_irq_o(finish_irq_o)
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Task to write AXI-Lite
    task axi_lite_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            s_axi_awvalid <= 1;
            s_axi_awaddr  <= addr;
            s_axi_wvalid  <= 1;
            s_axi_wdata   <= data;
            
            wait (s_axi_awready && s_axi_wready);
            @(posedge clk);
            s_axi_awvalid <= 0;
            s_axi_wvalid  <= 0;
            
            s_axi_bready  <= 1;
            wait (s_axi_bvalid);
            @(posedge clk);
            s_axi_bready  <= 0;
        end
    endtask

    // Task to stream data (S_AXIS)
    task axis_write_burst(input [3:0] tdest, input int length);
        begin
            for (int i = 0; i < length; i++) begin
                @(posedge clk);
                s_axis_tvalid <= 1;
                s_axis_tdata  <= {32'h0, 32'hAABBCCDD, 32'h11223344, i[31:0]};
                s_axis_tdest  <= tdest;
                s_axis_tlast  <= (i == length - 1) ? 1 : 0;
                
                wait (s_axis_tready);
            end
            @(posedge clk);
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
        end
    endtask

    // Test Sequence
    initial begin
        // Initialize signals
        rst_n = 0;
        s_axi_awvalid = 0;
        s_axi_awaddr = 0;
        s_axi_wvalid = 0;
        s_axi_wdata = 0;
        s_axi_arvalid = 0;
        s_axi_araddr = 0;
        s_axi_rready = 0;
        s_axi_bready = 0;
        
        s_axis_tvalid = 0;
        s_axis_tdata = 0;
        s_axis_tlast = 0;
        s_axis_tdest = 0;
        m_axis_tready = 1; // Always ready to receive

        // Reset
        #100;
        @(posedge clk);
        rst_n = 1;
        #20;

        // 1. Write Instructions (TDEST=0)
        $display("Writing Instructions to TDEST=0");
        axis_write_burst(4'd0, 4);

        // 2. Write Weights (TDEST=1)
        $display("Writing Weights to TDEST=1");
        axis_write_burst(4'd1, 8);

        // 3. Write Ping Bank (TDEST=2)
        $display("Writing Ping Bank to TDEST=2");
        axis_write_burst(4'd2, 8);

        // 4. Write Pong Bank (TDEST=3)
        $display("Writing Pong Bank to TDEST=3");
        axis_write_burst(4'd3, 8);

        // 5. Read back from Ping Bank via M_AXIS
        $display("Reading Ping Bank via M_AXIS");
        axi_lite_write(32'h0000_0020, 32'h0); // Source = Ping (0)
        axi_lite_write(32'h0000_0024, 32'h8); // Length = 8
        axi_lite_write(32'h0000_0028, 32'h1); // Start = 1

        wait (m_axis_tvalid && m_axis_tlast);
        @(posedge clk);
        
        // 6. Read back from Pong Bank via M_AXIS
        $display("Reading Pong Bank via M_AXIS");
        axi_lite_write(32'h0000_0020, 32'h1); // Source = Pong (1)
        axi_lite_write(32'h0000_0024, 32'h8); // Length = 8
        axi_lite_write(32'h0000_0028, 32'h1); // Start = 1

        wait (m_axis_tvalid && m_axis_tlast);
        @(posedge clk);

        #100;
        $display("Simulation Finished");
        $finish;
    end

endmodule
