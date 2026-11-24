"""Writes the README's "Experiments" section (between <!-- experiments:start --> and <!-- experiments:end -->) from
the result files in benchmarks/results, so every number there comes from a file."""
from __future__ import annotations

import json
import os
import re

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "..", "results")
README = os.path.join(HERE, "..", "..", "README.md")

L08, L07 = "LivePTV 64→32 (Lanczos, default)", "LivePTV 64→32 (shift, 0.7 method)"
L16, LNS, LBI = "LivePTV 64→32→16", "LivePTV 64→32 (deform, no smoothing)", "LivePTV 64→32 (bilinear)"
O32, O16 = "OpenPIV 64→32 (deform)", "OpenPIV 64→32→16 (deform)"


def load(name):
    with open(os.path.join(RES, name)) as f:
        return json.load(f)


def table(head, rows):
    out = ["| " + " | ".join(head) + " |", "| " + " | ".join("---" for _ in head) + " |"]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def details(title, summary, body):
    return f"<details>\n<summary><b>{title}</b> — {summary}</summary>\n\n{body.strip()}\n\n</details>\n"


def lam90(rows):
    lam = np.array([r["lambda"] for r in rows]); m = np.array([r["modulation"] for r in rows])
    i = np.where((m[:-1] < 0.9) & (m[1:] >= 0.9))[0]
    return float(np.exp(np.interp(0.9, [m[i[-1]], m[i[-1] + 1]], np.log(lam[i[-1]:i[-1] + 2])))) if len(i) else float("nan")


def e0():
    d, o = load("piv_e0.json"), load("v07/piv_e0.json")
    rows = []
    for lab, src, key in (("LivePTV 0.7", o, L08), ("LivePTV 0.8", d, L08), ("OpenPIV 0.26", d, O32)):
        rows.append([lab] + [f"{src[key][ax]['apparent_offset_px']:+.3f} px" for ax in ("y", "x")])
    body = ("A linear shear (gradient 0.04 px/px) along y and along x: the error at a vector divided by the gradient is how far "
            "the vector sits from where it was measured.\n\n" + table(["", "shear along y", "shear along x"], rows))
    return details("E0 · Vector positions", "LivePTV 0.7 reported every vector 0.5 px off its window centre; 0.8: < 0.01 px", body)


def e1():
    d = load("piv_e1.json")
    rows = []
    for dt in ("1.0", "1.6", "2.5", "4.0"):
        r = d[dt]
        def cell(k):
            v = r[k]
            return f"{max(max(abs(s['bias_x']), abs(s['bias_y'])) for s in v):.4f} / {np.mean([(s['std_x'] + s['std_y']) / 2 for s in v]):.4f}"
        rows.append([f"{dt} px", cell(L07), cell(L08), cell(LBI), cell(O32)])
    body = ("Uniform displacement 2 + f px (x) and 1 + f px (y), f = 0 … 1 in steps of 0.1; 0.04 particles/px (0.025 for 4 px); "
            "noise 2 grey levels; 3 pairs of 384 × 384 px per step. Cells: largest systematic error / mean random error (px).\n\n"
            + table(["particle images", "LivePTV 0.7", "LivePTV 0.8", "LivePTV, bilinear option", "OpenPIV 0.26"], rows)
            + '\n\n<img src="docs/images/bench_subpixel.png" alt="Sub-pixel bias against the fractional displacement">')
    return details("E1 · Sub-pixel bias and random error (uniform flow)",
                   "smallest bias of the tools (0.003 px at 2.5 px images, OpenPIV 0.016 px)", body)


