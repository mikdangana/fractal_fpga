# FractalSort FPGA

FPGA implementation of **FractalSort: High Precision Compressed Radix Sort on FPGA**, a high-throughput sorting architecture for Xilinx Virtex UltraScale+ devices with HBM.

## Overview

FractalSort is a compressed radix-sorting scheme for high-precision keys that achieves bandwidth-efficient memory-to-memory sorting. Key innovations:

- **Fractal Swap (FS)**: Binary radix sort using significant-bit concatenation at each precision level, implemented as an LSD radix sort pipeline with `N_LEVELS` stages
- **Fractal Filter (FF)**: In-place selection and concatenation of active entries based on significant bits, producing a compressed histogram for parallel merge
- **Histogram Compression**: Bounded histogram size through a novel compression scheme analogous to the disaggregated binary radix tree, enabling O(1) hash lookups for both value-at-index and index-at-value queries
- **Partition-Free Merge**: Eliminates data pre-processing and bucketing, achieving 3x bandwidth efficiency over state-of-the-art (Bonsai) on 16KB-128GB data sets

### Performance

- **On-chip sorting throughput**: 20 Tb/s at 350 MHz
- **Memory-to-memory sorting**: 3.2 Tb/s for 32-bit keys using HBM
- **Bandwidth efficiency**: ~80% at 4Gb, stable as data size increases
- **Speedup**: 6x (CPU), 2.5x (FPGA), 3x (GPU) in bandwidth-adjusted throughput on 4GB-2TB data sets
- **Complexity**: O(min(p, λ·log(n)) · log_B(n)), B >> 2

### Resource Scaling

- Registers scale linearly with precision: n_r ≈ 4.96p + 244
- Logic elements scale linearly: n_LE ≈ 24.84p + 181
- Resource usage scales linearly with input size

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  fractal.vhd (top-level)                            │
│  ┌───────────────────────────────────────────────┐  │
│  │  counter.vhd (sort pipeline + bin controller) │  │
│  │                                               │  │
│  │  FS Pipeline: N_LEVELS stages                 │  │
│  │  ┌──────────┐   ┌──────────┐                  │  │
│  │  │fs_scatter │──▶│ register │──▶ next level    │  │
│  │  │(radix    │   │ stage    │                   │  │
│  │  │ sort)    │   │          │                   │  │
│  │  └──────────┘   └──────────┘                   │  │
│  │                                               │  │
│  │  FF Components: histogram update + merge      │  │
│  │  Bin Controller: scatter writes + HBM drain   │  │
│  └───────────────────────────────────────────────┘  │
│                                                     │
│  HBM Interface (Phase 1 drain / Phase 2 readback)   │
└─────────────────────────────────────────────────────┘
```

### Sort Pipeline

The sort pipeline implements an LSD (Least Significant Digit) radix sort processing one key bit per level from bit `KEY_OFFSET` (LSB of key) to bit `PRECISIONS-1` (MSB). Each level consists of two clocked stages:

1. **fs_scatter**: Stable partition by the current key bit — entries with bit=0 placed first, bit=1 placed after
2. **Register stage**: Passes scatter output to the next level's input

Pipeline latency: `2 * N_LEVELS - 1` clock cycles (83 at default parameters).

### Two-Phase Operation

- **Phase 1 (Scatter)**: Input data flows through the sort pipeline. Sorted entries are extracted, binned by top key bits, buffered in on-chip SRAM, and drained to HBM in stride-parallel fashion
- **Phase 2 (Sort-back)**: Entries are read back from HBM bin-by-bin, re-sorted through the same pipeline, and written to the sorted output region in HBM

## Files

| File | Description |
|------|-------------|
| `counter.vhd` | Package (`reg24gen_package`) with constants and functions, plus `counter` entity containing the sort pipeline, histogram, and bin controller |
| `fractal.vhd` | Top-level entity with generate loop instantiating counter stages |
| `tb_fractal.vhd` | Testbench with random stimulus, simulated HBM memory, and sort-correctness checking |
| `run_synth.tcl` | Vivado synthesis script for timing and utilization reports |

## Parameters

Key constants in `reg24gen_package`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `N` / `INPUT_SIZE` | 8 | Fanout / entries per pipeline stage |
| `LOGN` | 3 | log2(N), tree depth |
| `PRECISIONS` | 49 | Total bits per entry (2·LOGN + 43) |
| `KEY_OFFSET` | 7 | First key bit position (2·LOGN + 1) |
| `KEY_WIDTH` | 42 | Number of key bits (PRECISIONS - KEY_OFFSET) |
| `RAW_PRECISION` | 128 | Raw input width per entry |
| `N_BINS` | 8 | Number of scatter bins (target 1024-4096) |
| `BIN_ENTRY_WIDTH` | 39 | Bits per bin entry (KEY_WIDTH - BIN_ID_BITS) |

## Toolchain

- **Vivado 2025.1** (xvhdl, xelab, xsim)
- **Target**: Xilinx Virtex UltraScale+ VU47P (xcvu47p-fsvh2892-2-e) with HBM2

### Simulation

```bash
# Compile
xvhdl counter.vhd fractal.vhd tb_fractal.vhd

# Elaborate
xelab work.tb_fractal -debug off -s sim_fractal

# Simulate
xsim sim_fractal -runall
```

### Synthesis

```bash
vivado -mode batch -source run_synth.tcl
```

## Citation

M. Dang'ana and H.-A. Jacobsen, "FractalSort: High Precision Compressed Radix Sort on FPGA," University of Toronto.
