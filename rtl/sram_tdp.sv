`timescale 1ns / 1ps

// [GIẢNG BÀI] Module này là "True Dual-Port RAM" (TDP RAM).
// "True" có nghĩa là 2 cổng (Port A và Port B) hoàn toàn bình đẳng:
// Cả 2 cổng đều có thể ĐỌC và GHI một cách độc lập vào cùng một mảng nhớ.
// Trình tổng hợp (Vivado) sẽ nhận diện mảng `mem` và tự động ánh xạ nó vào Block RAM (BRAM) vật lý.
module sram_tdp #(
    parameter DWIDTH = 64, // Độ rộng dữ liệu: 64-bit (Symmetric)
    parameter AWIDTH = 11  // Độ rộng địa chỉ: 11-bit => 2^11 = 2048 dòng => 16KB
)(
    input  logic              clk,

    // ==========================================
    // PORT A (Dành cho DMA - Global Arbiter)
    // ==========================================
    input  logic              ena,   // Enable Port A
    input  logic              wea,   // Write Enable Port A
    input  logic [AWIDTH-1:0] addra, // Địa chỉ Port A
    input  logic [DWIDTH-1:0] dina,  // Dữ liệu ghi Port A
    output logic [DWIDTH-1:0] douta, // Dữ liệu đọc Port A

    // ==========================================
    // PORT B (Dành cho Datapath - Mạch MAC)
    // ==========================================
    input  logic              enb,   // Enable Port B
    input  logic              web,   // Write Enable Port B
    input  logic [AWIDTH-1:0] addrb, // Địa chỉ Port B
    input  logic [DWIDTH-1:0] dinb,  // Dữ liệu ghi Port B
    output logic [DWIDTH-1:0] doutb  // Dữ liệu đọc Port B
);

    // [GIẢNG BÀI] Khai báo mảng nhớ lõi.
    // Với AWIDTH=11, mảng này có 2048 phần tử. Mỗi phần tử rộng 64 bit.
    // Lưu ý: Không khởi tạo giá trị ban đầu (initial) để giống với RAM thực tế trên chip.
    logic [DWIDTH-1:0] r_mem [0:(1<<AWIDTH)-1];

    initial begin
        for (int i = 0; i < (1<<AWIDTH); i++) begin
            r_mem[i] = '0;
        end
    end

    // ==========================================
    // LOGIC ĐỌC/GHI CHO PORT A
    // ==========================================
    // [GIẢNG BÀI] BRAM vật lý trên FPGA luôn đồng bộ với Clock.
    // Do đó, ta phải dùng always_ff. Dữ liệu đọc ra (douta) sẽ trễ 1 clock so với lúc cấp địa chỉ.
    always_ff @(posedge clk) begin
        if (ena) begin
            if (wea) begin
                r_mem[addra] <= dina; // Ghi dữ liệu
            end
            douta <= r_mem[addra]; // Đọc dữ liệu (Read-First Mode hoặc Write-First Mode)
                                 // Ở đây Vivado thường suy luận ra Write-First (đọc ra dữ liệu vừa ghi).
        end
    end

    // ==========================================
    // LOGIC ĐỌC/GHI CHO PORT B
    // ==========================================
    // [GIẢNG BÀI] Hoạt động y hệt Port A. 
    // Mạch MAC sẽ bơm tín hiệu vào cổng này để đọc điểm ảnh hoặc ghi kết quả.
    always_ff @(posedge clk) begin
        if (enb) begin
            if (web) begin
                r_mem[addrb] <= dinb;
            end
            doutb <= r_mem[addrb];
        end
    end

endmodule
