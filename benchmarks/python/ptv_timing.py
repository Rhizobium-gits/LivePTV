"""PTV speed: detection + tracking per 1920×1080 frame with ~20,000 particles (Taylor–Green flow, 2 px/frame),
LivePTV (harness `timeptv`, defaults) and trackpy (locate + link with a velocity predictor, one process).
Writes results/ptv_timing.json."""
import contextlib, io, json, os, subprocess, sys, tempfile, time
import numpy as np, pandas as pd, trackpy as tp
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import HARNESS, render, to_u8, write_frames

RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results")
W, H, N, FRAMES, U, L = 1920, 1080, 20000, 12, 2.0, 270.0
rng = np.random.default_rng(3)
x = rng.uniform(2, W - 3, N); y = rng.uniform(2, H - 3, N)
frames = []
for k in range(FRAMES):
    frames.append(to_u8(render(x, y, W, H, 2.5, np.full(N, 160.0)), 2.0, rng))
    u = U * np.sin(np.pi * x / L) * np.cos(np.pi * y / L); v = -U * np.cos(np.pi * x / L) * np.sin(np.pi * y / L)
    x = np.clip(x + u, 0, W - 1); y = np.clip(y + v, 0, H - 1)
out = {"width": W, "height": H, "particles": N}
with tempfile.TemporaryDirectory() as td:
    fi, fo = os.path.join(td, "f.u8"), os.path.join(td, "t.csv")
    write_frames(fi, frames)
    subprocess.run([HARNESS, "timeptv", fi, fo], check=True)
    r = pd.read_csv(fo)
    out["LivePTV_ms_per_frame"] = float(r.median_ms[0]); out["LivePTV_detected_per_frame"] = int(r.particles_per_frame[0])
tp.quiet()
t0 = time.perf_counter()
with contextlib.redirect_stdout(io.StringIO()):
    f = tp.batch([fr.astype(float) for fr in frames], 5, minmass=100, processes=1)
t1 = time.perf_counter()
with contextlib.redirect_stdout(io.StringIO()):
    tp.predict.NearestVelocityPredict(span=1).link_df(f, 6, memory=1, adaptive_stop=0.5, adaptive_step=0.95)
t2 = time.perf_counter()
out["trackpy_ms_per_frame"] = 1000 * (t2 - t0) / FRAMES
out["trackpy_locate_ms_per_frame"] = 1000 * (t1 - t0) / FRAMES
out["trackpy_detected_per_frame"] = len(f) / FRAMES
json.dump(out, open(os.path.join(RES, "ptv_timing.json"), "w"), indent=1)
print(out)
