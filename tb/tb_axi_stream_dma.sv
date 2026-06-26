`timescale 1ns / 1ps

// Testbench for rtlNoDma/tensor_processing_unit_top (AXI-Stream DMA path).
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

    // Task to read AXI-Lite
    task axi_lite_read(input [31:0] addr, output logic [31:0] data);
        begin
            @(posedge clk);
            s_axi_arvalid <= 1;
            s_axi_araddr  <= addr;
            s_axi_rready  <= 1;
            wait (s_axi_rvalid);
            data = s_axi_rdata;
            @(posedge clk);
            s_axi_arvalid <= 0;
            s_axi_rready  <= 0;
        end
    endtask

    // Single-beat S_AXIS write attempt; returns whether handshake occurred
    task axis_write_one(
        input  [3:0]        tdest,
        input  logic [127:0] tdata,
        input  logic        tlast,
        output logic        handed
    );
        int timeout;
        begin
            handed  = 0;
            timeout = 0;
            @(posedge clk);
            s_axis_tvalid <= 1;
            s_axis_tdata  <= tdata;
            s_axis_tdest  <= tdest;
            s_axis_tlast  <= tlast;

            while (!s_axis_tready && timeout < 20) begin
                @(posedge clk);
                timeout++;
            end
            handed = s_axis_tready;
            @(posedge clk);
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
        end
    endtask

    // Push one 64-bit instruction via S_AXIS TDEST=0
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

    function automatic logic [127:0] axis_expected_beat(
        input int i,
        input logic [31:0] tag_hi,
        input logic [31:0] tag_lo
    );
        axis_expected_beat = {32'h0, tag_hi, tag_lo, i[31:0]};
    endfunction

    // Task to stream data (S_AXIS)
    task axis_write_burst(
        input [3:0]        tdest,
        input int          length,
        input logic [31:0] tag_hi = 32'hAABBCCDD,
        input logic [31:0] tag_lo = 32'h11223344
    );
        begin
            for (int i = 0; i < length; i++) begin
                @(posedge clk);
                s_axis_tvalid <= 1;
                s_axis_tdata  <= axis_expected_beat(i, tag_hi, tag_lo);
                s_axis_tdest  <= tdest;
                s_axis_tlast  <= (i == length - 1) ? 1 : 0;

                wait (s_axis_tready);
            end
            @(posedge clk);
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
        end
    endtask

    // Configure and pulse M_AXIS read (global_arbiter regs 0x20/0x24/0x28)
    task m_axis_read_start(input [1:0] bank_sel, input int length);
        begin
            axi_lite_write(32'h0000_0020, {30'b0, bank_sel});
            axi_lite_write(32'h0000_0024, length[31:0]);
            axi_lite_write(32'h0000_0028, 32'h1);
        end
    endtask

    // Capture every M_AXIS beat on handshake and compare against expected SRAM contents
    task axis_read_and_check(
        input int          length,
        input logic [31:0] tag_hi,
        input logic [31:0] tag_lo,
        input string       bank_name
    );
        logic [127:0] expected;
        int           beat;
        int           errors;

        errors = 0;
        beat   = 0;
        while (beat < length) begin
            @(posedge clk);
            if (m_axis_tvalid && m_axis_tready) begin
                expected = axis_expected_beat(beat, tag_hi, tag_lo);
                if (m_axis_tdata !== expected) begin
                    $error("[%s] beat %0d: got %h, expected %h",
                           bank_name, beat, m_axis_tdata, expected);
                    errors++;
                end else begin
                    $display("[%s] beat %0d OK: %h", bank_name, beat, m_axis_tdata);
                end

                if (beat == length - 1) begin
                    if (!m_axis_tlast)
                        $error("[%s] missing tlast on final beat", bank_name);
                end else if (m_axis_tlast) begin
                    $error("[%s] unexpected tlast on beat %0d", bank_name, beat);
                end

                beat++;
            end
        end

        if (errors == 0)
            $display("[%s] readback PASS (%0d beats)", bank_name, length);
        else
            $error("[%s] readback FAIL (%0d mismatches)", bank_name, errors);
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

        // 3. Write Ping Bank (TDEST=2) — distinct tag pattern from pong
        $display("Writing Ping Bank to TDEST=2");
        axis_write_burst(4'd2, 8, 32'hAABBCCDD, 32'h11223344);

        // 4. Write Pong Bank (TDEST=3)
        $display("Writing Pong Bank to TDEST=3");
        axis_write_burst(4'd3, 8, 32'hDEADBEEF, 32'h55667788);

        // 5. Read back and validate Ping Bank via M_AXIS
        $display("Reading Ping Bank via M_AXIS");
        m_axis_read_start(2'd0, 8);
        axis_read_and_check(8, 32'hAABBCCDD, 32'h11223344, "Ping");

        // 6. Read back and validate Pong Bank via M_AXIS
        $display("Reading Pong Bank via M_AXIS");
        m_axis_read_start(2'd1, 8);
        axis_read_and_check(8, 32'hDEADBEEF, 32'h55667788, "Pong");

        // 7. M_AXIS busy register + re-start lockout
        $display("Testing M_AXIS busy status");
        begin
            logic [31:0] rd;
            int drain;
            m_axis_read_start(2'd0, 4);
            repeat (3) @(posedge clk);
            axi_lite_read(32'h0000_002C, rd);
            if (rd[0] !== 1'b1)
                $error("Expected m_axis_busy=1 during read, got %h", rd);
            else
                $display("m_axis_busy OK during transfer");
            axi_lite_write(32'h0000_0028, 32'h1);
            drain = 0;
            while (drain < 4) begin
                @(posedge clk);
                if (m_axis_tvalid && m_axis_tready) drain++;
            end
            axi_lite_read(32'h0000_002C, rd);
            if (rd[0] !== 1'b0)
                $error("Expected m_axis_busy=0 after read, got %h", rd);
            else
                $display("m_axis_busy cleared after transfer");
        end

        // 8. S_AXIS ping blocked during M_AXIS ping read
        $display("Testing S_AXIS blocked during M_AXIS read");
        begin
            logic        handed;
            logic [31:0] rd;
            m_axis_read_start(2'd0, 8);
            repeat (4) @(posedge clk);
            axi_lite_read(32'h0000_002C, rd);
            if (!rd[0])
                $error("M_AXIS should be busy before stall test");
            @(posedge clk);
            s_axis_tvalid <= 1;
            s_axis_tdata  <= 128'hBAD;
            s_axis_tdest  <= 4'd2;
            s_axis_tlast  <= 1'b0;
            @(posedge clk);
            handed = s_axis_tready;
            s_axis_tvalid <= 0;
            if (handed)
                $error("S_AXIS ping write should stall during M_AXIS ping read");
            else
                $display("S_AXIS ping correctly stalled during M_AXIS read");
            while (!(m_axis_tvalid && m_axis_tready && m_axis_tlast))
                @(posedge clk);
        end

        // 9. Pointer reset after partial burst
        $display("Testing S_AXIS pointer reset");
        begin
            logic handed;
            for (int i = 0; i < 3; i++) begin
                @(posedge clk);
                s_axis_tvalid <= 1;
                s_axis_tdata  <= axis_expected_beat(i, 32'hAABBCCDD, 32'h11223344);
                s_axis_tdest  <= 4'd2;
                s_axis_tlast  <= 1'b0;
                wait (s_axis_tready);
            end
            @(posedge clk);
            s_axis_tvalid <= 0;
            axi_lite_write(32'h0000_0030, 32'h2);
            axis_write_burst(4'd2, 2, 32'hAABBCCDD, 32'h11223344);
            m_axis_read_start(2'd0, 2);
            axis_read_and_check(2, 32'hAABBCCDD, 32'h11223344, "PingPtrRst");
        end

        #100;
        $display("Simulation Finished");
        $finish;
    end

endmodule
