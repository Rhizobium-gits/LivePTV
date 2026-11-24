"""PTV comparison: LivePTV ParticleDetector / ParticleTracker vs trackpy (locate / link with velocity predictor).

  P1 detection & localisation on single frames (both detectors' thresholds swept; best F1 reported, plus defaults)
  P2 tracking only (true positions + 0.05 px noise) in a Taylor-Green flow: link precision / recall vs displacement
  P3 end to end from images: velocity error of the produced samples
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import warnings

import numpy as np
import pandas as pd
from scipy.spatial import cKDTree

from common import HARNESS, render, to_u8, write_frames

warnings.filterwarnings("ignore")
RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results")
W = H = 512


def peak_of(I0, d_tau):
    from scipy.special import erf
    s = d_tau / 4
    e = erf(0.5 / (np.sqrt(2) * s))
    return I0 * 2 * np.pi * s * s * e * e


def match(tx, ty, dx, dy, tol=1.0):
    """Unique nearest matching within tol. Returns (tp_idx_truth, tp_idx_det)."""
    if len(dx) == 0:
        return np.array([], int), np.array([], int)
    tree = cKDTree(np.column_stack([tx, ty]))
    d, i = tree.query(np.column_stack([dx, dy]), distance_upper_bound=tol)
    order = np.argsort(d)
    used_t, ti, di = set(), [], []
    for k in order:
        if not np.isfinite(d[k]):
            break
        if i[k] in used_t:
            continue
        used_t.add(i[k]); ti.append(i[k]); di.append(k)
    return np.array(ti, int), np.array(di, int)


def pli(frac):
    return float(max(0.0, 2 * np.mean(np.abs(frac) < 0.25) - 1))


def liveptv_detect(img, k=None, minthr=None, bg=1):
    """LivePTV's detector; k / minthr None = the detector's own defaults."""
    with tempfile.TemporaryDirectory() as td:
        fi, fo = os.path.join(td, "f.u8"), os.path.join(td, "d.csv")
        write_frames(fi, [img])
        cmd = [HARNESS, "detect", fi, fo, "--bg", str(bg)]
        if k is not None:
            cmd += ["--k", str(k)]
        if minthr is not None:
            cmd += ["--minthr", str(minthr)]
        subprocess.run(cmd, check=True)
        d = pd.read_csv(fo)
    return d["x"].to_numpy(), d["y"].to_numpy()


def trackpy_detect(img, diameter, minmass):
    import trackpy as tp
    with contextlib.redirect_stdout(io.StringIO()):
        f = tp.locate(img, diameter, minmass=minmass, separation=3, preprocess=True)
    return f["x"].to_numpy(), f["y"].to_numpy()


def score(tx, ty, vis, dx, dy):
    ti, di = match(tx, ty, dx, dy)
    tp_vis = vis[ti].sum()
    recall = tp_vis / max(1, vis.sum())
    # detections matched to invisible particles are not counted as false (they are real), only unmatched ones
    precision = len(di) / max(1, len(dx))
    f1 = 2 * precision * recall / max(1e-9, precision + recall)
    ex = dx[di] - tx[ti]; ey = dy[di] - ty[ti]
    m = vis[ti]
    rms = float(np.sqrt(np.mean(np.concatenate([ex[m], ey[m]]) ** 2))) if m.any() else float("nan")
    frac = np.concatenate([dx[di][m] - np.round(dx[di][m]), dy[di][m] - np.round(dy[di][m])])
    return {"recall": float(recall), "precision": float(precision), "f1": float(f1), "loc_rms": rms, "pli": pli(frac)}


def p1_detection(rng):
    out = []
    for d_tau in (1.5, 2.5, 4.0):
        for noise in (2.0, 8.0):
            for ppp in (0.002, 0.01):
                n = int(ppp * W * H)
                tx = rng.uniform(4, W - 5, n); ty = rng.uniform(4, H - 5, n)
                z = rng.uniform(-0.75, 0.75, n)
                I0 = 180 * np.exp(-8 * z ** 2)
                img = to_u8(render(tx, ty, W, H, d_tau, I0), noise, rng)
                vis = peak_of(I0, d_tau) >= max(15.0, 3 * noise)
                row = {"d_tau": d_tau, "noise": noise, "ppp": ppp}
                # LivePTV: default, then sweep k
                lx, ly = liveptv_detect(img)
                row["LivePTV default"] = score(tx, ty, vis, lx, ly)
                best = None
                for k in (2, 3, 4, 5, 6, 8, 10):
                    lx, ly = liveptv_detect(img, k=k, minthr=4)
                    s = score(tx, ty, vis, lx, ly) | {"k": k}
                    best = s if best is None or s["f1"] > best["f1"] else best
                row["LivePTV tuned"] = best
                diam = 5 if d_tau <= 2.5 else 7
                best = None
                masses = None
                for mm in (0, 5, 10, 20, 40, 80, 160, 320, 640):
                    try:
                        x, y = trackpy_detect(img, diam, mm)
                    except Exception:
                        continue
                    s = score(tx, ty, vis, x, y) | {"minmass": mm}
                    best = s if best is None or s["f1"] > best["f1"] else best
                row["trackpy tuned"] = best
                out.append(row)
                print("P1", d_tau, noise, ppp, {k: round(v["f1"], 3) for k, v in row.items() if isinstance(v, dict)},
                      {k: round(v["loc_rms"], 3) for k, v in row.items() if isinstance(v, dict)}, file=sys.stderr)
    return out


# ------------------------------------------------------------------------------------------------ tracking
def taylor_green(U, L=128.0):
    def vel(x, y):
        return U * np.sin(np.pi * x / L) * np.cos(np.pi * y / L), -U * np.cos(np.pi * x / L) * np.sin(np.pi * y / L)
    return vel


def simulate(rng, N, U, frames=20, replace=0.02, sub=8):
    vel = taylor_green(U)
    x = rng.uniform(1, W - 2, N); y = rng.uniform(1, H - 2, N)
    ids = np.arange(N); nxt = N
    recs = []
    for k in range(frames):
        recs.append(pd.DataFrame({"frame": k, "id": ids.copy(), "x": x.copy(), "y": y.copy()}))
        h = 1.0 / sub
        for _ in range(sub):   # RK4
            k1 = vel(x, y); k2 = vel(x + h / 2 * k1[0], y + h / 2 * k1[1])
            k3 = vel(x + h / 2 * k2[0], y + h / 2 * k2[1]); k4 = vel(x + h * k3[0], y + h * k3[1])
            x = x + h / 6 * (k1[0] + 2 * k2[0] + 2 * k3[0] + k4[0])
            y = y + h / 6 * (k1[1] + 2 * k2[1] + 2 * k3[1] + k4[1])
        r = rng.random(N) < replace          # out-of-plane loss: replaced by a new particle
        x[r] = rng.uniform(1, W - 2, r.sum()); y[r] = rng.uniform(1, H - 2, r.sum())
        ids[r] = np.arange(nxt, nxt + r.sum()); nxt += r.sum()
    return pd.concat(recs, ignore_index=True)


def link_scores(df, track_col):
    """df: frame, id (truth), track (assigned). Precision / recall of frame-to-frame links."""
    tl = df.sort_values("frame")
    a = tl[["frame", "id", track_col]].copy()
    b = a.copy(); b["frame"] -= 1
    true_links = a.merge(b, on=["frame", "id"], suffixes=("", "_n"))
    out_links = a.merge(b, left_on=["frame", track_col], right_on=["frame", track_col], suffixes=("", "_n"))
    correct = (out_links["id"] == out_links["id_n"]).sum()
    recall = correct / max(1, len(true_links))
    precision = correct / max(1, len(out_links))
    lengths = a.groupby(track_col).size()
    return {"precision": float(precision), "recall": float(recall), "mean_track_len": float(lengths.mean())}


def p2_tracking(rng):
    import trackpy as tp
    out = []
    for N in (2000, 5000):
        spacing = np.sqrt(W * H / N)
        for U in (1, 2, 4, 6, 8, 10):
            df = simulate(rng, N, U)
            df["x"] += rng.normal(0, 0.05, len(df)); df["y"] += rng.normal(0, 0.05, len(df))
            R = max(4.0, 1.5 * U + 2)
            row = {"N": N, "U": U, "p_ratio": U / spacing, "search_radius": R}
            with tempfile.TemporaryDirectory() as td:
                fi, fo = os.path.join(td, "p.csv"), os.path.join(td, "t.csv")
                df[["frame", "x", "y"]].to_csv(fi, index=False)
                for label, maxd, pr in (("LivePTV default (12 px, 4 px)", 12, 4), ("LivePTV R-matched", R, 4)):
                    subprocess.run([HARNESS, "track", fi, fo, "--maxdisp", str(maxd), "--predrad", str(pr)], check=True)
                    t = pd.read_csv(fo)
                    d2 = df.copy(); d2["track"] = t["track"].to_numpy()
                    row[label] = link_scores(d2, "track")
            for label, pred in (("trackpy (no predictor)", None), ("trackpy + velocity predictor", tp.predict.NearestVelocityPredict(span=1))):
                d2 = df.rename(columns={"id": "true_id"}).copy()
                try:
                    with contextlib.redirect_stdout(io.StringIO()):
                        tp.quiet()
                        linker = pred.link_df if pred is not None else tp.link
                        t = linker(d2[["frame", "x", "y", "true_id"]], R, memory=1, adaptive_stop=0.5, adaptive_step=0.95)
                    t = t.rename(columns={"true_id": "id", "particle": "track"})
                    row[label] = link_scores(t, "track")
                except Exception as e:
                    row[label] = {"error": type(e).__name__}
            out.append(row)
            print("P2", N, U, {k: (round(v.get("precision", -1), 3), round(v.get("recall", -1), 3)) for k, v in row.items() if isinstance(v, dict)}, file=sys.stderr)
    return out


def p3_end_to_end(rng):
    """Images of the Taylor-Green flow; velocity error of samples vs the true field at the sample midpoint."""
    import trackpy as tp
    out = []
    for N, U in ((3000, 2), (3000, 5)):
        df = simulate(rng, N, U, frames=12, replace=0.02)
        vel = taylor_green(U)
        frames = []
        I0map = {}
        for k in range(12):
            s = df[df.frame == k]
            I = np.array([I0map.setdefault(i, 180 * np.exp(-8 * rng.uniform(-0.6, 0.6) ** 2)) for i in s.id])
            frames.append(to_u8(render(s.x.to_numpy(), s.y.to_numpy(), W, H, 2.5, I), 4.0, rng))
        row = {"N": N, "U": U}
        with tempfile.TemporaryDirectory() as td:
            fi, fo = os.path.join(td, "f.u8"), os.path.join(td, "s.csv")
            write_frames(fi, frames)
            R = max(4.0, 1.5 * U + 2)
            subprocess.run([HARNESS, "ptv", fi, fo, "--maxdisp", str(R), "--bg", "1"], check=True)
            s = pd.read_csv(fo)
            s = s[s.frame > 1]  # first frames: background warm-up
            tu, tv = vel(s.x.to_numpy(), s.y.to_numpy())
            e = np.hypot(s.dx - tu, s.dy - tv)
            keep = s.outlier == 0
            row["LivePTV"] = {"samples_per_frame": float(keep.sum() / s.frame.nunique()),
                              "rms": float(np.sqrt(np.mean(((s.dx - tu) ** 2 + (s.dy - tv) ** 2)[keep]) / 2)),
                              "bad_share(>0.5px)": float((e[keep] > 0.5).mean())}
        with contextlib.redirect_stdout(io.StringIO()):
            tp.quiet()
            feats = pd.concat([tp.locate(fr, 5, minmass=20, separation=3).assign(frame=k) for k, fr in enumerate(frames)])
            t = tp.predict.NearestVelocityPredict(span=1).link_df(feats, max(4.0, 1.5 * U + 2), memory=1, adaptive_stop=0.5, adaptive_step=0.95)
        t = t.sort_values(["particle", "frame"])
        g = t.groupby("particle")
        dx = g.x.diff(); dy = g.y.diff(); df_ = g.frame.diff()
        m = (df_ == 1) & (t.frame > 1)
        mx = (t.x - dx / 2)[m]; my = (t.y - dy / 2)[m]
        tu, tv = vel(mx.to_numpy(), my.to_numpy())
        e = np.hypot(dx[m] - tu, dy[m] - tv)
        row["trackpy"] = {"samples_per_frame": float(m.sum() / t.frame[m].nunique()),
                          "rms": float(np.sqrt(np.mean((dx[m] - tu) ** 2 + (dy[m] - tv) ** 2) / 2)),
                          "bad_share(>0.5px)": float((e > 0.5).mean())}
        out.append(row)
        print("P3", N, U, row, file=sys.stderr)
    return out


if __name__ == "__main__":
    which = sys.argv[1:] or ["p1", "p2", "p3"]
    for w in which:
        rng = np.random.default_rng({"p1": 21, "p2": 22, "p3": 23}[w])
        res = {"p1": p1_detection, "p2": p2_tracking, "p3": p3_end_to_end}[w](rng)
        with open(os.path.join(RES, f"ptv_{w}.json"), "w") as fh:
            json.dump(res, fh, indent=1, ensure_ascii=False)
        print(w, "saved", file=sys.stderr)
