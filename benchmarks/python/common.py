"""Synthetic PIV/PTV images with known displacement, and runners for LivePTV (via the Swift harness) and OpenPIV.

Conventions (same as LivePTV): pixel centres at integer coordinates, x right, y down; pixel i covers [i-0.5, i+0.5].
A particle pair is placed symmetrically about its midpoint p: frame A at p - d(p)/2, frame B at p + d(p)/2, so the
true displacement at any evaluation point x is d(x) for central-difference (symmetric) PIV schemes.
"""
from __future__ import annotations

import os
import struct
import subprocess
import tempfile
import time
from dataclasses import dataclass

import numpy as np
from scipy.special import erf

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HARNESS = os.environ.get("LIVEPTV_HARNESS", os.path.join(ROOT, "harness", ".build", "release", "liveptv-harness"))
SQ2 = np.sqrt(2.0)


# ----------------------------------------------------------------------------------------------- rendering
def render(xp, yp, W, H, d_tau, I0):
    """Gaussian particle images integrated over each pixel (erf), e^-2 diameter d_tau, peak intensity I0 for
    large particles. Returns float image (H, W)."""
    s = d_tau / 4.0
    r = int(np.ceil(3 * s + 1.5))
    k = np.arange(-r, r + 1)
    ix = np.floor(xp + 0.5).astype(int)
    iy = np.floor(yp + 0.5).astype(int)
    X = ix[:, None] + k[None, :]
    Y = iy[:, None] + k[None, :]
    ex = 0.5 * (erf((X + 0.5 - xp[:, None]) / (SQ2 * s)) - erf((X - 0.5 - xp[:, None]) / (SQ2 * s)))
    ey = 0.5 * (erf((Y + 0.5 - yp[:, None]) / (SQ2 * s)) - erf((Y - 0.5 - yp[:, None]) / (SQ2 * s)))
    vals = (I0 * 2 * np.pi * s * s)[:, None, None] * ey[:, :, None] * ex[:, None, :]
    img = np.zeros((H + 2 * r + 2, W + 2 * r + 2))
    XX = np.broadcast_to(X[:, None, :] + r + 1, vals.shape)
    YY = np.broadcast_to(Y[:, :, None] + r + 1, vals.shape)
    ok = (XX >= 0) & (XX < img.shape[1]) & (YY >= 0) & (YY < img.shape[0])
    np.add.at(img, (YY[ok], XX[ok]), vals[ok])
    return img[r + 1:r + 1 + H, r + 1:r + 1 + W]


def to_u8(img, noise, rng, background=10.0):
    out = img + background + rng.normal(0, noise, img.shape) if noise > 0 else img + background
    return np.clip(np.rint(out), 0, 255).astype(np.uint8)


@dataclass
class Scene:
    W: int = 512
    H: int = 512
    ppp: float = 0.04          # particles per pixel (in the illuminated volume)
    d_tau: float = 2.5         # e^-2 particle-image diameter, px
    noise: float = 2.0         # Gaussian sensor noise, grey levels (sigma)
    I_max: float = 180.0
    dz: float = 0.0            # out-of-plane displacement in units of the light-sheet thickness (e^-2 full width)


def make_pair(field, scene: Scene, rng):
    """field(x, y) -> (dx, dy) in px, vectorised. Returns (A, B) uint8 images."""
    W, H = scene.W, scene.H
    pad = 40
    n = int(scene.ppp * (W + 2 * pad) * (H + 2 * pad))
    px = rng.uniform(-pad, W + pad, n)
    py = rng.uniform(-pad, H + pad, n)
    z = rng.uniform(-0.75, 0.75, n)  # sheet coordinate, sheet e^-2 full width = 1
    dx, dy = field(px, py)
    za, zb = z - scene.dz / 2, z + scene.dz / 2
    Ia = scene.I_max * np.exp(-8 * za ** 2)
    Ib = scene.I_max * np.exp(-8 * zb ** 2)
    A = render(px - dx / 2, py - dy / 2, W, H, scene.d_tau, Ia)
    B = render(px + dx / 2, py + dy / 2, W, H, scene.d_tau, Ib)
    return to_u8(A, scene.noise, rng), to_u8(B, scene.noise, rng)


def write_frames(path, frames):
    H, W = frames[0].shape
    with open(path, "wb") as f:
        f.write(struct.pack("<iii", W, H, len(frames)))
        for fr in frames:
            f.write(np.ascontiguousarray(fr, dtype=np.uint8).tobytes())


