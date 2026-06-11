#include <iostream>
#include <fstream>
#include <vector>
#include <iomanip>
#include <cstdlib>
#include <ctime>
#include <cstdint>

// Define hardware parameters
const int IFM_W = 10;
const int IFM_H = 10;
const int C_IN  = 1;
const int C_OUT = 16;
const int K_SIZE = 5;
const int OUT_W = IFM_W - K_SIZE + 1; // 6
const int OUT_H = IFM_H - K_SIZE + 1; // 6
const int RIGHT_SHIFT = 2;
const int RELU_EN = 1;

// Arrays to hold generated data
int8_t ref_ifm[IFM_H][IFM_W][C_IN];
int8_t ref_wgt[C_OUT][C_IN][K_SIZE][K_SIZE];
int16_t ref_bias[C_OUT];
int32_t ref_raw_psum[OUT_H][OUT_W][C_OUT];

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

                // Add Bias (Bypassed)
                psum += ref_bias[cout];

                // Right Shift Arithmetic (Bypassed)
                psum = psum >> RIGHT_SHIFT;

                // Saturating Clamp (Bypassed)
                if (psum > 127) psum = 127;
                else if (psum < -128) psum = -128;

                // ReLU (Bypassed)
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

    // 1. Write ifm.hex
    std::ofstream f_ifm("ifm.hex");
    for (int h = 0; h < IFM_H; h++) {
        for (int w = 0; w < IFM_W; w++) {
            for (int c = 0; c < C_IN; c++) {
                writeHex8(f_ifm, (uint8_t)ref_ifm[h][w][c]);
            }
        }
    }
    f_ifm.close();
    std::cout << "[+] Generated ifm.hex" << std::endl;

    // 2. Write wgt.hex (Packed according to hardware spec)
    std::ofstream f_wgt("wgt.hex");
    int total_wgt_elements = C_IN * K_SIZE * K_SIZE;
    int padded_elements_per_tile = ((total_wgt_elements + 15) / 16) * 16;
    int num_cout_tiles = (C_OUT + 15) / 16;
    
    std::vector<uint8_t> wgt_mem(num_cout_tiles * padded_elements_per_tile * 16, 0);

    for (int cout = 0; cout < C_OUT; cout++) {
        for (int cin = 0; cin < C_IN; cin++) {
            for (int kh = 0; kh < K_SIZE; kh++) {
                for (int kw = 0; kw < K_SIZE; kw++) {
                    int cout_tile = cout / 16;
                    int ch = cout % 16;
                    int elem = (cin * K_SIZE * K_SIZE) + (kh * K_SIZE) + kw;
                    int word_offset = (cout_tile * padded_elements_per_tile) + elem;
                    wgt_mem[(word_offset * 16) + ch] = (uint8_t)ref_wgt[cout][cin][kh][kw];
                }
            }
        }
    }
    
    // Write out weight DDR memory mapped bytes
    for(size_t i=0; i<wgt_mem.size(); i++) {
        writeHex8(f_wgt, wgt_mem[i]);
    }
    f_wgt.close();
    std::cout << "[+] Generated wgt.hex" << std::endl;

    // 3. Write bias.hex
    std::ofstream f_bias("bias.hex");
    for (int cout = 0; cout < C_OUT; cout++) {
        // Little Endian: LSB first, MSB second. Wait, check TB!
        // ddr_mem[WGT_ADDR + base + ch] = ref_bias[cout][7:0];
        // ddr_mem[WGT_ADDR + base + 16 + ch] = ref_bias[cout][15:8];
        // We write them sequentially as they appear in memory.
        // Actually, the testbench packs them across the 16 channels.
        // Let's create a padded bias memory structure exactly like TB did.
    }
    // Correct bias mapping based on testbench
    int bias_base_word = num_cout_tiles * padded_elements_per_tile;
    std::vector<uint8_t> bias_mem(num_cout_tiles * 32, 0); // 32 bytes per 16 output channels
    
    for (int cout = 0; cout < C_OUT; cout++) {
        int cout_tile = cout / 16;
        int ch = cout % 16;
        bias_mem[(cout_tile * 32) + ch] = (uint8_t)(ref_bias[cout] & 0xFF);
        bias_mem[(cout_tile * 32) + 16 + ch] = (uint8_t)((ref_bias[cout] >> 8) & 0xFF);
    }
    for(size_t i=0; i<bias_mem.size(); i++) {
        writeHex8(f_bias, bias_mem[i]);
    }
    f_bias.close();
    std::cout << "[+] Generated bias.hex" << std::endl;

    // 4. Write microcode.hex
    std::ofstream f_mc("microcode.hex");
    uint32_t mc[2][5] = {{0}};
    for (int i = 0; i < 25; i++) {
        int pass = i / 16;
        int r    = 15 - (i % 16);
        int cin  = 0;
        int ky   = 4 - (i / 5);
        int kx   = i % 5;
        
        // Pack into mc
        // mc[pass][w*32 +: 32] -> wait, the SV code is:
        // mc[pass][r*10 + 7 +: 3] = ky;
        // mc[pass][r*10 + 4 +: 3] = kx;
        // mc[pass][r*10 + 0 +: 4] = cin;
    }
    // We need 160-bit logic per pass. In C++ we can use an array of 5 32-bit uints to represent 160 bits.
    uint32_t mc_data[2][5] = {{0}};
    for (int i = 0; i < 25; i++) {
        int pass = i / 16;
        int r    = 15 - (i % 16);
        int cin_val = 0;
        int ky   = 4 - (i / 5);
        int kx   = i % 5;
        
        int bit_offset = r * 10;
        int word_idx = bit_offset / 32;
        int local_bit = bit_offset % 32;
        
        // It's much easier to use a 160-bit integer or byte array.
        // Let's implement bit packing for microcode carefully.
    }
    // Actually, I'll rewrite the microcode generation bit packing carefully.
    uint8_t mc_bytes[2][20] = {{0}}; // 160 bits = 20 bytes
    for (int i = 0; i < 25; i++) {
        int pass = i / 16;
        int r    = 15 - (i % 16);
        int cin_val = 0;
        int kh   = 4 - (i / 5);
        int kw   = i % 5;
        
        uint16_t pack = (kh << 7) | (kw << 4) | (cin_val & 0xF); // 10 bits
        
        // Write 10 bits into mc_bytes starting at bit offset r*10
        int bit_idx = r * 10;
        int byte_idx = bit_idx / 8;
        int bit_shift = bit_idx % 8;
        
        // This overlaps up to 3 bytes
        mc_bytes[pass][byte_idx] |= (pack << bit_shift) & 0xFF;
        if (bit_shift + 10 > 8) {
            mc_bytes[pass][byte_idx + 1] |= (pack >> (8 - bit_shift)) & 0xFF;
        }
        if (bit_shift + 10 > 16) {
            mc_bytes[pass][byte_idx + 2] |= (pack >> (16 - bit_shift)) & 0xFF;
        }
    }
    // Now write out 32-bit words (5 words per pass)
    for (int pass = 0; pass < 2; pass++) {
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

    // 5. Write instructions.hex
    std::ofstream f_inst("instructions.hex");
    // format: [63:60] Opcode, ...
    writeHex64(f_inst, 0x1000000010000000ULL); // SET ADDR IFM
    writeHex64(f_inst, 0x1400000020000000ULL); // SET ADDR WGT
    writeHex64(f_inst, 0x1800000030000000ULL); // SET ADDR OFM
    
    int dma_wgt_bytes = (bias_base_word * 16) + (C_OUT * 2);
    writeHex64(f_inst, 0x4000000000000000ULL | dma_wgt_bytes); // LOAD_WGT
    
    int dma_ifm_bytes = IFM_H * IFM_W * 16; // wait, TB said: dma_ifm_bytes = IFM_H * IFM_W * 16; Wait, if C_IN=1, why * 16? 
    // TB actually has: automatic int dma_ifm_bytes = IFM_H * IFM_W * 16;
    // Ah, because AXI bus is 16 bytes. If it's a 10x10=100 elements, how does DMA load it? 1 byte per element.
    // In TB: ref_ifm[h][w][c], stored at IFM_ADDR + (h*IFM_W+w)*16 + c. So it's 16 bytes per spatial location.
    // I should fix the ifm.hex generation to account for 16-channel padding!
    writeHex64(f_inst, 0xA000000000000000ULL | dma_ifm_bytes); // LOAD_IFM
    writeHex64(f_inst, 0x5000000000000000ULL); // RUN_MAC
    writeHex64(f_inst, 0x7000000000000000ULL | 576); // STORE_OFM (6x6x16 = 576)
    writeHex64(f_inst, 0xF000000000000000ULL); // FINISH
    f_inst.close();
    std::cout << "[+] Generated instructions.hex" << std::endl;

    // Let's fix ifm.hex memory map. TB maps it as:
    // ddr_mem[IFM_ADDR + (h * IFM_W + w) * 16 + c] = ref_ifm[h][w][c];
    // So IFM has 16 bytes per spatial location!
    std::ofstream f_ifm2("ifm.hex"); // overwrite
    std::vector<uint8_t> ifm_mem(IFM_H * IFM_W * 16, 0);
    for (int h = 0; h < IFM_H; h++) {
        for (int w = 0; w < IFM_W; w++) {
            for (int c = 0; c < C_IN; c++) {
                ifm_mem[(h * IFM_W + w) * 16 + c] = (uint8_t)ref_ifm[h][w][c];
            }
        }
    }
    for(size_t i=0; i<ifm_mem.size(); i++) {
        writeHex8(f_ifm2, ifm_mem[i]);
    }
    f_ifm2.close();

    // 6. Write golden_ofm.hex (8-bit values)
    std::ofstream f_ofm("golden_ofm.hex");
    // OFM memory map in TB:
    // offset = (h * OUT_W + w) * 16 + cout;
    std::vector<uint8_t> ofm_mem(OUT_H * OUT_W * 16, 0);
    for (int h = 0; h < OUT_H; h++) {
        for (int w = 0; w < OUT_W; w++) {
            for (int cout = 0; cout < C_OUT; cout++) {
                ofm_mem[(h * OUT_W + w) * 16 + cout] = (uint8_t)ref_raw_psum[h][w][cout];
            }
        }
    }
    for(size_t i=0; i<ofm_mem.size(); i++) {
        writeHex8(f_ofm, ofm_mem[i]);
    }
    f_ofm.close();
    std::cout << "[+] Generated golden_ofm.hex (8-bit)" << std::endl;

    return 0;
}
