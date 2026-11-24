"""English figures for the LivePTV README (docs/images), from results/*.json and the showcase sessions.
Palette: LivePTV blue, OpenPIV orange, trackpy aqua (one hue per tool, line style per version)."""
from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
RES = os.path.join(ROOT, "results")
OUT = os.environ.get("README_IMAGES", os.path.join(ROOT, "..", "docs", "images"))
os.makedirs(OUT, exist_ok=True)
BLUE, ORANGE, AQUA = "#2a78d6", "#eb6834", "#1baf7a"
GREY, INK, INK2, GRID, SURFACE = "#8a8984", "#0b0b0b", "#52514e", "#e4e3df", "#ffffff"
plt.rcParams.update({
    "font.family": "Arial", "font.size": 10, "axes.edgecolor": GRID, "axes.labelcolor": INK2,
    "xtick.color": INK2, "ytick.color": INK2, "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8,
    "axes.spines.top": False, "axes.spines.right": False, "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
    "savefig.facecolor": SURFACE, "lines.linewidth": 2, "legend.frameon": False, "legend.handlelength": 3.2,
    "axes.titlesize": 11, "axes.titlecolor": INK, "axes.titleweight": "bold",
})


def load(name):
    with open(os.path.join(RES, name)) as f:
        return json.load(f)


def mk(ax, x, y, color, ls="-", label=None):
    ax.plot(x, y, ls, color=color, label=label, marker="o", markersize=6, markeredgecolor=SURFACE, markeredgewidth=1.5)


def save(fig, name):
    fig.savefig(os.path.join(OUT, name), dpi=130)
    plt.close(fig)
    print("wrote", name, file=sys.stderr)


def resolution():
    d = load("piv_e2.json")["validation off"]
    fig, ax = plt.subplots(figsize=(7.4, 4.2))
    lam = np.array([s["lambda"] for s in d["LivePTV 64→32 (Lanczos, default)"]])
    lf = np.geomspace(18, 240, 200)
    ax.plot(lf, np.sinc(32 / lf), color=GREY, lw=1, ls=":", label="top-hat average over a 32-px window")
    mk(ax, lam, [s["modulation"] for s in d["LivePTV 64→32 (shift, 0.7 method)"]], BLUE, ":", "LivePTV 0.7 (window shift)")
    mk(ax, lam, [s["modulation"] for s in d["LivePTV 64→32 (Lanczos, default)"]], BLUE, "-", "LivePTV 0.8 (image deformation)")
    mk(ax, lam, [s["modulation"] for s in d["OpenPIV 64→32 (deform)"]], ORANGE, "-", "OpenPIV 0.26 (image deformation)")
    ax.axhline(0, color=INK2, lw=0.8)
    ax.set_xscale("log")
    ax.set_xticks([20, 30, 40, 60, 80, 120, 160, 224]); ax.set_xticklabels(["20", "30", "40", "60", "80", "120", "160", "224"])
    ax.xaxis.set_minor_formatter(matplotlib.ticker.NullFormatter())
    ax.set_xlabel("wavelength of a sinusoidal displacement field λ (px)")
    ax.set_ylabel("amplitude recovered (1 = exact)")
    ax.set_title("Spatial resolution, final window 32 px")
    ax.legend(loc="lower right", fontsize=8.5)
    fig.tight_layout()
    save(fig, "bench_resolution.png")


