`timescale 1ns / 1ps

// ====================================================================================================== //
// This module is ReLU function.
// In CNN model, it is commonly set a activation funciotn succeed Convolution operation.
// The most popular activation funciotn is ReLU, which can force the negative value to 0.
// In this chip, ReLU can increase the sparsity of iact, therefore, ReLU funcion is properly in Peripheral. 
// ====================================================================================================== //

module ReLU (
    input  signed [7:0] data_in,
    output signed [7:0] data_out
);

    assign data_out = data_in[7] ? 8'sd0 : data_in;

endmodule
