#!/usr/bin/env python3
"""
GPU implementation of fractal_sort() using Numba CUDA.

Quick start (requires: Python 3.9+, numpy, numba with CUDA; NVIDIA GPU + driver):
  pip install numpy numba
  python fractal_sort_cuda.py --n 10000000 --cuda --nbins 4096 --nl 5

Notes
-----
• This uses a two-phase histogram: per-block accumulation in shared memory
  (fast shared-memory atomics) then a single global atomic add per bin per block.
• It mirrors the outer loop over keys and the inner loop over small \"chunks\"
  (size nL bits) per key. Replace `compute_k_and_v()` if your exact k/v mapping differs.
• If CUDA is unavailable or `--cuda` not passed, it falls back to a CPU implementation
  (NumPy loop; simple and correct, not the fastest CPU path).
"""

import argparse
import math
import sys
import numpy as np

try:
    from numba import cuda, int32, uint32
    HAS_CUDA = cuda.is_available()
except Exception:
    HAS_CUDA = False
    cuda = None  # type: ignore

# ---------------------- Tunables / defaults -------------------------
DEFAULT_NL = 5           # bits per sub-chunk
DEFAULT_NBINS = 4096     # per-block shared histogram size (must fit in shared mem)
THREADS_PER_BLOCK = 256

# ---------------------- Helper: popcount ----------------------------
try:
    # numba.cuda has popc on newer versions, but we keep a simple version
    import numba
    @numba.njit(inline="always")
    def popcount32(x: np.uint32) -> np.int32:
        c = 0
        xx = np.uint32(x)
        while xx:
            xx &= xx - np.uint32(1)
            c += 1
        return c
except Exception:
    def popcount32(x: int) -> int:
        return int(bin(x & 0xFFFFFFFF).count("1"))

# ---------------------- Bin / value logic ---------------------------
# This mirrors the idea of: for each key, iterate j over chunks of nL bits
# and derive a bin (k) and a small value (v) to add.
# Replace this with your exact mapping from your CPU version if needed.

def compute_k_and_v_for_chunk(key_u32: np.uint32, j: int, nL: int) -> tuple[int, int]:
    """Compute (k, v) for the j-th nL-bit chunk of key.
    k = the nL-bit value at bits [j*nL : (j+1)*nL)
    v = a small function of k (here: popcount of k or subset thereof)
    """
    shift = j * nL
    mask = (1 << nL) - 1
    k = int((key_u32 >> shift) & mask)
    # Example v: popcount of k; replace if your CPU logic differs
    v = int(popcount32(np.uint32(k)))
    return k, v

# ---------------------- CUDA kernel ---------------------------------
# Shared-memory histogram, grid-stride over keys, inner loop over chunks.

if HAS_CUDA:
    @cuda.jit
    def hist_kernel(keys, n, nL, nChunks, g_hist, NBINS):
        # shared histogram
        sh = cuda.shared.array(shape=0, dtype=int32)  # dynamic shared mem
        # We index into sh via raw pointer math; but Numba requires a sized array.
        # Work-around: we use dynamic shared memory via cuda.shared.array(0,..)
        # and treat it as a 1D int32 buffer of length NBINS provided at launch.

        t = cuda.threadIdx.x
        bdim = cuda.blockDim.x

        # Zero shared memory bins cooperatively
        i = t
        while i < NBINS:
            # Access via cuda.shared.array is not directly indexable when size=0.
            # Numba maps it as a raw array; use cuda.shared.array and a pointer view.
            # However, Numba allows indexing sh[i] when declared with shape=0
            # as long as we only use it within bounds. We'll rely on that here.
            sh[i] = 0
            i += bdim
        cuda.syncthreads()

        # Grid-stride over keys
        tid = cuda.grid(1)
        gsize = cuda.gridsize(1)
        while tid < n:
            key = keys[tid]
            # For each small chunk
            for j in range(nChunks):
                k, v = compute_k_and_v_for_chunk(key, j, nL)
                bin_id = k & (NBINS - 1)  # hash/tiling into NBINS
                cuda.atomic.add(sh, bin_id, v)
            tid += gsize

        cuda.syncthreads()
        # Merge shared → global: one global atomic per bin
        i = t
        while i < NBINS:
            val = sh[i]
            if val:
                cuda.atomic.add(g_hist, i, val)
            i += bdim

# ---------------------- Host-side GPU path --------------------------

