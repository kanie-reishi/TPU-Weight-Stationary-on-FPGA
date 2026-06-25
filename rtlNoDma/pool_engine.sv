`timescale 1ns / 1ps

module pool_engine #(
    parameter SRAM_AWIDTH = 11,
    parameter SRAM_DWIDTH = 128
)(
    input  logic clk,
    input  logic rst_n,

    // Control
    input  logic ctrl_pool_start,
    output logic ctrl_pool_done,
    output logic pool_busy_o,

    // Config Parameters
    input  logic [15:0] w_ifm_w,
    input  logic [15:0] w_ifm_h,
    input  logic [15:0] w_ifm_c,

    // SRAM Interface
    output logic [SRAM_AWIDTH-1:0] pool_ifm_addr,
    output logic                   pool_ifm_re,
    input  logic [SRAM_DWIDTH-1:0] pool_ifm_rdata,

    output logic [SRAM_AWIDTH-1:0] pool_ofm_addr,
    output logic                   pool_ofm_we,
    output logic [SRAM_DWIDTH-1:0] pool_ofm_wdata
);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_ADDR_P00,
        ST_ADDR_P01,
        ST_ADDR_P10,
        ST_ADDR_P11,
        ST_WAIT_P11,
        ST_WRITE_POOL
    } state_t;

    state_t state, next_state;

    // Dimensions
    logic [15:0] w_ifm_w_half;
    logic [15:0] w_ifm_h_half;
    logic [15:0] w_ch_tiles;
    
    assign w_ifm_w_half = w_ifm_w >> 1;
    assign w_ifm_h_half = w_ifm_h >> 1;
    assign w_ch_tiles = (w_ifm_c + 15) >> 4; // Number of 16-channel tiles

    // Loop counters
    logic [15:0] r_r, r_c, r_ch_tile;
    logic r_done;

    // Registers to hold read data
    logic [SRAM_DWIDTH-1:0] r_p00, r_p01, r_p10, r_p11;

    // ---------------------------------------------------------
    // 1. FSM State Transition
    // ---------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
        end else begin
            state <= next_state;
        end
    end

    always_comb begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (ctrl_pool_start) next_state = ST_ADDR_P00;
            end
            ST_ADDR_P00: next_state = ST_ADDR_P01;
            ST_ADDR_P01: next_state = ST_ADDR_P10;
            ST_ADDR_P10: next_state = ST_ADDR_P11;
            ST_ADDR_P11: next_state = ST_WAIT_P11;
            ST_WAIT_P11: next_state = ST_WRITE_POOL;
            ST_WRITE_POOL: begin
                if (r_ch_tile == w_ch_tiles - 1 && r_r == w_ifm_h_half - 1 && r_c == w_ifm_w_half - 1) begin
                    next_state = ST_IDLE;
                end else begin
                    next_state = ST_ADDR_P00;
                end
            end
            default: next_state = ST_IDLE;
        endcase
    end

    // ---------------------------------------------------------
    // 2. Loop Counters & Done Signal
    // ---------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_c <= '0;
            r_r <= '0;
            r_ch_tile <= '0;
            r_done <= 1'b0;
        end else begin
            if (state == ST_IDLE) begin
                r_c <= '0;
                r_r <= '0;
                r_ch_tile <= '0;
                r_done <= 1'b0;
            end else if (state == ST_WRITE_POOL) begin
                if (r_c == w_ifm_w_half - 1) begin
                    r_c <= '0;
                    if (r_r == w_ifm_h_half - 1) begin
                        r_r <= '0;
                        if (r_ch_tile == w_ch_tiles - 1) begin
                            r_done <= 1'b1;
                        end else begin
                            r_ch_tile <= r_ch_tile + 1'b1;
                        end
                    end else begin
                        r_r <= r_r + 1'b1;
                    end
                end else begin
                    r_c <= r_c + 1'b1;
                end
            end else begin
                r_done <= 1'b0;
            end
        end
    end

    assign ctrl_pool_done = r_done;
    assign pool_busy_o = (state != ST_IDLE) || ctrl_pool_start;

    // ---------------------------------------------------------
    // 3. SRAM Read/Write Logic & Data Latching
    // ---------------------------------------------------------
    // Base addresses for tiles
    logic [SRAM_AWIDTH-1:0] w_ifm_tile_base;
    logic [SRAM_AWIDTH-1:0] w_ofm_tile_base;
    
    // Each IFM tile has size: w_ifm_w * w_ifm_h
    assign w_ifm_tile_base = r_ch_tile * (w_ifm_w * w_ifm_h);
    // Each OFM tile has size: (w_ifm_w/2) * (w_ifm_h/2)
    assign w_ofm_tile_base = r_ch_tile * (w_ifm_w_half * w_ifm_h_half);

    always_comb begin
        pool_ifm_re = 1'b0;
        pool_ifm_addr = '0;
        
        pool_ofm_we = 1'b0;
        pool_ofm_addr = '0;

        case (state)
            ST_ADDR_P00: begin
                pool_ifm_re = 1'b1;
                pool_ifm_addr = w_ifm_tile_base + (2*r_r)*w_ifm_w + (2*r_c);
            end
            ST_ADDR_P01: begin
                pool_ifm_re = 1'b1;
                pool_ifm_addr = w_ifm_tile_base + (2*r_r)*w_ifm_w + (2*r_c + 1);
            end
            ST_ADDR_P10: begin
                pool_ifm_re = 1'b1;
                pool_ifm_addr = w_ifm_tile_base + (2*r_r + 1)*w_ifm_w + (2*r_c);
            end
            ST_ADDR_P11: begin
                pool_ifm_re = 1'b1;
                pool_ifm_addr = w_ifm_tile_base + (2*r_r + 1)*w_ifm_w + (2*r_c + 1);
            end
            ST_WRITE_POOL: begin
                pool_ofm_we = 1'b1;
                pool_ofm_addr = w_ofm_tile_base + r_r*w_ifm_w_half + r_c;
            end
            default: ;
        endcase
    end

    // Latch read data
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_p00 <= '0;
            r_p01 <= '0;
            r_p10 <= '0;
            r_p11 <= '0;
        end else begin
            case (state)
                ST_ADDR_P01: r_p00 <= pool_ifm_rdata; // Data for ADDR_P00 arrives here
                ST_ADDR_P10: r_p01 <= pool_ifm_rdata; // Data for ADDR_P01 arrives here
                ST_ADDR_P11: r_p10 <= pool_ifm_rdata; // Data for ADDR_P10 arrives here
                ST_WAIT_P11: r_p11 <= pool_ifm_rdata; // Data for ADDR_P11 arrives here
                default: ;
            endcase
        end
    end

    // ---------------------------------------------------------
    // 4. Max Pooling Combinational Logic (16 parallel blocks)
    // ---------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < 16; i++) begin : gen_max
            wire signed [7:0] p00 = r_p00[i*8 +: 8];
            wire signed [7:0] p01 = r_p01[i*8 +: 8];
            wire signed [7:0] p10 = r_p10[i*8 +: 8];
            wire signed [7:0] p11 = r_p11[i*8 +: 8];

            wire signed [7:0] max_01 = (p00 > p01) ? p00 : p01;
            wire signed [7:0] max_23 = (p10 > p11) ? p10 : p11;
            wire signed [7:0] max_val = (max_01 > max_23) ? max_01 : max_23;

            assign pool_ofm_wdata[i*8 +: 8] = max_val;
        end
    endgenerate

endmodule
