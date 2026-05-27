// ============================================================================
// cl_fractal.sv - AWS F2 CL wrapper for FractalSort VHDL pipeline
//
// Bridges the VHDL fractal sort module to the F2 shell:
//   - OCL AXI-Lite: control/status registers
//   - PCIS DMA: host loads input data into staging BRAM, reads results
//   - HBM: bin storage for Phase 1 scatter / Phase 2 merge
//   - DDR: tied off (EN_DDR=0)
//   - Histogram FIFO: local BRAM (simple loopback)
// ============================================================================

module cl_fractal
#(
  parameter EN_DDR = 0,
  parameter EN_HBM = 1,
  // VHDL pipeline parameters (must match reg24gen_package constants)
  parameter INPUT_SIZE      = 64,   // N*N
  parameter RAW_PRECISION   = 128,
  parameter HBM_PAYLOAD_BITS = 256,
  parameter W_ADDR          = 16,
  parameter N_INPUT_CYCLES  = 500
)
(
`include "cl_ports.vh"
);

`include "cl_id_defines.vh"
`include "cl_fractal_defines.vh"

  // Derived constants
  localparam INPUT_WIDTH  = INPUT_SIZE * RAW_PRECISION;  // 8192 bits
  localparam FIFO_WIDTH   = 4 * W_ADDR;                  // 64 bits
  // Input staging: host writes 512-bit words, pipeline reads INPUT_WIDTH per batch
  localparam PCIS_DATA_W  = 512;
  localparam WORDS_PER_BATCH = INPUT_WIDTH / PCIS_DATA_W; // 16
  // Staging BRAM: N_INPUT_CYCLES * WORDS_PER_BATCH entries of 512 bits
  localparam STAGE_DEPTH  = N_INPUT_CYCLES * WORDS_PER_BATCH; // 8000
  localparam STAGE_ADDR_W = $clog2(STAGE_DEPTH);              // 13

  //-------------------------------------------------------------------
  // Reset synchronization
  //-------------------------------------------------------------------
  logic sync_rst_n;

  xpm_cdc_async_rst CDC_ASYNC_RST_N
  (
    .src_arst  (rst_main_n),
    .dest_clk  (clk_main_a0),
    .dest_arst (sync_rst_n)
  );

  //-------------------------------------------------------------------
  // FLR response
  //-------------------------------------------------------------------
  logic sh_cl_flr_assert_q;

  always_ff @(posedge clk_main_a0)
    if (!rst_main_n) begin
      sh_cl_flr_assert_q <= 0;
      cl_sh_flr_done     <= 0;
    end else begin
      sh_cl_flr_assert_q <= sh_cl_flr_assert;
      cl_sh_flr_done     <= sh_cl_flr_assert_q && !cl_sh_flr_done;
    end

  //-------------------------------------------------------------------
  // Tie off unused outputs
  //-------------------------------------------------------------------
  assign cl_sh_dma_rd_full  = 1'b0;
  assign cl_sh_dma_wr_full  = 1'b0;
  assign cl_sh_status0      = 32'b0;
  assign cl_sh_status1      = 32'b0;
  assign cl_sh_status2      = 32'b0;
  assign cl_sh_pcim_awuser  = '0;
  assign cl_sh_pcim_aruser  = '0;

  always_comb begin
    cl_sh_id0 = `CL_SH_ID0;
    cl_sh_id1 = `CL_SH_ID1;
  end

  // PCIM - unused (no host DMA mastering needed)
  always_comb begin
    cl_sh_pcim_awid    = '0; cl_sh_pcim_awaddr  = '0; cl_sh_pcim_awlen   = '0;
    cl_sh_pcim_awsize  = '0; cl_sh_pcim_awburst = '0; cl_sh_pcim_awcache = '0;
    cl_sh_pcim_awlock  = '0; cl_sh_pcim_awprot  = '0; cl_sh_pcim_awqos   = '0;
    cl_sh_pcim_awvalid = '0; cl_sh_pcim_wid     = '0; cl_sh_pcim_wdata   = '0;
    cl_sh_pcim_wstrb   = '0; cl_sh_pcim_wlast   = '0; cl_sh_pcim_wuser   = '0;
    cl_sh_pcim_wvalid  = '0; cl_sh_pcim_bready  = '0; cl_sh_pcim_arid    = '0;
    cl_sh_pcim_araddr  = '0; cl_sh_pcim_arlen   = '0; cl_sh_pcim_arsize  = '0;
    cl_sh_pcim_arburst = '0; cl_sh_pcim_arcache = '0; cl_sh_pcim_arlock  = '0;
    cl_sh_pcim_arprot  = '0; cl_sh_pcim_arqos   = '0; cl_sh_pcim_arvalid = '0;
    cl_sh_pcim_rready  = '0;
  end

  // SDA - unused
  always_comb begin
    cl_sda_awready = 1'b1; cl_sda_wready = 1'b1;
    cl_sda_bresp = '0; cl_sda_bvalid = '0;
    cl_sda_arready = 1'b1;
    cl_sda_rdata = '0; cl_sda_rresp = '0; cl_sda_rvalid = '0;
  end

  // Interrupts - unused for now
  assign cl_sh_apppf_irq_req = '0;

  // Virtual JTAG
  assign tdo = 1'b0;

  // PCIe EP/RP - unused
  always_comb begin
    PCIE_EP_TXP = '0; PCIE_EP_TXN = '0;
    PCIE_RP_PERSTN = '0; PCIE_RP_TXP = '0; PCIE_RP_TXN = '0;
  end

  //===================================================================
  // DDR (tied off - not used)
  //===================================================================
  sh_ddr #(.DDR_PRESENT(EN_DDR)) SH_DDR (
    .clk(clk_main_a0), .rst_n(), .stat_clk(clk_main_a0), .stat_rst_n(),
    .CLK_DIMM_DP(CLK_DIMM_DP), .CLK_DIMM_DN(CLK_DIMM_DN),
    .M_ACT_N(M_ACT_N), .M_MA(M_MA), .M_BA(M_BA), .M_BG(M_BG),
    .M_CKE(M_CKE), .M_ODT(M_ODT), .M_CS_N(M_CS_N),
    .M_CLK_DN(M_CLK_DN), .M_CLK_DP(M_CLK_DP), .M_PAR(M_PAR),
    .M_DQ(M_DQ), .M_ECC(M_ECC), .M_DQS_DP(M_DQS_DP), .M_DQS_DN(M_DQS_DN),
    .cl_RST_DIMM_N(RST_DIMM_N),
    .cl_sh_ddr_axi_awid(), .cl_sh_ddr_axi_awaddr(), .cl_sh_ddr_axi_awlen(),
    .cl_sh_ddr_axi_awsize(), .cl_sh_ddr_axi_awvalid(), .cl_sh_ddr_axi_awburst(),
    .cl_sh_ddr_axi_awuser(), .cl_sh_ddr_axi_awready(),
    .cl_sh_ddr_axi_wdata(), .cl_sh_ddr_axi_wstrb(), .cl_sh_ddr_axi_wlast(),
    .cl_sh_ddr_axi_wvalid(), .cl_sh_ddr_axi_wready(),
    .cl_sh_ddr_axi_bid(), .cl_sh_ddr_axi_bresp(), .cl_sh_ddr_axi_bvalid(),
    .cl_sh_ddr_axi_bready(),
    .cl_sh_ddr_axi_arid(), .cl_sh_ddr_axi_araddr(), .cl_sh_ddr_axi_arlen(),
    .cl_sh_ddr_axi_arsize(), .cl_sh_ddr_axi_arvalid(), .cl_sh_ddr_axi_arburst(),
    .cl_sh_ddr_axi_aruser(), .cl_sh_ddr_axi_arready(),
    .cl_sh_ddr_axi_rid(), .cl_sh_ddr_axi_rdata(), .cl_sh_ddr_axi_rresp(),
    .cl_sh_ddr_axi_rlast(), .cl_sh_ddr_axi_rvalid(), .cl_sh_ddr_axi_rready(),
    .sh_ddr_stat_bus_addr(), .sh_ddr_stat_bus_wdata(),
    .sh_ddr_stat_bus_wr(), .sh_ddr_stat_bus_rd(),
    .sh_ddr_stat_bus_ack(), .sh_ddr_stat_bus_rdata(),
    .ddr_sh_stat_int(), .sh_cl_ddr_is_ready()
  );

  assign cl_sh_ddr_stat_ack   = 1'b1;
  assign cl_sh_ddr_stat_rdata = '0;
  assign cl_sh_ddr_stat_int   = '0;

  //===================================================================
  // HBM instantiation via cl_hbm_axi4 (reuses AWS example module)
  //===================================================================
  axi_bus_t hbm_axi4_bus();
  cfg_bus_t hbm_stat_cfg_bus();
  logic     hbm_ready;

  // Tie off the stats bus (no runtime HBM stats access needed)
  assign hbm_stat_cfg_bus.addr  = '0;
  assign hbm_stat_cfg_bus.wdata = '0;
  assign hbm_stat_cfg_bus.wr    = 1'b0;
  assign hbm_stat_cfg_bus.rd    = 1'b0;
  assign hbm_stat_cfg_bus.user  = '0;

  cl_hbm_axi4 #(.HBM_PRESENT(EN_HBM)) CL_HBM (
    .clk_hbm_ref          (clk_hbm_ref),
    .clk                   (clk_main_a0),
    .rst_n                 (sync_rst_n),
    .hbm_axi4_bus          (hbm_axi4_bus),
    .hbm_stat_bus          (hbm_stat_cfg_bus),
    .i_hbm_apb_preset_n_1  (hbm_apb_preset_n_1),
    .o_hbm_apb_paddr_1     (hbm_apb_paddr_1),
    .o_hbm_apb_pprot_1     (hbm_apb_pprot_1),
    .o_hbm_apb_psel_1      (hbm_apb_psel_1),
    .o_hbm_apb_penable_1   (hbm_apb_penable_1),
    .o_hbm_apb_pwrite_1    (hbm_apb_pwrite_1),
    .o_hbm_apb_pwdata_1    (hbm_apb_pwdata_1),
    .o_hbm_apb_pstrb_1     (hbm_apb_pstrb_1),
    .o_hbm_apb_pready_1    (hbm_apb_pready_1),
    .o_hbm_apb_prdata_1    (hbm_apb_prdata_1),
    .o_hbm_apb_pslverr_1   (hbm_apb_pslverr_1),
    .i_hbm_apb_preset_n_0  (hbm_apb_preset_n_0),
    .o_hbm_apb_paddr_0     (hbm_apb_paddr_0),
    .o_hbm_apb_pprot_0     (hbm_apb_pprot_0),
    .o_hbm_apb_psel_0      (hbm_apb_psel_0),
    .o_hbm_apb_penable_0   (hbm_apb_penable_0),
    .o_hbm_apb_pwrite_0    (hbm_apb_pwrite_0),
    .o_hbm_apb_pwdata_0    (hbm_apb_pwdata_0),
    .o_hbm_apb_pstrb_0     (hbm_apb_pstrb_0),
    .o_hbm_apb_pready_0    (hbm_apb_pready_0),
    .o_hbm_apb_prdata_0    (hbm_apb_prdata_0),
    .o_hbm_apb_pslverr_0   (hbm_apb_pslverr_0),
    .o_cl_sh_hbm_stat_int  (),
    .o_hbm_ready            (hbm_ready)
  );

  assign cl_sh_status_vled = {14'b0, hbm_ready, 1'b0};

  //===================================================================
  // Fractal pipeline signals
  //===================================================================
  logic                           pipe_reset;
  logic                           pipe_start;
  logic [INPUT_WIDTH-1:0]         pipe_raw_numbers_in;
  integer                         pipe_count;
  logic                           pipe_fifo_wr_en;
  logic                           pipe_fifo_re_en;
  logic [FIFO_WIDTH-1:0]          pipe_fifo_dout;
  logic [FIFO_WIDTH-1:0]          pipe_fifo_din;
  logic                           pipe_fifo_ready;
  logic                           pipe_hbm_wr_en;
  logic [HBM_PAYLOAD_BITS-1:0]    pipe_hbm_dout;
  logic                           pipe_hbm_ready;
  logic [31:0]                    pipe_hbm_wr_addr;
  logic                           pipe_hbm_rd_req;
  logic [31:0]                    pipe_hbm_rd_addr;
  logic [HBM_PAYLOAD_BITS-1:0]    pipe_hbm_rd_data;
  logic                           pipe_hbm_rd_valid;
  // DRAM/SSD - tied off (not used on F2 currently; tier auto-selects HBM)
  logic                           pipe_dram_wr_en, pipe_ssd_wr_en;
  logic [HBM_PAYLOAD_BITS-1:0]    pipe_dram_dout, pipe_ssd_dout;
  logic [31:0]                    pipe_dram_wr_addr, pipe_ssd_wr_addr;
  logic                           pipe_dram_rd_req, pipe_ssd_rd_req;
  logic [31:0]                    pipe_dram_rd_addr, pipe_ssd_rd_addr;
  logic                           pipe_phase1_complete;
  logic                           pipe_sort_complete;

  //===================================================================
  // Histogram FIFO loopback (same as testbench: immediate echo)
  //===================================================================
  always_ff @(posedge clk_main_a0) begin
    if (pipe_fifo_wr_en || pipe_fifo_re_en) begin
      pipe_fifo_ready <= 1'b1;
      pipe_fifo_din   <= pipe_fifo_dout;
    end else begin
      pipe_fifo_ready <= 1'b0;
      pipe_fifo_din   <= '0;
    end
  end

  //===================================================================
  // VHDL fractal module instantiation
  //===================================================================
  fractal FRACTAL_SORT_I (
    .clk             (clk_main_a0),
    .reset           (pipe_reset),
    .raw_numbers_in  (pipe_raw_numbers_in),
    .count           (pipe_count),
    .fifo_wr_en      (pipe_fifo_wr_en),
    .fifo_re_en      (pipe_fifo_re_en),
    .fifo_dout       (pipe_fifo_dout),
    .fifo_din        (pipe_fifo_din),
    .fifo_ready      (pipe_fifo_ready),
    .hbm_wr_en       (pipe_hbm_wr_en),
    .hbm_dout        (pipe_hbm_dout),
    .hbm_ready       (pipe_hbm_ready),
    .dram_wr_en      (pipe_dram_wr_en),
    .dram_dout       (pipe_dram_dout),
    .dram_ready      (1'b0),
    .ssd_wr_en       (pipe_ssd_wr_en),
    .ssd_dout        (pipe_ssd_dout),
    .ssd_ready       (1'b0),
    .phase1_complete (pipe_phase1_complete),
    .sort_complete   (pipe_sort_complete),
    .hbm_wr_addr     (pipe_hbm_wr_addr),
    .hbm_rd_req      (pipe_hbm_rd_req),
    .hbm_rd_addr     (pipe_hbm_rd_addr),
    .hbm_rd_data     (pipe_hbm_rd_data),
    .hbm_rd_valid    (pipe_hbm_rd_valid),
    .dram_wr_addr    (pipe_dram_wr_addr),
    .dram_rd_req     (pipe_dram_rd_req),
    .dram_rd_addr    (pipe_dram_rd_addr),
    .dram_rd_data    ('0),
    .dram_rd_valid   (1'b0),
    .ssd_wr_addr     (pipe_ssd_wr_addr),
    .ssd_rd_req      (pipe_ssd_rd_req),
    .ssd_rd_addr     (pipe_ssd_rd_addr),
    .ssd_rd_data     ('0),
    .ssd_rd_valid    (1'b0)
  );

  //===================================================================
  // Input Staging BRAM
  //   Host writes via PCIS DMA (512-bit words).
  //   Loader FSM reads WORDS_PER_BATCH consecutive words per batch
  //   and assembles the full INPUT_WIDTH vector for the pipeline.
  //===================================================================
  (* ram_style = "block" *)
  logic [PCIS_DATA_W-1:0] stage_bram [0:STAGE_DEPTH-1];

  // PCIS write port
  logic [STAGE_ADDR_W-1:0] stage_wr_addr;
  logic                     stage_wr_en;
  logic [PCIS_DATA_W-1:0]  stage_wr_data;

  // Loader and PCIS share read port (mutually exclusive: PCIS before start, loader after)
  logic [STAGE_ADDR_W-1:0] loader_rd_addr;
  logic [STAGE_ADDR_W-1:0] pcis_rd_addr;
  logic [STAGE_ADDR_W-1:0] stage_rd_addr;
  logic [PCIS_DATA_W-1:0]  stage_rd_data;

  // Mux: loader gets priority when running
  assign stage_rd_addr = (load_state inside {LOAD_RUNNING, LOAD_LATENCY, LOAD_ASSEMBLE})
                         ? loader_rd_addr : pcis_rd_addr;

  always_ff @(posedge clk_main_a0) begin
    if (stage_wr_en)
      stage_bram[stage_wr_addr] <= stage_wr_data;
    stage_rd_data <= stage_bram[stage_rd_addr];
  end

  //===================================================================
  // Input Loader FSM
  //   Reads WORDS_PER_BATCH (16) words from staging BRAM per batch,
  //   assembles them into INPUT_WIDTH, then asserts pipe_raw_numbers_in.
  //===================================================================
  typedef enum logic [2:0] {
    LOAD_IDLE,
    LOAD_RUNNING,
    LOAD_LATENCY,   // 1-cycle BRAM read latency
    LOAD_ASSEMBLE,
    LOAD_FEED,
    LOAD_DONE
  } load_state_t;

  load_state_t           load_state;
  logic [31:0]           load_batch_cnt;   // current batch number
  logic [4:0]            load_word_cnt;    // word within batch (0..15)
  logic [INPUT_WIDTH-1:0] load_assemble_reg;
  logic [STAGE_ADDR_W-1:0] load_base_addr;

  always_ff @(posedge clk_main_a0) begin
    if (!sync_rst_n || pipe_reset) begin
      load_state        <= LOAD_IDLE;
      load_batch_cnt    <= '0;
      load_word_cnt     <= '0;
      load_base_addr    <= '0;
      load_assemble_reg <= '0;
      loader_rd_addr    <= '0;
      pipe_raw_numbers_in <= '0;
    end else begin
      case (load_state)
        LOAD_IDLE: begin
          if (pipe_start) begin
            load_state     <= LOAD_RUNNING;
            load_batch_cnt <= '0;
            load_base_addr <= '0;
          end
        end

        LOAD_RUNNING: begin
          // Issue BRAM read for word 0
          load_word_cnt  <= '0;
          loader_rd_addr <= load_base_addr;
          load_state     <= LOAD_LATENCY;
        end

        LOAD_LATENCY: begin
          // BRAM output for word 0 registers on this edge.
          // Pre-issue read for word 1 so data pipeline stays ahead.
          loader_rd_addr <= load_base_addr + 1;
          load_state     <= LOAD_ASSEMBLE;
        end

        LOAD_ASSEMBLE: begin
          // stage_rd_data now holds word[load_word_cnt] (arrived previous edge)
          load_assemble_reg[load_word_cnt*PCIS_DATA_W +: PCIS_DATA_W] <= stage_rd_data;

          if (load_word_cnt == WORDS_PER_BATCH - 1) begin
            load_state <= LOAD_FEED;
          end else begin
            load_word_cnt  <= load_word_cnt + 1;
            loader_rd_addr <= load_base_addr + load_word_cnt + 2;  // +2: word_cnt+1 addr
          end
        end

        LOAD_FEED: begin
          // Present assembled data to pipeline for one cycle
          pipe_raw_numbers_in <= load_assemble_reg;
          load_base_addr      <= load_base_addr + WORDS_PER_BATCH;
          load_batch_cnt      <= load_batch_cnt + 1;

          if (load_batch_cnt == N_INPUT_CYCLES - 1)
            load_state <= LOAD_DONE;
          else
            load_state <= LOAD_RUNNING;
        end

        LOAD_DONE: begin
          pipe_raw_numbers_in <= '0;
          // Stay here until reset
        end

        default: load_state <= LOAD_IDLE;
      endcase
    end
  end

  //===================================================================
  // HBM AXI4 Bridge
  //   Converts fractal's simple wr_en/rd_req to AXI4 single-beat
  //   transactions on hbm_axi4_bus.
  //===================================================================
  typedef enum logic [2:0] {
    HBM_IDLE,
    HBM_WRITE_ADDR,
    HBM_WRITE_DATA,
    HBM_WRITE_RESP,
    HBM_READ_ADDR,
    HBM_READ_DATA
  } hbm_state_t;

  hbm_state_t hbm_state;
  logic [31:0] hbm_wr_count, hbm_rd_count;

  // Registered request capture
  logic [31:0]                 hbm_req_addr;
  logic [HBM_PAYLOAD_BITS-1:0] hbm_req_data;

  // Pipeline sees ready when bridge is idle
  assign pipe_hbm_ready = hbm_ready && (hbm_state == HBM_IDLE);

  always_ff @(posedge clk_main_a0) begin
    if (!sync_rst_n || pipe_reset) begin
      hbm_state        <= HBM_IDLE;
      hbm_wr_count     <= '0;
      hbm_rd_count     <= '0;
      pipe_hbm_rd_data  <= '0;
      pipe_hbm_rd_valid <= 1'b0;

      hbm_axi4_bus.awvalid <= 1'b0;
      hbm_axi4_bus.wvalid  <= 1'b0;
      hbm_axi4_bus.bready  <= 1'b0;
      hbm_axi4_bus.arvalid <= 1'b0;
      hbm_axi4_bus.rready  <= 1'b0;
    end else begin
      // Default: deassert handshake signals
      pipe_hbm_rd_valid    <= 1'b0;

      case (hbm_state)
        HBM_IDLE: begin
          hbm_axi4_bus.awvalid <= 1'b0;
          hbm_axi4_bus.wvalid  <= 1'b0;
          hbm_axi4_bus.arvalid <= 1'b0;

          if (pipe_hbm_wr_en) begin
            // Capture write request
            hbm_req_addr <= pipe_hbm_wr_addr;
            hbm_req_data <= pipe_hbm_dout;
            hbm_state    <= HBM_WRITE_ADDR;

            // Drive AW channel
            hbm_axi4_bus.awaddr  <= {32'b0, pipe_hbm_wr_addr};
            hbm_axi4_bus.awlen   <= 8'd0;     // single beat
            hbm_axi4_bus.awsize  <= 3'd5;     // 32 bytes
            hbm_axi4_bus.awburst <= 2'd1;     // INCR
            hbm_axi4_bus.awid    <= '0;
            hbm_axi4_bus.awvalid <= 1'b1;

          end else if (pipe_hbm_rd_req) begin
            hbm_req_addr <= pipe_hbm_rd_addr;
            hbm_state    <= HBM_READ_ADDR;

            hbm_axi4_bus.araddr  <= {32'b0, pipe_hbm_rd_addr};
            hbm_axi4_bus.arlen   <= 8'd0;
            hbm_axi4_bus.arsize  <= 3'd5;
            hbm_axi4_bus.arburst <= 2'd1;
            hbm_axi4_bus.arid    <= '0;
            hbm_axi4_bus.arvalid <= 1'b1;
          end
        end

        //--- Write path ---
        HBM_WRITE_ADDR: begin
          if (hbm_axi4_bus.awready) begin
            hbm_axi4_bus.awvalid <= 1'b0;
            // Drive W channel
            hbm_axi4_bus.wdata  <= {256'b0, hbm_req_data};  // lower 256 bits
            hbm_axi4_bus.wstrb  <= {32'b0, 32'hFFFF_FFFF};  // lower 256 bits valid
            hbm_axi4_bus.wlast  <= 1'b1;
            hbm_axi4_bus.wvalid <= 1'b1;
            hbm_state           <= HBM_WRITE_DATA;
          end
        end

        HBM_WRITE_DATA: begin
          if (hbm_axi4_bus.wready) begin
            hbm_axi4_bus.wvalid <= 1'b0;
            hbm_axi4_bus.bready <= 1'b1;
            hbm_state           <= HBM_WRITE_RESP;
          end
        end

        HBM_WRITE_RESP: begin
          if (hbm_axi4_bus.bvalid) begin
            hbm_axi4_bus.bready <= 1'b0;
            hbm_wr_count        <= hbm_wr_count + 1;
            hbm_state           <= HBM_IDLE;
          end
        end

        //--- Read path ---
        HBM_READ_ADDR: begin
          if (hbm_axi4_bus.arready) begin
            hbm_axi4_bus.arvalid <= 1'b0;
            hbm_axi4_bus.rready  <= 1'b1;
            hbm_state            <= HBM_READ_DATA;
          end
        end

        HBM_READ_DATA: begin
          if (hbm_axi4_bus.rvalid) begin
            pipe_hbm_rd_data  <= hbm_axi4_bus.rdata[HBM_PAYLOAD_BITS-1:0];
            pipe_hbm_rd_valid <= 1'b1;
            hbm_axi4_bus.rready <= 1'b0;
            hbm_rd_count      <= hbm_rd_count + 1;
            hbm_state         <= HBM_IDLE;
          end
        end

        default: hbm_state <= HBM_IDLE;
      endcase
    end
  end

  //===================================================================
  // Phase 1 completion detector
  //   After all N_INPUT_CYCLES batches are fed, assert phase1_complete.
  //   Also allow host to force it via OCL register.
  //===================================================================
  logic phase1_force;

  always_ff @(posedge clk_main_a0) begin
    if (!sync_rst_n || pipe_reset)
      pipe_phase1_complete <= 1'b0;
    else if (load_state == LOAD_DONE || phase1_force)
      pipe_phase1_complete <= 1'b1;
  end

  //===================================================================
  // OCL AXI-Lite Slave (control/status registers)
  //===================================================================
  // Simple register interface: single-cycle read/write, no pipelining
  logic [31:0] ocl_wr_addr, ocl_rd_addr;
  logic [31:0] ocl_wr_data;
  logic        ocl_wr_valid, ocl_rd_valid;
  logic [31:0] ocl_rd_data_reg;

  // Control register bits
  logic ctrl_start_pulse;

  always_ff @(posedge clk_main_a0) begin
    if (!sync_rst_n) begin
      pipe_reset        <= 1'b1;
      pipe_start        <= 1'b0;
      phase1_force      <= 1'b0;
      ctrl_start_pulse  <= 1'b0;
    end else begin
      ctrl_start_pulse <= 1'b0;  // auto-clear

      if (ocl_wr_valid) begin
        case (ocl_wr_addr[7:0])
          8'h00: begin  // CTRL
            if (ocl_wr_data[0]) ctrl_start_pulse <= 1'b1;
            pipe_reset   <= ocl_wr_data[1];
            phase1_force <= ocl_wr_data[2];
          end
          default: ;
        endcase
      end

      // Start pulse triggers loader FSM
      if (ctrl_start_pulse && !pipe_start)
        pipe_start <= 1'b1;
    end
  end

  // OCL read data mux
  always_comb begin
    case (ocl_rd_addr[7:0])
      8'h00: ocl_rd_data_reg = {29'b0, phase1_force, pipe_reset, pipe_start};
      8'h04: ocl_rd_data_reg = {29'b0, hbm_ready, pipe_sort_complete,
                                 (load_state != LOAD_IDLE && load_state != LOAD_DONE)};
      8'h08: ocl_rd_data_reg = N_INPUT_CYCLES;
      8'h0C: ocl_rd_data_reg = load_batch_cnt;
      8'h10: ocl_rd_data_reg = hbm_wr_count;
      8'h14: ocl_rd_data_reg = hbm_rd_count;
      default: ocl_rd_data_reg = 32'hDEAD_BEEF;
    endcase
  end

  // AXI-Lite write channel
  typedef enum logic [1:0] { OCL_WR_IDLE, OCL_WR_DATA, OCL_WR_RESP } ocl_wr_state_t;
  ocl_wr_state_t ocl_wr_state;

  always_ff @(posedge clk_main_a0) begin
    if (!sync_rst_n) begin
      ocl_wr_state   <= OCL_WR_IDLE;
      cl_ocl_awready <= 1'b0;
      cl_ocl_wready  <= 1'b0;
      cl_ocl_bvalid  <= 1'b0;
      cl_ocl_bresp   <= 2'b0;
      ocl_wr_valid   <= 1'b0;
    end else begin
      ocl_wr_valid <= 1'b0;

      case (ocl_wr_state)
        OCL_WR_IDLE: begin
          cl_ocl_awready <= 1'b1;
          cl_ocl_wready  <= 1'b1;
          if (ocl_cl_awvalid && ocl_cl_wvalid) begin
            ocl_wr_addr    <= ocl_cl_awaddr;
            ocl_wr_data    <= ocl_cl_wdata;
            ocl_wr_valid   <= 1'b1;
            cl_ocl_awready <= 1'b0;
            cl_ocl_wready  <= 1'b0;
            cl_ocl_bvalid  <= 1'b1;
            cl_ocl_bresp   <= 2'b00;  // OKAY
            ocl_wr_state   <= OCL_WR_RESP;
          end
        end
        OCL_WR_RESP: begin
          if (ocl_cl_bready) begin
            cl_ocl_bvalid <= 1'b0;
            ocl_wr_state  <= OCL_WR_IDLE;
          end
        end
        default: ocl_wr_state <= OCL_WR_IDLE;
      endcase
    end
  end

  // AXI-Lite read channel
  typedef enum logic [1:0] { OCL_RD_IDLE, OCL_RD_RESP } ocl_rd_state_t;
  ocl_rd_state_t ocl_rd_state;

  always_ff @(posedge clk_main_a0) begin
    if (!sync_rst_n) begin
      ocl_rd_state   <= OCL_RD_IDLE;
      cl_ocl_arready <= 1'b0;
      cl_ocl_rvalid  <= 1'b0;
      cl_ocl_rdata   <= '0;
      cl_ocl_rresp   <= 2'b0;
    end else begin
      case (ocl_rd_state)
        OCL_RD_IDLE: begin
          cl_ocl_arready <= 1'b1;
          if (ocl_cl_arvalid) begin
            ocl_rd_addr    <= ocl_cl_araddr;
            cl_ocl_arready <= 1'b0;
            // Use incoming address directly for combinational lookup
            ocl_rd_state   <= OCL_RD_RESP;
          end
        end
        OCL_RD_RESP: begin
          // Present read data (ocl_rd_addr latched previous cycle)
          cl_ocl_rdata  <= ocl_rd_data_reg;
          cl_ocl_rvalid <= 1'b1;
          cl_ocl_rresp  <= 2'b00;
          if (ocl_cl_rready && cl_ocl_rvalid) begin
            cl_ocl_rvalid <= 1'b0;
            ocl_rd_state  <= OCL_RD_IDLE;
          end
        end
        default: ocl_rd_state <= OCL_RD_IDLE;
      endcase
    end
  end

  //===================================================================
  // PCIS DMA Slave - Input staging BRAM loader
  //   Host writes 512-bit data into staging BRAM via DMA.
  //   Address bits [STAGE_ADDR_W+5:6] select BRAM entry (64-byte aligned).
  //   Host can also read back from staging BRAM.
  //===================================================================
  typedef enum logic [2:0] {
    PCIS_IDLE,
    PCIS_WR_DATA,
    PCIS_WR_RESP,
    PCIS_RD_DATA
  } pcis_state_t;

  pcis_state_t pcis_state;
  logic [15:0] pcis_txn_id;
  logic [7:0]  pcis_rd_len;
  logic [7:0]  pcis_rd_cnt;

  always_ff @(posedge clk_main_a0) begin
    if (!sync_rst_n) begin
      pcis_state             <= PCIS_IDLE;
      cl_sh_dma_pcis_awready <= 1'b0;
      cl_sh_dma_pcis_wready  <= 1'b0;
      cl_sh_dma_pcis_bvalid  <= 1'b0;
      cl_sh_dma_pcis_bid     <= '0;
      cl_sh_dma_pcis_bresp   <= '0;
      cl_sh_dma_pcis_arready <= 1'b0;
      cl_sh_dma_pcis_rvalid  <= 1'b0;
      cl_sh_dma_pcis_rid     <= '0;
      cl_sh_dma_pcis_rdata   <= '0;
      cl_sh_dma_pcis_rlast   <= 1'b0;
      cl_sh_dma_pcis_rresp   <= '0;
      cl_sh_dma_pcis_ruser   <= '0;
      stage_wr_en            <= 1'b0;
    end else begin
      stage_wr_en <= 1'b0;

      case (pcis_state)
        PCIS_IDLE: begin
          cl_sh_dma_pcis_awready <= 1'b1;
          cl_sh_dma_pcis_arready <= 1'b1;

          if (sh_cl_dma_pcis_awvalid) begin
            // Write transaction
            pcis_txn_id  <= sh_cl_dma_pcis_awid;
            stage_wr_addr <= sh_cl_dma_pcis_awaddr[STAGE_ADDR_W+5:6];
            cl_sh_dma_pcis_awready <= 1'b0;
            cl_sh_dma_pcis_arready <= 1'b0;
            cl_sh_dma_pcis_wready  <= 1'b1;
            pcis_state <= PCIS_WR_DATA;

          end else if (sh_cl_dma_pcis_arvalid) begin
            // Read transaction
            pcis_txn_id  <= sh_cl_dma_pcis_arid;
            pcis_rd_addr <= sh_cl_dma_pcis_araddr[STAGE_ADDR_W+5:6];
            pcis_rd_len   <= sh_cl_dma_pcis_arlen;
            pcis_rd_cnt   <= '0;
            cl_sh_dma_pcis_awready <= 1'b0;
            cl_sh_dma_pcis_arready <= 1'b0;
            pcis_state <= PCIS_RD_DATA;
          end
        end

        PCIS_WR_DATA: begin
          if (sh_cl_dma_pcis_wvalid) begin
            stage_wr_en   <= 1'b1;
            stage_wr_data <= sh_cl_dma_pcis_wdata;

            if (sh_cl_dma_pcis_wlast) begin
              cl_sh_dma_pcis_wready <= 1'b0;
              cl_sh_dma_pcis_bvalid <= 1'b1;
              cl_sh_dma_pcis_bid    <= pcis_txn_id;
              cl_sh_dma_pcis_bresp  <= 2'b00;
              pcis_state <= PCIS_WR_RESP;
            end else begin
              stage_wr_addr <= stage_wr_addr + 1;
            end
          end
        end

        PCIS_WR_RESP: begin
          if (sh_cl_dma_pcis_bready) begin
            cl_sh_dma_pcis_bvalid <= 1'b0;
            pcis_state <= PCIS_IDLE;
          end
        end

        PCIS_RD_DATA: begin
          // One-cycle BRAM read latency already handled by registered output
          cl_sh_dma_pcis_rvalid <= 1'b1;
          cl_sh_dma_pcis_rid    <= pcis_txn_id;
          cl_sh_dma_pcis_rdata  <= stage_rd_data;
          cl_sh_dma_pcis_rlast  <= (pcis_rd_cnt == pcis_rd_len);
          cl_sh_dma_pcis_rresp  <= 2'b00;

          if (sh_cl_dma_pcis_rready && cl_sh_dma_pcis_rvalid) begin
            if (pcis_rd_cnt == pcis_rd_len) begin
              cl_sh_dma_pcis_rvalid <= 1'b0;
              pcis_state <= PCIS_IDLE;
            end else begin
              pcis_rd_cnt   <= pcis_rd_cnt + 1;
              pcis_rd_addr <= pcis_rd_addr + 1;
            end
          end
        end

        default: pcis_state <= PCIS_IDLE;
      endcase
    end
  end

endmodule // cl_fractal
