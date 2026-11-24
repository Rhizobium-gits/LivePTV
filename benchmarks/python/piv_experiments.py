"""PIV comparison: LivePTV (PTVCore via Swift harness) vs OpenPIV windef (iterative image deformation).

Experiments (results/piv_*.json):
  E0 position convention (linear shear in x and y)
  E1 sub-pixel bias / random error vs fractional displacement, several particle-image diameters
  E2 spatial resolution: sinusoidal displacement, amplitude modulation vs wavelength
  E3 Lamb-Oseen vortex (mild / strong): RMS error, outliers, peak vorticity
  E4 dynamic range: uniform displacement magnitude
  E5 robustness: seeding density, noise, out-of-plane loss (vortex), plus LivePTV per-vector uncertainty check
  E6 speed (run separately, quiet machine): 1280x720, 1920x1080
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import sys
from multiprocessing import Pool

import numpy as np

from common import Scene, make_pair, run_liveptv, run_openpiv, errors

RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results")
os.makedirs(RES, exist_ok=True)
MARGIN = 32


def openpiv_quiet(args):
    A, B, kw = args
    with contextlib.redirect_stdout(io.StringIO()):
        return run_openpiv(A, B, **kw)


def openpiv_many(pairs, **kw):
    with Pool(8) as pool:
        return pool.map(openpiv_quiet, [(A, B, kw) for A, B in pairs])


def stats(res_list, field, W, H, margin=MARGIN):
    """Pooled metrics over pairs: rms (valid+replaced), bias, outlier share (|err|>0.5 px among all inside),
    valid share (status 0)."""
    exs, eys, n_in, n_out, n_valid = [], [], 0, 0, 0
    for r in res_list:
        ex, ey, use, inside = errors(r, field, W, H, margin)
        e = np.hypot(ex, ey)
        exs.append(ex[use]); eys.append(ey[use])
        n_in += inside.sum()
        n_out += ((e > 0.5) | ~use)[inside].sum()
        n_valid += (inside & (r["status"] == 0)).sum()
    ex = np.concatenate(exs); ey = np.concatenate(eys)
    e = np.hypot(ex, ey)
    good = e <= 0.5
    return {
        "rms_all": float(np.sqrt(np.mean(ex ** 2 + ey ** 2) / 2)),          # per component, all vectors
        "rms_good": float(np.sqrt(np.mean(ex[good] ** 2 + ey[good] ** 2) / 2)),  # per component, excl. outliers
        "bias_x": float(ex[good].mean()), "bias_y": float(ey[good].mean()),
        "std_x": float(ex[good].std()), "std_y": float(ey[good].std()),
        "outlier_share": float(n_out / max(1, n_in)),
        "valid_share": float(n_valid / max(1, n_in)),
        "n": int(n_in),
    }


TOOLS = {
    # name: (runner kind, kwargs)
    "LivePTV 64→32 (Lanczos, default)": ("L", dict(windows=(64, 32))),
    "LivePTV 64→32 (bilinear)": ("L", dict(windows=(64, 32), interp="bilinear")),
    "LivePTV 64→32→16": ("L", dict(windows=(64, 32, 16))),
    "LivePTV 64→32 (shift, 0.7 method)": ("L", dict(windows=(64, 32), deform=False, iters=2)),
    "LivePTV 64→32 (deform, no smoothing)": ("L", dict(windows=(64, 32), smooth=False)),
    "OpenPIV 64→32 (deform)": ("O", dict(windows=(64, 32), iters=3)),
    "OpenPIV 64→32→16 (deform)": ("O", dict(windows=(64, 32, 16), iters=3)),
}


def run_tool(name, pairs):
    kind, kw = TOOLS[name]
    if kind == "L":
        res, _, _ = run_liveptv(pairs, **kw)
        return res
    return [r for r, _ in openpiv_many(pairs, **kw)]


def e0_position(rng):
    W = H = 512
    sc = Scene(W=W, H=H, noise=1.0)
    g = 0.04
    out = {}
    for axis in ("y", "x"):
        if axis == "y":
            f = lambda x, y: (g * (y - 255.5), 0 * x)
        else:
            f = lambda x, y: (0 * x, g * (x - 255.5))
        pairs = [make_pair(f, sc, rng) for _ in range(4)]
        for name in ("LivePTV 64→32 (Lanczos, default)", "OpenPIV 64→32 (deform)"):
            res = run_tool(name, pairs)
            s = stats(res, f, W, H)
            bias = s["bias_x"] if axis == "y" else s["bias_y"]
            out.setdefault(name, {})[axis] = {"apparent_offset_px": -bias / g, **s}
    return out


def e1_subpixel(rng):
    W = H = 384
    fracs = np.round(np.linspace(0, 1, 11), 2)
    out = {}
    for d_tau in (1.0, 1.6, 2.5, 4.0):
        sc = Scene(W=W, H=H, d_tau=d_tau, noise=2.0, ppp=0.04 if d_tau < 3 else 0.025)
        rows = {n: [] for n in ("LivePTV 64→32 (Lanczos, default)", "LivePTV 64→32 (shift, 0.7 method)", "LivePTV 64→32 (bilinear)", "OpenPIV 64→32 (deform)")}
        for fr in fracs:
            f = (lambda a: (lambda x, y: (2 + a + 0 * x, 1 + a + 0 * y)))(fr)
            pairs = [make_pair(f, sc, rng) for _ in range(3)]
            for name in rows:
                s = stats(run_tool(name, pairs), f, W, H)
                rows[name].append({"frac": float(fr), **s})
        out[str(d_tau)] = rows
        print("E1 d_tau", d_tau, "done", file=sys.stderr)
    return out


def e2_mtf(rng):
    """dy = A sin(2πx/λ + φ), φ random per pair. Complex response H = fitted / true phasor:
    modulation = |H|·sign(Re H) (negative = phase reversal), phase in degrees. Wavelengths avoid 16 and 32 px, which
    sample exactly at the nodes of a 16-px / 8-px grid. Run with validation off (spatial response of the
    correlation itself) and on (what the user gets: the median test may flag a correct strong-gradient vector)."""
    W, H = 768, 256
    A = 1.0
    lams = [20, 24, 28, 40, 48, 56, 80, 112, 160, 224]
    sc = Scene(W=W, H=H, d_tau=2.5, noise=2.0, ppp=0.05)
    names = ["LivePTV 64→32 (Lanczos, default)", "LivePTV 64→32→16", "LivePTV 64→32 (shift, 0.7 method)",
             "LivePTV 64→32 (deform, no smoothing)", "OpenPIV 64→32 (deform)", "OpenPIV 64→32→16 (deform)"]
    out = {}
    for validate in (False, True):
        tag = "validation on" if validate else "validation off"
        out[tag] = {n: [] for n in names}
        for lam in lams:
            phis = rng.uniform(0, 2 * np.pi, 3)
            fields = [(lambda L, p: (lambda x, y: (0 * x, A * np.sin(2 * np.pi * x / L + p))))(lam, p) for p in phis]
            pairs = [make_pair(f, sc, rng) for f in fields]
            for name in names:
                kind, kw = TOOLS[name]
                if kind == "L":
                    res, _, _ = run_liveptv(pairs, validate=validate, **kw)
                else:
                    res = [r for r, _ in openpiv_many(pairs, validate=validate, **kw)]
                Hs, rmss = [], []
                for r, p in zip(res, phis):
                    x, y, dy, st = r["x"], r["y"], r["dy"], r["status"]
                    m = (x >= MARGIN) & (x <= W - 1 - MARGIN) & (y >= MARGIN) & (y <= H - 1 - MARGIN) & (st <= 1)
                    th = 2 * np.pi * x[m] / lam
                    X = np.column_stack([np.sin(th), np.cos(th), np.ones(m.sum())])
                    coef, *_ = np.linalg.lstsq(X, dy[m], rcond=None)
                    Hs.append(complex(coef[0], coef[1]) / (A * complex(np.cos(p), np.sin(p))))
                    rmss.append(np.sqrt(np.mean((dy[m] - A * np.sin(th + p)) ** 2)))
                Hm = np.mean(Hs)
                out[tag][name].append({"lambda": lam, "modulation": float(abs(Hm) * np.sign(Hm.real)),
                                       "phase_deg": float(np.degrees(np.angle(Hm))), "rms_vs_truth": float(np.mean(rmss))})
            print("E2", tag, "lambda", lam, "done", file=sys.stderr)
    return out


def lamb_oseen(xc, yc, rc, umax):
    rmax = 1.1209 * rc
    gamma = 2 * np.pi * rmax * umax / (1 - np.exp(-(rmax / rc) ** 2))

    def f(x, y):
        dx, dy = x - xc, y - yc
        r2 = dx * dx + dy * dy + 1e-12
        vt_over_r = gamma / (2 * np.pi * r2) * (1 - np.exp(-r2 / rc ** 2))
        return -vt_over_r * dy, vt_over_r * dx   # counter-clockwise in a y-down image = clockwise on screen; sign irrelevant
    omega0 = gamma / (np.pi * rc ** 2)
    return f, omega0


def peak_vorticity(r, W, H):
    """|omega| at the grid node nearest the vortex centre, central differences on the tool's grid (px/frame / px)."""
    x, y = r["x"], r["y"]
    xs, ys = np.unique(x), np.unique(y)
    U = np.full((len(ys), len(xs)), np.nan); V = U.copy()
    ix = np.searchsorted(xs, x); iy = np.searchsorted(ys, y)
    U[iy, ix] = r["dx"]; V[iy, ix] = r["dy"]
    h = xs[1] - xs[0]
    om = np.gradient(V, h, axis=1) - np.gradient(U, h, axis=0)
    c = np.unravel_index(np.argmin((xs[None, :] - W / 2 + 0.5) ** 2 + (ys[:, None] - H / 2 + 0.5) ** 2), U.shape)
    win = om[max(0, c[0] - 1):c[0] + 2, max(0, c[1] - 1):c[1] + 2]
    return float(np.nanmax(np.abs(win)))


