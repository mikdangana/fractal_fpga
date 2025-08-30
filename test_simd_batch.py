# plot_fractalsort_from_test_simd.py
# -----------------------------------------------------------------------------
# Runs fractalsort from the existing 'test_simd.py' module with NO CLI flags.
# For each n in {2^20, …, 2^29}, measures latency and peak RSS across batches
# b = 1..10 and produces two figures:
#   - fractalsort_latency_vs_batches.png
#   - fractalsort_memory_vs_batches.png
# -----------------------------------------------------------------------------

import os
import time
import threading
import numpy as np
import concurrent.futures as cf
from math import ceil, log2
from typing import Optional, Callable, Any, Tuple

# Use a headless-safe backend if there is no display
import matplotlib
if not os.environ.get("DISPLAY"):
    try:
        matplotlib.use("Agg", force=True)
    except Exception:
        pass
import matplotlib.pyplot as plt

# Import your sorter functions from the existing file
import test_simd as ts  # <-- must be on PYTHONPATH / same directory


# --------------------------- Helpers -----------------------------------------

def random_u32(N: int, seed: int = 123) -> np.ndarray:
    rng = np.random.default_rng(seed)
    return rng.integers(0, 2**32, size=N, dtype=np.uint32)


def _get_rss_bytes_portable() -> Optional[int]:
    """Return current process RSS bytes, or None if unavailable."""
    # psutil (best) if present
    try:
        import psutil  # type: ignore
        return psutil.Process(os.getpid()).memory_info().rss
    except Exception:
        pass
    # /proc (Linux)
    try:
        with open("/proc/self/statm", "r") as f:
            fields = f.read().split()
            pages = int(fields[1])  # resident set size in pages
        page_sz = os.sysconf("SC_PAGE_SIZE")
        return pages * page_sz
    except Exception:
        pass
    # resource fallback (units differ by OS; approximate)
    try:
        import resource  # type: ignore
        r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        # Linux typically KiB; macOS bytes
        return int(r * 1024) if r < 10**9 else int(r)
    except Exception:
        return None


def _run_with_peak_rss(func: Callable[[], Any], sample_sec: float = 0.02) -> Tuple[Any, float, float]:
    """
    Run 'func()', sampling RSS in a background thread.
    Returns (result, latency_seconds, peak_delta_bytes or nan).
    """
    baseline = _get_rss_bytes_portable()
    peak = baseline if baseline is not None else None
    stop = threading.Event()

    def _sampler():
        nonlocal peak
        while not stop.is_set():
            rss = _get_rss_bytes_portable()
            if rss is not None:
                peak = rss if peak is None else max(peak, rss)
            time.sleep(sample_sec)

    t = threading.Thread(target=_sampler, daemon=True)
    t.start()
    t0 = time.time()
    try:
        result = func()
    finally:
        latency = time.time() - t0
        stop.set()
        t.join(timeout=1.0)

    if baseline is None or peak is None:
        peak_delta = float("nan")
    else:
        peak_delta = float(max(0, peak - baseline))
    return result, latency, peak_delta


# Try to call ts.fractal_worker with (chunk, Lmax, carry) or (chunk, Lmax)
def _call_fractal_worker(chunk: np.ndarray, Lmax: int, carry: Optional[np.ndarray]) -> np.ndarray:
    try:
        return ts.fractal_worker(chunk, Lmax, carry)  # type: ignore[attr-defined]
    except TypeError:
        return ts.fractal_worker(chunk, Lmax)        # type: ignore[attr-defined]


def fractal_sort_batched(data: np.ndarray, batches: int = 1, parallel: bool = True) -> np.ndarray:
    """
    Split 'data' into 'batches' chunks and run ts.fractal_worker on each,
    then reduce by summing the returned count arrays.
    """
    if batches < 1:
        raise ValueError("batches must be >= 1")
    Lmax = ceil(log2(max(1, len(data))))
    chunks = np.array_split(data, batches)

    if not parallel or batches == 1:
        global_cnt = None
        for c in chunks:
            global_cnt = _call_fractal_worker(c, Lmax, global_cnt)
        return global_cnt if global_cnt is not None else np.zeros(1, dtype=np.uint32)

    with cf.ThreadPoolExecutor(max_workers=batches) as pool:
        results = list(pool.map(lambda c: _call_fractal_worker(c, Lmax, None), chunks))
    return np.sum(np.stack(results, axis=0), axis=0, dtype=np.uint32)


# --------------------------- Main plotting logic ------------------------------

