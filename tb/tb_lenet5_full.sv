`timescale 1ns / 1ps

// ============================================================================
// TOP-LEVEL TESTBENCH: tb_lenet5_full
// ============================================================================
// Performs end-to-end LeNet-5 HW acceleration on 100 MNIST test images.
// Instantiates lenet_accelerator, acts as the CPU driver.
// ============================================================================

module tb_lenet5_full();

    // =========================================================
    // PARAMETERS & SIGNALS
    // =========================================================
    localparam AXI_AWIDTH  = 40;
    localparam AXI_DWIDTH  = 128; // 128-bit internal bus width
    localparam SRAM_AWIDTH = 13;  // 128KB per bank (8192 words * 16 bytes)

    logic clk;
    logic rst_n;

    // --- AXI-Lite Slave (CPU -> FPGA) ---
    logic                    s_axi_awvalid;
    logic                    s_axi_awready;
    logic [31:0]             s_axi_awaddr;
    logic                    s_axi_wvalid;
    logic                    s_axi_wready;
    logic [31:0]             s_axi_wdata;
    
    logic                    s_axi_arvalid;
    logic                    s_axi_arready;
    logic [31:0]             s_axi_araddr;
    logic                    s_axi_rvalid;
    logic                    s_axi_rready;
    logic [31:0]             s_axi_rdata;
    logic [1:0]              s_axi_rresp;
    
    logic                    s_axi_bready;
    logic                    s_axi_bvalid;
    logic [1:0]              s_axi_bresp;

    // --- AXI-Full Master (FPGA -> DDR) ---
    logic [AXI_AWIDTH-1:0]   m_axi_araddr;
    logic [7:0]              m_axi_arlen;
    logic [2:0]              m_axi_arsize;
    logic [1:0]              m_axi_arburst;
    logic                    m_axi_arvalid;
    logic                    m_axi_arready;
    
    logic [AXI_DWIDTH-1:0]   m_axi_rdata;
    logic                    m_axi_rlast;
    logic                    m_axi_rvalid;
    logic                    m_axi_rready;

    logic [AXI_AWIDTH-1:0]   m_axi_awaddr;
    logic [7:0]              m_axi_awlen;
    logic [2:0]              m_axi_awsize;
    logic [1:0]              m_axi_awburst;
    logic                    m_axi_awvalid;
    logic                    m_axi_awready;

    logic [AXI_DWIDTH-1:0]   m_axi_wdata;
    logic                    m_axi_wlast;
    logic                    m_axi_wvalid;
    logic                    m_axi_wready;

    logic [1:0]              m_axi_bresp;
    logic                    m_axi_bvalid;
    logic                    m_axi_bready;

    logic                    finish_irq_o;

    // =========================================================
    // ACCELERATOR INSTANTIATION
    // =========================================================
    tensor_processing_unit_top #(
        .AXI_AWIDTH(AXI_AWIDTH),
        .AXI_DWIDTH(AXI_DWIDTH),
        .SRAM_AWIDTH(SRAM_AWIDTH)
    ) uut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready), .s_axi_awaddr(s_axi_awaddr),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready), .s_axi_wdata(s_axi_wdata),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready), .s_axi_araddr(s_axi_araddr),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_bready(s_axi_bready), .s_axi_bvalid(s_axi_bvalid), .s_axi_bresp(s_axi_bresp),

        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
        
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        
        .finish_irq_o(finish_irq_o)
    );

    // =========================================================
    // CLOCK & RESET
    // =========================================================
    always #5 clk = ~clk; // 100MHz (10ns period)

    initial begin
        #1000000000; // 1s simulation watchdog timeout
        $display("[WATCHDOG] Simulation timeout reached! Force terminating...");
        $finish;
    end

    // =========================================================
    // AXI-LITE MASTER BFM
    // =========================================================
    task axi_lite_write(input logic [31:0] addr, input logic [31:0] data);
        begin
            @(posedge clk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;

            do begin
                @(posedge clk);
            end while (!(s_axi_awready && s_axi_wready));
            
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid  <= 1'b0;

            while (!s_axi_bvalid) begin
                @(posedge clk);
            end
            
            s_axi_bready  <= 1'b0;
        end
    endtask

    task send_instruction(input logic [63:0] inst);
        begin
            axi_lite_write(32'h0000_0004, inst[63:32]);
            axi_lite_write(32'h0000_0000, inst[31:0]);
        end
    endtask

    task upload_microcode(input string filename, input int num_passes);
        begin
            logic [31:0] mc_mem [0 : 125 - 1];
            for (int i = 0; i < 125; i++) mc_mem[i] = 32'h0;
            $readmemh(filename, mc_mem);
            for (int p = 0; p < num_passes; p++) begin
                for (int w = 0; w < 5; w++) begin
                    axi_lite_write(32'h0200 + p * 32 + w * 4, mc_mem[p*5 + w]);
                end
            end
        end
    endtask

    // =========================================================
    // AXI-FULL MASTER BFM (Mock DDR Memory)
    // =========================================================
    logic [7:0] ddr_mem [longint];

    // Read Channel BFM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_arready <= 1'b0;
        end else begin
            if (m_axi_arvalid && !m_axi_arready) m_axi_arready <= 1'b1;
            else if (m_axi_arready) m_axi_arready <= 1'b0;
        end
    end

    initial begin
        m_axi_rvalid <= 1'b0;
        m_axi_rlast  <= 1'b0;
        m_axi_rdata  <= '0;
        forever begin
            @(posedge clk);
            if (m_axi_arvalid && m_axi_arready) begin
                logic [AXI_AWIDTH-1:0] r_addr;
                int r_len;
                r_addr = m_axi_araddr;
                r_len = m_axi_arlen;
                
                repeat(5) @(posedge clk); // 5 cycles memory latency

                for (int i = 0; i <= r_len; i++) begin
                    logic [127:0] temp_data;
                    temp_data = '0;
                    for (int b = 0; b < 16; b++) begin
                        temp_data[b*8 +: 8] = ddr_mem.exists(r_addr + b) ? ddr_mem[r_addr + b] : 8'h00;
                    end
                    
                    m_axi_rdata  <= temp_data;
                    m_axi_rvalid <= 1'b1;
                    m_axi_rlast  <= (i == r_len);
                    
                    wait(m_axi_rready);
                    @(posedge clk);
                    r_addr = r_addr + 16;
                end
                
                m_axi_rvalid <= 1'b0;
                m_axi_rlast  <= 1'b0;
            end
        end
    end

    // Write Channel BFM
    initial begin
        m_axi_awready <= 1'b0;
        m_axi_wready  <= 1'b0;
        m_axi_bvalid  <= 1'b0;
        m_axi_bresp   <= 2'b00;

        forever begin
            @(posedge clk);
            if (m_axi_awvalid && !m_axi_awready) begin
                m_axi_awready <= 1'b1;
                
                fork
                    begin
                        logic [AXI_AWIDTH-1:0] w_addr;
                        int w_len;
                        int beats;
                        w_addr = m_axi_awaddr;
                        w_len = m_axi_awlen;
                        beats = 0;

                        m_axi_wready <= 1'b1;
                        
                        while (beats <= w_len) begin
                            @(posedge clk);
                            if (m_axi_wvalid && m_axi_wready) begin
                                for (int b = 0; b < 16; b++) begin
                                    ddr_mem[w_addr + b] = m_axi_wdata[b*8 +: 8];
                                end
                                w_addr = w_addr + 16;
                                beats++;
                                if (m_axi_wlast) break;
                            end
                        end
                        m_axi_wready <= 1'b0;
                        
                        @(posedge clk);
                        m_axi_bvalid <= 1'b1;
                        wait(m_axi_bready);
                        @(posedge clk);
                        m_axi_bvalid <= 1'b0;
                    end
                join_none
            end else begin
                m_axi_awready <= 1'b0;
            end
        end
    end

    // =========================================================
    // INSTRUCTION GENERATION TASKS
    // =========================================================
    task run_c1(input logic [39:0] ifm_addr, input logic [39:0] wgt_addr);
        begin
            send_instruction({4'h1, 2'b00, 18'h0, ifm_addr});
            send_instruction({4'h1, 2'b01, 18'h0, wgt_addr});
            send_instruction({4'h2, 12'h0, 16'd32, 16'd32, 16'd1});
            send_instruction({4'h3, 28'h0, 16'd6, 8'd5, 4'd1, 4'd12});
            send_instruction({4'h4, 28'h0, 32'd544});
            send_instruction({4'hA, 28'h0, 32'd16384});
            send_instruction({4'h5, 59'h0, 1'b1});
            send_instruction({4'h2, 12'h0, 16'd28, 16'd28, 16'd6});
            send_instruction({4'h6, 50'h0, 2'b00, 8'd2});
            send_instruction({4'hF, 60'h0});
        end
    endtask

    task run_c3(input logic [39:0] wgt_addr);
        begin
            send_instruction({4'h1, 2'b01, 18'h0, wgt_addr});
            send_instruction({4'h2, 12'h0, 16'd14, 16'd14, 16'd6});
            send_instruction({4'h3, 28'h0, 16'd16, 8'd5, 4'd1, 4'd9});
            send_instruction({4'h4, 28'h0, 32'd2592});
            send_instruction({4'h5, 59'h0, 1'b1});
            send_instruction({4'h2, 12'h0, 16'd10, 16'd10, 16'd16});
            send_instruction({4'h6, 50'h0, 2'b00, 8'd2});
            send_instruction({4'hF, 60'h0});
        end
    endtask

    task run_c5(input logic [39:0] wgt_addr, input logic [39:0] ofm_addr);
        begin
            send_instruction({4'h1, 2'b01, 18'h0, wgt_addr});
            send_instruction({4'h1, 2'b10, 18'h0, ofm_addr});
            send_instruction({4'h2, 12'h0, 16'd5, 16'd5, 16'd16});
            send_instruction({4'h3, 28'h0, 16'd120, 8'd5, 4'd1, 4'd10});
            send_instruction({4'h4, 28'h0, 32'd51456});
            send_instruction({4'h5, 59'h0, 1'b1});
            send_instruction({4'h7, 28'h0, 32'd128});
            send_instruction({4'hF, 60'h0});
        end
    endtask

    task run_f6(input logic [39:0] ifm_addr, input logic [39:0] wgt_addr, input logic [39:0] ofm_addr);
        begin
            send_instruction({4'h1, 2'b00, 18'h0, ifm_addr});
            send_instruction({4'h1, 2'b01, 18'h0, wgt_addr});
            send_instruction({4'h1, 2'b10, 18'h0, ofm_addr});
            send_instruction({4'h2, 12'h0, 16'd1, 16'd1, 16'd120});
            send_instruction({4'h3, 28'h0, 16'd84, 8'd1, 4'd1, 4'd7});
            send_instruction({4'h4, 28'h0, 32'd12480});
            send_instruction({4'hA, 28'h0, 32'd128});
            send_instruction({4'h5, 59'h0, 1'b1});
            send_instruction({4'h7, 28'h0, 32'd96});
            send_instruction({4'hF, 60'h0});
        end
    endtask

    task run_out(input logic [39:0] ifm_addr, input logic [39:0] wgt_addr, input logic [39:0] ofm_addr);
        begin
            send_instruction({4'h1, 2'b00, 18'h0, ifm_addr});
            send_instruction({4'h1, 2'b01, 18'h0, wgt_addr});
            send_instruction({4'h1, 2'b10, 18'h0, ofm_addr});
            send_instruction({4'h2, 12'h0, 16'd1, 16'd1, 16'd84});
            send_instruction({4'h3, 28'h0, 16'd10, 8'd1, 4'd1, 4'd0});
            send_instruction({4'h4, 28'h0, 32'd1568});
            send_instruction({4'hA, 28'h0, 32'd96});
            send_instruction({4'h5, 59'h0, 1'b0}); // relu_en=0
            send_instruction({4'h7, 28'h0, 32'd16});
            send_instruction({4'hF, 60'h0});
        end
    endtask

    // =========================================================
    // MOCK DATA STORAGE
    // =========================================================
    logic [7:0] c1_wgt_mem [0 : 512 - 1];
    logic [7:0] c1_bias_mem [0 : 32 - 1];
    
    logic [7:0] c3_wgt_mem [0 : 2560 - 1];
    logic [7:0] c3_bias_mem [0 : 32 - 1];
    
    logic [7:0] c5_wgt_mem [0 : 51200 - 1];
    logic [7:0] c5_bias_mem [0 : 256 - 1];
    
    logic [7:0] f6_wgt_mem [0 : 12288 - 1];
    logic [7:0] f6_bias_mem [0 : 192 - 1];
    
    logic [7:0] out_wgt_mem [0 : 1536 - 1];
    logic [7:0] out_bias_mem [0 : 32 - 1];
    
    logic [7:0] mnist_images_mem [0 : 100 * 16384 - 1];
    logic [7:0] mnist_labels [0 : 99];
    integer label_file;

    // =========================================================
    // LOGGING TASKS (Enabled via `define DEBUG_DUMP)
    // =========================================================
