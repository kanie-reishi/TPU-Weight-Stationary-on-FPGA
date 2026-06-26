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
    // 3. ENGINE STATUS (Port B mutual exclusion)
    // =========================================================
    input  logic                    engine_busy_i,
    input  logic [1:0]              src_bank_i,
    input  logic [1:0]              dst_bank_i,
    output logic                    m_axis_busy_o,

    // =========================================================
    // 4. LUỒNG ĐI TỚI CONTROLLER (Instruction FIFO)
    // =========================================================
    output logic [63:0]             ctrl_inst_data_o,
    output logic                    ctrl_inst_empty_o,
    input  logic                    ctrl_inst_read_i,

    // =========================================================
    // 5. LUỒNG ĐI TỚI CÁC BANK MEMORY (SRAM Interfaces)
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

    localparam BANK_PING = 2'b01;
    localparam BANK_PONG = 2'b10;

    // ---------------------------------------------------------
    // KHỐI 1: S_AXIS TDEST ROUTING & INGESTION
    // ---------------------------------------------------------
    logic w_fifo_full;
    logic w_fifo_wr_en;
    logic [63:0] w_fifo_wr_data;

    assign w_fifo_wr_en   = s_axis_tvalid && s_axis_tready && (s_axis_tdest == 4'd0);
    assign w_fifo_wr_data = s_axis_tdata[63:0];

    instruction_fifo u_inst_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en      (w_fifo_wr_en && !w_fifo_full),
        .wr_data    (w_fifo_wr_data),
        .full       (w_fifo_full),
        .rd_en      (ctrl_inst_read_i),
        .rd_data    (ctrl_inst_data_o),
        .empty      (ctrl_inst_empty_o)
    );

    logic [SRAM_AWIDTH-1:0] wgt_write_addr_reg;
    logic [SRAM_AWIDTH-1:0] ping_write_addr_reg;
    logic [SRAM_AWIDTH-1:0] pong_write_addr_reg;

    logic w_ptr_rst_wgt;
    logic w_ptr_rst_ping;
    logic w_ptr_rst_pong;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wgt_write_addr_reg  <= '0;
            ping_write_addr_reg <= '0;
            pong_write_addr_reg <= '0;
        end else begin
            if (w_ptr_rst_wgt)  wgt_write_addr_reg  <= '0;
            if (w_ptr_rst_ping) ping_write_addr_reg <= '0;
            if (w_ptr_rst_pong) pong_write_addr_reg <= '0;

            if (s_axis_tvalid && s_axis_tready) begin
                if (s_axis_tdest == 4'd1) begin
                    if (s_axis_tlast) wgt_write_addr_reg <= '0;
                    else              wgt_write_addr_reg <= wgt_write_addr_reg + 1;
                end else if (s_axis_tdest == 4'd2) begin
                    if (s_axis_tlast) ping_write_addr_reg <= '0;
                    else              ping_write_addr_reg <= ping_write_addr_reg + 1;
                end else if (s_axis_tdest == 4'd3) begin
                    if (s_axis_tlast) pong_write_addr_reg <= '0;
                    else              pong_write_addr_reg <= pong_write_addr_reg + 1;
                end
            end
        end
    end

    // ---------------------------------------------------------
    // KHỐI 2: AXI-LITE CONTROL & M_AXIS CONFIG
    // ---------------------------------------------------------
    logic [1:0]  m_axis_src_bank;
    logic [31:0] m_axis_length;
    logic        m_axis_start;

    logic w_axi_write_fire;
    assign w_axi_write_fire = s_axi_awvalid && s_axi_wvalid && s_axi_awready && s_axi_wready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_src_bank <= '0;
            m_axis_length   <= '0;
            m_axis_start    <= 1'b0;
            w_ptr_rst_wgt   <= 1'b0;
            w_ptr_rst_ping  <= 1'b0;
            w_ptr_rst_pong  <= 1'b0;
        end else begin
            if (m_axis_start) m_axis_start <= 1'b0;
            w_ptr_rst_wgt   <= 1'b0;
            w_ptr_rst_ping  <= 1'b0;
            w_ptr_rst_pong  <= 1'b0;

            if (w_axi_write_fire) begin
                // Decode [11:0] only — do not use awaddr[7:0] (aliases PEA cfg 0x0120–0x0130)
                unique case (s_axi_awaddr[11:0])
                    12'h020: m_axis_src_bank <= s_axi_wdata[1:0];
                    12'h024: m_axis_length   <= s_axi_wdata;
                    12'h028: begin
                        if (!m_axis_busy_o)
                            m_axis_start <= s_axi_wdata[0];
                    end
                    12'h030: begin
                        w_ptr_rst_wgt  <= s_axi_wdata[0];
                        w_ptr_rst_ping <= s_axi_wdata[1];
                        w_ptr_rst_pong <= s_axi_wdata[2];
                    end
                    default: ;
                endcase
            end
        end
    end

    assign s_axi_awready = 1'b1;
    assign s_axi_wready  = 1'b1;

    // ---------------------------------------------------------
    // KHỐI 3: M_AXIS STATE MACHINE
    // ---------------------------------------------------------
    typedef enum logic [1:0] { IDLE, READ_SRAM, STREAM_OUT } m_axis_state_t;
    m_axis_state_t m_state;

    logic [31:0]            m_axis_cnt;
    logic [SRAM_AWIDTH-1:0] m_read_addr;
    logic [1:0]             m_active_bank;

    assign m_axis_busy_o = (m_state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_state       <= IDLE;
            m_axis_cnt    <= '0;
            m_read_addr   <= '0;
            m_active_bank <= '0;
        end else begin
            case (m_state)
                IDLE: begin
                    if (m_axis_start && m_axis_length > 0) begin
                        m_state       <= READ_SRAM;
                        m_active_bank <= m_axis_src_bank;
                        m_read_addr   <= '0;
                        m_axis_cnt    <= m_axis_length;
                    end
                end

                READ_SRAM: m_state <= STREAM_OUT;

                STREAM_OUT: begin
                    if (m_axis_tready) begin
                        m_axis_cnt <= m_axis_cnt - 1;
                        if (m_axis_cnt == 1) begin
                            m_state <= IDLE;
                        end else begin
                            m_read_addr <= m_read_addr + 1;
                            m_state     <= READ_SRAM;
                        end
                    end
                end

                default: m_state <= IDLE;
            endcase
        end
    end

    assign m_axis_tvalid = (m_state == STREAM_OUT);
    assign m_axis_tdata  = (m_active_bank == 2'd0) ? ping_rdata_i : pong_rdata_i;
    assign m_axis_tlast  = (m_state == STREAM_OUT) && (m_axis_cnt == 1);

    assign ping_addr_o = (m_state != IDLE && m_active_bank == 2'd0) ? m_read_addr : ping_write_addr_reg;
    assign pong_addr_o = (m_state != IDLE && m_active_bank == 2'd1) ? m_read_addr : pong_write_addr_reg;

    // ---------------------------------------------------------
    // KHỐI 4: S_AXIS BACKPRESSURE & WRITE GATING
    // ---------------------------------------------------------
    logic block_ping_m_axis;
    logic block_pong_m_axis;
    logic block_ping_engine;
    logic block_pong_engine;

    assign block_ping_m_axis = m_axis_busy_o && (m_active_bank == 2'd0);
    assign block_pong_m_axis = m_axis_busy_o && (m_active_bank == 2'd1);

    assign block_ping_engine = engine_busy_i
                            && (src_bank_i == BANK_PING || dst_bank_i == BANK_PING);
    assign block_pong_engine = engine_busy_i
                            && (src_bank_i == BANK_PONG || dst_bank_i == BANK_PONG);

    logic w_axis_fire;
    assign w_axis_fire = s_axis_tvalid && s_axis_tready;

    assign wgt_we_o  = w_axis_fire && (s_axis_tdest == 4'd1);
    assign wgt_addr_o  = wgt_write_addr_reg;
    assign wgt_wdata_o = s_axis_tdata;

    assign ping_we_o    = w_axis_fire && (s_axis_tdest == 4'd2) && !block_ping_m_axis;
    assign ping_wdata_o = s_axis_tdata;

    assign pong_we_o    = w_axis_fire && (s_axis_tdest == 4'd3) && !block_pong_m_axis;
    assign pong_wdata_o = s_axis_tdata;

    logic w_tready_inst;
    logic w_tready_wgt;
    logic w_tready_ping;
    logic w_tready_pong;
    logic w_tready_other;

    assign w_tready_inst  = ~w_fifo_full;
    assign w_tready_wgt   = 1'b1;
    assign w_tready_ping  = !block_ping_m_axis && !block_ping_engine;
    assign w_tready_pong  = !block_pong_m_axis && !block_pong_engine;
    assign w_tready_other = 1'b0;

    assign s_axis_tready =
        (s_axis_tdest == 4'd0) ? w_tready_inst :
        (s_axis_tdest == 4'd1) ? w_tready_wgt :
        (s_axis_tdest == 4'd2) ? w_tready_ping :
        (s_axis_tdest == 4'd3) ? w_tready_pong :
        w_tready_other;

endmodule
