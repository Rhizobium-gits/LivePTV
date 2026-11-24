"""A live recording from a real camera (Insta360 Ace Pro 2 in USB webcam mode, 1920 × 1080 at 30 fps, every frame saved
as ProRes by `ace-probe usb --save-video`): LivePTV, OpenPIV windef and OpenCV optical flow (DIS, Farnebäck) on the same
frames. Three experiments:

1. Known motion on real frames. Two consecutive frames from a still moment carry the camera's real texture, sensor
   noise and compression; the second is warped by a known field (a vortex of 4 px peak on a 1.3 px drift), so every
   window has an exact answer.
2. False motion. The camera stood on a desk (LivePTV's camera-motion fit: median shift ≤ 0.03 px per pair), so in the
   parts of the picture that did not change around a pair, every measured displacement is an error. Textured windows
   and textureless ones (bare ceiling, smooth walls) are reported separately.
OpenPIV runs with its high-pass pre-filter (σ = 7 px) and normalised correlation, the counterpart of LivePTV's own
pre-processing; on these natural images its defaults (no pre-filter) are biased towards zero (also reported).

3. Agreement on real motion. Pairs with moderate motion (a person moving at a desk), within the range PIV is built for;
   no ground truth, so the tools are compared with each other.

usage: real_camera_compare.py STREAM.mov [--pairs N] [--blur-rect x,y,w,h] [--tag NAME]
writes results/real_camera[_TAG].json and results/figs/real_camera[_TAG]_*.png
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import time

import cv2
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.interpolate import RegularGridInterpolator

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import run_liveptv, run_openpiv  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "..", "results")
FIG = os.path.join(RES, "figs")
FACEBOXES = os.path.join(HERE, "..", "tools", "faceboxes")
BLUE, ORANGE, GREEN, PURPLE = "#2a78d6", "#eb6834", "#2f9e44", "#8a4fd8"
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
plt.rcParams.update({"font.family": "Arial", "font.size": 10, "figure.facecolor": SURFACE,
                     "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE, "axes.titlecolor": INK})
TOOLS = ["LivePTV", "OpenPIV", "OpenCV DIS", "OpenCV Farnebäck"]
COLORS = dict(zip(TOOLS, (BLUE, ORANGE, GREEN, PURPLE)))
LOW = 4            # low-resolution factor for the motion / still masks
WIN = 32           # final window (px) of both PIV tools; optical flow is averaged over the same window
MARGIN = 32        # windows this close to the picture edge are left out of the statistics


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets", "-show_entries",
                        "stream=width,height,nb_read_packets", "-of", "csv=p=0", path], capture_output=True, text=True, check=True)
    w, h, n = (int(v) for v in r.stdout.strip().split(","))
    return w, h, n


def read_frames(path, w, h, scale=1, select=None):
    """Grey frames (uint8) from ffmpeg; `select`: frame numbers to keep (returned in increasing order)."""
    vf = []
    if select is not None:
        vf.append("select='" + "+".join(f"eq(n\\,{k})" for k in select) + "'")
    if scale > 1:
        vf.append(f"scale={w // scale}:{h // scale}:flags=area")
    cmd = ["ffmpeg", "-v", "error", "-i", path]
    if vf:
        cmd += ["-vf", ",".join(vf)]
    cmd += ["-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "gray", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(-1, h // scale, w // scale)


def window_mean(img, x, y):
    """Mean of `img` over the WIN × WIN window centred at each (x, y)."""
    m = cv2.boxFilter(img.astype(np.float32), -1, (WIN, WIN), normalize=True, borderType=cv2.BORDER_REFLECT)
    xi = np.clip(np.round(x).astype(int), 0, img.shape[1] - 1)
    yi = np.clip(np.round(y).astype(int), 0, img.shape[0] - 1)
    return m[yi, xi]


def on_grid(r, x, y):
    """OpenPIV's regular grid → the given positions (bilinear)."""
    ox, oy = np.unique(r["x"]), np.unique(r["y"])
    U = np.full((len(oy), len(ox)), np.nan); V = U.copy()
    U[np.searchsorted(oy, r["y"]), np.searchsorted(ox, r["x"])] = r["dx"]
    V[np.searchsorted(oy, r["y"]), np.searchsorted(ox, r["x"])] = r["dy"]
    pts = np.column_stack([y, x])
    iu = RegularGridInterpolator((oy, ox), U, bounds_error=False, fill_value=np.nan)
    iv = RegularGridInterpolator((oy, ox), V, bounds_error=False, fill_value=np.nan)
    return iu(pts), iv(pts)


