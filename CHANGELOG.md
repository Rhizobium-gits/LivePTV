# Changelog

## Unreleased (0.8): image deformation, corrected vector positions

Measured against OpenPIV 0.26 (window deformation, as in PIVlab) and trackpy 0.7 on the same synthetic images; the
comparison and its scripts are outside this repository.

- **Image deformation (default).** Every pass after the first resamples both frames with the previous field (frame A at
  x − d/2, frame B at x + d/2, Lanczos-4), so windows follow the velocity gradients inside them (Scarano 2002). The
  predictor is filled everywhere (masked and invalid cells from their measured neighbours), filtered adaptively to its
  noise (3 × 3 or ≈ 5 × 5 binomial), interpolated by cubic convolution on a grid extended by linear extrapolation, and
  not used below half valid vectors. Runs on the GPU (bit-identical deformed frames) and the CPU. Three final
  iterations by default (saved settings with the old default 2 are migrated, schema 4). Measured: Lamb–Oseen vortex
  0.104 → 0.022 px (OpenPIV 0.063 px); amplitude kept at 90 % down to λ = 80 px with 32-px windows (window shift 127 px,
  OpenPIV 77 px), no overshoot; uniform flow 0.0059 → 0.0066 px (the price where there is nothing to resolve). New
  settings *Window deformation* and *Smooth the predictor*; the methods paragraph names the scheme.
- **Vector positions.** Vectors are reported at their window centre x0 + (w − 1)/2 (they were at x0 + w/2, 0.5 px off;
  also in ensemble correlation and camera-shake re-measurement).
- **Edge vectors.** Windows at the image edge are measured where they are reported (they were measured 3–5 px further
  in, at the 8-tap kernel's margins; such windows now fall back to bilinear), and the normalised median test uses the
  5 × 5 block on the grid border, where the 3 × 3 neighbours lie on one side: in a shear flow 58–71 % of a correct
  edge row used to be replaced.
- **Tests.** `DeformationTests` (positions, edges, resolution, vortex, uniform flow, predictor), border cases in
  `GridKernelTests`, GPU/CPU comparison with and without deformation.
- **Camera motion beyond a shift.** The camera-shake fit now has translation, similarity, affine (shear, rolling
  shutter), linearised perspective (keystone, a tilting camera) and a pivot model (rotation and zoom about one point
  learned over the session, e.g. a stand swaying about its foot far outside the picture). *Automatic* (new default;
  saved "similarity" is migrated) chooses per pair by BIC among the models the static windows determine (a smallest
  normalised eigenvalue check keeps one-sided backgrounds from fitting shear or keystone). The pivot is reported live,
  in `evaluation.json` (`cameraMotion`), the report and the methods paragraph; `frames.csv` records the model, all
  parameters and each pair's turning point. **PTV is corrected too**: consecutive frames are cross-correlated for the
  static windows and every particle step has the camera motion between its frames subtracted. Measured: a stand
  swaying about a point 900 px below the picture, static-border fluctuation 13.96 → 1.17 px/s and the pivot found within
  15 px; PTV velocity error 10.54 → 2.54 px/s; shear + keystone 4.82 (similarity) → 1.45 px/s.
- **PTV detection.** Threshold = background level + k·σ from the median and MAD of the smoothed foreground (k = 5;
  particles no longer raise it): recall at 0.01 particles/px 0.45–0.53 → 0.76–0.89, worst precision 0.997, pure noise
  gives no detections. The running background is not updated under this frame's detections (slow particles used to
  leak into it and be pushed along their motion: Brownian D +37 % → +3 %). Saved `thresholdK` is dropped (schema 4).
- **PTV tracking.** Global minimum-cost assignment per connected group (shortest augmenting paths), a search radius
  that grows with speed, acceleration while consistent, and a neighbour-consistency vote for tracks without a
  prediction: 5000 particles at 1.4 spacings per frame, precision / recall 0.32 / 0.21 → 0.98 / 0.97 (trackpy with a
  velocity predictor 0.77 / 0.67). 20,000 particles per 1080p frame: detect + track 52 ms.
- **Fix: static background slowly lost.** The static test learned from fields that keep the long-term mean motion, so
  static windows showed it as a steady offset and dropped out one by one (compensation could stop after ~60 pairs on
  clean images). It now learns from fields with the whole motion removed.
