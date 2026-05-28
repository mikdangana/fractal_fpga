# FractalSort FPGA

FPGA implementation of **FractalSort: High Precision Compressed Radix Sort on FPGA** (M. Dang'ana, H.-A. Jacobsen, University of Toronto).

## Algorithm

FractalSort decomposes radix sorting into three modules operating on a fractal tree structure with branching factor $B$, where $n_b$ = `INPUT_SIZE` is the batch size:

- **Fractal Swap (FS)**: A fractal tree with fanout $B$ (= $N$) and depth $\log_B(n_b)$. At level $l$, each FS node processes a sub-problem of size $n_b / B^l$. Each node contains distribution (partition by significant bit) and aggregation logic (merge sorted results from its $B$ children).

- **Fractal Filter (FF)**: A binary tree of FF nodes at depth $\min(p, \log_2(n_b))$. Each FF node uses a *Change Detector* to identify significant bits and concatenate only active entries, producing a compressed histogram update. This is optional in LSB sorting mode.

- **Controller**: Orchestrates two-phase operation. Phase 1 scatters compressed leaf entries into merge tree-associated leaf bins drained to tiered memory. Phase 2 loads each leaf bin back to sort the compressed entries, enabling collision-free parallel updates to the bin merge tree.


## Simulation

Requires Vivado 2025.1 (xvhdl, xelab, xsim).

### Quick sim (INPUT_SIZE=8, < 1 GB RAM)

Set `INPUT_SIZE := N` in src/counter.vhd line 36, then:

```bash
xvhdl --2008 src/counter.vhd src/fractal.vhd src/tb_fractal.vhd && \
xelab work.tb_fractal -debug off -s tb_fractal_sim && \
xsim tb_fractal_sim -runall --log sim_output.txt
```

### Full sim (INPUT_SIZE=64, ~16 GB RAM)

Set `INPUT_SIZE := N*N` in src/counter.vhd line 36, then run the same command above.

A successful run prints `Phase 2 COMPLETED` with no sort-order errors.

## AWS F2 End-to-End Sort

Target: Xilinx VU47P on AWS F2 (f2.12xlarge) with HBM2.

### Build AFI

```bash
cd ~/src/aws-fpga && source hdk_setup.sh && \
export CL_DIR=$PWD/../fractal_fpga/src/cl_fractal && \
cd $CL_DIR/build/scripts && \
$HDK_DIR/cl/examples/cl_dram_hbm_dma/build/scripts/aws_build_dcp_from_cl.py \
  --cl cl_fractal --clock_recipe_a A0 --clock_recipe_b B0 --clock_recipe_hbm H0 && \
aws s3 cp $CL_DIR/build/checkpoints/to_aws/*.tar s3://your-bucket/dcps/ && \
aws ec2 create-fpga-image \
  --name "FractalSort" \
  --input-storage-location Bucket=your-bucket,Key=dcps/your-dcp.tar \
  --logs-storage-location Bucket=your-bucket,Key=logs/
```

### Load and sort

```bash
# On the f2 instance:
sudo fpga-load-local-image -S 0 -I <agfi-id>

# 1. DMA dataset into FPGA staging BRAM via PCIS (512-bit, 64B-aligned)
# 2. Start sort:  OCL write 0x00 <- 0x01
# 3. Poll status: OCL read  0x04  (wait for bit 1 = sort_complete)
# 4. Read sorted results from HBM via PCIS/PCIM
```

The pipeline input is $n_b \times 128$ bits per load, delivered as 512-bit PCIS beats.

### OCL register map

| Address | Name | Description |
|---------|------|-------------|
| `0x00` | CTRL | bit 0: start, bit 1: reset, bit 2: force phase1_complete |
| `0x04` | STATUS | bit 0: busy, bit 1: sort_complete, bit 2: hbm_ready |
| `0x10` | HBM_WR_COUNT | HBM writes |
| `0x14` | HBM_RD_COUNT | HBM reads |

### Tiered storage

Auto-selected by dataset size: HBM (<=16 GB), DRAM (<=64 GB), SSD (>64 GB). Override with `FORCE_TIER` in src/counter.vhd.

## Files

| File | Description |
|------|-------------|
| `src/counter.vhd` | Sort pipeline, histogram, bin controller, tiered memory routing |
| `src/fractal.vhd` | Top-level wrapper |
| `src/tb_fractal.vhd` | Testbench with simulated memory and correctness checking |
| `src/run_synth.tcl` | Standalone Vivado synthesis script |
| `src/cl_fractal/design/cl_fractal.sv` | AWS F2 CL wrapper: OCL, PCIS DMA, HBM AXI4 bridge |
| `src/cl_fractal/design/cl_fractal_pkg.sv` | AXI bus interfaces |
| `src/cl_fractal/design/cl_fractal_defines.vh` | OCL register map, AXI defaults |
| `src/cl_fractal/build/scripts/synth_cl_fractal.tcl` | Vivado synthesis script for F2 build |

## Citation

M. Dang'ana and H.-A. Jacobsen, "[FractalSort: High Precision Compressed Radix Sort on FPGA](https://ieeexplore.ieee.org/document/11348110/)," University of Toronto.