def e3_vortex(rng):
    W = H = 512
    out = {}
    for label, rc, umax in (("mild (rc=60 px, 3 px max)", 60, 3.0), ("strong (rc=30 px, 4 px max)", 30, 4.0)):
        f, om0 = lamb_oseen(255.5, 255.5, rc, umax)
        sc = Scene(W=W, H=H, d_tau=2.5, noise=2.0, ppp=0.04)
        pairs = [make_pair(f, sc, rng) for _ in range(4)]
        out[label] = {"omega0": float(om0)}
        for name in ("LivePTV 64→32 (Lanczos, default)", "LivePTV 64→32→16", "LivePTV 64→32 (shift, 0.7 method)",
                     "LivePTV 64→32 (deform, no smoothing)", "OpenPIV 64→32 (deform)", "OpenPIV 64→32→16 (deform)"):
            res = run_tool(name, pairs)
            s = stats(res, f, W, H)
            pv = np.mean([peak_vorticity(r, W, H) for r in res])
            # ideal: the true field sampled on the same grid, same differencing
            ideal = []
            for r in res:
                tx, ty = f(r["x"], r["y"])
                ideal.append(peak_vorticity({"x": r["x"], "y": r["y"], "dx": tx, "dy": ty}, W, H))
            out[label][name] = {**s, "peak_vorticity": pv, "peak_vorticity_ideal_on_grid": float(np.mean(ideal))}
        print("E3", label, "done", file=sys.stderr)
    return out


