#!/usr/bin/env python3
# lsb_histogram.py
#
# python -m pip install numpy numba
#
# Example:
#   python lsb_histogram.py 1000000 16 10
# → generate 1 M random ints, count up to 16-bit substrings,
#   show bins whose count ≥ 10.

import sys
import numpy as np
import concurrent.futures as cf
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from math import ceil, floor
from memory_profiler import memory_usage
from numba import njit, prange, types
from numba.typed import Dict, List
from time import time
from random import randint;

n_workers = 1
executor = ThreadPoolExecutor(max_workers=n_workers)


def parse_args():
    N       = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
    Lmax    = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    minimum = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    return N, Lmax, minimum


# ---------------------------------------------------------------------
# 1  Generate or load your data  (replace this with np.fromfile / pandas, …)
# ---------------------------------------------------------------------
def random_u32(size, seed=42, p=32):
    rng = np.random.default_rng(seed)
    return rng.integers(0, 2**p, size, dtype=np.uint32)


import numpy as np
from numba import types, extending

@extending.intrinsic
def nb_atomic_add_u64(typingctx, arr_t, idx_t, val_t):
    """
    Atomically add `val` into arr[idx] for 1-D uint64 arrays on CPU.
    Returns the old value (fetch_add semantics).
    """
    # Validate types
    if not (isinstance(arr_t, types.Array) and arr_t.ndim == 1 and arr_t.dtype == types.uint64):
        raise TypeError("nb_atomic_add_u64 expects a 1-D array of uint64")
    if idx_t != types.intp or val_t != types.uint64:
        raise TypeError("nb_atomic_add_u64 expects (arr:uint64[:], idx:intp, val:uint64)")

    sig = types.uint64(arr_t, types.intp, types.uint64)

    def codegen(context, builder, signature, args):
        arr, idx, val = args

        # IMPORTANT: pass (context, builder, arr) — not just (builder, arr)
        ary = context.make_array(arr_t)(context, builder, arr)
        data_ptr = ary.data                      # i64* to the first element
        elem_ptr = builder.gep(data_ptr, [idx])  # &arr[idx]

        old = builder.atomic_rmw('add', elem_ptr, val, 'monotonic')
        return old

    return sig, codegen



# ---------------------------------------------------------------------
#  3-way bucketed hash-insert (JIT-compiled, no Python overhead)
# ---------------------------------------------------------------------
#@njit(nogil=True)
@njit(nogil=True, fastmath=True, parallel=True)
def _scatter_tree(keys, Lmax, wc=1, p=16, logp=4, cnts=None):
    #nL    = ceil(p/Lmax)
    #size  = 2**Lmax 
    # bases = np.zeros((size, nL), dtype=np.uint32)
    #cnts  = np.zeros(ceil(2**p*wc/p), dtype=np.uint32)
    nL = logp #5 #ceil(p*np.log2(p)/64) # assumes wc=2 approx
    nJ = floor(p/nL)
    N = 2**(p-logp - 1)
    #kcnts = np.zeros(floor(p/nL)*keys.size, dtype=np.uint32) if cnts is None else None
    cnts = np.zeros(N, dtype=np.uint64) if cnts is None else cnts
    #uniq = np.zeros(1, dtype=np.uint64)
    #counts = np.zeros(1, dtype=np.uint32)
    #masks = np.empty(nL, dtype=np.uint32)
    #for i in range(nL): #range(1, Lmax + 1):
    #    L0, L1 = i*Lmax, min((i+1)*Lmax, p)
    #    masks[i] = ((np.uint32(1) << L1-L0) - 1) << L0 #& (np.uint32(1) << L0)

    for i in prange(keys.size):                 # one pass over input
        for j in prange(floor(p/nL)):
            k = keys[i] & ((np.uint64(1) << j*nL)-1)
            v = np.uint64(1) & (k>>j*nL+0) | np.uint64(1) & (k>>j*nL+2) |\
                np.uint64(1) & (k>>j*nL+4) | np.uint64(1) & (k>>j*nL+8) |\
                np.uint64(1) & (k>>j*nL+16) 
            #cnts[k] += v
            nb_atomic_add_u64(cnts, np.intp(k % cnts.size), np.uint64(v))
            #np.add.at(cnts, k, v)
            #kcnts[i*nJ+j] = k
        #ks = [keys[i] & (np.uint32(1) << l) for l in prange(p-1)]
        #vs = [np.uint32(1) & (ks[l] >> l) for l in prange(p-1)]
        #cnts[ks] += vs
        #cnts[key >> logp] += np.uint32(1) & (key >> l) #if key>0 else 0 #<< (k % fwc)
    #for k in prange(N):
    #    cnts[k] = np.sum(kcnts[k*keys.size:(k+1)*keys.size])
    return cnts.copy()