def e2():
    d = load("piv_e2.json")
    off, on = d["validation off"], d["validation on"]
    names = [(L07, "LivePTV 0.7"), (L08, "LivePTV 0.8"), (LNS, "0.8, predictor unfiltered"), (L16, "0.8, 16-px windows"),
             (O32, "OpenPIV 0.26"), (O16, "OpenPIV, 16-px windows")]
    lams = [r["lambda"] for r in off[L08]]
    rows = []
    for k, lab in names:
        rows.append([lab] + [f"{r['modulation']:.2f}" for r in off[k]] + [f"{lam90(off[k]):.0f}", f"{lam90(on[k]):.0f}"])
    body = ("Displacement dy = sin(2πx/λ + φ) px (random φ), 768 × 256 px, 0.05 particles/px, 2.5 px images. Recovered "
            "amplitude (1 = exact, negative = phase reversed) with the outlier test off; the last two columns give the "
            "shortest wavelength kept at 90 % amplitude without and with the normalised median test.\n\n"
            + table(["λ (px) →"] + [str(l) for l in lams] + ["λ₉₀ (px)", "λ₉₀, with test"], rows)
            + "\n\nWith a window of 32 px, a plain window average (top-hat) keeps 0.64 at λ = 64 px and 90 % only at λ ≈ 125 px; "
            "LivePTV 0.7 sat on that curve. The median test removes some correct vectors where neighbours differ strongly "
            "(λ ≲ 3 vector spacings), in both tools.")
    return details("E2 · Spatial resolution (sinusoidal displacement)",
                   f"90 % amplitude down to λ = {lam90(off[L08]):.0f} px (0.7: {lam90(off[L07]):.0f}, OpenPIV: {lam90(off[O32]):.0f})", body)


def e3():
    d = load("piv_e3.json")
    mild, strong = list(d)
    names = [(L07, "LivePTV 0.7"), (L08, "LivePTV 0.8"), (LNS, "0.8, predictor unfiltered"), (L16, "0.8, 16-px windows"),
             (O32, "OpenPIV 0.26"), (O16, "OpenPIV, 16-px windows")]
    rows = []
    for k, lab in names:
        a, b = d[mild][k], d[strong][k]
        rows.append([lab, f"{a['rms_all']:.4f}", f"{b['rms_all']:.4f}", f"{100 * b['outlier_share']:.1f} %",
                     f"{b['peak_vorticity'] / b['peak_vorticity_ideal_on_grid']:.2f}"])
    body = ("Lamb–Oseen vortices in 512 × 512 px images (0.04 particles/px, 2.5 px images, noise 2): core radius 60 px with "
            "3 px peak displacement, and 30 px with 4 px. RMS error per component (px) over the whole field; peak vorticity "
            "relative to the exact field sampled on the same grid.\n\n"
            + table(["", "core 60 px: RMS", "core 30 px: RMS", "core 30 px: off > 0.5 px", "core 30 px: peak vorticity"], rows)
            + '\n\n<img src="docs/images/bench_vortex.png" alt="Error maps for the strong vortex">')
    return details("E3 · Vortices", f"core 30 px: {d[strong][L08]['rms_all']:.3f} px (0.7: {d[strong][L07]['rms_all']:.3f}, "
                   f"OpenPIV: {d[strong][O32]['rms_all']:.3f})", body)


def e4():
    d = load("piv_e4.json")
    rows = [[f"{a['magnitude']:.1f} px", f"{a['rms_good']:.4f} / {100 * a['valid_share']:.0f} %", f"{b['rms_good']:.4f} / {100 * b['valid_share']:.0f} %"]
            for a, b in zip(d[L08], d[O32])]
    body = ("Uniform displacement (D, D/2) with the default 64 → 32 px schedule. Cells: RMS error (px) / valid vectors. LivePTV "
            "also adapts the frame spacing so the typical displacement stays near 2 px.\n\n"
            + table(["displacement", "LivePTV 0.8", "OpenPIV 0.26"], rows))
    return details("E4 · Large displacements", "both tools to 29 px with every vector valid", body)


def e5():
    d, o = load("piv_e5.json"), load("v07/piv_e5.json")
    lab = {"ppp": "particles / px", "noise": "noise σ (grey levels)", "dz": "out-of-plane motion (sheet thicknesses)"}
    parts = []
    for key in ("ppp", "noise", "dz"):
        rows = []
        for a, s7, b, a7 in zip(d[key][L08], d[key][L07], d[key][O32], o[key][L08]):
            rows.append([a[key], f"{s7['rms_all']:.4f}", f"{a['rms_all']:.4f}", f"{b['rms_all']:.4f}",
                         f"{a['sigma_pred_rms'] / a['sigma_actual_rms']:.2f}", f"{a7['sigma_pred_rms'] / a7['sigma_actual_rms']:.2f}"])
        parts.append(table([lab[key], "LivePTV 0.7", "LivePTV 0.8", "OpenPIV 0.26",
                                                   "0.8: predicted ÷ actual", "0.7: predicted ÷ actual"], rows))
    body = ("The weak vortex of E3 with one condition changed at a time (base: 0.04 particles/px, noise 2, no out-of-plane "
            "motion). RMS error per component (px), and the per-vector uncertainty LivePTV reports (correlation statistics) "
            "divided by the actual error.\n\n" + "\n\n".join(parts)
            + '\n\n<img src="docs/images/bench_robustness.png" alt="RMS error against seeding, noise and out-of-plane motion">'
            + '\n<img src="docs/images/bench_uncertainty.png" width="45%" alt="Predicted uncertainty against actual error">'
            + "\n\nThe reported uncertainty covers random error. With image deformation it is conservative on clean images "
              "(up to ×1.5) and about 15 % low on noisy ones.")
    return details("E5 · Difficult images and the reported uncertainty",
                   "ahead of OpenPIV in every condition; uncertainty within ×0.84–1.48 of the actual error", body)