def build_sparse_hist_gpu(keys_h: np.ndarray, nL = DEFAULT_NL, NBINS = DEFAULT_NBINS,
                           blocks = None, threads = THREADS_PER_BLOCK) -> np.ndarray:
    if not HAS_CUDA:
        raise RuntimeError("CUDA not available. Run with --cpu or install CUDA-capable Numba setup.")
    if keys_h.dtype != np.uint32:
        keys_h = keys_h.astype(np.uint32, copy=False)

    n = keys_h.size
    if blocks is None:
        blocks = max(1, (n + threads - 1) // threads)

    # number of nL-bit chunks to visit across a 32-bit key
    nChunks = (32 + nL - 1) // nL

    # Global histogram on device
    g_hist_d = cuda.device_array(NBINS, dtype=np.int32)
    g_hist_d[:] = 0

    # Upload keys
    keys_d = cuda.to_device(keys_h)

    # Dynamic shared memory size in bytes
    shmem = NBINS * np.dtype(np.int32).itemsize

    # Launch kernel (grid-stride)
    hist_kernel[blocks, threads, 0, shmem](keys_d, n, nL, nChunks, g_hist_d, NBINS)
    cuda.synchronize()

    return g_hist_d.copy_to_host()

# ---------------------- CPU fallback (simple, correct) --------------

def build_sparse_hist_cpu(keys: np.ndarray, nL: int = DEFAULT_NL, NBINS: int = DEFAULT_NBINS) -> np.ndarray:
    if keys.dtype != np.uint32:
        keys = keys.astype(np.uint32, copy=False)
    nChunks = (32 + nL - 1) // nL
    hist = np.zeros(NBINS, dtype=np.int64)
    for key in keys:
        for j in range(nChunks):
            k, v = compute_k_and_v_for_chunk(key, j, nL)
            hist[k & (NBINS - 1)] += v
    return hist

# ---------------------- fractal_sort (GPU/CPU) ----------------------

def fractal_sort(data: np.ndarray, use_cuda: bool = False, batches: int = 1,
                 nL: int = DEFAULT_NL, NBINS: int = DEFAULT_NBINS,
                 threads: int = THREADS_PER_BLOCK) -> np.ndarray:
    """Return a histogram-like summary array of length NBINS.
    If `use_cuda` is True and CUDA is available, runs the GPU path.
    If batches > 1, splits data and accumulates into the same global hist.
    """
    if batches < 1:
        batches = 1

    if use_cuda:
        if not HAS_CUDA:
            raise RuntimeError("--cuda requested but CUDA is not available.")
        # Process batches by repeatedly launching on the same device-global hist
        # to avoid host round-trips per batch.
        # We'll allocate the device global histogram once and reuse it across launches.
        data = data.astype(np.uint32, copy=False)
        n = data.size
        chunks = np.array_split(data, batches)

        # Prepare device global histogram
        g_hist_d = cuda.device_array(NBINS, dtype=np.int32)
        g_hist_d[:] = 0

        shmem = NBINS * np.dtype(np.int32).itemsize
        nChunks = (32 + nL - 1) // nL

        for chunk in chunks:
            if chunk.size == 0:
                continue
            keys_d = cuda.to_device(chunk)
            blocks = max(1, (chunk.size + threads - 1) // threads)
            hist_kernel[blocks, threads, 0, shmem](keys_d, chunk.size, nL, nChunks, g_hist_d, NBINS)
        cuda.synchronize()
        return g_hist_d.copy_to_host()

    # CPU fallback
    hist = np.zeros(NBINS, dtype=np.int64)
    for chunk in np.array_split(data, batches):
        if chunk.size == 0:
            continue
        hist += build_sparse_hist_cpu(chunk, nL=nL, NBINS=NBINS)
    return hist

# ---------------------- CLI / Demo ----------------------------------

def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="fractal_sort GPU/CPU demo")
    ap.add_argument("--n", type=int, default=1_000_000, help="number of uint32 keys")
    ap.add_argument("--cuda", action="store_true", help="use CUDA path")
    ap.add_argument("--batches", type=int, default=1, help="split input into this many batches")
    ap.add_argument("--nl", type=int, default=DEFAULT_NL, help="bits per chunk (nL)")
    ap.add_argument("--nbins", type=int, default=DEFAULT_NBINS, help="histogram bins (must fit in shared memory)")
    ap.add_argument("--seed", type=int, default=42, help="rng seed")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    rng = np.random.default_rng(args.seed)
    data = rng.integers(0, 2**32, size=args.n, dtype=np.uint32)

    use_cuda = bool(args.cuda)
    if use_cuda and not HAS_CUDA:
        print("[warn] CUDA not available; falling back to CPU.")
        use_cuda = False

    # Sanity: NBINS must be power-of-two and fit in shared mem
    if args.nbins & (args.nbins - 1) != 0:
        raise ValueError("--nbins must be a power of two (e.g., 1024, 2048, 4096)")
    # Typical GPUs have 48–100 KB of shared mem per block. int32 bins → 4 bytes each.
    # 4096 bins → 16 KB shared; safe on most devices.

    from time import perf_counter
    t0 = perf_counter()
    hist = fractal_sort(data, use_cuda=use_cuda, batches=args.batches,
                        nL=args.nl, NBINS=args.nbins)
    dt = (perf_counter() - t0) * 1000

    print(f"fractal_sort done in {dt:.1f} ms | cuda={use_cuda} | n={args.n:,} | batches={args.batches} | nL={args.nl} | NBINS={args.nbins}")
    print("hist sample:", hist[:32])


if __name__ == "__main__":
    sys.exit(main())