@njit(nogil=True, fastmath=True, parallel=True)
def _scatter_tree_atomic(keys, Lmax, wc=3, p=32, logp=5, cnts=None):
    # same outer params as before
    nL = 5
    nJ = p // nL
    nJ = floor(p/nL)
    N  = 1 << (p - logp - 1)

    # allocate outputs / staging
    cnts = np.zeros(N, dtype=np.uint64) if cnts is None else cnts
    #if cnts is None:
    #    cnts = np.zeros(N, dtype=np.uint64)

    # stage indices & values computed in parallel
    total = keys.size * nJ
    kbuf  = np.empty(total, dtype=np.uint32)
    vbuf  = np.empty(total, dtype=np.uint32)   # keep as u32, add as u64 later

    for i in prange(keys.size):
        base = i * nJ
        ki   = np.uint64(keys[i])
        for j in range(nJ):
            # match your original mask
            k = ki & ((np.uint64(1) << (j * nL)) - 1)

            # keep your original 'v' formula, just fix parentheses for numba
            ofs = j * nL
            v = ((np.uint64(1) & (k >> (ofs + 0))) |
                 (np.uint64(1) & (k >> (ofs + 2))) |
                 (np.uint64(1) & (k >> (ofs + 4))) |
                 (np.uint64(1) & (k >> (ofs + 8))) |
                 (np.uint64(1) & (k >> (ofs + 16))))

            # ensure idx is within cnts
            kbuf[base + j] = np.uint32(k % N)
            vbuf[base + j] = np.uint32(v)

    # serial, race-free accumulation
    for t in range(total):
        cnts[kbuf[t]] += np.uint64(vbuf[t])

    return cnts.copy()


@njit(nogil=True, fastmath=True)
def binary_hist_sparse(keys, p=32):
    """
    Build a sparse right‑child histogram up to depth `p`.
    Returns
        rights : List[ Dict[uint32, uint32] ]   (length p+1)
                 rights[d][prefix]  ==  count( right child of <prefix>)
    Memory is O(N · average‑popcount), tiny compared with dense 2**p.
    """
    rights = List.empty_list(Dict.empty(
                  key_type=types.uint32, value_type=types.uint32))
    for _ in range(p+1):
        rights.append(Dict.empty(key_type=types.uint32,
                                 value_type=types.uint32))

    for k in keys.astype(np.uint32):
        parent = np.uint32(0)               # prefix of length d‑1
        for depth in range(1, p+1):
            bit = (k >> (depth-1)) & 1
            if bit:                         # only right children stored
                cur = rights[depth].get(parent, 0)
                rights[depth][parent] = cur + 1
            parent = (parent << 1) | bit    # extend prefix for next depth
    return rights



