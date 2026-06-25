`timescale 1ns / 1ps

module pea_top #(
    parameter DATA_WIDTH = 8,
    parameter PSUM_WIDTH = 32,
    parameter ADDR_WIDTH = 16
)(
    input  logic clk,
    input  logic rst_n,

    // Controller Interface
    input  logic ctrl_start,
    output logic ctrl_done,

    // Configuration Interface
    input  logic [15:0] cfg_addr,
    input  logic [31:0] cfg_data,
    input  logic        cfg_we,

    // Memory Interface: Weight & Bias Bank (Read)
    output logic [ADDR_WIDTH-1:0] wb_read_addr,
    output logic                  wb_re,
    input  logic [15:0][7:0]      wb_read_data,
    
    // Memory Interface: IFM Buffer (Read)
    output logic [ADDR_WIDTH-1:0] ifm_read_addr,
    output logic                  ifm_re,
    input  logic [15:0][7:0]      ifm_read_data,

    // Memory Interface: OFM Buffer (Write)
    output logic [ADDR_WIDTH-1:0] ofm_write_addr,
    output logic                  ofm_we,
    output logic [15:0][7:0]      ofm_write_data
);

    // =========================================================================
    // 1. Configuration Register File
    // =========================================================================
    logic [31:0] r_reg_ifm_width;     
    logic [31:0] r_reg_ifm_height;    
    logic [31:0] r_reg_channels_in;   
    logic [31:0] r_reg_channels_out;  
    logic [31:0] r_reg_kernel_size;   
    logic [4:0]  r_reg_right_shift;   
    logic [31:0] r_reg_row_stride;    
    logic [31:0] r_reg_col_stride;    
    logic [31:0] r_reg_weight_base;   
    logic [31:0] r_reg_bias_base;     
    logic        r_reg_relu_en;
    logic        r_reg_pool_en;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_reg_ifm_width    <= '0;
            r_reg_ifm_height   <= '0;
            r_reg_channels_in  <= '0;
            r_reg_channels_out <= '0;
            r_reg_kernel_size  <= '0;
            r_reg_right_shift  <= '0;
            r_reg_row_stride   <= '0;
            r_reg_col_stride   <= '0;
            r_reg_weight_base  <= '0;
            r_reg_bias_base    <= '0;
            r_reg_relu_en      <= 1'b0;
            r_reg_pool_en      <= 1'b0;
        end else if (cfg_we) begin
            case (cfg_addr)
                16'h0100: r_reg_ifm_width    <= cfg_data;
                16'h0104: r_reg_ifm_height   <= cfg_data;
                16'h0108: r_reg_channels_in  <= cfg_data;
                16'h010C: r_reg_channels_out <= cfg_data;
                16'h0110: r_reg_kernel_size  <= cfg_data;
                16'h0114: r_reg_right_shift  <= cfg_data[4:0];
                16'h0118: r_reg_row_stride   <= cfg_data;
                16'h011C: r_reg_col_stride   <= cfg_data;
                16'h0120: r_reg_weight_base  <= cfg_data;
                16'h0124: r_reg_bias_base    <= cfg_data;
                16'h0128: r_reg_relu_en      <= cfg_data[0];
                16'h012C: r_reg_pool_en      <= cfg_data[0];
            endcase
        end
    end

    // =========================================================================
    // 2. KHAI BÁO TÍN HIỆU (WIRING & SIGNALS)
    // =========================================================================
    // Hằng số cho kiến trúc
    localparam MAX_IFM_WIDTH = 32;
    localparam KERNEL_SIZE = 5;
    localparam PSUM_ADDR_W = 10; // 10-bit cho phép lưu tối đa 1024 PSUM (C1 cần 28x28 = 784)

    // Datapath Wires (Luồng dữ liệu)
    logic [KERNEL_SIZE-1:0][KERNEL_SIZE-1:0][127:0] w_window_data;
    logic w_is_valid_window;
    logic w_valid_stream_window;
    logic w_is_valid_window_d1, w_is_valid_window_d2, w_is_valid_window_d3;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_is_valid_window_d1 <= 1'b0;
            w_is_valid_window_d2 <= 1'b0;
            w_is_valid_window_d3 <= 1'b0;
        end else begin
            w_is_valid_window_d1 <= w_is_valid_window;
            w_is_valid_window_d2 <= w_is_valid_window_d1;
            w_is_valid_window_d3 <= w_is_valid_window_d2;
        end
    end
    logic [15:0][7:0]  w_routed_data;
    logic [15:0][7:0]  w_routed_data_delayed; // Pipeline register (Delay 1 clock)

    logic [15:0][31:0] w_psum_to_top;
    logic [15:0][31:0] w_psum_from_bottom;
    logic [15:0]       w_psum_en_bottom;

    // FSM Control Wires (Các dây này sẽ được FSM điều khiển ở phần dưới)
    logic        w_stream_en;
    logic        w_stream_en_delayed;
    logic [4:0]  w_current_pass_id;
    logic        w_is_first_pass;
    logic        w_psum_re;
    logic        w_psum_we;
    logic [PSUM_ADDR_W-1:0] w_psum_read_addr;
    logic [PSUM_ADDR_W-1:0] w_psum_write_addr;
    
    logic [15:0] w_load_weight_en;
    logic        w_swap_weight;
    logic [15:0] w_data_en_left;
    logic [15:0] w_psum_en_top;

    // Giải mã địa chỉ Microcode (Giả sử Microcode RAM nằm ở địa chỉ >= 0x0200)
    logic        w_microcode_we;
    assign w_microcode_we = cfg_we && (cfg_addr >= 16'h0200);

    // Post-Processor Signals
    logic [15:0][15:0] r_bias_data;      // 16 bias values, 16-bit each (nạp từ Weight Bank)
    logic [1:0]        r_pp_bias_cnt;    // Bộ đếm sub-state đọc bias
    logic              r_pp_start;       // Xung kích hoạt post-processor
    logic              w_pp_done;        // Post-processor báo hoàn thành
    logic              w_pp_psum_re;     // PP → PSUM buffer read enable
    logic [PSUM_ADDR_W-1:0] w_pp_psum_rd_addr; // PP → PSUM buffer read address
    logic              w_pp_ofm_we;      // PP → OFM write enable
    logic [ADDR_WIDTH-1:0] w_pp_ofm_addr;// PP → OFM write address
    logic [15:0][7:0]  w_pp_ofm_data;    // PP → OFM write data
    logic              r_computation_done;// Cờ báo đã xong toàn bộ tiles
    logic              w_delay_chain_empty; // Delay chain PSUM write đã rỗng

    // =========================================================================
    // 3. PIPELINE ALIGNMENT (ĐỒNG BỘ TRỄ 1 CLOCK)
    // =========================================================================
    // Delay registers for implicit declarations
    logic [15:0] w_load_weight_en_delayed;
    logic [15:0] w_data_en_left_delayed;
    logic [15:0] w_psum_en_top_delayed;
    // IFM Data phải bị làm trễ 1 clock để đợi BRAM nhả PSUM ra
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_routed_data_delayed <= '0;
        end else begin
            w_routed_data_delayed <= w_routed_data;
        end
    end

    // =========================================================================
    // 4. INSTANTIATE DATAPATH BLOCKS
    // =========================================================================
    line_buffer #(
        .MAX_WIDTH (MAX_IFM_WIDTH),
        .KERNEL_SIZE (KERNEL_SIZE),
        .DATA_WIDTH (128)
    ) u_line_buffer (
        .clk               (clk),
        .rst_n             (rst_n),
        .stream_en         (w_stream_en_delayed),
        .img_width         (r_reg_ifm_width[$clog2(MAX_IFM_WIDTH)-1:0]), // Input động từ Register file
        .pixel_in          (ifm_read_data),
        .window_data_out   (w_window_data)
    );

    window_router #(
        .DATA_WIDTH(128),
        .KERNEL_SIZE(5)
    ) u_window_router (
        .clk             (clk),
        .i_cfg_we        (cfg_we),
        .i_cfg_addr      (cfg_addr),
        .i_cfg_data      (cfg_data),
        .i_current_pass_id (w_current_pass_id),
        .window_in       (w_window_data),
        .routed_data_out (w_routed_data)
    );

    pea_systolic_16x16 u_systolic_core (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .load_weight_en        (w_load_weight_en_delayed),
        .weight_in_top         (wb_read_data),
        .swap_weight_in_global (w_swap_weight),
        .data_en_left          (w_data_en_left_delayed),
        .data_in_left          (w_routed_data_delayed),
        .psum_en_top           (w_psum_en_top_delayed),
        .psum_in_top           (w_psum_to_top),     // From BRAM
        .psum_out_bottom       (w_psum_from_bottom),// To BRAM
        .psum_en_bottom        (w_psum_en_bottom)
    );

    psum_buffer u_psum_bram (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .is_first_pass          (w_is_first_pass),
        .psum_re                (w_psum_re),
        .psum_we                (w_psum_we),
        .read_addr              (w_psum_read_addr),
        .write_addr             (w_psum_write_addr),
        .psum_from_bottom       (w_psum_from_bottom),
        .psum_to_top            (w_psum_to_top)
    );

    // =========================================================================
    // 5. FSM & Control
    // =========================================================================

    typedef enum logic [3:0] {
        ST_IDLE         = 4'd0,
        ST_LOAD_WEIGHT  = 4'd1,
        ST_WARM_UP      = 4'd2,
        ST_STREAM       = 4'd3,
        ST_FLUSH        = 4'd4,
        ST_CHECK_PASS   = 4'd5,
        ST_POST_PROC    = 4'd6,
        ST_PP_DRAIN     = 4'd7
    } state_t;

    state_t r_state, w_next_state;

    // Hardware Counters
    logic [6:0]  r_cout_tile_cnt; // Đếm Cout Tiles (C1:1, C5:8)
    logic [4:0]  r_pass_id_cnt;   // Đếm số Pass trong 1 Tile (C1:2, C5:25)
    logic [4:0]  r_weight_cnt;    // Đếm 16 nhịp nạp weight
    logic [31:0] r_warmup_cnt;    // Đếm nhịp fill Line Buffer
    logic [31:0] r_stream_cnt;    // Đếm tổng số pixel IFM đã đọc trong 1 pass
    logic [15:0] r_col_cnt;       // Đếm toạ độ X của pixel đang chui vào Line Buffer
    logic [6:0]  r_flush_cnt;     // Đếm 48 nhịp flush pipeline PEA

    // Các bộ đếm quản lý Địa chỉ bộ nhớ PSUM BRAM
    logic [PSUM_ADDR_W-1:0] r_psum_rd_ptr; // Con trỏ đọc psum chuẩn (0 -> out_w*out_h-1)

    // AUTOMATIC THRESHOLD CALCULATIONS
    logic [4:0]  w_num_passes;
    logic [6:0]  w_max_cout_tiles;
    logic [31:0] w_warmup_threshold;
    logic [31:0] w_total_ifm_pixels;
    logic [PSUM_ADDR_W-1:0] w_max_output_pixels;

    always_comb begin
        // Tính số passes = ceil(Cin * (K*K) / 16) -> Dùng dịch bit, không dùng chia
        w_num_passes     = ((r_reg_channels_in * r_reg_kernel_size * r_reg_kernel_size) + 15) >> 4;
        
        // Tính số Cout Tiles = ceil(Cout / 16)
        w_max_cout_tiles = (r_reg_channels_out + 15) >> 4;
        
        // Ngung Warm-up = (K-1)*Width + K
        w_warmup_threshold = (r_reg_kernel_size - 1) * r_reg_ifm_width + r_reg_kernel_size;
        
        // Tổng số pixel IFM của 1 ảnh = Width * Height
        w_total_ifm_pixels = r_reg_ifm_width * r_reg_ifm_height;
        
        // Tổng số lượng điểm ảnh kết quả (OFM) = out_width * out_height
        w_max_output_pixels = (r_reg_ifm_width - (r_reg_kernel_size - 1)) * (r_reg_ifm_height - (r_reg_kernel_size - 1)); 

        // Cửa sổ hợp lệ (Chỉ bật khi đang WARM_UP hoặc STREAM để tránh gối đầu từ LOAD_WEIGHT cho 1x1)
        w_is_valid_window = (r_state == ST_WARM_UP || r_state == ST_STREAM) && (r_col_cnt >= r_reg_kernel_size - 1);

        // Tín hiệu combinational: cửa sổ hợp lệ trong trạng thái STREAM
        // Với kernel 1x1 (FC), tap đọc kx=3 cần thêm 1 nhịp để data dịch từ [4]->[3]
        // (warmup chỉ 1 nhịp + line buffer không reset giữa pass => tiêu thụ d2 bị sớm 1 nhịp,
        //  pass 0 đọc cold=0, các pass sau đọc nhầm word pass_id+1). Dùng d3 cho kernel=1.
        w_valid_stream_window = (r_state == ST_STREAM) &&
                                ((r_reg_kernel_size == 32'd1) ? w_is_valid_window_d3
                                                              : w_is_valid_window_d2);
    end

    // DEBUG LOG (Commented out)
    // always_ff @(posedge clk) begin
    //     if (ctrl_start) begin
    //         $display("[PEA_TOP_DEBUG] Starting MAC: IFM_W=%0d, IFM_H=%0d, C_IN=%0d, C_OUT=%0d, w_max_output_pixels=%0d, w_num_passes=%0d, w_max_cout_tiles=%0d",
    //             r_reg_ifm_width, r_reg_ifm_height, r_reg_channels_in, r_reg_channels_out, w_max_output_pixels, w_num_passes, w_max_cout_tiles);
    //     end
    // end

    // =========================================================================
    // 4b. OFM POST-PROCESSOR (Bias + Right Shift + ReLU)
    // =========================================================================
    ofm_post_processor #(
        .PSUM_ADDR_W (PSUM_ADDR_W),
        .OFM_ADDR_W  (ADDR_WIDTH)
    ) u_ofm_pp (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (r_pp_start),
        .done           (w_pp_done),
        .reg_relu_en    (r_reg_relu_en),
        .reg_right_shift(r_reg_right_shift),
        .reg_out_pixels (w_max_output_pixels),
        .bias_data      (r_bias_data),
        .ofm_base_addr  (ADDR_WIDTH'(r_cout_tile_cnt)),
        .ofm_addr_stride(ADDR_WIDTH'(w_max_cout_tiles)),
        .psum_re        (w_pp_psum_re),
        .psum_rd_addr   (w_pp_psum_rd_addr),
        .psum_rdata     (w_psum_to_top),
        .ofm_we         (w_pp_ofm_we),
        .ofm_addr       (w_pp_ofm_addr),
        .ofm_data       (w_pp_ofm_data)
    );

    // Nối output post-processor ra port OFM của pea_top
    assign ofm_we         = w_pp_ofm_we;
    assign ofm_write_addr = w_pp_ofm_addr;
    assign ofm_write_data = w_pp_ofm_data;

    // =========================================================================
    // 7. STATE TRANSITION LOGIC (Sequential Block)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_state <= ST_IDLE;
        end else begin
            r_state <= w_next_state;
        end
    end
    // =========================================================================
    // 8. NEXT STATE LOGIC (Combinational Block)
    // =========================================================================
    always_comb begin
        w_next_state = r_state;
        
        case (r_state)
            ST_IDLE: begin
                if (ctrl_start) w_next_state = ST_LOAD_WEIGHT;
            end
            
            ST_LOAD_WEIGHT: begin
                // Nạp đủ 16 weights cho 16 hàng PE thì chuyển trạng thái
                if (r_weight_cnt == 5'd15) w_next_state = ST_WARM_UP;
            end

            ST_WARM_UP: begin
                // Đợi dòng nước (data) nạp đầy Line Buffer và Window Array
                if (r_warmup_cnt == w_warmup_threshold - 1) w_next_state = ST_STREAM;
            end
            
            ST_STREAM: begin
                // Stream nốt số pixel còn lại sau khi warmup
                // Thoát ST_STREAM ngay khi valid window cuối cùng được nạp vào PEA
                if (w_valid_stream_window && (r_psum_rd_ptr == w_max_output_pixels - 1)) 
                    w_next_state = ST_FLUSH;
            end

            ST_FLUSH: begin
                // Đợi Pipeline PE Array chạy nốt những dữ liệu cuối cùng (delay chain = 64)
                if (r_flush_cnt == 64) w_next_state = ST_CHECK_PASS;
            end

            ST_CHECK_PASS: begin
                // Trạng thái ảo quyết định rẽ nhánh Pass
                if (r_pass_id_cnt < w_num_passes - 1)
                    w_next_state = ST_LOAD_WEIGHT; // Tua lại (Rewind) chạy Pass tiếp theo
                else
                    w_next_state = ST_POST_PROC;   // Đã xong 1 cụm 16 Cout -> Đi xử lý hậu kỳ
            end
            
            ST_POST_PROC: begin
                // Đợi delay chain rỗng, đọc bias, rồi kích Post-Processor
                if (w_delay_chain_empty && r_pp_bias_cnt == 2'd2)
                    w_next_state = ST_PP_DRAIN;
            end

            ST_PP_DRAIN: begin
                // Chờ Post-Processor xử lý xong toàn bộ OFM pixels
                if (w_pp_done) begin
                    if (r_cout_tile_cnt < w_max_cout_tiles - 1)
                        w_next_state = ST_LOAD_WEIGHT;
                    else
                        w_next_state = ST_IDLE;
                end
            end
            
            default: w_next_state = ST_IDLE;
        endcase
    end

    // =========================================================================
    // 9. HARDWARE COUNTERS CONTROL (Sequential Block)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_cout_tile_cnt <= '0;
            r_pass_id_cnt   <= '0;
            r_weight_cnt    <= '0;
            r_warmup_cnt    <= '0;
            r_stream_cnt    <= '0;
            r_psum_rd_ptr   <= '0;
            r_pp_bias_cnt   <= '0;
        end else begin
            case (r_state)
                ST_IDLE: begin
                    r_cout_tile_cnt <= '0;
                    r_pass_id_cnt   <= '0;
                    r_weight_cnt    <= '0;
                    r_warmup_cnt    <= '0;
                    r_stream_cnt    <= '0;
                    r_psum_rd_ptr   <= '0;
                    r_pp_bias_cnt   <= '0;
                    r_flush_cnt     <= '0;
                end
                ST_LOAD_WEIGHT: begin
                    r_weight_cnt <= r_weight_cnt + 1;
                    // Reset các bộ đếm chuẩn bị cho khâu stream ảnh tiếp theo
                    r_warmup_cnt  <= '0;
                    r_stream_cnt  <= '0;
                    r_psum_rd_ptr <= '0;
                    r_col_cnt <= '0;
                    r_flush_cnt <= '0;
                end

                ST_WARM_UP: begin
                    r_weight_cnt <= '0;
                    r_warmup_cnt <= r_warmup_cnt + 1;

                    if(r_col_cnt == r_reg_ifm_width - 1)
                        r_col_cnt <= '0;
                    else 
                        r_col_cnt <= r_col_cnt + 1;
                end
                
                ST_STREAM: begin
                    r_stream_cnt <= r_stream_cnt + 1;
                    
                    if(r_col_cnt == r_reg_ifm_width - 1)
                        r_col_cnt <= '0;
                    else 
                        r_col_cnt <= r_col_cnt + 1;
                        
                end

                ST_FLUSH: begin
                    r_flush_cnt <= r_flush_cnt + 1;
                end

                ST_CHECK_PASS: begin
                    if (r_pass_id_cnt < w_num_passes - 1) begin
                        r_pass_id_cnt <= r_pass_id_cnt + 1;
                    end
                    r_pp_bias_cnt <= '0;
                end
                
                ST_POST_PROC: begin
                    r_pass_id_cnt <= '0;
                    if (w_delay_chain_empty) begin
                        r_pp_bias_cnt <= r_pp_bias_cnt + 1;
                    end
                end

                ST_PP_DRAIN: begin
                    if (w_pp_done) begin
                        if (r_cout_tile_cnt < w_max_cout_tiles - 1) begin
                            r_cout_tile_cnt <= r_cout_tile_cnt + 1;
                        end
                    end
                end
            endcase
            
            if (w_valid_stream_window && (r_psum_rd_ptr < w_max_output_pixels - 1)) begin
                r_psum_rd_ptr <= r_psum_rd_ptr + 1;
            end
        end
    end
    // =========================================================================
    // 10. PSUM WRITE DELAY CHAIN (Đồng bộ với Latency của PEA)
    // =========================================================================
    // Đỗ trễ từ data_en_left đến khi psum_out_bottom valid là 63 nhịp (bao gồm Skew + PE + Deskew) + 1 nhịp.
    logic [63:0][PSUM_ADDR_W-1:0] psum_addr_delay_chain;
    logic [63:0]                 psum_we_delay_chain;

    assign w_delay_chain_empty = (psum_we_delay_chain == '0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            psum_addr_delay_chain <= '0;
            psum_we_delay_chain   <= '0;
        end else begin
            // Đẩy con trỏ đọc hiện tại và lệnh cho phép ghi (we) vào đầu ống
            // Lệnh ghi thực sự (w_psum_we) chỉ xảy ra trong trạng thái STREAM và cửa sổ đã hợp lệ
            psum_addr_delay_chain[0] <= r_psum_rd_ptr;
            psum_we_delay_chain[0]   <= w_valid_stream_window;
            
            // Dịch chuyển đường ống trễ
            for (int i = 1; i < 64; i++) begin
                psum_addr_delay_chain[i] <= psum_addr_delay_chain[i-1];
                psum_we_delay_chain[i]   <= psum_we_delay_chain[i-1];
            end
        end
    end

    // Hàng dữ liệu rút ra ở cuối ống trễ gán vào cổng ghi của BRAM
    assign w_psum_write_addr = psum_addr_delay_chain[63];
    assign w_psum_we         = psum_we_delay_chain[63];

    logic [31:0] cycle_cnt = 0;
    always_ff @(posedge clk) cycle_cnt <= cycle_cnt + 1;

    // =========================================================================
    // 11. DRIVING CONTROL WIRES TO DATAPATH (Driving the Wires from Section 2)
    // =========================================================================
    assign w_stream_en       = (r_state == ST_WARM_UP) || (r_state == ST_STREAM);
    assign w_current_pass_id = r_pass_id_cnt;
    // Chỉ chặn BRAM nạp 0 ở Pass 0 trong giai đoạn streaming (tránh ảnh hưởng post-processing)
    assign w_is_first_pass   = (r_pass_id_cnt == 5'd0) && (r_state == ST_WARM_UP || r_state == ST_STREAM);

    // Mux port đọc PSUM buffer: streaming hoặc post-processor
    assign w_psum_re         = w_valid_stream_window || w_pp_psum_re;
    assign w_psum_read_addr  = w_pp_psum_re ? w_pp_psum_rd_addr : r_psum_rd_ptr;

    // Các tín hiệu kích hoạt lõi Systolic Array
    assign w_load_weight_en  = (r_state == ST_LOAD_WEIGHT) ? 16'hFFFF : 16'h0000;
    assign w_swap_weight     = (r_reg_kernel_size == 32'd1) ? 
                               ((r_state == ST_STREAM) && (r_stream_cnt == 32'd0)) :
                               ((r_state == ST_WARM_UP) && (r_warmup_cnt == 32'd1));
    
    assign w_data_en_left    = w_valid_stream_window ? 16'hFFFF : 16'h0000;
    assign w_psum_en_top     = w_valid_stream_window ? 16'hFFFF : 16'h0000;

    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_stream_en_delayed    <= '0;
            w_data_en_left_delayed <= '0;
            w_psum_en_top_delayed  <= '0;
            w_load_weight_en_delayed <= '0;
        end else begin
            w_stream_en_delayed    <= w_stream_en;
            w_data_en_left_delayed <= w_data_en_left;
            w_psum_en_top_delayed  <= w_psum_en_top;
            w_load_weight_en_delayed <= w_load_weight_en;
        end
    end

    // Giao diện SRAM Bộ nhớ ngoài (Rewind tự động bằng bộ đếm r_stream_cnt và r_warmup_cnt)
    assign ifm_re            = w_stream_en;

    logic [ADDR_WIDTH-1:0] w_pass_ifm_base;
    assign w_pass_ifm_base = (r_reg_kernel_size == 1) ? ADDR_WIDTH'(r_pass_id_cnt) : '0;

    // Đọc tuần tự từ địa chỉ gốc của ảnh, khi chuyển Pass bộ đếm tự reset về 0 làm con trỏ tự Rewind!
    assign ifm_read_addr     = w_pass_ifm_base + 
                               ((r_state == ST_WARM_UP) ? ADDR_WIDTH'(r_warmup_cnt) : 
                                (r_state == ST_STREAM)  ? ADDR_WIDTH'(w_warmup_threshold + r_stream_cnt) : '0);

    // Weight SRAM: Mux giữa nạp weight (LOAD_WEIGHT) và đọc bias (POST_PROC)
    assign wb_re             = (r_state == ST_LOAD_WEIGHT) ||
                               (r_state == ST_POST_PROC && w_delay_chain_empty && r_pp_bias_cnt <= 2'd1);
    assign wb_read_addr      = (r_state == ST_POST_PROC) ?
                               (r_reg_bias_base + {r_cout_tile_cnt, r_pp_bias_cnt[0]}) :
                               (r_reg_weight_base + (r_cout_tile_cnt * w_num_passes * 16) + (r_pass_id_cnt * 16) + r_weight_cnt);

    // Khối điều khiển tổng ngoài Core
    assign ctrl_done         = r_computation_done;

    // =========================================================================
    // 12. BIAS READING LOGIC (Đọc 2 word bias 16-bit từ Weight Bank)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_bias_data <= '0;
            r_pp_start  <= 1'b0;
        end else begin
            r_pp_start <= 1'b0; // Mặc định tắt xung

            if (r_state == ST_POST_PROC && w_delay_chain_empty) begin
                case (r_pp_bias_cnt)
                    2'd1: begin
                        // BRAM trả dữ liệu từ lệnh đọc ở cnt=0 → lưu phần thấp của bias cho cả 16 kênh
                        for (int i = 0; i < 16; i++) begin
                            logic [15:0] cur;
                            cur = r_bias_data[i];
                            r_bias_data[i] <= {cur[15:8], wb_read_data[i]};
                        end
                    end
                    2'd2: begin
                        // BRAM trả dữ liệu từ lệnh đọc ở cnt=1 → lưu phần cao của bias cho cả 16 kênh
                        for (int i = 0; i < 16; i++) begin
                            logic [15:0] cur;
                            cur = r_bias_data[i];
                            r_bias_data[i] <= {wb_read_data[i], cur[7:0]};
                        end
                        // Kích hoạt post-processor pipeline
                        r_pp_start <= 1'b1;
                        // $display("[PEA_TOP] Loaded bias_data:");
                        // for (int i = 0; i < 16; i++) begin
                        //     $display("  chan %0d: %0d", i, $signed({wb_read_data[i], r_bias_data[i][7:0]}));
                        // end
                    end
                endcase
            end
        end
    end

    // =========================================================================
    // 13. COMPUTATION DONE FLAG
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_computation_done <= 1'b0;
        end else begin
            if (ctrl_start)
                r_computation_done <= 1'b0;
            else if (r_state == ST_PP_DRAIN && w_pp_done && !(r_cout_tile_cnt < w_max_cout_tiles - 1))
                r_computation_done <= 1'b1;
        end
    end

endmodule
