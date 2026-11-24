# Changelog

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