# ──────────────────────────────────────────────────────────────────
# Parameters
#   keys     : uint32[ N ]      (can be uint64 with tiny edits)
#   p        : max prefix depth you need ( 1 … 32 )
#
# Returns
#   parent   : length (p+1) array               parent[d]   = count of *all*
#   right    : numpy object array length p
#              right[d]  is uint32[ 2**d ]      right‑child counts at depth d
#
# Memory  : O(2**p)  (e.g. p=32 → 256 Ki ints); left children not stored.
# Time    : O(n · ceil(p/8))   – one byte pass per 8 prefix bits.
# ──────────────────────────────────────────────────────────────────
@njit(nogil=True, fastmath=True, parallel=True)
def binary_histogram_arrays(keys, p=32):
    assert 1 <= p <= 32
    N      = keys.size
    parent = np.zeros(p + 1,      dtype=np.uint32)      # level‑totals
    right  = [np.zeros(1 << d,    dtype=np.uint32) for d in range(p + 1)]

    # whole array count
    parent[0] = N

    # process prefixes in buckets of 8 bits (one byte)
    for depth in range(1, p + 1):
        bit  = 1 << (depth - 1)                       # mask of current bit
        mask = bit - 1                                # lower (depth‑1) bits

        # right‑child counts at this depth
        rc = right[depth]
        par = right[depth - 1] if depth > 1 else None   # sibling array

        for i in prange(N):
            k = keys[i]
            if k & bit:                                 # bit == 1
                idx = (k & mask)                        # prefix without msb
                rc[idx] += 1

        # fill parent counts for this depth (needed by next level)
        parent[depth] = rc.sum()
        # we could also build new 'par' here if you need parent‑array per node.

    return parent, right



# ---------------------------------------------------------------------
# 2  Core algorithm  (Numba-JIT = C-speed, but all Python semantics)
# ---------------------------------------------------------------------
@njit(parallel=True, fastmath=True)
def build_sparse_hist1(keys, Lmax):
    # Worst-case upper bound on distinct bins
    # (rarely hit in realistic data, but lets us pre-allocate once).
    max_bins = keys.size * Lmax
    bins  = np.empty(max_bins, dtype=np.uint64)
    offs  = 0
    N = keys.size

    for idx in prange(max_bins):                # flat parallel loop
        L     = idx // N                     # 0-based: 0…Lmax-1
        i     = idx - L * N                  # idx % N (faster than %)
        mask  = np.uint32((1 << (L+1)) - 1)  # +1 because L starts at 0 here
        bins[idx] = (np.uint64(L+1) << 32) | (keys[i] & mask)
    #for L in range(Lmax + 1):                 # only this loop is Python
    #    mask = np.uint32((1 << L) - 1)
    #    for i in prange(keys.size):
    #        bins[offs + i] = (np.uint64(L) << 32) | (keys[i] & mask)
    #    offs += keys.size

    all_bins = bins #[:offs]

    # --- sort & run-length encode (Numba’s np.sort is parallel) --------
    #all_bins.sort()                              # in-place timsort-like
    uniq  = np.empty_like(all_bins)
    count = np.empty_like(all_bins, dtype=np.uint32)

    u = 0
    i = 0
    while False: #i < all_bins.size:
        j = i + 1
        while j < all_bins.size and all_bins[j] == all_bins[i]:
            j += 1
        uniq[u]   = all_bins[i]
        count[u]  = j - i
        u += 1
        i  = j

    return uniq[:u], count[:u]                   # trimmed views


