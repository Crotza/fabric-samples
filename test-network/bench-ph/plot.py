#!/usr/bin/env python3
from pathlib import Path
import argparse
import csv
import math
import matplotlib.pyplot as plt

def read_rows(csv_path: Path):
    rows = []
    with csv_path.open("r", newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            out = {}
            out["algo"] = r["algo"].strip()
            out["file"] = r["file"].strip()

            def to_int(x):
                x = (x or "").strip()
                try:
                    return int(x)
                except:
                    return None

            def to_float(x):
                x = (x or "").strip()
                try:
                    return float(x)
                except:
                    return None

            out["B_bytes"] = to_int(r.get("B_bytes", ""))
            out["bytes"] = to_int(r.get("bytes", "")) or 0
            out["elapsed_ms_med"] = to_float(r.get("elapsed_ms_med", "")) or 0.0
            out["throughput_mib_s"] = to_float(r.get("throughput_mib_s", "")) or 0.0
            out["sum_hex"] = (r.get("sum_hex", "") or "").strip()
            rows.append(out)
    return rows

def pivot_by_file(rows):
    by_file = {}
    for r in rows:
        algo = r.get("algo")
        fname = r.get("file")
        if algo not in ("SHA-256", "PH128"):
            continue
        if fname not in by_file:
            by_file[fname] = {}
        by_file[fname][algo] = r
    return by_file

def _bar_labels(ax, bars, fmt="{}"):
    for b in bars:
        height = b.get_height()
        ax.text(
            b.get_x() + b.get_width()/2.0,
            height,
            fmt.format(f"{height:.2f}"),
            ha="center",
            va="bottom",
            fontsize=9,
            rotation=0
        )

def make_time_plot(rows, out_png: Path):
    by_file = pivot_by_file(rows)

    labels = []
    sha_times = []
    ph_times = []
    for fname, algos in by_file.items():
        if fname == "TOTAL":
            continue
        if "SHA-256" in algos and "PH128" in algos:
            labels.append(fname)
            sha_times.append(algos["SHA-256"]["elapsed_ms_med"])
            ph_times.append(algos["PH128"]["elapsed_ms_med"])

    x = list(range(len(labels)))
    width = 0.4
    fig, ax = plt.subplots(figsize=(10, 5))
    ax.grid(True, axis="y", alpha=0.3)

    bars_sha = ax.bar([i - width/2 for i in x], sha_times, width, label="SHA-256")
    bars_ph  = ax.bar([i + width/2 for i in x], ph_times, width, label="PH128")

    ax.set_title("Elapsed time (ms) por arquivo")
    ax.set_xlabel("Arquivo")
    ax.set_ylabel("Tempo mediano (ms)")
    ax.set_xticks(x, labels, rotation=20, ha="right")
    ax.legend()

    _bar_labels(ax, bars_sha)
    _bar_labels(ax, bars_ph)

    fig.tight_layout()
    fig.savefig(out_png, dpi=120)
    plt.close(fig)

def make_speedup_plot(rows, out_png: Path):
    by_file = pivot_by_file(rows)

    labels = []
    speedups = []
    for fname, algos in by_file.items():
        if "SHA-256" in algos and "PH128" in algos:
            sha_t = algos["SHA-256"]["throughput_mib_s"]
            ph_t  = algos["PH128"]["throughput_mib_s"]
            if sha_t and ph_t:
                labels.append(fname)
                speedups.append(ph_t / sha_t)

    x = list(range(len(labels)))
    fig, ax = plt.subplots(figsize=(10, 5))
    ax.grid(True, axis="y", alpha=0.3)

    bars = ax.bar(x, speedups)
    ax.set_title("Speedup de throughput (PH128 / SHA-256)")
    ax.set_xlabel("Arquivo")
    ax.set_ylabel("Speedup (×)")
    ax.set_xticks(x, labels, rotation=20, ha="right")

    _bar_labels(ax, bars)

    fig.tight_layout()
    fig.savefig(out_png, dpi=120)
    plt.close(fig)

def make_throughput_plot(rows, out_png: Path, title=None):
    """Grouped bars of absolute throughput (MiB/s), SHA-256 vs PH128.
       Adds values atop bars and a light grid behind."""
    by_file = pivot_by_file(rows)

    # Prefer a stable, meaningful order if present
    preferred = ["public_state.data", "private_state_hashes.data", "txids.data", "_all.data", "TOTAL"]
    # Build set of all files that have both algos
    all_labels = [fname for fname, algos in by_file.items() if "SHA-256" in algos and "PH128" in algos]
    # Use preferred ordering first, then the remaining in sorted order
    labels = [f for f in preferred if f in all_labels] + sorted([f for f in all_labels if f not in preferred])

    sha_vals = [by_file[f]["SHA-256"]["throughput_mib_s"] for f in labels]
    ph_vals  = [by_file[f]["PH128"]["throughput_mib_s"] for f in labels]

    x = list(range(len(labels)))
    width = 0.4

    fig, ax = plt.subplots(figsize=(11, 5.5))
    ax.grid(True, axis="y", alpha=0.3)

    bars_sha = ax.bar([i - width/2 for i in x], sha_vals, width, label="SHA-256")
    bars_ph  = ax.bar([i + width/2 for i in x], ph_vals, width, label="PH128")

    title = title or "Snapshot Hashing Throughput — SHA-256 Vs PH128 (150k Tx, 10KB)"
    ax.set_title(title)
    ax.set_xlabel("Arquivo")
    ax.set_ylabel("Throughput (MiB/s)")
    ax.set_xticks(x, labels, rotation=20, ha="right")
    ax.legend()

    _bar_labels(ax, bars_sha)
    _bar_labels(ax, bars_ph)

    fig.tight_layout()
    fig.savefig(out_png, dpi=120)
    plt.close(fig)

def main():
    ap = argparse.ArgumentParser(description="Gerar gráficos do snapshot_bench.csv")
    ap.add_argument("--csv", type=Path, default=Path("snapshot_bench.csv"),
                    help="Caminho para o CSV (default: snapshot_bench.csv)")
    ap.add_argument("--outdir", type=Path, default=Path("."),
                    help="Diretório de saída para as imagens (default: .)")
    ap.add_argument("--title", type=str, default="Snapshot Hashing Throughput — SHA-256 Vs PH128 (150k Tx, 10KB)",
                    help="Título do gráfico de throughput absoluto")
    args = ap.parse_args()

    rows = read_rows(args.csv)
    base = args.csv.stem

    time_png = args.outdir / f"{base}_time.png"
    speedup_png = args.outdir / f"{base}_speedup.png"
    throughput_png = args.outdir / f"{base}_throughput.png"

    make_time_plot(rows, time_png)
    make_speedup_plot(rows, speedup_png)
    make_throughput_plot(rows, throughput_png, title=args.title)

    print("OK! Arquivos salvos:")
    print(" -", time_png)
    print(" -", speedup_png)
    print(" -", throughput_png)

if __name__ == "__main__":
    main()
