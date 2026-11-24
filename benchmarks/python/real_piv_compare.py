"""Real PIV images shipped with OpenPIV (openpiv/data): LivePTV (PTVCore via the Swift harness, default settings:
64 → 32 px, image deformation, 3 final iterations) and OpenPIV windef (64 → 32 px, symmetric deformation, 3 final
iterations) on the same pairs. No ground truth: the tools are compared with each other (OpenPIV interpolated to
LivePTV's vector positions), plus valid shares and run time. Writes results/real_piv.json and figures."""
from __future__ import annotations

import contextlib
import io
import json
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.interpolate import RegularGridInterpolator
from skimage import io as skio

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import run_liveptv, run_openpiv  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "..", "results")
FIG = os.path.join(RES, "figs")
DATA = os.path.join(os.path.dirname(__import__("openpiv").__file__), "data")
BLUE, ORANGE, INK, INK2, GRID, SURFACE = "#2a78d6", "#eb6834", "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
plt.rcParams.update({"font.family": "Arial", "font.size": 10, "figure.facecolor": SURFACE,
                     "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE, "axes.titlecolor": INK})

CASES = [
    ("test1", "exp1_001_a.bmp", "exp1_001_b.bmp", "OpenPIV test1: dense seeding (511×369)"),
    ("test2", "2image_00.tif", "2image_01.tif", "OpenPIV test2: plate edge with glare (1008×1012)"),
    ("test4", "Camera1-0101.tif", "Camera1-0102.tif", "OpenPIV test4: stirred tank (1720×2304)"),
    ("test5", "Pattern_1_A.tif", "Pattern_1_B.tif", "OpenPIV test5: tank with a glint (1024×1024)"),
]


def load(path):
    im = skio.imread(path)
    if im.ndim == 3:
        im = im[..., 0]
    return im.astype(np.uint8)


def main():
    out = {}
    for name, fa, fb, title in CASES:
        A, B = load(os.path.join(DATA, name, fa)), load(os.path.join(DATA, name, fb))
        # LivePTV: same pair 4 times, timing of the warm runs
        res, times, dev = run_liveptv([(A, B)] * 4, iters=3)
        L = res[0]
        with contextlib.redirect_stdout(io.StringIO()):
            O, ms = run_openpiv(A, B, iters=3)
        # OpenPIV on its regular grid → interpolate to LivePTV positions
        ox, oy = np.unique(O["x"]), np.unique(O["y"])
        OU = np.full((len(oy), len(ox)), np.nan); OV = OU.copy()
        OU[np.searchsorted(oy, O["y"]), np.searchsorted(ox, O["x"])] = O["dx"]
        OV[np.searchsorted(oy, O["y"]), np.searchsorted(ox, O["x"])] = O["dy"]
        iu = RegularGridInterpolator((oy, ox), OU, bounds_error=False, fill_value=np.nan)
        iv = RegularGridInterpolator((oy, ox), OV, bounds_error=False, fill_value=np.nan)
        pts = np.column_stack([L["y"], L["x"]])
        du, dv = L["dx"] - iu(pts), L["dy"] - iv(pts)
        m = np.isfinite(du) & np.isfinite(dv) & (L["status"] <= 1)
        d = np.hypot(du[m], dv[m])
        speed = np.hypot(L["dx"][m], L["dy"][m])
        out[name] = {"title": title, "size": list(A.shape), "vectors_liveptv": int(len(L["x"])),
                     "valid_liveptv": float(np.mean(L["status"] == 0)), "replaced_openpiv": float(np.mean(O["status"] == 1)),
                     "median_diff_px": float(np.median(d)), "p90_diff_px": float(np.percentile(d, 90)),
                     "share_within_0p2px": float(np.mean(d < 0.2)), "median_speed_px": float(np.median(speed)),
                     "ms_liveptv": float(np.median(times[1:])), "device": dev, "ms_openpiv": float(ms)}
        print(name, {k: (round(v, 3) if isinstance(v, float) else v) for k, v in out[name].items()}, file=sys.stderr)

        # figure: image with both vector fields, side by side
        fig, axes = plt.subplots(1, 2, figsize=(10.5, 5.0 * A.shape[0] / A.shape[1] + 0.9))
        img = np.clip(A / np.percentile(A, 99.5), 0, 1)
        step = max(1, int(round(len(np.unique(L["x"])) / 28)))
        for ax, (lab, r, col) in zip(axes, (("LivePTV", L, BLUE), ("OpenPIV (image deformation)", O, ORANGE))):
            ax.imshow(img, cmap="gray", vmin=0, vmax=1.3)
            xs = np.unique(r["x"])
            keep = np.isin(r["x"], xs[::step]) & np.isin(r["y"], np.unique(r["y"])[::step])
            sc = 3.0 * step * 16 / max(1e-6, np.percentile(np.hypot(r["dx"], r["dy"]), 95))
            ax.quiver(r["x"][keep], r["y"][keep], r["dx"][keep], r["dy"][keep], color=col,
                      angles="xy", scale_units="xy", scale=1 / sc, width=0.0035, headwidth=3.5)
            ax.set_title(lab, fontsize=10)
            ax.set_xticks([]); ax.set_yticks([])
        fig.suptitle(f"{title}\ndifference between the tools: median {out[name]['median_diff_px']:.3f} px, within 0.2 px: {100 * out[name]['share_within_0p2px']:.0f} %",
                     fontsize=10.5, fontweight="bold", color=INK)
        fig.tight_layout()
        fig.savefig(os.path.join(FIG, f"real_{name}.png"), dpi=110)
        plt.close(fig)
    json.dump(out, open(os.path.join(RES, "real_piv.json"), "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    os.makedirs(FIG, exist_ok=True)
    main()
