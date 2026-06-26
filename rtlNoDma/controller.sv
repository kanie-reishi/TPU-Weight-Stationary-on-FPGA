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
    input  logic [63:0] inst_data_i,
    input  logic        inst_empty_i,
    output logic        inst_read_o,

    // =========================================================
    // 2. GIAO DIỆN DATAPATH / PE ARRAY (Compute Engine)
    // =========================================================
    output logic        mac_start_o,
    input  logic        mac_done_i,
    output logic        pool_start_o,
    input  logic        pool_done_i,

    output logic [1:0]  src_bank_o,
    output logic [1:0]  dst_bank_o,

    output logic [15:0] ifm_w_o, ifm_h_o, ifm_c_o,
    output logic [15:0] ofm_c_o,
    output logic [7:0]  knl_size_o,
    output logic [3:0]  stride_o,
    output logic [3:0]  shift_amt_o,
    output logic        relu_en_o,
    output logic [1:0]  pool_type_o,

    output logic        engine_busy_o,

    // =========================================================
    // 3. GIAO DIỆN NGẮT (Tới CPU Host)
    // =========================================================
    output logic        finish_irq_o
);

    // Opcodes supported in rtlNoDma (DDR DMA opcodes removed)
    localparam OP_SET_DIM   = 4'h2;
    localparam OP_SET_KNL   = 4'h3;
    localparam OP_RUN_MAC   = 4'h5;
    localparam OP_RUN_POOL  = 4'h6;
    localparam OP_FINISH    = 4'hF;

    localparam BANK_PING = 2'b01;
    localparam BANK_PONG = 2'b10;

    typedef enum logic [3:0] {
        ST_FETCH,
        ST_DECODE,
        ST_WAIT_MAC,
        ST_WAIT_POOL,
        ST_HALT
    } state_t;

    state_t r_state, r_next_state;

    logic [63:0] r_curr_inst;
    logic [1:0]  r_src_bank_ptr;

    assign src_bank_o    = r_src_bank_ptr;
    assign dst_bank_o    = (r_src_bank_ptr == BANK_PING) ? BANK_PONG : BANK_PING;
    assign engine_busy_o = (r_state == ST_WAIT_MAC) || (r_state == ST_WAIT_POOL);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) r_state <= ST_FETCH;
        else        r_state <= r_next_state;
    end

    always_comb begin
        r_next_state  = r_state;
        inst_read_o   = 1'b0;

        case (r_state)
            ST_FETCH: begin
                if (!inst_empty_i) begin
                    inst_read_o  = 1'b1;
                    r_next_state = ST_DECODE;
                end
            end

            ST_DECODE: begin
                unique case (r_curr_inst[63:60])
                    OP_SET_DIM, OP_SET_KNL: r_next_state = ST_FETCH;
                    OP_RUN_MAC:             r_next_state = ST_WAIT_MAC;
                    OP_RUN_POOL:            r_next_state = ST_WAIT_POOL;
                    OP_FINISH:              r_next_state = ST_HALT;
                    default:                r_next_state = ST_FETCH;
                endcase
            end

            ST_WAIT_MAC: begin
                if (mac_done_i && !mac_start_o) r_next_state = ST_FETCH;
            end

            ST_WAIT_POOL: begin
                if (pool_done_i && !pool_start_o) r_next_state = ST_FETCH;
            end

            ST_HALT: r_next_state = ST_HALT;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_curr_inst    <= '0;
            r_src_bank_ptr <= BANK_PING;

            mac_start_o  <= 1'b0;
            pool_start_o <= 1'b0;
            finish_irq_o <= 1'b0;
        end else begin
            mac_start_o  <= 1'b0;
            pool_start_o <= 1'b0;

            case (r_state)
                ST_FETCH: begin
                    if (!inst_empty_i) r_curr_inst <= inst_data_i;
                end

                ST_DECODE: begin
                    unique case (r_curr_inst[63:60])
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
                            mac_start_o <= 1'b1;
                        end

                        OP_RUN_POOL: begin
                            pool_type_o  <= r_curr_inst[9:8];
                            knl_size_o   <= r_curr_inst[7:0];
                            pool_start_o <= 1'b1;
                        end

                        OP_FINISH: finish_irq_o <= 1'b1;

                        default: ;
                    endcase
                end

                ST_WAIT_MAC: begin
                    if (mac_done_i)
                        r_src_bank_ptr <= (r_src_bank_ptr == BANK_PING) ? BANK_PONG : BANK_PING;
                end

                ST_WAIT_POOL: begin
                    if (pool_done_i)
                        r_src_bank_ptr <= (r_src_bank_ptr == BANK_PING) ? BANK_PONG : BANK_PING;
                end

                ST_HALT: finish_irq_o <= 1'b1;
            endcase
        end
    end

endmodule