# ----------------------------------------------------------------------------------------------- runners
def run_liveptv(pairs, windows=(64, 32), overlap=0.5, iters=2, interp="lanczos4", gpu=True, uncertainty=True,
                validate=True, deform=None, smooth=None):
    """pairs: list of (A, B). Returns list of dicts of arrays (x, y, dx, dy, status, corr, sigx, sigy) and times (ms)."""
    with tempfile.TemporaryDirectory() as td:
        fin = os.path.join(td, "f.u8")
        fout = os.path.join(td, "o.csv")
        ftime = os.path.join(td, "t.txt")
        write_frames(fin, [im for p in pairs for im in p])
        cmd = [HARNESS, "piv", fin, fout, "--windows", ",".join(map(str, windows)), "--overlap", str(overlap),
               "--iters", str(iters), "--interp", interp, "--gpu", "1" if gpu else "0",
               "--uncertainty", "1" if uncertainty else "0", "--timing", ftime]
        if not validate:
            cmd += ["--vthr", "1e9"]
        if deform is not None:
            cmd += ["--deform", "1" if deform else "0"]
        if smooth is not None:
            cmd += ["--smooth", "1" if smooth else "0"]
        subprocess.run(cmd, check=True)
        data = np.genfromtxt(fout, delimiter=",", names=True)
        lines = open(ftime).read().split("\n")
        times = [float(l) for l in lines if l and not l.startswith("device")]
        device = [l for l in lines if l.startswith("device")][0].split(",", 1)[1]
    out = []
    for k in range(len(pairs)):
        m = data["pair"] == k
        out.append({c: data[c][m] for c in ("x", "y", "dx", "dy", "status", "corr", "sigx", "sigy")})
    return out, times, device


def run_openpiv(A, B, windows=(64, 32), overlap=0.5, iters=2, deform="symmetric", median_threshold=2.0,
                validate=True):
    """OpenPIV windef (iterative image deformation), without the final y-flip, so coordinates and v are in image
    convention (y down). Returns dict(x, y, dx, dy, status) and elapsed ms."""
    from openpiv import windef, validation, filters
    s = windef.PIVSettings()
    ws = list(windows[:-1]) + [windows[-1]] * iters
    s.windowsizes = tuple(ws)
    s.overlap = tuple(int(round(w * overlap)) for w in ws)
    s.num_iterations = len(ws)
    s.deformation_method = deform
    s.interpolation_order = 3
    s.subpixel_method = "gaussian"
    s.median_threshold = median_threshold
    s.median_normalized = True
    s.min_max_u_disp = (-60, 60)
    s.min_max_v_disp = (-60, 60)
    s.show_plot = False
    if not validate:
        s.median_threshold = 1e9
        s.std_threshold = 1e9
        s.sig2noise_validate = False
        s.validation_first_pass = False
    t0 = time.perf_counter()
    a = A.astype(np.float64)
    b = B.astype(np.float64)
    x, y, u, v, s2n = windef.first_pass(a, b, s)
    u = np.ma.array(u, mask=np.zeros_like(u, dtype=bool))
    v = np.ma.array(v, mask=np.zeros_like(v, dtype=bool))
    flags = validation.typical_validation(u, v, s2n, s)
    u, v = filters.replace_outliers(u, v, flags)
    for i in range(1, s.num_iterations):
        x, y, u, v, grid_mask, flags = windef.multipass_img_deform(a, b, i, x, y, u, v, s)
    ms = (time.perf_counter() - t0) * 1e3
    u = np.ma.fix_invalid(u, fill_value=0.0).data
    v = np.ma.fix_invalid(v, fill_value=0.0).data
    st = np.where(np.asarray(flags).ravel(), 1, 0)  # 1 = replaced (OpenPIV flags outliers then replaces them)
    return {"x": x.ravel(), "y": y.ravel(), "dx": u.ravel(), "dy": v.ravel(), "status": st}, ms


def errors(res, field, W, H, margin=0):
    """Signed errors (ex, ey) at vectors inside [margin, W-1-margin] (status valid or replaced), plus mask used."""
    x, y = res["x"], res["y"]
    inside = (x >= margin) & (x <= W - 1 - margin) & (y >= margin) & (y <= H - 1 - margin)
    use = inside & ((res["status"] == 0) | (res["status"] == 1))
    tx, ty = field(x, y)
    return res["dx"] - tx, res["dy"] - ty, use, inside