# ---------------------------------------------------------------------
#  3-way bucketed hash-insert (JIT-compiled, no Python overhead)
# ---------------------------------------------------------------------
#@njit(nogil=True)
@njit(nogil=True, fastmath=True)
def _scatter_three(keys, Lmax, Ldelta=1, p=32):
    N     = keys.size
    nL = ceil(p/Lmax)
    size  = 2**Lmax #N #* Lmax                         # bucket count
    bases = np.zeros((size, Ldelta, nL), dtype=np.uint64)
    cnts  = np.zeros((size, Ldelta, nL), dtype=np.uint32)
    uniq = np.zeros(1, dtype=np.uint64)
    counts = np.zeros(1, dtype=np.uint32)
    masks = np.empty(nL, dtype=np.uint32)
    for i in range(nL): #range(1, Lmax + 1):
        L0, L1 = i*Lmax, min((i+1)*Lmax, p)
        masks[i] = ((np.uint32(1) << L1-L0) - 1) << L0 #& (np.uint32(1) << L0)

    for k in keys:                              # one pass over input
        for L in range(nL): #range(1, Lmax + 1):
            L0, L1 = L*Lmax, min((L+1)*Lmax, p)
            sub, psub  = k & masks[L], k & masks[L-1 if L>0 else 0]
            full = (np.uint64(L1) << p) | sub
            pfull = (np.uint64(L1) << p) | psub

            idx  = full % size
            pidx  = pfull % size
            base = pidx #full - idx                   # multiple_of_counts_len

            for i in range(Ldelta):                         # linear probe loop
                # 1) try to find matching base or empty cell
                hit   = -1
                empty = -1
                for s in range(Ldelta):
                    b = bases[idx, s, L]
                    if b == base:
                        hit = s
                        break
                    if b == 0 and empty == -1:
                        empty = s

                if hit != -1:                   # match → add 1
                    cnts[idx, hit, L] += 1
                    break

                if empty != -1:                 # claim empty slot
                    bases[idx, empty, L] = base
                    cnts[idx, empty, L]  = 1
                    break

                idx = (idx + 1) % size          # bucket full → probe next

    idx = 0
    for i in range(0): #range(len(cnts)):                 # one pass over bases & cnts
        for j in range(Ldelta):
          for L in range(nL): 
            if L < 1 and cnts[i, j, L] > 0:
                bases[i, j, L] = idx
                counts[idx] = cnts[i, j, L]
                for c in range(cnts[i, j, L]):
                    uniq[idx] = bases[i, j, L]+i
                    idx += 1 if idx < size else 0
            elif cnts[i, j, L] > 0:
                pidx = bases[i, j, L]
                cidx = pidx + counts[pidx]
                uniq[cidx], counts[cidx] = cidx, cnts[i, j, L]
                counts[pidx] -= cnts[i, j, L]
    return uniq[:idx], counts[:idx]


# ---------------------------------------------------------------------
#  Public helper ------------------------------------------------------
def build_sparse_hist(keys: np.ndarray, Lmax: int, global_cnts=None):
    """
    keys   : uint32[ N ]     (raw integers)
    Lmax   : maximum substring length (e.g. 16)
    returns: (bases, cnts)  —  both shape (size, 3)
             bases[i,j] == 0  →  unused cell
    """
    #max_bins = keys.size * Lmax

    return _scatter_tree(keys.astype(np.uint32), Lmax, global_cnts)
    #return binary_hist_sparse(keys.astype(np.uint32))


def radix_uint32(a):
    """Out‑of‑place radix‑LSB sort for uint32; returns a new array."""
    if a.dtype != np.uint32:
        raise TypeError("Only uint32 supported")
    src = a.copy()
    dst = np.empty_like(src)

    for shift in (0, 8, 16, 24):                 # 4 passes
        # 1) histogram  -------------------------------------------------
        counts = np.bincount((src >> shift) & 0xFF, minlength=256)

        # 2) prefix sum  ------------------------------------------------
        offsets = np.uint32(np.cumsum(counts, dtype=np.uint32) - counts)

        # 3) scatter (vectorised)  --------------------------------------
        idx   = offsets[(src >> shift) & 0xFF]
        dst[idx] = src                       # NumPy treats lhs as fancy‑index
        offsets[(src >> shift) & 0xFF] += 1  # bump positions

        src, dst = dst, src                  # swap for next pass

    return src