def vortex_maps():
    sys.path.insert(0, HERE)
    from common import Scene, make_pair, run_liveptv, run_openpiv, errors
    from piv_experiments import lamb_oseen
    rng = np.random.default_rng(31)
    W = H = 512
    f, _ = lamb_oseen(255.5, 255.5, 30, 4.0)
    A, B = make_pair(f, Scene(W=W, H=H, d_tau=2.5, noise=2.0, ppp=0.04), rng)
    old, _, _ = run_liveptv([(A, B)], deform=False, iters=2)
    new, _, _ = run_liveptv([(A, B)])
    with contextlib.redirect_stdout(io.StringIO()):
        O, _ = run_openpiv(A, B, iters=3)
    fig, axes = plt.subplots(1, 3, figsize=(11.4, 4.0))
    for ax, (name, r) in zip(axes, (("LivePTV 0.7 (window shift)", old[0]), ("LivePTV 0.8 (image deformation)", new[0]),
                                    ("OpenPIV 0.26 (image deformation)", O))):
        ex, ey, use, _ = errors(r, f, W, H)
        e = np.hypot(ex, ey)
        xs, ys = np.unique(r["x"]), np.unique(r["y"])
        M = np.full((len(ys), len(xs)), np.nan)
        M[np.searchsorted(ys, r["y"]), np.searchsorted(xs, r["x"])] = e
        im = ax.imshow(M, extent=(xs[0] - 8, xs[-1] + 8, ys[-1] + 8, ys[0] - 8), cmap="Blues", vmin=0, vmax=0.3)
        ax.set_title(f"{name}\nRMS error {np.sqrt(np.mean(e[use] ** 2) / 2):.3f} px", fontsize=10)
        ax.set_xlabel("x (px)"); ax.grid(False)
    axes[0].set_ylabel("y (px)")
    cb = fig.colorbar(im, ax=axes, shrink=0.85, label="error magnitude (px)")
    cb.outline.set_visible(False)
    fig.suptitle("Lamb–Oseen vortex, core radius 30 px, 4 px peak displacement: where the error is",
                 fontweight="bold", color=INK, fontsize=11)
    fig.savefig(os.path.join(OUT, "bench_vortex.png"), dpi=130, bbox_inches="tight")
    plt.close(fig)


def robustness():
    d = load("piv_e5.json")
    fig, axes = plt.subplots(1, 3, figsize=(10.4, 3.5), sharey=True)
    lab = {"ppp": "seeding density (particles / px)", "noise": "sensor noise (grey levels, σ)",
           "dz": "out-of-plane motion (sheet thicknesses)"}
    for ax, key in zip(axes, ("ppp", "noise", "dz")):
        L = d[key]["LivePTV 64→32 (Lanczos, default)"]; S = d[key]["LivePTV 64→32 (shift, 0.7 method)"]
        O = d[key]["OpenPIV 64→32 (deform)"]
        xs = [s[key] for s in L]
        mk(ax, xs, [s["rms_all"] for s in S], BLUE, ":", "LivePTV 0.7")
        mk(ax, xs, [s["rms_all"] for s in L], BLUE, "-", "LivePTV 0.8")
        mk(ax, xs, [s["rms_all"] for s in O], ORANGE, "-", "OpenPIV 0.26")
        ax.set_xlabel(lab[key])
        if key == "ppp":
            ax.set_xscale("log")
            ax.set_xticks([0.005, 0.01, 0.02, 0.04, 0.08]); ax.set_xticklabels(["0.005", "0.01", "0.02", "0.04", "0.08"])
            ax.xaxis.set_minor_formatter(matplotlib.ticker.NullFormatter())
    axes[0].set_ylabel("RMS error (px, per component)")
    axes[0].legend(fontsize=8)
    fig.suptitle("Difficult images (vortex flow, final window 32 px)", fontweight="bold", color=INK, fontsize=11)
    fig.tight_layout()
    save(fig, "bench_robustness.png")


