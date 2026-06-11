#include <iostream>
#include <fstream>
#include <vector>
#include <iomanip>
#include <cstdlib>
#include <ctime>
#include <cstdint>
#include <string>

// Hardware parameters for Conv5
const int IFM_W = 5;
const int IFM_H = 5;
const int C_IN  = 16;
const int C_OUT = 120;
const int K_SIZE = 5;
const int OUT_W = 1;
const int OUT_H = 1;
const int RIGHT_SHIFT = 10;
const int RELU_EN = 1;

// Padding target dimensions
const int COUT_TILES = 8;  // ceil(120 / 16)
const int NUM_PASSES = 25; // (16 * 5 * 5) / 16

// Reference arrays
int8_t ref_ifm[IFM_H][IFM_W][C_IN];
int8_t ref_wgt[C_OUT][C_IN][K_SIZE][K_SIZE];
int16_t ref_bias[C_OUT];
int32_t ref_raw_psum[OUT_H][OUT_W][C_OUT];
int32_t ref_raw_mac[OUT_H][OUT_W][C_OUT];
int32_t ref_temp_sum[OUT_H][OUT_W][C_OUT];
int32_t ref_temp_shifted[OUT_H][OUT_W][C_OUT];

// Helper to write a 128-bit hex line (16 bytes)
// In SystemVerilog, the LSB (index 0) is written at the right (last), 
// and the MSB (index 15) is written at the left (first).
void writeHex128(std::ofstream& file, const std::vector<uint8_t>& bytes) {
    for (int i = 15; i >= 0; i--) {
        file << std::hex << std::setw(2) << std::setfill('0') << (int)bytes[i];
    }
    file << std::endl;
}

// Helper to write a 32-bit hex line (4 bytes)
void writeHex32(std::ofstream& file, uint32_t val) {
    file << std::hex << std::setw(8) << std::setfill('0') << val << std::endl;
}

void generate_data() {
    // Generate IFM
    for (int h = 0; h < IFM_H; h++) {
        for (int w = 0; w < IFM_W; w++) {
            for (int c = 0; c < C_IN; c++) {
                ref_ifm[h][w][c] = (rand() % 256) - 128;
            }
        }
    }

    // Generate Weights
    for (int cout = 0; cout < C_OUT; cout++) {
        for (int cin = 0; cin < C_IN; cin++) {
            for (int kh = 0; kh < K_SIZE; kh++) {
                for (int kw = 0; kw < K_SIZE; kw++) {
                    ref_wgt[cout][cin][kh][kw] = (rand() % 256) - 128;
                }
            }
        }
    }

    // Generate Bias
    for (int cout = 0; cout < C_OUT; cout++) {
        ref_bias[cout] = (rand() % 65536) - 32768;
    }
}

void compute_reference() {
    for (int h = 0; h < OUT_H; h++) {
        for (int w = 0; w < OUT_W; w++) {
            for (int cout = 0; cout < C_OUT; cout++) {
                int32_t psum = 0;

                // Convolution
                for (int cin = 0; cin < C_IN; cin++) {
                    for (int kh = 0; kh < K_SIZE; kh++) {
                        for (int kw = 0; kw < K_SIZE; kw++) {
                            psum += ref_ifm[h + kh][w + kw][cin] * ref_wgt[cout][cin][kh][kw];
                        }
                    }
                }

                ref_raw_mac[h][w][cout] = psum;
                int32_t temp_sum = psum + ref_bias[cout];
                ref_temp_sum[h][w][cout] = temp_sum;

                int32_t temp_shifted = temp_sum >> RIGHT_SHIFT;
                ref_temp_shifted[h][w][cout] = temp_shifted;

                psum = temp_shifted;

                // Saturating Clamp
                if (psum > 127) psum = 127;
                else if (psum < -128) psum = -128;

                // ReLU
                if (RELU_EN && psum < 0) psum = 0;

                ref_raw_psum[h][w][cout] = psum;
            }
        }
    }
}

