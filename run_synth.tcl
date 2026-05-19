# Synthesis script for timing analysis
# Target: Virtex UltraScale+ VU47P HBM -2 speed grade

read_vhdl -library work [list \
    {C:/Users/mikda/src/fractal_fpga/counter.vhd} \
    {C:/Users/mikda/src/fractal_fpga/fractal.vhd} \
]

synth_design \
    -top fractal \
    -part xcvu47p-fsvh2892-2-e \
    -mode out_of_context \
    -flatten_hierarchy rebuilt \
    -directive RuntimeOptimized

create_clock -period 10.0 -name clk [get_ports clk]

report_timing_summary \
    -max_paths 5 \
    -file {C:/Users/mikda/src/fractal_fpga/timing_summary.rpt}

report_timing \
    -max_paths 1 \
    -nworst 1 \
    -path_type full \
    -file {C:/Users/mikda/src/fractal_fpga/timing_critical.rpt}

report_utilization \
    -file {C:/Users/mikda/src/fractal_fpga/utilization.rpt}

puts "Synthesis complete."