def run_all(pairs, default_openpiv=False):
    """Every tool on every pair → per tool: list of (u, v) at LivePTV's vector positions, positions, times (ms)."""
    lres, ltimes, device = run_liveptv(pairs, iters=3)
    out = {t: [] for t in TOOLS}
    times = {t: [] for t in TOOLS}
    times["LivePTV"] = ltimes[1:] if len(ltimes) > 1 else ltimes       # the first pair includes GPU set-up
    dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
    pos = []
    for k, (A, B) in enumerate(pairs):
        L = lres[k]
        x, y = L["x"], L["y"]
        pos.append((x, y))
        ok = L["status"] <= 1                                          # valid or replaced
        out["LivePTV"].append((np.where(ok, L["dx"], np.nan), np.where(ok, L["dy"], np.nan)))
        with contextlib.redirect_stdout(io.StringIO()):
            o, ms = run_openpiv(A, B, iters=3, highpass=7, normalized=True)
        out["OpenPIV"].append(on_grid(o, x, y)); times["OpenPIV"].append(ms)
        if default_openpiv:
            with contextlib.redirect_stdout(io.StringIO()):
                o, ms = run_openpiv(A, B, iters=3)
            out.setdefault("OpenPIV defaults", []).append(on_grid(o, x, y)); times.setdefault("OpenPIV defaults", []).append(ms)
        t0 = time.perf_counter(); f = dis.calc(A, B, None); times["OpenCV DIS"].append((time.perf_counter() - t0) * 1e3)
        out["OpenCV DIS"].append((window_mean(f[..., 0], x, y), window_mean(f[..., 1], x, y)))
        t0 = time.perf_counter(); f = cv2.calcOpticalFlowFarneback(A, B, None, 0.5, 5, 21, 3, 7, 1.5, 0)
        times["OpenCV Farnebäck"].append((time.perf_counter() - t0) * 1e3)
        out["OpenCV Farnebäck"].append((window_mean(f[..., 0], x, y), window_mean(f[..., 1], x, y)))
    return out, pos, {t: float(np.median(v)) for t, v in times.items()}, device


def summ(v):
    v = np.asarray(v, dtype=float)
    v = v[np.isfinite(v)]
    if v.size == 0:
        return None
    return {"n": int(v.size), "median_px": float(np.median(v)), "rms_px": float(np.sqrt(np.mean(v ** 2))),
            "p95_px": float(np.percentile(v, 95)), "share_over_0p5px": float(np.mean(v > 0.5)),
            "share_over_2px": float(np.mean(v > 2))}


def known_field(x, y, W, H):
    """The applied displacement (px): 1.3 px drift + a Lamb–Oseen vortex (core 220 px, 4 px peak) at the centre."""
    cx, cy, rc, peak = W / 2, H / 2, 220.0, 4.0
    dx, dy = x - cx, y - cy
    r = np.hypot(dx, dy) + 1e-9
    vt = peak * 1.398 * (rc / r) * (1 - np.exp(-1.2564 * (r / rc) ** 2))   # 1.398: peak of the profile = `peak`
    return 1.3 - vt * dy / r, 0.4 + vt * dx / r