`ifdef DEBUG_DUMP
    task dump_sram_bank_to_file(
        input string filename,
        input int    num_words,   // Number of 128-bit words to dump
        input int    num_channels // Active channels per word (e.g. 6 for C1)
    );
        integer fd;
        fd = $fopen(filename, "w");
        if (fd == 0) begin
            $display("[LOG ERROR] Cannot open %s", filename);
            return;
        end
        $fwrite(fd, "# SRAM Ping Bank Dump: %0d words, %0d active channels per word\n", num_words, num_channels);
        $fwrite(fd, "# Format: word_addr | ch0 ch1 ch2 ... ch(N-1)\n");
        for (int w = 0; w < num_words; w++) begin
            $fwrite(fd, "%04d |", w);
            for (int ch = 0; ch < num_channels; ch++) begin
                $fwrite(fd, " %4d", $signed(uut.u_ping_bank.r_mem[w][ch*8 +: 8]));
            end
            $fwrite(fd, "\n");
        end
        $fclose(fd);
        $display("  [LOG] Wrote %s (%0d words x %0d ch)", filename, num_words, num_channels);
    endtask

    task dump_ddr_region_to_file(
        input string filename,
        input longint base_addr,
        input int     num_bytes,
        input int     num_channels // For display formatting
    );
        integer fd;
        fd = $fopen(filename, "w");
        if (fd == 0) begin
            $display("[LOG ERROR] Cannot open %s", filename);
            return;
        end
        $fwrite(fd, "# DDR Dump: base=0x%010h, %0d bytes, %0d channels\n", base_addr, num_bytes, num_channels);
        $fwrite(fd, "# Format: byte_offset | ch0 ch1 ch2 ... ch(N-1)\n");
        for (int w = 0; w < num_bytes / 16; w++) begin
            $fwrite(fd, "%04d |", w);
            for (int ch = 0; ch < ((num_channels < 16) ? num_channels : 16); ch++) begin
                automatic logic [7:0] v;
                v = ddr_mem.exists(base_addr + w * 16 + ch) ? ddr_mem[base_addr + w * 16 + ch] : 8'h00;
                $fwrite(fd, " %4d", $signed(v));
            end
            $fwrite(fd, "\n");
        end
        $fclose(fd);
        $display("  [LOG] Wrote %s (%0d bytes)", filename, num_bytes);
    endtask
`endif

    // =========================================================
    // MAIN SIMULATION CONTROL BLOCK
    // =========================================================
    initial begin
        int correct_predictions;
        correct_predictions = 0;

        // Reset inputs
        clk = 0;
        rst_n = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_arvalid = 0; s_axi_rready = 0; s_axi_bready = 0;

        $display("==================================================");
        $display("   [INIT] Pre-loading weights, biases and MNIST data...");
        $display("==================================================");

        $readmemh("c1_wgt.hex", c1_wgt_mem);
        $readmemh("c1_bias.hex", c1_bias_mem);
        $readmemh("c3_wgt.hex", c3_wgt_mem);
        $readmemh("c3_bias.hex", c3_bias_mem);
        $readmemh("c5_wgt.hex", c5_wgt_mem);
        $readmemh("c5_bias.hex", c5_bias_mem);
        $readmemh("f6_wgt.hex", f6_wgt_mem);
        $readmemh("f6_bias.hex", f6_bias_mem);
        $readmemh("out_wgt.hex", out_wgt_mem);
        $readmemh("out_bias.hex", out_bias_mem);
        $readmemh("mnist_images.hex", mnist_images_mem);

        label_file = $fopen("mnist_labels.txt", "r");
        if (label_file == 0) begin
            $display("[ERROR] Failed to open mnist_labels.txt!");
            $finish;
        end
        for (int i = 0; i < 100; i++) begin
            int val;
            $fscanf(label_file, "%d\n", val);
            mnist_labels[i] = val[7:0];
        end
        $fclose(label_file);

        // Populate DDR BFM
        ddr_mem.delete();
        for (int i = 0; i < 100 * 16384; i++) ddr_mem[40'h1000_0000 + i] = mnist_images_mem[i];
        
        for (int i = 0; i < 512; i++) ddr_mem[40'h2000_0000 + i] = c1_wgt_mem[i];
        for (int i = 0; i < 32; i++)  ddr_mem[40'h2000_0000 + 512 + i] = c1_bias_mem[i];
        
        for (int i = 0; i < 2560; i++) ddr_mem[40'h2010_0000 + i] = c3_wgt_mem[i];
        for (int i = 0; i < 32; i++)   ddr_mem[40'h2010_0000 + 2560 + i] = c3_bias_mem[i];
        
        for (int i = 0; i < 51200; i++) ddr_mem[40'h2020_0000 + i] = c5_wgt_mem[i];
        for (int i = 0; i < 256; i++)   ddr_mem[40'h2020_0000 + 51200 + i] = c5_bias_mem[i];
        
        for (int i = 0; i < 12288; i++) ddr_mem[40'h2030_0000 + i] = f6_wgt_mem[i];
        for (int i = 0; i < 192; i++)   ddr_mem[40'h2030_0000 + 12288 + i] = f6_bias_mem[i];
        
        for (int i = 0; i < 1536; i++) ddr_mem[40'h2040_0000 + i] = out_wgt_mem[i];
        for (int i = 0; i < 32; i++)   ddr_mem[40'h2040_0000 + 1536 + i] = out_bias_mem[i];

        #200 rst_n = 1;
        #200;

        $display("==================================================");
        $display("   STARTING END-TO-END LENET-5 HW ACCELERATION    ");
        $display("==================================================");

        for (int img_idx = 0; img_idx < 100; img_idx++) begin
            $display("[IMAGE %0d/100] Label: %0d", img_idx + 1, mnist_labels[img_idx]);

            // ------------------ LAYER 1 (C1) ------------------
            upload_microcode("c1_mc.hex", 2);
            axi_lite_write(32'h0100, 32); // ifm_width
            axi_lite_write(32'h0104, 32); // ifm_height
            axi_lite_write(32'h0108, 1);  // channels_in
            axi_lite_write(32'h010C, 6);  // channels_out
            axi_lite_write(32'h0110, 5);  // kernel_size
            axi_lite_write(32'h0114, 12); // right_shift
            axi_lite_write(32'h0120, 0);  // weight_base
            axi_lite_write(32'h0124, 32); // bias_base
            axi_lite_write(32'h0128, 1);  // relu_en

`ifdef DEBUG_DUMP
            // Log C1 input image (32x32x1 from DDR) for first 3 images
            if (img_idx < 3) begin
                automatic string fn;
                automatic longint img_base;
                automatic integer fd;
                img_base = 40'h1000_0000 + img_idx * 16384;
                $sformat(fn, "c1_input_img%0d.log", img_idx);
                fd = $fopen(fn, "w");
                if (fd != 0) begin
                    $fwrite(fd, "# C1 Input Image %0d (32x32, channel 0 only)\n", img_idx);
                    $fwrite(fd, "# Format: row col | pixel_value (unsigned)\n");
                    for (int r = 0; r < 32; r++) begin
                        for (int c = 0; c < 32; c++) begin
                            automatic logic [7:0] px;
                            px = ddr_mem.exists(img_base + (r * 32 + c) * 16) ? ddr_mem[img_base + (r * 32 + c) * 16] : 8'h00;
                            $fwrite(fd, "%3d ", px);
                        end
                        $fwrite(fd, "\n");
                    end
                    $fclose(fd);
                    $display("  [LOG] Wrote %s (32x32 pixels)", fn);
                end
            end
`endif

            run_c1(40'h1000_0000 + img_idx * 16384, 40'h2000_0000);
            wait(finish_irq_o);
            #100;

            rst_n = 0; #50; rst_n = 1; #100;

            // ------------------ LAYER 2 (C3) ------------------
            upload_microcode("c3_mc.hex", 10);
            axi_lite_write(32'h0100, 14); // ifm_width
            axi_lite_write(32'h0104, 14); // ifm_height
            axi_lite_write(32'h0108, 6);  // channels_in
            axi_lite_write(32'h010C, 16); // channels_out
            axi_lite_write(32'h0110, 5);  // kernel_size
            axi_lite_write(32'h0114, 9);  // right_shift
            axi_lite_write(32'h0120, 0);  // weight_base
            axi_lite_write(32'h0124, 160);// bias_base
            axi_lite_write(32'h0128, 1);  // relu_en

            run_c3(40'h2010_0000);
            wait(finish_irq_o);
            #100;

            rst_n = 0; #50; rst_n = 1; #100;

            // ------------------ LAYER 3 (C5) ------------------
            upload_microcode("c5_mc.hex", 25);
            axi_lite_write(32'h0100, 5);   // ifm_width
            axi_lite_write(32'h0104, 5);   // ifm_height
            axi_lite_write(32'h0108, 16);  // channels_in
            axi_lite_write(32'h010C, 120); // channels_out
            axi_lite_write(32'h0110, 5);   // kernel_size
            axi_lite_write(32'h0114, 10);  // right_shift
            axi_lite_write(32'h0120, 0);   // weight_base
            axi_lite_write(32'h0124, 3200);// bias_base
            axi_lite_write(32'h0128, 1);   // relu_en

            run_c5(40'h2020_0000, 40'h4000_0000);
            wait(finish_irq_o);
            #100;

            rst_n = 0; #50; rst_n = 1; #100;

            // ------------------ LAYER 4 (F6) ------------------
            upload_microcode("f6_mc.hex", 8);
            axi_lite_write(32'h0100, 1);   // ifm_width
            axi_lite_write(32'h0104, 1);   // ifm_height
            axi_lite_write(32'h0108, 120); // channels_in
            axi_lite_write(32'h010C, 84);  // channels_out
            axi_lite_write(32'h0110, 1);   // kernel_size
            axi_lite_write(32'h0114, 7);   // right_shift
            axi_lite_write(32'h0120, 0);   // weight_base
            axi_lite_write(32'h0124, 768);  // bias_base
            axi_lite_write(32'h0128, 1);   // relu_en

            run_f6(40'h4000_0000, 40'h2030_0000, 40'h4000_1000);
            wait(finish_irq_o);
            #100;

            rst_n = 0; #50; rst_n = 1; #100;

            // ------------------ LAYER 5 (OUT) -----------------
            upload_microcode("out_mc.hex", 6);
            axi_lite_write(32'h0100, 1);   // ifm_width
            axi_lite_write(32'h0104, 1);   // ifm_height
            axi_lite_write(32'h0108, 84);  // channels_in
            axi_lite_write(32'h010C, 10);  // channels_out
            axi_lite_write(32'h0110, 1);   // kernel_size
            axi_lite_write(32'h0114, 0);   // right_shift
            axi_lite_write(32'h0120, 0);   // weight_base
            axi_lite_write(32'h0124, 96);   // bias_base
            axi_lite_write(32'h0128, 0);   // relu_en

            run_out(40'h4000_1000, 40'h2040_0000, 40'h3000_0000 + img_idx * 16);
            wait(finish_irq_o);
            #100;

`ifdef DEBUG_DUMP
            // Log OUT output (10 logits, stored in DDR at 0x3000_0000 + offset, 16 bytes)
            if (img_idx < 3) begin
                automatic string fn;
                $sformat(fn, "out_output_img%0d.log", img_idx);
                dump_ddr_region_to_file(fn, 40'h3000_0000 + img_idx * 16, 16, 10); // 1 word, 10 channels
            end
`endif

            #100;

            // Calculate Prediction (Argmax) on logit values in DDR
            begin
                int max_val;
                int pred;
                max_val = -2147483647 - 1;
                pred = -1;
                for (int c = 0; c < 10; c++) begin
                    logic [7:0] val;
                    int s_val;
                    val = ddr_mem[40'h3000_0000 + img_idx * 16 + c];
                    s_val = $signed(val);
                    if (s_val > max_val) begin
                        max_val = s_val;
                        pred = c;
                    end
                end
                
                $display("  => Logits: [%d, %d, %d, %d, %d, %d, %d, %d, %d, %d]",
                         $signed(ddr_mem[40'h3000_0000 + img_idx * 16 + 0]),
                         $signed(ddr_mem[40'h3000_0000 + img_idx * 16 + 1]),
                         $signed(ddr_mem[40'h3000_0000 + img_idx * 16 + 2]),
                         $signed(ddr_mem[40'h3000_0000 + img_idx * 16 + 3]),
                         $signed(ddr_mem[40'h3000_0000 + img_idx * 16 + 4]),
                         $signed(ddr_mem[40'h3000_0000 + img_idx * 16 + 5]),
                         $signed(ddr_mem[40'h3000_0000 + img_idx * 16 + 6]),
                         $signed(ddr_mem[40'h3000_0000 + img_idx * 16 + 7]),
                         $signed(ddr_mem[40'h3000_0000 + img_idx * 16 + 8]),
                         $signed(ddr_mem[40'h3000_0000 + img_idx * 16 + 9]));
                if (pred == mnist_labels[img_idx]) begin
                    correct_predictions++;
                    $display("  => Match! Predicted: %0d, Expected: %0d", pred, mnist_labels[img_idx]);
                end else begin
                    $display("  => MISMATCH! Predicted: %0d, Expected: %0d", pred, mnist_labels[img_idx]);
                end
            end

            rst_n = 0; #50; rst_n = 1; #100;
        end

        $display("\n==================================================");
        $display("   FINAL EVALUATION ACCURACY: %0d / 100", correct_predictions);
        $display("==================================================");
        $finish;
    end

endmodule
