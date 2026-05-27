`ifndef CL_FRACTAL_DEFINES
`define CL_FRACTAL_DEFINES

  `define CL_NAME cl_fractal

  `define FPGA_LESS_RST
  `define SH_SDA

  // Default AXI values (same as cl_dram_hbm_dma)
  `define DEF_AXSIZE    3'd5   // 32 bytes per beat (256-bit HBM)
  `define DEF_AXBURST   2'd1   // INCR burst
  `define DEF_AXCACHE   4'd3   // Bufferable, Modifiable
  `define DEF_AXLOCK    1'd0   // Normal access
  `define DEF_AXPROT    3'd2   // Unprivileged, Non-Secure
  `define DEF_AXQOS     4'd0   // Regular Identifier
  `define DEF_AXREGION  4'd0   // Single region

  // OCL register addresses
  `define OCL_CTRL          32'h00   // bit0: start, bit1: reset_pipe, bit2: force_phase1_complete
  `define OCL_STATUS        32'h04   // bit0: busy, bit1: sort_complete, bit2: hbm_ready
  `define OCL_N_BATCHES     32'h08   // number of input batches (read-only from VHDL constant)
  `define OCL_INPUT_BATCH   32'h0C   // current input batch counter
  `define OCL_HBM_WR_COUNT  32'h10   // HBM write counter
  `define OCL_HBM_RD_COUNT  32'h14   // HBM read counter

`endif