def warp(img, W, H):
    """B(x) = A(x − d(x)) by fixed-point inversion of the forward field, cubic interpolation."""
    gx, gy = np.meshgrid(np.arange(W, dtype=np.float32), np.arange(H, dtype=np.float32))
    sx, sy = gx.copy(), gy.copy()
    for _ in range(6):                      # solve s + d(s) = x for the source point s
        u, v = known_field(sx, sy, W, H)
        sx, sy = (gx - u).astype(np.float32), (gy - v).astype(np.float32)
    return cv2.remap(img, sx, sy, cv2.INTER_CUBIC, borderMode=cv2.BORDER_REFLECT)


def face_boxes(img):
    if not os.path.exists(FACEBOXES):
        return []
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "f.png")
        cv2.imwrite(p, img)
        line = subprocess.run([FACEBOXES, p], capture_output=True, text=True).stdout.strip()
    boxes = []
    for b in line.split(",", 1)[1].split(";") if "," in line else []:
        if b:
            x, y, w, h = (float(v) for v in b.split(","))
            boxes.append((int(x - 0.45 * w), int(y - 0.6 * h), int(1.9 * w), int(2.2 * h)))
    return boxes


def privacy_blur(gray, rects):
    out = gray.copy()
    boxes = list(rects) + face_boxes(gray)
    blurred = cv2.GaussianBlur(gray, (0, 0), 25)
    for (x, y, w, h) in boxes:
        x0, y0, x1, y1 = max(0, x), max(0, y), min(gray.shape[1], x + w), min(gray.shape[0], y + h)
        out[y0:y1, x0:x1] = blurred[y0:y1, x0:x1]
    return out, boxes


