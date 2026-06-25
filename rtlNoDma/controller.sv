`timescale 1ns / 1ps

module controller #(
    parameter AXI_AWIDTH = 40,
    parameter AXI_DWIDTH = 64
)(
    input  logic        clk,
    input  logic        rst_n,

// =========================================================
    // 1. GIAO DIỆN INSTRUCTION FIFO (Từ Global Arbiter / Inst Mem)
    // =========================================================
    input  logic [63:0] inst_data_i,   // Lệnh 64-bit đẩy sang từ Arbiter
    input  logic        inst_empty_i,  // Arbiter báo Instruction FIFO rỗng
    output logic        inst_read_o,   // Controller báo Arbiter kéo lệnh tiếp theo

    // =========================================================
    // 2. GIAO DIỆN DATAPATH / PE ARRAY (Compute Engine)
    // =========================================================
    // Tín hiệu điều khiển luồng
    output logic        mac_start_o,
    input  logic        mac_done_i,     // Sliding Window / PE báo hoàn thành
    output logic        pool_start_o,
    input  logic        pool_done_i,    // Khối Pool báo hoàn thành
    
    // Tín hiệu định tuyến SRAM nội bộ
    output logic [1:0]  src_bank_o,     // Bank chứa IFM (01=Ping, 10=Pong)
    output logic [1:0]  dst_bank_o,     // Bank ghi OFM
    
    // Thanh ghi tham số truyền cho PE Array (Parameter Wires)
    output logic [15:0] ifm_w_o, ifm_h_o, ifm_c_o,
    output logic [15:0] ofm_c_o,
    output logic [7:0]  knl_size_o,
    output logic [3:0]  stride_o,
    output logic [3:0]  shift_amt_o,
    output logic        relu_en_o,
    output logic [1:0]  pool_type_o,

    // =========================================================
    // 3. GIAO DIỆN NGẮT (Tới CPU Host)
    // =========================================================
    output logic        finish_irq_o
);

    // --- Định nghĩa Opcodes (Từ ISA v2.0) ---
    localparam OP_SET_ADDR  = 4'h1;
    localparam OP_SET_DIM   = 4'h2;
    localparam OP_SET_KNL   = 4'h3;
    localparam OP_LOAD_WGT  = 4'h4;
    localparam OP_RUN_MAC   = 4'h5;
    localparam OP_RUN_POOL  = 4'h6;
    localparam OP_STORE_OFM = 4'h7;
    localparam OP_SYNC      = 4'h8;
    localparam OP_LOAD_IFM  = 4'hA; // [GIẢNG BÀI] 1. Mở rộng ISA: Thêm lệnh nạp IFM từ DDR vào FPGA.
    localparam OP_FINISH    = 4'hF;

    // --- Định nghĩa Bank ID ---
    localparam BANK_WGT  = 2'b00;
    localparam BANK_PING = 2'b01;
    localparam BANK_PONG = 2'b10;

    // --- FSM States ---
    typedef enum logic [3:0] {
        ST_FETCH,
        ST_DECODE,
        ST_WAIT_MAC,
        ST_WAIT_POOL,
        ST_WAIT_SYNC,
        ST_HALT
    } state_t;

    state_t r_state, r_next_state;

    // --- Thanh ghi lưu trữ cấu hình (Configuration Registers) ---
    logic [AXI_AWIDTH-1:0] r_reg_ifm_addr, r_reg_wgt_addr, r_reg_ofm_addr;
    logic [63:0]           r_curr_inst;       // Thanh ghi chứa lệnh hiện tại
    logic [1:0]            r_src_bank_ptr;    // Con trỏ Ping-Pong

    // Gán đầu ra thông số cho PE Array liên tục
    assign src_bank_o = r_src_bank_ptr;
    assign dst_bank_o = (r_src_bank_ptr == BANK_PING) ? BANK_PONG : BANK_PING; // Đích luôn ngược với Nguồn

    // =========================================================
    // FSM LOGIC
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) r_state <= ST_FETCH;
        else        r_state <= r_next_state;
    end

    always_comb begin
        r_next_state  = r_state;
        inst_read_o = 1'b0;

        case (r_state)
            ST_FETCH: begin
                if (!inst_empty_i) begin
                    inst_read_o = 1'b1;  // Pop lệnh khỏi FIFO
                    r_next_state  = ST_DECODE;
                end
            end

            ST_DECODE: begin
                logic [3:0] r_opcode;
                r_opcode = r_curr_inst[63:60]; // Lấy 4 bit Opcode
                
                case (r_opcode)
                    OP_SET_ADDR, OP_SET_DIM, OP_SET_KNL: r_next_state = ST_FETCH; // Cập nhật tham số xong thì nạp tiếp
                    // [GIẢNG BÀI] 2. Thêm OP_LOAD_IFM vào nhóm lệnh kích hoạt tiến trình DMA.
                    OP_LOAD_WGT, OP_LOAD_IFM, OP_STORE_OFM: r_next_state = ST_EXEC_DMA;
                    OP_RUN_MAC:                          r_next_state = ST_WAIT_MAC;
                    OP_RUN_POOL:                         r_next_state = ST_WAIT_POOL;
                    OP_SYNC:                             r_next_state = ST_WAIT_SYNC;
                    OP_FINISH:                           r_next_state = ST_HALT;
                    default:                             r_next_state = ST_FETCH;
                endcase
            end



            ST_WAIT_MAC: begin
                // Auto-stall: Đứng đợi cho đến khi PE Array tính xong layer
                if (mac_done_i && !mac_start_o) r_next_state = ST_FETCH;
            end

            ST_WAIT_POOL: begin
                // Auto-stall: Đứng đợi Pool tính xong
                if (pool_done_i && !pool_start_o) r_next_state = ST_FETCH;
            end

            ST_WAIT_SYNC: begin
                // Block pipeline cho đến khi Arbiter báo DMA đã rảnh
                if (!dma_busy_i) r_next_state = ST_FETCH;
            end

            ST_HALT: begin
                // Giữ nguyên trạng thái Halt cho đến khi Reset chip
                r_next_state = ST_HALT;
            end
        endcase
    end

    // =========================================================
    // DECODE & THỰC THI LỆNH (Datapath / Registers)
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_curr_inst    <= '0;
            r_src_bank_ptr <= BANK_PING; // Mặc định dữ liệu ảnh gốc nằm ở PING
            
            // Reset các cờ điều khiển
            mac_start_o  <= 1'b0;
            pool_start_o <= 1'b0;
            finish_irq_o <= 1'b0;
        end else begin
            // Mặc định clear xung (Pulse) để các cờ không bị treo
            mac_start_o  <= 1'b0;
            pool_start_o <= 1'b0;

            case (r_state)
                ST_FETCH: begin
                    if (!inst_empty_i) r_curr_inst <= inst_data_i; // Lưu lệnh vào thanh ghi
                end

                ST_DECODE: begin
                    logic [3:0] r_opcode;
                    r_opcode = r_curr_inst[63:60];

                    // Tách Payload
                    case (r_opcode)
                        OP_SET_ADDR: begin
                            logic [1:0] r_addr_type;
                            r_addr_type = r_curr_inst[59:58];
                            if      (r_addr_type == 2'b00) r_reg_ifm_addr <= r_curr_inst[39:0];
                            else if (r_addr_type == 2'b01) r_reg_wgt_addr <= r_curr_inst[39:0];
                            else if (r_addr_type == 2'b10) r_reg_ofm_addr <= r_curr_inst[39:0];
                        end

                        OP_SET_DIM: begin
                            ifm_w_o <= r_curr_inst[47:32];
                            ifm_h_o <= r_curr_inst[31:16];
                            ifm_c_o <= r_curr_inst[15:0];
                        end

                        OP_SET_KNL: begin
                            ofm_c_o     <= r_curr_inst[31:16];
                            knl_size_o  <= r_curr_inst[15:8];
                            stride_o    <= r_curr_inst[7:4];
                            shift_amt_o <= r_curr_inst[3:0];
                        end

                        OP_RUN_MAC: begin
                            relu_en_o   <= r_curr_inst[0];
                            mac_start_o <= 1'b1; // Phát xung kích hoạt mảng PE
                        end

                        OP_RUN_POOL: begin
                            pool_type_o  <= r_curr_inst[9:8];
                            knl_size_o   <= r_curr_inst[7:0]; // Tái sử dụng dây knl_size_o
                            pool_start_o <= 1'b1;
                        end

                        OP_FINISH: begin
                            finish_irq_o <= 1'b1; // Kích hoạt ngắt về PS
                        end
                    endcase
                end

                ST_WAIT_MAC: begin
                    // Đảo chiều Ping-Pong sau khi hoàn thành Conv
                    if (mac_done_i) r_src_bank_ptr <= (r_src_bank_ptr == BANK_PING) ? BANK_PONG : BANK_PING;
                end

                ST_WAIT_POOL: begin
                    // Đảo chiều Ping-Pong sau khi hoàn thành Pool
                    if (pool_done_i) r_src_bank_ptr <= (r_src_bank_ptr == BANK_PING) ? BANK_PONG : BANK_PING;
                end

                ST_HALT: begin
                    // Hold finish_irq high until reset (software polls 0x04 / PS IRQ)
                    finish_irq_o <= 1'b1;
                end
            endcase
        end
    end

endmodule