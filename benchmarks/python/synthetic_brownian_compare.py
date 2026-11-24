"""Which diffusion estimate is right? Synthetic Brownian particles made to resemble trackpy's bulk_water sample
(particle images ≈ 6.4 px across, D = 3.5 px²/s at 24 fps → 0.54 px per axis per frame, slow drift, 300 frames),
with the true D known. Both trackings (LivePTV detector + tracker via the harness, trackpy as in the walkthrough) are
evaluated with the same two estimators: lag-1/lag-2 with localisation noise removed, and the ensemble MSD (first 10
lags, drift removed). Writes results/synthetic_brownian.json."""
import json, os, subprocess, sys, tempfile
import numpy as np, pandas as pd, trackpy as tp

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import HARNESS, render, to_u8, write_frames  # noqa: E402

RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results")
tp.quiet()
W, H, FPS, D_TRUE, N, FRAMES = 640, 424, 24.0, 3.5, 350, 300


def estimators(tracks):
    """tracks: frame, particle, x, y (px). Returns D (px²/s) from lag 1/2 and from the MSD fit."""
    t = tp.filter_stubs(tracks, 25)
    drift = tp.compute_drift(t)
    tm = tp.subtract_drift(t.copy(), drift).reset_index(drop=True).sort_values(["particle", "frame"])
    g = tm.groupby("particle")

    def var(k):
        dx, dy, df = g["x"].diff(k), g["y"].diff(k), g["frame"].diff(k)
        m = df == k
        return np.var(np.concatenate([dx[m].values, dy[m].values]))

    v1, v2 = var(1), var(2)
    d12 = (v2 - v1) / (2 / FPS)
    em = tp.emsd(tm, 1.0, FPS, max_lagtime=10)
    slope = np.polyfit(em.index.values[:10], em.values[:10], 1)[0]
    return float(d12), float(slope / 4), float(np.sqrt(max(0, (2 * v1 - v2) / 2))), int(tm.particle.nunique())


def main(seed=5):
    rng = np.random.default_rng(seed)
    x = rng.uniform(5, W - 6, N); y = rng.uniform(5, H - 6, N)
    I0 = rng.uniform(90, 150, N)
    step = np.sqrt(2 * D_TRUE / FPS)
    frames = []
    for k in range(FRAMES):
        frames.append(to_u8(render(x, y, W, H, 6.4, I0), 3.0, rng, background=20))
        x = x + 0.8 / FPS + rng.normal(0, step, N)
        y = y + 0.2 / FPS + rng.normal(0, step, N)
    out = {"D_true_px2_s": D_TRUE}
    with tempfile.TemporaryDirectory() as td:
        fi, fo = os.path.join(td, "f.u8"), os.path.join(td, "s.csv")
        write_frames(fi, frames)
        subprocess.run([HARNESS, "ptv", fi, fo, "--maxdisp", "6", "--bg", "1"], check=True)
        det = pd.read_csv(fo + ".det.csv").rename(columns={"track": "particle"})
        det = det[det.particle > 0]
        d12, dmsd, sig, ntr = estimators(det[["frame", "particle", "x", "y"]])
        out["LivePTV"] = {"D_lag12": d12, "D_msd10": dmsd, "loc_sigma_px": sig, "tracks": ntr}
    f = tp.batch([fr.astype(float) for fr in frames], 11, minmass=100, processes=1)
    t = tp.link(f, 5, memory=3)
    d12, dmsd, sig, ntr = estimators(t[["frame", "particle", "x", "y"]].reset_index(drop=True))
    out["trackpy"] = {"D_lag12": d12, "D_msd10": dmsd, "loc_sigma_px": sig, "tracks": ntr}
    for k in ("LivePTV", "trackpy"):
        for e in ("D_lag12", "D_msd10"):
            out[k][e + "_bias_pct"] = 100 * (out[k][e] / D_TRUE - 1)
    json.dump(out, open(os.path.join(RES, "synthetic_brownian.json"), "w"), indent=1)
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