def quiver_panel(ax, img, x, y, u, v, color, scale, every=3):
    xs, ys = np.unique(x), np.unique(y)
    keep = np.isin(x, xs[::every]) & np.isin(y, ys[::every]) & np.isfinite(u) & np.isfinite(v)
    ax.imshow(img, cmap="gray", vmin=0, vmax=255)
    ax.quiver(x[keep], y[keep], u[keep], v[keep], color=color, angles="xy", scale_units="xy", scale=1 / scale,
              width=0.0028, headwidth=3.5)
    ax.set_xticks([]); ax.set_yticks([])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stream")
    ap.add_argument("--pairs", type=int, default=12)
    ap.add_argument("--blur-rect", action="append", default=[])
    ap.add_argument("--tag", default="")
    a = ap.parse_args()
    tag = f"_{a.tag}" if a.tag else ""
    rects = [tuple(int(v) for v in r.split(",")) for r in a.blur_rect]
    W, H, N = probe(a.stream)
    os.makedirs(FIG, exist_ok=True)

    # --- motion per frame step (low resolution, global brightness removed)
    low = read_frames(a.stream, W, H, scale=LOW).astype(np.float32)
    low = np.stack([cv2.GaussianBlur(f, (0, 0), 1.0) for f in low])
    low -= np.median(low, axis=(1, 2), keepdims=True)
    energy = np.abs(np.diff(low, axis=0)).mean(axis=(1, 2))

    def spaced(order, n, gap):
        out = []
        for t in order:
            t = int(t)
            if 16 <= t < len(energy) - 16 and all(abs(t - p) >= gap for p in out):
                out.append(t)
            if len(out) == n:
                break
        return sorted(out)

    # --- 1. known motion on real frames: the stillest frame steps
    still_picks = spaced(np.argsort(energy), 4, 60)
    fr = read_frames(a.stream, W, H, select=sorted(set(still_picks + [p + 1 for p in still_picks])))
    idx = {k: i for i, k in enumerate(sorted(set(still_picks + [p + 1 for p in still_picks])))}
    known_pairs = [(fr[idx[p]], warp(fr[idx[p + 1]], W, H)) for p in still_picks]
    kres, kpos, ktimes, device = run_all(known_pairs, default_openpiv=True)
    known = {}
    for t in TOOLS + ["OpenPIV defaults"]:
        tex, flat = [], []
        for k, (A, _) in enumerate(known_pairs):
            x, y = kpos[k]
            u, v = kres[t][k]
            tu, tv = known_field(x, y, W, H)
            e = np.hypot(u - tu, v - tv)
            inside = (x > MARGIN) & (x < W - MARGIN) & (y > MARGIN) & (y < H - MARGIN)
            m = window_mean(A, x, y)
            sd = np.sqrt(np.maximum(0, window_mean(A.astype(np.float32) ** 2, x, y) - m ** 2))
            tex += e[inside & (sd >= 8)].tolist(); flat += e[inside & (sd < 8)].tolist()
        known[t] = {"textured": summ(tex), "textureless": summ(flat)}
    print("KNOWN MOTION (error vs applied field):")
    for t in TOOLS + ["OpenPIV defaults"]:
        print(f"  {t:18s} textured {known[t]['textured']}\n  {'':18s} textureless {known[t]['textureless']}")

    # --- 2 + 3. real motion: moderately moving frame steps (70th–90th percentile of motion)
    lo, hi = np.percentile(energy, 70), np.percentile(energy, 90)
    cand = [t for t in np.argsort(-energy) if lo <= energy[t] <= hi]
    picks = spaced(cand, a.pairs, 20)
    sel = sorted(set(picks + [p + 1 for p in picks]))
    fr = read_frames(a.stream, W, H, select=sel)
    idx = {k: i for i, k in enumerate(sel)}
    pairs = [(fr[idx[p]], fr[idx[p + 1]]) for p in picks]
    res, pos, times, _ = run_all(pairs)
    false_motion = {t: {"textured": [], "textureless": []} for t in TOOLS}
    agree = {f"{p} vs {q}": [] for i, p in enumerate(TOOLS) for q in TOOLS[i + 1:]}
    per_pair = []
    for k, (A, B) in enumerate(pairs):
        x, y = pos[k]
        p = picks[k]
        # still around this pair: no change > 5 grey levels in the second before and after (low resolution)
        span = low[max(0, p - 15):p + 17]
        still_low = (span.max(axis=0) - span.min(axis=0)) < 5.0
        still = cv2.resize(still_low.astype(np.uint8), (W, H), interpolation=cv2.INTER_NEAREST).astype(np.float32)
        st = window_mean(still, x, y) > 0.999
        moving = window_mean(np.abs(B.astype(np.float32) - A.astype(np.float32)), x, y) > 6.0
        m = window_mean(A, x, y)
        sd = np.sqrt(np.maximum(0, window_mean(A.astype(np.float32) ** 2, x, y) - m ** 2))
        inside = (x > MARGIN) & (x < W - MARGIN) & (y > MARGIN) & (y < H - MARGIN)
        textured = sd >= 8
        # 🐱 agreement only where the textured picture moved, and within PIV's design range (≤ 8 px per pair in LivePTV)
        lu, lv = res["LivePTV"][k]
        inrange = np.hypot(lu, lv) <= 8
        for t in TOOLS:
            u, v = res[t][k]
            mag = np.hypot(u, v)
            false_motion[t]["textured"] += mag[inside & st & textured].tolist()
            false_motion[t]["textureless"] += mag[inside & st & ~textured].tolist()
        for i, p1 in enumerate(TOOLS):
            for p2 in TOOLS[i + 1:]:
                d = np.hypot(res[p1][k][0] - res[p2][k][0], res[p1][k][1] - res[p2][k][1])
                agree[f"{p1} vs {p2}"] += d[inside & moving & textured & inrange].tolist()
        per_pair.append({"frame": p, "still_windows": int((inside & st).sum()),
                         "moving_textured_windows": int((inside & moving & textured & inrange).sum())})

    out = {"stream": os.path.basename(a.stream), "size": [W, H], "frames": N, "device": device,
           "settings": "PIV: 64 → 32 px, 50 % overlap, 3 final iterations (LivePTV; OpenPIV windef with its high-pass "
                       "pre-filter σ = 7 px and normalised correlation); optical flow: OpenCV DIS (preset medium) and Farnebäck, averaged over the same 32 × 32 px windows",
           "ms_per_pair": times,
           "known_motion": {"pairs": still_picks, "field": "1.3 px drift + Lamb–Oseen vortex, core 220 px, 4 px peak",
                            "error": known},
           "false_motion": {"pairs": picks, "magnitude": {t: {k2: summ(v) for k2, v in false_motion[t].items()} for t in TOOLS}},
           "agreement_moving": {"pairs": picks, "difference": {k2: summ(v) for k2, v in agree.items()}},
           "per_pair": per_pair}
    json.dump(out, open(os.path.join(RES, f"real_camera{tag}.json"), "w"), indent=1, ensure_ascii=False)
    print("ms per pair:", {t: round(v, 1) for t, v in times.items()})
    print("FALSE MOTION (still background, truth 0):")
    for t in TOOLS:
        fm = out["false_motion"]["magnitude"][t]
        print(f"  {t:18s} textured {fm['textured']}\n  {'':18s} textureless {fm['textureless']}")
    print("AGREEMENT on moving textured windows:")
    for k2, v in out["agreement_moving"]["difference"].items():
        print(f"  {k2:34s} {v}")

    # --- figure 1: the known-motion error maps (one pair), same colour scale
    A0 = known_pairs[0][0]
    shown, kboxes = privacy_blur(A0, rects)
    print("known figure privacy boxes", kboxes)
    x, y = kpos[0]
    xs, ys = np.unique(x), np.unique(y)
    fig, axes = plt.subplots(2, 2, figsize=(12.5, 7.6), constrained_layout=True)
    for ax, t in zip(axes.ravel(), TOOLS):
        u, v = kres[t][0]
        tu, tv = known_field(x, y, W, H)
        e = np.hypot(u - tu, v - tv).reshape(len(ys), len(xs))
        ax.imshow(shown, cmap="gray", vmin=0, vmax=255, extent=(0, W, H, 0))
        im = ax.imshow(np.ma.masked_invalid(e), cmap="magma", vmin=0, vmax=1.0, alpha=0.85,
                       extent=(xs[0] - 8, xs[-1] + 8, ys[-1] + 8, ys[0] - 8))
        kt = out["known_motion"]["error"][t]["textured"]
        ax.set_title(f"{t}: median error {kt['median_px']:.3f} px (textured windows)", fontsize=10.5)
        ax.set_xticks([]); ax.set_yticks([]); ax.set_xlim(0, W); ax.set_ylim(H, 0)
    fig.colorbar(im, ax=axes, shrink=0.6, label="|error| (px per pair)")
    fig.suptitle("Real camera frames with a known displacement (1.3 px drift + 4 px vortex): error of each tool",
                 fontsize=11.5, fontweight="bold", color=INK)
    fig.savefig(os.path.join(FIG, f"real_camera{tag}_known.png"), dpi=100)
    plt.close(fig)

    # --- figure 2: the real motion, four tools on the same pair, faces blurred
    k = int(np.argmax([p["moving_textured_windows"] for p in per_pair]))
    A = pairs[k][0]
    shown, boxes = privacy_blur(A, rects)
    x, y = pos[k]
    mags = np.concatenate([np.hypot(*res[t][k]) for t in TOOLS])
    sc = 45.0 / max(1e-6, np.nanpercentile(mags, 98))
    fig, axes = plt.subplots(2, 2, figsize=(12.5, 7.6), constrained_layout=True)
    for ax, t in zip(axes.ravel(), TOOLS):
        quiver_panel(ax, shown, x, y, res[t][k][0], res[t][k][1], COLORS[t], sc)
        ax.set_title(f"{t} · {times[t]:.0f} ms per 1080p pair", fontsize=10.5)
    fig.suptitle(f"Live recording, Insta360 Ace Pro 2 over USB ({W}×{H}, 30 fps): one frame pair in four tools "
                 f"(arrows ×{sc:.0f}, same scale)", fontsize=11.5, fontweight="bold", color=INK)
    fig.savefig(os.path.join(FIG, f"real_camera{tag}_tools.png"), dpi=100)
    plt.close(fig)
    print("figure pairs: known", still_picks[0], "real", picks[k], "privacy boxes", boxes)


if __name__ == "__main__":
    main()
