# LivePTV

[![CI](https://github.com/Rhizobium-gits/LivePTV/actions/workflows/ci.yml/badge.svg)](https://github.com/Rhizobium-gits/LivePTV/actions/workflows/ci.yml)
![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-orange)
![iPadOS 17 | macOS 14](https://img.shields.io/badge/platforms-iPadOS%2017%20%7C%20macOS%2014-blue)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**Real-time particle image velocimetry (PIV) and particle tracking (PTV) on an iPad, with the corrections a real
experiment needs.** A camera looks at a bottle or a tank. LivePTV removes the glass reflections, glare and glints,
undoes the lens effect of the filled container by ray tracing, and reports velocity fields in true plane coordinates.
Every vector comes with its uncertainty, and a methods paragraph is generated for your paper.

日本語の概要は[下](#日本語の概要)にあります。演算の体系（日本語）: [docs/METHODS_ja.md](docs/METHODS_ja.md)

<p align="center">
  <img src="docs/examples/synthetic_bottle_piv/figure_summary.png" width="49%" alt="Time-averaged vortex in a glass bottle, true plane coordinates">
  <img src="docs/examples/synthetic_bottle_piv/figure_quality.png" width="49%" alt="Masks, single-vector uncertainty, peak locking and the bottle's lateral magnification">
</p>

*Synthetic validation case, generated and checked by the tests.* A Lamb–Oseen vortex in water inside a 60 mm glass
bottle, filmed from the side, with reflection stripes on the glass, a saturated hot spot, and a glint travelling along
the free surface. Corrected result: 1.9 % relative RMS error. A naive analysis (mm/px from the bottle diameter, no
corrections) gives 34.5 %. Full output: [docs/examples/synthetic_bottle_piv](docs/examples/synthetic_bottle_piv/), which
includes `report.html` and `methods.txt`.

**Contents:** [What you can see](#what-you-can-see) · [How it compares](#how-it-compares) ·
[What it does](#what-it-does) · [Validation](#validation-all-asserted-by-scriptstestsh) ·
[Measuring a flow in a bottle](#measuring-a-flow-in-a-bottle) · [Getting started](#getting-started) · [日本語の概要](#日本語の概要)

## What you can see

Every recording ends with an evaluation folder: publication figures (PNG + vector PDF), a self-contained
`report.html`, a `methods.txt` paragraph, CSV and VTK. The figures below were written by the app's own pipeline and
recorder ([`ShowcaseTests`](LivePTVKit/Tests/PipelineTests/ShowcaseTests.swift)); the synthetic scenes have an exact
flow, so each caption gives the error of the time-averaged field.

| | |
| --- | --- |
| <img src="docs/images/app_vortex_pair.jpg" alt="Counter-rotating vortex pair: speed and vectors, streamlines, vorticity, divergence"> | <img src="docs/images/app_vortex_array.jpg" alt="Taylor–Green vortex array: speed and vectors, streamlines, vorticity, divergence"> |
| **Counter-rotating vortex pair.** Speed and vectors, evenly spaced streamlines, vorticity (sign shown), divergence as a check of planar flow. Mean field within 0.32 % of the exact flow. | **Taylor–Green vortex array**, twelve cells of alternating rotation. 0.23 %. |
| <img src="docs/images/app_channel_profiles.jpg" alt="Channel flow: velocity profiles with error bars"> | <img src="docs/images/app_ensemble.jpg" alt="Ensemble-correlation field of faint, sparse Brownian tracers"> |
| **Channel (Poiseuille) flow.** Centre-line profiles with ±2 standard errors and the ±1 SD fluctuation band. 0.81 %. | **Faint, sparse, Brownian tracers (µPIV-like).** Ensemble correlation over 149 pairs: 7.4 % error, where averaging single-pair vectors gives 11.8 %. |
| <img src="docs/images/app_bottle_overlay.jpg" alt="Mean speed and vectors drawn over the camera image of the bottle"> | <img src="docs/images/app_bottle_quality.jpg" alt="Measurement quality: masks, uncertainty map, sub-pixel histogram, container magnification"> |
| **Over the camera image.** The bottle case above, true velocities at their apparent positions. | **Measurement quality.** What was masked and why, the random uncertainty of single vectors, the sub-pixel histogram (peak locking), the bottle's magnification. |

**Real recordings.** OpenPIV's sample PIV recordings, analysed by LivePTV (blue vectors). There is no ground truth;
LivePTV and OpenPIV agree to a median of 0.02–0.07 px, and LivePTV takes 6–94 ms per pair where OpenPIV takes
0.2–4 s ([details](#real-recordings)).

<img src="docs/images/real_piv.jpg" alt="Three real PIV recordings with LivePTV vectors: dense seeding, a plate edge with glare, a stirred tank">

**Brownian motion, real microscopy video.** trackpy's `bulk_water` sample (1 µm latex spheres in water, 24 fps)
played into the app as a video file, PTV mode: tracks, the diffusion coefficient and the Stokes–Einstein diameter.
With the same estimator, LivePTV and trackpy agree within 1 % (lag 1–2: 1,252 vs 1,243 nm) and 4 % (10-lag MSD fit:
983 vs 1,021 nm) ([details](#particle-tracking)).

<img src="docs/images/real_brownian.png" alt="LivePTV tracks of Brownian spheres, ensemble mean squared displacement, and particle sizes from LivePTV and trackpy">

**Camera motion.** A camera on a stand that sways about its foot, 900 px below the picture, through the full
pipeline: the apparent velocity fluctuation of the static border falls from 13.96 to 1.20 px/s, the turning point is
located within 25 px and reported as outside the frame, and PTV particle velocities improve from 10.52 to 3.55 px/s
RMS error. Rolling-shutter shear with keystone: 1.46 px/s with the automatic model, 4.87 px/s with shift + rotation +
zoom only. The mean field is not the issue (zero-mean shake averages out); fluctuation and turbulence statistics,
and every single PTV step, are. Synthetic Brownian PTV through the pipeline: D within 3 % of the true value,
Stokes–Einstein 557 nm for true 572 nm.

## How it compares

LivePTV was run against [OpenPIV](https://github.com/OpenPIV/openpiv-python) 0.26.3 (iterative image deformation, the
same family as PIVlab) and [trackpy](https://github.com/soft-matter/trackpy) 0.7 on identical images. Scripts, raw
results and how to rerun them: [benchmarks/](benchmarks/).

### Capabilities

From public documentation, release notes and source code (November 2026). Commercial tools were not tested.

| | LivePTV 0.8 | PIVlab 3.14 / 4.0 β | OpenPIV 0.26 | PaIRS-UniNa 0.2 | DaVis 11, DynamicStudio, Insight 4G | trackpy 0.7 |
| --- | --- | --- | --- | --- | --- | --- |
| Runs on | iPad, Mac | MATLAB, Windows app | Python | Windows, macOS, Linux | Windows | Python |
| Analysis while filming | **yes** (GPU) | camera control and live image; live PIV not implemented | no | no | vendor "real-time / online" modes | no |
| Iterative image deformation | yes | yes | yes | yes | yes | – |
| Per-vector uncertainty | yes (correlation statistics) | yes (image matching) | no (signal-to-noise only) | no | yes | – |
| Ensemble correlation | yes | yes | no | statistics only | yes | – |
| Refraction through a round container | **yes, live** | no | no | yes (offline) | not documented | – |
| Lens distortion, stereo, 3-D | no | distortion, stereo (4.0 β) | no | yes | yes (incl. Shake-the-Box) | – |
| Particle tracking | 2-D, live | no | no | no | 3-D LPT / Shake-the-Box | 2-D and N-D, offline |
| Report with methods paragraph | yes | – | – | – | – | – |
| Licence | MIT | MIT | GPL-3.0 | LGPL-3.0 | commercial | BSD-3 |

### Accuracy on synthetic images with known truth

Same images for every tool: erf-integrated Gaussian particle images (2.5 px), light sheet, 2 grey levels of noise, 8 bit.
Windows 64 → 32 px, 50 % overlap, three final iterations for both PIV tools.

| Measure | LivePTV 0.7 | **LivePTV 0.8** | OpenPIV 0.26 |
| --- | --- | --- | --- |
| Vector position error (shear flow) | 0.5 px | **0.003 px** | 0.03–0.05 px |
| Largest sub-pixel bias, uniform flow | 0.003 px | **0.003 px** | 0.016 px |
| Random error, uniform flow | **0.0060 px** | 0.0066 px | 0.0092 px |
| Shortest wavelength kept at 90 % amplitude (32-px windows) | 127 px | 80 px (65 px unfiltered) | **63 px** |
| Lamb–Oseen vortex, core 60 px: RMS error | 0.041 px | **0.008 px** | 0.018 px |
| Lamb–Oseen vortex, core 30 px: RMS error | 0.111 px | **0.023 px** | 0.053 px |
| Sparse seeding (0.005 particles/px): RMS error | 0.111 px | **0.040 px** | 0.073 px |
| Heavy noise (σ = 24 grey levels): RMS error | 0.090 px | **0.081 px** | 0.103 px |

<p align="center">
  <img src="docs/images/bench_resolution.png" width="49%" alt="Amplitude recovered against wavelength: LivePTV 0.7, LivePTV 0.8, OpenPIV, top-hat theory">
  <img src="docs/images/bench_robustness.png" width="49%" alt="RMS error against seeding density, noise and out-of-plane motion">
</p>
<p align="center"><img src="docs/images/bench_vortex.png" width="80%" alt="Error maps for a strong vortex: LivePTV 0.7, LivePTV 0.8, OpenPIV"></p>

Where LivePTV 0.8 does not lead: OpenPIV keeps slightly finer detail at default settings, because LivePTV filters its
deformation predictor to keep the noise down (switch *Smooth the predictor* off: 65 px, at about twice the random
error). In uniform flow there is nothing to resolve and the predictor adds a little noise (0.0060 → 0.0066 px), and on
18 faint, difficult image pairs the valid share drops from 88.5 to 87.0 %.

### Real recordings

| OpenPIV sample | Size | LivePTV vs OpenPIV: median difference | within 0.2 px | LivePTV | OpenPIV |
| --- | --- | --- | --- | --- | --- |
| test1, dense seeding | 511 × 369 | 0.066 px | 95 % | 6 ms | 0.19 s |
| test2, plate edge with glare | 1008 × 1012 | 0.049 px | 83 % | 20 ms | 1.0 s |
| test4, stirred tank | 1720 × 2304 | 0.024 px | 93 % | 94 ms | 4.1 s |
| test5, tank with a glint (nearly still) | 1024 × 1024 | 0.021 px | 96 % | 22 ms | 1.0 s |

Both tools produce scattered vectors in regions without particles (behind the plate in test2); LivePTV's are somewhat
wilder there.

### Particle tracking

Detection on single frames (particle images 1.5–4 px, noise σ 2–8 grey levels, 0.002–0.01 particles/px), tracking
of exact positions plus 0.05 px noise in a Taylor–Green flow with 2 % of the particles replaced per frame, and the
whole chain from images. trackpy's minimum mass was tuned per condition for its best F1; LivePTV runs on defaults.

<p align="center"><img src="docs/images/bench_ptv.png" width="95%" alt="Link correctness against displacement, and detection F1 per condition, for LivePTV 0.7, LivePTV 0.8 and trackpy"></p>

| Measure | LivePTV 0.7 | **LivePTV 0.8** | trackpy 0.7 |
| --- | --- | --- | --- |
| Detection recall, 0.01 particles/px (2.5–4 px images) | 0.45–0.53 | **0.76–0.89** | 0.77–0.87 (tuned) |
| Detection precision, worst condition | 0.990 | **0.997** | 0.983 |
| Localisation error | 0.04–0.14 px | 0.06–0.15 px | 0.08–0.19 px |
| Links right (precision / recall), 5000 particles, 10 px/frame = 1.4 spacings | 0.32 / 0.21 | **0.98 / 0.97** | 0.77 / 0.67 |
| Same, 6 px/frame = 0.8 spacings | 0.90 / 0.86 | **0.995 / 0.994** | 0.90 / 0.86 |
| From images, 3000 particles at 5 px/frame: samples per frame, share off by > 0.5 px | 1,084, 3.8 % | 1,887, **2.7 %** | 2,107, 8.1 % |
| Brownian D, synthetic (true 3.5 px²/s), lag 1–2 / 10-lag MSD | +37 % / +26 % | **+3 % / +4 %** | +5 % / +1 % |

What changed in 0.8: a threshold from the median and MAD of the image (particles no longer raise it), a running
background that does not learn the particles (slow particles were pushed along their motion, inflating Brownian D),
global minimum-cost assignment instead of nearest-first, a search radius that grows with speed, and a
neighbour-consistency vote for tracks without a prediction yet. Where it does not lead: small particle images
(1.5 px) in heavy noise, where recall fell from 0.65 to 0.57 (trackpy 0.58).

**Real video (trackpy `bulk_water`).** LivePTV through the app pipeline, trackpy as in its walkthrough, both drift
corrected. With the same estimator the two agree: lag 1–2 (LivePTV's estimator, localisation noise removed) 0.342 vs
0.345 µm²/s, 10-lag MSD fit 0.436 vs 0.420 µm²/s. The recording spreads slightly faster than diffusive (MSD exponent
1.07), so the two estimators differ by 25 %; the MSD fit gives 983 / 1,021 nm for the nominal 1 µm spheres at 20 °C.

### Speed

<p align="center"><img src="docs/images/bench_speed.png" width="80%" alt="Time per image pair at 1280×720 and 1920×1080"></p>

| Task (Apple M4, analysis engine) | LivePTV 0.8 | Reference |
| --- | --- | --- |
| PIV, 1280 × 720 pair (64 → 32 px, deformation, 3 iterations) | 17 ms on the GPU, 27 ms CPU only | OpenPIV 0.26: 0.91 s |
| PIV, 1920 × 1080 pair | 39 ms on the GPU, 67 ms CPU only | OpenPIV 0.26: 2.1 s |
| PTV, 1920 × 1080 frame with ~20,000 particles (detect + track) | 52 ms (17,500 found) | trackpy 0.7: 0.49 s (10,700 found) |
| PIV on OpenPIV's real samples (511 × 369 … 1720 × 2304) | 6–94 ms | OpenPIV 0.26: 0.19–4.1 s |

OpenPIV and trackpy ran in one Python process, as they do by default; both can be parallelised over image pairs.
LivePTV's numbers are per pair inside one process, so they set the live frame rate. iPad timings are not measured yet.

## What it does

| | |
| --- | --- |
| **Sources** | Insta360 Ace Pro 2 over its own Wi-Fi (community-documented protocol, *not yet verified on hardware*); USB/UVC cameras on iPad and Mac; video files; synthetic flows with known ground truth (vortex, vortex pair, Taylor–Green array, rotation, channel, uniform, Brownian, camera shake) |
| **PIV** | Multi-pass FFT cross-correlation (64 → 32 px) with iterative image deformation (symmetric, 8-tap Lanczos resampling, cubic predictor with noise-adaptive filtering), overlap-unbiased 3-point Gaussian peak fit, correlation threshold, normalised median test, flagged replacement, adaptive pair spacing for slow flows |
| **Uncertainty** | Random uncertainty of every vector from correlation statistics (predicted ÷ actual error 0.72–1.48 over the test and benchmark conditions, see [METHODS §18](docs/METHODS.md#18-limitations-and-recommendations)); noise-corrected fluctuations; standard errors of the mean |
| **Scene corrections** | Running-mean background removal (reflections, labels, scratches); static-glare and moving-glint masks; user exclusions; camera-motion compensation for PIV and PTV: shift, rotation about any point (also far outside the picture, e.g. a stand swaying about its foot, which is located and reported), zoom, rolling-shutter shear and keystone, chosen automatically per pair from what the static background can determine |
| **Containers** | Round bottles and flat tanks: 3-D ray tracing through wall and fluid (Snell's law), length scale from the bottle silhouette, wall band masked, displacements mapped end to end, results resampled on a regular grid in true coordinates |
| **Speed** | Image deformation and the 32-px correlation passes run on the GPU (Metal, shader compiled at run time, so it also works in Swift Playgrounds) with the same vectors as the CPU path (tested to 1e-4 px; deformed frames bit-identical); Apple M4, analysis engine: 17 ms per pair at 1280×720, 39 ms at 1920×1080. Falls back to the CPU (Accelerate) on GPUs older than Apple7 |
| **PTV** | Detection above a robust noise threshold with a background that does not learn the particles, 3-point Gaussian sub-pixel positions, tracking by global minimum-cost assignment with speed-dependent gates and a neighbour-consistency start, Brownian diffusion and Stokes–Einstein size |
| **Also** | Ensemble correlation (µPIV), particle-image diameter and peak-locking diagnostics |
| **Outputs** | Self-contained `report.html`, `methods.txt`, publication figures (PNG + vector PDF), CSV, VTK (ParaView), raw per-frame records, bit-exact preview stream |

How every number is computed, why, and how it was validated: **[docs/METHODS.md](docs/METHODS.md)** (English) /
**[docs/METHODS_ja.md](docs/METHODS_ja.md)** (日本語).

## Validation (all asserted by `./scripts/test.sh`)

| Case | Result |
| --- | --- |
| Vortex in a 60 mm bottle with reflections and glints, end to end | 1.9 % error (naive 34.5 %) |
| Reflection stripe + hot spot + moving glint over a uniform flow | RMS 0.170 → 0.030 px; outliers 2.2 % → 0 % |
| Uniform flow imaged through a 56 mm bottle | 0.451 → 0.046 px |
| Ray tracer vs closed-form optics | ≤ 1.2·10⁻⁴ mm; centre magnification 0.7502 = 1/n |
| Single-vector uncertainty vs actual error | ratio 0.72–0.90 over noise, size and out-of-plane loss |
| Sub-pixel bias of aligned windows | bilinear 0.053 px → Lanczos-4 0.002 px |
| Image deformation vs window shift | Lamb–Oseen vortex 0.104 → 0.022 px; sinusoid at λ = 2 windows: amplitude 0.72 → 0.84 |
| Vector positions; edge rows in a shear flow | offset 0.5 → < 0.1 px; edge vectors replaced 58–71 % → 0 % |
| GPU (Metal) vs CPU correlation, same frames | statuses identical; vectors within 7·10⁻⁵ px (deformed frames bit-identical); uncertainty within 0.1 % |
| Ensemble correlation, faint sparse vortex | 8.5 % vs 11.8 % (vector average); 99 % valid |
| Camera on a stand swaying about a point 900 px below the picture | static-border fluctuation 13.96 → 1.20 px/s; pivot located within 25 px; PTV velocity error 10.52 → 3.55 px/s |
| Rolling-shutter shear + keystone | 1.46 px/s (automatic model) vs 4.87 px/s (shift + rotation + zoom only) |
| Brownian diffusion coefficient | within 4 %; with background removal on, +3 % (was +37 %: slow particles leaked into the background) |
| PTV linking, 5000 particles at 1.4 spacings per frame | precision / recall 0.98 / 0.97 (was 0.32 / 0.21) |

## Measuring a flow in a bottle

1. Fill and seed the bottle (or use the turbidity of the fluid itself). Fix the camera on a stand, perpendicular to
   the bottle, and use the camera's linear (distortion-corrected) mode. A light sheet through the axis defines the
   measurement plane best.
2. In the app, choose the source and start the preview.
3. **Container → Round bottle**, then **Mark container outline**. Drag from one outer edge of the bottle to the other,
   from just below the free surface to just above the base.
4. In *Analysis settings › Container and refraction*, enter the outer diameter, the wall thickness and the materials
   (presets for glass, PMMA, PET, water, glycerol and more). The length scale now comes from the silhouette.
5. Leave *Background removal* on the running mean. Use **Add exclusion** for labels or reflections that are still
   visible. *Show masked areas* displays what is ignored.
6. **Start recording**, then stop. The session folder contains the evaluation, figures, the methods paragraph and all
   raw data (Files app: *On My iPad › LivePTV › Sessions*).

For a flat-walled tank, calibrate mm/px with a target in the measurement plane. Alternatively, calibrate on the outer
wall, give the camera distance, and enable *calibrated on the outer wall*.

## Getting started

**iPad app (Xcode).** Open `LivePTV.xcodeproj`, choose your team under *Signing & Capabilities* (a free Apple ID
works), select your iPad and run. The scheme builds Release (the analysis needs compiler optimisation).
Step-by-step guide in Japanese: [docs/INSTALL_XCODE_ja.md](docs/INSTALL_XCODE_ja.md).
Without Xcode, `./scripts/make-swiftpm.sh` builds a Swift Playgrounds package that runs on the iPad itself (unoptimised,
about 3× slower).

**As a Swift package.** Add `https://github.com/Rhizobium-gits/LivePTV` and depend on `PTVCore` (algorithms only) or
`LivePTVKit` (sources, pipeline, recording, SwiftUI app):

```swift
import PTVCore

// 🐱 the bottle: outer silhouette marked on the image, 60 mm glass bottle with water
var bottle = ContainerGeometry()
bottle.shape = .cylinder
bottle.outline = PixelROI(x: 70, y: 30, width: 500, height: 420)
bottle.outerDiameterMM = 60
bottle.wallThicknessMM = 2
let map = RefractionMap(geometry: bottle, calibrationMMPerPixel: nil)!

// 🐱 per frame, in time order: background + masks, then PIV between consecutive frames
// 🐱 (a, b: LumaImage, the luma plane of two frames as Float)
let suppressor = ReflectionSuppressor()
let engine = PIVEngine()
let walls = StaticMask.build(width: a.width, height: a.height, originX: 0, originY: 0, scale: 1,
                             exclusions: [], container: map)
let pa = suppressor.process(a, staticMask: walls), pb = suppressor.process(b, staticMask: walls)
if var field = engine.compute(a: engine.prepare(pa.image, mask: pa.mask),
                              b: engine.prepare(pb.image, mask: pb.mask), dt: 1.0 / 30) {
    map.correct(&field)            // 🐱 true displacements in the measurement plane
    // field.dx / field.dy (px per pair) × map.mmPerPixel → mm; field.sigmaX / sigmaY: uncertainty
}
```

**Tests and tools on a Mac** (Command Line Tools are enough):

```sh
./scripts/test.sh                                     # 135 tests: algorithms, optics, GPU vs CPU, end-to-end recordings, protocol
cd LivePTVKit
swift run -c release ace-probe benchmark --width 1280 --height 720   # add --gpu 0 to time the CPU-only path
swift run -c release ace-probe probe --seconds 20     # Mac joined to the camera Wi-Fi: hardware check
```

## Repository layout

| Path | What |
| --- | --- |
| `LivePTVKit/Sources/PTVCore` | Algorithms: PIV engine (CPU and Metal GPU correlation), uncertainty, ensemble correlation, background and masks, refraction (ray tracing), shake compensation, PTV detector and tracker, statistics |
| `LivePTVKit/Sources/Pipeline` | Frame pipeline, recording, end-of-measurement evaluation, figures, report, VTK |
| `LivePTVKit/Sources/CameraKit` | Camera sources (Insta360 Wi-Fi client, USB, files, synthetic), H.264/H.265 decoding |
| `LivePTVKit/Sources/LivePTVUI` | SwiftUI app (live view, settings, sessions) |
| `LivePTVKit/Sources/ace-probe` | Mac command line: camera verification, benchmark, USB live analysis |
| `LivePTVKit/Tests` | 135 tests, including the validation cases above (`ShowcaseTests` writes the example sessions when asked) |
| `App/`, `LivePTV.xcodeproj`, `project.yml` | iPad app shell (XcodeGen); the package lives in `LivePTVKit/` because Xcode cannot use the project's own folder as a local package |
| `Package.swift` | Root manifest so the repository can be added by URL |
| `docs/` | [METHODS](docs/METHODS.md), [Japanese methods](docs/METHODS_ja.md), [camera integration report](docs/TECHNICAL_REPORT.md), [Xcode guide (ja)](docs/INSTALL_XCODE_ja.md), example session, README images |
| `benchmarks/` | Comparison with OpenPIV and trackpy: Swift harness, Python scripts, results ([benchmarks/README.md](benchmarks/README.md)) |
| `scripts/` | `test.sh`, `pack.sh` (zip for another Mac), `make-swiftpm.sh` (Swift Playgrounds), `mock_camera.py` |

## Session data

Each recording folder holds:
- `session.json`: every setting, the camera, the calibration and the clock anchor;
- per-frame records (`frames.csv`, `particles.csv`, `velocities.csv`, `field.csv`, `piv_vectors.csv` with
  per-vector uncertainty and status valid / replaced / invalid / masked);
- the received preview stream, bit-exact;
- the evaluation: `report.html`, `evaluation.json`, `methods.txt`, `mean_field.csv` (rectified when a container is
  set), `mean_field.vtk`, and the figures `figure_summary`, `figure_quality`, `figure_profiles`, `figure_timeseries`
  and `figure_ensemble`.

The details are in [docs/METHODS.md §16](docs/METHODS.md#16-outputs).

## Status and limitations

- The Insta360 Ace Pro 2 Wi-Fi protocol is community-documented and tested only against a protocol-accurate mock
  camera. Verify it with `ace-probe` before relying on it ([camera report](docs/TECHNICAL_REPORT.md), §9). USB cameras work.
- Refraction is corrected for one measurement plane. With volume illumination of turbid fluid, the image is
  depth-averaged. See [METHODS §18](docs/METHODS.md#18-limitations-and-recommendations) for this and the other
  assumptions: optical axis, lens distortion, temperature-dependent refractive indices.
- Velocities use camera timestamps. The live preview is compressed; keep the camera's own recording for re-analysis.
- The comparisons use synthetic images (exact truth, no lens or compression) and public sample recordings (no truth).
  PIVlab and commercial packages were not run. iPad hardware speed has not been measured yet (all timings: Apple M4 Mac).

## 日本語の概要

LivePTV は、カメラ映像から流れ場を iPad 上でリアルタイムに計測する PIV/PTV アプリとライブラリです。瓶や水槽越しに撮影する実験で問題になる次の誤差を補正します。

- **瓶の反射・ラベル・傷**: 時間平均の背景を差し引いて除去します。
- **映り込みの強い部分（グレア）と、水面のきらめき**: 自動でマスクします。それ以外に除外したい場所は、画面上で手で指定できます。
- **丸い瓶のレンズ効果**: 水を入れた円筒は、中心付近で幅を約 1.33 倍に、壁際ではそれ以上に引き伸ばして見せます。カメラからの光線を壁と液体の中で屈折させて追跡し（スネルの法則）、測定面上の本当の位置と速度に直します。長さの尺度は瓶の外径とその見かけの幅から決まります。
- **カメラの揺れ**: 静止部分から推定して差し引きます。

すべてのベクトルに不確かさ（相関統計による推定）が付きます。PIV は窓変形（反復画像変形）方式で、画像の変形と 32 px の相関を GPU（Metal）で計算し、CPU と同じベクトル（差 1·10⁻⁴ px 以内）を返します。Apple M4 では 1280×720 の 1 ペアを 17 ms、1920×1080 を 39 ms で解析します。記録を止めると、図（PNG とベクター PDF）、レポート、論文用の手法説明文、CSV、VTK が自動で保存されます。合成データによる検証では、反射と水面のきらめきがある 60 mm ガラス瓶の中の渦を誤差 1.9 % で再現しました。補正なしの解析では 34.5 % でした。

**既存ツールとの比較**（同じ画像で OpenPIV 0.26・trackpy 0.7 と比較。手順と結果は [benchmarks/](benchmarks/)）:

| 項目 | LivePTV 0.8 | OpenPIV 0.26 |
| --- | --- | --- |
| 渦（コア 30 px）の RMS 誤差 | **0.023 px** | 0.053 px |
| 粒子の少ない画像（0.005 個/画素） | **0.040 px** | 0.073 px |
| 一様流のサブピクセル系統誤差 | **0.003 px** | 0.016 px |
| 振幅 90 % を保つ最短の波長（32 px 窓） | 80 px | **63 px** |
| 1 ペアの処理時間（実画像、1008×1012） | **20 ms** | 1.0 s |

| 粒子追跡の項目 | LivePTV 0.8 | trackpy 0.7 |
| --- | --- | --- |
| 正しく結べた割合（粒子 5000 個、1 フレーム 10 px = 粒子間隔の 1.4 倍） | **0.98 / 0.97** | 0.77 / 0.67 |
| ブラウン運動の拡散係数（合成、真値 3.5 px²/s） | +3 % | +5 % |
| 1920×1080・粒子約 2 万個の 1 フレーム（検出 + 追跡） | **52 ms** | 0.49 s |

OpenPIV に同梱の実験画像（正解なし）では、2 つのツールの差は中央値 0.02–0.07 px でした。trackpy の実際の顕微鏡動画（1 µm の粒子のブラウン運動）では、同じ推定式で拡散係数が 1 % 以内で一致しました。分解能（細かい構造の再現）は OpenPIV の既定がわずかに上です。LivePTV は予測場を平滑化してノイズを抑えているためで、平滑化を切ると 65 px になります。

カメラを載せた台の揺れも補正します。平行移動だけでなく、画面の外の点（台の根元など）を中心とする回転、ローリングシャッターのせん断、カメラの傾きによる台形のゆがみを、静止した背景から自動で見分けて差し引きます。回転の中心も推定して表示します。PIV だけでなく PTV の速度にも効きます。画面の 900 px 下を中心に揺れる台の合成映像では、静止した縁の見かけの速度変動が 13.96 から 1.20 px/s に下がり、PTV の速度誤差は 10.52 から 3.55 px/s になりました。

- 演算の体系と検証の詳細: [docs/METHODS_ja.md](docs/METHODS_ja.md)
- iPad へのインストール手順: [docs/INSTALL_XCODE_ja.md](docs/INSTALL_XCODE_ja.md)
- 瓶で測る手順は、上の「Measuring a flow in a bottle」と同じです。

## Citation and license

If you use LivePTV in published work, please cite it ([CITATION.cff](CITATION.cff)) and the method papers listed in
[METHODS §19](docs/METHODS.md#19-references). MIT License, see [LICENSE](LICENSE).
