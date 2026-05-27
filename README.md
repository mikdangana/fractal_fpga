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
- **Complexity**: O(min(p, lambda-log(n)) * log_B(n)), B >> 2

### Resource Scaling

- Registers scale linearly with precision: n_r ~ 4.96p + 244
- Logic elements scale linearly: n_LE ~ 24.84p + 181
- Resource usage scales linearly with input size

## Architecture

```
+-----------------------------------------------------+
|  fractal.vhd (top-level wrapper)                     |
|  +-----------------------------------------------+  |
|  |  counter.vhd (sort pipeline + bin controller)  |  |
|  |                                                |  |
|  |  FS Pipeline: N_LEVELS=128 stages              |  |
|  |  +----------+   +----------+                   |  |
|  |  |fs_scatter |-->| register |-->  next level    |  |
|  |  |(radix    |   | stage    |                    |  |
|  |  | sort)    |   |          |                    |  |
|  |  +----------+   +----------+                    |  |
|  |                                                |  |
|  |  SRL Key Bit Delays (~49K LUTs)                |  |
|  |  BRAM Entry FIFO (114 BRAMs)                   |  |
|  |  Bin Controller: scatter writes + HBM drain    |  |
|  +-----------------------------------------------+  |
|                                                      |
|  Tiered Memory: HBM / DRAM / SSD (auto-select)      |
+-----------------------------------------------------+

+-----------------------------------------------------+
|  cl_fractal.sv (AWS F2 CL wrapper)                   |
|  +-----------------------------------------------+  |
|  |  OCL AXI-Lite: control/status registers        |  |
|  |  PCIS DMA: host data load into staging BRAM    |  |
|  |  Input Loader FSM: 16x512b -> 8192b pipeline   |  |
|  |  HBM AXI4 Bridge: wr_en/rd_req -> AXI4        |  |
|  |  cl_hbm_axi4: AXI4 -> AXI3 -> HBM IP          |  |
|  +-----------------------------------------------+  |
+-----------------------------------------------------+
```

### Sort Pipeline

The sort pipeline implements an LSD (Least Significant Digit) radix sort processing one key bit per level. Each level consists of:

1. **fs_scatter**: Stable partition by the current key bit (entries with bit=0 first, bit=1 after)
2. **Register stage**: Passes scatter output to the next level

At `INPUT_SIZE=64`: FS_DEPTH=2, STAGES_PER_LEVEL=3, pipeline latency = 3 * 128 - 1 = 383 cycles.

The data delay chain (which would need 3.1 Mbit of FFs at INPUT_SIZE=64) is replaced with:
- **SRL key bit delays** (~49K LUTs): Per-bit shift registers with variable depth
- **BRAM entry FIFO** (~114 BRAMs): Stores full entries for reconstruction at the last pipeline stage

### Two-Phase Operation

- **Phase 1 (Scatter)**: Input data flows through the sort pipeline. Sorted entries are binned by top key bits, buffered in on-chip SRAM, and drained to HBM
- **Phase 2 (Sort-back)**: Entries are read back from HBM bin-by-bin, re-sorted through the pipeline, and written to the sorted output region

### Tiered Storage

Storage tier is auto-selected based on dataset size:
- **HBM** (<=16 GB): default on AWS F2
- **DRAM** (<=64 GB): for larger datasets
- **SSD** (>64 GB): for very large datasets

Set `FORCE_TIER` in `counter.vhd` to override for testing.

## Files

| File | Description |
|------|-------------|
| `counter.vhd` | Package (`reg24gen_package`) with constants/functions, plus `counter` entity: sort pipeline, histogram, bin controller, tiered memory routing |
| `fractal.vhd` | Top-level wrapper: instantiates counter, memory arbiter, broadcast |
| `tb_fractal.vhd` | Testbench: random stimulus, simulated HBM/DRAM/SSD memory, sort-correctness checking |
| `cl_fractal/` | AWS F2 CL wrapper (SystemVerilog) |
| `cl_fractal/design/cl_fractal.sv` | CL top-level: OCL registers, PCIS DMA, input loader, HBM AXI4 bridge |
| `cl_fractal/design/cl_fractal_pkg.sv` | AXI bus interface definitions |
| `cl_fractal/design/cl_fractal_defines.vh` | OCL register map, AXI defaults |
| `cl_fractal/build/scripts/synth_cl_fractal.tcl` | Vivado synthesis script for F2 build |

