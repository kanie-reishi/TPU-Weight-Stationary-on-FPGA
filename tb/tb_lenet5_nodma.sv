`timescale 1ns / 1ps

// End-to-end LeNet-5 on rtlNoDma (S_AXIS / M_AXIS data path, trimmed ISA).
`ifndef MAX_IMAGES
`define MAX_IMAGES 100
`endif

module tb_lenet5_nodma();

    localparam AXI_AWIDTH  = 40;
    localparam AXI_DWIDTH  = 64;
    localparam SRAM_DWIDTH = 128;
    localparam SRAM_AWIDTH = 11;

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
    ) uut (
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

    logic [7:0] c1_wgt_mem [0:511];
    logic [7:0] c1_bias_mem [0:31];
    logic [7:0] c3_wgt_mem [0:2559];
    logic [7:0] c3_bias_mem [0:31];
    logic [7:0] c5_wgt_mem [0:51199];
    logic [7:0] c5_bias_mem [0:255];
    logic [7:0] f6_wgt_mem [0:12287];
    logic [7:0] f6_bias_mem [0:191];
    logic [7:0] out_wgt_mem [0:1535];
    logic [7:0] out_bias_mem [0:31];
    logic [7:0] mnist_images_mem [0:`MAX_IMAGES * 16384 - 1];
    logic [7:0] mnist_labels [0:99];

    logic [7:0] c5_ofm_buf [0:127];
    logic [7:0] f6_ofm_buf [0:95];
    logic [7:0] logits_mem [0:`MAX_IMAGES - 1][0:15];
    logic [7:0] stream_scratch [0:51455];

    integer label_file;

    always #5 clk = ~clk;

    initial begin
        #3_600_000_000_000;
        $display("[WATCHDOG] Simulation timeout reached! Force terminating...");
        $finish;
    end

    // =========================================================
    // AXI-Lite BFM
    // =========================================================
    task axi_lite_write(input logic [31:0] addr, input logic [31:0] data);
        begin
            @(posedge clk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;
            do @(posedge clk); while (!(s_axi_awready && s_axi_wready));
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid  <= 1'b0;
            while (!s_axi_bvalid) @(posedge clk);
            s_axi_bready  <= 1'b0;
        end
    endtask

    task axi_lite_read(input logic [31:0] addr, output logic [31:0] data);
        begin
            @(posedge clk);
            s_axi_araddr  <= addr;
            s_axi_arvalid <= 1'b1;
            s_axi_rready  <= 1'b1;
            wait (s_axi_rvalid);
            data = s_axi_rdata;
            @(posedge clk);
            s_axi_arvalid <= 1'b0;
            s_axi_rready  <= 1'b0;
        end
    endtask

    task upload_microcode(input string filename, input int num_passes);
        logic [31:0] mc_mem [0:124];
        begin
            for (int i = 0; i < 125; i++) mc_mem[i] = 32'h0;
            $readmemh(filename, mc_mem);
            for (int p = 0; p < num_passes; p++) begin
                for (int w = 0; w < 5; w++) begin
                    axi_lite_write(32'h0200 + p * 32 + w * 4, mc_mem[p * 5 + w]);
                end
            end
        end
    endtask

    // =========================================================
    // AXI-Stream BFM
    // =========================================================
    task axis_push_inst(input logic [63:0] inst);
        begin
            @(posedge clk);
            s_axis_tvalid <= 1'b1;
            s_axis_tdata  <= {64'b0, inst};
            s_axis_tdest  <= 4'd0;
            s_axis_tlast  <= 1'b1;
            wait (s_axis_tready);
            @(posedge clk);
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
        end
    endtask

    task axis_stream_scratch(input [3:0] tdest, input int num_bytes);
        int total_beats;
        int beat;
        int byte_i;
        logic [127:0] word;
        begin
            total_beats = (num_bytes + 15) / 16;
            for (beat = 0; beat < total_beats; beat++) begin
                word = '0;
                for (int b = 0; b < 16; b++) begin
                    byte_i = beat * 16 + b;
                    if (byte_i < num_bytes)
                        word[b * 8 +: 8] = stream_scratch[byte_i];
                end
                @(posedge clk);
                s_axis_tvalid <= 1'b1;
                s_axis_tdata  <= word;
                s_axis_tdest  <= tdest;
                s_axis_tlast  <= (beat == total_beats - 1);
                wait (s_axis_tready);
            end
            @(posedge clk);
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
        end
    endtask

    task axis_stream_mnist(input int base_idx, input int num_bytes);
        int total_beats;
        int beat;
        int byte_i;
        logic [127:0] word;
        begin
            total_beats = (num_bytes + 15) / 16;
            for (beat = 0; beat < total_beats; beat++) begin
                word = '0;
                for (int b = 0; b < 16; b++) begin
                    byte_i = beat * 16 + b;
                    if (byte_i < num_bytes)
                        word[b * 8 +: 8] = mnist_images_mem[base_idx + byte_i];
                end
                @(posedge clk);
                s_axis_tvalid <= 1'b1;
                s_axis_tdata  <= word;
                s_axis_tdest  <= 4'd2;
                s_axis_tlast  <= (beat == total_beats - 1);
                wait (s_axis_tready);
            end
            @(posedge clk);
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
        end
    endtask

    task axis_stream_c5_ofm(input int num_bytes);
        int total_beats;
        int beat;
        int byte_i;
        logic [127:0] word;
        begin
            total_beats = (num_bytes + 15) / 16;
            for (beat = 0; beat < total_beats; beat++) begin
                word = '0;
                for (int b = 0; b < 16; b++) begin
                    byte_i = beat * 16 + b;
                    if (byte_i < num_bytes)
                        word[b * 8 +: 8] = c5_ofm_buf[byte_i];
                end
                @(posedge clk);
                s_axis_tvalid <= 1'b1;
                s_axis_tdata  <= word;
                s_axis_tdest  <= 4'd2;
                s_axis_tlast  <= (beat == total_beats - 1);
                wait (s_axis_tready);
            end
            @(posedge clk);
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
        end
    endtask

    task axis_stream_f6_ofm(input int num_bytes);
        int total_beats;
        int beat;
        int byte_i;
        logic [127:0] word;
        begin
            total_beats = (num_bytes + 15) / 16;
            for (beat = 0; beat < total_beats; beat++) begin
                word = '0;
                for (int b = 0; b < 16; b++) begin
                    byte_i = beat * 16 + b;
                    if (byte_i < num_bytes)
                        word[b * 8 +: 8] = f6_ofm_buf[byte_i];
                end
                @(posedge clk);
                s_axis_tvalid <= 1'b1;
                s_axis_tdata  <= word;
                s_axis_tdest  <= 4'd2;
                s_axis_tlast  <= (beat == total_beats - 1);
                wait (s_axis_tready);
            end
            @(posedge clk);
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
        end
    endtask

    function automatic logic [31:0] ctrl_bank_to_m_axis(input logic [1:0] bank);
        ctrl_bank_to_m_axis = (bank == 2'b10) ? 32'd1 : 32'd0;
    endfunction

    task m_axis_read_c5(input int num_bytes);
        logic [31:0] rd;
        int words;
        int byte_i;
        begin
            while (1) begin
                axi_lite_read(32'h0000_002C, rd);
                if (!rd[0]) break;
                @(posedge clk);
            end
            axi_lite_read(32'h0000_002D, rd);
            words = (num_bytes + 15) / 16;
            axi_lite_write(32'h0000_0020, ctrl_bank_to_m_axis(rd[1:0]));
            axi_lite_write(32'h0000_0024, words[31:0]);
            axi_lite_write(32'h0000_0028, 32'd1);
            byte_i = 0;
            while (byte_i < num_bytes) begin
                @(posedge clk);
                if (m_axis_tvalid && m_axis_tready) begin
                    for (int b = 0; b < 16 && byte_i < num_bytes; b++) begin
                        c5_ofm_buf[byte_i] = m_axis_tdata[b * 8 +: 8];
                        byte_i++;
                    end
                end
            end
        end
    endtask

    task m_axis_read_f6(input int num_bytes);
        logic [31:0] rd;
        int words;
        int byte_i;
        begin
            while (1) begin
                axi_lite_read(32'h0000_002C, rd);
                if (!rd[0]) break;
                @(posedge clk);
            end
            axi_lite_read(32'h0000_002D, rd);
            words = (num_bytes + 15) / 16;
            axi_lite_write(32'h0000_0020, ctrl_bank_to_m_axis(rd[1:0]));
            axi_lite_write(32'h0000_0024, words[31:0]);
            axi_lite_write(32'h0000_0028, 32'd1);
            byte_i = 0;
            while (byte_i < num_bytes) begin
                @(posedge clk);
                if (m_axis_tvalid && m_axis_tready) begin
                    for (int b = 0; b < 16 && byte_i < num_bytes; b++) begin
                        f6_ofm_buf[byte_i] = m_axis_tdata[b * 8 +: 8];
                        byte_i++;
                    end
                end
            end
        end
    endtask

    task m_axis_read_logits(input int img_idx, input int num_bytes);
        logic [31:0] rd;
        int words;
        int byte_i;
        begin
            while (1) begin
                axi_lite_read(32'h0000_002C, rd);
                if (!rd[0]) break;
                @(posedge clk);
            end
            axi_lite_read(32'h0000_002D, rd);
            words = (num_bytes + 15) / 16;
            axi_lite_write(32'h0000_0020, ctrl_bank_to_m_axis(rd[1:0]));
            axi_lite_write(32'h0000_0024, words[31:0]);
            axi_lite_write(32'h0000_0028, 32'd1);
            byte_i = 0;
            while (byte_i < num_bytes) begin
                @(posedge clk);
                if (m_axis_tvalid && m_axis_tready) begin
                    for (int b = 0; b < 16 && byte_i < num_bytes; b++) begin
                        logits_mem[img_idx][byte_i] = m_axis_tdata[b * 8 +: 8];
                        byte_i++;
                    end
                end
            end
        end
    endtask

    task pulse_layer_reset();
        begin
            rst_n = 0;
            #50;
            rst_n = 1;
            #100;
        end
    endtask

    // =========================================================
    // Layer drivers (stream + trimmed ISA)
    // =========================================================
    task run_c1_nodma(input int img_idx);
        begin
            for (int i = 0; i < 512; i++) stream_scratch[i] = c1_wgt_mem[i];
            for (int i = 0; i < 32; i++)  stream_scratch[512 + i] = c1_bias_mem[i];
            axis_stream_scratch(4'd1, 544);
            axis_stream_mnist(img_idx * 16384, 16384);
            axis_push_inst({4'h2, 12'h0, 16'd32, 16'd32, 16'd1});
            axis_push_inst({4'h3, 28'h0, 16'd6, 8'd5, 4'd1, 4'd12});
            axis_push_inst({4'h5, 59'h0, 1'b1});
            axis_push_inst({4'h2, 12'h0, 16'd28, 16'd28, 16'd6});
            axis_push_inst({4'h6, 50'h0, 2'b00, 8'd2});
            axis_push_inst({4'hF, 60'h0});
        end
    endtask

    task run_c3_nodma();
        begin
            for (int i = 0; i < 2560; i++) stream_scratch[i] = c3_wgt_mem[i];
            for (int i = 0; i < 32; i++)   stream_scratch[2560 + i] = c3_bias_mem[i];
            axis_stream_scratch(4'd1, 2592);
            axis_push_inst({4'h2, 12'h0, 16'd14, 16'd14, 16'd6});
            axis_push_inst({4'h3, 28'h0, 16'd16, 8'd5, 4'd1, 4'd9});
            axis_push_inst({4'h5, 59'h0, 1'b1});
            axis_push_inst({4'h2, 12'h0, 16'd10, 16'd10, 16'd16});
            axis_push_inst({4'h6, 50'h0, 2'b00, 8'd2});
            axis_push_inst({4'hF, 60'h0});
        end
    endtask

    task run_c5_nodma();
        begin
            for (int i = 0; i < 51200; i++) stream_scratch[i] = c5_wgt_mem[i];
            for (int i = 0; i < 256; i++)   stream_scratch[51200 + i] = c5_bias_mem[i];
            axis_stream_scratch(4'd1, 51456);
            axis_push_inst({4'h2, 12'h0, 16'd5, 16'd5, 16'd16});
            axis_push_inst({4'h3, 28'h0, 16'd120, 8'd5, 4'd1, 4'd10});
            axis_push_inst({4'h5, 59'h0, 1'b1});
            axis_push_inst({4'hF, 60'h0});
        end
    endtask

    task run_f6_nodma();
        begin
            axis_stream_c5_ofm(128);
            for (int i = 0; i < 12288; i++) stream_scratch[i] = f6_wgt_mem[i];
            for (int i = 0; i < 192; i++)   stream_scratch[12288 + i] = f6_bias_mem[i];
            axis_stream_scratch(4'd1, 12480);
            axis_push_inst({4'h2, 12'h0, 16'd1, 16'd1, 16'd120});
            axis_push_inst({4'h3, 28'h0, 16'd84, 8'd1, 4'd1, 4'd7});
            axis_push_inst({4'h5, 59'h0, 1'b1});
            axis_push_inst({4'hF, 60'h0});
        end
    endtask

    task run_out_nodma();
        begin
            axis_stream_f6_ofm(96);
            for (int i = 0; i < 1536; i++) stream_scratch[i] = out_wgt_mem[i];
            for (int i = 0; i < 32; i++)   stream_scratch[1536 + i] = out_bias_mem[i];
            axis_stream_scratch(4'd1, 1568);
            axis_push_inst({4'h2, 12'h0, 16'd1, 16'd1, 16'd84});
            axis_push_inst({4'h3, 28'h0, 16'd10, 8'd1, 4'd1, 4'd7});
            axis_push_inst({4'h5, 59'h0, 1'b0});
            axis_push_inst({4'hF, 60'h0});
        end
    endtask

    // =========================================================
    // Main
    // =========================================================
    initial begin
        int correct_predictions;
        correct_predictions = 0;

        clk = 0;
        rst_n = 0;
        s_axi_awvalid = 0;
        s_axi_wvalid  = 0;
        s_axi_arvalid = 0;
        s_axi_rready  = 0;
        s_axi_bready  = 0;
        s_axis_tvalid = 0;
        s_axis_tdata  = 0;
        s_axis_tlast  = 0;
        s_axis_tdest  = 0;
        m_axis_tready = 1;

        $display("==================================================");
        $display("   [INIT] rtlNoDma LeNet-5 — loading hex data...");
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
            if ($fscanf(label_file, "%d\n", val) != 1) begin
                $display("[ERROR] Short read on mnist_labels.txt at line %0d", i);
                $finish;
            end
            mnist_labels[i] = val[7:0];
        end
        $fclose(label_file);

        #200;
        rst_n = 1;
        #200;

        $display("==================================================");
        $display("   STARTING rtlNoDma LENET-5 (%0d images)", `MAX_IMAGES);
        $display("==================================================");

        for (int img_idx = 0; img_idx < `MAX_IMAGES; img_idx++) begin
            $display("[IMAGE %0d/%0d] Label: %0d", img_idx + 1, `MAX_IMAGES, mnist_labels[img_idx]);

            // C1
            upload_microcode("c1_mc.hex", 2);
            axi_lite_write(32'h0100, 32);
            axi_lite_write(32'h0104, 32);
            axi_lite_write(32'h0108, 1);
            axi_lite_write(32'h010C, 6);
            axi_lite_write(32'h0110, 5);
            axi_lite_write(32'h0114, 12);
            axi_lite_write(32'h0120, 0);
            axi_lite_write(32'h0124, 32);
            axi_lite_write(32'h0128, 1);
            run_c1_nodma(img_idx);
            wait (finish_irq_o);
            #100;
            pulse_layer_reset();

            // C3
            upload_microcode("c3_mc.hex", 10);
            axi_lite_write(32'h0100, 14);
            axi_lite_write(32'h0104, 14);
            axi_lite_write(32'h0108, 6);
            axi_lite_write(32'h010C, 16);
            axi_lite_write(32'h0110, 5);
            axi_lite_write(32'h0114, 9);
            axi_lite_write(32'h0120, 0);
            axi_lite_write(32'h0124, 160);
            axi_lite_write(32'h0128, 1);
            run_c3_nodma();
            wait (finish_irq_o);
            #100;
            pulse_layer_reset();

            // C5
            upload_microcode("c5_mc.hex", 25);
            axi_lite_write(32'h0100, 5);
            axi_lite_write(32'h0104, 5);
            axi_lite_write(32'h0108, 16);
            axi_lite_write(32'h010C, 120);
            axi_lite_write(32'h0110, 5);
            axi_lite_write(32'h0114, 10);
            axi_lite_write(32'h0120, 0);
            axi_lite_write(32'h0124, 3200);
            axi_lite_write(32'h0128, 1);
            run_c5_nodma();
            wait (finish_irq_o);
            #100;
            m_axis_read_c5(128);
            pulse_layer_reset();

            // F6
            upload_microcode("f6_mc.hex", 8);
            axi_lite_write(32'h0100, 1);
            axi_lite_write(32'h0104, 1);
            axi_lite_write(32'h0108, 120);
            axi_lite_write(32'h010C, 84);
            axi_lite_write(32'h0110, 1);
            axi_lite_write(32'h0114, 7);
            axi_lite_write(32'h0120, 0);
            axi_lite_write(32'h0124, 768);
            axi_lite_write(32'h0128, 1);
            run_f6_nodma();
            wait (finish_irq_o);
            #100;
            m_axis_read_f6(96);
            pulse_layer_reset();

            // OUT
            upload_microcode("out_mc.hex", 6);
            axi_lite_write(32'h0100, 1);
            axi_lite_write(32'h0104, 1);
            axi_lite_write(32'h0108, 84);
            axi_lite_write(32'h010C, 10);
            axi_lite_write(32'h0110, 1);
            axi_lite_write(32'h0114, 7);
            axi_lite_write(32'h0120, 0);
            axi_lite_write(32'h0124, 96);
            axi_lite_write(32'h0128, 0);
            run_out_nodma();
            wait (finish_irq_o);
            #100;
            m_axis_read_logits(img_idx, 16);

            begin
                int max_val;
                int pred;
                max_val = -2147483647 - 1;
                pred = -1;
                for (int c = 0; c < 10; c++) begin
                    int s_val;
                    s_val = $signed(logits_mem[img_idx][c]);
                    if (s_val > max_val) begin
                        max_val = s_val;
                        pred = c;
                    end
                end
                $display("  => Logits: [%d, %d, %d, %d, %d, %d, %d, %d, %d, %d]",
                         $signed(logits_mem[img_idx][0]), $signed(logits_mem[img_idx][1]),
                         $signed(logits_mem[img_idx][2]), $signed(logits_mem[img_idx][3]),
                         $signed(logits_mem[img_idx][4]), $signed(logits_mem[img_idx][5]),
                         $signed(logits_mem[img_idx][6]), $signed(logits_mem[img_idx][7]),
                         $signed(logits_mem[img_idx][8]), $signed(logits_mem[img_idx][9]));
                if (pred == mnist_labels[img_idx]) begin
                    correct_predictions++;
                    $display("  => Match! Predicted: %0d, Expected: %0d", pred, mnist_labels[img_idx]);
                end else begin
                    $display("  => MISMATCH! Predicted: %0d, Expected: %0d", pred, mnist_labels[img_idx]);
                end
            end

            pulse_layer_reset();
        end

        $display("\n==================================================");
        $display("   FINAL EVALUATION ACCURACY: %0d / %0d", correct_predictions, `MAX_IMAGES);
        $display("==================================================");
        $finish;
    end

endmodule
