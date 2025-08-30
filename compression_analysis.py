import numpy as np
import matplotlib.pyplot as plt

# Define the updated C function
def calculate_C_modified_v4(n, p):
    wc = wr = np.log2(n) - 1
    wi = p / np.log(n)
    if n <= 2**p:
        return (1 * p) / (wc + wr/2 + 2 * wi)
    else:
        return (2**(1 - p - 1)) * (n * p) / (wc + 2 * wi)

# Define the n-ranges for each subplot
n_values_1_to_10 = np.logspace(1, 10, 400, base=2)
n_values_10_to_20 = np.logspace(10, 20, 400, base=2)
n_values_20_to_35 = np.logspace(20, 35, 400, base=2)
n_values_30_to_60 = np.logspace(30, 60, 400, base=2)

# Set up 2x2 plot grid
fig, axes = plt.subplots(2, 2, figsize=(16/2, 12/2))
axes = axes.flatten()

# Subplot 1: n = 2^1 to 2^10, p = 4 to 512
for p in [4, 8, 16, 32, 64, 128, 256, 512]:
    axes[0].plot(n_values_1_to_10, [calculate_C_modified_v4(n, p) for n in n_values_1_to_10], label=f'p = {p}')

# Subplot 2: n = 2^10 to 2^20, p = 16 to 512
for p in [16, 32, 64, 128, 256, 512]:
    axes[1].plot(n_values_10_to_20, [calculate_C_modified_v4(n, p) for n in n_values_10_to_20], label=f'p = {p}')

# Subplot 3: n = 2^20 to 2^35, p = 32 to 512
for p in [32, 64, 128, 256, 512]:
    axes[2].plot(n_values_20_to_35, [calculate_C_modified_v4(n, p) for n in n_values_20_to_35], label=f'p = {p}')

# Subplot 4: n = 2^30 to 2^60, p = 64 to 512
for p in [64, 128, 256, 512]:
    axes[3].plot(n_values_30_to_60, [calculate_C_modified_v4(n, p) for n in n_values_30_to_60], label=f'p = {p}')

# Formatting
for ax in axes:
    ax.axhline(y=1, color='g', linestyle='--')
    ax.set_xscale('log', base=2)
    ax.set_xlabel(r'$n$', fontsize=16)
    ax.set_ylabel(r'$C$', fontsize=16)
    ax.tick_params(axis='both', which='major', labelsize=16)
    ax.grid(True)
    ax.legend(loc='center left', bbox_to_anchor=(1, 0.5), fontsize=14)

plt.tight_layout()
plt.show()

