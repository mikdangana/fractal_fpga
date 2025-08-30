import numpy as np
import matplotlib.pyplot as plt
from math import ceil, floor
from numba import njit, prange
from random import random


# parameters ----------------------------------------------
MODEL_SCALE = 2**0 #2**20
CACHE_BITS = 2**29 / MODEL_SCALE          # 4096  counter‑units
WC        = 2.88                      # bits per counter  (empirical)
cache_budget = CACHE_BITS / WC
CACHE_DEPTH = ceil(np.log2(cache_budget))        # ≈ 1 425 counters
COMPUTABLES_MEM = 2**35
computed_budget = COMPUTABLES_MEM / (MODEL_SCALE * WC)
COMPUTABLES_DEPTH = ceil(np.log2(computed_budget))
WC_BITS  = WC   # empirical counter width

INV_2_CACHE        = 1 / 2**CACHE_DEPTH
INV_2_COMP         = 1 / 2**(COMPUTABLES_DEPTH)

print("cache_budget, computed_budget =", cache_budget, computed_budget)


def beff_cache_vec(n_arr, p, *,
                   cache_depth=CACHE_DEPTH,
                   comp_depth=COMPUTABLES_DEPTH,
                   wc_bits=WC_BITS):
    """Vectorised b_eff, n_arr is 1‑D float/uint array."""
    n_arr = np.asarray(n_arr, dtype=np.float64)
    k     = np.ceil(np.log2(n_arr))              # depth for each n

    # zone masks -------------------------------------------------------
    deep  = np.clip(k - cache_depth - comp_depth - 1, 0, None)
    comp  = np.clip(k - cache_depth, 0, comp_depth)
    # counters ---------------------------------------------------------
    wc_comp = wc_bits * comp * INV_2_CACHE
    wc_deep = wc_bits * deep * INV_2_COMP
    wc      = wc_comp + wc_deep
    # pointers + id only for deep zone
    wr   = deep
    wid  = (p / k) * deep

    overhead = 1.5 * (wc + wr + wid)
    return (p) / (p + overhead)


def beff_twozones(n, p):
    """
    n : # entries (scalar or np.ndarray)
    p : precision bits
    """
    n = np.asarray(n, dtype=np.float64)
    k = np.ceil(np.log2(n))                         # depth needed
    # ----------------------------- helper lambdas ----------
    def counter_bits(d, k):
        """counter bits for one level d (0‑based), per entry"""
        return (k - d) / 2**(d + 1) * WC_BITS_PER_COUNT

    # ---- split the tree into three regions ----------------
    wc_comp  = np.zeros_like(n)     # counters in COMPUTABLES zone
    wc_deep  = np.zeros_like(n)     # counters deeper than computables
    wr_deep  = np.zeros_like(n)
    wid_deep = np.zeros_like(n)

    for depth in range(int(k.max())):
        mask = k > depth            # entries whose tree reaches this depth
        if not mask.any():
            break

        bits = counter_bits(depth, k[mask])

        if depth < CACHE_DEPTH:
            continue                                # cached => free

        elif depth < COMPUTABLES_DEPTH:
            wc_comp[mask] += bits                   # counter only

        else:                                       # full overhead
            wc_deep [mask] += bits
            wr_deep [mask] += 1 / 2**(depth+1) * k[mask]  # pointer bits
            wid_deep[mask] += 1 / 2**(depth+1) * p / k[mask]  # id bits

    # per‑entry overheads
    w_c  = wc_comp + wc_deep
    w_r  = wr_deep
    w_id = wid_deep

    overhead = 1.5 * (w_c + w_r + w_id)
    return (p) / (p + overhead)

# --------------------------------------------------------------------
# Smooth, vectorised b_eff for "cache + computables + deep" model
# Everything is per‑entry; nothing is rounded or clipped to integers.
# --------------------------------------------------------------------
CACHE_DEPTH        = 28
COMPUTABLES_DEPTH  = 34
WC_BITS            = 2.88          # bits per counter

INV_2_CACHE = 1 / 2**CACHE_DEPTH
INV_2_COMP  = 1 / 2**(CACHE_DEPTH + COMPUTABLES_DEPTH)

def beff_smooth(d_mb, p):
    """
    d_mb : dataset size in megabits   (can be a NumPy array)
    p    : precision bits
    returns b_eff (same shape as d_mb) without stair‑steps
    """
    n = (d_mb * 2**20) / p          # entries  (float)
    k = np.log2(n)                  # continuous depth (no ceil)
    # how many levels land in each region
    comp_levels = np.clip(k - CACHE_DEPTH, 0, COMPUTABLES_DEPTH)
    deep_levels = np.clip(k - (CACHE_DEPTH + COMPUTABLES_DEPTH), 0, None)

    # per‑entry overhead components
    wc  = WC_BITS * (comp_levels * INV_2_CACHE +
                     deep_levels * INV_2_COMP)
    wr  = deep_levels
    wid = (p / k) * deep_levels

    overhead = 1.5 * (wc + wr + wid)
    return p / (p + overhead)