def plot_fractalsort_latency_and_memory_vs_batches(
    exponents=range(20, 30),      # 2^20 … 2^29 (can be heavy)
    b_start=1, b_end=10,          # batches 1 … 10
    repeats=1,                    # average latency over this many runs
    seed=123,
    parallel=False,
    save_latency="fractalsort_latency_vs_batches.png",
    save_memory="fractalsort_memory_vs_batches.png",
):
    """
    For each N = 2^exp, measure latency and peak additional RSS while sorting,
    across batches b=1..10. Produce two figures (one line per N):
      1) latency vs batches
      2) peak additional RSS (MiB) vs batches
    """

    # Warm-up on small input to avoid JIT/first-run skew if numba/JIT is used
    try:
        _ = fractal_sort_batched(random_u32(1 << 18, seed=seed), batches=1, parallel=parallel)
    except Exception:
        # If warm-up fails, continue anyway
        pass

    b_values = list(range(b_start, b_end + 1))
    latency_series = {}
    mem_series = {}

    for exp in exponents:
        N = 1 << exp
        try:
            data = random_u32(N, seed=seed + exp)
        except MemoryError:
            print(f"[skip] Unable to allocate input for N=2^{exp} ({N:,}). Skipping.")
            continue

        latencies = []
        peaks_mib = []

        for b in b_values:
            total_lat = 0.0
            peak_max_bytes = 0
            saw_nan = False

            for _r in range(repeats):
                _, elapsed, peak_bytes = _run_with_peak_rss(
                    #lambda: fractal_sort_batched(data, batches=b, parallel=parallel),
                    lambda: ts.fractal_sort(data, batches=b),
                    sample_sec=0.02,
                )
                total_lat += elapsed
                if np.isnan(peak_bytes):
                    saw_nan = True
                else:
                    peak_max_bytes = max(peak_max_bytes, int(peak_bytes))

            latencies.append(total_lat / max(1, repeats))
            peaks_mib.append(float("nan") if saw_nan else (peak_max_bytes / (1024 * 1024)))

            print(f"[N=2^{exp}  b={b}]  latency={latencies[-1]:.3f}s  peak={peaks_mib[-1]:.1f} MiB")

        latency_series[exp] = np.asarray(latencies, dtype=float)
        mem_series[exp] = np.asarray(peaks_mib, dtype=float)

    # Plot 1: latency vs batches
    plt.figure(figsize=(10, 6))
    for exp, series in latency_series.items():
        plt.plot(b_values, series, marker="o", linewidth=2,
                 label=f"N=2^{exp} ({1<<exp:,})")
    plt.title("fractalsort latency vs number of batches (b)")
    plt.xlabel("Batches (b)")
    plt.ylabel("Latency (s)")
    plt.xticks(b_values)
    plt.grid(True, linestyle=":")
    plt.legend(title="Input size", bbox_to_anchor=(1.04, 1), loc="upper left")
    plt.tight_layout()
    plt.savefig(save_latency)
    print(f"[saved] {os.path.abspath(save_latency)}")
    try:
        plt.show()
    except Exception:
        pass
    plt.close()

    # Plot 2: peak memory vs batches
    plt.figure(figsize=(10, 6))
    for exp, series in mem_series.items():
        plt.plot(b_values, series, marker="o", linewidth=2,
                 label=f"N=2^{exp} ({1<<exp:,})")
    plt.title("fractalsort peak memory vs number of batches (b)")
    plt.xlabel("Batches (b)")
    plt.ylabel("Peak Memory (MiB)")
    plt.xticks(b_values)
    plt.grid(True, linestyle=":")
    plt.legend(title="Input size", bbox_to_anchor=(1.04, 1), loc="upper left")
    plt.tight_layout()
    plt.savefig(save_memory)
    print(f"[saved] {os.path.abspath(save_memory)}")
    try:
        plt.show()
    except Exception:
        pass
    plt.close()


