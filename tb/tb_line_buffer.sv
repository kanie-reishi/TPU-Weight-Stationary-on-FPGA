`timescale 1ns / 1ps

// ============================================================================
// Testbench: tb_line_buffer
// Purpose  : Demonstrate how the line_buffer module works by streaming a
//            small 8x8 image with sequential pixel values (1, 2, 3, ..., 64).
//            The testbench prints the 5x5 window content at every clock cycle
//            so you can trace the waterfall shift and circular buffer behavior.
//
// Key Concepts Illustrated:
//   1. Column pointer wraps around at img_width (circular addressing)
//   2. Window shifts LEFT each cycle (new data enters column 4)
//   3. Line buffers act as delay lines — they store one full row of data
//      so that data from previous rows reappears exactly img_width cycles later
//   4. After streaming (KERNEL_SIZE-1)*img_width + KERNEL_SIZE pixels,
//      the window is fully populated with the first valid 5x5 patch
// ============================================================================
module tb_line_buffer;

    // =========================================================================
    // Parameters — Override DATA_WIDTH to 8 bits for waveform readability
    // =========================================================================
    localparam MAX_WIDTH   = 32;
    localparam KERNEL_SIZE = 5;
    localparam DATA_WIDTH  = 8;   // Overridden from 128 for easy debug
    localparam IMG_W       = 8;   // Simulated image width
    localparam IMG_H       = 8;   // Simulated image height
    localparam TOTAL_PX    = IMG_W * IMG_H;

    // =========================================================================
    // DUT Signals
    // =========================================================================
    logic                             clk;
    logic                             rst_n;
    logic                             stream_en;
    logic [$clog2(MAX_WIDTH)-1:0]     img_width;
    logic                             pixel_valid_in;
    logic [DATA_WIDTH-1:0]            pixel_in;
    logic [KERNEL_SIZE-1:0][KERNEL_SIZE-1:0][DATA_WIDTH-1:0] window_data_out;

    // =========================================================================
    // Device Under Test
    // =========================================================================
    line_buffer #(
        .MAX_WIDTH  (MAX_WIDTH),
        .KERNEL_SIZE(KERNEL_SIZE),
        .DATA_WIDTH (DATA_WIDTH)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .stream_en      (stream_en),
        .img_width      (img_width),
        .pixel_valid_in (pixel_valid_in),
        .pixel_in       (pixel_in),
        .window_data_out(window_data_out)
    );

    // =========================================================================
    // Clock Generation — 100 MHz (10 ns period)
    // =========================================================================
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Pixel counter — tracks which pixel we are currently streaming
    // =========================================================================
    integer pixel_count;

    // =========================================================================
    // Main Stimulus
    // =========================================================================
    initial begin
        // --- Initialization ---
        rst_n          = 0;
        stream_en      = 0;
        pixel_valid_in = 0;
        pixel_in       = '0;
        img_width      = IMG_W;  // Tell the DUT the image is 8 pixels wide
        pixel_count    = 0;

        $display("=============================================================");
        $display(" TESTBENCH: tb_line_buffer");
        $display(" Image Size : %0d x %0d  (Total %0d pixels)", IMG_W, IMG_H, TOTAL_PX);
        $display(" Kernel Size: %0d x %0d", KERNEL_SIZE, KERNEL_SIZE);
        $display(" DATA_WIDTH : %0d bits", DATA_WIDTH);
        $display("=============================================================");
        $display("");
        $display(" Pixel layout (row-major order):");
        $display("   Row 0:  1  2  3  4  5  6  7  8");
        $display("   Row 1:  9 10 11 12 13 14 15 16");
        $display("   Row 2: 17 18 19 20 21 22 23 24");
        $display("   Row 3: 25 26 27 28 29 30 31 32");
        $display("   Row 4: 33 34 35 36 37 38 39 40");
        $display("   Row 5: 41 42 43 44 45 46 47 48");
        $display("   Row 6: 49 50 51 52 53 54 55 56");
        $display("   Row 7: 57 58 59 60 61 62 63 64");
        $display("");

        // --- Release Reset ---
        #20;
        rst_n = 1;
        #10;

        $display("[%0t] Reset released. Starting pixel stream...", $time);
        $display("-------------------------------------------------------------");

        // =====================================================================
        // Stream all 64 pixels (8 rows x 8 columns), one per clock cycle
        // =====================================================================
        stream_en      = 1;
        pixel_valid_in = 1;

        for (pixel_count = 0; pixel_count < TOTAL_PX; pixel_count++) begin
            pixel_in = pixel_count + 1;  // Pixel values: 1, 2, 3, ..., 64
            @(posedge clk);
            #1; // Small delay after posedge to let outputs settle

            // Print current state
            $display("[Cycle %0d] pixel_in = %0d | col_ptr = %0d | row = %0d, col = %0d",
                     pixel_count, pixel_count + 1,
                     dut.r_col_ptr,
                     pixel_count / IMG_W, pixel_count % IMG_W);

            // ---------------------------------------------------------
            // Line Buffer Read/Write Log at current col_ptr
            // Shows what was READ from each LB (fed into window col 4)
            // and what was WRITTEN back (from window col 0 overflow)
            // ---------------------------------------------------------
            $display("  LB R/W @ col_ptr=%0d:", dut.r_col_ptr);
            $display("    LB1: read -> win[1][4] = %3d | win[0][0] = %3d -> write LB1",
                     dut.r_lb_1[dut.r_col_ptr], dut.r_window_arr[0][0]);
            $display("    LB2: read -> win[2][4] = %3d | win[1][0] = %3d -> write LB2",
                     dut.r_lb_2[dut.r_col_ptr], dut.r_window_arr[1][0]);
            $display("    LB3: read -> win[3][4] = %3d | win[2][0] = %3d -> write LB3",
                     dut.r_lb_3[dut.r_col_ptr], dut.r_window_arr[2][0]);
            $display("    LB4: read -> win[4][4] = %3d | win[3][0] = %3d -> write LB4",
                     dut.r_lb_4[dut.r_col_ptr], dut.r_window_arr[3][0]);

            // ---------------------------------------------------------
            // Waterfall Data Flow Trace
            // Visualizes the cascade: pixel_in -> LB1 -> LB2 -> LB3 -> LB4
            // ---------------------------------------------------------
            $display("  Waterfall: pixel_in(%0d) -> LB1[%0d](%0d) -> LB2[%0d](%0d) -> LB3[%0d](%0d) -> LB4[%0d](%0d)",
                     pixel_count + 1,
                     dut.r_col_ptr, dut.r_lb_1[dut.r_col_ptr],
                     dut.r_col_ptr, dut.r_lb_2[dut.r_col_ptr],
                     dut.r_col_ptr, dut.r_lb_3[dut.r_col_ptr],
                     dut.r_col_ptr, dut.r_lb_4[dut.r_col_ptr]);

            print_window();

            // ---------------------------------------------------------
            // Full Line Buffer Dump at key milestones
            // ---------------------------------------------------------
            // After first row is complete (col_ptr wraps back to 0)
            if (pixel_count == IMG_W - 1) begin
                $display(">>> MILESTONE: First row complete. Full LB state:");
                print_line_buffers();
            end
            // After window is first fully populated: (KERNEL_SIZE-1)*IMG_W + KERNEL_SIZE - 1
            if (pixel_count == (KERNEL_SIZE - 1) * IMG_W + KERNEL_SIZE - 2) begin
                $display(">>> MILESTONE: Window fully populated (first valid 5x5 patch). Full LB state:");
                print_line_buffers();
            end
            // After each full row completes (except first, already handled)
            if (pixel_count > IMG_W - 1 && (pixel_count % IMG_W) == IMG_W - 1) begin
                $display(">>> MILESTONE: Row %0d complete. Full LB state:", pixel_count / IMG_W);
                print_line_buffers();
            end
        end

        // =====================================================================
        // Stream a few more cycles with stream_en=0 to observe frozen state
        // =====================================================================
        stream_en      = 0;
        pixel_valid_in = 0;
        pixel_in       = '0;

        $display("-------------------------------------------------------------");
        $display("[%0t] Stream ended. Window is now frozen:", $time);
        repeat (3) @(posedge clk);
        #1;
        print_window();

        $display(">>> FINAL: Line Buffer SRAM contents after stream ended:");
        print_line_buffers();

        // =====================================================================
        // Finish
        // =====================================================================
        $display("");
        $display("=============================================================");
        $display(" TESTBENCH COMPLETE");
        $display("=============================================================");
        $display("");
        $display(" HOW TO READ THE RESULTS:");
        $display("   - The window is a 5x5 grid of pixel values.");
        $display("   - Row 0 is the NEWEST row (most recently written).");
        $display("   - Row 4 is the OLDEST row (delayed by 4 line buffers).");
        $display("   - Each cycle, columns shift LEFT and new data enters col 4.");
        $display("   - After streaming pixel #37 (row 4, col 4), the window");
        $display("     should contain the first valid 5x5 patch:");
        $display("        [  1  2  3  4  5 ]");
        $display("        [  9 10 11 12 13 ]");
        $display("        [ 17 18 19 20 21 ]");
        $display("        [ 25 26 27 28 29 ]");
        $display("        [ 33 34 35 36 37 ]");
        $display("   - This is the top-left 5x5 window of the 8x8 image.");
        $display("");
        $display(" HOW TO READ LINE BUFFER LOGS:");
        $display("   - 'LB R/W' shows what each LB reads (feeds into window col 4)");
        $display("     and what gets written back (overflow from window col 0).");
        $display("   - 'Waterfall' traces the delay cascade: pixel enters LB1,");
        $display("     emerges one row later, cascades to LB2, etc.");
        $display("   - Full LB dumps show all SRAM contents up to img_width.");
        $display("   - Each LB acts as a FIFO delay of exactly img_width cycles.");
        $display("=============================================================");

        #50;
        $finish;
    end

    // =========================================================================
    // Task: Print the 5x5 window content in a readable grid format
    // =========================================================================
    task print_window;
        begin
            $display("  Window 5x5:");
            for (int r = 0; r < KERNEL_SIZE; r++) begin
                $write("    [");
                for (int c = 0; c < KERNEL_SIZE; c++) begin
                    $write(" %3d", window_data_out[r][c]);
                end
                $display(" ]");
            end
            $display("");
        end
    endtask

    // =========================================================================
    // Task: Print the full SRAM contents of all 4 line buffers
    // Dumps addresses 0 to img_width-1 for each LB in tabular format
    // =========================================================================
    task print_line_buffers;
        begin
            $display("  Line Buffer SRAM Contents (addr 0..%0d):", img_width - 1);
            $write("    Addr |");
            for (int a = 0; a < img_width; a++) begin
                $write(" %3d", a);
            end
            $display("");
            $write("    -----|");
            for (int a = 0; a < img_width; a++) begin
                $write("----");
            end
            $display("");
            // LB1
            $write("    LB1  |");
            for (int a = 0; a < img_width; a++) begin
                $write(" %3d", dut.r_lb_1[a]);
            end
            $display("");
            // LB2
            $write("    LB2  |");
            for (int a = 0; a < img_width; a++) begin
                $write(" %3d", dut.r_lb_2[a]);
            end
            $display("");
            // LB3
            $write("    LB3  |");
            for (int a = 0; a < img_width; a++) begin
                $write(" %3d", dut.r_lb_3[a]);
            end
            $display("");
            // LB4
            $write("    LB4  |");
            for (int a = 0; a < img_width; a++) begin
                $write(" %3d", dut.r_lb_4[a]);
            end
            $display("");
            $display("");
        end
    endtask

    // =========================================================================
    // Timeout watchdog — prevent simulation from hanging
    // =========================================================================
    initial begin
        #100000;
        $display("[TIMEOUT] Simulation exceeded time limit!");
        $finish;
    end

endmodule
