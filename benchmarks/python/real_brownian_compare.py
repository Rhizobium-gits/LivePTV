"""bulk_water (real video): LivePTV's own session (showcase/real_brownian, written by ShowcaseTests.realBrownianVideo
through the app pipeline) against trackpy (results/trackpy_bulk_water.json from real_brownian_trackpy.py). The same two estimators on both trackings:
(a) LivePTV's lag-1/lag-2 estimator with localisation noise removed (Michalet 2010), (b) trackpy's ensemble MSD after
removing stubs < 25 frames and the drift, linear fit over the first 10 lags. Writes results/real_brownian.json and a
figure for the README."""
import json, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np, pandas as pd, trackpy as tp
from skimage import io as skio

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
RES = os.path.join(ROOT, "results")
FIG = os.environ.get("README_IMAGES", os.path.join(ROOT, "..", "docs", "images"))
BLUE, AQUA, INK, INK2, GREY, SURFACE = "#2a78d6", "#1baf7a", "#0b0b0b", "#52514e", "#8a8984", "#fcfcfb"
plt.rcParams.update({"font.family": "Arial", "font.size": 10, "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
                     "savefig.facecolor": SURFACE, "axes.spines.top": False, "axes.spines.right": False,
                     "axes.grid": True, "grid.color": "#e4e3df", "legend.frameon": False})
tp.quiet()
mpp, fps = 1 / 2.85, 24.0
kT, eta = 1.380649e-23 * 293.15, 1.002e-3


def se_nm(d_um2):
    return kT / (3 * np.pi * eta * d_um2 * 1e-12) * 1e9


def main():
    ev = json.load(open(os.path.join(ROOT, "showcase/real_brownian/evaluation.json")))
    tpj = json.load(open(os.path.join(ROOT, "results/trackpy_bulk_water.json")))
    p = pd.read_csv(os.path.join(ROOT, "showcase/real_brownian/particles.csv"))
    t = p.rename(columns={"frame_index": "frame", "track_id": "particle", "x_px": "x", "y_px": "y"})[["frame", "particle", "x", "y"]]
    t = t[t.particle > 0]
    t = tp.filter_stubs(t, 25)
    drift = tp.compute_drift(t)
    tm = tp.subtract_drift(t.copy(), drift).reset_index(drop=True)
    em = tp.emsd(tm, mpp, fps, max_lagtime=100)
    slope, icpt = np.polyfit(em.index.values[:10], em.values[:10], 1)
    em_tp = pd.read_csv(os.path.join(ROOT, "results/trackpy_bulk_water_emsd.csv"), index_col=0).iloc[:, 0]
    d_live_app = ev["diffusion"]["dUm2PerS"]
    out = {
        "LivePTV": {"D_app_lag12_um2_s": d_live_app, "D_app_se_um2_s": ev["diffusion"]["standardErrorUm2PerS"],
                    "size_app_nm": ev["diffusion"]["stokesEinsteinDiameterNm"], "D_msd10_um2_s": slope / 4,
                    "size_msd10_nm": se_nm(slope / 4), "tracks_ge25": int(tm.particle.nunique()),
                    "detections_per_frame": float(len(p) / p.frame_index.nunique())},
        "trackpy": {"D_lag12_um2_s": tpj["D_michalet_um2_s"], "size_lag12_nm": tpj["SE_diameter_nm_michalet"],
                    "D_msd10_um2_s": tpj["D_linear10_um2_s"], "size_msd10_nm": tpj["SE_diameter_nm_linear"],
                    "D_powerlaw_um2_s": tpj["D_powerlaw_um2_s"], "powerlaw_n": tpj["powerlaw_n"],
                    "detections_per_frame": tpj["features_per_frame"]},
        "nominal": {"diameter_nm": 1000, "D_um2_s_20C": kT / (3 * np.pi * eta * 1e-6) * 1e12},
    }
    json.dump(out, open(os.path.join(RES, "real_brownian.json"), "w"), indent=1)
    print(json.dumps(out, indent=1))

    # figure: (a) first frame with LivePTV tracks, (b) MSD of both trackings, (c) Stokes–Einstein sizes
    fig = plt.figure(figsize=(12.6, 4.2))
    ax0 = fig.add_axes([0.02, 0.1, 0.36, 0.78])
    img = skio.imread(os.path.join(ROOT, "data/trackpy-examples/sample_data/bulk_water/bulk_water_000.png"))[..., 0]
    ax0.imshow(img, cmap="gray")
    tr = p[(p.track_id > 0) & (p.frame_index < 120)]
    long = tr.groupby("track_id").size()
    for tid in long[long > 60].index[:220]:
        s = tr[tr.track_id == tid]
        ax0.plot(s.x_px, s.y_px, lw=0.9, color=BLUE, alpha=0.9)
    ax0.set_xticks([]); ax0.set_yticks([]); ax0.grid(False)
    ax0.set_title("LivePTV tracks (first 5 s, longer than 60 frames)", fontsize=10, color=INK)
    ax1 = fig.add_axes([0.45, 0.16, 0.25, 0.7])
    ax1.loglog(em.index, em.values, color=BLUE, lw=2, label="LivePTV tracks")
    ax1.loglog(em_tp.index, em_tp.values, color=AQUA, lw=2, ls="--", label="trackpy tracks")
    lag = np.array([em.index.min(), em.index.max()])
    ax1.loglog(lag, 4 * out["nominal"]["D_um2_s_20C"] * lag, color=GREY, lw=1, ls=":", label="1 µm sphere in water, 20 °C")
    ax1.set_xlabel("lag time (s)"); ax1.set_ylabel("mean squared displacement (µm²)")
    ax1.set_title("Ensemble MSD (drift removed)", fontsize=10, color=INK)
    ax1.legend(fontsize=8)
    ax2 = fig.add_axes([0.77, 0.16, 0.21, 0.7])
    labels = ["LivePTV\n(app, lag 1–2)", "LivePTV\n(MSD fit)", "trackpy\n(MSD fit)", "trackpy\n(lag 1–2)"]
    vals = [out["LivePTV"]["size_app_nm"], out["LivePTV"]["size_msd10_nm"], out["trackpy"]["size_msd10_nm"], out["trackpy"]["size_lag12_nm"]]
    cols = [BLUE, BLUE, AQUA, AQUA]
    y = np.arange(len(vals))[::-1]
    ax2.barh(y, vals, height=0.5, color=cols)
    for yi, v in zip(y, vals):
        ax2.text(v + 25, yi, f"{v:,.0f} nm", va="center", fontsize=9, color=INK, zorder=5,
                 bbox=dict(boxstyle="square,pad=0.15", fc=SURFACE, ec="none"))
    ax2.axvline(1000, color=INK2, lw=0.8)
    ax2.set_yticks(y); ax2.set_yticklabels(labels, fontsize=8.5)
    ax2.set_xlim(0, 1650); ax2.grid(axis="y", visible=False)
    ax2.set_xlabel("Stokes–Einstein diameter (nm, water at 20 °C)")
    ax2.set_title("Particle size (nominal 1 µm)", fontsize=10, color=INK)
    fig.savefig(os.path.join(FIG, "real_brownian.png"), dpi=130)
    print("wrote real_brownian.png", file=sys.stderr)


if __name__ == "__main__":
    main()