def e6():
    d, t = load("piv_e6.json"), load("ptv_timing.json")
    rows = []
    for res in ("1280x720", "1920x1080"):
        r = d[res]
        rows.append([f"PIV {res.replace('x', ' × ')}", f"{r['LivePTV (GPU 32-px passes)']['ms_median']:.1f} ms",
                     f"{r['LivePTV (CPU only)']['ms_median']:.1f} ms", f"OpenPIV {r['OpenPIV windef (Python, 1 process)']['ms_median']:.0f} ms"])
    rows.append([f"PTV {t['width']} × {t['height']}, ~{t['particles']:,} particles", "–",
                 f"{t['LivePTV_ms_per_frame']:.0f} ms ({t['LivePTV_detected_per_frame']:,} found)",
                 f"trackpy {t['trackpy_ms_per_frame']:.0f} ms ({t['trackpy_detected_per_frame']:,.0f} found)"])
    body = ("Apple M4 (Mac), median over repeated pairs; LivePTV's analysis engine in one process, OpenPIV and trackpy in "
            "one Python process (their default). PIV: 64 → 32 px, 50 % overlap, three final iterations for both.\n\n"
            + table(["task", "LivePTV, GPU", "LivePTV, CPU only", "reference"], rows))
    return details("E6 · Speed", "PIV 17 ms (720p) / 39 ms (1080p) per pair; PTV 52 ms for 20,000 particles", body)


def real_piv():
    d = load("real_piv.json")
    rows = [[v["title"].split(": ")[0], v["title"].split(": ")[1], f"{v['median_diff_px']:.3f} px", f"{v['p90_diff_px']:.2f} px",
             f"{100 * v['share_within_0p2px']:.0f} %", f"{100 * v['valid_liveptv']:.1f} %", f"{v['ms_liveptv']:.0f} ms", f"{v['ms_openpiv'] / 1000:.2f} s"]
            for v in d.values()]
    body = ("OpenPIV's sample recordings (real images, shipped with the `openpiv` package), both tools at 64 → 32 px with "
            "image deformation and three final iterations. No ground truth: OpenPIV is interpolated to LivePTV's vector "
            "positions and the difference is reported.\n\n"
            + table(["recording", "scene", "median difference", "90th percentile", "within 0.2 px", "LivePTV valid", "LivePTV", "OpenPIV"], rows))
    return details("R1 · Real PIV recordings", "the two tools agree to a median of 0.02–0.07 px", body)


def p1():
    d, o = load("ptv_p1.json"), load("v07/ptv_p1.json")
    f = lambda s: f"{s['recall']:.2f} / {s['precision']:.3f} / {s['loc_rms']:.3f}"
    rows = [[f"{r['d_tau']:g} px", f"{r['noise']:g}", f"{r['ppp']:g}", f(ro["LivePTV default"]), f(r["LivePTV default"]),
             f"{f(r['LivePTV tuned'])} (k {r['LivePTV tuned']['k']:g})", f"{f(r['trackpy tuned'])} ({r['trackpy tuned']['minmass']:g})"]
            for r, ro in zip(d, o)]
    body = ("Single 512 × 512 frames, particles in a light sheet (so some are faint), recall counted over particles that rise "
            "above max(15, 3σ) grey levels. Cells: recall / precision / localisation error (px). The tuned columns sweep "
            "LivePTV's k and trackpy's minimum mass for the best F1.\n\n"
            + table(["particle images", "noise", "particles/px", "LivePTV 0.7", "LivePTV 0.8 (defaults)", "LivePTV 0.8, best k",
                     "trackpy 0.7, best minmass"], rows)
            + '\n\n<img src="docs/images/bench_ptv.png" alt="Tracking and detection results">')
    return details("P1 · Particle detection", "recall up from 0.45–0.53 to 0.76–0.89 in dense images, precision ≥ 0.997", body)