def e4_dynamic_range(rng):
    W = H = 512
    sc = Scene(W=W, H=H, d_tau=2.5, noise=2.0, ppp=0.04)
    out = {n: [] for n in ("LivePTV 64→32 (Lanczos, default)", "OpenPIV 64→32 (deform)")}
    for D in (2, 6, 10, 14, 18, 22, 26):
        f = (lambda d: (lambda x, y: (d + 0 * x, 0.5 * d + 0 * y)))(D)
        pairs = [make_pair(f, sc, rng) for _ in range(2)]
        for name in out:
            s = stats(run_tool(name, pairs), f, W, H)
            out[name].append({"magnitude": float(np.hypot(D, D / 2)), **s})
    return out


def e5_robustness(rng):
    W = H = 512
    f, _ = lamb_oseen(255.5, 255.5, 60, 3.0)
    base = dict(W=W, H=H, d_tau=2.5, noise=2.0, ppp=0.04, dz=0.0)
    sweeps = {"ppp": [0.005, 0.01, 0.02, 0.04, 0.08], "noise": [2, 8, 16, 24], "dz": [0.0, 0.15, 0.3, 0.5]}
    out = {}
    for key, vals in sweeps.items():
        out[key] = {n: [] for n in ("LivePTV 64→32 (Lanczos, default)", "LivePTV 64→32 (shift, 0.7 method)", "OpenPIV 64→32 (deform)")}
        for v in vals:
            sc = Scene(**{**base, key: v})
            pairs = [make_pair(f, sc, rng) for _ in range(3)]
            for name in out[key]:
                res = run_tool(name, pairs)
                s = stats(res, f, W, H)
                if name.startswith("LivePTV") and "shift" not in name:
                    # per-vector uncertainty: predicted RMS sigma vs actual RMS error, valid vectors, excluding outliers
                    pr, ac = [], []
                    for r in res:
                        ex, ey, use, inside = errors(r, f, W, H, MARGIN)
                        m = inside & (r["status"] == 0) & (np.hypot(ex, ey) <= 0.5) & np.isfinite(r["sigx"])
                        pr.append(np.concatenate([r["sigx"][m], r["sigy"][m]]) ** 2)
                        ac.append(np.concatenate([ex[m], ey[m]]) ** 2)
                    pr = np.concatenate(pr); ac = np.concatenate(ac)
                    s["sigma_pred_rms"] = float(np.sqrt(pr.mean())) if len(pr) else None
                    s["sigma_actual_rms"] = float(np.sqrt(ac.mean())) if len(ac) else None
                out[key][name].append({key: v, **s})
        print("E5", key, "done", file=sys.stderr)
    return out