# ---------------------------------------------------------------------
#  native radix‑LSB sort, 4 passes  -----------------------------------
# ---------------------------------------------------------------------
@njit(nogil=True, fastmath=True)
def radix_uint32_numba(src: np.ndarray) -> np.ndarray:
    """
    Out‑of‑place radix sort (LSB first) for uint32 ndarray.
    Returns a *new* sorted array; original is not modified.
    """
    #if src.dtype != np.uint32:
    #    raise TypeError("radix_uint32_numba expects uint32 array")

    n   = src.size
    buf = np.empty_like(src)                  # work buffer

    # Four passes: process 8 bits (one byte) at a time
    for shift in (0, 8, 16, 24):
        # 1) histogram
        counts = np.zeros(256, dtype=np.uint32)
        for i in range(n):
            counts[(src[i] >> shift) & 0xFF] += 1

        # 2) prefix sum (in‑place, counts -> offsets)
        tot = np.uint32(0)
        for b in range(256):
            c = counts[b]
            counts[b] = tot
            tot += c

        # 3) scatter – streaming, branch‑free
        for i in range(n):
            b  = (src[i] >> shift) & 0xFF
            idx = counts[b]
            buf[idx] = src[i]
            counts[b] = idx + 1

        # swap src ↔ buf for next pass
        src, buf = buf, src

    # after four passes 'src' holds the sorted data
    return src.copy()        # return a fresh ndarray



@njit(nogil=True, fastmath=True)
def hash_u64(x):
    # 64-bit mix constant, David Wheeler’s hash
    x ^= x >> 33; x *= 0xff51afd7ed558ccd
    x ^= x >> 33; x *= 0xc4ceb9fe1a85ec53
    x ^= x >> 33
    return x

@njit(nogil=True, fastmath=True, parallel=True)
def merge_openaddr(l_keys, l_cnt, g_keys, g_cnt):
    cap  = g_keys.size
    for i in prange(l_keys.size):
        k   = l_keys[i]
        add = l_cnt[i]
        slot = hash_u64(k) & (cap-1)

        while True:
            gk = g_keys[slot]
            if gk == 0:                          # empty  →  claim slot
                if np.uint64(0) == \
                   nb_atomic_cas_u64(g_keys, slot, 0, k):
                    g_cnt[slot] = add            # first writer sets cnt
                    break                       # done
                # else another thread won; fall through as an update
            elif gk == k:
                nb_atomic_add_u32(g_cnt, slot, add)
                break
            else:                                # collision → linear probe
                slot = (slot + 1) & (cap-1)


def run_threads(N, Lmax, keys):
    def process_item(i):
        b = int(N/n_workers)
        uniq, count = build_sparse_hist(keys[i*b:(i+1)*b], Lmax)
        return uniq, count


    start = time()
    # Submit each BFS item for processing
    futures = [executor.submit(process_item, i) for i in range(n_workers)]

    # Gather results (new BFS items from each thread)
    return [f.result() for f in as_completed(futures)]




# ---------------------------------------------------------------------
# 3  Main driver -------------------------------------------------------
def main():
    N, Lmax, min_cnt = parse_args()
    keys = random_u32(N)

    start = time()
    #uniq, count = build_sparse_hist(keys, Lmax)
    run_threads(N, Lmax, keys)
    print("local.hist.time =", time()-start, "ms for", N, "entries")

    print(f"# sparse histogram   N={N}   Lmax={Lmax}")

# =============================================================================
#  merge_into_global()
#  --------------------
#  Thread-safe, SIMD-/vector-based merge of one sparse histogram
#  (local_keys, local_cnt) into a *global* sparse histogram that lives
#  in shared memory.  No Python-level loops touch the data; NumPy does
#  all heavy lifting and releases the GIL during the vector ops, so
#  many Python threads can build local histograms concurrently.
# =============================================================================

_global_lock   = threading.Lock()       # protects the global arrays
_global_keys   = np.empty(0, dtype=np.uint64)
_global_counts = np.empty(0, dtype=np.uint32)



