import numpy as np
import matplotlib.pyplot as plt

def plot_function():
    """
    Plots the function f(D,p) = p / (p + 4*w_c), where w_c = D/p - 1,
    for p in [32..256] and D in [8..2048] (interpreting D as gigabits).

    You can adjust the list of D values or plot style as needed.
    """
    # Define a set of D values in gigabits (Gb). 
    # For example, powers of two from 8Gb up to 2048Gb (~2Tb).
    D_values = [8, 16, 32, 64, 128, 256, 512, 1024, 2048]

    # Define p values (integers from 32 to 256).
    p_values = np.arange(32, 257)

    # Create a figure
    plt.figure(figsize=(8, 5))

    # For each D, compute and plot f(D,p)
    for D in D_values:
        # w_c = (D / p) - 1
        # f(D,p) = p / [p + 4 * w_c]
        b = 2**(8-30)
        w_c, w_p, ids = D/p_values, 1.33+(D-b)/b*(2.31-1.33), 8.38 #(D / p_values) - 1
        fDp = p_values / (p_values + 4 * w_c)

        # Plot f(D,p) vs. p
        plt.plot(p_values, fDp, label=f"{D} Gb")

    plt.xlabel("p")
    plt.ylabel(r"$\frac{p}{p + 4 w_c}$")
    plt.title("Plot of f(D,p) for various D (8 Gb to 2 Tb)")
    plt.legend()
    plt.grid(True)
    plt.show()

if __name__ == "__main__":
    plot_function()