def e6_speed(rng):
    """Wall time per pair on this Mac (Apple M4). LivePTV: warm engine, median of pairs 2..N. OpenPIV: one process,
    single thread (its default), median of 2 pairs. Same window schedule 64→32, 2 final iterations, 50 % overlap."""
    out = {}
    for (W, H) in ((1280, 720), (1920, 1080)):
        f, _ = lamb_oseen(W / 2 - 0.5, H / 2 - 0.5, 80, 3.0)
        sc = Scene(W=W, H=H, d_tau=2.5, noise=2.0, ppp=0.03)
        base = make_pair(f, sc, rng)
        pairs = [base] * 12
        row = {}
        for label, kw in (("LivePTV (GPU 32-px passes)", dict(gpu=True)), ("LivePTV (CPU only)", dict(gpu=False)),
                          ("LivePTV (CPU, bilinear, no uncertainty)", dict(gpu=False, interp="bilinear", uncertainty=False))):
            res, times, dev = run_liveptv(pairs, **kw)
            row[label] = {"ms_median": float(np.median(times[2:])), "vectors": int(len(res[0]["x"])), "device": dev}
        ts = []
        for _ in range(2):
            with contextlib.redirect_stdout(io.StringIO()):
                r, ms = run_openpiv(*base, iters=3)
            ts.append(ms)
        row["OpenPIV windef (Python, 1 process)"] = {"ms_median": float(np.median(ts)), "vectors": int(len(r["x"]))}
        out[f"{W}x{H}"] = row
        print("E6", W, H, {k: round(v["ms_median"], 1) for k, v in row.items()}, file=sys.stderr)
    return out


if __name__ == "__main__":
    which = sys.argv[1:] or ["e0", "e1", "e2", "e3", "e4", "e5"]
    for w in which:
        rng = np.random.default_rng({"e0": 10, "e1": 11, "e2": 12, "e3": 13, "e4": 14, "e5": 15, "e6": 16}[w])
        res = globals()[{"e0": "e0_position", "e1": "e1_subpixel", "e2": "e2_mtf", "e3": "e3_vortex",
                         "e4": "e4_dynamic_range", "e5": "e5_robustness", "e6": "e6_speed"}[w]](rng)
        with open(os.path.join(RES, f"piv_{w}.json"), "w") as fh:
            json.dump(res, fh, indent=1, ensure_ascii=False)
        print(w, "saved", file=sys.stderr)