int main() {
    srand(42); // Seed for reproducibility
    generate_data();
    compute_reference();

    std::string out_dir = "e:\\Projects\\LeNet-5 on FPGA\\LeNet5OnFPGA\\LeNet5OnFPGA.sim\\sim_1\\behav\\xsim\\";

    std::cout << "[+] Generating Conv5 tiling golden vectors..." << std::endl;

    // 1. Write ifm.hex (25 lines of 128-bit)
    std::ofstream f_ifm(out_dir + "ifm.hex");
    if (!f_ifm.is_open()) {
        std::cerr << "[-] Error opening ifm.hex at: " << out_dir << std::endl;
        return 1;
    }
    for (int h = 0; h < IFM_H; h++) {
        for (int w = 0; w < IFM_W; w++) {
            std::vector<uint8_t> bytes(16, 0);
            for (int c = 0; c < C_IN; c++) {
                bytes[c] = (uint8_t)ref_ifm[h][w][c];
            }
            writeHex128(f_ifm, bytes);
        }
    }
    f_ifm.close();
    std::cout << "[+] Generated ifm.hex" << std::endl;

    // 2. Write weight.hex (3200 lines of 128-bit)
    std::ofstream f_wgt(out_dir + "weight.hex");
    if (!f_wgt.is_open()) {
        std::cerr << "[-] Error opening weight.hex at: " << out_dir << std::endl;
        return 1;
    }
    int num_elements = C_IN * K_SIZE * K_SIZE; // 400
    for (int cout_tile = 0; cout_tile < COUT_TILES; cout_tile++) {
        for (int pass = 0; pass < NUM_PASSES; pass++) {
            for (int cnt = 0; cnt < 16; cnt++) {
                int i = pass * 16 + cnt;
                std::vector<uint8_t> bytes(16, 0);

                for (int ch = 0; ch < 16; ch++) {
                    int cout = cout_tile * 16 + ch;
                    if (i < num_elements && cout < C_OUT) {
                        int spatial_idx = i / C_IN;
                        int kh = spatial_idx / 5;
                        int kw = spatial_idx % 5;
                        int cin = i % C_IN;
                        bytes[ch] = (uint8_t)ref_wgt[cout][cin][kh][kw];
                    }
                }
                writeHex128(f_wgt, bytes);
            }
        }
    }
    f_wgt.close();
    std::cout << "[+] Generated weight.hex" << std::endl;

    // 3. Write bias.hex (128 lines of 16-bit hex)
    std::ofstream f_bias(out_dir + "bias.hex");
    if (!f_bias.is_open()) {
        std::cerr << "[-] Error opening bias.hex at: " << out_dir << std::endl;
        return 1;
    }
    for (int cout_tile = 0; cout_tile < COUT_TILES; cout_tile++) {
        for (int ch = 0; ch < 16; ch++) {
            int cout = cout_tile * 16 + ch;
            int16_t val = (cout < C_OUT) ? ref_bias[cout] : 0;
            f_bias << std::hex << std::setw(4) << std::setfill('0') << (uint16_t)val << std::endl;
        }
    }
    f_bias.close();
    std::cout << "[+] Generated bias.hex" << std::endl;

    // 3b. Write microcode.hex (NUM_PASSES * 5 lines of 32-bit)
    std::ofstream f_mc(out_dir + "microcode.hex");
    if (!f_mc.is_open()) {
        std::cerr << "[-] Error opening microcode.hex at: " << out_dir << std::endl;
        return 1;
    }
    std::vector<std::vector<uint8_t>> mc_bytes(NUM_PASSES, std::vector<uint8_t>(20, 0));
    for (int pass = 0; pass < NUM_PASSES; pass++) {
        for (int r = 0; r < 16; r++) {
            int cnt = 15 - r;
            int i = pass * 16 + cnt;
            
            int ky = 0, kx = 0, cin = 0;
            if (i < num_elements) {
                int spatial_idx = i / C_IN;
                int kh = spatial_idx / 5;
                int kw = spatial_idx % 5;
                ky = 4 - kh; // Hardware Y=4 maps to C++ kh=0
                kx = kw;
                cin = i % C_IN;
            }
            
            uint16_t pack = (ky << 7) | (kx << 4) | (cin & 0xF); // 10 bits
            
            int bit_idx = r * 10;
            int byte_idx = bit_idx / 8;
            int bit_shift = bit_idx % 8;
            
            mc_bytes[pass][byte_idx] |= (pack << bit_shift) & 0xFF;
            if (bit_shift + 10 > 8) {
                mc_bytes[pass][byte_idx + 1] |= (pack >> (8 - bit_shift)) & 0xFF;
            }
            if (bit_shift + 10 > 16) {
                mc_bytes[pass][byte_idx + 2] |= (pack >> (16 - bit_shift)) & 0xFF;
            }
        }
    }
    for (int pass = 0; pass < NUM_PASSES; pass++) {
        for (int w = 0; w < 5; w++) {
            uint32_t word = 0;
            word |= mc_bytes[pass][w*4 + 0];
            word |= (mc_bytes[pass][w*4 + 1] << 8);
            word |= (mc_bytes[pass][w*4 + 2] << 16);
            word |= (mc_bytes[pass][w*4 + 3] << 24);
            writeHex32(f_mc, word);
        }
    }
    f_mc.close();
    std::cout << "[+] Generated microcode.hex" << std::endl;

    // 4. Write expected_ofm.hex (128 lines of 8-bit hex)
    std::ofstream f_ofm(out_dir + "expected_ofm.hex");
    if (!f_ofm.is_open()) {
        std::cerr << "[-] Error opening expected_ofm.hex at: " << out_dir << std::endl;
        return 1;
    }
    for (int cout_tile = 0; cout_tile < COUT_TILES; cout_tile++) {
        for (int ch = 0; ch < 16; ch++) {
            int cout = cout_tile * 16 + ch;
            uint8_t val = (cout < C_OUT) ? (uint8_t)ref_raw_psum[0][0][cout] : 0;
            f_ofm << std::hex << std::setw(2) << std::setfill('0') << (int)val << std::endl;
        }
    }
    f_ofm.close();
    std::cout << "[+] Generated expected_ofm.hex (128 lines of 8-bit hex)" << std::endl;

    // 5. Write golden_psum_signed.txt
    std::ofstream f_raw_psum(out_dir + "golden_psum_signed.txt");
    if (f_raw_psum.is_open()) {
        for (int h = 0; h < OUT_H; h++) {
            for (int w = 0; w < OUT_W; w++) {
                for (int cout_tile = 0; cout_tile < COUT_TILES; cout_tile++) {
                    f_raw_psum << "ofm_addr: " << (h * OUT_W + w) << "\n";
                    for (int ch = 0; ch < 16; ch++) {
                        int cout = cout_tile * 16 + ch;
                        int32_t psum_val = 0;
                        int32_t bias_val = 0;
                        int32_t temp_sum_val = 0;
                        int32_t temp_shifted_val = 0;
                        if (cout < C_OUT) {
                            psum_val = ref_raw_mac[h][w][cout];
                            bias_val = ref_bias[cout];
                            temp_sum_val = ref_temp_sum[h][w][cout];
                            temp_shifted_val = ref_temp_shifted[h][w][cout];
                        }
                        f_raw_psum << "  [" << ch << "]: PSUM=" << psum_val 
                                   << ", BIAS=" << bias_val
                                   << ", temp_sum=" << temp_sum_val
                                   << ", temp_shifted=" << temp_shifted_val << "\n";
                    }
                }
            }
        }
        f_raw_psum.close();
        std::cout << "[+] Generated golden_psum_signed.txt" << std::endl;
    } else {
        std::cerr << "[-] Error opening golden_psum_signed.txt" << std::endl;
    }

    // 6. Write golden_window_stream.txt (FOR HARDWARE WAVEFORM DEBUGGING)
    std::ofstream f_win(out_dir + "golden_window_stream.txt");
    if (f_win.is_open()) {
        int num_elements = C_IN * K_SIZE * K_SIZE; // 400
        for (int h = 0; h < OUT_H; h++) {
            for (int w = 0; w < OUT_W; w++) {
                f_win << "========================================\n";
                f_win << "Valid Window at (h=" << h << ", w=" << w << "):\n";
                for (int pass = 0; pass < NUM_PASSES; pass++) {
                    f_win << "  Pass " << pass << ": [";
                    for (int r = 0; r < 16; r++) {
                        int cnt = 15 - r;
                        int i = pass * 16 + cnt;
                        if (i < num_elements) {
                            int spatial_idx = i / C_IN;
                            int kh = spatial_idx / 5;
                            int kw = spatial_idx % 5;
                            int cin = i % C_IN;
                            int val = ref_ifm[h + kh][w + kw][cin];
                            f_win << std::setw(4) << val;
                        } else {
                            f_win << "   0"; // Padding
                        }
                        if (r < 15) f_win << ", ";
                    }
                    f_win << "]\n";
                }
            }
        }
        f_win.close();
        std::cout << "[+] Generated golden_window_stream.txt" << std::endl;
    } else {
        std::cerr << "[-] Error opening golden_window_stream.txt" << std::endl;
    }

    std::cout << "[+] All golden files generated successfully." << std::endl;

    return 0;
}