def beff_cache_ids(dbits, p):
    n = float(dbits)/p*2**20   # dbits Mb to # entries 
    k = np.ceil(np.log2(n))
    w_id = ceil(p/np.log2(n))
    cache_ns = CACHE_BITS / (WC + w_id)
    comp_ns = COMPUTABLES_MEM / (MODEL_SCALE * WC)
    counters_cached = 0
    counters_bits   = 0
    bits_used       = 0
    computed_counts = 0.0
    computed_bits   = 0.0
    unc_counts      = 0.0
    unc_bits        = 0.0

    for d in range(p):           # level sweep
        nodes = (float(n)/float(2**p) * float(2**d))
        counter_bits = nodes * max(p-d,1) #+(1-pr)*max(p-d-1,1)) #max(k-d,1)
        if d <= CACHE_DEPTH or n < cache_budget: # counters_cached+nodes <= cache_ns:
            counters_cached += nodes
            counters_bits += counter_bits
        elif d <= COMPUTABLES_DEPTH: #computed_counts+nodes<=comp_ns:
            computed_counts += nodes
            computed_bits += counter_bits
        else:                         # uncached from here down
            unc_counts += nodes
            unc_bits += counter_bits

    f_computed = float(computed_counts) / (n-1) if n>1 else 0
    f_unc = float(unc_counts) / (n-1) if n>1 else 0
    w_c   = float(computed_bits + unc_bits) / n
    w_c_cache = float(counters_bits)/n
    w_c_comp   = float(computed_bits) / n
    w_c_unc   = float(unc_bits) / n
    w_r   = k * f_unc
    w_id  = p / k * f_unc # / k * (f_unc + ((counters_cached+computed_counts)/(n-1) if n>1 else 0))
    return float(p)/float(p+1.5*(w_c_comp) +w_c_cache + w_c_unc + w_r + w_id) # fractalsort
    #return p / (2*p + 2*(w_c_comp) + 2*w_c_unc + 2*w_r + 2*w_id) # fractalsortA


def beff_cache(n, p):
    n = float(n)
    k = np.ceil(np.log2(n))
    counters_cached = 0
    bits_used       = 0
    computed_counts = 0.0
    computed_bits   = 0.0
    unc_counts      = 0.0
    unc_bits        = 0.0

    tnodes = 0
    #k = k+1 if floor(np.log2(n))==ceil(np.log2(n)) else k
    #for d in range(int(k)):           # level sweep
    for d in range(p):           # level sweep
        nodes = min(float(n)/float(2**p), 1) * (2**d) # if max(k-d,1)>1 else (n % (2**d)) #n / 2**(d+1)
        tnodes += nodes
        counter_bits = nodes * max(p-d,1) #max(k-d,1)
        if d <= CACHE_DEPTH: #counters_cached + nodes <= cache_budget:
            counters_cached += nodes
        elif d <= COMPUTABLES_DEPTH: #counters_cached + nodes <= computed_budget:
            computed_counts += nodes
            computed_bits += counter_bits
        else:                         # uncached from here down
            unc_counts += nodes
            unc_bits += counter_bits
    #print("ceil(k),k,total =", ceil(k),np.log2(n), tnodes)

    f_computed = computed_counts / (n-1) if n>1 else 0
    f_unc = unc_counts / (n-1) if n>1 else 0
    w_c   = (computed_bits + unc_bits) / n
    w_r   = k * f_unc
    w_id  = p / k * f_unc
    if False: #int(n) == 2**29:
        print("f_unc, w_c, w_r, w_id, n,p,k =", f_unc, w_c, w_r, w_id,n,p,k)
    return (p) / (p + 1.5*(w_c) + w_r + w_id) # fractalsort
    #return (p) / (2*p + 2*(w_c) + w_r + w_id) # fractalsortA


def plot_vec():
    p_list  = [8, 16, 32, 64, 128]
    n_vals  = np.logspace(0, 9, 1_000_000)   # one million samples to 1e9


    plt.figure(figsize=(10,6))
    for p in p_list:
        plt.plot(n_vals, beff_cache_vec(n_vals, p),
                 lw=1, label=f"p = {p} bits")
 
    # vertical guides -----------------------------------------
    plt.axvline(2**CACHE_DEPTH,         ls='--', c='black',
                label=f"CACHE_DEPTH = {CACHE_DEPTH}")
    plt.axvline(2**(COMPUTABLES_DEPTH), ls=':', c='grey',
                label=f"COMPUTABLES_DEPTH = {COMPUTABLES_DEPTH}")

    plt.xscale('log');  plt.ylim(0.3, 1.02)
    plt.xlabel("entries  n"); plt.ylabel("bandwidth efficiency  $b_{\\rm eff}$")
    plt.title("b_eff to 1 billion (vectorised NumPy)")
    plt.grid(True, ls='--', alpha=.3);  plt.legend();  plt.show()



