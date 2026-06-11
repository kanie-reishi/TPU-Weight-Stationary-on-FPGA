`timescale 1ns / 1ps

// ============================================================================
// OFM Post-Processor
// Pipeline 3-stage: Read PSUM → Add Bias + Right Shift → Clamp + ReLU
// Throughput: 1 output pixel/cycle (after 2-cycle pipeline latency)
//
// Luồng dữ liệu:
//   Stage 1: Phát lệnh đọc PSUM buffer (1 cycle BRAM latency)
//   Stage 2: Cộng bias (sign-extend 16→32) + arithmetic right shift (registered)
//   Stage 3: Saturating clamp [-128,127] + ReLU → ghi OFM SRAM (combinational)
// ============================================================================

module ofm_post_processor #(
    parameter PSUM_ADDR_W = 10,
    parameter OFM_ADDR_W  = 16
)(
    input  logic clk,
    input  logic rst_n,

    // ---- Control ----
    input  logic        start,           // Pulse kích hoạt post-processing
    output logic        done,            // Pulse báo hoàn thành (pixel cuối đã ghi)

    // ---- Configuration (ổn định trong suốt quá trình xử lý) ----
    input  logic        reg_relu_en,
    input  logic [4:0]  reg_right_shift,
    input  logic [PSUM_ADDR_W-1:0] reg_out_pixels, // Tổng số output pixels (out_w × out_h)

    // ---- Bias (đã nạp sẵn trước khi start) ----
    input  logic [15:0][15:0] bias_data, // 16 giá trị bias signed 16-bit

    // ---- OFM Address Config ----
    input  logic [OFM_ADDR_W-1:0] ofm_base_addr,   // Địa chỉ gốc (= cout_tile_id)
    input  logic [OFM_ADDR_W-1:0] ofm_addr_stride,  // Bước nhảy (= ceil(Cout/16))

    // ---- PSUM Buffer Read Interface ----
    output logic                   psum_re,
    output logic [PSUM_ADDR_W-1:0] psum_rd_addr,
    input  logic [15:0][31:0]      psum_rdata,      // 16 channels × 32-bit accumulated psum

    // ---- OFM Write Interface ----
    output logic                   ofm_we,
    output logic [OFM_ADDR_W-1:0]  ofm_addr,
    output logic [15:0][7:0]       ofm_data
);

    // =========================================================================
    // 1. FSM
    // =========================================================================
    typedef enum logic [1:0] {
        PP_IDLE    = 2'd0,
        PP_RUNNING = 2'd1,
        PP_DRAIN   = 2'd2
    } pp_state_t;

    pp_state_t r_state;

    // Bộ đếm pixel (Stage 1)
    logic [PSUM_ADDR_W-1:0] r_pixel_cnt;
    logic w_reading;
    assign w_reading = (r_state == PP_RUNNING);

    // Bộ đếm drain (2 cycles cho pipeline flush)
    logic [1:0] r_drain_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_state     <= PP_IDLE;
            r_pixel_cnt <= '0;
            r_drain_cnt <= '0;
        end else begin
            case (r_state)
                PP_IDLE: begin
                    if (start) begin
                        r_state     <= PP_RUNNING;
                        r_pixel_cnt <= '0;
                    end
                end

                PP_RUNNING: begin
                    if (r_pixel_cnt == reg_out_pixels - 1) begin
                        r_state     <= PP_DRAIN;
                        r_drain_cnt <= '0;
                    end else begin
                        r_pixel_cnt <= r_pixel_cnt + 1;
                    end
                end

                PP_DRAIN: begin
                    if (r_drain_cnt == 2'd1) begin
                        r_state <= PP_IDLE;
                    end else begin
                        r_drain_cnt <= r_drain_cnt + 1;
                    end
                end

                default: r_state <= PP_IDLE;
            endcase
        end
    end

    // Done pulse: bật ở chu kỳ cuối của PP_DRAIN (pixel cuối cùng đã ghi ra OFM)
    assign done = (r_state == PP_DRAIN) && (r_drain_cnt == 2'd1);

    // =========================================================================
    // 2. Stage 1: Phát lệnh đọc PSUM Buffer
    // =========================================================================
    assign psum_re      = w_reading;
    assign psum_rd_addr = r_pixel_cnt;

    // Bộ tích lũy địa chỉ OFM (cộng dồn stride mỗi pixel)
    logic [OFM_ADDR_W-1:0] r_ofm_addr_acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_ofm_addr_acc <= '0;
        end else if (start) begin
            r_ofm_addr_acc <= ofm_base_addr;
        end else if (w_reading) begin
            r_ofm_addr_acc <= r_ofm_addr_acc + ofm_addr_stride;
        end
    end

    // =========================================================================
    // 3. Pipeline Register: Stage 1 → Stage 2 (Căn chỉnh trễ BRAM 1 cycle)
    // =========================================================================
    logic r_s2_valid;
    logic [OFM_ADDR_W-1:0] r_s2_addr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_s2_valid <= 1'b0;
            r_s2_addr  <= '0;
        end else begin
            r_s2_valid <= w_reading;
            r_s2_addr  <= r_ofm_addr_acc;
        end
    end

    

    
    // Mở file và ghi log
    integer fd;
    initial begin
        fd = $fopen("hardware_raw_psum.log", "w");
        if (fd == 0) $display("Error opening hardware_raw_psum.log");
    end

    always_ff @(posedge clk) begin
        if (r_s2_valid) begin
            $fdisplay(fd, "ofm_addr: %0d", r_s2_addr);
            for (int i = 0; i < 16; i++) begin
                $fdisplay(fd, "  [%0d]: PSUM=%0d, BIAS=%0d, temp_sum=%0d, temp_shifted=%0d", i, $signed(psum_rdata[i]), $signed({{16{bias_data[i][15]}}, bias_data[i]}), 
                    $signed(psum_rdata[i]) + $signed({{16{bias_data[i][15]}}, bias_data[i]}),
                    ($signed(psum_rdata[i]) + $signed({{16{bias_data[i][15]}}, bias_data[i]})) >>> reg_right_shift
                );
            end
        end
    end

        // =========================================================================
    // CODE CŨ (Đã comment lại để debug raw psum)
    // 4. Stage 2: Cộng Bias (sign-extend 16→32) + Arithmetic Right Shift
    //    Input: psum_rdata (valid 1 cycle sau lệnh đọc BRAM)
    //    Output: r_s3_shifted (registered)
    // =========================================================================
    logic r_s3_valid;
    logic [OFM_ADDR_W-1:0] r_s3_addr;
    logic signed [15:0][31:0] r_s3_shifted;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_s3_valid   <= 1'b0;
            r_s3_addr    <= '0;
            r_s3_shifted <= '0;
        end else begin
            r_s3_valid <= r_s2_valid;
            r_s3_addr  <= r_s2_addr;

            for (int i = 0; i < 16; i++) begin
                logic signed [31:0] temp_sum;
                logic signed [31:0] temp_shifted;
                temp_sum = $signed(psum_rdata[i]) + $signed({{16{bias_data[i][15]}}, bias_data[i]});
                temp_shifted = temp_sum >>> reg_right_shift;
                r_s3_shifted[i] <= temp_shifted;
            end
        end
    end

    // =========================================================================
    // 5. Stage 3: Saturating Clamp [-128, 127] + ReLU [0, 127] (combinational)
    // =========================================================================
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi++) begin : gen_clamp_relu
            logic signed [7:0] w_clamped;

            // Saturating clamp về dải signed 8-bit
            assign w_clamped = ($signed(r_s3_shifted[gi]) > 32'sd127)  ? 8'sd127  :
                               ($signed(r_s3_shifted[gi]) < -32'sd128) ? -8'sd128 :
                               r_s3_shifted[gi][7:0];

            // ReLU: ép giá trị âm về 0
            assign ofm_data[gi] = (reg_relu_en && w_clamped[7]) ? 8'd0 : w_clamped;
        end
    endgenerate

    assign ofm_we   = r_s3_valid;
    assign ofm_addr = r_s3_addr;

    // DEBUG LOGS
    always_ff @(posedge clk) begin
        if (r_s2_valid && r_s2_addr < 16) begin
            $display("[OFM_PP_DEBUG] Raw hardware psums at addr=%0d (Stage 2):", r_s2_addr);
            for (int i = 0; i < 16; i++) begin
                $display("  chan %0d: raw_hw_psum=%0d", i, $signed(psum_rdata[i]));
            end
        end
        if (ofm_we && ofm_addr < 16) begin
            $display("[OFM_PP] ofm_addr=%0d Detailed Channel Stats:", ofm_addr);
            for (int i = 0; i < 16; i++) begin
                $display("  chan %0d: shifted=%0d, ofm_data=%0d",
                         i, $signed(r_s3_shifted[i]), $signed(ofm_data[i]));
            end
        end
        if (start) begin
            $display("[OFM_PP] START asserted | reg_out_pixels=%0d", reg_out_pixels);
        end
        if (done) begin
            $display("[OFM_PP] DONE asserted");
        end
    end

endmodule
