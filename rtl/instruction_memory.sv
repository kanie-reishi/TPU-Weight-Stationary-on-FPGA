`timescale 1ns / 1ps

module instruction_fifo #(
    parameter DATA_WIDTH = 64, // Độ rộng 1 lệnh (ISA v2.0)
    parameter ADDR_WIDTH = 6   // Độ sâu FIFO = 2^6 = 64 lệnh
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Giao diện Write (Từ Global Arbiter / CPU Host)
    input  logic                    wr_en,
    input  logic [DATA_WIDTH-1:0]   wr_data,
    output logic                    full,

    // Giao diện Read (Tới Controller)
    input  logic                    rd_en,
    output logic [DATA_WIDTH-1:0]   rd_data,
    output logic                    empty
);

    // Kích thước mảng bộ nhớ: 64 ô, mỗi ô 64 bit
    localparam DEPTH = 1 << ADDR_WIDTH;
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Con trỏ Read và Write (Dư 1 bit MSB để phân biệt Đầy/Rỗng)
    logic [ADDR_WIDTH:0] wr_ptr;
    logic [ADDR_WIDTH:0] rd_ptr;

    // =========================================================
    // 1. LOGIC TRẠNG THÁI (ĐẦY / RỖNG)
    // =========================================================
    // FIFO rỗng khi 2 con trỏ chỉ vào cùng 1 vị trí (kể cả bit MSB)
    assign empty = (wr_ptr == rd_ptr);
    
    // FIFO đầy khi 2 con trỏ chỉ vào cùng vị trí, nhưng bit MSB ngược nhau
    // (nghĩa là con trỏ ghi đã chạy trước con trỏ đọc đúng 1 vòng)
    assign full  = (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH]) && 
                   (wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0]);

    // =========================================================
    // 2. LOGIC ĐỌC DỮ LIỆU (FWFT - First-Word Fall-Through)
    // =========================================================
    // Xuất thẳng dữ liệu tại vị trí con trỏ đọc ra ngoài (Combinational Read).
    // Vivado sẽ tự động map mảng 'mem' này vào Distributed RAM (LUTs).
    assign rd_data = mem[rd_ptr[ADDR_WIDTH-1:0]];

    // =========================================================
    // 3. LOGIC GHI DỮ LIỆU VÀ CẬP NHẬT CON TRỎ
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else begin
            // Xử lý Ghi (Write)
            if (wr_en && !full) begin
                mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;
                wr_ptr <= wr_ptr + 1'b1;
            end
            
            // Xử lý Đọc (Read) - Tăng con trỏ để bỏ qua lệnh hiện tại
            if (rd_en && !empty) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
        end
    end

endmodule