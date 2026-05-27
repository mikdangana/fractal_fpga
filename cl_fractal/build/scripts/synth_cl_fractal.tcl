# synth_cl_fractal.tcl - Synthesis script for FractalSort CL

# Common header
source ${HDK_SHELL_DIR}/build/scripts/synth_cl_header.tcl

###############################################################################
print "Reading FractalSort design sources"
###############################################################################

# Read SystemVerilog interface/package definitions
read_verilog -sv [list \
  ${CL_DIR}/design/cl_fractal_pkg.sv
]

# Read VHDL sources (fractal sort pipeline)
read_vhdl -vhdl2008 [list \
  ${CL_DIR}/../../counter.vhd \
  ${CL_DIR}/../../fractal.vhd
]

# Read CL top-level and defines
read_verilog -sv [list \
  ${CL_DIR}/design/cl_fractal.sv
]

read_verilog -sv [list ${CL_DIR}/design/cl_fractal_defines.vh]
set_property file_type {Verilog Header} [get_files ${CL_DIR}/design/cl_fractal_defines.vh]
set_property is_global_include true     [get_files ${CL_DIR}/design/cl_fractal_defines.vh]

# Read HBM wrapper modules from the example design
read_verilog -sv [list \
  ${HDK_SHELL_DIR}/../cl/examples/cl_dram_hbm_dma/design/cl_hbm_axi4.sv \
  ${HDK_SHELL_DIR}/../cl/examples/cl_dram_hbm_dma/design/cl_hbm_wrapper.sv
]

###############################################################################
print "Reading CL IP blocks"
###############################################################################

## HBM IP's
read_ip [ list \
  ${HDK_IP_SRC_DIR}/cl_hbm_mmcm/cl_hbm_mmcm.xci \
  ${HDK_IP_SRC_DIR}/cl_hbm/cl_hbm.xci
]

## AXI Register Slice IP's
read_ip [ list \
  ${HDK_IP_SRC_DIR}/axi_register_slice/axi_register_slice.xci \
  ${HDK_IP_SRC_DIR}/cl_axi3_256b_reg_slice/cl_axi3_256b_reg_slice.xci
]

## Read BD (AXI SmartConnect for AXI4→AXI3 conversion)
add_files [ list \
  ${HDK_BD_SRC_DIR}/cl_axi_sc_1x1/cl_axi_sc_1x1.bd
]

read_verilog [ list \
  ${HDK_BD_GEN_DIR}/cl_axi_sc_1x1/hdl/cl_axi_sc_1x1_wrapper.v
]

###############################################################################
print "Reading user constraints"
###############################################################################

# No custom constraints for now - using default shell constraints

###############################################################################
print "Starting synthesizing customer design ${CL}"
###############################################################################
update_compile_order -fileset sources_1

synth_design -mode out_of_context \
             -top ${CL} \
             -verilog_define XSDB_SLV_DIS \
             -part ${DEVICE_TYPE} \
             -keep_equivalent_registers

# Common footer
source ${HDK_SHELL_DIR}/build/scripts/synth_cl_footer.tcl