def plot_cached():
    # -------------------------------- plot ---------------------------------
    p_list  = [8, 16, 32, 64, 128]
    batches = np.arange(1, 20_000_001, 200)
    n_vals  = batches * 512               # now the x‑coordinate

    fig, ax = plt.subplots(figsize=(10, 6))

    for p in p_list:
        ax.plot(n_vals,                    # <-- x‑axis is n
                [beff_cache(n, p) for n in n_vals],
                marker='.', ms=3, lw=1,
                label=f"p = {p} bits")

    # -- vertical markers ---------------------------------------------------
    ax.axvline(cache_budget,   ls='--', c='purple',
               label=f"CACHE_DEPTH = {CACHE_DEPTH}")
    ax.axvline(computed_budget, ls=':', c='pink',
               label=f"COMPUTABLES_DEPTH = {COMPUTABLES_DEPTH}")
    ax.axvline((2**34)/32, ls=':', c='yellow',
               label=f"16Gb (p=32) = {(2**34)/WC}")

    # cosmetics -------------------------------------------------------------
    ax.set_xscale('log')
    #ax.set_ylim(0.0, 1.02)
    ax.set_xlabel("Number of entries $n$")          # <-- new label
    ax.set_ylabel("Bandwidth efficiency $b_{\\mathrm{eff}}$")
    ax.set_title("b_eff evolution (60 kB top‑level counter cache)")
    ax.grid(True, ls='--', alpha=.35)
    ax.legend()
    plt.show()


def plot_smooth():
    d_vals = np.logspace(2, 7, 2000)        # e.g. 100 Mb … 10 Gb, 2000 points
    fig, ax = plt.subplots(figsize=(10, 6))
    for p in [8, 16, 32, 64, 128]:
         ax.plot(d_vals,
            beff_smooth(d_vals, p),      # <<‑‑ vectorised call
            lw=1.5, label=f"p = {p} bits")

    # -- vertical markers ---------------------------------------------------
    ax.axvline(CACHE_BITS/2**20,   ls='--', c='purple',
               label=f"Cache = {CACHE_BITS/2**20} Mb")
    ax.axvline(COMPUTABLES_MEM/2**20, ls=':', c='pink',
               label=f"Computable = {COMPUTABLES_MEM/2**20} Mb")
    ax.axvline(2**34/2**20, ls=':', c='cyan',
               label=f"d = 16Gb")

    # cosmetics -------------------------------------------------------------
    ax.set_xscale('log')
    #ax.set_ylim(0.0, 1.02)
    ax.set_xlabel("Dataset size $d$ (Mb)")          # <-- new label
    ax.set_ylabel("Bandwidth efficiency $b_{\\mathrm{eff}}$")
    ax.set_title("b_eff evolution (512 Mb BROM counter cache)")
    ax.grid(True, ls='--', alpha=.35)
    ax.legend()
    plt.show()


def plot_datasets():
    # -------------------------------- plot ---------------------------------
    p_list  = [8, 16, 32, 64, 128, 256, 512]
    batches = np.arange(1, 2*128*20_001, 200)
    d_vals  = batches # * 128              # now the x‑coordinate

    fig, ax = plt.subplots(figsize=(10, 6))

    for p in p_list:
        ax.plot(d_vals,                    # <-- x‑axis is n
                [beff_cache_ids(d_mbits, p) for d_mbits in d_vals],
                marker='.', ms=3, lw=1,
                label=f"p = {p} bits")

    # -- vertical markers ---------------------------------------------------
    ax.axvline(CACHE_BITS/2**20,   ls='--', c='purple',
               label=f"Cache = {CACHE_BITS/2**20} Mb")
    ax.axvline(COMPUTABLES_MEM/2**20, ls='--', c='pink',
               label=f"Compute = {COMPUTABLES_MEM/2**30} Gb")
    ax.axvline(2**32/2**20, ls=':', c='cyan',
               label=f"D = 4Gb")
    ax.axvline(2**33/2**20, ls=':', c='gold',
               label=f"D = 8Gb")
    ax.axvline(2**34/2**20, ls=':', c='coral',
               label=f"D = 16Gb")
    ax.axvline(2**39/2**20, ls=':', c='turquoise',
               label=f"D = 512Gb")
    ax.axvline(2**42/2**20, ls=':', c='violet',
               label=f"D = 2Tb")

    # cosmetics -------------------------------------------------------------
    ax.set_xscale('log')
    #ax.set_ylim(0.0, 1.02)
    ax.set_xlabel("Dataset size $D$ (Mb)")          # <-- new label
    ax.set_ylabel("Bandwidth efficiency $b_{\\mathrm{eff}}$")
    ax.set_title("b_eff evolution (512 Mb BROM counter cache)")
    ax.grid(True, ls='--', alpha=.35)
    ax.legend()
    plt.show()


#plot_vec()
plot_datasets()
#plot_smooth()
