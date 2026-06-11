`timescale 1ns / 1ps

// ============================================================================
// Module: mac_pe (Processing Element)
// Description: A single node in the Double-Buffered Weight Stationary Systolic Array.
// ============================================================================
module mac_pe #(
    parameter ROW = 0,
    parameter COL = 0
)(
    input  logic        clk,
    input  logic        rst_n,
 
    // Weight Pre-load Interface (flows vertically, Top to Bottom)
    // Uses a shadow register to allow loading while computing
    input  logic        load_weight_en,
    input  logic [7:0]  weight_in,
    output logic [7:0]  weight_out,
 
    // Wavefront Swapping Interface (flows horizontally with data)
    input  logic        swap_weight_in,
    output logic        swap_weight_out,
 
    // Data Flow Interface (flows horizontally, Left to Right)
    input  logic        data_en,
    input  logic [7:0]  data_in,
    output logic [7:0]  data_out,
    output logic        data_en_out,
 
    // Partial Sum Flow Interface (flows vertically, Top to Bottom)
    input  logic        psum_en,
    input  logic [31:0] psum_in,
    output logic [31:0] psum_out,
    output logic        psum_en_out
);
    // Stage 1 Registers (Latched at T+1)
    logic [7:0]  r_weight;
    logic [7:0]  r_weight_shadow;
    logic [7:0]  r_data;
    logic        r_data_en;
    logic        r_swap;

    // Stage 2 Registers (Latched at T+2, representing MREG & propagation)
    logic signed [15:0] r_mult_res;
    logic [7:0]  r_data_out;
    logic        r_data_en_out;
    logic        r_swap_out;
    logic [31:0] r_psum_in;
    logic        r_psum_en_in;

    // Stage 3 Registers (Latched at T+3, representing PREG)
    logic [31:0] r_psum;
    logic        r_psum_en;

    // Output assignments
    assign weight_out      = r_weight_shadow; // Weight shadow flows without pipeline stages
    assign data_out        = r_data_out;
    assign data_en_out     = r_data_en_out;
    assign swap_weight_out = r_swap_out;
    assign psum_out        = r_psum;
    assign psum_en_out     = r_psum_en;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            r_weight        <= 8'd0;
            r_weight_shadow <= 8'd0;
            r_data          <= 8'd0;
            r_data_en       <= 1'b0;
            r_swap          <= 1'b0;
            
            r_mult_res      <= 16'd0;
            r_data_out      <= 8'd0;
            r_data_en_out   <= 1'b0;
            r_swap_out      <= 1'b0;
            r_psum_in       <= 32'd0;
            r_psum_en_in    <= 1'b0;
            
            r_psum          <= 32'd0;
            r_psum_en       <= 1'b0;
        end else begin
            // -------------------------------------------------------------
            // STAGE 1: Input Latching (AREG/BREG equivalents)
            // -------------------------------------------------------------
            if (load_weight_en) begin
                r_weight_shadow <= weight_in;
            end
            
            r_swap <= swap_weight_in;
            if (swap_weight_in) begin
                r_weight <= r_weight_shadow;
                if ($signed(r_weight_shadow) != 0) begin
                    $display("[PE_DEBUG] at %0t PE(%0d,%0d): swapped weight=%0d", $time, ROW, COL, $signed(r_weight_shadow));
                end
            end
            
            r_data    <= data_in;
            r_data_en <= data_en;

            // -------------------------------------------------------------
            // STAGE 2: Multiplier (MREG) & Horizontal Propagation
            // -------------------------------------------------------------
            r_mult_res    <= $signed(r_weight) * $signed(r_data);
            if (r_data_en && COL == 0) begin
                $display("[PE_MULT_DEBUG] at %0t PE(%0d,0) mult: weight=%0d, data=%0d, product=%0d", 
                         $time, ROW, $signed(r_weight), $signed(r_data), $signed($signed(r_weight) * $signed(r_data)));
            end
            
            r_data_out    <= r_data;
            r_data_en_out <= r_data_en;
            r_swap_out    <= r_swap;

            // Align Psum input with the multiplier result
            r_psum_in     <= psum_in;
            r_psum_en_in  <= psum_en;

            // -------------------------------------------------------------
            // STAGE 3: Accumulator (PREG)
            // -------------------------------------------------------------
            r_psum_en <= r_psum_en_in;
            
            // data_en_out is aligned with psum_en_in
            if (r_psum_en_in && r_data_en_out) begin
                r_psum <= $signed(r_psum_in) + $signed(r_mult_res);
            end else if (r_psum_en_in) begin
                r_psum <= r_psum_in;
            end else begin
                r_psum <= 32'd0; 
            end
        end
    end
endmodule