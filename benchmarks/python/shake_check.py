"""Camera-motion correction actually applied per pair, from a session's frames.csv.

For a fixed camera the truth is zero: anything applied is error. Reports the largest displacement the correction
applies anywhere in the frame (corners and centre), per pair, in px.
usage: shake_check.py SESSION_DIR [SESSION_DIR ...]
"""
import sys, glob
import numpy as np
import pandas as pd


def corner_correction(r, w, h):
    cx, cy = r.shake_center_x_px, r.shake_center_y_px
    tx, ty = r.shake_tx_px, r.shake_ty_px
    th = r.shake_rotation_mrad / 1e3
    s = r.shake_scale_ppm / 1e6
    ex, ey = r.shake_stretch_x_ppm / 1e6, r.shake_stretch_y_ppm / 1e6
    gx, gy = r.shake_shear_x_ppm / 1e6, r.shake_shear_y_ppm / 1e6
    kx, ky = r.shake_keystone_x_per_mpx / 1e6, r.shake_keystone_y_per_mpx / 1e6
    best = 0.0
    for x, y in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (cx, cy)]:
        px, py = x - cx, y - cy
        q = kx * px + ky * py
        dx = tx + (s + ex) * px + (th + gx) * py - px * q
        dy = ty + (-th + gy) * px + (s + ey) * py - py * q
        best = max(best, float(np.hypot(dx, dy)))
    return best


for d in sys.argv[1:]:
    files = glob.glob(f"{d}/**/frames.csv", recursive=True) or glob.glob(f"{d}/frames.csv")
    for fpath in files:
        f = pd.read_csv(fpath)
        f = f.fillna({c: 0 for c in f.columns if c.startswith("shake_") and c != "shake_model"})
        w = int(f.roi_w.max()); h = int(f.roi_h.max())
        a = f[f.shake_applied == 1]
        c = np.array([corner_correction(r, w, h) for r in a.itertuples()])
        if len(c) == 0:
            print(f"{fpath}: no pairs corrected")
            continue
        models = a.shake_model.value_counts().to_dict()
        print(f"{fpath}\n  pairs corrected {len(c)}/{len(f)} | applied correction at the frame edge: "
              f"median {np.median(c):.3f} px, p95 {np.percentile(c, 95):.3f}, max {c.max():.2f} px | >0.5 px: {np.mean(c > 0.5) * 100:.1f} % "
              f"| >1 px: {np.mean(c > 1) * 100:.1f} % | background windows median {int(a.shake_background_windows.median())} | models {models}")
