`timescale 1ns / 1ps

module tb_conv5();

    // ==========================================
    // Configuration Parameters
    // ==========================================
    localparam AXI_AWIDTH  = 40;
    localparam AXI_DWIDTH  = 128;
    localparam SRAM_AWIDTH = 11;
    
    // ==========================================
    // Signals Declaration
    // ==========================================
    logic clk;
    logic rst_n;
    
    // AXI-Lite
    logic [31:0] s_axi_awaddr, s_axi_wdata;
    logic s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    logic s_axi_awready, s_axi_wready, s_axi_bvalid;
    logic [1:0]  s_axi_bresp;
    
    // AXI-Full
    logic [AXI_AWIDTH-1:0] m_axi_araddr, m_axi_awaddr;
    logic [7:0]  m_axi_arlen, m_axi_awlen;
    logic [2:0]  m_axi_arsize, m_axi_awsize;
    logic [1:0]  m_axi_arburst, m_axi_awburst;
    logic        m_axi_arvalid, m_axi_arready;
    logic        m_axi_awvalid, m_axi_awready;
    logic [AXI_DWIDTH-1:0] m_axi_wdata, m_axi_rdata;
    logic        m_axi_wvalid, m_axi_wready, m_axi_wlast;
    logic        m_axi_rvalid, m_axi_rready, m_axi_rlast;
    logic        m_axi_bvalid, m_axi_bready;
    logic [1:0]  m_axi_bresp;
    
    // Interrupt
    logic finish_irq_o;

    // ==========================================
    // WATCHDOG TIMER
    // ==========================================
    initial begin
        #100000000;
        $display("[ERROR] Watchdog timeout! Simulation stuck in an infinite loop.");
        $finish;
    end

    // ==========================================
    // INIT DUT (Design Under Test)
    // ==========================================
    lenet_accelerator #(
        .AXI_AWIDTH(AXI_AWIDTH),
        .AXI_DWIDTH(AXI_DWIDTH),
        .SRAM_AWIDTH(SRAM_AWIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        // AXI-Lite
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),   .s_axi_wvalid(s_axi_wvalid),   .s_axi_wready(s_axi_wready),
        .s_axi_bready(s_axi_bready), .s_axi_bvalid(s_axi_bvalid),   .s_axi_bresp(s_axi_bresp),
        // AXI-Full
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),     .m_axi_arsize(m_axi_arsize),   .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),   .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready), .m_axi_rlast(m_axi_rlast),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),     .m_axi_awsize(m_axi_awsize),   .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),   .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wlast(m_axi_wlast),   .m_axi_wready(m_axi_wready),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),   .m_axi_bresp(m_axi_bresp),
        // Interrupt
        .finish_irq_o(finish_irq_o)
    );

    // ==========================================
    // CLOCK & RESET
    // ==========================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ==========================================
    // AXI-LITE TASKS
    // ==========================================
    task axi_lite_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            s_axi_awaddr  <= addr;
            s_axi_wdata   <= data;
            s_axi_awvalid <= 1'b1;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;
            
            // Wait for slave to sample address and data
            do begin
                @(posedge clk);
            end while (!(s_axi_awready && s_axi_wready));
            
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid  <= 1'b0;
            
            // Wait for BVALID response
            while (!s_axi_bvalid) begin
                @(posedge clk);
            end
            
            s_axi_bready  <= 1'b0;
        end
    endtask

    task send_instruction(input [63:0] inst);
        begin
            axi_lite_write(32'h0000_0004, inst[63:32]);
            axi_lite_write(32'h0000_0000, inst[31:0]);
        end
    endtask

    // Microcode will be loaded from file
    logic [31:0] mc_mem [0 : 25 * 5 - 1]; // 5 words per pass (125 words total)

    task upload_microcode;
        begin
            $readmemh("microcode.hex", mc_mem);
            for (int p = 0; p < 25; p++) begin
                for (int w = 0; w < 5; w++) begin
                    axi_lite_write(32'h0200 + p * 32 + w * 4, mc_mem[p*5 + w]);
                end
            end
        end
    endtask

    // ==========================================
    // DATA SCOREBOARD (Mock DDR 128-bit)
    // ==========================================
    logic [AXI_DWIDTH-1:0] mock_ddr [0:32767];

    // =========================================================================
    // Mock Data Loaders for Real Weights & IFM
    // =========================================================================
    logic [127:0] hex_ifm    [0:1023];
    logic [127:0] hex_weight [0:4095];
    logic [15:0]  hex_bias   [0:127];  // 128 lines of 16-bit readable bias values
    logic [7:0]   hex_ofm    [0:127];  // 128 lines of 8-bit readable expected OFM

    task automatic load_hex_data();
        int pass_base;
        $readmemh("ifm.hex", hex_ifm);
        $readmemh("weight.hex", hex_weight);
        $readmemh("bias.hex", hex_bias);
        $readmemh("expected_ofm.hex", hex_ofm);

        // Load IFM into DDR at word 4096 (0x10000 = 65536 bytes)
        for (int i=0; i<25; i++) mock_ddr[4096 + i] = hex_ifm[i];

        // Prepare WGT + BIAS per pass. Put them starting at word 8192 (0x20000 = 131072 bytes)
        // Each pass takes 400 words of weights and 16 words of biases (padded) = 416 words.
        for (int p=0; p<8; p++) begin
            pass_base = 8192 + p * 416;
            // 1. Copy 400 words of weights
            for (int w=0; w<400; w++) begin
                mock_ddr[pass_base + w] = hex_weight[p * 400 + w];
            end
            // 2. Pack and copy 16-bit bias values into 2 words of 128-bit
            // Word 0 (pass_base + 400) gets lower 8 bits of all 16 biases
            // Word 1 (pass_base + 401) gets upper 8 bits of all 16 biases
            mock_ddr[pass_base + 400] = '0;
            mock_ddr[pass_base + 401] = '0;
            for (int ch=0; ch<16; ch++) begin
                mock_ddr[pass_base + 400][ch*8 +: 8] = hex_bias[p * 16 + ch][7:0];
                mock_ddr[pass_base + 401][ch*8 +: 8] = hex_bias[p * 16 + ch][15:8];
            end
            // 3. Pad remaining 14 words with 0
            for (int b=2; b<16; b++) begin
                mock_ddr[pass_base + 400 + b] = '0;
            end
        end
    endtask

    logic [AXI_AWIDTH-1:0] read_start_addr;
    integer read_len;

    // Mock DDR READ
    initial begin
        m_axi_arready <= 1'b0;
        m_axi_rvalid  <= 1'b0;
        m_axi_rlast   <= 1'b0;
        
        forever begin
            m_axi_arready <= 1'b1;
            @(posedge clk);
            if (m_axi_arvalid) begin
                read_start_addr = m_axi_araddr;
                read_len = m_axi_arlen + 1;
                m_axi_arready <= 1'b0;
                
                // Return data from Mock DDR
                for (integer i = 0; i < read_len; i = i + 1) begin
                    m_axi_rvalid <= 1'b1;
                    // Get word address (divide by 16 because 128-bit)
                    m_axi_rdata  <= mock_ddr[(read_start_addr / 16) + i]; 
                    m_axi_rlast  <= (i == read_len - 1) ? 1'b1 : 1'b0;
                    while(1) begin
                        @(posedge clk);
                        if (m_axi_rready) break;
                    end
                end
                m_axi_rvalid <= 1'b0;
                m_axi_rlast  <= 1'b0;
            end
        end
    end

    logic [AXI_AWIDTH-1:0] write_start_addr;
    integer write_len;

    // Mock DDR WRITE
    initial begin
        m_axi_awready <= 1'b0;
        m_axi_wready  <= 1'b0;
        m_axi_bvalid  <= 1'b0;
        m_axi_bresp   <= 2'b00;

        forever begin
            m_axi_awready <= 1'b1;
            @(posedge clk);
            if (m_axi_awvalid) begin
                write_start_addr = m_axi_awaddr;
                write_len = m_axi_awlen + 1;
                m_axi_awready <= 1'b0;

                for (integer i = 0; i < write_len; i = i + 1) begin
                    m_axi_wready <= 1'b1;
                    while(1) begin
                        @(posedge clk);
                        if (m_axi_wvalid) begin
                            mock_ddr[(write_start_addr / 16) + i] = m_axi_wdata;
                            if (m_axi_wlast) i = write_len; // exit loop early if wlast
                            break;
                        end
                    end
                end
                m_axi_wready <= 1'b0;
                m_axi_bvalid <= 1'b1;
                while(1) begin
                    @(posedge clk);
                    if (m_axi_bready) break;
                end
                m_axi_bvalid <= 1'b0;
            end
        end
    end

    // ==========================================
    // MAIN TEST FLOW
    // ==========================================
    initial begin
        // Reset system
        rst_n = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        
        // Init Mock DDR with zeros
        for (integer i=0; i<32768; i++) mock_ddr[i] = '0;

        $display("[+] Loading Hex Data into Mock DDR...");
        load_hex_data();
        
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_conv5);
        
        #20 rst_n = 1;
        #50;

        $display("==================================================");
        $display("   STARTING FULL SYSTEM TEST: LENET ACCELERATOR");
        $display("==================================================");

        // 1. Configure PEA registers (Via AXI-Lite offset 0x100)
        $display("[+] Configuring PEA...");
        axi_lite_write(32'h0000_0100, 5);  // width
        axi_lite_write(32'h0000_0104, 5);  // height
        axi_lite_write(32'h0000_0108, 16); // cin
        axi_lite_write(32'h0000_010C, 16); // cout
        axi_lite_write(32'h0000_0110, 5);  // kernel size
        axi_lite_write(32'h0000_0114, 10); // right shift (10 for Conv5 quantized data)
        axi_lite_write(32'h0000_0118, 5);  // row stride
        axi_lite_write(32'h0000_011C, 1);  // col stride
        axi_lite_write(32'h0000_0128, 1);  // relu enable (1 = enabled)

        $display("[+] Uploading Window Router Microcode...");
        upload_microcode();

        // Loop over 8 passes
        for (int p=0; p<8; p++) begin
            $display("--------------------------------------------------");
            $display("[+] Starting Pass %0d...", p);
            
            // Set dynamic Base Addresses for PEA
            axi_lite_write(32'h0000_0120, 0);   // weight_base (luôn bắt đầu từ 0 của WGT bank)
            axi_lite_write(32'h0000_0124, 400); // bias_base (word thứ 400 của WGT bank)
            
            // 2. Load IFM (Cần nạp lại mỗi pass vì hệ thống tự động swap Ping-Pong)
            $display("[+] Pushing OP_LOAD_IFM instruction...");
            // Set Address 0x10000 for IFM
            send_instruction({4'h1, 2'b00, 18'd0, 40'h0000_010000});
            // Command Load IFM (400 bytes = 25 words for 5x5 image)
            send_instruction({4'hA, 28'd0, 32'd400});
            
            // 3. Load WGT + BIAS cho Pass hiện tại
            // DDR addr: 0x20000 + p * 6656 (6656 bytes = 416 words)
            send_instruction({4'h1, 2'b01, 18'd0, 40'(40'h0000_020000 + p * 6656)});
            send_instruction({4'h4, 28'd0, 32'd6656});
            
            // 4. Run MAC
            send_instruction({4'h5, 60'd0});
            
            // 5. Store OFM cho Pass hiện tại
            // DDR addr: 0x30000 + p * 16 (16 bytes = 1 word)
            send_instruction({4'h1, 2'b10, 18'd0, 40'(40'h0000_030000 + p * 16)});
            send_instruction({4'h7, 28'd0, 32'd16});
        end

        // 6. Finish
        $display("--------------------------------------------------");
        $display("[+] Pushing OP_FINISH instruction...");
        send_instruction({4'hF, 60'd0});

        // Wait for interrupt flag to assert
        $display("[?] Waiting for system processing to complete...");
        while(!finish_irq_o) @(posedge clk);
        $display("[!] System asserted FINISH_IRQ flag!");

        // 7. Verifying Results (Scoreboard)
        begin
            integer errors = 0;
            $display("[+] Verifying OFM Results from Mock DDR...");
            for (int p=0; p<8; p++) begin
                // DDR word index: 0x30000 / 16 = 12288
                // Build expected 128-bit word from 16 byte elements
                logic [127:0] expected_word;
                for (int ch=0; ch<16; ch++) begin
                    expected_word[ch*8 +: 8] = hex_ofm[p * 16 + ch];
                end

                if (mock_ddr[12288 + p] !== expected_word) begin
                    $display("   [FAIL] Pass %0d: Expected %H, Got %H", p, expected_word, mock_ddr[12288 + p]);
                    errors++;
                end else begin
                    $display("   [PASS] Pass %0d output matches golden data!", p);
                end
            end
            
            if (errors == 0) begin
                $display("==================================================");
                $display("   TEST COMPLETED SUCCESSFULLY! ALL PASSES MATCHED!");
                $display("==================================================");
            end else begin
                $display("==================================================");
                $display("   TEST FAILED WITH %0d ERRORS!", errors);
                $display("==================================================");
            end
        end

        $finish;
    end

endmodule