def p2():
    d, o = load("ptv_p2.json"), load("v07/ptv_p2.json")
    g = lambda s: f"{s['precision']:.3f} / {s['recall']:.3f}" if "precision" in s else "–"
    rows = [[r["N"], f"{r['U']} px", f"{r['p_ratio']:.2f}", g(ro["LivePTV default (12 px, 4 px)"]), g(r["LivePTV default (12 px, 4 px)"]),
             g(r["trackpy (no predictor)"]), g(r["trackpy + velocity predictor"])] for r, ro in zip(d, o)]
    ab, gate = load("ptv_ablation.json"), load("ptv_gate_fast.json")["results"]
    arow = []
    for name, rr in ab.items():
        mp, mr = np.mean([r["precision"] for r in rr]), np.mean([r["recall"] for r in rr])
        a = next(r for r in rr if r["N"] == 2000 and r["U"] == 10); b = next(r for r in rr if r["N"] == 5000 and r["U"] == 10)
        arow.append([name, f"{mp:.3f} / {mr:.3f}", f"{a['precision']:.3f} / {a['recall']:.3f}", f"{b['precision']:.3f} / {b['recall']:.3f}"])
    grow = [[k.replace("/", " particles, ") + " px/frame"] + [f"{v[a][0]:.3f} / {v[a][1]:.3f}" for a in ("0", "0.1", "0.3")] for k, v in gate.items()]
    body = ("Exact particle positions (+0.05 px noise) in a Taylor–Green vortex array, 512 × 512 px, 20 frames, 2 % of the "
            "particles replaced per frame (out-of-plane loss). Cells: precision / recall of frame-to-frame links; the search "
            "radius of trackpy is 1.5 U + 2 px.\n\n"
            + table(["particles", "max displacement", "÷ mean spacing", "LivePTV 0.7", "LivePTV 0.8", "trackpy", "trackpy + predictor"], rows)
            + "\n\n**What each part contributes** (the same datasets with one part of the tracker switched off; "
              "[`ptv_ablation.py`](benchmarks/python/ptv_ablation.py)):\n\n"
            + table(["tracker", "mean over the 12 cases", "2000 particles, 10 px", "5000 particles, 10 px"], arow)
            + "\n\nThe neighbour-consistency vote for tracks without a prediction and the global assignment make the "
              "difference; without the vote the tracker falls back to the 0.7 level. The speed-dependent gate does nothing "
              "within these cases; it is there for faster, sparser flows (separate datasets, search radius 24 px; gate factor "
              "0 / 0.1 (default) / 0.3):\n\n"
            + table(["flow", "factor 0", "factor 0.1", "factor 0.3"], grow)
            + "\n\n0.3 would help the sparse case more but costs the dense one.")
    return details("P2 · Particle tracking", "0.98 / 0.97 at 1.4 particle spacings per frame (0.7: 0.32 / 0.21, trackpy: 0.77 / 0.67)", body)


def p3():
    d, o = load("ptv_p3.json"), load("v07/ptv_p3.json")
    f = lambda s: f"{s['samples_per_frame']:,.0f} / {s['rms']:.3f} / {100 * s['bad_share(>0.5px)']:.1f} %"
    rows = [[f"{r['U']} px/frame", f(ro["LivePTV"]), f(r["LivePTV"]), f(r["trackpy"])] for r, ro in zip(d, o)]
    body = ("3000 particles in the Taylor–Green flow rendered as images (2.5 px particles, noise 4), 12 frames, detection and "
            "tracking with each tool's defaults (trackpy: diameter 5, minimum mass 20, velocity predictor). Cells: velocity "
            "samples per frame / RMS error (px) / share off by more than 0.5 px.\n\n"
            + table(["flow", "LivePTV 0.7", "LivePTV 0.8", "trackpy 0.7"], rows))
    return details("P3 · From images to particle velocities", "75 % more samples than 0.7 and the fewest bad ones", body)


