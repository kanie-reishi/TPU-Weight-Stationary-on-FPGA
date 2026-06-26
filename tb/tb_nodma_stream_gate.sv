`timescale 1ns / 1ps

// Tests S_AXIS backpressure when engine_busy blocks ping/pong Port B banks.
module tb_nodma_stream_gate();

    parameter AXI_AWIDTH  = 40;
    parameter AXI_DWIDTH  = 64;
    parameter SRAM_DWIDTH = 128;
    parameter SRAM_AWIDTH = 11;

    logic clk;
    logic rst_n;

    logic                    s_axi_awvalid, s_axi_awready;
    logic [31:0]             s_axi_awaddr;
    logic                    s_axi_wvalid, s_axi_wready;
    logic [31:0]             s_axi_wdata;
    logic                    s_axi_arvalid, s_axi_arready;
    logic [31:0]             s_axi_araddr;
    logic                    s_axi_rvalid, s_axi_rready;
    logic [31:0]             s_axi_rdata;
    logic [1:0]              s_axi_rresp;
    logic                    s_axi_bready, s_axi_bvalid;
    logic [1:0]              s_axi_bresp;

    logic                    s_axis_tvalid, s_axis_tready;
    logic [127:0]            s_axis_tdata;
    logic                    s_axis_tlast;
    logic [3:0]              s_axis_tdest;

    logic                    m_axis_tvalid, m_axis_tready;
    logic [127:0]            m_axis_tdata;
    logic                    m_axis_tlast;

    logic                    finish_irq_o;

    tensor_processing_unit_top #(
        .AXI_AWIDTH(AXI_AWIDTH),
        .AXI_DWIDTH(AXI_DWIDTH),
        .SRAM_DWIDTH(SRAM_DWIDTH),
        .SRAM_AWIDTH(SRAM_AWIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr),   .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),   .s_axi_wdata(s_axi_wdata),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_araddr(s_axi_araddr),   .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),   .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_bready(s_axi_bready),   .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bresp(s_axi_bresp),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tdata(s_axis_tdata),   .s_axis_tlast(s_axis_tlast),
        .s_axis_tdest(s_axis_tdest),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .m_axis_tdata(m_axis_tdata),   .m_axis_tlast(m_axis_tlast),
        .finish_irq_o(finish_irq_o)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    task axis_push_inst(input [63:0] inst);
        begin
            @(posedge clk);
            s_axis_tvalid <= 1;
            s_axis_tdata  <= {64'b0, inst};
            s_axis_tdest  <= 4'd0;
            s_axis_tlast  <= 1'b1;
            wait (s_axis_tready);
            @(posedge clk);
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
        end
    endtask

    // Sample tready on the first valid cycle only
    task axis_probe_tready(input [3:0] tdest, output logic ready);
        begin
            @(posedge clk);
            s_axis_tvalid <= 1;
            s_axis_tdata  <= 128'hCAFE;
            s_axis_tdest  <= tdest;
            s_axis_tlast  <= 1'b1;
            @(posedge clk);
            ready = s_axis_tready;
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
        end
    endtask

    initial begin
        logic ready_ping, ready_pong, ready_wgt, ready_bad;

        rst_n = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_arvalid = 0;
        s_axi_rready = 0; s_axi_bready = 0;
        s_axis_tvalid = 0; s_axis_tdata = 0; s_axis_tlast = 0; s_axis_tdest = 0;
        m_axis_tready = 1;

        #100;
        @(posedge clk);
        rst_n = 1;
        #20;

        $display("Issuing OP_RUN_MAC to enter engine_busy");
        axis_push_inst(64'h5000_0000_0000_0000);

        repeat (3) @(posedge clk);

        if (!dut.w_engine_busy)
            $error("Expected engine_busy after OP_RUN_MAC");
        else
            $display("engine_busy asserted");

        axis_probe_tready(4'd2, ready_ping);
        axis_probe_tready(4'd3, ready_pong);
        axis_probe_tready(4'd1, ready_wgt);
        axis_probe_tready(4'd9, ready_bad);

        if (ready_ping)
            $error("TDEST=2 (ping) should stall while engine_busy");
        else
            $display("TDEST=2 correctly stalled");

        if (ready_pong)
            $error("TDEST=3 (pong) should stall while engine_busy (dst bank)");
        else
            $display("TDEST=3 correctly stalled");

        if (!ready_wgt)
            $error("TDEST=1 (weights) should still accept while engine_busy");
        else
            $display("TDEST=1 still accepts (weight bank not gated)");

        if (ready_bad)
            $error("Reserved TDEST should not handshake");
        else
            $display("Reserved TDEST correctly rejected");

        $display("Stream gate tests PASS");
        $finish;
    end

endmodule
