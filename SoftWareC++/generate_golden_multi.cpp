#include <iostream>
#include <fstream>
#include <vector>
#include <iomanip>
#include <cstdlib>
#include <ctime>
#include <cstdint>

// Helper to write a 1-byte hex value
void writeHex8(std::ofstream& file, uint8_t val) {
    file << std::hex << std::setw(2) << std::setfill('0') << (int)val << std::endl;
}

// Helper to write a 4-byte hex value
void writeHex32(std::ofstream& file, uint32_t val) {
    file << std::hex << std::setw(8) << std::setfill('0') << val << std::endl;
}

// Helper to write an 8-byte hex value
void writeHex64(std::ofstream& file, uint64_t val) {
    file << std::hex << std::setw(16) << std::setfill('0') << val << std::endl;
}

int main(int argc, char* argv[]) {
    if (argc < 5) {
        std::cerr << "Usage: " << argv[0] << " IFM_W IFM_H C_IN C_OUT [RELU_EN] [RIGHT_SHIFT]" << std::endl;
        return 1;
    }

    int IFM_W = std::atoi(argv[1]);
    int IFM_H = std::atoi(argv[2]);
    int C_IN  = std::atoi(argv[3]);
    int C_OUT = std::atoi(argv[4]);
    int RELU_EN = (argc > 5) ? std::atoi(argv[5]) : 1;
    int RIGHT_SHIFT = (argc > 6) ? std::atoi(argv[6]) : 2;
    int K_SIZE = 5;
    
    int OUT_W = IFM_W - K_SIZE + 1;
    int OUT_H = IFM_H - K_SIZE + 1;

    int num_cout_tiles = (C_OUT + 15) / 16;
    int num_elements = C_IN * 25;
    int num_passes = (num_elements + 15) / 16;

    std::string out_dir = "e:\\Projects\\LeNet-5 on FPGA\\LeNet5OnFPGA\\LeNet5OnFPGA.sim\\sim_1\\behav\\xsim\\";

    std::cout << "Generating test vectors for: " << IFM_W << "x" << IFM_H << "x" << C_IN << " -> " << C_OUT << std::endl;
    std::cout << "Tiles: " << num_cout_tiles << ", Passes: " << num_passes << std::endl;

    srand(time(NULL));

    // Allocate memory
    std::vector<std::vector<std::vector<int8_t>>> ref_ifm(IFM_H, std::vector<std::vector<int8_t>>(IFM_W, std::vector<int8_t>(C_IN)));
    
    // Weights: [cout][cin][kh][kw]
    std::vector<std::vector<std::vector<std::vector<int8_t>>>> ref_wgt(C_OUT, std::vector<std::vector<std::vector<int8_t>>>(C_IN, std::vector<std::vector<int8_t>>(K_SIZE, std::vector<int8_t>(K_SIZE))));
    
    std::vector<int16_t> ref_bias(C_OUT);
    
    // OFM: [h][w][cout]
    std::vector<std::vector<std::vector<int32_t>>> ref_raw_psum(OUT_H, std::vector<std::vector<int32_t>>(OUT_W, std::vector<int32_t>(C_OUT)));
    std::vector<std::vector<std::vector<int32_t>>> ref_raw_mac(OUT_H, std::vector<std::vector<int32_t>>(OUT_W, std::vector<int32_t>(C_OUT)));
    std::vector<std::vector<std::vector<int32_t>>> ref_temp_sum(OUT_H, std::vector<std::vector<int32_t>>(OUT_W, std::vector<int32_t>(C_OUT)));
    std::vector<std::vector<std::vector<int32_t>>> ref_temp_shifted(OUT_H, std::vector<std::vector<int32_t>>(OUT_W, std::vector<int32_t>(C_OUT)));

    // Generate random data
    for (int h = 0; h < IFM_H; h++) {
        for (int w = 0; w < IFM_W; w++) {
            for (int c = 0; c < C_IN; c++) {
                ref_ifm[h][w][c] = (rand() % 256) - 128;
            }
        }
    }

    for (int cout = 0; cout < C_OUT; cout++) {
        for (int cin = 0; cin < C_IN; cin++) {
            for (int kh = 0; kh < K_SIZE; kh++) {
                for (int kw = 0; kw < K_SIZE; kw++) {
                    ref_wgt[cout][cin][kh][kw] = (rand() % 256) - 128;
                }
            }
        }
        ref_bias[cout] = (rand() % 65536) - 32768;
    }

    // 1. Write ifm.hex
    std::ofstream f_ifm(out_dir + "ifm.hex");
    for (int h = 0; h < IFM_H; h++) {
        for (int w = 0; w < IFM_W; w++) {
            for (int c = 0; c < 16; c++) { // DMA writes/reads 16 channels per beat (128-bit)
                if (c < C_IN) {
                    writeHex8(f_ifm, ref_ifm[h][w][c]);
                } else {
                    writeHex8(f_ifm, 0); // padding
                }
            }
        }
    }
    f_ifm.close();
    std::cout << "[+] Generated ifm.hex" << std::endl;

    // 2. Write wgt.hex
    std::ofstream f_wgt(out_dir + "wgt.hex");
    for (int cout_tile = 0; cout_tile < num_cout_tiles; cout_tile++) {
        for (int pass = 0; pass < num_passes; pass++) {
            for (int cnt = 0; cnt < 16; cnt++) {
                int r = 15 - cnt; 
                int i = pass * 16 + cnt;
                
                for (int ch = 0; ch < 16; ch++) {
                    int cout = cout_tile * 16 + ch;
                    if (i < num_elements && cout < C_OUT) {
                        int spatial_idx = i / C_IN;
                        int kh = spatial_idx / 5;
                        int kw = spatial_idx % 5;
                        int cin = i % C_IN;
                        writeHex8(f_wgt, ref_wgt[cout][cin][kh][kw]);
                    } else {
                        writeHex8(f_wgt, 0);
                    }
                }
            }
        }
    }
    f_wgt.close();
    std::cout << "[+] Generated wgt.hex" << std::endl;

    // 3. Write bias.hex
    std::ofstream f_bias(out_dir + "bias.hex");
    for (int cout_tile = 0; cout_tile < num_cout_tiles; cout_tile++) {
        for (int ch = 0; ch < 16; ch++) {
            int cout = cout_tile * 16 + ch;
            int16_t val = (cout < C_OUT) ? ref_bias[cout] : 0;
            writeHex8(f_bias, (uint8_t)(val & 0xFF));
        }
        for (int ch = 0; ch < 16; ch++) {
            int cout = cout_tile * 16 + ch;
            int16_t val = (cout < C_OUT) ? ref_bias[cout] : 0;
            writeHex8(f_bias, (uint8_t)((val >> 8) & 0xFF));
        }
    }
    f_bias.close();
    std::cout << "[+] Generated bias.hex" << std::endl;

    // 4. Write microcode.hex
    std::ofstream f_mc(out_dir + "microcode.hex");
    std::vector<std::vector<uint8_t>> mc_bytes(num_passes, std::vector<uint8_t>(20, 0));
    for (int pass = 0; pass < num_passes; pass++) {
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
    
    for (int pass = 0; pass < num_passes; pass++) {
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

    // 5. Compute Reference Convolution
    for (int h = 0; h < OUT_H; h++) {
        for (int w = 0; w < OUT_W; w++) {
            for (int cout = 0; cout < C_OUT; cout++) {
                int32_t psum = 0;
                for (int cin = 0; cin < C_IN; cin++) {
                    for (int kh = 0; kh < K_SIZE; kh++) {
                        for (int kw = 0; kw < K_SIZE; kw++) {
                            psum += ref_ifm[h + kh][w + kw][cin] * ref_wgt[cout][cin][kh][kw];
                        }
                    }
                }

                int32_t raw_mac = psum;
                int32_t temp_sum = raw_mac + ref_bias[cout];
                int32_t temp_shifted = temp_sum >> RIGHT_SHIFT;

                psum = temp_shifted;

                if (psum > 127) psum = 127;
                else if (psum < -128) psum = -128;

                if (RELU_EN && psum < 0) psum = 0;

                ref_raw_psum[h][w][cout] = psum;
                ref_raw_mac[h][w][cout] = raw_mac;
                ref_temp_sum[h][w][cout] = temp_sum;
                ref_temp_shifted[h][w][cout] = temp_shifted;
            }
        }
    }

    // Write golden_psum_signed.txt
    std::ofstream f_raw_psum(out_dir + "golden_psum_signed.txt");
    for (int h = 0; h < OUT_H; h++) {
        for (int w = 0; w < OUT_W; w++) {
            f_raw_psum << "ofm_addr: " << (h * OUT_W + w) << "\n";
            for (int cout = 0; cout < C_OUT; cout++) {
                f_raw_psum << "  [" << cout << "]: PSUM=" << ref_raw_mac[h][w][cout] 
                           << ", BIAS=" << ref_bias[cout]
                           << ", temp_sum=" << ref_temp_sum[h][w][cout]
                           << ", temp_shifted=" << ref_temp_shifted[h][w][cout] << "\n";
            }
        }
    }
    f_raw_psum.close();
    std::cout << "[+] Generated golden_psum_signed.txt" << std::endl;

    // Write golden_ofm.hex in NHWC interleaved tiles
    std::ofstream f_ofm(out_dir + "golden_ofm.hex");
    for (int h = 0; h < OUT_H; h++) {
        for (int w = 0; w < OUT_W; w++) {
            for (int tile = 0; tile < num_cout_tiles; tile++) {
                for (int ch = 0; ch < 16; ch++) {
                    int cout = tile * 16 + ch;
                    if (cout < C_OUT) {
                        writeHex8(f_ofm, ref_raw_psum[h][w][cout]);
                    } else {
                        writeHex8(f_ofm, 0); // padding
                    }
                }
            }
        }
    }
    f_ofm.close();
    std::cout << "[+] Generated golden_ofm.hex" << std::endl;

    // 6. Write golden_window_stream.txt (FOR HARDWARE WAVEFORM DEBUGGING)
    std::ofstream f_win(out_dir + "golden_window_stream.txt");
    for (int h = 0; h < OUT_H; h++) {
        for (int w = 0; w < OUT_W; w++) {
            f_win << "========================================\n";
            f_win << "Valid Window at (h=" << h << ", w=" << w << "):\n";
            for (int pass = 0; pass < num_passes; pass++) {
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

    // 7. Write instructions.hex
    std::ofstream f_inst(out_dir + "instructions.hex");
    writeHex64(f_inst, 0x1000000010000000ULL); // SET ADDR IFM
    writeHex64(f_inst, 0x1400000020000000ULL); // SET ADDR WGT
    writeHex64(f_inst, 0x1800000030000000ULL); // SET ADDR OFM

    uint64_t inst_dim = 0x2000000000000000ULL | ((uint64_t)IFM_W << 32) | ((uint64_t)IFM_H << 16) | (C_IN);
    writeHex64(f_inst, inst_dim); 

    uint64_t inst_knl = 0x3000000000000000ULL | ((uint64_t)C_OUT << 16) | ((uint64_t)K_SIZE << 8) | (1 << 4) | (RIGHT_SHIFT);
    writeHex64(f_inst, inst_knl);

    int ifm_bytes = IFM_W * IFM_H * 16; 
    writeHex64(f_inst, 0xA000000000000000ULL | ifm_bytes);

    int wgt_bytes = num_cout_tiles * num_passes * 16 * 16; 
    int bias_bytes = num_cout_tiles * 32;
    writeHex64(f_inst, 0x4000000000000000ULL | (wgt_bytes + bias_bytes));

    writeHex64(f_inst, 0x5000000000000000ULL | RELU_EN);

    int ofm_bytes = OUT_W * OUT_H * num_cout_tiles * 16;
    writeHex64(f_inst, 0x7000000000000000ULL | ofm_bytes);

    writeHex64(f_inst, 0xF000000000000000ULL);
    f_inst.close();
    std::cout << "[+] Generated instructions.hex" << std::endl;

    return 0;
}