## Parameters

Key constants in `reg24gen_package` (counter.vhd):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `N` | 8 | Fanout per tree level |
| `INPUT_SIZE` | 64 (N*N) | Entries per pipeline batch |
| `RAW_PRECISION` | 128 | Raw input width per entry (bits) |
| `PRECISIONS` | 49 | Internal bits per entry (2*LOGN + 43) |
| `N_INPUT_CYCLES` | 500 | Number of input batches |
| `N_LEVELS` | 128 | Pipeline stages (= RAW_PRECISION) |
| `PIPELINE_LATENCY` | 383 | Total pipeline delay (clock cycles) |
| `N_BINS` | 256 | Number of scatter bins |
| `HBM_PAYLOAD_BITS` | 256 | HBM data width per transaction |
| `FORCE_TIER` | -1 | Storage tier override (-1=auto, 0=HBM, 1=DRAM, 2=SSD) |

## Toolchain

- **Vivado 2025.1** (xvhdl, xelab, xsim for simulation; Vivado for synthesis)
- **Target**: Xilinx Virtex UltraScale+ VU47P (AWS F2 f2.12xlarge) with HBM2
- **AWS FPGA Developer Kit**: `aws-fpga` HDK for F2 shell integration

## Simulation

### Quick Simulation (INPUT_SIZE=N=8)

For fast iteration, set `INPUT_SIZE := N` in counter.vhd (line 36). This reduces elaboration memory from 16+ GB to under 1 GB.

```bash
# Compile all VHDL sources (VHDL-2008 required)
xvhdl --2008 counter.vhd fractal.vhd tb_fractal.vhd

# Elaborate
xelab work.tb_fractal -debug off -s tb_fractal_sim

# Run simulation (output goes to stdout)
xsim tb_fractal_sim -runall

# Or save output to file
xsim tb_fractal_sim -runall --log sim_output.txt
```

### Full Simulation (INPUT_SIZE=N*N=64)

Requires ~16 GB RAM for elaboration. Set `INPUT_SIZE := N*N` in counter.vhd.

```bash
xvhdl --2008 counter.vhd fractal.vhd tb_fractal.vhd
xelab work.tb_fractal -debug off -s tb_fractal_sim
xsim tb_fractal_sim -runall --log sim_output.txt
```

### Testing Specific Storage Tiers

To test DRAM or SSD tiers with the small simulation dataset, set `FORCE_TIER` in counter.vhd:

```vhdl
CONSTANT FORCE_TIER : INTEGER := 0;  -- 0=HBM, 1=DRAM, 2=SSD
```

Then recompile and run. Set back to `-1` for auto-select in production.

### What to Expect

The testbench:
1. **Phase 1**: Feeds `N_INPUT_CYCLES` random batches through the pipeline. Entries are scatter-binned and drained to simulated memory. Watch for `[P1] cycle=...` progress.
2. **Phase 1 complete**: Reports total HBM/DRAM/SSD writes.
3. **Phase 2**: Reads entries back from memory bin-by-bin, re-sorts them. Reports `Phase 2 COMPLETED`.
4. **Correctness check**: Verifies sorted output is in order.

A successful run ends with `Phase 2 COMPLETED` and no sort-order errors.

### Troubleshooting

- **Elaboration killed / out of memory**: Use `INPUT_SIZE := N` for quick sim
- **xelab lock file error**: `rm -rf xsim.dir/tb_fractal_sim` and re-elaborate
- **All zeros in sort output**: Ensure `FORCE_TIER` matches available memory model in testbench. All three tier models (hbm_mem, dram_mem, ssd_mem) are active.

## AWS F2 FPGA Deployment

### Prerequisites

