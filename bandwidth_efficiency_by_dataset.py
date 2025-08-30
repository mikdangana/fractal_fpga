import math
import numpy as np
import matplotlib.pyplot as plt

def plot_bandwidth_efficiency():
    """
    Plots f(D,p) = p / [p + 4*(log2( (D in bits) / p ) - 1)]
    with D in gigabits (Gb) and p in bits.

    We'll sample D from 8..2048 (Gb) on the x-axis, use various p values in bits,
    and draw vertical dashed lines at D=8 and D=16 (both in Gb).
    """

    # p_values in bits
    # e.g., 32 bits, 64 bits, 128 bits, 256 bits
    # (If you meant something else, adjust accordingly.)
    p_values = [32, 64, 128, 256, 512]

    # Define D from 8Gb to 2048Gb on a log scale
    D_gb = np.logspace(np.log10(8), np.log10(2048), num=100)  # D in gigabits

    plt.figure(figsize=(8,5))

    # 1 Gb = 1e9 bits.  We'll convert D (Gb) -> bits inside the loop.
    for p in p_values:
        # Convert D from Gb to bits
        D_bits = D_gb * 1e9
        # w_c = log2(D_bits / p) - 1
        w_c = 2.304-0.65/np.sqrt(D_bits) #0.5*np.log2(D_bits / p) - 1.0
        w_p = np.log2(D_bits)/8*1.33-0.16 # np.log2(D_bits / p) - 1.0 if p > 32 else 0
        w_id = math.log2(p) + 1.38
        beff = p / (p + 2*(w_c+w_p+w_id)) if p > 16 else D_bits/(w_c*2**p)
        print("D={}, wc={}, wp={}, w_id={}, p={}".format(D_gb,w_c,w_p,w_id,p))
        # f(D,pf)

        plt.plot(D_gb, beff, label=f"p = {p} bits")

    # Add dashed vertical lines at D=8Gb and D=16Gb
    plt.axvline(x=8,  color='red', linestyle='--', label="D = 8 Gb")
    plt.axvline(x=16, color='blue', linestyle='--', label="D = 16 Gb")

    # Log scale on x-axis to handle the wide D range
    plt.xscale("log")

    plt.xlabel("D (Gb)")
    plt.ylabel("Bandwidth Efficiency")  # or "f(D,p)"
    plt.title(r"Bandwidth Efficiency: $f(D,p) = \frac{p}{p + 4(\log_{2}(\frac{D_{\mathrm{bits}}}{p}) - 1)}$")
    plt.grid(True)
    plt.legend()
    plt.show()

if __name__ == "__main__":
    plot_bandwidth_efficiency()