def plot_fractalsort_latency_and_memory_vs_batches_4plot(
    exponents=range(20, 30),      # 2^20 … 2^29 (can be heavy)
    b_start=1, b_end=10,          # batches 1 … 10
    repeats=1,                    # average latency over this many runs
    seed=123,
    parallel=False,
    save_latency="fractalsort_latency_vs_batches.png",
    save_memory="fractalsort_memory_vs_batches.png",
    save_fourpanel="fractalsort_latency_memory_4panel.png",
):
    """
    For each N = 2^exp, measure latency and peak additional RSS while sorting,
    across batches b=1..10. Produces:
      1) latency vs batches (single figure)
      2) peak memory vs batches (single figure)
      3) four-panel figure:
         TL: latency (2^20->2^29)
         TR: latency (2^20->2^25)
         BL: peak memory (2^20->2^29)
         BR: peak memory (2^20->2^25)
    """

    # Warm-up on small input to avoid JIT/first-run skew if numba/JIT is used
    #try:
        #_ = fractal_sort_batched(random_u32(1 << 18, seed=seed), batches=1, parallel=parallel)
    #except Exception:
    #    pass  # continue anyway

    b_values = list(range(b_start, b_end + 1))
    latency_series = {}  # exp -> np.array [len(b_values)]
    mem_series = {}      # exp -> np.array [len(b_values)] (MiB)

    for exp in exponents:
        N = 1 << exp
        try:
            data = random_u32(N, seed=seed + exp)
        except MemoryError:
            print(f"[skip] Unable to allocate input for N=2^{exp} ({N:,}). Skipping.")
            continue

        latencies = []
        peaks_mib = []

        for b in b_values:
            total_lat = 0.0
            peak_max_bytes = 0
            saw_nan = False

            for _r in range(repeats):
                # Use the local batching wrapper (calls your worker(s))
                _, elapsed, peak_bytes = _run_with_peak_rss(
                    lambda: ts.fractal_sort(data, batches=b, serial=True),
                    sample_sec=0.02,
                )
                total_lat += elapsed
                if np.isnan(peak_bytes):
                    saw_nan = True
                else:
                    peak_max_bytes = max(peak_max_bytes, int(peak_bytes))

            lat = total_lat / max(1, repeats)
            pmib = float("nan") if saw_nan else (peak_max_bytes / (1024 * 1024))

            latencies.append(lat)
            peaks_mib.append(pmib)

            print(f"[N=2^{exp}  b={b}]  latency={lat:.3f}s  peak={pmib:.3f} MiB")

        latency_series[exp] = np.asarray(latencies, dtype=float)
        mem_series[exp] = np.asarray(peaks_mib, dtype=float)

    # ----------------- Single figure: latency vs batches -----------------
    plt.figure(figsize=(10, 6))
    for exp, series in latency_series.items():
        mu = np.nanmean(series)
        sig = np.nanstd(series, ddof=1) if np.isfinite(series).sum() >= 2 else 0.0
        mn = np.nanmin(series)
        plt.plot(b_values, series, marker="o", linewidth=2,
                 label=f"N=2^{exp} (min={mn:.2f}, σ={sig:.2f})")
        for x, y in zip(b_values, series):
            if np.isfinite(y):
                plt.annotate(f"{y:.2f}", (x, y), textcoords="offset points",
                             xytext=(0, 5), ha="center", fontsize=9)
    plt.title("fractalsort latency vs number of batches (b)", fontsize=14)
    plt.xlabel("Batches (b)", fontsize=14)
    plt.ylabel("Latency (s)", fontsize=14)
    plt.xticks(b_values, fontsize=12)
    plt.yticks(fontsize=12)
    plt.grid(True, linestyle=":")
    plt.legend(title="Input size (stats over b)", bbox_to_anchor=(1.04, 1), loc="upper left", fontsize=10)
    plt.tight_layout()
    plt.savefig(save_latency)
    print(f"[saved] {os.path.abspath(save_latency)}")
    try: plt.show()
    except Exception: pass
    plt.close()

    # ----------------- Single figure: peak memory vs batches -------------
    plt.figure(figsize=(10, 6))
    for exp, series in mem_series.items():
        # CHANGE: compute stats on values relative to the series' minimum (avoid axis offset artifacts)
        rel = series - np.nanmin(series)
        mu = np.nanmean(rel)
        sig = np.nanstd(rel, ddof=1) if np.isfinite(rel).sum() >= 2 else 0.0
        mn = np.nanmin(rel)
        plt.plot(b_values, series, marker="o", linewidth=2,
                 label=f"N=2^{exp} (min={mn:.3f}, σ={sig:.3f})")
        if False:
          for x, y in zip(b_values, series):
            if np.isfinite(y):
                plt.annotate(f"{y:.3f}", (x, y), textcoords="offset points",
                             xytext=(0, 5), ha="center", fontsize=9)
    plt.title("fractalsort peak memory vs number of batches (b)", fontsize=14)
    plt.xlabel("Batches (b)", fontsize=14)
    plt.ylabel("Peak Memory (MiB)", fontsize=14)
    # CHANGE: turn off y-axis offset/scientific formatting for memory plots
    plt.gca().ticklabel_format(axis="y", style="plain", useOffset=False)
    plt.xticks(b_values, fontsize=12)
    plt.yticks(fontsize=12)
    plt.grid(True, linestyle=":")
    plt.legend(title="Input size (stats over b)", bbox_to_anchor=(1.04, 1), loc="upper left", fontsize=10)
    plt.tight_layout()
    plt.savefig(save_memory)
    print(f"[saved] {os.path.abspath(save_memory)}")
    try: plt.show()
    except Exception: pass
    plt.close()

    # ----------------- Four-panel figure: latency/memory, two ranges -----
    def _plot_lines_with_stats(ax, series_dict, exps, y_label, value_fmt, *, memory=False):
        have_any = False
        for e in exps:
            if e not in series_dict:
                continue
            y = series_dict[e]
            # CHANGE: for memory panes, compute stats relative to the series' minimum
            y_stats = (y - np.nanmin(y)) if memory else y
            mn = np.nanmin(y)
            sig = np.nanstd(y_stats, ddof=1) if np.isfinite(y_stats).sum() >= 2 else 0.0
            label = f"N=2^{e} (min={mn:{value_fmt}}, σ={sig:{value_fmt}})"
            ax.plot(b_values, y, marker="o", linewidth=2, label=label)
            if "Latency" in y_label:
              for x, yi in zip(b_values, y):
                if np.isfinite(yi):
                    ax.annotate(f"{yi:{value_fmt}}", (x, yi),
                                textcoords="offset points", xytext=(0, 5),
                                ha="center", fontsize=9)
            have_any = True
        if not have_any:
            ax.text(0.5, 0.5, "No data", ha="center", va="center", fontsize=12)
        ax.set_xlabel("Batches (b)", fontsize=14)
        ax.set_ylabel(y_label, fontsize=14)
        ax.grid(True, linestyle=":")
        ax.tick_params(axis="both", labelsize=12)
        # CHANGE: disable offset for memory subplots to avoid "+1.28e3" display
        if memory:
            ax.ticklabel_format(axis="y", style="plain", useOffset=False)
        ax.legend(fontsize=9)

    exps_26_29 = [e for e in range(26, 30) if e in latency_series]
    exps_20_25 = [e for e in range(20, 26) if e in latency_series]

    fig, axes = plt.subplots(2, 2, figsize=(14, 10), sharex=False, sharey=False)

    # TL: latency 2^25 -> 2^29
    ax = axes[0, 0]
    _plot_lines_with_stats(ax, latency_series, exps_26_29, y_label="Latency (s)", value_fmt=".2f", memory=False)
    ax.set_title(r"Latency for $n=2^{26} \to 2^{%d}$" % (exps_26_29[-1] if exps_26_29 else 29), fontsize=14)

    # TR: latency 2^20 -> 2^25
    ax = axes[0, 1]
    _plot_lines_with_stats(ax, latency_series, exps_20_25, y_label="Latency (s)", value_fmt=".2f", memory=False)
    ax.set_title(r"Latency for $n=2^{20} \to 2^{%d}$" % (exps_20_25[-1] if exps_20_25 else 25), fontsize=14)

    # BL: memory 2^20 -> 2^29
    ax = axes[1, 0]
    _plot_lines_with_stats(ax, mem_series, exps_26_29, y_label="Peak Memory (MiB)", value_fmt=".3f", memory=True)
    ax.set_title(r"Memory for $n=2^{26} \to 2^{%d}$" % (exps_26_29[-1] if exps_26_29 else 29), fontsize=14)

    # BR: memory 2^20 -> 2^25
    ax = axes[1, 1]
    _plot_lines_with_stats(ax, mem_series, exps_20_25, y_label="Peak Memory (MiB)", value_fmt=".3f", memory=True)
    ax.set_title(r"Memory for $n=2^{20} \to 2^{%d}$" % (exps_20_25[-1] if exps_20_25 else 25), fontsize=14)

    plt.tight_layout()
    plt.savefig(save_fourpanel)
    print(f"[saved] {os.path.abspath(save_fourpanel)}")
    try: plt.show()
    except Exception: pass
    plt.close()



# ------------------------------ Run immediately -------------------------------

if __name__ == "__main__":
    # No CLI flags needed—runs full 2^20..2^29 by default.
    # If your machine is RAM-limited, change exponents=range(20, 29)
    plot_fractalsort_latency_and_memory_vs_batches_4plot(
        exponents=range(31, 32),  # 2^20 … 2^29
        b_start=10, b_end=20,
        repeats=1,
        parallel=False,
        save_latency="fractalsort_latency_vs_batches.png",
        save_memory="fractalsort_memory_vs_batches.png",
    )