- AWS account with F2 FPGA access
- `aws-fpga` HDK cloned at `~/src/aws-fpga`
- Vivado 2025.1 installed
- An f2.12xlarge instance (or local build machine + f2 for loading)

### Build Flow

The CL wrapper can be built locally and transferred to an F2 instance for loading.

#### 1. Set Up Environment

```bash
# Source the HDK setup
cd ~/src/aws-fpga
source hdk_setup.sh

# Set CL directory to the fractal wrapper
export CL_DIR=$PWD/../fractal_fpga/cl_fractal
```

#### 2. Build the DCP

```bash
cd $CL_DIR/build/scripts

# Build with default clocks (clk_main_a0=250 MHz)
$HDK_DIR/cl/examples/cl_dram_hbm_dma/build/scripts/aws_build_dcp_from_cl.py \
  --cl cl_fractal \
  --clock_recipe_a A0 \
  --clock_recipe_b B0 \
  --clock_recipe_hbm H0
```

The build produces a Design Checkpoint (DCP) tarball in `$CL_DIR/build/checkpoints/`.

#### 3. Create the AFI

```bash
# Upload DCP to S3
aws s3 cp $CL_DIR/build/checkpoints/to_aws/*.tar s3://your-bucket/dcps/

# Create AFI
aws ec2 create-fpga-image \
  --name "FractalSort" \
  --input-storage-location Bucket=your-bucket,Key=dcps/your-dcp.tar \
  --logs-storage-location Bucket=your-bucket,Key=logs/
```

Wait for AFI to become available (`aws ec2 describe-fpga-images --fpga-image-ids <afi-id>`).

#### 4. Load and Run on F2

```bash
# On the f2.12xlarge instance:

# Load the AFI
sudo fpga-load-local-image -S 0 -I <agfi-id>

# Verify
sudo fpga-describe-local-image -S 0 -H

# The FPGA is now programmed. Use the host driver to interact.
```

### Host Interaction (OCL Registers)

Use `fpga-access-example` or a custom C program with the FPGA libraries to access OCL registers:

| Address | Name | R/W | Description |
|---------|------|-----|-------------|
| `0x00` | CTRL | W | bit 0: start, bit 1: pipeline reset, bit 2: force phase1_complete |
| `0x04` | STATUS | R | bit 0: busy, bit 1: sort_complete, bit 2: hbm_ready |
| `0x08` | N_BATCHES | R | Number of input batches (500) |
| `0x0C` | INPUT_BATCH | R | Current batch counter |
| `0x10` | HBM_WR_COUNT | R | Total HBM writes |
| `0x14` | HBM_RD_COUNT | R | Total HBM reads |

### End-to-End Sort Sequence

```
Host                              FPGA (cl_fractal)
 |                                  |
 |  1. Write dataset via PCIS DMA   |
 |  (512-bit words, 64-byte aligned)|
 |--------------------------------->|  -> staging BRAM
 |                                  |
 |  2. OCL write 0x00 <- 0x01       |
 |  (start)                         |
 |--------------------------------->|  -> loader FSM begins
 |                                  |     feeding pipeline
 |  3. Poll OCL 0x04                |
 |  (wait for sort_complete)        |
 |<- - - - - - - - - - - - - - - - -|
 |                                  |  Phase 1: scatter to HBM
 |                                  |  Phase 2: read bins, re-sort
 |                                  |  sort_complete = 1
 |  4. Read sorted results          |
 |  from HBM via PCIS/PCIM          |
 |<---------------------------------|
```

**Data format**: Each batch is `INPUT_SIZE * RAW_PRECISION = 64 * 128 = 8192` bits = 1024 bytes = 16 PCIS beats (512-bit each). Total dataset: `N_INPUT_CYCLES * 1024 = 512,000` bytes.

### Synthesis (Standalone)

For resource/timing estimates without the full F2 build:

```bash
vivado -mode batch -source run_synth.tcl
```

## Citation

M. Dang'ana and H.-A. Jacobsen, "FractalSort: High Precision Compressed Radix Sort on FPGA," University of Toronto.