def merge_into_global(local_keys: np.ndarray,
                      local_cnts: np.ndarray):
    global _global_keys, _global_counts

    with _global_lock:
        if _global_keys is None:
            _global_keys = local_keys.copy()
            _global_counts  = local_cnts.copy()
            return

        # Merge two sorted 1D lists: keys and counts
        all_keys   = np.concatenate((_global_keys, local_keys))
        all_counts = np.concatenate((_global_counts, local_cnts))

        order      = np.argsort(all_keys, kind='mergesort')
        all_keys   = all_keys  [order]
        all_counts = all_counts[order]

        uniq, idx  = np.unique(all_keys, return_index=True)
        summed     = np.add.reduceat(all_counts, idx)

        _global_keys = uniq
        _global_counts  = summed



#from lsb_histogram import build_sparse_hist, random_u32   # your earlier code

def worker(batch, Lmax):
    bases, cnt = build_sparse_hist(batch, Lmax)
    #merge_into_global(bases, cnt)            # one vectorised merge
    global _global_keys, _global_counts
    _global_keys, _global_counts = bases, cnt


def run_parallel(N=8_400_000*2**2, batches=1):
    Lmax = ceil(np.log2(N))
    data  = random_u32(N)                   # toy input
    chunks = np.array_split(data, batches)
    start = time()

    with cf.ThreadPoolExecutor(max_workers=batches) as pool:
        futs = [pool.submit(worker, chunk, Lmax) for chunk in chunks]
        for f in futs: f.result()           # propagate exceptions

    duration = time()-start
    global _global_keys, _global_counts
    count = 0
    incr = 0
    for i,cnt in enumerate(_global_counts):
        count += cnt
        incr += 1 if i==0 or _global_keys[i]>_global_keys[i-1] else 0
    print("run_parallel.time =", duration, "ms for ", N, "entries with", batches, "batches, count=", count, ", incr=", incr, ", uniq=", np.unique(data).shape)
    print("run_parallel.sample =", np.unique(_global_keys).shape)

    # after the pool exits, global arrays hold the full histogram
    return _global_keys, _global_counts


def merge_right_arrays(batch_rights):
    """
    batch_rights: list of worker results, each = list[depth] of np.arrays

    Returns a list[depth] where each array is the element‑wise
    sum of that depth across all batches.
    """
    p = len(batch_rights[0]) - 1                   # same for every batch

    merged = []
    for d in range(p + 1):
        # stack all batches' depth‑d arrays into a 2‑D tensor
        stacked = np.stack([br[d] for br in batch_rights], axis=0)
        # vectorised reduction – one memory pass
        merged.append(stacked.sum(axis=0, dtype=np.uint64))
    return merged



def fractal_worker(batch, Lmax, global_hist=None):
    _local_cnts = build_sparse_hist(batch, Lmax, global_hist)
    if True:
        return _local_cnts

    @njit(nogil=True, fastmath=True)
    def add(a, b):
        return a + b

    global _global_lock, _global_counts

    with _global_lock:
        if _global_counts is None or _global_counts.shape != _local_cnts.shape:
            _global_counts = _local_cnts.copy()
            return
        _global_counts = add(_global_counts, _local_cnts)


def fractal_sort(data, batches=1, serial=False):
    batches = int(sys.argv[sys.argv.index('-b')+1]) if '-b' in sys.argv else 1
    Lmax = ceil(np.log2(len(data)))
    chunks = np.array_split(data, batches)

    if '-s' in sys.argv or serial: # batches in series
        global_cnt = None
        for chunk in chunks:
            global_cnt = fractal_worker(chunk, Lmax, global_cnt)
    else:                # batches in parallel
        with cf.ThreadPoolExecutor(max_workers=batches) as pool:
            results = list(pool.map(fractal_worker, chunks, [Lmax]*batches))
    
        # ▸ vectorised reduce: stack → sum → inplace
        local_cnts = np.stack(results, axis=0)          # shape = (batches, N)
        global_cnt = local_cnts.sum(axis=0, dtype=np.uint32)

    return global_cnt #merge_right_arrays(results)


