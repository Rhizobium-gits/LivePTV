"""trackpy reference analysis of trackpy's bulk_water sample (1 µm latex spheres in water, 24 fps, 2.85 px/µm),
following the trackpy walkthrough (diameter 11, invert, link 5 px with memory 3, stubs < 25 frames removed, drift
subtracted). D from (a) the power-law fit of the ensemble MSD, (b) a linear fit over the first 10 lags, (c) the same
lag-1/lag-2 estimator LivePTV uses (Michalet 2010). Writes results/trackpy_bulk_water.json (+ the ensemble MSD as CSV)."""
import glob, json, os, sys, time
import numpy as np, trackpy as tp
from skimage import io as skio

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
tp.quiet()
files = sorted(glob.glob(os.path.join(ROOT, "data/trackpy-examples/sample_data/bulk_water/bulk_water_*.png")))[:300]
frames = [skio.imread(f)[..., 0].astype(float) for f in files]
mpp, fps = 1 / 2.85, 24.0
t0 = time.perf_counter()
f = tp.batch(frames, 11, minmass=130, invert=True, processes=1)
t1 = time.perf_counter()
t = tp.link(f, 5, memory=3)
t2 = time.perf_counter()
t = tp.filter_stubs(t, 25)
drift = tp.compute_drift(t)
tm = tp.subtract_drift(t.copy(), drift).reset_index(drop=True)
em = tp.emsd(tm, mpp, fps, max_lagtime=100)
fit = tp.utils.fit_powerlaw(em, plot=False)
n, A = float(fit["n"].iloc[0]), float(fit["A"].iloc[0])
lag, msd = em.index.values[:10], em.values[:10]
slope, icpt = np.polyfit(lag, msd, 1)
tm = tm.sort_values(["particle", "frame"])


def steps(k):
    g = tm.groupby("particle")
    dx, dy, df = g["x"].diff(k), g["y"].diff(k), g["frame"].diff(k)
    m = df == k
    return np.concatenate([dx[m].values, dy[m].values])


v1, v2 = np.var(steps(1)), np.var(steps(2))
dt = 1 / fps
D_px = (v2 - v1) / (2 * dt)
sig2 = (2 * v1 - v2) / 2
kT, eta = 1.380649e-23 * 293.15, 1.002e-3


def se_nm(D_um2):
    return kT / (3 * np.pi * eta * D_um2 * 1e-12) * 1e9


out = {"features_per_frame": len(f) / len(frames), "tracks": int(t["particle"].nunique()),
       "time_locate_s": t1 - t0, "time_link_s": t2 - t1, "frames": len(frames),
       "powerlaw_n": n, "powerlaw_A_um2": A, "D_powerlaw_um2_s": A / 4,
       "D_linear10_um2_s": slope / 4, "msd_offset_um2": icpt,
       "D_michalet_px2_s": D_px, "D_michalet_um2_s": D_px * mpp ** 2, "loc_sigma_px": float(np.sqrt(max(sig2, 0))),
       "SE_diameter_nm_linear": se_nm(slope / 4), "SE_diameter_nm_michalet": se_nm(D_px * mpp ** 2),
       "drift_px_total": [float(drift["x"].iloc[-1]), float(drift["y"].iloc[-1])]}
json.dump(out, open(os.path.join(ROOT, "results/trackpy_bulk_water.json"), "w"), indent=1)
em.to_csv(os.path.join(ROOT, "results/trackpy_bulk_water_emsd.csv"))
for k, v in out.items():
    print(k, v)