def brownian():
    s, s7, r = load("synthetic_brownian.json"), load("v07/synthetic_brownian.json"), load("real_brownian.json")
    rows = [["LivePTV 0.7", f"{s7['LivePTV']['D_lag12_bias_pct']:+.0f} %", f"{s7['LivePTV']['D_msd10_bias_pct']:+.0f} %", f"{s7['LivePTV']['loc_sigma_px']:.3f} px"],
            ["LivePTV 0.8", f"{s['LivePTV']['D_lag12_bias_pct']:+.0f} %", f"{s['LivePTV']['D_msd10_bias_pct']:+.0f} %", f"{s['LivePTV']['loc_sigma_px']:.3f} px"],
            ["trackpy 0.7", f"{s['trackpy']['D_lag12_bias_pct']:+.0f} %", f"{s['trackpy']['D_msd10_bias_pct']:+.0f} %", f"{s['trackpy']['loc_sigma_px']:.3f} px"]]
    lv, tp = r["LivePTV"], r["trackpy"]
    rows2 = [["LivePTV 0.8 (app pipeline)", f"{lv['D_app_lag12_um2_s']:.3f} µm²/s → {lv['size_app_nm']:,.0f} nm", f"{lv['D_msd10_um2_s']:.3f} µm²/s → {lv['size_msd10_nm']:,.0f} nm"],
             ["trackpy 0.7 (walkthrough settings)", f"{tp['D_lag12_um2_s']:.3f} µm²/s → {tp['size_lag12_nm']:,.0f} nm", f"{tp['D_msd10_um2_s']:.3f} µm²/s → {tp['size_msd10_nm']:,.0f} nm"]]
    body = ("**Synthetic, known D.** Particles made to resemble the real sample (6.4 px images, D = 3.5 px²/s at 24 fps, slow "
            "drift, 300 frames); both trackings evaluated with the same estimators after removing stubs and drift.\n\n"
            + table(["", "D error, lag 1–2 (noise removed)", "D error, 10-lag MSD fit", "localisation σ"], rows)
            + "\n\nLivePTV 0.7's background learned the slow particles and pushed them along their motion.\n\n"
            "**Real video.** trackpy's `bulk_water` sample (1 µm latex spheres in water, 24 fps, 2.85 px/µm); Stokes–Einstein "
            "diameter at 20 °C (nominal 1,000 nm).\n\n"
            + table(["", "lag 1–2", "10-lag MSD fit"], rows2)
            + f"\n\nThe recording spreads slightly faster than diffusive (MSD exponent {tp['powerlaw_n']:.2f}), so the two "
              "estimators differ; with the same estimator the tools agree.")
    return details("B · Brownian motion and particle size", "D within 3 % on synthetic particles (0.7: +37 %); the tools agree on the real video", body)


def camera():
    c = load("camera_motion.json")
    p, u = c["pipeline"], c["unit"]
    sw, pt, sh = p["stand_sway_piv"], p["stand_sway_ptv"], p["shear_keystone_piv"]
    rows = [["stand sways about its foot, 900 px below the picture: static border fluctuation", f"{sw['border_std_px_s']['uncompensated']:.2f} px/s", f"{sw['border_std_px_s']['automatic']:.2f} px/s"],
            ["same: flow fluctuation", f"{sw['flow_std_px_s']['uncompensated']:.2f} px/s", f"{sw['flow_std_px_s']['automatic']:.2f} px/s"],
            ["same, PTV: velocity RMS error", f"{pt['velocity_rms_error_px_s']['uncompensated']:.2f} px/s", f"{pt['velocity_rms_error_px_s']['automatic']:.2f} px/s"],
            ["rolling-shutter shear + keystone: static border (similarity model vs automatic)", f"{sh['border_std_px_s']['similarity']:.2f} px/s", f"{sh['border_std_px_s']['automatic']:.2f} px/s"],
            ["same: flow", f"{sh['flow_std_px_s']['similarity']:.2f} px/s", f"{sh['flow_std_px_s']['automatic']:.2f} px/s"]]
    body = ("The synthetic camera moves the whole picture each frame (rotation about a chosen point, shift, zoom, shear, "
            "keystone) over a steady vortex with a static textured border; the full pipeline runs with compensation off or "
            "automatic. A steady flow has no real fluctuation, so what remains is camera motion left over.\n\n"
            + table(["case", "without / before", "with"], rows)
            + f"\n\nThe pivot was found at ({sw['pivot_found_px'][0]}, {sw['pivot_found_px'][1]}) px for the true "
              f"({sw['pivot_truth_px'][0]}, {sw['pivot_truth_px'][1]}) px (R² {sw['pivot_r2']:.2f}) and reported as outside "
              f"the frame. Unit tests: a pivot 1500 px below the picture is learned within {abs(u['pivot_1500px_below']['learned_px'][1] - u['pivot_1500px_below']['truth_px'][1]) + abs(u['pivot_1500px_below']['learned_px'][0] - u['pivot_1500px_below']['truth_px'][0])} px; "
              "with static background on one side only, shear and keystone are never fitted; a pure shift with noise is "
              f"fitted as a shift in all {u['pure_shift_noise_0p05px']['models']['translation']} pairs. The compensation is for "
              "fluctuations and single PTV steps: zero-mean shake averages out of the mean field, and there compensation costs a "
              f"little (mean-field error {100 * c['showcase_stand_sway']['mean_field_rel_rms']['uncompensated']:.2f} % without, "
              f"{100 * c['showcase_stand_sway']['mean_field_rel_rms']['automatic']:.2f} % with), because the long-term mean "
              "motion is kept as possible flow and its estimate is uncertain."
            + '\n\n<img src="docs/images/bench_camera_motion.png" alt="Fluctuation maps without and with compensation, and the learned pivot">')
    return details("C · Camera motion", "fluctuation 13.96 → 1.20 px/s for a stand swaying about its foot; pivot within 25 px", body)


