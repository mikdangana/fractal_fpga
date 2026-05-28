# Synthesis script for timing analysis
# Target: Virtex UltraScale+ VU47P HBM -2 speed grade

read_vhdl -library work [list \
    {src/counter.vhd} \
    {src/fractal.vhd} \
]

synth_design \
    -top fractal \
    -part xcku3p-ffva676-2-e \
    -mode out_of_context \
    -flatten_hierarchy rebuilt \
    -directive RuntimeOptimized

create_clock -period 10.0 -name clk [get_ports clk]

report_timing_summary \
    -max_paths 5 \
    -file {timing_summary.rpt}

report_timing \
    -max_paths 1 \
    -nworst 1 \
    -path_type full \
    -file {timing_critical.rpt}

report_utilization \
    -file {utilization.rpt}

puts "Synthesis complete."