def speed():
    new = load("piv_e6.json")
    rows = [("LivePTV 0.8, GPU", "LivePTV (GPU 32-px passes)", new, BLUE),
            ("LivePTV 0.8, CPU only", "LivePTV (CPU only)", new, BLUE),
            ("OpenPIV 0.26 (Python)", "OpenPIV windef (Python, 1 process)", new, ORANGE)]
    fig, axes = plt.subplots(1, 2, figsize=(9.6, 2.7), sharey=True)
    for ax, res in zip(axes, ("1280x720", "1920x1080")):
        v = [src[res][key]["ms_median"] for _, key, src, _ in rows]
        y = np.arange(len(v))[::-1]
        ax.barh(y, v, height=0.5, color=[c for *_, c in rows])
        for yi, vi in zip(y, v):
            ax.text(vi * 1.12, yi, f"{vi:,.0f} ms", va="center", color=INK, fontsize=9, zorder=5,
                    bbox=dict(boxstyle="square,pad=0.15", fc=SURFACE, ec="none"))
        ax.set_xscale("log"); ax.set_xlim(5, 8000); ax.set_ylim(-0.75, len(v) - 0.5)
        ax.set_xticks([10, 100, 1000]); ax.set_xticklabels(["10", "100", "1000"])
        ax.xaxis.set_minor_formatter(matplotlib.ticker.NullFormatter())
        ax.axvline(1000 / 30, color=INK2, lw=0.8)
        ax.text(1000 / 30 * 1.08, -0.62, "30 fps", color=INK2, fontsize=8)
        ax.set_yticks(y); ax.set_yticklabels([r[0] for r in rows])
        ax.set_title(res.replace("x", " × ")); ax.set_xlabel("time per image pair (ms, log)")
        ax.grid(axis="y", visible=False)
    fig.suptitle("PIV speed on an Apple M4 (64 → 32 px, 50 % overlap, three final iterations)", fontweight="bold", color=INK, fontsize=11)
    fig.tight_layout()
    save(fig, "bench_speed.png")


def real_piv():
    sys.path.insert(0, HERE)
    from common import run_liveptv
    from real_piv_compare import CASES, DATA, load as load_img
    r = load("real_piv.json")
    cases = [c for c in CASES if c[0] != "test5"]          # test5: nearly still fluid, vectors are noise-sized
    ratios = []
    for name, fa, fb, title in cases:
        im = load_img(os.path.join(DATA, name, fa))
        ratios.append(im.shape[1] / im.shape[0])
    fig, axes = plt.subplots(1, len(cases), figsize=(13, 5.6), gridspec_kw={"width_ratios": ratios})
    for ax, (name, fa, fb, title) in zip(axes, cases):
        A, B = load_img(os.path.join(DATA, name, fa)), load_img(os.path.join(DATA, name, fb))
        L = run_liveptv([(A, B)], iters=3)[0][0]
        img = np.clip(A / np.percentile(A, 99.5), 0, 1)
        ax.imshow(img, cmap="gray", vmin=0, vmax=1.4)
        xs, ys = np.unique(L["x"]), np.unique(L["y"])
        step = max(1, int(round(len(xs) / 22)))
        keep = np.isin(L["x"], xs[::step]) & np.isin(L["y"], ys[::step]) & (L["status"] <= 1)
        mag = np.hypot(L["dx"], L["dy"])
        sc = 0.9 * step * (xs[1] - xs[0]) / max(1e-6, np.percentile(mag[L["status"] <= 1], 95))
        ax.quiver(L["x"][keep], L["y"][keep], L["dx"][keep], L["dy"][keep], color=BLUE, angles="xy", scale_units="xy",
                  scale=1 / sc, width=0.004, headwidth=3.5)
        q = r[name]
        ax.set_title(f"{title.split(': ')[1]}\nvs OpenPIV: median |Δ| {q['median_diff_px']:.3f} px\n"
                     f"LivePTV {q['ms_liveptv']:.0f} ms · OpenPIV {q['ms_openpiv'] / 1000:.1f} s", fontsize=9.5)
        ax.set_xticks([]); ax.set_yticks([]); ax.grid(False)
    fig.suptitle("Real PIV recordings shipped with OpenPIV, analysed by LivePTV (vectors) and compared with OpenPIV",
                 fontweight="bold", color=INK, fontsize=11, y=0.99)
    fig.tight_layout(rect=(0, 0, 1, 0.95))
    fig.savefig(os.path.join(OUT, "real_piv.jpg"), dpi=120, pil_kwargs={"quality": 88})
    plt.close(fig)


