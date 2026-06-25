`timescale 1ns / 1ps

module axi_full_dma_engine #(
    parameter AXI_AWIDTH  = 40, // 40-bit cho KR260 UltraScale+
    parameter AXI_DWIDTH  = 64, // 64-bit dữ liệu (8 bytes/nhịp)
    parameter SRAM_AWIDTH = 11  // Không gian địa chỉ cho Local Bank
)(
    input  logic clk,
    input  logic rst_n,

    // =========================================================
    // 1. GIAO DIỆN ĐIỀU KHIỂN TỪ CONTROLLER
    // =========================================================
    input  logic                    dma_req_i,     // Tín hiệu yêu cầu chạy DMA
    input  logic                    dma_dir_i,     // 0 = READ (LOAD_WGT), 1 = WRITE (STORE_OFM)
    input  logic [AXI_AWIDTH-1:0]   dma_addr_i,    // Địa chỉ gốc trên DDR (40-bit)
    input  logic [31:0]             dma_bytes_i,   // Số byte cần truyền
    input  logic [1:0]              dma_bank_sel_i,// Chọn SRAM: 00=WGT, 01=PING, 10=PONG
    
    output logic                    dma_busy_o,    // Báo Controller biết DMA đang bận (cho lệnh SYNC)
    output logic                    dma_done_o,    // Xung báo hoàn thành

    // =========================================================
    // 2. GIAO DIỆN AXI4-FULL MASTER (Giao tiếp với PS/DDR)
    // =========================================================
    // --- Kênh Read Address (AR) ---
    output logic [AXI_AWIDTH-1:0]   m_axi_araddr,
    output logic [7:0]              m_axi_arlen,   // Số beat trong 1 Burst (0-255)
    output logic [2:0]              m_axi_arsize,  // Kích thước 1 beat = log2(AXI_DWIDTH/8)
    output logic [1:0]              m_axi_arburst, // 2'b01 = INCR
    output logic                    m_axi_arvalid,
    input  logic                    m_axi_arready,
    
    // --- Kênh Read Data (R) ---
    input  logic [AXI_DWIDTH-1:0]   m_axi_rdata,
    input  logic                    m_axi_rlast,
    input  logic                    m_axi_rvalid,
    output logic                    m_axi_rready,

    // --- Kênh Write Address (AW) ---
    output logic [AXI_AWIDTH-1:0]   m_axi_awaddr,
    output logic [7:0]              m_axi_awlen,
    output logic [2:0]              m_axi_awsize,
    output logic [1:0]              m_axi_awburst,
    output logic                    m_axi_awvalid,
    input  logic                    m_axi_awready,

    // --- Kênh Write Data (W) ---
    output logic [AXI_DWIDTH-1:0]   m_axi_wdata,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  logic                    m_axi_wready,

    // --- Kênh Write Response (B) ---
    input  logic [1:0]              m_axi_bresp,
    input  logic                    m_axi_bvalid,
    output logic                    m_axi_bready,

    // =========================================================
    // 3. GIAO DIỆN LOCAL SRAM (BÊN TRONG FPGA)
    // =========================================================
    output logic                    sram_we_o,     // Write Enable chung
    output logic [1:0]              sram_bank_o,   // Định hướng Bank (từ dma_bank_sel_i)
    output logic [SRAM_AWIDTH-1:0]  sram_addr_o,   // Địa chỉ trỏ vào SRAM
    output logic [AXI_DWIDTH-1:0]   sram_wdata_o,  // Dữ liệu ghi vào SRAM (Read DDR)
    input  logic [AXI_DWIDTH-1:0]   sram_rdata_i   // Dữ liệu đọc từ SRAM (Write DDR)
);

    // Tính toán hằng số cho AXI Size (VD: 64-bit = 8 bytes = 2^3 -> arsize = 3)
    localparam BEAT_BYTES = AXI_DWIDTH / 8;
    localparam SIZE_VAL   = $clog2(BEAT_BYTES);

    // Máy trạng thái DMA
    typedef enum logic [3:0] {
        IDLE,
        CALC_BURST, // Tính toán số lượng Beat cho Burst tiếp theo
        READ_AR,    // Phát địa chỉ Đọc
        READ_R,     // Kéo dữ liệu Đọc
        WRITE_AW,   // Phát địa chỉ Ghi
        WRITE_W,    // Đẩy dữ liệu Ghi
        WRITE_B,    // Chờ DDR xác nhận Ghi xong
        DONE
    } state_t;

    state_t r_state, r_next_state;

    // Thanh ghi quản lý Burst (Burst-Splitter Registers)
    logic [AXI_AWIDTH-1:0] r_current_ddr_addr;
    logic [31:0]           r_beats_remaining; 
    logic [8:0]            r_current_burst_beats; // Tối đa 256, cần 9 bit để lưu giá trị 256

    // =========================================================
    // KHỐI FSM CHÍNH
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) r_state <= IDLE;
        else        r_state <= r_next_state;
    end

    always_comb begin
        r_next_state = r_state;
        case (r_state)
            IDLE: begin
                if (dma_req_i) r_next_state = CALC_BURST;
            end
            
            CALC_BURST: begin
                if (r_beats_remaining == 0) 
                    r_next_state = DONE;
                else if (dma_dir_i == 1'b0) // READ
                    r_next_state = READ_AR;
                else                        // WRITE
                    r_next_state = WRITE_AW;
            end
            
            READ_AR:  if (m_axi_arvalid && m_axi_arready) r_next_state = READ_R;
            READ_R:   if (m_axi_rvalid && m_axi_rready && m_axi_rlast) r_next_state = CALC_BURST;
            
            WRITE_AW: if (m_axi_awvalid && m_axi_awready) r_next_state = WRITE_W;
            WRITE_W:  if (m_axi_wvalid && m_axi_wready && m_axi_wlast) r_next_state = WRITE_B;
            WRITE_B:  if (m_axi_bvalid && m_axi_bready) r_next_state = CALC_BURST;
            
            DONE:     r_next_state = IDLE;
            default:  r_next_state = IDLE;
        endcase
    end

    // =========================================================
    // KHỐI TÍNH TOÁN BURST & ĐỊA CHỈ (Datapath)
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_current_ddr_addr    <= '0;
            r_beats_remaining     <= '0;
            r_current_burst_beats <= '0;
            sram_addr_o         <= '0;
            sram_bank_o         <= '0;
        end else begin
            case (r_state)
                IDLE: begin
                    if (dma_req_i) begin
                        r_current_ddr_addr <= dma_addr_i;
                        // Chuyển đổi Bytes sang Beats (làm tròn lên nếu không chia hết)
                        r_beats_remaining  <= (dma_bytes_i + (BEAT_BYTES - 1)) / BEAT_BYTES;
                        sram_addr_o      <= '0; // Reset địa chỉ SRAM
                        sram_bank_o      <= dma_bank_sel_i;
                    end
                end
                
                CALC_BURST: begin
                    // Chia nhỏ Burst: Nếu còn lớn hơn 256 beats, cắt lấy 256. Nếu không, lấy phần còn lại.
                    if (r_beats_remaining > 256) r_current_burst_beats <= 256;
                    else                       r_current_burst_beats <= r_beats_remaining[8:0];
                end

                READ_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        sram_addr_o <= sram_addr_o + 1; // Tăng địa chỉ SRAM
                        if (m_axi_rlast) begin
                            r_beats_remaining  <= r_beats_remaining - r_current_burst_beats;
                            r_current_ddr_addr <= r_current_ddr_addr + (r_current_burst_beats * BEAT_BYTES);
                        end
                    end
                end

                WRITE_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        sram_addr_o <= sram_addr_o + 1; // PREFETCH SRAM address to hide 1-cycle latency!
                    end
                end

                WRITE_W: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        sram_addr_o <= sram_addr_o + 1;
                        if (m_axi_wlast) begin
                            r_beats_remaining  <= r_beats_remaining - r_current_burst_beats;
                            r_current_ddr_addr <= r_current_ddr_addr + (r_current_burst_beats * BEAT_BYTES);
                        end
                    end
                end
            endcase
        end
    end

    // =========================================================
    // GÁN TÍN HIỆU GIAO TIẾP AXI VÀ SRAM
    // =========================================================
    // Constants cho AXI
    assign m_axi_arsize  = SIZE_VAL[2:0];
    assign m_axi_awsize  = SIZE_VAL[2:0];
    assign m_axi_arburst = 2'b01; // INCR
    assign m_axi_awburst = 2'b01; // INCR

    // Kênh AR
    assign m_axi_arvalid = (r_state == READ_AR);
    assign m_axi_araddr  = r_current_ddr_addr;
    assign m_axi_arlen   = r_current_burst_beats - 1; // AXI spec: len = beats - 1

    // Kênh R
    assign m_axi_rready  = (r_state == READ_R);

    // Kênh AW
    assign m_axi_awvalid = (r_state == WRITE_AW);
    assign m_axi_awaddr  = r_current_ddr_addr;
    assign m_axi_awlen   = r_current_burst_beats - 1;

    // Kênh W (Ghi dữ liệu từ SRAM ra DDR)
    // Chú ý: Ở thiết kế thực tế, sram_rdata_i có thể trễ 1 clock. 
    // Trong template này ta giả sử SRAM đọc tổ hợp (hoặc đã được pre-fetch).
    logic [8:0] r_w_beat_cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) r_w_beat_cnt <= '0;
        else if (r_state == WRITE_AW) r_w_beat_cnt <= '0;
        else if (m_axi_wvalid && m_axi_wready) r_w_beat_cnt <= r_w_beat_cnt + 1;
    end

    assign m_axi_wvalid = (r_state == WRITE_W);
    assign m_axi_wdata  = sram_rdata_i;
    assign m_axi_wlast  = (m_axi_wvalid && (r_w_beat_cnt == (r_current_burst_beats - 1)));

    // Kênh B
    assign m_axi_bready = (r_state == WRITE_B);

    // Điều khiển SRAM
    assign sram_we_o    = (r_state == READ_R && m_axi_rvalid && m_axi_rready);
    assign sram_wdata_o = m_axi_rdata;

    // Phản hồi cho Controller
    assign dma_busy_o   = (r_state != IDLE);
    assign dma_done_o   = (r_state == DONE);

endmodule