`timescale 1ns / 1ps

module window_router #(
    parameter DATA_WIDTH = 128,
    parameter KERNEL_SIZE = 5
)(
    input  logic clk,
    
    // Microcode config interface (Từ AXI-Lite)
    input  logic i_cfg_we,
    input  logic [15:0] i_cfg_addr,
    input  logic [31:0] i_cfg_data, 
    
    // Control signal từ FSM
    input  logic [4:0] i_current_pass_id,  // Pass hiện tại đang chạy
    
    // Input từ Line Buffer
    input  logic [KERNEL_SIZE-1:0][KERNEL_SIZE-1:0][DATA_WIDTH-1:0] window_in,
    
    // Output tới PEA (16 rows, mỗi row 8-bit)
    output logic [15:0][7:0] routed_data_out
);
    //================================================//
    //                  1.Declaration                 //
    //================================================//
    // =========================================================
    // HOLDING REGISTER & ADDRESS DECODING
    // =========================================================
    // Thanh ghi tạm 160-bit để gom đủ 5 mảnh 32-bit
    logic [159:0] holding_reg;
    // Tách địa chỉ dựa trên Memory Map (Base = 0x100, mỗi Pass chiếm 32 bytes = 0x20)
    logic is_microcode_space;
    logic [4:0] target_pass_id;
    logic [2:0] word_index;

    assign is_microcode_space = (i_cfg_addr >= 16'h0200) && (i_cfg_addr < 16'h0600);
    assign target_pass_id     = (i_cfg_addr - 16'h0200) >> 5; // Mỗi Pass 32 bytes
    assign word_index         = i_cfg_addr[4:2]; // Lấy số thứ tự Word (0 đến 4)
    
    // Khai báo LUTRAM chứa Microcode (25 entries x 160 bits)
    (* ram_style = "distributed" *) logic [159:0] microcode_ram[0:24];
    // Đọc Microcode RAM bằng current_pass_id
    //=================================================//
    //                  2. Combinational Logic         //
    //=================================================//
    logic [159:0] w_current_microcode;
    always_comb begin
        w_current_microcode = microcode_ram[i_current_pass_id];
    end
    
    // Generate 16 MUXes để trích xuất 8-bit từ window_in dựa trên vi lệnh
    always_comb begin
        for (int r = 0;r < 16; r++) begin
            // 1. Cắt 10-bit vi lệnh cho từng Hàng 'r' (Dùng biến automatic để cô lập logic trong vòng for)
            automatic logic [2:0] ky  = w_current_microcode[r*10 + 7 +: 3]; // 3 bits [9:7]
            automatic logic [2:0] kx  = w_current_microcode[r*10 + 4 +: 3]; // 3 bits [6:4]
            automatic logic [3:0] cin = w_current_microcode[r*10 + 0 +: 4]; // 4 bits [3:0]
            
            // 2. Định tuyến (Routing):
            // Lấy 1 khối 128-bit tại tọa độ (ky, kx) của Window Array
            // Sau đó trích xuất ĐÚNG 1 BYTE (8-bit) tại vị trí kênh (cin)
            routed_data_out[r] = window_in[ky][kx][cin * 8 +: 8];
        end
    end
    //=================================================//
    //                 3. Packing and Writing RAM      //
    //=================================================//
    always_ff @(posedge clk) begin
        if (i_cfg_we && is_microcode_space) begin
            // 1. Ghi từng mảnh 32-bit vào Thanh ghi tạm
            case (word_index)
                3'd0: holding_reg[31:0]    <= i_cfg_data;
                3'd1: holding_reg[63:32]   <= i_cfg_data;
                3'd2: holding_reg[95:64]   <= i_cfg_data;
                3'd3: holding_reg[127:96]  <= i_cfg_data;
                3'd4: holding_reg[159:128] <= i_cfg_data;
            endcase
            
            // 2. CÒ KÍCH HOẠT (Trigger Write): 
            // Khi CPU ghi mảnh cuối cùng (Word 4), bê cả 160-bit ập vào RAM
            if (word_index == 3'd4) begin
                // Lưu ý: Phải ghép khối holding_reg (cũ) với i_cfg_data (mới) 
                // để đảm bảo không bị trễ 1 clock.
                microcode_ram[target_pass_id] <= {i_cfg_data, holding_reg[127:0]};
            end
        end
    end
endmodule