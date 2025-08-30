import numpy as np
import matplotlib.pyplot as plt

# Define the range for L
L = np.arange(10, 101)  # 10 to 100 inclusive

# Compute y = 0.5 * L^2 - L * log2(L)
y = 0.5 * L**2 - L * np.log2(L)

plt.figure(figsize=(8,5))
plt.plot(L, y, marker='o')
plt.title(r'$y = 0.5 L^2 - L \log_2(L)$ for $L=10$ to $L=100$')
plt.xlabel('L')
plt.ylabel('y')
plt.grid(True, linestyle=':')
plt.show()

