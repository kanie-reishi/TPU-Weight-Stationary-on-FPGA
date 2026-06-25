`timescale 1ns / 1ps

// ====================================================================================================== //
// This module is Max_pooling (Combinational 1-cycle version).
// This module only contains the find_max logic for a 2x2 window.
// In this design, the pooling function only supports 2x2 max pooling.
// ====================================================================================================== //

module Max_pooling (
    input  signed [7:0] p00,
    input  signed [7:0] p01,
    input  signed [7:0] p10,
    input  signed [7:0] p11,
    output signed [7:0] data_out
);

    // find max 2-stage comparator
    wire signed [7:0] w_max_valule_0_1 = (p00 > p01) ? p00 : p01;
    wire signed [7:0] w_max_valule_2_3 = (p10 > p11) ? p10 : p11;
    wire signed [7:0] w_max_value      = (w_max_valule_0_1 > w_max_valule_2_3) ? w_max_valule_0_1 : w_max_valule_2_3;

    assign data_out = w_max_value;

endmodule