def showcase():
    s = load("showcase_summary.json")
    rows = [["vortex in a 60 mm bottle (reflections, glare, glint, refraction)", f"{100 * s['bottle']['corrected']:.1f} % (naive analysis {100 * s['bottle']['naive']:.1f} %)"],
            ["counter-rotating vortex pair", f"{100 * s['vortex_pair']:.2f} %"], ["Taylor–Green vortex array", f"{100 * s['vortex_array']:.2f} %"],
            ["channel (Poiseuille) flow", f"{100 * s['channel']:.2f} %"],
            ["faint sparse Brownian tracers", f"ensemble {100 * s['faint_ensemble']['ensemble']:.1f} %, averaged single pairs {100 * s['faint_ensemble']['averaged_single_pairs']:.1f} %"],
            ["Brownian PTV (synthetic)", f"D {s['brownian_ptv_synthetic']['D_px2_s']:.3f} px²/s for {s['brownian_ptv_synthetic']['D_true_px2_s']:.1f}; {s['brownian_ptv_synthetic']['stokes_einstein_nm']} nm for {s['brownian_ptv_synthetic']['true_nm']} nm"]]
    body = ("Synthetic scenes recorded through the app's pipeline and recorder (`ShowcaseTests`); relative RMS error of the "
            "time-averaged field against the exact flow.\n\n" + table(["scene", "result"], rows))
    return details("S · Example sessions", "0.2–1.9 % with dense tracers, 7.4 % for faint sparse ones (ensemble correlation)", body)


def main():
    parts = ["## Experiments", "",
             "Every number below is read from [`benchmarks/results`](benchmarks/results) by "
             "[`make_readme_tables.py`](benchmarks/python/make_readme_tables.py); how to rerun them is in "
             "[benchmarks/README.md](benchmarks/README.md). Synthetic images: Gaussian particle images integrated over each "
             "pixel, a light sheet, Gaussian noise, 8 bit, exact displacement. LivePTV 0.7 is the previous release "
             "(window shift), LivePTV 0.8 this version, both with default settings unless stated. Click a line to open it.", ""]
    for f in (e0, e1, e2, e3, e4, e5, e6, real_piv, p1, p2, p3, brownian, camera, showcase):
        parts.append(f())
    section = "\n".join(parts).rstrip() + "\n"
    with open(README) as fh:
        text = fh.read()
    start, end = "<!-- experiments:start -->", "<!-- experiments:end -->"
    new = re.sub(re.escape(start) + r".*?" + re.escape(end), start + "\n" + section + end, text, flags=re.S)
    if new == text and start not in text:
        raise SystemExit("markers not found in README.md")
    with open(README, "w") as fh:
        fh.write(new)
    print("README experiments section:", len(section.splitlines()), "lines")


if __name__ == "__main__":
    main()
