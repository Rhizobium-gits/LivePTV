"""What each part of LivePTV 0.8's tracker contributes: the P2 datasets (Taylor–Green flow, exact positions + 0.05 px,
2 % replaced per frame, same seed and draw order as ptv_experiments.py p2) tracked with one part switched off at a
time. Writes results/ptv_ablation.json. `gate` (argument): the speed-dependent gate on faster, sparser flows than P2
covers (seed 99, search radius 24 px) → results/ptv_gate_fast.json."""
import json, os, subprocess, sys, tempfile
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ptv_experiments import simulate, link_scores, HARNESS  # noqa: E402

RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results")
VARIANTS = {
    "LivePTV 0.8 (defaults)": [],
    "closest-first instead of global assignment": ["--global", "0"],
    "no speed-dependent gate (factor 0)": ["--alpha", "0"],
    "speed-dependent gate factor 0.3": ["--alpha", "0.3"],
    "no acceleration term": ["--accel", "0"],
    "neighbour prediction and first-frame vote off": ["--nbpred", "0"],
}


def main():
    rng = np.random.default_rng(22)            # as ptv_experiments.p2_tracking
    sets = []
    for N in (2000, 5000):
        for U in (1, 2, 4, 6, 8, 10):
            df = simulate(rng, N, U)
            df["x"] += rng.normal(0, 0.05, len(df)); df["y"] += rng.normal(0, 0.05, len(df))
            sets.append((N, U, df))
    out = {}
    with tempfile.TemporaryDirectory() as td:
        fi, fo = os.path.join(td, "p.csv"), os.path.join(td, "t.csv")
        for name, flags in VARIANTS.items():
            rows = []
            for N, U, df in sets:
                df[["frame", "x", "y"]].to_csv(fi, index=False)
                subprocess.run([HARNESS, "track", fi, fo, "--maxdisp", "12", "--predrad", "4"] + flags, check=True)
                import pandas as pd
                t = pd.read_csv(fo)
                d2 = df.copy(); d2["track"] = t["track"].to_numpy()
                rows.append({"N": N, "U": U, **link_scores(d2, "track")})
            out[name] = rows
            m = (np.mean([r["precision"] for r in rows]), np.mean([r["recall"] for r in rows]))
            print(f"{name:48s} mean {m[0]:.3f}/{m[1]:.3f} | 5000/10 {rows[-1]['precision']:.3f}/{rows[-1]['recall']:.3f}", file=sys.stderr)
    json.dump(out, open(os.path.join(RES, "ptv_ablation.json"), "w"), indent=1)


def gate_fast():
    import pandas as pd
    rng = np.random.default_rng(99)
    res = {}
    with tempfile.TemporaryDirectory() as td:
        fi, fo = os.path.join(td, "p.csv"), os.path.join(td, "t.csv")
        for N, U in ((2000, 12), (2000, 16), (5000, 12)):
            df = simulate(rng, N, U)
            df["x"] += rng.normal(0, 0.05, len(df)); df["y"] += rng.normal(0, 0.05, len(df))
            df[["frame", "x", "y"]].to_csv(fi, index=False)
            row = {}
            for a in ("0", "0.1", "0.3"):
                subprocess.run([HARNESS, "track", fi, fo, "--maxdisp", "24", "--predrad", "4", "--alpha", a], check=True)
                t = pd.read_csv(fo)
                d2 = df.copy(); d2["track"] = t["track"].to_numpy()
                sc = link_scores(d2, "track")
                row[a] = [round(sc["precision"], 3), round(sc["recall"], 3)]
            res[f"{N}/{U}"] = row
            print(N, U, row, file=sys.stderr)
    json.dump({"source": "ptv_ablation.py gate: the speed-dependent gate on faster flows (seed 99, search radius 24 px)",
               "results": res}, open(os.path.join(RES, "ptv_gate_fast.json"), "w"), indent=1)


if __name__ == "__main__":
    gate_fast() if sys.argv[1:] == ["gate"] else main()
