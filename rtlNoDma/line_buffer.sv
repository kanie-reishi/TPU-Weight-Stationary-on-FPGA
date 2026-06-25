`timescale 1ns / 1ps

// ============================================================================
// Module: line_buffer
// Description: Local SRAM Circular Line Buffer for Processing Element Array.
//              Automatically handles modulo row mapping.
// ============================================================================
module line_buffer #(
    parameter MAX_WIDTH = 32,
    parameter KERNEL_SIZE = 5,
    parameter DATA_WIDTH = 128
)(
    input  logic clk,
    
    input  logic rst_n,
    // Control signals
    input  logic stream_en, // FSM báo hiệu đang stream ảnh
    input  logic [$clog2(MAX_WIDTH)-1:0] img_width, // Width thực tế
    // Write Interface (From IFM SRAM)
    input  logic pixel_valid_in,
    input  logic [DATA_WIDTH-1:0] pixel_in,
    
    // Read Interface (To Window Router)
    output logic [KERNEL_SIZE-1:0][KERNEL_SIZE-1:0][DATA_WIDTH-1:0] window_data_out
);
    //================================================//
    //                  1.Declaration                 //
    //================================================//
    // Khai báo 4 LUTRAM cho Delay Lines
    localparam LB_DEPTH = MAX_WIDTH;

    (* ram_style = "distributed" *) logic [DATA_WIDTH-1:0] r_lb_1[LB_DEPTH-1:0];
    (* ram_style = "distributed" *) logic [DATA_WIDTH-1:0] r_lb_2[LB_DEPTH-1:0];
    (* ram_style = "distributed" *) logic [DATA_WIDTH-1:0] r_lb_3[LB_DEPTH-1:0];
    (* ram_style = "distributed" *) logic [DATA_WIDTH-1:0] r_lb_4[LB_DEPTH-1:0];

    initial begin
        for (int i = 0; i < LB_DEPTH; i++) begin
            r_lb_1[i] = '0;
            r_lb_2[i] = '0;
            r_lb_3[i] = '0;
            r_lb_4[i] = '0;
        end
    end
    
    // Khai báo 25 Flip-Flops cho Window Array
    logic [DATA_WIDTH-1:0] r_window_arr[KERNEL_SIZE-1:0][KERNEL_SIZE-1:0];
    // Logic con trỏ col_ptr (0 -> img_width-1)
    logic [$clog2(MAX_WIDTH)-1:0] r_col_ptr;
    // =========================================================
    // LOGIC CON TRỎ COL_PTR (DELAY LINE POINTER)
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_col_ptr <= '0;
        end else if (stream_en) begin
            // Đếm quay vòng dựa trên width thực tế của Layer hiện tại
            if (r_col_ptr == img_width - 1) begin
                r_col_ptr <= '0;
            end else begin
                r_col_ptr <= r_col_ptr + 1'b1;
            end
        end
    end
    
    // =========================================================
    // LOGIC THÁC NƯỚC (WATERFALL SHIFT & RAM DELAY)
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset toàn bộ Window Array về 0
            for(int r = 0; r < KERNEL_SIZE; r++) begin
                for(int c = 0; c < KERNEL_SIZE; c++) begin
                    r_window_arr[r][c] <= '0;
                end
            end
        end else if (stream_en) begin
            // Bước 1: Dịch chuyển các cột trong Window sang Trái
            // (Cột 0 nhận từ cột 1, cột 1 nhận từ cột 2)
            for(int r = 0; r < KERNEL_SIZE; r++) begin
                for(int c = 0; c < KERNEL_SIZE -1 ; c++) begin
                    r_window_arr[r][c] <= r_window_arr[r][c+1];
                end
            end

            // Hàng 0: Lấy từ pixel_in
            r_window_arr[0][4]  <= pixel_in;
            r_lb_1[r_col_ptr] <= pixel_in;          // Đổ THẲNG xuống hầm ngầm 0

            // Hàng 1: Lấy từ hầm ngầm 0 trồi lên
            r_window_arr[1][4]  <= r_lb_1[r_col_ptr];
            r_lb_2[r_col_ptr] <= r_lb_1[r_col_ptr]; // Đổ TIẾP xuống hầm ngầm 1

            // Hàng 2: Lấy từ hầm ngầm 1 trồi lên
            r_window_arr[2][4]  <= r_lb_2[r_col_ptr];
            r_lb_3[r_col_ptr] <= r_lb_2[r_col_ptr]; // Đổ TIẾP xuống hầm ngầm 2

            // Hàng 3: Lấy từ hầm ngầm 2 trồi lên
            r_window_arr[3][4]  <= r_lb_3[r_col_ptr];
            r_lb_4[r_col_ptr] <= r_lb_3[r_col_ptr]; // Đổ TIẾP xuống hầm ngầm 3

            // Hàng 4: Lấy từ hầm ngầm 3 trồi lên (Hàng cuối cùng không có RAM ngầm bên dưới)
            r_window_arr[4][4]  <= r_lb_4[r_col_ptr];
        end
    end

    // Gắn mảng thanh ghi nội bộ ra cổng output
    genvar r, c;
    generate
        for (r = 0; r < KERNEL_SIZE; r++) begin : gen_r
            for (c = 0; c < KERNEL_SIZE; c++) begin : gen_c
                assign window_data_out[r][c] = r_window_arr[r][c];
            end
        end
    endgenerate
endmodule
