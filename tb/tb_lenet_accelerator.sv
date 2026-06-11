`timescale 1ns / 1ps

// ============================================================================
// TOP-LEVEL TESTBENCH: tb_lenet_accelerator
// ============================================================================
// Chức năng:
// 1. Khởi tạo lenet_accelerator
// 2. AXI-Lite BFM: Gửi cấu hình và tập lệnh (Instructions) cho Controller
// 3. AXI-Full BFM (DDR Mock): Giả lập bộ nhớ DDR chứa ảnh đầu vào và nhận ảnh đầu ra
// 4. Random Data Generator & Reference Model: Tự động kiểm tra tính đúng đắn
// ============================================================================

module tb_lenet_accelerator();

    // =========================================================
    // PARAMETERS & SIGNALS
    // =========================================================
    localparam AXI_AWIDTH = 40;
    localparam AXI_DWIDTH = 128; // Changed to match SRAM_DWIDTH (128)

    // CONV3 Settings
    localparam IFM_W = 14;
    localparam IFM_H = 14;
    localparam K_SIZE = 5;
    localparam OUT_W = IFM_W - K_SIZE + 1;
    localparam OUT_H = IFM_H - K_SIZE + 1;
    localparam C_IN = 16;
    localparam C_OUT = 16;
    localparam COUT_TILES = (C_OUT + 15) / 16;
    localparam NUM_PASSES = (C_IN * K_SIZE * K_SIZE + 15) / 16;

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
    // INSTANTIATION
    // =========================================================
    lenet_accelerator #(
        .AXI_AWIDTH(AXI_AWIDTH),
        .AXI_DWIDTH(AXI_DWIDTH)
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
    always #5 clk = ~clk; // 100MHz

    // Watchdog timer to prevent infinite loops/simulation hangs
    initial begin
        #100000; // 100us timeout
        $display("[WATCHDOG] Simulation timeout reached! Force terminating...");
        $finish;
    end

    // =========================================================
    // AXI-LITE BFM (Master)
    // =========================================================
    task axi_lite_write(input logic [31:0] addr, input logic [31:0] data);
        begin
            @(posedge clk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;

            // Chờ Ready từ Slave
            do begin
                @(posedge clk);
            end while (!(s_axi_awready && s_axi_wready));
            
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid  <= 1'b0;

            // Chờ BVALID trả về
            while (!s_axi_bvalid) begin
                @(posedge clk);
            end
            
            s_axi_bready  <= 1'b0;
        end
    endtask

    // Tương tự, AXI-Lite Read (không dùng nhiều trong test flow này)
    task axi_lite_read(input logic [31:0] addr, output logic [31:0] data);
        begin
            @(posedge clk);
            s_axi_araddr  = addr;
            s_axi_arvalid = 1'b1;
            s_axi_rready  = 1'b1;

            wait(s_axi_arready);
            @(posedge clk);
            s_axi_arvalid = 1'b0;

            wait(s_axi_rvalid);
            data = s_axi_rdata;
            @(posedge clk);
            s_axi_rready  = 1'b0;
        end
    endtask

    task send_instruction(input logic [63:0] inst);
        begin
            axi_lite_write(32'h0000_0004, inst[63:32]);
            axi_lite_write(32'h0000_0000, inst[31:0]);
        end
    endtask

    // Microcode will be loaded from file
    logic [31:0] mc_mem [0 : NUM_PASSES * 5 - 1]; // 5 words per pass

    task upload_microcode;
        begin
            $readmemh("microcode.hex", mc_mem);
            for (int p = 0; p < NUM_PASSES; p++) begin
                for (int w = 0; w < 5; w++) begin
                    axi_lite_write(32'h0200 + p * 32 + w * 4, mc_mem[p*5 + w]);
                end
            end
        end
    endtask

    // =========================================================
    // AXI-FULL BFM (DDR Memory Mock - Slave)
    // =========================================================
    logic [7:0] ddr_mem [longint]; // Associative Array cho bộ nhớ 64-bit address space

    // 1. Read Channel
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_arready <= 1'b0;
        end else begin
            // Chấp nhận yêu cầu đọc
            if (m_axi_arvalid && !m_axi_arready) begin
                m_axi_arready <= 1'b1;
            end else if (m_axi_arready) begin
                m_axi_arready <= 1'b0;
            end

            // Phản hồi dữ liệu liên tục theo Burst
            // Lưu ý: BFM này giản lược, giả định Burst INCR và luôn gửi liền mạch
            // (Thực tế cần dùng máy trạng thái xử lý m_axi_arlen)
            // Để đơn giản cho mô phỏng, ta dùng vòng lặp (với delay giả lập) ở khối process riêng
        end
    end

    // Read Data Thread
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
                
                // Mất 5 nhịp clock để truy cập DDR
                repeat(5) @(posedge clk);

                for (int i = 0; i <= r_len; i++) begin
                    logic [127:0] temp_data;
                    temp_data = '0;
                    
                    // Ghép 16 bytes thành 1 từ 128-bit
                    for (int b = 0; b < 16; b++) begin
                        temp_data[b*8 +: 8] = ddr_mem.exists(r_addr + b) ? ddr_mem[r_addr + b] : 8'h00;
                    end
                    
                    m_axi_rdata  <= temp_data;
                    m_axi_rvalid <= 1'b1;
                    m_axi_rlast  <= (i == r_len);
                    
                    wait(m_axi_rready); // Đợi Master sẵn sàng nhận
                    @(posedge clk);
                    r_addr = r_addr + 16; // Mặc định bus 128-bit = 16 bytes
                end
                
                m_axi_rvalid <= 1'b0;
                m_axi_rlast  <= 1'b0;
            end
        end
    end

    // 2. Write Channel
    initial begin
        m_axi_awready <= 1'b0;
        m_axi_wready  <= 1'b0;
        m_axi_bvalid  <= 1'b0;
        m_axi_bresp   <= 2'b00;

        forever begin
            @(posedge clk);
            // Chấp nhận Address
            if (m_axi_awvalid && !m_axi_awready) begin
                m_axi_awready <= 1'b1;
                
                // Thu thập Data
                fork
                    begin
                        logic [AXI_AWIDTH-1:0] w_addr;
                        int w_len;
                        int beats;
                        w_addr = m_axi_awaddr;
                        w_len = m_axi_awlen;
                        beats = 0;

                        m_axi_wready <= 1'b1; // Sẵn sàng nhận data
                        
                        while (beats <= w_len) begin
                            @(posedge clk);
                            if (m_axi_wvalid && m_axi_wready) begin
                                // Ghi 16 bytes vào DDR Mock
                                for (int b = 0; b < 16; b++) begin
                                    ddr_mem[w_addr + b] = m_axi_wdata[b*8 +: 8];
                                end
                                w_addr = w_addr + 16;
                                beats++;
                                if (m_axi_wlast) break;
                            end
                        end
                        m_axi_wready <= 1'b0;
                        
                        // Phản hồi BVALID
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
    // KỊCH BẢN KIỂM THỬ (TEST SEQUENCE)
    // =========================================================
    
    // Memory map
    localparam IFM_ADDR  = 40'h1000_0000;
    localparam WGT_ADDR  = 40'h2000_0000; // Trọng số và Bias
    localparam OFM_ADDR  = 40'h3000_0000; // Kết quả trả về
    
    // Kích thước (Fix theo phần cứng K=5 của PEA)
    // Các hằng số IFM_W, IFM_H, C_IN, C_OUT, v.v. đã được dời lên đầu file.
    localparam RIGHT_SHIFT = 8;
    localparam RELU_EN = 1;

    // Arrays loaded from HEX files
    logic [7:0] ifm_mem_file [0 : IFM_H * IFM_W * 16 - 1]; // Size includes padding
    logic [7:0] wgt_mem_file [0 : ((C_OUT+15)/16) * (((C_IN*K_SIZE*K_SIZE+15)/16)*16) * 16 - 1];
    logic [7:0] bias_mem_file [0 : ((C_OUT+15)/16)*32 - 1];
    logic [63:0] inst_mem_file [0 : 15]; // Max 16 instructions
    logic [7:0] golden_ofm_file [0 : OUT_H * OUT_W * (COUT_TILES * 16) - 1];
    initial begin
        int real_cout;
        longint offset;
        longint bias_base_offset;
        
        // Khởi tạo tín hiệu
        clk = 0;
        rst_n = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_arvalid = 0; s_axi_rready = 0; s_axi_bready = 0;
        
        $display("==================================================");
        $display("[+] Loading Golden Data from HEX files...");
        $display("==================================================");
        
        $readmemh("ifm.hex", ifm_mem_file);
        $readmemh("wgt.hex", wgt_mem_file);
        $readmemh("bias.hex", bias_mem_file);
        $readmemh("instructions.hex", inst_mem_file);
        $readmemh("golden_ofm.hex", golden_ofm_file);

        // 1. Khởi tạo mảng DDR bằng 0
        ddr_mem.delete();

        // 2. Nạp IFM vào DDR
        for (int i = 0; i < $size(ifm_mem_file); i++) begin
            ddr_mem[IFM_ADDR + i] = ifm_mem_file[i];
        end

        // 3. Nạp WGT vào DDR
        for (int i = 0; i < $size(wgt_mem_file); i++) begin
            ddr_mem[WGT_ADDR + i] = wgt_mem_file[i];
        end

        // 4. Nạp BIAS vào DDR
        begin
            automatic int total_wgt_elements = C_IN * K_SIZE * K_SIZE;
            automatic int padded_elements_per_tile = ((total_wgt_elements + 15) / 16) * 16;
            automatic int bias_base_word = ((C_OUT + 15) / 16) * padded_elements_per_tile;
            
            for (int i = 0; i < $size(bias_mem_file); i++) begin
                ddr_mem[WGT_ADDR + (bias_base_word * 16) + i] = bias_mem_file[i];
            end
        end


        // Bỏ Reset
        #100 rst_n = 1;
        #100;

        $display("[+] Sending PEA Array configuration via AXI-Lite...");
        // Các thanh ghi PEA Cfg map ở 0x100 trở đi trong lenet_accelerator.sv
        axi_lite_write(32'h0100, IFM_W); // ifm_width
        axi_lite_write(32'h0104, IFM_H); // ifm_height
        axi_lite_write(32'h0108, C_IN);  // channels_in
        axi_lite_write(32'h010C, C_OUT); // channels_out
        axi_lite_write(32'h0110, K_SIZE);// kernel_size
        axi_lite_write(32'h0114, RIGHT_SHIFT); // right_shift
        axi_lite_write(32'h0120, 0); // weight base nội bộ SRAM = 0
        // Bias base = COUT_TILES * NUM_PASSES * 16 (Cho Conv3 là 1 * 25 * 16 = 400 words)
        axi_lite_write(32'h0124, COUT_TILES * NUM_PASSES * 16); // bias base (word addr)
        axi_lite_write(32'h0128, RELU_EN); // relu enable

        $display("[+] Uploading Window Router Microcode...");
        upload_microcode();

        $display("[+] Pushing Instructions to Controller (Instruction FIFO mapped at 0x00)...");
        // Đẩy toàn bộ lệnh (có thể lên tới 16 lệnh)
        for(int i = 0; i < 16; i++) begin
            if (inst_mem_file[i] !== 64'bx && inst_mem_file[i] !== 0) begin
                send_instruction(inst_mem_file[i]);
            end
        end

        $display("[?] Waiting for finish interrupt signal (finish_irq_o)...");
        wait(finish_irq_o);
        $display("[!] Finish interrupt received! Starting result verification.");

        // =========================================================================
        // KIỂM TRA MÔ HÌNH THAM CHIẾU (REFERENCE CHECK)
        // =========================================================================
        // Tham chiếu đã được C++ sinh ra và lưu vào golden_ofm_file
        
        check_results();

        $finish;
    end



    // Hàm đối chiếu DDR với kết quả tham chiếu
    task check_results();
        int errors;
        int checked;
        longint offset;
        logic [7:0] hw_val;
        logic [7:0] ref_val;
        
        errors = 0;
        checked = 0;
        
        for (int h = 0; h < OUT_H; h++) begin
            for (int w = 0; w < OUT_W; w++) begin
                for (int cout = 0; cout < C_OUT; cout++) begin
                    // Tính offset ghi ra DMA: PEA ghi theo thứ tự Pixel -> Channel (padded to 16)
                    offset = (h * OUT_W + w) * (COUT_TILES * 16) + cout;
                    hw_val = ddr_mem.exists(OFM_ADDR + offset) ? ddr_mem[OFM_ADDR + offset] : 8'hXX;
                    ref_val = golden_ofm_file[offset];
                    
                    checked++;
                    
                    if (hw_val !== ref_val) begin
                        $display("[FAIL] At (h=%0d, w=%0d, c=%0d): HW = %0d, REF = %0d", h, w, cout, $signed(hw_val), $signed(ref_val));
                        errors++;
                    end
                end
            end
        end
        
        $display("==================================================");
        if (errors == 0)
            $display("[PASS] All %0d pixels match perfectly!", checked);
        else
            $display("[FAIL] There are %0d / %0d mismatched pixels.", errors, checked);
        $display("==================================================");
    endtask

endmodule
