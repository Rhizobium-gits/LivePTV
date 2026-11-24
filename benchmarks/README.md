# Benchmarks

Everything behind the comparison and gallery in the [README](../README.md): LivePTV against OpenPIV (image
deformation, the same family as PIVlab) and trackpy on identical images, plus example sessions recorded by the real
app pipeline. The numbers in `results/` are the ones quoted in the README.

## Layout

| Path | What |
| --- | --- |
| `harness/` | Small Swift command-line tool that calls `PTVCore` directly (`piv`, `detect`, `track`, `ptv`, `timeptv` modes) on raw frames |
| `python/common.py` | Synthetic particle images with exactly known displacement (erf-integrated Gaussian particles, light sheet, noise, 8-bit), runners for LivePTV and OpenPIV |
| `python/piv_experiments.py` | E0 vector positions, E1 sub-pixel bias, E2 spatial resolution (sinusoids), E3 Lamb–Oseen vortices, E4 large displacements, E5 seeding / noise / out-of-plane loss, E6 speed |
| `python/ptv_experiments.py` | P1 detection and localisation, P2 tracking in a Taylor–Green flow, P3 end to end from images (vs trackpy) |
| `python/real_piv_compare.py` | OpenPIV's sample recordings (real images): LivePTV vs OpenPIV agreement and run time |
| `python/real_brownian_trackpy.py`, `real_brownian_compare.py` | trackpy's `bulk_water` microscopy video: diffusion coefficient and Stokes–Einstein size, LivePTV (app pipeline) vs trackpy |
| `python/synthetic_brownian_compare.py` | The same estimators on synthetic Brownian particles with known D |
| `python/ptv_timing.py` | PTV speed: detection + tracking of ~20,000 particles per 1920 × 1080 frame, LivePTV vs trackpy |
| `python/make_readme_figs.py` | The README figures (`docs/images`) |
| `python/make_readme_tables.py` | The README's *Experiments* section, written from `results/` between its markers |
| `results/` | JSON / CSV results (`v07/`: the same experiments with LivePTV 0.7; `camera_motion.json` and `showcase_summary.json` hold numbers printed by the tests, with their source) |
| `fetch_data.sh` | Downloads trackpy's `bulk_water` sample and encodes it as a ProRes video (not redistributed here) |

The example sessions come from `LivePTVKit/Tests/PipelineTests/ShowcaseTests.swift`: synthetic scenes with an exact
flow (vortex pair, Taylor–Green array, channel flow, faint tracers with ensemble correlation, camera shake, a stand
swaying about its foot, Brownian PTV) and the real `bulk_water` video, each run through `AnalysisPipeline` and `ExperimentRecorder` exactly as in the
app. They are skipped in normal test runs.

## Reproducing

```sh
cd benchmarks
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
(cd harness && swift build -c release)
./fetch_data.sh                                   # trackpy sample video (needs git and ffmpeg)

# example sessions (figures, report, CSV, VTK) → benchmarks/showcase/<scene>
cd .. && LIVEPTV_SHOWCASE_DIR=$PWD/benchmarks/showcase \
  LIVEPTV_REAL_BROWNIAN=$PWD/benchmarks/data/bulk_water_24fps_prores.mov \
  ./scripts/test.sh --filter ShowcaseTests && cd benchmarks

cd python
../.venv/bin/python piv_experiments.py e0 e1 e2 e3 e4 e5    # minutes
../.venv/bin/python piv_experiments.py e6                   # speed: run on an idle machine
../.venv/bin/python ptv_experiments.py p1 p2 p3
../.venv/bin/python real_piv_compare.py
../.venv/bin/python real_brownian_trackpy.py && ../.venv/bin/python real_brownian_compare.py
../.venv/bin/python synthetic_brownian_compare.py
../.venv/bin/python ptv_timing.py                           # idle machine
../.venv/bin/python make_readme_figs.py
../.venv/bin/python make_readme_tables.py
```

## What is and is not compared

- **Run here:** LivePTV (this repository), OpenPIV 0.26.3 (`windef`: symmetric image deformation, cubic spline,
  64 → 32 px, three final iterations), trackpy 0.7 (Crocker–Grier location, linking with a velocity predictor).
- **Not run:** PIVlab (needs MATLAB) and commercial packages (DaVis, DynamicStudio, Insight). The capability table in
  the README for those comes from their public documentation and release notes (checked November 2026).
- **Synthetic images** have exact ground truth but no lens, compression or real illumination. The real recordings
  (OpenPIV samples, trackpy `bulk_water`) have no ground truth: there the tools are compared with each other, and the
  Brownian particle size with the nominal 1 µm.
- **Speed** was measured on an Apple M4 (Mac). OpenPIV ran in one Python process, as it does by default.