def fractal_sort_gpu_sort_rle(keys_host, p=32, nL=5, logp=5):
    import cupy as cp
    keys = cp.asarray(keys_host, dtype=cp.uint32)
    nJ   = p // nL
    # Derive all (k,v) pairs just like your CPU loop; vectorized:
    js   = cp.arange(nJ, dtype=cp.uint32)[None, :]             # (1, nJ)
    Ks   = keys[:, None].astype(cp.uint64)                     # (N, nJ)

    # k = low (j*nL) bits
    k    = Ks & ((cp.uint64(1) << (js * nL)) - 1)              # (N, nJ)

    # v: same bit-pick pattern as your code (watch parens!)
    ofs  = js * nL
    v = ((cp.uint64(1) & (k >> (ofs + 0))) |
         (cp.uint64(1) & (k >> (ofs + 2))) |
         (cp.uint64(1) & (k >> (ofs + 4))) |
         (cp.uint64(1) & (k >> (ofs + 8))) |
         (cp.uint64(1) & (k >> (ofs + 16))))

    # Flatten
    kf = k.reshape(-1)
    vf = v.reshape(-1)

    # If you need a *dense* count array of length Nbins:
    Nbins = 1 << (p - logp - 1)
    kf = (kf % Nbins).astype(cp.int32)

    # Sort by key, then RLE the values
    order = cp.argsort(kf)                     # radix on GPU
    k_sorted = kf[order]
    v_sorted = vf[order].astype(cp.uint64)

    # Run-length encode keys, summing v per unique key
    # cp.diff trick to find boundaries
    if k_sorted.size == 0:
        return cp.zeros(Nbins, dtype=cp.uint64).get()
    boundaries=cp.concatenate([cp.array([True]), k_sorted[1:] != k_sorted[:-1]])
    idx = cp.nonzero(boundaries)[0]
    # segment sums with reduceat
    sums = cp.add.reduceat(v_sorted, idx)
    uniq = k_sorted[boundaries]

    # Materialize dense counts
    cnts = cp.zeros(Nbins, dtype=cp.uint64)
    cnts[uniq] = sums
    return cnts.get()    # back to host



if __name__ == '__main__':
    #print(f'Histogram bins: {gk.size:,}')
    exps = [int(exp) for exp in sys.argv[sys.argv.index('-e')+1].split(',')] \
            if '-e' in sys.argv else [24]
    kinds =sys.argv[sys.argv.index('-k')+1].split(',') if '-k' in sys.argv else\
        ['quicksort','mergesort', 'heapsort', 'timsort', 'radix', 'fractalsort']
    results = [['n']+kinds]
    timings = [['n']+kinds]
    for i in exps:
        rnd = random_u32(2**i)
        results.append([2**i])
        timings.append([2**i])
        for kind in kinds:
            data = rnd.copy()
            start=time()
            if kind=='timsort':
                res=memory_usage((lambda: list(data).sort(),(),{}),interval=0.1)
            elif kind=='radix':
                res=memory_usage((lambda: radix_uint32_numba(data),(),{}),interval=0.1)
            elif kind=='heapsort' and i>29:
                res = []
            elif kind=='fractalgpu':
                res=memory_usage((lambda: fractal_sort_gpu_sort_rle(data),(),{}),interval=0.1)
            else:
                res = memory_usage((lambda: fractal_sort(data) if kind=='fractalsort' else np.sort(data, kind=kind),(),{}),interval=0.1)
            results[-1].append(max(res))
            timings[-1].append(time()-start)
            #print("n, kind, duration =", 2**i, kind, time()-start, "ms")
    for t,res in zip(timings[1:], results[1:]):
        print("n,(MiB),(s)", res+t[1:]) 
    if '-t' in sys.argv:
        for t in timings[1:]:
            print("n,timing (ms) =", t)


if __name__ == "__main_1_":
    main()

