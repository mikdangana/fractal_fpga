import math
import numpy as np
import matplotlib.pyplot as plt
from adjustText import adjust_text

BROM_SIZE = 8*2**9 #500 MB
COMPUTABLE_PTR_DEPTH = 35



def get_wc(p, D_bits):
    """
    Mean counter‑width w(n,p) with the new definition:

        k = ceil(log2 n)
        if n < 2^p:
            w = (2^(k+1) - k - 2) / n
        else:
            w = ((k - p + 2) * 2^p - (k + 2)) / (2^p - 1)

    Vectorised for numpy arrays.
    """
    n  = np.asarray(D_bits, dtype=float)
    if len(n.shape) == 0:
        wc, wci, n = 0, np.log2(D_bits), D_bits
        for l in range(p):
            nl = 2**l if 2**l < n/2 else n/2
            wci = wc-1 if wci>2 else 1
            wc += wci * nl 
        print("wc,p,n =", wc/(2*n), p, n)
        return wc/(2*n) 
    wc, wci = np.zeros(n.shape, dtype=np.float64), np.log2(n)
    ntotal = wc
    for l in range(32):
        nl = np.where(2**l <= n/2, np.float64(2**l),  \
                                   n % n/2) #np.where(n>ntotal, n%ntotal, 0)) 
        ntotal += nl
        wc += nl * wci #np.where(wc is None, wci * nl, wc + wci * nl) #np.log2(2**pi/(2**p) * n)
        wci = np.where(wci>2, wci-1, np.float64(1))
    wc = wc/(2*n) 
    if True:
        print("wc,n,1 =", wc[:5], n[:5])
        return wc #if n < 2**p else np.log2(n)/2

    k = np.log2(n)          # ceil(log2 n)
    
    # Boolean masks for sparse (n < 2^p) and dense (n >= 2^p)
    sparse = n < 2**p
    dense  = ~sparse
    
    w = np.empty_like(n, dtype=float)
    
    # --- sparse branch ----------------------------------------------------
    if sparse.any():
        nn = n[sparse]
        kk = k[sparse]
        w[sparse] = (2**(kk + 1) - kk - 2) / nn
    
    # --- dense branch -----------------------------------------------------
    if dense.any():
        nn = n[dense]    # not used, but kept for clarity
        kk = k[dense]
        w[dense] = ((kk - p + 2) * 2**p - (kk + 2)) / (2**p - 1)
    
    return w / 2 # MD: Only half the nodes have counters :)


def plot_bandwidth_efficiency():
    """
    Plots f(D,p) = p / [p + 4*(log2( (D in bits) / p ) - 1)]
    with D in gigabits (Gb) and p in bits.
    Then draws vertical lines at D=8, D=16, and labels intersection points,
    automatically preventing label overlaps via adjustText.
    """

    p_values = [32, 64, 128, 256, 512]
    D_gb = np.logspace(np.log10(4), np.log10(2048), num=100)  # D in gigabits

    plt.figure(figsize=(8,5))

    # We'll collect text objects in this list
    text_objs = []



    for p in p_values:
        # Convert entire D range from Gb to bits
        D_bits = D_gb * 1e9
        # Your custom formula:
        w_c = np.where(D_bits>BROM_SIZE/p, get_wc(p, D_bits), 0.0)
        w_r = np.where(np.log2(D_bits)>COMPUTABLE_PTR_DEPTH, (np.log2(D_bits)-1)/2, 0.0)
        w_id = np.where(np.log2(D_bits)>COMPUTABLE_PTR_DEPTH, math.log2(p)*0 + 2*p/np.log2(D_bits), 0.0)

        if p > 32:  # 1.5 => read/write ratio?
             beff = w_c #p / (p + 1.5*(w_c + w_r/1.5 + w_id)) # w_r written only once
        else:
             beff = p / (p + 1.5*(w_c+w_r+w_id))

        plt.plot(D_gb, beff, label=f"p = {p} bits")

        # Intersection points at D=8, 16:
        for Dfix in [ 4, 8, 16, 32, 512, 1024, 2048 ]:
            Dfix_bits = Dfix * 1e9
            wc_fix = get_wc(p, Dfix_bits)
            wr_fix = (np.log2(Dfix_bits)-1)/2 #8*1.33-0.16 
            wid_fix = math.log2(p)*0 + 2*p/np.log2(Dfix_bits) #1.38

            if p > 32:
                 beff_fix = p / (p + 1.5*(wc_fix + wr_fix/1.5 + wid_fix))
            else:
                 beff_fix = p / (p + 1.5*(wc_fix + wid_fix))

            # Plot intersection marker
            plt.plot(Dfix, beff_fix, 'ko', ms=5)

            # Add label
            txt = plt.text(
                Dfix, beff_fix,
                f"{beff_fix:.3f}",
                fontsize=9, color='k',
                ha='left', va='bottom'
            )
            text_objs.append(txt)

    # Add dashed vertical lines for D=8, D=16
    plt.axvline(x=4,  color='yellow',  linestyle='--', label="D = 4 Gb")
    plt.axvline(x=8,  color='red',  linestyle='--', label="D = 8 Gb")
    plt.axvline(x=16, color='blue', linestyle='--', label="D = 16 Gb")
    plt.axvline(x=32, color='purple', linestyle='--', label="D = 32 Gb")
    plt.axvline(x=512, color='green', linestyle='--', label="D = 512 Gb")
    plt.axvline(x=1024, color='pink', linestyle='--', label="D = 1 Tb")
    plt.axvline(x=2048, color='orange', linestyle='--', label="D = 2 Tb")

    plt.xscale("log")
    plt.xlabel("D (Gb)")
    plt.ylabel("Bandwidth Efficiency")
    #plt.title("Bandwidth Efficiency with Intersection Labels (Overlap-Free)")

    plt.grid(True)
    plt.legend(loc='center')

    # Now adjust the text to reduce overlaps
    adjust_text(
        text_objs, 
        # optional arguments:
        only_move={'points': 'y', 'text': 'xy'},  # e.g., only move text if you prefer
        arrowprops=dict(arrowstyle='->', color='gray', lw=0.8)
    )

    plt.show()

if __name__ == "__main__":
    plot_bandwidth_efficiency()

