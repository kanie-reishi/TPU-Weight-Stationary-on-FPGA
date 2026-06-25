`timescale 1ns / 1ps

module weight_bias_bank #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Global Arbiter Interface (Write Only)
    input  logic                    arbiter_we,
    input  logic [ADDR_WIDTH-1:0]   arbiter_addr,
    input  logic [DATA_WIDTH-1:0]   arbiter_data,
    input  logic                    arbiter_write_done,

    // PEA Interface (Read Only)
    input  logic                    pea_re,
    input  logic [ADDR_WIDTH-1:0]   pea_addr,
    output logic [DATA_WIDTH-1:0]   pea_data,
    input  logic                    pea_read_done
);

    // Two memory banks for Ping-Pong Buffering
    // SystemVerilog array modeling for BRAM inference
    logic [DATA_WIDTH-1:0] r_bank0 [0:(1<<ADDR_WIDTH)-1];
    logic [DATA_WIDTH-1:0] r_bank1 [0:(1<<ADDR_WIDTH)-1];

    // Ping-Pong Pointer
    // 0: Arbiter writes to Bank 0, PEA reads from Bank 1
    // 1: Arbiter writes to Bank 1, PEA reads from Bank 0
    logic r_ping_pong_ptr;

    // Handshake state registers
    logic r_write_ready;
    logic r_read_ready;

    // Ping-Pong Control Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_ping_pong_ptr <= 1'b0;
            r_write_ready   <= 1'b0;
            r_read_ready    <= 1'b0;
        end else begin
            // Latch the done signals
            if (arbiter_write_done) r_write_ready <= 1'b1;
            if (pea_read_done)      r_read_ready  <= 1'b1;

            // Swap banks when both Arbiter and PEA have finished their current bank
            if ((r_write_ready || arbiter_write_done) && (r_read_ready || pea_read_done)) begin
                r_ping_pong_ptr <= ~r_ping_pong_ptr;
                r_write_ready   <= 1'b0;
                r_read_ready    <= 1'b0;
            end
        end
    end

    // Memory Write Logic (Synchronous Write)
    always_ff @(posedge clk) begin
        if (arbiter_we) begin
            if (r_ping_pong_ptr == 1'b0) begin
                r_bank0[arbiter_addr] <= arbiter_data;
            end else begin
                r_bank1[arbiter_addr] <= arbiter_data;
            end
        end
    end

    // Memory Read Logic (Synchronous Read)
    logic [DATA_WIDTH-1:0] r_bank0_read_data;
    logic [DATA_WIDTH-1:0] r_bank1_read_data;

    always_ff @(posedge clk) begin
        if (pea_re) begin
            r_bank0_read_data <= r_bank0[pea_addr];
            r_bank1_read_data <= r_bank1[pea_addr];
        end
    end

    // Output MUX based on Ping-Pong Pointer
    // If ptr == 0, Arbiter is using Bank 0, so PEA must read from Bank 1
    // If ptr == 1, Arbiter is using Bank 1, so PEA must read from Bank 0
    assign pea_data = (r_ping_pong_ptr == 1'b0) ? r_bank1_read_data : r_bank0_read_data;

endmodule
