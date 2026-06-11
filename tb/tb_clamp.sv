module tb_clamp;
    logic signed [15:0][31:0] r_s3_shifted;
    logic signed [31:0] temp_sum;
    logic signed [31:0] temp_shifted;
    logic signed [7:0] w_clamped;
    
    initial begin
        temp_sum = -14367;
        temp_shifted = temp_sum >>> 8; // -57
        $display("temp_shifted = %0d", temp_shifted);
        
        r_s3_shifted[7] = temp_shifted;
        
        w_clamped = ($signed(r_s3_shifted[7]) > 32'sd127)  ? 8'sd127  :
                    ($signed(r_s3_shifted[7]) < -32'sd128) ? -8'sd128 :
                    r_s3_shifted[7][7:0];
                    
        $display("r_s3_shifted[7] = %0d", r_s3_shifted[7]);
        $display("$signed(r_s3_shifted[7]) = %0d", $signed(r_s3_shifted[7]));
        $display("w_clamped = %0d", w_clamped);
        
        $finish;
    end
endmodule
