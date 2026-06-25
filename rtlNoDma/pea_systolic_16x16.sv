`timescale 1ns / 1ps

// ============================================================================
// Module: pea_systolic_16x16
// Description: A 16x16 grid of mac_pe units. Includes Input Skewing and Output De-Skewing.
// ============================================================================
module pea_systolic_16x16 (
    input  logic clk,
    input  logic rst_n,

    // Weight Pre-load Interface (Input at top row)
    input  logic [15:0]       load_weight_en,
    input  logic [15:0][7:0]  weight_in_top,

    // IFM Data Input Interface (Simultaneous Input)
    input  logic [15:0]       data_en_left,
    input  logic [15:0][7:0]  data_in_left,
    
    // Wavefront Swapping Trigger (Simultaneous Input, will be skewed with data)
    input  logic              swap_weight_in_global,

    // Partial Sum Input (Input at top row)
    input  logic [15:0]       psum_en_top,
    input  logic [15:0][31:0] psum_in_top,

    // Output Feature Map Result (Aligned Simultaneous Output)
    output logic [15:0][31:0] psum_out_bottom,
    output logic [15:0]       psum_en_bottom
);

    // ------------------------------------------------------------------------
    // 1. INPUT SKEW BUFFERS (Stagger data horizontally by row index)
    // ------------------------------------------------------------------------
    logic [15:0][7:0] w_skewed_data_in;
    logic [15:0]      w_skewed_data_en;
    logic [15:0]      w_skewed_swap_in;

    genvar r, c;
    generate
        for (r = 0; r < 16; r++) begin : skew_row
            if (r == 0) begin
                assign w_skewed_data_in[r] = data_in_left[r];
                assign w_skewed_data_en[r] = data_en_left[r];
                assign w_skewed_swap_in[r] = swap_weight_in_global;
            end else begin
                // Shift register of length '2*r'
                localparam delay = 2 * r;
                logic [7:0] r_sr_data [0:delay-1];
                logic       r_sr_en   [0:delay-1];
                logic       r_sr_swap [0:delay-1];
                
                always_ff @(posedge clk) begin
                    if (!rst_n) begin
                        for (int k=0; k<delay; k++) begin
                            r_sr_data[k] <= 8'd0;
                            r_sr_en[k]   <= 1'b0;
                            r_sr_swap[k] <= 1'b0;
                        end
                    end else begin
                        r_sr_data[0] <= data_in_left[r];
                        r_sr_en[0]   <= data_en_left[r];
                        r_sr_swap[0] <= swap_weight_in_global;
                        for (int k=1; k<delay; k++) begin
                            r_sr_data[k] <= r_sr_data[k-1];
                            r_sr_en[k]   <= r_sr_en[k-1];
                            r_sr_swap[k] <= r_sr_swap[k-1];
                        end
                    end
                end
                assign w_skewed_data_in[r] = r_sr_data[delay-1];
                assign w_skewed_data_en[r] = r_sr_en[delay-1];
                assign w_skewed_swap_in[r] = r_sr_swap[delay-1];
            end
        end
    endgenerate

    // ------------------------------------------------------------------------
    // 1b. PSUM INPUT SKEW BUFFERS (Stagger psum horizontally by col index)
    // ------------------------------------------------------------------------
    logic [15:0][31:0] w_skewed_psum_in;
    logic [15:0]       w_skewed_psum_en;

    generate
        for (c = 0; c < 16; c++) begin : skew_psum_col
            // Shift register of length '2*c + 1'
            localparam delay = 2 * c + 1;
            logic [31:0] r_sr_psum_data [0:delay-1];
            logic        r_sr_psum_en   [0:delay-1];
            
            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    for (int k=0; k<delay; k++) begin
                        r_sr_psum_data[k] <= 32'd0;
                        r_sr_psum_en[k]   <= 1'b0;
                    end
                end else begin
                    r_sr_psum_data[0] <= psum_in_top[c];
                    r_sr_psum_en[0]   <= psum_en_top[c];
                    for (int k=1; k<delay; k++) begin
                        r_sr_psum_data[k] <= r_sr_psum_data[k-1];
                        r_sr_psum_en[k]   <= r_sr_psum_en[k-1];
                    end
                end
            end
            assign w_skewed_psum_in[c] = r_sr_psum_data[delay-1];
            assign w_skewed_psum_en[c] = r_sr_psum_en[delay-1];
        end
    endgenerate

    // ------------------------------------------------------------------------
    // 2. 16x16 PE GRID
    // ------------------------------------------------------------------------
    logic [7:0]  w_weight_data [0:16][0:15];
    logic [31:0] w_p_data [0:16][0:15];
    logic        w_p_en   [0:16][0:15];
    logic [7:0]  w_d_data [0:15][0:16];
    logic        w_d_en   [0:15][0:16];
    logic        w_s_swap [0:15][0:16];

    generate
        // Boundary connections
        for (c = 0; c < 16; c++) begin : top_boundary
            assign w_weight_data[0][c] = weight_in_top[c];
            assign w_p_data[0][c] = w_skewed_psum_in[c];
            assign w_p_en[0][c]   = w_skewed_psum_en[c];
        end
        for (r = 0; r < 16; r++) begin : left_boundary
            assign w_d_data[r][0] = w_skewed_data_in[r];
            assign w_d_en[r][0]   = w_skewed_data_en[r];
            assign w_s_swap[r][0] = w_skewed_swap_in[r];
        end

        for (r = 0; r < 16; r++) begin : grid_row
            for (c = 0; c < 16; c++) begin : grid_col
                mac_pe #(
                    .ROW(r),
                    .COL(c)
                ) u_pe (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    .load_weight_en (load_weight_en[c]),
                    .weight_in      (w_weight_data[r][c]),
                    .weight_out     (w_weight_data[r+1][c]),
                    .swap_weight_in (w_s_swap[r][c]),
                    .swap_weight_out(w_s_swap[r][c+1]),
                    .data_en        (w_d_en[r][c]),
                    .data_in        (w_d_data[r][c]),
                    .data_out       (w_d_data[r][c+1]),
                    .data_en_out    (w_d_en[r][c+1]),
                    .psum_en        (w_p_en[r][c]),
                    .psum_in        (w_p_data[r][c]),
                    .psum_out       (w_p_data[r+1][c]),
                    .psum_en_out    (w_p_en[r+1][c])
                );
            end
        end
    endgenerate

    // ------------------------------------------------------------------------
    // 3. OUTPUT DE-SKEW BUFFERS (Re-align columns)
    // Column c outputs earlier than Column c+1, so Col c needs more delay.
    // Delay for Col c is (15 - c) cycles.
    // ------------------------------------------------------------------------
    generate
        for (c = 0; c < 16; c++) begin : deskew_col
            localparam delay = 2 * (15 - c);
            
            if (delay == 0) begin
                assign psum_out_bottom[c] = w_p_data[16][c];
                assign psum_en_bottom[c]  = w_p_en[16][c];
            end else begin
                logic [31:0] r_ds_data [0:delay-1];
                logic        r_ds_en   [0:delay-1];
                
                always_ff @(posedge clk) begin
                    if (!rst_n) begin
                        for (int k=0; k<delay; k++) begin
                            r_ds_data[k] <= 32'd0;
                            r_ds_en[k]   <= 1'b0;
                        end
                    end else begin
                        r_ds_data[0] <= w_p_data[16][c];
                        r_ds_en[0]   <= w_p_en[16][c];
                        for (int k=1; k<delay; k++) begin
                            r_ds_data[k] <= r_ds_data[k-1];
                            r_ds_en[k]   <= r_ds_en[k-1];
                        end
                    end
                end
                assign psum_out_bottom[c] = r_ds_data[delay-1];
                assign psum_en_bottom[c]  = r_ds_en[delay-1];
            end
        end
    endgenerate

endmodule