- **Tested with a real camera.** An Insta360 Ace Pro 2 in USB webcam mode on an M4 Mac (`ace-probe usb`): 1920 × 1080
  at 30.1 fps by the camera's timestamps, PIV at ½ resolution analysed live at 29 fps (19 ms per frame, 2 of 1,334
  frames skipped), full resolution ≈ 10 fps (85–98 ms per frame live). Four faults showed up that synthetic tests had not:
  - *Camera that stays silent.* The Ace Pro 2 sometimes reports 1080p30 but sends no frame until it has streamed
    another format once. A watchdog restarts the stream through the smallest other format when no frame arrives within
    3 s, and reports a second silence (`ExternalCameraSource.restartStream()`).
  - *Camera-motion correction on real images.* A still camera at ½ resolution received corrections of up to 516 px at
    the frame edge (median 0.94 px). Causes and fixes: static windows were re-measured on the raw frames with their own
    vectors as offsets, which after background removal are noise (now one robust offset, the median of the static
    windows); a model was used when a few clustered windows determined it locally (now also the correction's precision
    at the field's corners: leverage ≤ 0.25, or absolute noise ≤ 0.05 px); fits whose static windows disagree by more
    than 1/16 window are not applied (reported, with a warning); a session pivot also needs rotations at least twice
    their noise (noise fitted from a cluster of windows looks like rotation about that cluster). Afterwards: median
    0.04 px, maximum 1.2 px; temporal scatter of the still scene's mean field 11.8 → 0.8 px/s (full resolution 30.8 →
    1.3 px/s, maximum correction 1.38 → 0.18 px). The re-measurement runs in parallel (full-resolution frame 93 → 77 ms).
  - *Empty live field with long pairs.* A PIV field is dated at its pair's mid time; with automatic 1-s pairs (a still
    scene) and a 0.25-s averaging window, the displayed field was empty while every pair was measured. The newest field
    is now always part of the average.
  - `ace-probe`: `file` mode (a recorded video through the same pipeline), analysis switches for `usb`/`file`
    (`--method --shake --shake-model --deform --gpu --background --resolution --spacing`), `--save-video` (every camera
    frame as ProRes with its timestamp, for re-analysis by any tool), `--gif-every` (the live overlay as frames, with
    `hud.csv`), `--blur-faces` / `--blur-rect` (privacy in published pictures only; the analysis uses the raw frames).
- **Real-camera comparison** (`benchmarks/python/real_camera_compare.py`): LivePTV, OpenPIV, OpenCV DIS and Farnebäck on
  the same recorded stream; known motion applied to real frames (median error 0.089 px vs 0.195, 0.272, 0.429 px), false
  motion on the still background, agreement on real motion, time per pair (52 ms vs 2.3 s, 52 ms, 142 ms). The README
  opens with an animation of the live analysis (faces blurred).
- **Synthetic camera.** Rotation about any point (`shakePivot`), zoom, shear and keystone.
- **Synthetic flows.** A counter-rotating vortex pair and a Taylor–Green vortex array, also in the app's demo source.
- **Example sessions and benchmarks.** `ShowcaseTests` (run only with `LIVEPTV_SHOWCASE_DIR`) records synthetic scenes
  and a real microscopy video through the app pipeline; `benchmarks/` holds the harness, scripts and results that
  compare LivePTV with OpenPIV and trackpy on the same images (README: *What you can see*, *How it compares*).

## Unreleased: GPU correlation

- **GPU (Metal).** The 32-px correlation passes (window fill, mean/σ, single-vector uncertainty, FFT cross-correlation,
  peak search) run on the GPU; the sub-pixel fit stays on the CPU with the same code, so the vectors are the same as on
  the CPU (statuses identical, ≤ 6·10⁻⁷ px, σ ≤ 0.01 %). Apple M4, 1920×1080: 42.0 ms per frame instead of 56.1 ms;
  1280×720: 17.0 instead of 23.3 ms. The shader is compiled at run time (no Xcode step, works in Swift Playgrounds) and
  checks itself at start-up; GPUs below Apple family 7, other window sizes and the new setting *Correlate on the GPU*
  off use the CPU. The live panel shows where the correlation ran; `ace-probe benchmark --gpu 0` times the CPU path.
- **Tests.** `GPUCorrelationTests` compare the two paths on a scene with every window status (101 tests in total).

## 0.7.0 (2026-11-24): research-grade corrections

- **Scene corrections.** Running-mean temporal background removal (default); lower/upper envelopes as options. Static-glare
  and moving-glint (saturated blob) masks; user exclusion regions; masked windows get their own status and stay out of
  validation, replacement and statistics.
- **Container refraction.** Round bottles and flat-walled tanks. Camera rays are traced in 3-D through wall and
  fluid (vector Snell's law), for a distant camera or one at a known distance. The length scale comes from the bottle
  silhouette, the wall band is masked, displacements are mapped end to end, and session results are resampled on a
  regular grid in true plane coordinates.
- **Accuracy.** Final passes shift windows with an 8-tap Lanczos kernel instead of bilinear interpolation. The aligned-window
  bias falls from 0.053 px to 0.002 px, and the actual error on clean images from 0.040 px to 0.006 px.
- **Uncertainty.** Per-vector random uncertainty from correlation statistics (Wieneke 2015); predicted/actual
  0.82–1.10 on synthetic images. Per-cell single-sample uncertainty and noise-corrected fluctuation.
- **Diagnostics.** Particle-image diameter from the correlation-peak width; peak-locking index; masked shares.
- **Camera shake with background removal.** Static windows are measured again on the raw frames.
- **Outputs.** `figure_quality` (masks, uncertainty map, sub-pixel histogram, container magnification), `methods.txt`
  and a methods section in `report.html`, `mean_field.vtk`, `mean_field_image_grid.csv`, uncertainty columns.
- **App.** Container outline and exclusions drawn on the live image, mask overlay, new settings sections.
- **Library.** Root `Package.swift`, so the repository can be added by URL; MIT licence; CI.
- **Docs.** `docs/METHODS.md` and `docs/METHODS_ja.md` (computational framework and validation).
- **Validation.** Bottle scene, reflection/glint scene, ray-tracer vs closed form, uncertainty calibration and
  interpolation-bias tests (98 tests in total).
- **Privacy.** The example MAC address in the sources is now a placeholder.

## 0.6.0

Ensemble correlation, smooth live display (AVSampleBufferDisplayLayer), unoptimised-build speed-ups, Xcode project.
