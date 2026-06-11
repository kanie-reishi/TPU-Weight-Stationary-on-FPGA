`timescale 1ns / 1ps

module psum_buffer #(
    parameter ADDR_WIDTH = 10,   // Đủ sức chứa 1024 điểm ảnh
    parameter DATA_WIDTH = 512   // 16 channels * 32-bit 
)(
    input  logic clk,
    input  logic rst_n,
    // Control signals từ FSM
    input  logic is_first_pass, // Cờ báo hiệu Pass 1
    input  logic psum_re,      // Enable đọc
    input  logic psum_we,      // Enable ghi (trễ 16 clock so với re)
    input  logic [ADDR_WIDTH - 1:0] read_addr,  // 0 -> 63
    input  logic [ADDR_WIDTH - 1:0] write_addr, // 0 -> 63
    
    // Input từ đáy PEA
    input  logic [15:0][31:0] psum_from_bottom,
    
    // Output nạp vào đỉnh PEA
    output logic [15:0][31:0] psum_to_top
);
    //=================================================
    // 1. Khai báo BRAM (1024 x 512-bit = 50KB)
    //=================================================
    localparam DEPTH = 1 << ADDR_WIDTH; // 2^10 = 1024
    (*ram_style = "block" *) logic [DATA_WIDTH-1:0] r_psum_bram [0:DEPTH-1];

    logic [DATA_WIDTH-1:0] r_psum_bram_data;

    //=================================================
    // 2. Logic ghi và đọc dữ liệu vào BRAM
    //=================================================
    always_ff @(posedge clk) begin
        // Logic ghi dữ liệu
        if (psum_we) begin
            r_psum_bram[write_addr] <= psum_from_bottom;
        end
        // Logic đọc dữ liệu
        if (psum_re) begin
            r_psum_bram_data <= r_psum_bram[read_addr];
        end
    end

    //=================================================
    // 3. Pipeline Alignment
    //=================================================
    logic r_is_first_pass;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_is_first_pass <= 1'b0;
        end else begin
            r_is_first_pass <= is_first_pass;
        end
    end

    //================================================
    // 4. Mux output
    //=================================================
    always_comb begin
        if (r_is_first_pass) begin
            psum_to_top = 0;
        end else begin
            psum_to_top = r_psum_bram_data;
        end
    end
endmodule