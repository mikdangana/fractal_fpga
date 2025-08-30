import numpy as np
from collections import defaultdict, Counter

def prefix_histogram(n: int, p: int, rng=None):
    """
    Draw n uniform p-bit integers and build a histogram of ALL MSB-prefixes.
    Returns dict:
        depth ℓ  ->  {'count': Counter, 'prob': np.array}
    """
    rng = np.random.default_rng(rng)
    nums = rng.integers(0, 1 << p, size=n, dtype=np.uint64)

    # depth ℓ  -> Counter
    counts = defaultdict(Counter)

    for x in nums:
        x = int(x)                 # to Python int for bit-shift
        for ℓ in range(1, p + 1):
            counts[ℓ][x >> (p - ℓ)] += 1

    # convert to probabilities
    hist = {}
    for ℓ, ctr in counts.items():
        k = 1 << ℓ
        cnt = np.zeros(k, dtype=int)
        for idx, c in ctr.items():
            cnt[idx] = c
        hist[ℓ] = {
            "count": cnt,
            "prob":  cnt / n
        }
    return hist



if __name__ == "__main__":
    n, p = 100, 16
    hist = prefix_histogram(n, p, rng=42)

    # inspect depth 8
    depth = 8
    print("Counts @", depth, "bits:", hist[depth]["count"][:10], "...")
    print("Probabilities should be ~1/256 =", 1/256)

    # quick bar-plot
    import matplotlib.pyplot as plt
    probs = hist[depth]["prob"]
    x = np.arange(1 << depth)
    plt.bar(x, probs, width=0.8, label='empirical')
    plt.axhline(1 / (1 << depth), c='r', ls='--', label='theory $2^{-\\ell}$')
    plt.xlabel(f'prefix pattern (0‒{2**depth-1})')
    plt.ylabel('probability')
    plt.title(f'n={n}, p={p}, depth={depth}')
    plt.legend()
    plt.tight_layout(); plt.show()

