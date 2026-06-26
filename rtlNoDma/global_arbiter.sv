`timescale 1ns / 1ps

module global_arbiter #(
    parameter AXI_AWIDTH  = 40, 
    parameter AXI_DWIDTH  = 64,
    parameter SRAM_DWIDTH = 128,
    parameter SRAM_AWIDTH = 11 
)(
    input  logic clk,
    input  logic rst_n,

    // =========================================================
    // 1. GIAO DIỆN VỚI CPU HOST (AXI-Lite Slave)
    // =========================================================
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,
    input  logic [31:0]             s_axi_awaddr,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,
    input  logic [31:0]             s_axi_wdata,

    // =========================================================
    // 2. GIAO DIỆN AXI STREAM (S_AXIS & M_AXIS)
    // =========================================================
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    input  logic [127:0]            s_axis_tdata,
    input  logic                    s_axis_tlast,
    input  logic [3:0]              s_axis_tdest,

    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic [127:0]            m_axis_tdata,
    output logic                    m_axis_tlast,

    // =========================================================
    // 3. LUỒNG ĐI TỚI CONTROLLER (Instruction FIFO)
    // =========================================================
    output logic [63:0]             ctrl_inst_data_o,
    output logic                    ctrl_inst_empty_o,
    input  logic                    ctrl_inst_read_i,
    
    // =========================================================
    // 4. LUỒNG ĐI TỚI CÁC BANK MEMORY (SRAM Interfaces)
    // =========================================================
    output logic                    wgt_we_o,
    output logic [SRAM_AWIDTH-1:0]  wgt_addr_o,
    output logic [SRAM_DWIDTH-1:0]  wgt_wdata_o,

    output logic                    ping_we_o,
    output logic [SRAM_AWIDTH-1:0]  ping_addr_o,
    output logic [SRAM_DWIDTH-1:0]  ping_wdata_o,
    input  logic [SRAM_DWIDTH-1:0]  ping_rdata_i,

    output logic                    pong_we_o,
    output logic [SRAM_AWIDTH-1:0]  pong_addr_o,
    output logic [SRAM_DWIDTH-1:0]  pong_wdata_o,
    input  logic [SRAM_DWIDTH-1:0]  pong_rdata_i
);

    // ---------------------------------------------------------
    // KHỐI 1: S_AXIS TDEST ROUTING & INGESTION
    // ---------------------------------------------------------
    logic w_fifo_full;
    logic w_fifo_wr_en;
    logic [63:0] w_fifo_wr_data;
    
    // Instruction FIFO (TDEST == 0)
    assign w_fifo_wr_en = s_axis_tvalid && (s_axis_tdest == 4'd0);
    assign w_fifo_wr_data = s_axis_tdata[63:0];
    
    instruction_fifo u_inst_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en      (w_fifo_wr_en && !w_fifo_full), // Prevent write if full
        .wr_data    (w_fifo_wr_data),
        .full       (w_fifo_full),
        .rd_en      (ctrl_inst_read_i),
        .rd_data    (ctrl_inst_data_o),
        .empty      (ctrl_inst_empty_o)
    );

    // Auto-incrementing address counters for SRAM banks
    logic [SRAM_AWIDTH-1:0] wgt_write_addr_reg;
    logic [SRAM_AWIDTH-1:0] ping_write_addr_reg;
    logic [SRAM_AWIDTH-1:0] pong_write_addr_reg;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wgt_write_addr_reg <= '0;
            ping_write_addr_reg <= '0;
            pong_write_addr_reg <= '0;
        end else begin
            if (s_axis_tvalid && s_axis_tready) begin
                if (s_axis_tdest == 4'd1) begin
                    if (s_axis_tlast) wgt_write_addr_reg <= '0;
                    else wgt_write_addr_reg <= wgt_write_addr_reg + 1;
                end else if (s_axis_tdest == 4'd2) begin
                    if (s_axis_tlast) ping_write_addr_reg <= '0;
                    else ping_write_addr_reg <= ping_write_addr_reg + 1;
                end else if (s_axis_tdest == 4'd3) begin
                    if (s_axis_tlast) pong_write_addr_reg <= '0;
                    else pong_write_addr_reg <= pong_write_addr_reg + 1;
                end
            end
        end
    end
    
    // SRAM Write enables (combining valid and TDEST)
    assign wgt_we_o = s_axis_tvalid && (s_axis_tdest == 4'd1);
    assign wgt_addr_o = wgt_write_addr_reg;
    assign wgt_wdata_o = s_axis_tdata;
    
    assign ping_we_o = s_axis_tvalid && (s_axis_tdest == 4'd2);
    assign ping_wdata_o = s_axis_tdata;
    
    assign pong_we_o = s_axis_tvalid && (s_axis_tdest == 4'd3);
    assign pong_wdata_o = s_axis_tdata;

    // S_AXIS Ready: Target is ready if FIFO not full (for inst) or always ready for SRAMs
    assign s_axis_tready = (s_axis_tdest == 4'd0) ? ~w_fifo_full : 1'b1;

    // ---------------------------------------------------------
    // KHỐI 2: AXI-LITE CONTROL & M_AXIS CONFIG
    // ---------------------------------------------------------
    logic [1:0]  m_axis_src_bank; // 0=Ping, 1=Pong
    logic [31:0] m_axis_length;
    logic        m_axis_start;
    
    logic w_axi_write_fire;
    assign w_axi_write_fire = s_axi_awvalid && s_axi_wvalid && s_axi_awready && s_axi_wready;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_src_bank <= '0;
            m_axis_length <= '0;
            m_axis_start <= 1'b0;
        end else begin
            // Auto-clear start pulse
            if (m_axis_start) m_axis_start <= 1'b0;
            
            if (w_axi_write_fire) begin
                case (s_axi_awaddr[7:0])
                    8'h20: m_axis_src_bank <= s_axi_wdata[1:0];
                    8'h24: m_axis_length <= s_axi_wdata;
                    8'h28: m_axis_start <= s_axi_wdata[0];
                endcase
            end
        end
    end
    
    // Always accept AXI-Lite writes immediately
    assign s_axi_awready = 1'b1;
    assign s_axi_wready  = 1'b1;

    // ---------------------------------------------------------
    // KHỐI 3: M_AXIS STATE MACHINE
    // ---------------------------------------------------------
    typedef enum logic [1:0] { IDLE, READ_SRAM, STREAM_OUT } m_axis_state_t;
    m_axis_state_t m_state;
    
    logic [31:0] m_axis_cnt;
    logic [SRAM_AWIDTH-1:0] m_read_addr;
    logic [1:0] m_active_bank;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_state <= IDLE;
            m_axis_cnt <= '0;
            m_read_addr <= '0;
            m_active_bank <= '0;
        end else begin
            case (m_state)
                IDLE: begin
                    if (m_axis_start && m_axis_length > 0) begin
                        m_state <= READ_SRAM;
                        m_active_bank <= m_axis_src_bank;
                        m_read_addr <= '0;
                        m_axis_cnt <= m_axis_length;
                    end
                end
                
                READ_SRAM: begin
                    // 1 cycle bubble to wait for SRAM read data
                    m_state <= STREAM_OUT;
                end
                
                STREAM_OUT: begin
                    if (m_axis_tready) begin
                        m_axis_cnt <= m_axis_cnt - 1;
                        if (m_axis_cnt == 1) begin
                            m_state <= IDLE;
                        end else begin
                            m_read_addr <= m_read_addr + 1;
                            m_state <= READ_SRAM; // Go back to read next word
                        end
                    end
                end
            endcase
        end
    end

    // M_AXIS outputs
    assign m_axis_tvalid = (m_state == STREAM_OUT);
    assign m_axis_tdata  = (m_active_bank == 2'd0) ? ping_rdata_i : pong_rdata_i;
    assign m_axis_tlast  = (m_state == STREAM_OUT) && (m_axis_cnt == 1);

    // MUX cho Ping/Pong Address (S_AXIS ghi hoặc M_AXIS đọc)
    assign ping_addr_o = (m_state != IDLE && m_active_bank == 2'd0) ? m_read_addr : ping_write_addr_reg;
    assign pong_addr_o = (m_state != IDLE && m_active_bank == 2'd1) ? m_read_addr : pong_write_addr_reg;

endmodule