def ptv():
    """(a) tracking: links right (geometric mean of precision and recall) against max displacement / mean spacing,
    5000 particles; (b) detection F1 per P1 condition with default settings."""
    new, old = load("ptv_p2.json"), load("v07/ptv_p2.json")
    d1n, d1o = load("ptv_p1.json"), load("v07/ptv_p1.json")
    fig, axes = plt.subplots(1, 2, figsize=(11.5, 3.9), gridspec_kw={"width_ratios": [1, 1.25]})
    ax = axes[0]

    def gm(r, key):
        v = r.get(key, {})
        return np.sqrt(v["precision"] * v["recall"]) if "precision" in v else np.nan
    for rows, key, col, ls, lab in ((old, "LivePTV default (12 px, 4 px)", BLUE, ":", "LivePTV 0.7"),
                                    (new, "LivePTV default (12 px, 4 px)", BLUE, "-", "LivePTV 0.8"),
                                    (new, "trackpy + velocity predictor", AQUA, "-", "trackpy 0.7 + velocity predictor")):
        rr = [r for r in rows if r["N"] == 5000]
        mk(ax, [r["p_ratio"] for r in rr], [gm(r, key) for r in rr], col, ls, lab)
    ax.set_xlabel("largest displacement per frame / mean particle spacing")
    ax.set_ylabel("links right (√(precision × recall))")
    ax.set_title("Tracking, 5000 particles in a Taylor–Green flow")
    ax.legend(fontsize=8, loc="lower left")
    ax = axes[1]
    labels = [f"{r['d_tau']:g} px, σ {r['noise']:g}, {r['ppp']:g}" for r in d1n]
    x = np.arange(len(labels))
    wdt = 0.27
    for off, rows, key, col, lab in ((-wdt, d1o, "LivePTV default", "#9ec5f4", "LivePTV 0.7, default"),
                                     (0, d1n, "LivePTV default", BLUE, "LivePTV 0.8, default"),
                                     (wdt, d1n, "trackpy tuned", AQUA, "trackpy 0.7, best minmass")):
        ax.bar(x + off, [r[key]["f1"] for r in rows], width=wdt * 0.92, color=col, label=lab)
    ax.set_xticks(x); ax.set_xticklabels(labels, rotation=55, ha="right", fontsize=7.5)
    ax.set_ylim(0.4, 1.13); ax.set_yticks([0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]); ax.set_ylabel("detection F1"); ax.grid(axis="x", visible=False)
    ax.set_title("Detection (particle size, noise, particles/px)")
    ax.legend(fontsize=8, loc="upper left", ncol=3)
    fig.tight_layout()
    save(fig, "bench_ptv.png")


GALLERY = [  # (scene, file in the session folder, README name)
    ("bottle", "figure_summary.png", "app_bottle_summary.png"),
    ("bottle", "figure_quality.png", "app_bottle_quality.png"),
    ("bottle", "overlay_on_image.png", "app_bottle_overlay.png"),
    ("vortex_pair", "figure_summary.png", "app_vortex_pair.png"),
    ("vortex_array", "figure_summary.png", "app_vortex_array.png"),
    ("channel", "figure_profiles.png", "app_channel_profiles.png"),
    ("faint_ensemble", "figure_ensemble.png", "app_ensemble.png"),
]


def gallery():
    from PIL import Image
    for scene, src, dst in GALLERY:
        im = Image.open(os.path.join(ROOT, "showcase", scene, src)).convert("RGB")
        if im.width > 1100:                              # never upscale
            im = im.resize((1100, round(im.height * 1100 / im.width)), Image.LANCZOS)
        out = os.path.join(OUT, dst.replace(".png", ".jpg"))
        im.save(out, quality=88, optimize=True)
        print("wrote", os.path.basename(out), os.path.getsize(out) // 1024, "KB", file=sys.stderr)


if __name__ == "__main__":
    which = sys.argv[1:] or ["resolution", "vortex", "robust", "speed", "real", "gallery"]
    for w in which:
        {"resolution": resolution, "vortex": vortex_maps, "robust": robustness, "speed": speed,
         "real": real_piv, "gallery": gallery, "ptv": ptv}[w]()
